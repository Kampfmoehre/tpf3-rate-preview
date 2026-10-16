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

-- reachable speed physics
-- Avelia Liberty: 410 t + payload, 9280 kW, 400 kN, 260 km/h, 7 parts x 0.02 friction
local avelia = { weight = 417, power = 9280, tractiveEffort = 400, friction = 0.14, topSpeed = 260 / 3.6, brakeDecel = 2.5 }
local d, tt = M.accelDistanceTime(avelia, avelia.topSpeed)
-- analytic: m vt^2 / (2F) + (m/P)(v^3 - vt^3)/3 with vt = P/F = 23.2 m/s  -> ~5.7 km, ~130 s
near("avelia accel distance", d, 5730, 60)
near("avelia accel time", tt, 129, 2)
-- 4 km between stops: measured in-game 227 km/h (Top Speed Reached)
local v4 = M.reachableSpeed(4000, avelia)
near("avelia reachable on 4 km (km/h)", v4 * 3.6, 220, 12)
near("avelia reaches top on 8 km", M.reachableSpeed(8000, avelia) * 3.6, 260, 0.01)
near("avelia on 500 m", M.reachableSpeed(500, avelia) * 3.6, 95, 15)
-- bus: 70 km/h reached easily within 300 m
local bus = { weight = 16, power = 150, tractiveEffort = 30, friction = 0.02, topSpeed = 70 / 3.6, brakeDecel = 2.5 }
near("bus reaches top on 400 m", M.reachableSpeed(400, bus) * 3.6, 70, 0.01)
near("bus on 300 m (accel 262 m + brake 75 m)", M.reachableSpeed(300, bus) * 3.6, 67, 1)
near("line max over sections", M.reachableSpeedOnLine({ 500, 4000, 1000 }, avelia), v4, 0.01)
assert(M.reachableSpeed(4000, { weight = 100, power = 0, tractiveEffort = 100, topSpeed = 50 }) == nil, "no power -> nil")
assert(M.reachableSpeed(4000, { weight = 100, power = 500, tractiveEffort = 1, friction = 2, topSpeed = 50 }) == nil, "friction > pull -> nil")
assert(M.reachableSpeedOnLine({}, avelia) == nil, "no sections -> nil")
-- sections with real track length and speed limit (cap, m/s; nil = unknown)
local vs, capped = M.reachableSpeedOnSections({ { length = 8000, cap = 100 / 3.6 }, { length = 500 } }, avelia)
near("track cap limits the long section", vs * 3.6, 100, 0.01)
assert(capped == true, "capped flag when the cap decides")
vs, capped = M.reachableSpeedOnSections({ { length = 4000, cap = 300 / 3.6 }, { length = 500, cap = 80 / 3.6 } }, avelia)
near("cap above physics does not matter", vs, v4, 0.01)
assert(capped == false, "not capped when physics decides")
vs, capped = M.reachableSpeedOnSections({ { length = 4000 }, { length = 8000, cap = 240 / 3.6 } }, avelia)
near("max over sections: capped 8 km (240) beats uncapped 4 km (~220)", vs * 3.6, 240, 0.01)
assert(capped == true, "capped flag follows the best section")
assert(M.reachableSpeedOnSections({}, avelia) == nil, "no sections -> nil (OnSections)")
-- heavy freight train: 2000 t, 3000 kW, 250 kN, 100 km/h
local freight = { weight = 2000, power = 3000, tractiveEffort = 250, friction = 0.5, topSpeed = 100 / 3.6, brakeDecel = 2.5 }
local df = M.accelDistanceTime(freight, freight.topSpeed)
-- analytic: 2000*12^2/(2*250) + (2000/3000)*(27.8^3 - 12^3)/3 = 4967 m
near("freight accel distance ~ 5.0 km", df, 4967, 40)
near("freight on 2 km (km/h)", M.reachableSpeed(2000, freight) * 3.6, 70, 10)

if failures > 0 then
	print(failures .. " failure(s)")
	os.exit(1)
end
print("all tests passed")
