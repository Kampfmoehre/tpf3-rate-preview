-- Track speed limits per line section, shared by Kampfmoehre's mods.
--
-- A vehicle's MOVE_PATH holds exactly the section it is driving: from the
-- previous stop to the stop with index TransportVehicle.stopIndex (measured
-- 2026-10-16: replaced on departure, identical for all vehicles of a line;
-- at a terminal it is only the short path inside the station). Each path edge
-- points into a TRANSPORT_NETWORK component whose edge has speedLimit and
-- curveSpeedLimit (both m/s; curve ~770 km/h on straight track).
--
-- The collector reads a section once and refreshes it after MAX_AGE. Per step
-- it reads until TIME_BUDGET is used up (at least one, at most
-- MAX_SECTIONS_PER_STEP sections): most sections cost 0.2-4 ms, one long
-- section (400+ edges) up to ~40 ms. Lines with an open window (want()) go
-- first; opening a window (a want() after a pause) re-reads its line once, so
-- a track upgrade shows without waiting MAX_AGE. Lines without vehicles have
-- no data.
--
-- Shared instance: Top Speed Reached and Line Rate Preview each ship a copy of
-- this file and use the collector stored as field SHARED_KEY of the builtin
-- module table, which all GUI scripts share (rawget/rawset do not exist in the
-- GUI Lua state, and assigning a global logs an error); the highest
-- API_VERSION wins. step() throttles itself, so calls from both mods read
-- every section only once. Keep the interface (new/step/want/lineTrackMax/
-- section/reset/API_VERSION) backwards compatible.
--
-- No game API at require time, so the module can be unit-tested with plain
-- luajit (see test/track_limits_test.lua).
local M = {}

M.API_VERSION = 2          -- 2: want() after a pause re-reads the line
M.SHARED_KEY = "kampfmoehre_track_limits"
M.STEP_INTERVAL = 1.5        -- seconds (os.time resolution); callers step about every 2 s
M.MAX_SECTIONS_PER_STEP = 4
M.TIME_BUDGET = 0.003        -- seconds of reading per step
M.MAX_AGE = 300              -- seconds until a section is read again
M.WANT_SECONDS = 5           -- a want() keeps its line prioritised this long
M.MIN_RUN = 200              -- metres a limit must hold contiguously to count (runLimit)
M.LOG_READS = false          -- debugging: log one line per section read

-- edges = { { limit = m/s, curve = m/s, length = m }, ... }
-- edges in path order -> { length = m, maxLimit = m/s, runLimit = m/s,
--    byLimit = { [km/h] = m }, edges = n } with
--    maxLimit = max over min(limit, curve) of all edges,
--    runLimit = highest v with a contiguous stretch of at least
--               min(MIN_RUN, length / 2) metres on which every edge allows >= v
--               (short crossings at 40 in a 20 km/h avenue do not count),
--    byLimit  = metres per effective limit, for diagnostics
function M.summarize(edges)
	if type(edges) ~= "table" or #edges == 0 then return nil end
	local length, maxLimit, byLimit, eff, values = 0, nil, {}, {}, {}
	for i, e in ipairs(edges) do
		local len = e.length or 0
		length = length + len
		local v = e.limit
		if e.curve and e.curve > 0 and (v == nil or e.curve < v) then v = e.curve end
		eff[i] = v or false
		if v then
			if maxLimit == nil or v > maxLimit then maxLimit = v end
			local kmh = math.floor(v * 3.6 + 0.5)
			byLimit[kmh] = (byLimit[kmh] or 0) + len
			values[v] = true
		end
	end
	if maxLimit == nil then return nil end
	local candidates = {}
	for v in pairs(values) do candidates[#candidates + 1] = v end
	table.sort(candidates, function(a, b) return a > b end)
	local need = math.min(M.MIN_RUN, length / 2)
	local runLimit = nil
	for __, v in ipairs(candidates) do
		local run = 0
		for i, e in ipairs(edges) do
			if eff[i] and eff[i] >= v then
				run = run + (e.length or 0)
				if run >= need then break end
			else
				run = 0
			end
		end
		if run >= need then
			runLimit = v
			break
		end
	end
	return { length = length, maxLimit = maxLimit, runLimit = runLimit or maxLimit, byLimit = byLimit, edges = #edges }
end

local Collector = {}
Collector.__index = Collector

-- adapter = { vehicleSection(v) -> enRoute, stopIndex; pathEdges(v) -> edges;
--             lineStopCount(line) -> n; clock() -> s (default os.clock);
--             log(msg), logRead(line, stopIndex, summary, seconds) optional }
function M.new(adapter)
	local c = setmetatable({ adapter = adapter, API_VERSION = M.API_VERSION }, Collector)
	c:reset()
	return c
end

function Collector:reset()
	self.lines = {}   -- line -> { stops = n, staleBefore = t?, sections = { [stopIndex] = { length, maxLimit, at } } }
	self.lastStep = nil
	self.warned = {}
	self.wanted = {}  -- line -> time of the last want()
end

-- a window shows this line: read its sections first for WANT_SECONDS. A want
-- after a pause (the window was just opened) also marks the line's known
-- sections stale; their old values stay visible until they are re-read.
function Collector:want(line, now)
	if not line then return end
	local last = self.wanted[line]
	if last == nil or now - last > M.WANT_SECONDS then
		local L = self.lines[line]
		if L then L.staleBefore = now end
	end
	self.wanted[line] = now
end

function Collector:call(name, ...)
	local ok, a, b = pcall(self.adapter[name], ...)
	if ok then return a, b end
	if not self.warned[name] then
		self.warned[name] = true
		if self.adapter.log then self.adapter.log(name .. " failed: " .. tostring(a)) end
	end
	return nil
end

-- section s of line L must be read again: too old, or read before the line's
-- window was opened
local function stale(L, s, now)
	return now - s.at >= M.MAX_AGE or (L.staleBefore ~= nil and s.at < L.staleBefore)
end

-- true if every section of the line is known and fresh
local function complete(L, now)
	if not L or not L.stops then return false end
	local n = 0
	for __, s in pairs(L.sections) do
		if stale(L, s, now) then return false end
		n = n + 1
	end
	return n >= L.stops
end

-- vehicles = list of entities, vehicleLine = vehicle -> line, now = seconds
function Collector:step(vehicles, vehicleLine, now)
	if self.lastStep and now - self.lastStep < M.STEP_INTERVAL then return end
	self.lastStep = now
	-- forget lines that have no vehicles any more
	local active = {}
	for __, line in pairs(vehicleLine) do active[line] = true end
	for line in pairs(self.lines) do
		if not active[line] then self.lines[line] = nil end
	end
	for line, at in pairs(self.wanted) do
		if now - at > M.WANT_SECONDS then self.wanted[line] = nil end
	end
	local clock = self.adapter.clock or os.clock
	local started, reads, tried, done = clock(), 0, {}, {}
	local function visit(v)
		local line = vehicleLine[v]
		if not line or done[line] then return false end
		local L = self.lines[line]
		if complete(L, now) then
			done[line] = true
			return false
		end
		local enRoute, idx = self:call("vehicleSection", v)
		local key = tostring(line) .. "|" .. tostring(idx)
		local s = L and L.sections[idx]
		if not (enRoute and idx and not tried[key] and (s == nil or stale(L, s, now))) then return false end
		tried[key] = true
		local t0 = clock()
		local sum = M.summarize(self:call("pathEdges", v))
		if sum then
			local stops = self:call("lineStopCount", line)
			if not L or L.stops ~= stops then
				L = { stops = stops, sections = {} }
				self.lines[line] = L
			end
			sum.at = now
			L.sections[idx] = sum
			if self.adapter.logRead then pcall(self.adapter.logRead, line, idx, sum, clock() - t0) end
		end
		reads = reads + 1
		return reads >= M.MAX_SECTIONS_PER_STEP or clock() - started >= M.TIME_BUDGET
	end
	-- vehicles of wanted lines first, then all
	if next(self.wanted) then
		for __, v in ipairs(vehicles) do
			local line = vehicleLine[v]
			if line and self.wanted[line] and visit(v) then return end
		end
	end
	for __, v in ipairs(vehicles) do
		if visit(v) then return end
	end
end

-- -> highest track speed limit (m/s, runLimit: holds for MIN_RUN at a stretch)
--    over the known sections, number of known sections, number of stops
--    (= sections); nil if nothing is known
function Collector:lineTrackMax(line)
	local L = self.lines[line]
	if not L then return nil end
	local max, known = nil, 0
	for __, s in pairs(L.sections) do
		known = known + 1
		local v = s.runLimit or s.maxLimit
		if max == nil or v > max then max = v end
	end
	if max == nil then return nil end
	return max, known, L.stops
end

-- section ending at stop `stopIndex` (0-based): { length = m, maxLimit = m/s, at } or nil
function Collector:section(line, stopIndex)
	local L = self.lines[line]
	return L and L.sections[stopIndex] or nil
end

-- Engine access. MOVE_PATH entries are not {EdgeId, bool} as the tealdef says
-- (index 1 is nil), hence the field fallbacks.
local function edgeIdOf(e)
	local id = e[1] or e.edgeId or e.first or e.edge
	if id ~= nil and id.entity == nil and id.edgeId ~= nil then id = id.edgeId end
	return id
end

-- owner = log prefix of the mod whose copy runs, e.g. "kampfmoehre_top_speed";
-- lines read "[kampfmoehre_track_limits@kampfmoehre_top_speed] ..."
function M.engineAdapter(owner)
	local prefix = "[kampfmoehre_track_limits@" .. tostring(owner or "?") .. "] "
	local CT = api.type.ComponentType
	local EN_ROUTE = api.type.enum.TransportVehicleState.EN_ROUTE
	-- wall clock in microseconds; os.clock is the CPU time of all game threads
	-- and overstates the cost several times
	local wall = api.type.Clock.new()
	-- getComponent throws "Invalid entity" for vehicles/lines removed since the
	-- caller's list was built (sold, replaced): treat that as "no data"
	local function component(entity, ct)
		local ok, c = pcall(api.engine.getComponent, entity, ct)
		if ok then return c end
		return nil
	end
	return {
		vehicleSection = function(v)
			local tv = component(v, CT.TRANSPORT_VEHICLE)
			if not tv then return nil end
			return tv.state == EN_ROUTE, tv.stopIndex
		end,
		pathEdges = function(v)
			local mp = component(v, CT.MOVE_PATH)
			if not mp or not mp.path then return nil end
			local out, networks = {}, {}
			for __, e in ipairs(mp.path.edges) do
				local id = edgeIdOf(e)
				if id == nil then error("path entry without EdgeId") end
				local tn = networks[id.entity]
				if tn == nil then
					tn = component(id.entity, CT.TRANSPORT_NETWORK) or false
					networks[id.entity] = tn
				end
				local edge = tn and tn.edges[id.index + 1]
				if edge then
					out[#out + 1] = {
						limit = edge.speedLimit,
						curve = edge.curveSpeedLimit,
						length = edge.geometry and edge.geometry.length or 0,
					}
				end
			end
			return out
		end,
		lineStopCount = function(line)
			local l = component(line, CT.LINE)
			return l and #l.stops or nil
		end,
		clock = function() return wall:getTime() / 1e6 end,
		log = function(msg) log.warning(prefix .. msg) end,
		logRead = M.LOG_READS and function(line, stopIndex, sum, seconds)
			local kmhs = {}
			for kmh in pairs(sum.byLimit) do kmhs[#kmhs + 1] = kmh end
			table.sort(kmhs, function(a, b) return sum.byLimit[a] > sum.byLimit[b] end)
			local parts = {}
			for i = 1, math.min(6, #kmhs) do
				parts[i] = string.format("%d km/h:%.0f m", kmhs[i], sum.byLimit[kmhs[i]])
			end
			log.message(prefix .. string.format("line %s stop %s: %d edges, %.0f m, run %.0f km/h, max %.0f km/h, %.2f ms | %s",
				tostring(line), tostring(stopIndex), sum.edges, sum.length, sum.runLimit * 3.6, sum.maxLimit * 3.6, seconds * 1000,
				table.concat(parts, ", ")))
		end or nil,
	}
end

-- The collector shared by all mods in this GUI state; holder = a table every
-- mod gets the same instance of (the builtin module); owner = log prefix of
-- the calling mod, kept by the collector it creates (shows whose copy runs).
function M.getShared(holder, makeAdapter, owner)
	local s = holder[M.SHARED_KEY]
	if s == nil or (s.API_VERSION or 0) < M.API_VERSION then
		s = M.new(makeAdapter(owner))
		s.owner = owner
		holder[M.SHARED_KEY] = s
	end
	return s
end

return M
