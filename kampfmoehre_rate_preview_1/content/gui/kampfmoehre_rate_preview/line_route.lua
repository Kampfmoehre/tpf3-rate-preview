-- Real track route of a line between its stops, from the game's pathfinder
-- (api.engine.util.pathfinding.findPathNodeToNode, terminal node -> terminal
-- node). Unlike track_limits it needs no vehicle on the line, so the rough
-- estimate and the speed row of an empty line get real lengths, speed limits
-- and heights.
--
-- The cache reads one section per visit inside a time budget per step (the
-- caller steps every 2 s), wanted lines (store open) first. A line is read
-- again after MAX_AGE, or when it is wanted after a pause (the store was just
-- opened, stops may have changed); its old route stays visible until the new
-- read is complete. Section i runs from stop i to stop i % n + 1 (closed round
-- trip), the order of rate_preview's lineSectionsWithTrack.
--
-- No game API at require time, so the module can be unit-tested with plain
-- luajit (see test/line_route_test.lua).
local M = {}

M.MAX_AGE = 300              -- seconds until a line is read again
M.TIME_BUDGET = 0.003        -- seconds of reading per step
M.MAX_SECTIONS_PER_STEP = 4
M.WANT_SECONDS = 5           -- a want() keeps its line prioritised this long

-- transport modes for findPathNodeToNode per carrier name and cargo kind
-- ("pax" | "cargo" | "any"), from the route probe (docs/probes/route_probe/):
-- rail without ELECTRIC_TRAIN (same path, 3x cheaper; catenary is checked
-- per edge), road by kind (buses may use bus lanes), no network for aircraft.
-- Ships are left out until their cost is probed (unusual searches took up to
-- 16 ms; they keep the straight line). Wrong modes are expensive (a tram line
-- with bus modes: 14 ms detours).
M.MODES = {
	RAIL = { any = { "TRAIN" } },
	ROAD = { pax = { "BUS" }, cargo = { "TRUCK" } },
	TRAM = { any = { "TRAM", "ELECTRIC_TRAM" } },
}

-- mode names for a carrier name and kind, or nil (no route for that carrier)
function M.modesFor(carrierName, kind)
	local byKind = M.MODES[carrierName]
	if not byKind then return nil end
	return byKind[kind or "any"] or byKind.any or byKind.cargo
end

local Cache = {}
Cache.__index = Cache

-- adapter = { lineStops(line) -> { { node = NodeId or nil, key = string, waypoints = bool }, ... }, modes
--               (modes nil = no route for this line; a stop with waypoints keeps
--               the straight line for its outgoing section, the pathfinder would
--               ignore them),
--             path(fromNode, toNode, modes) -> edges or nil, reason,
--             clock() -> s, log(msg), complete(line, entry) optional (a read finished) }
-- summarize = edges -> section summary or nil (track_limits.summarize)
function M.new(adapter, summarize)
	local c = setmetatable({ adapter = adapter, summarize = summarize }, Cache)
	c:reset()
	return c
end

function Cache:reset()
	self.entries = {}  -- line -> last complete read { at, n, sections = { [i] = summary or false }, length } or { none = true, at }
	self.pending = {}  -- line -> read in progress { at, n, stops, modes, sections, nextIdx }
	self.wanted = {}   -- line -> time of the last want()
	self.stale = {}    -- line -> true: wanted after a pause, read again
end

-- the line's stops changed (a consumer saw another section count): drop a
-- read in progress and read the line again at the next step
function Cache:invalidate(line)
	if line == nil then return end
	self.pending[line] = nil
	self.stale[line] = true
end

-- the store shows this line: read it first for WANT_SECONDS; a want after a
-- pause reads the line again
function Cache:want(line, now)
	if line == nil then return end
	local last = self.wanted[line]
	if last == nil or now - last > M.WANT_SECONDS then self.stale[line] = true end
	self.wanted[line] = now
end

-- read in progress for the line, a new one if the line is due, or nil
function Cache:startOrContinue(line, now)
	local p = self.pending[line]
	if p then return p end
	local e = self.entries[line]
	if e and now - e.at < M.MAX_AGE and not self.stale[line] then return nil end
	self.stale[line] = nil
	local ok, stops, modes = pcall(self.adapter.lineStops, line)
	if not ok or type(stops) ~= "table" or #stops < 2 or modes == nil then
		self.entries[line] = { none = true, at = now }
		return nil
	end
	p = { at = now, n = #stops, stops = stops, modes = modes, sections = {}, nextIdx = 1 }
	self.pending[line] = p
	return p
end

function Cache:readOne(line, p)
	local clock = self.adapter.clock or os.clock
	local t0 = clock()
	local i = p.nextIdx
	local a, b = p.stops[i], p.stops[i % p.n + 1]
	local sum, why = nil, "no terminal node"
	if a.waypoints then
		why = "waypoints"
	elseif a.node ~= nil and b.node ~= nil then
		local ok, edges, reason = pcall(self.adapter.path, a.node, b.node, p.modes)
		if ok and edges then
			sum = self.summarize(edges)
			why = "no readable edges"
		else
			why = ok and tostring(reason or "no path") or ("path failed: " .. tostring(edges))
		end
	end
	p.sections[i] = sum or false
	local ms = (clock() - t0) * 1000
	p.ms = (p.ms or 0) + ms
	if ms > (p.maxMs or 0) then p.maxMs = ms end
	if not sum and not p.logged then
		p.logged = true
		if self.adapter.log then pcall(self.adapter.log, "line " .. tostring(line) .. " section " .. i .. ": " .. why) end
	end
	p.nextIdx = i + 1
	if p.nextIdx > p.n then
		local length = 0
		for k = 1, p.n do
			local s = p.sections[k]
			if not s then length = nil break end
			length = length + (s.length or 0)
		end
		self.entries[line] = { at = p.at, n = p.n, sections = p.sections, length = length, ms = p.ms, maxMs = p.maxMs }
		self.pending[line] = nil
		if self.adapter.complete then pcall(self.adapter.complete, line, self.entries[line]) end
	end
end

-- lines = player lines to keep routes for (wanted lines are kept as well)
function Cache:step(lines, now)
	local keep = {}
	for __, line in ipairs(lines or {}) do keep[line] = true end
	for line, at in pairs(self.wanted) do
		if now - at > M.WANT_SECONDS then self.wanted[line] = nil else keep[line] = true end
	end
	for line in pairs(self.entries) do if not keep[line] then self.entries[line] = nil end end
	for line in pairs(self.pending) do if not keep[line] then self.pending[line] = nil end end
	for line in pairs(self.stale) do if not keep[line] then self.stale[line] = nil end end

	local clock = self.adapter.clock or os.clock
	local started, reads = clock(), 0
	-- true when the budget is used up
	local function work(line)
		while true do
			local p = self:startOrContinue(line, now)
			if not p then return false end
			self:readOne(line, p)
			reads = reads + 1
			if reads >= M.MAX_SECTIONS_PER_STEP or clock() - started >= M.TIME_BUDGET then return true end
		end
	end
	for line in pairs(self.wanted) do
		if work(line) then return end
	end
	for __, line in ipairs(lines or {}) do
		if work(line) then return end
	end
end

-- -> { at, n = sections, sections = { [i] = summary or false }, length = m or nil
--      (nil unless every section has a route), ms / maxMs = read time } or nil; during the first read
--    the partial result (sections read so far)
function Cache:route(line)
	local e = self.entries[line]
	if e and not e.none then return e end
	local p = self.pending[line]
	if p and not (e and e.none) then return p end
	return nil
end

return M
