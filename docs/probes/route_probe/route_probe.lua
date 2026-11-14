-- TEMPORARY probe (plan 2026-11-13-route-and-physics, Task 1): does
-- api.engine.util.pathfinding.findPathNodeToNode give the track between two
-- stops of a line, with which transport modes per carrier, at what cost, and
-- does its length match the section the line's vehicles drive?
-- Runs once, START_STEPS ticks after load, one line per tick. Not shipped.
local M = {}

M.START_STEPS = 15   -- ticks of 2 s before the first line (let the game settle)
M.MAX_LINES = 20

local MODE_SETS = {
	{ "RAIL", { "TRAIN", "ELECTRIC_TRAIN" } },
	{ "RAIL", { "TRAIN" } },
	{ "ROAD", { "BUS" } },
	{ "ROAD", { "TRUCK" } },
	{ "ROAD", { "CAR" } },
	{ "TRAM", { "TRAM", "ELECTRIC_TRAM" } },
	{ "WATER", { "SHIP", "SMALL_SHIP" } },
	{ "AIR", { "AIRCRAFT", "SMALL_AIRCRAFT", "HELICOPTER" } },
}
local CARRIERS = { "ROAD", "RAIL", "TRAM", "WATER", "AIR" }

local prefix = "[kampfmoehre_rate_preview] route probe "
local ticks, lines, nextLine, done = 0, nil, 1, false
local stats = {} -- "carrier|set" -> { ok, fail, ms = {}, ratioStraight = {}, ratioDriven = {} }
local entryLogged = false

local function comp(entity, ct)
	local ok, c = pcall(api.engine.getComponent, entity, ct)
	return ok and c or nil
end

local function center(entity)
	local bv = comp(entity, api.type.ComponentType.BOUNDING_VOLUME)
	if not (bv and bv.bbox) then return nil end
	local mn, mx = bv.bbox.min, bv.bbox.max
	return { x = (mn.x + mx.x) / 2, y = (mn.y + mx.y) / 2, z = (mn.z + mx.z) / 2 }
end

local function dist(a, b)
	if not (a and b) then return nil end
	return math.sqrt((a.x - b.x) ^ 2 + (a.y - b.y) ^ 2 + (a.z - b.z) ^ 2)
end

-- stop -> station entity, terminal vehicle node
local function stopNode(stop)
	local CT = api.type.ComponentType
	local sg = comp(stop.stationGroup, CT.STATION_GROUP)
	local station = sg and sg.stations and sg.stations[stop.station + 1]
	if not station then return nil, nil, "no station" end
	local st = comp(station, CT.STATION)
	local term = st and st.terminals and st.terminals[stop.terminal + 1]
	if not term then return station, nil, "no terminal" end
	return station, term.vehicleNodeId, nil
end

local function describe(e)
	local parts = { type(e) }
	for __, k in ipairs({ 1, 2, "edgeId", "dir", "first", "second" }) do
		local ok, v = pcall(function() return e[k] end)
		if ok and v ~= nil then parts[#parts + 1] = tostring(k) .. "=" .. tostring(v) end
	end
	return table.concat(parts, " ")
end

local function pathMetres(path)
	local n, metres, networks = 0, 0, {}
	for __, e in ipairs(path) do
		n = n + 1
		local id = e[1] or e.edgeId or e.first
		if id ~= nil and id.entity == nil and id.edgeId ~= nil then id = id.edgeId end
		if id ~= nil then
			local tn = networks[id.entity]
			if tn == nil then
				tn = comp(id.entity, api.type.ComponentType.TRANSPORT_NETWORK) or false
				networks[id.entity] = tn
			end
			local edge = tn and tn.edges[id.index + 1]
			if edge and edge.geometry then metres = metres + (edge.geometry.length or 0) end
		end
	end
	return n, metres
end

local function carrierName(c)
	for __, name in ipairs(CARRIERS) do
		local ok, v = pcall(function() return api.type.enum.Carrier[name] end)
		if ok and v ~= nil and tostring(v) == tostring(c) then return name end
	end
	return tostring(c)
end

local function stat(key)
	local s = stats[key]
	if not s then
		s = { ok = 0, fail = 0, ms = {}, rs = {}, rd = {} }
		stats[key] = s
	end
	return s
end

local function probeLine(line, tracks)
	local CT = api.type.ComponentType
	local lc = comp(line, CT.LINE)
	if not (lc and lc.stops and #lc.stops >= 2) then return end
	local carrier = "none"
	local okV, vs = pcall(api.engine.system.transportVehicleSystem.getLineVehicles, line)
	if okV and type(vs) == "table" and vs[1] then
		local tv = comp(vs[1], CT.TRANSPORT_VEHICLE)
		if tv then carrier = carrierName(tv.carrier) end
	end
	local n = #lc.stops
	local clock = api.type.Clock.new()
	for i = 1, n do
		local sA, nodeA, whyA = stopNode(lc.stops[i])
		local sB, nodeB, whyB = stopNode(lc.stops[i % n + 1])
		local straight = dist(center(sA), center(sB))
		local driven = nil
		if tracks then
			local ok, sec = pcall(tracks.section, tracks, line, i % n)
			if ok and sec then driven = sec.length end
		end
		local waypoints = lc.stops[i].waypoints and #lc.stops[i].waypoints or 0
		if not (nodeA and nodeB) then
			log.message(prefix .. string.format("line %s carrier %s section %d: no node (%s / %s)", tostring(line), carrier, i,
				tostring(whyA), tostring(whyB)))
		else
			for __, set in ipairs(MODE_SETS) do
				local modes = {}
				for __, name in ipairs(set[2]) do modes[#modes + 1] = api.type.enum.TransportMode[name] end
				local t0 = clock:getTime()
				local ok, path = pcall(api.engine.util.pathfinding.findPathNodeToNode, { nodeA }, { nodeB }, modes)
				local ms = (clock:getTime() - t0) / 1000
				local entries, metres = 0, 0
				if ok and path ~= nil then
					local okM, a, b = pcall(pathMetres, path)
					if okM then entries, metres = a, b end
					if not entryLogged and entries > 0 then
						entryLogged = true
						log.message(prefix .. "entry format: " .. describe(path[1]) .. " | result type " .. type(path))
					end
				end
				local key = carrier .. "|" .. set[1] .. ":" .. table.concat(set[2], "+")
				local s = stat(key)
				s.ms[#s.ms + 1] = ms
				if ok and entries > 0 then
					s.ok = s.ok + 1
					if straight and straight > 0 then s.rs[#s.rs + 1] = metres / straight end
					if driven and driven > 0 then s.rd[#s.rd + 1] = metres / driven end
				else
					s.fail = s.fail + 1
				end
				log.message(prefix .. string.format("line %s carrier %s section %d/%d modes %s:%s: %s, entries %d, metres %.0f, straight %s, driven %s, waypoints %d, %.2f ms",
					tostring(line), carrier, i, n, set[1], table.concat(set[2], "+"), ok and "ok" or ("err " .. tostring(path)),
					entries, metres, straight and string.format("%.0f", straight) or "-", driven and string.format("%.0f", driven) or "-",
					waypoints, ms))
			end
		end
	end
end

local function median(list)
	if #list == 0 then return nil end
	local c = {}
	for i, v in ipairs(list) do c[i] = v end
	table.sort(c)
	return c[math.floor((#c + 1) / 2)]
end

local function summary()
	local keys = {}
	for k in pairs(stats) do keys[#keys + 1] = k end
	table.sort(keys)
	for __, k in ipairs(keys) do
		local s = stats[k]
		local maxMs = 0
		for __, v in ipairs(s.ms) do if v > maxMs then maxMs = v end end
		local function f(v) return v and string.format("%.3f", v) or "-" end
		log.message(prefix .. string.format("summary %s: ok %d fail %d, ms median %s max %.2f, route/straight median %s, route/driven median %s (n %d)",
			k, s.ok, s.fail, f(median(s.ms)), maxMs, f(median(s.rs)), f(median(s.rd)), #s.rd))
	end
end

-- call every 2 s from the entry plugin's step timer
function M.tick(tracks)
	if done then return end
	ticks = ticks + 1
	if ticks < M.START_STEPS then return end
	if lines == nil then
		local enums = {}
		for __, name in ipairs(CARRIERS) do
			local ok, v = pcall(function() return api.type.enum.Carrier[name] end)
			enums[#enums + 1] = name .. "=" .. tostring(ok and v)
		end
		log.message(prefix .. "start, Carrier enum " .. table.concat(enums, " ") .. ", pathfinding "
			.. type(api.engine.util.pathfinding) .. ", findPathNodeToNode " .. type(api.engine.util.pathfinding and api.engine.util.pathfinding.findPathNodeToNode))
		local okP, player = pcall(api.engine.util.getPlayer)
		local okL, all = false, nil
		if okP then okL, all = pcall(api.engine.system.lineSystem.getLinesForPlayer, player) end
		lines = (okL and type(all) == "table") and all or {}
	end
	if nextLine > #lines or nextLine > M.MAX_LINES then
		done = true
		summary()
		log.message(prefix .. "done")
		return
	end
	local ok, err = pcall(probeLine, lines[nextLine], tracks)
	if not ok then log.message(prefix .. "line " .. tostring(lines[nextLine]) .. " failed: " .. tostring(err)) end
	nextLine = nextLine + 1
end

return M
