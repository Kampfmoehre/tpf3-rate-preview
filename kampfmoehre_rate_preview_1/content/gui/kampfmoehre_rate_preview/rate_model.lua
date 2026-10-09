-- Pure formulas for the rough rate estimate of a line without vehicles.
-- No game API in here so the module can be unit-tested with plain luajit
-- (see test/rate_model_test.lua). All constants were measured in-game
-- (5699 terminal stops, 445 vehicles; see README "How the rough estimate works").
local M = {}

-- fixed door times per stop (seconds)
M.ARRIVE_SECONDS = 2.0
M.DEPART_SECONDS = 2.0
-- extra overhead when at least one unit is loaded
M.LOAD_OVERHEAD_SECONDS = 2.3
-- mean "wait for scheduled departure / cargo" per stop
M.WAIT_SECONDS = { pax = 4.1, cargo = 5.5 }
-- seconds per unit at loadSpeed 1 and penalty 1; passengers load 16x faster
M.CARGO_UNIT_SECONDS = 16.0
M.PAX_UNIT_SECONDS = 1.0
-- Passenger stops: fixed part (doors, waiting) plus boarding and alighting.
-- Measured on 70 lines: passengers per stop (both directions) are about
-- 1.75 x capacity on two-stop lines and about 0.5 x capacity from six stops
-- on, i.e. capacity x max(0.5, 3.5 / stops).
M.PAX_FIXED_SECONDS = 8.4
M.PAX_TURNOVER_PER_CYCLE = 3.5
M.PAX_MIN_TURNOVER_PER_STOP = 0.5
-- loadSpeed of a consist is the SUM over its parts with capacity: wagons load
-- in parallel (measured on buses, trams, 3- to 10-car trains and cargo trains)

-- penalty = 1 / (terminal modifier x stock modifier); 1 if unknown
function M.penalty(terminalModifier, stockModifier)
	local t = (type(terminalModifier) == "number" and terminalModifier > 0) and terminalModifier or 1
	local s = (type(stockModifier) == "number" and stockModifier > 0) and stockModifier or 1
	return 1 / (t * s)
end

-- seconds to load or unload one unit; kind = "pax" | "cargo"
function M.secondsPerUnit(kind, loadSpeed, penalty)
	if type(loadSpeed) ~= "number" or loadSpeed <= 0 then return nil end
	if kind == "pax" then
		return M.PAX_UNIT_SECONDS / loadSpeed
	end
	return M.CARGO_UNIT_SECONDS * (penalty or 1) / loadSpeed
end

-- passengers boarding and alighting per stop for a consist of `capacity` on a
-- line with `nStops` stops
function M.paxUnitsPerStop(capacity, nStops)
	return capacity * math.max(M.PAX_MIN_TURNOVER_PER_STOP, M.PAX_TURNOVER_PER_CYCLE / math.max(1, nStops or 1))
end

-- dwell time of one stop: { kind, loadSpeed, penalty, unload, load }
-- (pax: unload + load = boarding and alighting passengers)
function M.stopSeconds(stop)
	if stop.kind == "pax" then
		if type(stop.loadSpeed) ~= "number" or stop.loadSpeed <= 0 then return nil end
		return M.PAX_FIXED_SECONDS + ((stop.unload or 0) + (stop.load or 0)) / stop.loadSpeed
	end
	local spu = M.secondsPerUnit(stop.kind, stop.loadSpeed, stop.penalty)
	if spu == nil then return nil end
	local t = M.ARRIVE_SECONDS + M.DEPART_SECONDS + (M.WAIT_SECONDS[stop.kind] or M.WAIT_SECONDS.cargo)
	t = t + (stop.unload or 0) * spu
	if (stop.load or 0) > 0 then
		t = t + M.LOAD_OVERHEAD_SECONDS + stop.load * spu
	end
	return t
end

-- Stops of a new line: passengers board and alight at every stop (see
-- paxUnitsPerStop); cargo is loaded once and unloaded once per round trip with full
-- capacity (at the stops with the two best penalties, i.e. the specialised
-- ends), as measured on busy two-stop lines (turnover 2.0 x capacity).
-- penalties: one entry per stop (1 if unknown)
function M.stopsForNewLine(kind, capacity, loadSpeed, penalties)
	local stops = {}
	if kind == "pax" then
		local units = M.paxUnitsPerStop(capacity, #penalties)
		for i = 1, #penalties do
			stops[i] = { kind = kind, loadSpeed = loadSpeed, penalty = penalties[i], unload = units / 2, load = units / 2 }
		end
		return stops
	end
	local order = {}
	for i = 1, #penalties do order[i] = i end
	table.sort(order, function(a, b) return penalties[a] < penalties[b] end)
	local loadAt, unloadAt = order[1], order[2] or order[1]
	for i = 1, #penalties do
		stops[i] = { kind = kind, loadSpeed = loadSpeed, penalty = penalties[i],
			unload = (i == unloadAt) and capacity or 0, load = (i == loadAt) and capacity or 0 }
	end
	return stops
end

---------------------------------------------------------------------------
-- Travel time model, fitted on the player's other lines of the same carrier
-- and cargo kind:  travel = p * len / top + q * len + b * stops
-- p: vehicle-limited share (detour factor), q: road/track-limited share
-- (1 / effective speed limit), b: seconds per stop for braking and
-- accelerating. Measured road lines: buses hardly depend on their top speed
-- (streets limit them), trucks and all rail/water/air vehicles more so.
---------------------------------------------------------------------------
M.MIN_FIT_SAMPLES = 6

-- least squares x for rows of (features, y); features all of the same length
local function leastSquares(rows, cols)
	local n = #cols
	local A, b = {}, {}
	for i = 1, n do
		A[i] = {}
		for j = 1, n do A[i][j] = 0 end
		b[i] = 0
	end
	for _, r in ipairs(rows) do
		for i = 1, n do
			local xi = r.x[cols[i]]
			for j = 1, n do A[i][j] = A[i][j] + xi * r.x[cols[j]] end
			b[i] = b[i] + xi * r.y
		end
	end
	-- gaussian elimination with partial pivoting
	for i = 1, n do
		local piv = i
		for r = i + 1, n do if math.abs(A[r][i]) > math.abs(A[piv][i]) then piv = r end end
		A[i], A[piv], b[i], b[piv] = A[piv], A[i], b[piv], b[i]
		if math.abs(A[i][i]) < 1e-12 then return nil end
		for r = 1, n do
			if r ~= i then
				local f = A[r][i] / A[i][i]
				for c = 1, n do A[r][c] = A[r][c] - f * A[i][c] end
				b[r] = b[r] - f * b[i]
			end
		end
	end
	local x = {}
	for i = 1, n do x[cols[i]] = b[i] / A[i][i] end
	return x
end

-- samples: list of { len, top, stops, travel }; returns { p, q, b, n, mode }
function M.fitTravel(samples)
	local rows = {}
	for _, s in ipairs(samples or {}) do
		if s.len and s.top and s.stops and s.travel and s.len > 0 and s.top > 0 and s.stops > 0 and s.travel > 0 then
			rows[#rows + 1] = { x = { p = s.len / s.top, q = s.len, b = s.stops }, y = s.travel }
		end
	end
	if #rows == 0 then return nil end
	if #rows < M.MIN_FIT_SAMPLES then
		-- too few lines: single detour factor on top speed
		local sum = 0
		for _, r in ipairs(rows) do sum = sum + r.y / r.x.p end
		return { p = sum / #rows, q = 0, b = 0, n = #rows, mode = "single" }
	end
	-- full fit, then drop terms that come out negative (not physical)
	for _, cols in ipairs({ { "p", "q", "b" }, { "p", "b" }, { "q", "b" }, { "p", "q" }, { "p" }, { "q" } }) do
		local x = leastSquares(rows, cols)
		if x then
			local ok = true
			for _, c in ipairs(cols) do if x[c] < 0 then ok = false end end
			if ok then
				return { p = x.p or 0, q = x.q or 0, b = x.b or 0, n = #rows, mode = table.concat(cols) }
			end
		end
	end
	return nil
end

function M.travelSeconds(lengthMetres, topSpeed, nStops, params)
	if not (lengthMetres and topSpeed and params) or lengthMetres <= 0 or topSpeed <= 0 then return nil end
	local t = (params.p or 0) * lengthMetres / topSpeed + (params.q or 0) * lengthMetres + (params.b or 0) * (nStops or 0)
	if t <= 0 then return nil end
	return t
end

function M.cycleSeconds(lengthMetres, topSpeed, stops, params)
	local t = M.travelSeconds(lengthMetres, topSpeed, #stops, params)
	if t == nil then return nil end
	for _, stop in ipairs(stops) do
		local s = M.stopSeconds(stop)
		if s == nil then return nil end
		t = t + s
	end
	return t
end

-- rate = capacity x k / cycle, k = seconds per game year as the game's rate uses it
function M.rate(capacity, k, cycleSeconds)
	if not (capacity and k and cycleSeconds) or cycleSeconds <= 0 then return nil end
	return capacity * k / cycleSeconds
end

return M
