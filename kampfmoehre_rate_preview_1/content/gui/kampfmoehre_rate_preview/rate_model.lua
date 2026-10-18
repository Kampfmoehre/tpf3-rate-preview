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

---------------------------------------------------------------------------
-- Reachable speed between stops (land vehicles).
-- The game's own tooltip physics (vehicle_util.getPowerRatingTextAndToolTip):
-- pull F(v) = min(tractiveEffort, power / v), acceleration a(v) =
-- (F(v) - resistance) / weight with tractiveEffort in kN, power in kW, weight
-- in t (incl. full payload), v in m/s; on the flat resistance = rolling
-- friction. Braking is uniform (brakeDeceleration, m/s^2). A section of
-- length d allows the largest v <= topSpeed with accelDistance(v) +
-- v^2 / (2 b) <= d.
-- phys = { weight, power, tractiveEffort, friction, topSpeed, brakeDecel }
---------------------------------------------------------------------------
M.ACCEL_INTEGRATION_STEPS = 200
M.DEFAULT_BRAKE_DECEL = 2.5

local function pull(phys, v)
	if v <= 0 then return phys.tractiveEffort end
	return math.min(phys.tractiveEffort, phys.power / v)
end

-- true if the consist can accelerate at all on the flat
local function physValid(phys)
	return type(phys) == "table" and (phys.weight or 0) > 0 and (phys.power or 0) > 0
		and (phys.tractiveEffort or 0) > 0 and (phys.topSpeed or 0) > 0
		and phys.tractiveEffort > (phys.friction or 0)
end

-- distance (m) and time (s) to accelerate from standstill to v on the flat; nil if impossible
function M.accelDistanceTime(phys, v)
	if not physValid(phys) or v <= 0 then return nil end
	local friction = phys.friction or 0
	local function invA(u) -- weight / (F(u) - friction) = 1 / a(u)
		local f = pull(phys, u) - friction
		if f <= 0 then return nil end
		return phys.weight / f
	end
	-- Simpson's rule, split at the kink v_t = power / tractiveEffort
	local function simpson(a, b, fn)
		local n = M.ACCEL_INTEGRATION_STEPS
		local h = (b - a) / n
		local sum = 0
		for i = 0, n do
			local x = a + i * h
			local y = fn(x)
			if y == nil then return nil end
			local w = (i == 0 or i == n) and 1 or ((i % 2 == 1) and 4 or 2)
			sum = sum + w * y
		end
		return sum * h / 3
	end
	local vt = phys.power / phys.tractiveEffort
	local dist, time = 0, 0
	local segments = (vt > 0 and vt < v) and { { 0, vt }, { vt, v } } or { { 0, v } }
	for _, seg in ipairs(segments) do
		local t = simpson(seg[1], seg[2], invA)
		local d = simpson(seg[1], seg[2], function(u) local i = invA(u) return i and u * i or nil end)
		if t == nil or d == nil then return nil end
		dist, time = dist + d, time + t
	end
	return dist, time
end

-- largest speed (m/s) reachable on a section of `lengthMetres` incl. braking to a stop
function M.reachableSpeed(lengthMetres, phys)
	if not physValid(phys) or not lengthMetres or lengthMetres <= 0 then return nil end
	local b = (phys.brakeDecel and phys.brakeDecel > 0) and phys.brakeDecel or M.DEFAULT_BRAKE_DECEL
	local function fits(v)
		local d = M.accelDistanceTime(phys, v)
		return d ~= nil and d + v * v / (2 * b) <= lengthMetres
	end
	local top = phys.topSpeed
	if fits(top) then return top end
	local lo, hi = 0, top
	for _ = 1, 30 do
		local mid = (lo + hi) / 2
		if fits(mid) then lo = mid else hi = mid end
	end
	return lo
end

-- max reachable speed over sections { { length = m, cap = m/s or nil }, ... }:
-- per section min(reachableSpeed(length), cap), cap = the track's speed limit
-- if known (track_limits.lua). Second result: true if the best section is
-- limited by its cap rather than by physics. nil if unknown.
function M.reachableSpeedOnSections(sections, phys)
	local best, bestCapped = nil, false
	for _, sec in ipairs(sections or {}) do
		local v = M.reachableSpeed(sec.length, phys)
		if v then
			local capped = sec.cap ~= nil and sec.cap < v
			if capped then v = sec.cap end
			if best == nil or v > best then best, bestCapped = v, capped end
		end
	end
	return best, bestCapped
end

-- max reachable speed over a list of section lengths, nil if unknown
function M.reachableSpeedOnLine(sectionLengths, phys)
	local best = nil
	for _, len in ipairs(sectionLengths or {}) do
		local v = M.reachableSpeed(len, phys)
		if v and (best == nil or v > best) then best = v end
	end
	return best
end

---------------------------------------------------------------------------
-- Gradients (measured 2026-10-18 against MOVE_PATH.dyn.accel, rms 0.005 m/s²):
-- a = (F(v) - friction - G * s * m) / m with the game's own G = 3.27
-- (vehicle_util.tl calcDownhillSlopeForce, a third of real gravity) and
-- s = mean grade under the train. Mass: empty weight + max payload times the
-- cargo's weightFactor (1.0 goods, 1/6 passengers, base/content/cargos), i.e.
-- full load; a loaded stone train climbed lighter than that, so this errs on
-- the slow side.
-- section = { length = m, cap = m/s?, profile = { step = m, h = { h(0), h(step), ... } } }
-- (track_limits.lua, travel direction); phys as above plus length (train, m).
---------------------------------------------------------------------------
M.GRAVITY = 3.27
M.PASSENGER_WEIGHT_FACTOR = 1 / 6
M.CLIMB_AFFECTED = 0.9      -- affected: min speed below this share of the flat run there
M.CLIMB_WINDOW = 200        -- m, window for the shown grade
M.STALL_SPEED = 5 / 3.6     -- shown as "< 5 km/h" when the consist cannot climb
M.CLIMB_MIN_SPEED = 0.5     -- m/s, floor of the integration
M.DEFAULT_TRAIN_LENGTH = 20

-- consist mass in t: empty + full payload, passengers weigh 1/6
function M.consistMass(weightEmpty, weightMaxPayload, passengersOnly)
	local factor = passengersOnly and M.PASSENGER_WEIGHT_FACTOR or 1
	return (weightEmpty or 0) + (weightMaxPayload or 0) * factor
end

local function heightAt(profile, x)
	local h, step = profile.h, profile.step
	local n = #h
	local f = x / step
	local i = math.floor(f)
	if n == 1 or i < 0 then return h[1] end
	if i >= n - 1 then return h[n] end
	return h[i + 1] + (h[i + 2] - h[i + 1]) * (f - i)
end

-- speeds at x = (k - 1) * step from a standing start; with grade = false on
-- the flat. Further results: longest stretch (m) the consist cannot climb,
-- grade under the train per position.
local function speedRun(profile, length, phys, withGrade, trainLength)
	local step, m, G = profile.step, phys.weight, M.GRAVITY
	local friction = phys.friction or 0
	local vmax = phys.topSpeed
	if phys.cap and phys.cap < vmax then vmax = phys.cap end
	local n = math.floor(length / step) + 1
	local v, out, slopes = M.CLIMB_MIN_SPEED, {}, {}
	local run, stall = 0, 0
	local h0 = heightAt(profile, 0)
	for k = 1, n do
		out[k] = v
		local x = (k - 1) * step
		local s = 0
		if withGrade then
			if x < trainLength then
				s = (heightAt(profile, x) - h0) / math.max(x, step)
			else
				s = (heightAt(profile, x) - heightAt(profile, x - trainLength)) / trainLength
			end
			if G * s * m + friction >= phys.tractiveEffort then run = run + step else run = 0 end
			if run > stall then stall = run end
		end
		slopes[k] = s
		local a = (pull(phys, v) - friction - G * s * m) / m
		local v2 = v * v + 2 * a * step
		v = v2 > 0 and math.sqrt(v2) or 0
		if v < M.CLIMB_MIN_SPEED then v = M.CLIMB_MIN_SPEED end
		if v > vmax then v = vmax end
	end
	return out, stall, slopes
end

-- speed the consist can hold on grade s (pull = resistance), capped at vmax;
-- 0 if it cannot climb s at all
local function balanceSpeed(phys, s, vmax)
	local force = (phys.friction or 0) + M.GRAVITY * s * phys.weight
	if force <= 0 then return vmax end
	if force >= phys.tractiveEffort then return 0 end
	return math.min(vmax, phys.power / force)
end

-- slowest point of a climb on one section (see the spec
-- docs/superpowers/specs/2026-10-18-gradient-speed-design.md):
-- -> { minSpeed, at, grade, flatSpeed, affected, stalls } or nil without profile
function M.climbOnSection(section, phys)
	if type(section) ~= "table" or type(section.profile) ~= "table" or not physValid(phys) then return nil end
	local profile = section.profile
	if type(profile.h) ~= "table" or #profile.h == 0 or (profile.step or 0) <= 0 then return nil end
	local step = profile.step
	local length = section.length or (#profile.h - 1) * step
	if length <= 0 then return nil end
	local trainLength = phys.length or M.DEFAULT_TRAIN_LENGTH
	if trainLength <= 0 then trainLength = M.DEFAULT_TRAIN_LENGTH end
	local p = { weight = phys.weight, power = phys.power, tractiveEffort = phys.tractiveEffort,
		friction = phys.friction, topSpeed = phys.topSpeed, cap = section.cap }
	local grade, stall, slopes = speedRun(profile, length, p, true, trainLength)
	local flat = speedRun(profile, length, p, false, trainLength)
	local n = #grade
	local b = (phys.brakeDecel and phys.brakeDecel > 0) and phys.brakeDecel or M.DEFAULT_BRAKE_DECEL
	local vmax = p.topSpeed
	if p.cap and p.cap < vmax then vmax = p.cap end
	-- per position the speed the climb holds the train to: what it has there,
	-- or, if it is still accelerating (from the stop), what it could hold on
	-- that grade. Slower acceleration alone (a gentle grade on which the
	-- top speed is still reachable) does not count. Affected positions are
	-- those below CLIMB_AFFECTED of the flat run there; the result is the
	-- lowest of them (else the lowest overall, not affected). Braking zone
	-- excluded.
	local hit, low, any = nil, nil, nil
	for k = 1, n do
		local e = math.max(grade[k], balanceSpeed(p, slopes[k], vmax))
		if any == nil or e < any.e then any = { k = k, e = e } end
		local x = (k - 1) * step
		if x <= length - flat[k] * flat[k] / (2 * b) then
			if low == nil or e < low.e then low = { k = k, e = e } end
			if e < M.CLIMB_AFFECTED * flat[k] and (hit == nil or e < hit.e) then hit = { k = k, e = e } end
		end
	end
	local pick = hit or low or any
	local minSpeed, affected = pick.e, hit ~= nil
	local best = pick.k
	local at = (best - 1) * step
	-- steepest mean grade over CLIMB_WINDOW ending at or before `at`
	local w = math.min(M.CLIMB_WINDOW, length)
	local steepest = (heightAt(profile, w) - heightAt(profile, 0)) / w
	for e = w, at, step do
		local g = (heightAt(profile, e) - heightAt(profile, e - w)) / w
		if g > steepest then steepest = g end
	end
	return {
		minSpeed = minSpeed,
		at = at,
		grade = steepest,
		flatSpeed = flat[best],
		affected = affected,
		stalls = stall >= trainLength,
	}
end

-- affected sections (each result gets index = 1-based section) and the one
-- with the lowest min speed; filtering first, so a mild section never hides
-- a mountain
function M.climbOnSections(sections, phys)
	local worst, list = nil, {}
	for i, sec in ipairs(sections or {}) do
		local r = M.climbOnSection(sec, phys)
		if r and r.affected then
			r.index = i
			list[#list + 1] = r
			if worst == nil or r.minSpeed < worst.minSpeed then worst = r end
		end
	end
	return worst, list
end

return M
