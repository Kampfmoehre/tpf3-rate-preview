-- run: luajit test/line_route_test.lua  (from the repo root)
package.path = "kampfmoehre_rate_preview_1/content/gui/kampfmoehre_rate_preview/?.lua;" .. package.path
local M = require "line_route"

local failures = 0
local function check(name, cond, detail)
	if cond then
		print("ok   " .. name)
	else
		failures = failures + 1
		print("FAIL " .. name .. (detail and (": " .. detail) or ""))
	end
end

-- summarize stub: a section = the sum of its edge lengths
local function summarize(edges)
	if type(edges) ~= "table" or #edges == 0 then return nil end
	local len = 0
	for __, e in ipairs(edges) do len = len + e.length end
	return { length = len }
end

-- fake world: lines[line] = { stops = { key, ... }, lengths = { section lengths }, modes = {...} or nil }
-- a section length of false makes the pathfinder fail for it
local function fakeAdapter(lines)
	local a = { calls = {}, logs = {}, t = 0 }
	a.lineStops = function(line)
		local L = lines[line]
		if not L then return nil end
		local stops = {}
		for i, key in ipairs(L.stops) do
			stops[i] = { node = { line = line, i = i }, key = key, waypoints = L.waypoints and L.waypoints[i] or nil }
		end
		return stops, L.modes
	end
	a.path = function(from, to, modes)
		a.t = a.t + 0.001
		a.calls[#a.calls + 1] = from.line
		local len = lines[from.line].lengths[from.i]
		if not len then return nil, "no path" end
		return { { length = len } }
	end
	a.clock = function() return a.t end
	a.log = function(msg) a.logs[#a.logs + 1] = msg end
	a.completed = {}
	a.complete = function(line, entry) a.completed[#a.completed + 1] = { line = line, length = entry.length, ms = entry.ms, maxMs = entry.maxMs } end
	return a
end

local function fill(cache, lines, now, steps)
	for __ = 1, steps or 20 do cache:step(lines, now) end
end

-- complete route -----------------------------------------------------------
local world = { [1] = { stops = { "a", "b", "c" }, lengths = { 1000, 1000, 500 }, modes = { "TRAIN" } } }
local adapter = fakeAdapter(world)
local cache = M.new(adapter, summarize)
fill(cache, { 1 }, 100)
local r = cache:route(1)
check("route_complete length", r and r.length == 2500, r and tostring(r.length))
check("route_complete sections", r and #r.sections == 3 and r.n == 3)
check("route_complete section 3", r and r.sections[3] and r.sections[3].length == 500)
check("route_complete reads each section once", #adapter.calls == 3, tostring(#adapter.calls))

-- failed section -----------------------------------------------------------
world = { [1] = { stops = { "a", "b", "c" }, lengths = { 1000, false, 500 }, modes = { "TRAIN" } } }
adapter = fakeAdapter(world)
cache = M.new(adapter, summarize)
fill(cache, { 1 }, 100)
r = cache:route(1)
check("route_failed_section is false", r and r.sections[2] == false)
check("route_failed_section no length", r and r.length == nil)
check("route_failed_section other sections kept", r and r.sections[1] and r.sections[1].length == 1000)
check("route_failed_section logs once", #adapter.logs == 1, tostring(#adapter.logs))
fill(cache, { 1 }, 150)
check("route_failed_section not retried before MAX_AGE", #adapter.calls == 3, tostring(#adapter.calls))

-- fingerprint: a changed line is re-read when it is due (wanted after a pause)
world = { [1] = { stops = { "a", "b", "c" }, lengths = { 1000, 1000, 500 }, modes = { "TRAIN" } } }
adapter = fakeAdapter(world)
cache = M.new(adapter, summarize)
fill(cache, { 1 }, 100)
world[1].stops = { "a", "b" }
world[1].lengths = { 700, 800 }
cache:want(1, 200)
fill(cache, { 1 }, 200)
r = cache:route(1)
check("route_fingerprint re-read", #adapter.calls == 5, tostring(#adapter.calls))
check("route_fingerprint new sections", r and r.n == 2 and r.length == 1500 and r.sections[3] == nil,
	r and tostring(r.length))

-- unchanged stops: a want within WANT_SECONDS of the last one does not re-read
cache:want(1, 202)
fill(cache, { 1 }, 202)
check("route_want_repeat no re-read", #adapter.calls == 5, tostring(#adapter.calls))

-- MAX_AGE ------------------------------------------------------------------
world = { [1] = { stops = { "a", "b" }, lengths = { 1000, 1000 }, modes = { "TRAIN" } } }
adapter = fakeAdapter(world)
cache = M.new(adapter, summarize)
fill(cache, { 1 }, 100)
fill(cache, { 1 }, 100 + M.MAX_AGE - 1)
check("route_max_age not yet", #adapter.calls == 2, tostring(#adapter.calls))
fill(cache, { 1 }, 100 + M.MAX_AGE + 1)
check("route_max_age re-read", #adapter.calls == 4, tostring(#adapter.calls))
check("route_max_age keeps the old route while re-reading", cache:route(1) and cache:route(1).length == 2000)

-- budget -------------------------------------------------------------------
world = {}
local lines = {}
for l = 1, 5 do
	world[l] = { stops = { "a", "b", "c" }, lengths = { 100, 100, 100 }, modes = { "BUS" } }
	lines[l] = l
end
adapter = fakeAdapter(world)
cache = M.new(adapter, summarize)
cache:step(lines, 100)
check("route_budget at most MAX_SECTIONS_PER_STEP", #adapter.calls <= M.MAX_SECTIONS_PER_STEP, tostring(#adapter.calls))
check("route_budget at least one", #adapter.calls >= 1)
local before = #adapter.calls
adapter.t = 0
local slow = adapter.path
adapter.path = function(...) adapter.t = adapter.t + 0.05 return slow(...) end
cache:step(lines, 102)
check("route_budget one slow read per step", #adapter.calls == before + 1, tostring(#adapter.calls - before))

-- want first ---------------------------------------------------------------
adapter = fakeAdapter(world)
cache = M.new(adapter, summarize)
cache:want(5, 100)
cache:step(lines, 100)
check("route_want_first", adapter.calls[1] == 5, tostring(adapter.calls[1]))

-- no modes -----------------------------------------------------------------
world = { [1] = { stops = { "a", "b" }, lengths = { 1000, 1000 }, modes = nil } }
adapter = fakeAdapter(world)
cache = M.new(adapter, summarize)
fill(cache, { 1 }, 100)
check("route_no_modes no path call", #adapter.calls == 0)
check("route_no_modes no route", cache:route(1) == nil)

-- lines that disappear are forgotten ----------------------------------------
world = { [1] = { stops = { "a", "b" }, lengths = { 1000, 1000 }, modes = { "TRAIN" } } }
adapter = fakeAdapter(world)
cache = M.new(adapter, summarize)
fill(cache, { 1 }, 100)
cache:step({}, 103)
check("route_pruned", cache:route(1) == nil)

-- wanted line outside the list (empty line in the store) is still read
world = { [7] = { stops = { "a", "b" }, lengths = { 300, 400 }, modes = { "TRAIN" } } }
adapter = fakeAdapter(world)
cache = M.new(adapter, summarize)
cache:want(7, 100)
fill(cache, {}, 100)
check("route_wanted_outside_list", cache:route(7) and cache:route(7).length == 700)

-- modes per carrier and kind (probe 2026-11-14) ------------------------------
local function same(a, b) return a and b and table.concat(a, "+") == table.concat(b, "+") end
check("modes rail", same(M.modesFor("RAIL", "cargo"), { "TRAIN" }))
check("modes bus line", same(M.modesFor("ROAD", "pax"), { "BUS" }))
check("modes truck line", same(M.modesFor("ROAD", "cargo"), { "TRUCK" }))
check("modes road unknown kind", same(M.modesFor("ROAD", nil), { "TRUCK" }))
check("modes tram", same(M.modesFor("TRAM", "pax"), { "TRAM", "ELECTRIC_TRAM" }))
check("modes air none", M.modesFor("AIR", "pax") == nil)
check("modes water none until probed", M.modesFor("WATER", "cargo") == nil)
check("modes unknown carrier none", M.modesFor(nil, "pax") == nil)

-- a stop with waypoints: its outgoing section keeps the straight line -------
world = { [1] = { stops = { "a", "b", "c" }, lengths = { 1000, 1000, 500 }, modes = { "TRAIN" }, waypoints = { [2] = true } } }
adapter = fakeAdapter(world)
cache = M.new(adapter, summarize)
fill(cache, { 1 }, 100)
r = cache:route(1)
check("route_waypoints section skipped", r and r.sections[2] == false)
check("route_waypoints no path call for it", #adapter.calls == 2, tostring(#adapter.calls))
check("route_waypoints neighbours kept", r and r.sections[1] and r.sections[3] and r.sections[1].length == 1000)

-- completion callback -------------------------------------------------------
world = { [1] = { stops = { "a", "b" }, lengths = { 300, 400 }, modes = { "TRAIN" } } }
adapter = fakeAdapter(world)
cache = M.new(adapter, summarize)
fill(cache, { 1 }, 100)
check("route_complete_callback once", #adapter.completed == 1, tostring(#adapter.completed))
check("route_complete_callback length", adapter.completed[1] and adapter.completed[1].length == 700)

-- read time in the completion entry (fake clock: 1 ms per path call) --------
world = { [1] = { stops = { "a", "b", "c" }, lengths = { 100, 200, 300 }, modes = { "TRAIN" } } }
adapter = fakeAdapter(world)
cache = M.new(adapter, summarize)
fill(cache, { 1 }, 100)
check("route_timing total ms", adapter.completed[1] and math.abs((adapter.completed[1].ms or 0) - 3) < 1e-6,
	adapter.completed[1] and tostring(adapter.completed[1].ms))
check("route_timing max ms", adapter.completed[1] and math.abs((adapter.completed[1].maxMs or 0) - 1) < 1e-6)

-- invalidate: a line whose stop count changed is read again right away -------
world = { [1] = { stops = { "a", "b", "c" }, lengths = { 100, 200, 300 }, modes = { "TRAIN" } } }
adapter = fakeAdapter(world)
cache = M.new(adapter, summarize)
fill(cache, { 1 }, 100)
world[1].stops = { "a", "b" }
world[1].lengths = { 100, 150 }
cache:invalidate(1)
fill(cache, { 1 }, 101)
r = cache:route(1)
check("route_invalidate re-reads", r and r.n == 2 and r.length == 250, r and tostring(r.n))
-- invalidating during a read drops the pending read (its stops are stale)
world = { [1] = { stops = { "a", "b", "c" }, lengths = { 100, 200, 300 }, modes = { "TRAIN" } } }
adapter = fakeAdapter(world)
cache = M.new(adapter, summarize)
cache:step({ 1 }, 100)                 -- budget: at most 3 of 3 sections, read not finished yet? force a partial read
cache.pending[1] = cache.pending[1] or { at = 100, n = 3, stops = {}, modes = {}, sections = {}, nextIdx = 1 }
world[1].stops = { "a", "b" }
world[1].lengths = { 100, 150 }
cache:invalidate(1)
fill(cache, { 1 }, 101)
r = cache:route(1)
check("route_invalidate drops a pending read", r and r.n == 2, r and tostring(r.n))

print(failures == 0 and "all tests passed" or (failures .. " test(s) failed"))
os.exit(failures == 0 and 0 or 1)
