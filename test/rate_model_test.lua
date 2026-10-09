-- run: luajit test/rate_model_test.lua  (from the repo root)
package.path = "kampfmoehre_rate_preview_1/content/gui/kampfmoehre_rate_preview/?.lua;" .. package.path
local M = require "rate_model"

local failures = 0
local function near(name, got, want, tol)
	tol = tol or 0.01
	if got == nil or math.abs(got - want) > tol then
		failures = failures + 1
		print(string.format("FAIL %s: got %s, want %s", name, tostring(got), tostring(want)))
	else
		print("ok   " .. name)
	end
end

-- penalties as the engine reports them (pen = 1 / (vc * sc))
near("penalty industry terminal", M.penalty(2, 1), 0.5)
near("penalty specialised station + warehouse", M.penalty(2, 2), 0.25)
near("penalty generic terminal", M.penalty(1, nil), 1.0)

-- measured: cargo b = 16 * pen / loadSpeed, passengers b = 1 / loadSpeed
near("cargo ls=10 pen=0.25", M.secondsPerUnit("cargo", 10, 0.25), 0.40)
near("cargo ls=4 pen=0.5", M.secondsPerUnit("cargo", 4, 0.5), 2.00)
near("cargo ls=8 pen=1", M.secondsPerUnit("cargo", 8, 1), 2.00)
near("pax ls=3", M.secondsPerUnit("pax", 3), 0.333)
near("pax ls=1.5", M.secondsPerUnit("pax", 1.5), 0.667)
assert(M.secondsPerUnit("pax", 0) == nil, "zero load speed -> nil")

-- a measured kind of stop: Kipper (ls 10) loading 28 units at pen 0.25
near("stop cargo load 28 @ ls10 pen0.25", M.stopSeconds({ kind = "cargo", loadSpeed = 10, penalty = 0.25, unload = 0, load = 28 }),
	2 + 2 + 5.5 + 2.3 + 28 * 0.4)
-- passenger stops: fixed part + passengers / summed load speed
near("stop pax 10+10 @ ls3", M.stopSeconds({ kind = "pax", loadSpeed = 3, penalty = nil, unload = 10, load = 10 }), 8.4 + 20 / 3)
near("stop pax empty", M.stopSeconds({ kind = "pax", loadSpeed = 20 }), 8.4)
near("pax units 2 stops", M.paxUnitsPerStop(120, 2), 210)
near("pax units 10 stops", M.paxUnitsPerStop(28, 10), 14)
-- measured: 3-car train (120 seats, 3 x loadSpeed 4) on a 2-stop line dwells 24 s
near("train dwell", M.stopSeconds({ kind = "pax", loadSpeed = 12, unload = 105, load = 105 }), 24, 2)
-- measured: 10-car train (275 seats, 10 x 3) 20.9 s
near("long train dwell", M.stopSeconds({ kind = "pax", loadSpeed = 30, unload = 240, load = 240 }), 21, 4)
-- unloading only: no load overhead
near("stop cargo unload only", M.stopSeconds({ kind = "cargo", loadSpeed = 10, penalty = 1, unload = 10, load = 0 }),
	2 + 2 + 5.5 + 16)

-- new line stop model
local pax = M.stopsForNewLine("pax", 20, 5, { 1, 1 })
near("pax stops count", #pax, 2)
near("pax stop load (1.75 x 20 / 2)", pax[1].load, 17.5)
near("pax stop unload", pax[2].unload, 17.5)
local cargo = M.stopsForNewLine("cargo", 40, 10, { 0.5, 0.5, 1 })
near("cargo loads once", cargo[1].load + cargo[2].load + cargo[3].load, 40)
near("cargo unloads once", cargo[1].unload + cargo[2].unload + cargo[3].unload, 40)
near("cargo uses best penalties", cargo[3].load + cargo[3].unload, 0)
local one = M.stopsForNewLine("cargo", 40, 10, { 0.5 })
near("cargo single stop loads and unloads there", one[1].load + one[1].unload, 80)

-- travel model
local P = { p = 2, q = 0.05, b = 10 }
near("travel p/q/b", M.travelSeconds(1000, 10, 3, P), 200 + 50 + 30)
near("cycle", M.cycleSeconds(1000, 10, { { kind = "cargo", loadSpeed = 10, penalty = 1, unload = 0, load = 0 } }, P), 200 + 50 + 10 + 9.5)
assert(M.travelSeconds(1000, 0, 1, P) == nil, "top = 0 -> nil")
assert(M.travelSeconds(1000, 10, 1, nil) == nil, "no params -> nil")

-- fit recovers exact synthetic parameters
local syn = {}
for i = 1, 12 do
	local len, top, stops = 1000 + 700 * i, 10 + (i % 4) * 5, 2 + (i % 5)
	syn[#syn + 1] = { len = len, top = top, stops = stops, travel = 1.5 * len / top + 0.04 * len + 12 * stops }
end
local fit = M.fitTravel(syn)
near("fit p", fit.p, 1.5, 1e-6)
near("fit q", fit.q, 0.04, 1e-6)
near("fit b", fit.b, 12, 1e-6)
-- few samples: single factor on top speed
local few = M.fitTravel({ { len = 1000, top = 10, stops = 2, travel = 300 }, { len = 2000, top = 20, stops = 2, travel = 300 } })
near("single factor p", few.p, 3)
assert(few.mode == "single" and few.q == 0 and few.b == 0, "single mode")
assert(M.fitTravel({}) == nil, "no samples -> nil")
-- negative terms are dropped: data with no stop cost
local nostop = {}
for i = 1, 10 do
	local len, top, stops = 500 * i, 15, (i % 3) + 1
	nostop[#nostop + 1] = { len = len, top = top, stops = stops, travel = 2 * len / top - 0 * stops }
end
local f2 = M.fitTravel(nostop)
assert(f2.p >= 0 and f2.q >= 0 and f2.b >= 0, "non-negative fit")

-- real reference lines (fixture): the fit must beat the single detour factor
package.path = "test/?.lua;" .. package.path
local fixture = require "caldata_fixture"
local function medianRelErr(samples, pred)
	local e = {}
	for _, s in ipairs(samples) do e[#e + 1] = math.abs(pred(s) - s.travel) / s.travel end
	table.sort(e)
	return e[math.floor((#e + 1) / 2)]
end
for _, kind in ipairs({ "pax", "cargo" }) do
	local samples = fixture[kind]
	local params = M.fitTravel(samples)
	local fitErr = medianRelErr(samples, function(s) return M.travelSeconds(s.len, s.top, s.stops, params) end)
	local sum = 0
	for _, s in ipairs(samples) do sum = sum + s.travel * s.top / s.len end
	local single = { p = sum / #samples }
	local singleErr = medianRelErr(samples, function(s) return M.travelSeconds(s.len, s.top, s.stops, single) end)
	print(string.format("     fixture %s: n=%d fit=%s p=%.2f q=%.4f b=%.1f median err %.3f (single factor %.3f)",
		kind, #samples, params.mode, params.p, params.q, params.b, fitErr, singleErr))
	near("fixture " .. kind .. " fit beats single factor", fitErr < singleErr and 1 or 0, 1, 0)
	near("fixture " .. kind .. " median error below 20 %", fitErr < 0.20 and 1 or 0, 1, 0)
end

-- Linie 5 (bus, 28 seats, loadSpeed 4, 10 stops): measured 9-13 s per stop
local busStops = M.stopsForNewLine("pax", 28, 4, { 1, 1, 1, 1, 1, 1, 1, 1, 1, 1 })
local busDwell = 0
for _, st in ipairs(busStops) do busDwell = busDwell + M.stopSeconds(st) end
near("bus line dwell", busDwell, 10 * (8.4 + 14 / 4))

-- Linie 1 (truck, 2 stops): rate 87 at frequency 11:11 with capacity 40 -> k = 1459
near("rate from k", M.rate(40, 1459, 671), 87, 0.1)
-- Linie 4 (bus, 2 stops): rate 68 at 7:11 with 20 seats
near("rate bus", M.rate(20, 1465, 431), 68, 0.1)

if failures > 0 then
	print(failures .. " failure(s)")
	os.exit(1)
end
print("all tests passed")
