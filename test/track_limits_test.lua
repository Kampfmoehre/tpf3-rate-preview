-- run: luajit test/track_limits_test.lua  (from the repo root)
package.path = "kampfmoehre_rate_preview_1/content/gui/kampfmoehre_rate_preview/?.lua;" .. package.path
local M = require "track_limits"

local failures = 0
local function check(name, cond, detail)
	if cond then
		print("ok   " .. name)
	else
		failures = failures + 1
		print("FAIL " .. name .. (detail and (": " .. detail) or ""))
	end
end
local function near(name, got, want, tol)
	tol = tol or 0.01
	check(name, got ~= nil and math.abs(got - want) <= tol,
		string.format("got %s, want %s", tostring(got), tostring(want)))
end

-- summarize ---------------------------------------------------------------
local kmh = 1 / 3.6
local s = M.summarize({
	{ limit = 100 * kmh, curve = 770 * kmh, length = 1000 },
	{ limit = 100 * kmh, curve = 60 * kmh, length = 200 },
	{ limit = 80 * kmh, curve = 770 * kmh, length = 300 },
})
near("summarize length", s and s.length, 1500)
near("summarize max of min(limit, curve)", s and s.maxLimit, 100 * kmh)

s = M.summarize({ { limit = 100 * kmh, curve = 60 * kmh, length = 200 } })
near("curve limit caps the edge", s and s.maxLimit, 60 * kmh)

s = M.summarize({ { limit = 50 * kmh, curve = 0, length = 10 }, { limit = 40 * kmh, length = 10 } })
near("missing/zero curve limit is ignored", s and s.maxLimit, 50 * kmh)

-- runLimit: highest v with a contiguous stretch >= MIN_RUN where every edge allows >= v
local function e(limitKmh, length) return { limit = limitKmh * kmh, curve = 770 * kmh, length = length } end
s = M.summarize({ e(20, 300), e(40, 30), e(20, 300), e(40, 20), e(20, 300) })
near("short fast pieces in a slow street do not count", s and s.runLimit, 20 * kmh)
near("maxLimit still sees them", s and s.maxLimit, 40 * kmh)
s = M.summarize({ e(100, 50), e(160, 120), e(150, 90), e(160, 100), e(100, 500) })
near("run counts edges allowing at least v (160/150/160 -> 150 over 310 m)", s and s.runLimit, 150 * kmh)
s = M.summarize({ e(20, 100), e(40, M.MIN_RUN), e(20, 100) })
near("a stretch of exactly MIN_RUN counts", s and s.runLimit, 40 * kmh)
s = M.summarize({ e(40, 60), e(60, 100), e(40, 40) })
near("short section: half its length is enough (100 of 200 m)", s and s.runLimit, 60 * kmh)
s = M.summarize({ e(40, 60), e(60, 90), e(40, 50) })
near("short section: less than half is not", s and s.runLimit, 40 * kmh)

check("empty edge list gives nil", M.summarize({}) == nil)
check("nil edge list gives nil", M.summarize(nil) == nil)

-- collector with a fake engine ---------------------------------------------
-- vehicles: entity -> { enRoute, stopIndex, edges }
local clock = 0
local function fakeAdapter(world, lineStops, reads, cost)
	return {
		clock = function() return clock end,
		vehicleSection = function(v)
			local w = world[v]
			if not w then return nil end
			return w.enRoute, w.stopIndex
		end,
		pathEdges = function(v)
			reads[#reads + 1] = v
			clock = clock + (cost or 0)
			return world[v] and world[v].edges
		end,
		lineStopCount = function(line) return lineStops[line] end,
	}
end
local function edges(limitKmh, length)
	return { { limit = limitKmh * kmh, curve = 770 * kmh, length = length } }
end

local world = {
	[1] = { enRoute = true, stopIndex = 0, edges = edges(100, 1000) },
	[2] = { enRoute = true, stopIndex = 1, edges = edges(80, 500) },
	[3] = { enRoute = false, stopIndex = 2, edges = edges(10, 20) },  -- in the station
	[4] = { enRoute = true, stopIndex = 0, edges = edges(100, 1000) }, -- same section as 1
	[5] = { enRoute = true, stopIndex = 0, edges = edges(60, 700) },   -- other line
}
local vehicleLine = { [1] = 10, [2] = 10, [3] = 10, [4] = 10, [5] = 20 }
local list = { 1, 2, 3, 4, 5 }
local reads = {}
local c = M.new(fakeAdapter(world, { [10] = 3, [20] = 2 }, reads))

c:step(list, vehicleLine, 100)
check("free reads: all distinct sections in one step (cap MAX_SECTIONS_PER_STEP)",
	#reads == math.min(3, M.MAX_SECTIONS_PER_STEP), "reads=" .. #reads)
local max, known, total = c:lineTrackMax(10)
near("line max after first step", max, 100 * kmh)
check("known/total sections", known == 2 and total == 3, tostring(known) .. "/" .. tostring(total))
check("vehicle in a station is never read", reads[1] ~= 3 and reads[2] ~= 3 and reads[3] ~= 3)
check("a section already read in this step is not read again (vehicle 4)", reads[3] == 5,
	"third read=" .. tostring(reads[3]))

-- time budget: each read costs more than the budget -> one read per step
reads = {}
c = M.new(fakeAdapter(world, { [10] = 3, [20] = 2 }, reads, M.TIME_BUDGET * 2))
c:step(list, vehicleLine, 100)
check("time budget: an expensive read ends the step", #reads == 1, "reads=" .. #reads)
c:step(list, vehicleLine, 100 + M.STEP_INTERVAL / 2)
check("throttle: a second step within STEP_INTERVAL does nothing", #reads == 1, "reads=" .. #reads)
c:step(list, vehicleLine, 100 + M.STEP_INTERVAL)
c:step(list, vehicleLine, 100 + 2 * M.STEP_INTERVAL)
check("following steps read the remaining sections", #reads == 3, "reads=" .. #reads)
check("a known section is not read again (vehicle 4)", reads[3] == 5, "third read=" .. tostring(reads[3]))

-- wanted lines (open windows) go first
reads = {}
c = M.new(fakeAdapter(world, { [10] = 3, [20] = 2 }, reads, M.TIME_BUDGET * 2))
c:want(20, 100)
c:step(list, vehicleLine, 100)
check("wanted line is read first", reads[1] == 5, "first read=" .. tostring(reads[1]))
c:step(list, vehicleLine, 100 + M.WANT_SECONDS + M.STEP_INTERVAL)
check("an expired want has no priority any more", reads[2] == 1, "second read=" .. tostring(reads[2]))

reads = {}
c = M.new(fakeAdapter(world, { [10] = 3, [20] = 2 }, reads))
c:step(list, vehicleLine, 100)
near("other line max", (c:lineTrackMax(20)), 60 * kmh)
local sec = c:section(10, 1)
near("section length", sec and sec.length, 500)
near("section limit", sec and sec.maxLimit, 80 * kmh)

c:step(list, vehicleLine, 100 + 2 * M.STEP_INTERVAL)
check("nothing left to read while fresh", #reads == 3, "reads=" .. #reads)
local sum = M.summarize({
	{ limit = 40 * kmh, curve = 770 * kmh, length = 300 },
	{ limit = 20 * kmh, curve = 770 * kmh, length = 500 },
	{ limit = 40 * kmh, curve = 15 * kmh, length = 20 },
})
check("byLimit sums the length per effective limit",
	sum and math.abs((sum.byLimit[20] or 0) - 500) < 0.5 and math.abs((sum.byLimit[40] or 0) - 300) < 0.5
	and math.abs((sum.byLimit[15] or 0) - 20) < 0.5)
world[1].edges = edges(120, 1000) -- track upgraded
c:step(list, vehicleLine, 100 + M.MAX_AGE + M.STEP_INTERVAL)
near("stale section is re-read", (c:lineTrackMax(10)), 120 * kmh)

-- opening a window (want after a pause) re-reads its line once
local function countOf(list, v)
	local n = 0
	for __, x in ipairs(list) do if x == v then n = n + 1 end end
	return n
end
world[2].edges = edges(80, 500)
reads = {}
c = M.new(fakeAdapter(world, { [10] = 3, [20] = 2 }, reads))
c:step(list, vehicleLine, 100)
world[2].edges = edges(160, 500) -- track upgraded right after the first read
c:want(10, 110)
near("old value stays visible until re-read", (c:section(10, 1) or {}).maxLimit, 80 * kmh)
max, known = c:lineTrackMax(10)
check("stale sections still count as known", known == 2, tostring(known))
c:step(list, vehicleLine, 110)
near("opened window re-reads its line", (c:section(10, 1) or {}).maxLimit, 160 * kmh)
check("other lines are not re-read", countOf(reads, 5) == 1, "reads of vehicle 5=" .. countOf(reads, 5))
local before = #reads
c:want(10, 110 + M.WANT_SECONDS)
c:step(list, vehicleLine, 110 + M.WANT_SECONDS)
check("a window that stays open does not re-read", #reads == before, "reads=" .. #reads - before)
c:want(10, 110 + 3 * M.WANT_SECONDS)
c:step(list, vehicleLine, 110 + 3 * M.WANT_SECONDS)
check("reopening after a pause re-reads again", #reads == before + 2, "reads=" .. #reads - before)
c = M.new(fakeAdapter(world, { [10] = 3, [20] = 2 }, {}))
c:want(10, 100)
check("want for an unknown line is harmless", c:lineTrackMax(10) == nil)

-- line changed its number of stops: old sections are dropped
reads = {}
c = M.new(fakeAdapter(world, { [10] = 3, [20] = 2 }, reads))
c:step({ 1 }, vehicleLine, 0)
local stops = { [10] = 4, [20] = 2 }
c.adapter.lineStopCount = function(line) return stops[line] end
c:step({ 2 }, vehicleLine, M.STEP_INTERVAL)
max, known, total = c:lineTrackMax(10)
check("changed stop count drops old sections", known == 1 and total == 4,
	tostring(known) .. "/" .. tostring(total))

check("unknown line gives nil", c:lineTrackMax(999) == nil)
check("reset forgets everything", (function() c:reset() return c:lineTrackMax(10) == nil end)())

-- shared instance ----------------------------------------------------------
local G = {}
local a = M.getShared(G, function() return fakeAdapter(world, {}, {}) end)
local b = M.getShared(G, function() return fakeAdapter(world, {}, {}) end)
check("second mod gets the same collector", a == b)
G[M.SHARED_KEY] = { API_VERSION = 0 }
local newer = M.getShared(G, function() return fakeAdapter(world, {}, {}) end)
check("an older shared collector is replaced", newer.API_VERSION == M.API_VERSION and G[M.SHARED_KEY] == newer)
G[M.SHARED_KEY] = { API_VERSION = M.API_VERSION + 1, marker = true }
check("a newer shared collector is kept", M.getShared(G, function() return nil end).marker == true)

-- the creating mod is passed to the adapter factory (log prefix)
local owner = nil
local G2 = {}
local first = M.getShared(G2, function(o) owner = o return fakeAdapter(world, {}, {}) end, "kampfmoehre_top_speed")
check("adapter factory gets the owner", owner == "kampfmoehre_top_speed", tostring(owner))
check("collector remembers its owner", first.owner == "kampfmoehre_top_speed", tostring(first.owner))
M.getShared(G2, function(o) owner = o return fakeAdapter(world, {}, {}) end, "kampfmoehre_rate_preview")
check("second mod does not take over the owner", first.owner == "kampfmoehre_top_speed")

print(failures == 0 and "all tests passed" or (failures .. " test(s) failed"))
os.exit(failures == 0 and 0 or 1)
