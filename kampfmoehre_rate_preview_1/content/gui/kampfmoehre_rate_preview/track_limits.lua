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
-- no data. Each section also keeps its height profile (edge
-- geometry.height, resampled every 10 m in travel direction) for the
-- gradient simulation in Line Rate Preview, and the metres of rails without
-- catenary (edge transportModes) for its "no catenary" warning.
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

M.API_VERSION = 3          -- 2: want() after a pause re-reads the line; 3: section().profile
M.SHARED_KEY = "kampfmoehre_track_limits"
M.STEP_INTERVAL = 1.5        -- seconds (os.time resolution); callers step about every 2 s
M.MAX_SECTIONS_PER_STEP = 4
M.TIME_BUDGET = 0.003        -- seconds of reading per step
M.MAX_AGE = 300              -- seconds until a section is read again
M.WANT_SECONDS = 5           -- a want() keeps its line prioritised this long
M.MIN_RUN = 200              -- metres a limit must hold contiguously to count (runLimit)
M.LOG_READS = false          -- debugging: log one line per section read (+ heights, probes of open windows)

-- edges = { { limit = m/s, curve = m/s, length = m, h0, h1, fwd, noCatenary }, ... }
-- edges in path order -> { length = m, maxLimit = m/s, runLimit = m/s,
--    byLimit = { [km/h] = m }, edges = n, profile = resampleProfile(edges),
--    unelectrified = m of noCatenary edges, unelectrifiedAt = m to the first or nil } with
--    maxLimit = max over min(limit, curve) of all edges,
--    runLimit = highest v with a contiguous stretch of at least
--               min(MIN_RUN, length / 2) metres on which every edge allows >= v
--               (short crossings at 40 in a 20 km/h avenue do not count),
--    byLimit  = metres per effective limit, for diagnostics
function M.summarize(edges)
	if type(edges) ~= "table" or #edges == 0 then return nil end
	local length, maxLimit, byLimit, eff, values = 0, nil, {}, {}, {}
	local unelectrified, unelectrifiedAt = 0, nil
	for i, e in ipairs(edges) do
		local len = e.length or 0
		if e.noCatenary then
			if unelectrifiedAt == nil then unelectrifiedAt = length end
			unelectrified = unelectrified + len
		end
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
	return { length = length, maxLimit = maxLimit, runLimit = runLimit or maxLimit, byLimit = byLimit, edges = #edges,
		profile = M.resampleProfile(edges, M.PROFILE_RESAMPLE_STEP),
		unelectrified = unelectrified, unelectrifiedAt = unelectrifiedAt }
end

-- Heights along a path. edges = { { length = m, h0 = m, h1 = m, fwd = bool? }, ... }
-- in path order; h0/h1 = geometry heights at the edge's start/end, fwd = path
-- direction (MOVE_PATH entry .dir; false = driven from h1 to h0). Without fwd
-- the direction follows from height continuity with the neighbouring edge.
-- -> D, H, n: cumulative distance and height at the edge boundaries 0..n
--    (travel direction), a, b = oriented start/end height per edge; nil
--    without heights
local function orientedPath(edges)
	if type(edges) ~= "table" or #edges == 0 then return nil end
	local n = #edges
	local a, b = {}, {}
	for i, e in ipairs(edges) do
		if e.h0 == nil or e.h1 == nil then return nil end
		a[i], b[i] = e.h0, e.h1
		if e.fwd == false then a[i], b[i] = e.h1, e.h0 end
	end
	-- unknown direction: start where the previous edge ended (the first edge
	-- where the next one starts)
	local function flip(i) a[i], b[i] = b[i], a[i] end
	for i = 1, n do
		if edges[i].fwd == nil then
			if i > 1 then
				if math.abs(b[i] - b[i - 1]) < math.abs(a[i] - b[i - 1]) then flip(i) end
			elseif n > 1 then
				local da = math.min(math.abs(a[i] - edges[2].h0), math.abs(a[i] - edges[2].h1))
				local db = math.min(math.abs(b[i] - edges[2].h0), math.abs(b[i] - edges[2].h1))
				if da < db then flip(i) end
			end
		end
	end
	local D, H = { [0] = 0 }, { [0] = a[1] }
	for i = 1, n do
		D[i] = D[i - 1] + (edges[i].length or 0)
		H[i] = H[i - 1] + (b[i] - a[i])
	end
	return D, H, n, a, b
end

-- heights at 0, step, 2 step, ... up to the path length (linear per edge)
local function sampleHeights(D, H, n, step)
	local heights, k = {}, 0
	for x = 0, D[n] + 1e-6, step do
		while k < n - 1 and D[k + 1] < x do k = k + 1 end
		local len = D[k + 1] - D[k]
		local t = len > 0 and (x - D[k]) / len or 0
		heights[#heights + 1] = H[k] + (H[k + 1] - H[k]) * math.max(0, math.min(1, t))
	end
	return heights
end

-- Height profile for the gradient simulation (rate_model.climbOnSection):
-- edges as above -> { step = m, h = { h(0), h(step), ... } } in travel
-- direction, nil without heights
M.PROFILE_RESAMPLE_STEP = 10

function M.resampleProfile(edges, step)
	local D, H, n = orientedPath(edges)
	if not D or D[n] <= 0 then return nil end
	step = step or M.PROFILE_RESAMPLE_STEP
	return { step = step, h = sampleHeights(D, H, n, step) }
end

-- Diagnostics (LOG_READS): edges as above
-- -> { length, startH, endH, rise, fall, gaps = joints off by > 0.5 m,
--      windows = { [w] = { up = grade, upAt = m, down = grade, downAt = m } }
--      (steepest mean grade over any stretch >= w metres, +up / -down,
--      at = start of that stretch from the section start),
--      heights = { h at 0, PROFILE_STEP, ... } }, nil without heights
M.GRADE_WINDOWS = { 200, 1000 }
M.PROFILE_STEP = 250

function M.gradeProfile(edges)
	local D, H, n, a, b = orientedPath(edges)
	if not D then return nil end
	local rise, fall, gaps = 0, 0, 0
	for i = 1, n do
		if i > 1 and math.abs(a[i] - b[i - 1]) > 0.5 then gaps = gaps + 1 end
		local dh = b[i] - a[i]
		if dh > 0 then rise = rise + dh else fall = fall - dh end
	end
	local length = D[n]
	local windows = {}
	for __, w in ipairs(M.GRADE_WINDOWS) do
		local need = math.min(w, length)
		local r = { up = nil, down = nil }
		local j = 0
		for i = 0, n - 1 do
			if j <= i then j = i + 1 end
			while j < n and D[j] - D[i] < need do j = j + 1 end
			local d = D[j] - D[i]
			if d >= need and d > 0 then
				local g = (H[j] - H[i]) / d
				if r.up == nil or g > r.up then r.up, r.upAt = g, D[i] end
				if r.down == nil or g < r.down then r.down, r.downAt = g, D[i] end
			end
		end
		windows[w] = r
	end
	return { length = length, startH = H[0], endH = H[n], rise = rise, fall = fall, gaps = gaps,
		windows = windows, heights = sampleHeights(D, H, n, M.PROFILE_STEP) }
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
	-- debugging (LOG_READS): speed and gradient of the vehicles of open windows
	if self.adapter.probe and next(self.wanted) then
		local probed = 0
		for __, v in ipairs(vehicles) do
			local line = vehicleLine[v]
			if line and self.wanted[line] and probed < 4 then
				probed = probed + 1
				pcall(self.adapter.probe, v, line)
			end
		end
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
		local edges = self:call("pathEdges", v)
		local sum = M.summarize(edges)
		if sum and M.LOG_READS then sum.diag = M.gradeProfile(edges) end
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

-- section ending at stop `stopIndex` (0-based): { length = m, maxLimit = m/s,
--    runLimit = m/s, profile = { step, h } or nil, unelectrified = m,
--    unelectrifiedAt = m or nil, at } or nil
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
	local keysLogged = false
	local consistLogged = {}
	-- path entry -> TRANSPORT_NETWORK edge table (or nil), direction flag (or nil)
	local function networkEdge(e, networks)
		local id = edgeIdOf(e)
		if id == nil then error("path entry without EdgeId") end
		local tn = networks[id.entity]
		if tn == nil then
			tn = component(id.entity, CT.TRANSPORT_NETWORK) or false
			networks[id.entity] = tn
		end
		local fwd = e[2]
		if type(fwd) ~= "boolean" then fwd = e.dir end
		if type(fwd) ~= "boolean" then fwd = e.forward end
		if type(fwd) ~= "boolean" then fwd = e.second end
		if type(fwd) ~= "boolean" then fwd = nil end
		return tn and tn.edges[id.index + 1] or nil, fwd
	end
	local function heightsOf(edge)
		local h = edge.geometry and edge.geometry.height
		if not h then return nil end
		return h.x or h[1], h.y or h[2]
	end
	-- rails without their electric variant (TRAIN without ELECTRIC_TRAIN, TRAM
	-- without ELECTRIC_TRAM, TRAM_TRACK without ELECTRIC_TRAM_TRACK); streets
	-- without tram rails do not count
	local TM = api.type.enum.TransportMode
	local railPairs = {
		{ TM.TRAIN, TM.ELECTRIC_TRAIN },
		{ TM.TRAM, TM.ELECTRIC_TRAM },
		{ TM.TRAM_TRACK, TM.ELECTRIC_TRAM_TRACK },
	}
	local function allows(modes, m)
		local v = modes[m]
		return v == true or v == 1
	end
	local function lacksCatenary(edge)
		local modes = edge.transportModes
		if type(modes) ~= "table" and type(modes) ~= "userdata" then return false end
		for __, pr in ipairs(railPairs) do
			if allows(modes, pr[1]) and not allows(modes, pr[2]) then return true end
		end
		return false
	end
	local function edgeEntry(edge, fwd)
		local h0, h1 = heightsOf(edge)
		local okC, noCat = pcall(lacksCatenary, edge)
		return {
			limit = edge.speedLimit,
			curve = edge.curveSpeedLimit,
			length = edge.geometry and edge.geometry.length or 0,
			h0 = h0, h1 = h1, fwd = fwd,
			noCatenary = okC and noCat or false,
		}
	end
	local function logEntryKeys(e, edge)
		if keysLogged or not M.LOG_READS then return end
		keysLogged = true
		local keys = {}
		if type(e) == "table" then
			for k, val in pairs(e) do keys[#keys + 1] = tostring(k) .. "=" .. tostring(val) end
		else
			keys[1] = type(e) .. " " .. tostring(e)
			for __, k in ipairs({ "edgeId", "first", "second", "dir", "forward", "edge" }) do
				local ok, val = pcall(function() return e[k] end)
				if ok and val ~= nil then keys[#keys + 1] = k .. "=" .. tostring(val) end
			end
		end
		local h = edge and edge.geometry and edge.geometry.height
		local hk = {}
		if type(h) == "table" then for k, val in pairs(h) do hk[#hk + 1] = tostring(k) .. "=" .. tostring(val) end end
		local z0 = "?"
		if edge and edge.geometry then
			local ok, p = pcall(api.engine.util.transport.calcPosition, edge.geometry, 0)
			if ok and p then z0 = tostring(p.z) end
		end
		log.message(prefix .. "path entry {" .. table.concat(keys, ", ") .. "} height {" .. table.concat(hk, ", ")
			.. "} (" .. type(h) .. ") calcPosition(0).z=" .. z0)
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
				local edge, fwd = networkEdge(e, networks)
				logEntryKeys(e, edge)
				if edge then out[#out + 1] = edgeEntry(edge, fwd) end
			end
			return out
		end,
		-- debugging: one line per call with speed and the gradient under the vehicle
		probe = M.LOG_READS and function(v, line)
			local mp = component(v, CT.MOVE_PATH)
			if not mp or not mp.path or not mp.dyn then return end
			local tv = component(v, CT.TRANSPORT_VEHICLE)
			if tv and not consistLogged[v] then
				consistLogged[v] = true
				local ok, err = pcall(function()
					local vsu = ug_require "::/gui/line_vehicle_mgmt/vehicle_store_util.tl"
					local vehicles = vsu.makeMultipleVehiclesFromParts({ tv.transportVehicleConfig.vehicles })
					local d = vsu.collectVehicleData(vehicles, tv.modifiers)
					local sim = "?"
					pcall(function() sim = tostring(api.res.getBaseConfig().simulateCargoWeight) end)
					log.message(prefix .. string.format("probe veh %s consist: %d parts, empty %.1f t, max payload %.1f t, power %.0f kW, tractive %.0f kN, friction %.3f, top %.1f km/h, simulateCargoWeight=%s",
						tostring(v), #tv.transportVehicleConfig.vehicles, d.weight, d.weightMaxPayload, d.power, d.tractiveEffort,
						d.rollingFriction or -1, (d.speed or 0) * 3.6, sim))
				end)
				if not ok then log.message(prefix .. "probe consist failed: " .. tostring(err)) end
			end
			local idx = mp.dyn.pathPos.edgeIndex -- 0-based
			local n = #mp.path.edges
			-- edges up to ~300 m behind the front and the current one
			local networks, list, cur = {}, {}, nil
			local back = 0
			for i = idx + 1, 1, -1 do
				local edge, fwd = networkEdge(mp.path.edges[i], networks)
				if not edge then break end
				local entry = edgeEntry(edge, fwd)
				table.insert(list, 1, entry)
				if i == idx + 1 then cur = entry end
				back = back + entry.length
				if back >= 300 then break end
			end
			local nextEdge = mp.path.edges[idx + 2]
			if nextEdge then
				local edge, fwd = networkEdge(nextEdge, networks)
				if edge then list[#list + 1] = edgeEntry(edge, fwd) end
			end
			local p = M.gradeProfile(list)
			local curGrade = "?"
			if cur and cur.h0 and cur.length > 0 then
				local dh = cur.h1 - cur.h0
				if cur.fwd == false then dh = -dh end
				curGrade = string.format("%+.2f%%%s", 100 * dh / cur.length, cur.fwd == nil and "(dir?)" or "")
			end
			local back300 = "?"
			if p and p.length > 0 then back300 = string.format("%+.2f%%", 100 * (p.endH - p.startH) / p.length) end
			log.message(prefix .. string.format("probe line %s veh %s stop %s edge %d/%d pos %.0f m: speed %.1f km/h, accel %+.4f, edge %s, last %.0f m %s, h %.1f m",
				tostring(line), tostring(v), tostring(tv and tv.stopIndex), idx + 1, n, mp.dyn.pathPos.pos or -1,
				(mp.dyn.speed or 0) * 3.6, mp.dyn.accel or 0, curGrade, p and p.length or 0, back300, cur and cur.h1 or -1))
		end or nil,
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
			local p = sum.diag
			if p then
				local ws = {}
				for __, w in ipairs(M.GRADE_WINDOWS) do
					local r = p.windows[w]
					if r and r.up then
						ws[#ws + 1] = string.format("%d m: up %+.2f%% @%.0f, down %+.2f%% @%.0f", w, 100 * r.up, r.upAt, 100 * r.down, r.downAt)
					end
				end
				local hs = {}
				for i, h in ipairs(p.heights) do hs[i] = string.format("%.0f", h) end
				log.message(prefix .. string.format("line %s stop %s heights: %.1f -> %.1f m, rise %.1f, fall %.1f, gaps %d | %s | every %d m: %s",
					tostring(line), tostring(stopIndex), p.startH, p.endH, p.rise, p.fall, p.gaps, table.concat(ws, "; "),
					M.PROFILE_STEP, table.concat(hs, " ")))
			end
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
