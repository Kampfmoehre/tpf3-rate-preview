-- Line Rate Preview for Transport Fever 3.
--
-- Shows the line's current rate and the estimated rate after the purchase /
-- replacement / modification in the vehicle dialog:
--  * in the bottom bar of the cart (next to the buy button), computed over the
--    whole cart: all entries, times the amount spin box;
--  * additionally in the detail panel on the right for single-vehicle
--    carriers (road, water, air) when buying, where one list entry is the
--    whole purchase.
--
-- The game computes the rate in C++ (api.engine.util.line.calcLineStationThroughput)
-- from the vehicles actually running on the line, so a preview is only
-- possible for a line that already has vehicles: the rate per capacity unit is
-- known and the capacity change is scaled with it, assuming the same cycle time.
--
-- Hooks. All go through module tables cached in _ug_loadedModules, so wrapping
-- their fields affects the base scripts. The GUI Lua state has no debug
-- library and recipe ids cannot be looked up by name, so everything is done
-- through exported helper functions and the builtin layout calls:
--  * line_util.getBestDepotForLine(line): called by the manager window's
--    "Buy Vehicles" button right before it opens the store -> target line.
--  * react.fireEvent(nil, "buyVehicles" | "replaceVehicles" | "modifyVehicles", param):
--    store opened; replace/modify carry param.vehicleEntities -> line + old capacity.
--  * vehicle_store_util.makeMultipleVehiclesFromParts + collectVehicleData:
--    called per cart entry (VehicleCart) -> summed cart capacity.
--  * builtin.DoubleSpinBox (min 1, max 99): the amount field of the bottom bar.
--  * builtin.BoxLayout with meta.class "bottom-bar-layout": the cart's bottom
--    bar -> our text is inserted there.
--  * vehicle_store_util.makeVehicleData: registry of list vehicleData;
--    makeVehicleProgressBarRow("Top Speed") / makeVehiclePropertyRow("Weight",
--    "Length") identify the detail panel render and the shown vehicle; the
--    second vertical builtin.BoxLayout of that render is its right column.

function data()
	local VERSION = "0.14.0"

	local react = ug_require "::/gui/main/react.lua"
	local builtin = ug_require "::/gui/main/builtin.lua"
	local vehicle_store_util = ug_require "::/gui/line_vehicle_mgmt/vehicle_store_util.tl"

	-- unwrapped helpers for our own lookups (the cart tracking below wraps the
	-- module's fields, and those wrappers must not see our internal calls)
	if not builtin._kampfmoehreRatePreviewRaw then
		builtin._kampfmoehreRatePreviewRaw = {
			makeParts = vehicle_store_util.makeMultipleVehiclesFromParts,
			collect = vehicle_store_util.collectVehicleData,
		}
	end
	local raw = builtin._kampfmoehreRatePreviewRaw
	local line_util = ug_require "::/gui/line_vehicle_mgmt/line_util.tl"
	local gui_react_util = ug_require "::/gui/main/gui_react_util.tl"
	local statistics_react_util = ug_require "::/gui/statistics/statistics_react_util.tl"
	local cargo_util = ug_require "::/gui/main/cargo_util.tl"
	local rate_model = ug_require "kampfmoehre_rate_preview_1::/gui/kampfmoehre_rate_preview/rate_model.lua"

	---------------------------------------------------------------------------
	-- helpers
	---------------------------------------------------------------------------
	-- Builtins may be called as builtin.X{params} or builtin.X(react.ref(r), {params})
	-- (see react.lua splitParams); the params table is always the last argument.
	local function lastArg(...)
		local n = select("#", ...)
		if n == 0 then return nil end
		return (select(n, ...))
	end

	local function formatInt(n)
		local i = math.floor(n + 0.5)
		local ok, lang_util = pcall(ug_require, "::/scripts/lang_util.tl")
		if ok and lang_util and lang_util.formatInt then
			local ok2, s = pcall(lang_util.formatInt, i)
			if ok2 and s then return s end
		end
		return tostring(i)
	end

	local function isEntity(e)
		return type(e) == "number" and e >= 0
	end

	-- capacity of an existing vehicle, as the game's own vehicle list shows it
	local function vehicleCapacity(vehicle)
		local ok, data = pcall(statistics_react_util.calculateCargoColumnDataForVehicle, vehicle)
		if ok and type(data) == "table" and type(data.demand) == "number" then
			return data.demand
		end
		return 0
	end

	-- capacity of a line, as the line manager's "Capacity" cell shows it
	local function lineCapacity(line)
		local ok, data = pcall(statistics_react_util.calculateCargoColumnDataForLine, line)
		if ok and type(data) == "table" and type(data.demand) == "number" then
			return data.demand
		end
		return 0
	end

	-- Top speed of an existing vehicle's consist in m/s (incl. maintenance
	-- penalty), as the game's condition card computes it; nil if unknown.
	local function vehicleTopSpeed(vehicle)
		local speed = nil
		local okT, errT = pcall(function()
			local tv = api.engine.getComponent(vehicle, api.type.ComponentType.TRANSPORT_VEHICLE)
			if not tv then return end
			local vs = raw.makeParts({ tv.transportVehicleConfig.vehicles })
			local data = raw.collect(vs, tv.modifiers)
			speed = data and (data.speedAdjusted or data.speed) or nil
			if speed == math.huge then speed = data and data.speed or nil end
			if speed == math.huge then speed = nil end
		end)
		if not okT then log.warning("[rate_preview] vehicleTopSpeed failed: " .. tostring(errT)) end
		return speed
	end

	-- Reference speed of the line: the speed of its current vehicles (min),
	-- i.e. what the current rate was measured with.
	local function lineReferenceSpeed(line)
		local ok, vs = pcall(api.engine.system.transportVehicleSystem.getLineVehicles, line)
		if not ok or type(vs) ~= "table" then return nil end
		local ref = nil
		for _, v in ipairs(vs) do
			local sp = vehicleTopSpeed(v)
			if sp and sp > 0 and (ref == nil or sp < ref) then ref = sp end
		end
		return ref
	end

	-- "(+)" if the new consist is faster than the line's current vehicles (the
	-- estimate is then conservative), "(-)" if slower, "" if equal/unknown.
	-- Note: defined before the local `ctx` exists, so the line is passed in.
	local function speedHint(newSpeed, line)
		if line == nil or type(newSpeed) ~= "number" or newSpeed <= 0 or newSpeed == math.huge then return "" end
		local ref = lineReferenceSpeed(line)
		if not ref then return "" end
		-- plain ASCII: the game font has no arrow glyphs
		if newSpeed > ref * 1.02 then return " (+)" end
		if newSpeed < ref * 0.98 then return " (-)" end
		return ""
	end

	local function vehicleLine(vehicle)
		local ok, tv = pcall(api.engine.getComponent, vehicle, api.type.ComponentType.TRANSPORT_VEHICLE)
		if not ok or tv == nil then
			return nil
		end
		local st = api.type["enum"].TransportVehicleState
		if tv.state == st.EN_ROUTE or tv.state == st.AT_TERMINAL then
			return isEntity(tv.line) and tv.line or nil
		end
		return nil
	end

	-- The cargo types the game counts for a line's "Capacity" cell: those
	-- produced along the line (see statistics_react_util.calculateCargoColumnDataForLine,
	-- which sums the capacity per such type). A vehicle's relevant capacity is
	-- the sum of its per-type capacities over exactly these types, e.g. only
	-- the 12 cargo slots of a helicopter with 20 seats + 12 slots on an oil line.
	local function lineCargoTypes(line)
		local ok, types = pcall(cargo_util.getSortedProducedCargoTypes,
			{ lineEntity = line, getTendency = true, showEmpty = true }, "CAPACITY")
		if ok and type(types) == "table" and #types > 0 then
			return types
		end
		return nil
	end

	-- e: cart entry or vehicleData with allCargoTypes {cargoTypeId : capacity},
	-- cap/totalCapacity (physical), capCargo/totalCapacityCargo (freight part).
	-- Multi-purpose wagons list the same slots under every cargo type, so the
	-- per-type sum is capped at the physical capacity.
	local function relevantCapacity(e, types)
		if e == nil then return 0 end
		local total = e.cap or e.totalCapacity or 0
		local all = e.allCargoTypes
		if types == nil or type(all) ~= "table" then
			return total
		end
		local sum, any = 0, false
		for _, t in ipairs(types) do
			local c = all[t]
			if type(c) == "number" then
				sum = sum + c
				any = true
			end
		end
		if not any then
			return total
		end
		-- cap at the physical total only: totalCapacityCargo is the largest
		-- single compartment, not the freight total (CarGoTram: 14 of 60)
		return math.min(sum, total)
	end

	-- fingerprint of a cart entry's parts (model ids), to detect edits in
	-- Replace/Modify mode where the cart starts out as the current consist
	-- Iterates a Lua table or a native (userdata) vector from the engine.
	local function forEach(list, fn)
		if type(list) == "table" then
			for _, v in ipairs(list) do fn(v) end
		elseif list ~= nil then
			pcall(function()
				for _, v in ipairs_native(list) do fn(v) end
			end)
		end
	end

	local function partsFingerprint(vehicleParts)
		local ids = {}
		forEach(vehicleParts, function(list)
			forEach(list, function(part)
				local ok, modelId = pcall(function() return part.part.modelId end)
				ids[#ids + 1] = tostring(ok and modelId or "?")
			end)
			ids[#ids + 1] = "|"
		end)
		return table.concat(ids, ",")
	end

	-- Current rate, capacity and vehicle count of a line.
	local lastNaLog = nil
	local function lineStats(line)
		local okV, vehicles = pcall(api.engine.system.transportVehicleSystem.getLineVehicles, line)
		local count = (okV and type(vehicles) == "table") and #vehicles or 0
		local okR, rate = pcall(api.engine.util.line.calcLineStationThroughput, line)
		return { count = count, capacity = lineCapacity(line), rate = (okR and rate) or 0 }
	end

	---------------------------------------------------------------------------
	-- store context: set when the store opens
	---------------------------------------------------------------------------
	-- { mode, line, carrier, oldCapacity, replaceCount }
	local ctx = nil
	local pendingBuyLine = nil -- set by getBestDepotForLine, consumed by "buyVehicles"

	-- Capacity of an existing vehicle computed the same way as a cart entry
	-- (per-type capacities over the line's cargo types, capped at the total),
	-- so replacing a vehicle with the same model yields a zero change.
	local function vehicleRelevantCapacity(vehicle, types)
		local data = nil
		pcall(function()
			local tv = api.engine.getComponent(vehicle, api.type.ComponentType.TRANSPORT_VEHICLE)
			if not tv then return end
			local vs = raw.makeParts({ tv.transportVehicleConfig.vehicles })
			data = raw.collect(vs, tv.modifiers)
		end)
		if type(data) ~= "table" then
			return vehicleCapacity(vehicle)
		end
		return relevantCapacity({ cap = data.totalCapacity, allCargoTypes = data.allCargoTypes }, types)
	end

	local function contextFromEvent(name, param)
		local carrier = type(param) == "table" and param.carrier or nil
		if name == "buyVehicles" then
			local line = pendingBuyLine
			pendingBuyLine = nil
			if not isEntity(line) then
				return nil
			end
			return { mode = "Buy", line = line, carrier = carrier, oldCapacity = 0, replaceCount = 1 }
		elseif name == "replaceVehicles" or name == "modifyVehicles" then
			local vehicles = type(param) == "table" and param.vehicleEntities or nil
			if type(vehicles) ~= "table" or #vehicles == 0 then
				return nil
			end
			local line = nil
			for _, v in ipairs(vehicles) do
				line = line or vehicleLine(v)
			end
			local types = line and lineCargoTypes(line) or nil
			local oldCapacity, oldCaps = 0, {}
			for _, v in ipairs(vehicles) do
				local c = vehicleRelevantCapacity(v, types)
				oldCaps[#oldCaps + 1] = c
				oldCapacity = oldCapacity + c
			end
			if not isEntity(line) then
				return nil
			end
			return {
				mode = (name == "replaceVehicles") and "Replace" or "Modify",
				line = line,
				carrier = carrier,
				oldCapacity = oldCapacity,
				oldCaps = oldCaps,
				replaceCount = #vehicles,
			}
		end
		return nil
	end

	-- "current → ≈ estimate" for a total new capacity, or nil if nothing to show.
	-- "current → ≈ new" frequency text when `added` vehicles join the line.
	-- The game's frequency is cycle time / number of vehicles, so adding
	-- vehicles shortens it to N / (N + added) of the current value (assuming the
	-- new vehicles are about as fast as the existing ones).
	local function frequencyText(added)
		if ctx == nil or added <= 0 then
			return nil
		end
		local stats = lineStats(ctx.line)
		if stats == nil or stats.count == 0 then
			return nil
		end
		local okF, seconds = pcall(line_util.calculateFrequencySeconds, ctx.line)
		if not okF or type(seconds) ~= "number" or seconds <= 0 then
			return nil
		end
		local newSeconds = seconds * stats.count / (stats.count + added)
		local fmt = function(v)
			local ok, str = pcall(api.util.formatMinutesSeconds, math.floor(v + 0.5))
			return (ok and str) or (tostring(math.floor(v + 0.5)) .. " s")
		end
		return fmt(seconds) .. "  →  ≈ " .. fmt(newSeconds)
	end

	---------------------------------------------------------------------------
	-- Rough estimate for lines without vehicles (mod parameter "roughEstimate").
	-- The game knows no cycle time for an empty line, so we calibrate on the
	-- player's other lines of the same carrier: for each, the straight-line
	-- round trip between its stops, its cycle time (frequency x vehicles) and
	-- its top speed give an effective "straight-line speed per km/h of top
	-- speed"; rate x cycle / capacity gives the game's year length. Both are
	-- averaged and applied to the new line's straight-line length and the new
	-- vehicle's top speed. Detours, speed limits and stop times are only
	-- covered as far as the reference lines share them, hence "rough".
	---------------------------------------------------------------------------
	local roughEnabled = false
	-- diagnostic log for the rough estimate, deduplicated per message
	local lastRoughLog = nil
	local function roughLog(msg)
		msg = "[rate_preview] rough: " .. msg
		if msg ~= lastRoughLog then
			lastRoughLog = msg
			log.message(msg)
		end
	end

	local function entityCenter(entity)
		local pos = nil
		pcall(function()
			local bv = api.engine.getComponent(entity, api.type.ComponentType.BOUNDING_VOLUME)
			if bv and bv.bbox then
				local mn, mx = bv.bbox.min, bv.bbox.max
				pos = api.type.Vec3f.new((mn.x + mx.x) * 0.5, (mn.y + mx.y) * 0.5, (mn.z + mx.z) * 0.5)
			end
		end)
		return pos
	end

	-- straight-line round-trip length of a line in metres, or nil (< 2 stops)
	-- Returns the straight-line round trip in metres (stops and waypoints in
	-- line order, closed back to the first stop) and the number of stops.
	local function lineStraightLength(line)
		local points = {}
		local nStops = 0
		local okL, errL = pcall(function()
			local lc = api.engine.getComponent(line, api.type.ComponentType.LINE)
			if not lc or not lc.stops then return end
			-- getComponent returns plain tables; ipairs_native would call :at on them
			for _, stop in ipairs(lc.stops) do
				local target = stop.stationGroup
				pcall(function()
					local sg = api.engine.getComponent(stop.stationGroup, api.type.ComponentType.STATION_GROUP)
					local st = sg and sg.stations and sg.stations[stop.station + 1]
					if st and st >= 0 then target = st end
				end)
				local c = entityCenter(target) or entityCenter(stop.stationGroup)
				if c then points[#points + 1] = c end
				nStops = nStops + 1
				-- waypoints after the stop: 3D position (ships, aircraft) or a lane position
				for _, wp in ipairs(stop.waypoints or {}) do
					pcall(function()
						if wp.pos then
							points[#points + 1] = api.type.Vec3f.new(wp.pos.x, wp.pos.y, wp.pos.z)
						elseif wp.edgePos then
							local tn = api.engine.getComponent(wp.edgePos.edgeId.entity, api.type.ComponentType.TRANSPORT_NETWORK)
							local edge = tn.edges[wp.edgePos.edgeId.index + 1]
							local pos = api.engine.util.transport.calcPosition(edge.geometry, wp.edgePos.param)
							if pos then points[#points + 1] = api.type.Vec3f.new(pos.x, pos.y, pos.z) end
						end
					end)
				end
			end
		end)
		if not okL then
			roughLog("lineStraightLength(" .. tostring(line) .. ") failed: " .. tostring(errL))
		end
		if #points < 2 then return nil end
		local total = 0
		for i = 1, #points do
			local a, b = points[i], points[(i % #points) + 1]
			total = total + api.type.Vec3f.distance(a, b)
		end
		return total, nStops
	end

	-- Pure travel time of one round trip in seconds, from the engine's per-section
	-- times of the line's vehicles (they exclude dwell time); nil if unknown.
	local function lineTravelSeconds(line)
		local best = nil
		pcall(function()
			local vs = api.engine.system.transportVehicleSystem.getLineVehicles(line)
			local sum, n = 0, 0
			for _, v in ipairs(vs) do
				local tv = api.engine.getComponent(v, api.type.ComponentType.TRANSPORT_VEHICLE)
				local total, ok = 0, tv ~= nil and type(tv.sectionTimes) == "table" and #tv.sectionTimes > 0
				if ok then
					for _, t in ipairs(tv.sectionTimes) do
						if type(t) ~= "number" or t <= 0 then ok = false break end
						total = total + t
					end
				end
				if ok then sum, n = sum + total, n + 1 end
			end
			if n > 0 then best = sum / n end
		end)
		return best
	end

	-- id of the passenger cargo type (cached)
	local paxId = nil
	local function passengerId()
		if paxId == nil then
			local ok, id = pcall(function() return api.res.cargoTypeRep.getPassengerCargoTypeId() end)
			paxId = (ok and type(id) == "number") and id or -1
		end
		return paxId
	end

	-- Terminal load speed modifier of every stop for the given cargo classes
	-- (strings like "GOODS"; {"PASSENGERS"} for passengers). The engine applies
	-- the modifier of the transfer-speed entry whose class set contains the
	-- cargo's class; "UNIVERSAL" entries match any freight. Unknown -> 1.
	-- The stock (warehouse) modifier is not reachable from here and assumed 1.
	local function lineTerminalModifiers(line, cargoClasses)
		local mods = {}
		local isPax = cargoClasses[1] == "PASSENGERS" and #cargoClasses == 1
		pcall(function()
			local lc = api.engine.getComponent(line, api.type.ComponentType.LINE)
			for i, stop in ipairs(lc.stops) do
				local m = 1
				pcall(function()
					local sg = api.engine.getComponent(stop.stationGroup, api.type.ComponentType.STATION_GROUP)
					local station = api.engine.getComponent(sg.stations[stop.station + 1], api.type.ComponentType.STATION)
					local term = station.terminals[stop.terminal + 1]
					for _, ts in ipairs(term.cargoTransferSpeeds or {}) do
						local match = false
						for _, cls in ipairs(ts.cargoTypeSet.cargoClassesIncluded or {}) do
							if (cls == "UNIVERSAL" and not isPax) then match = true end
							for _, mine in ipairs(cargoClasses) do
								if cls == mine then match = true end
							end
						end
						if match and type(ts.loadSpeedModifier) == "number" and ts.loadSpeedModifier > m then
							m = ts.loadSpeedModifier
						end
					end
				end)
				mods[i] = m
			end
		end)
		return mods
	end

	-- cargo class tags of the cargo types a new consist will carry on the line
	local function newConsistCargoClasses(lineTypes, capsByType)
		local classes, seen = {}, {}
		local pax = passengerId()
		pcall(function()
			for _, t in ipairs(lineTypes or {}) do
				if capsByType == nil or (type(capsByType[t]) == "number" and capsByType[t] > 0) then
					if t == pax then
						if not seen.PASSENGERS then seen.PASSENGERS = true; classes[#classes + 1] = "PASSENGERS" end
					else
						local ct = api.res.cargoTypeRep.get(t)
						for _, tag in ipairs(ct.cargoClasses or {}) do
							if not seen[tag] then seen[tag] = true; classes[#classes + 1] = tag end
						end
					end
				end
			end
		end)
		return classes
	end

	local function vehicleCarrier(vehicle)
		local c = nil
		pcall(function()
			local tv = api.engine.getComponent(vehicle, api.type.ComponentType.TRANSPORT_VEHICLE)
			c = tv and tv.carrier or nil
		end)
		return c
	end

	-- Cargo kind of a vehicle: "pax" (passengers only) or "cargo" (any freight
	-- capacity), nil if unknown. Buses and trucks share the ROAD carrier but
	-- have very different stop patterns, so the calibration prefers reference
	-- lines of the same kind and falls back to the whole carrier.
	-- caps: {cargoTypeId : capacity}; oneBased = true for tv.config.capacities (index = id + 1)
	local function kindOfCaps(caps, oneBased)
		if type(caps) ~= "table" then return nil end
		local pax, any = passengerId(), false
		for k, cap in pairs(caps) do
			if type(cap) == "number" and cap > 0 then
				any = true
				if (oneBased and (k - 1) or k) ~= pax then return "cargo" end
			end
		end
		return any and "pax" or nil
	end

	local function vehicleKind(vehicle)
		local kind = nil
		pcall(function()
			local tv = api.engine.getComponent(vehicle, api.type.ComponentType.TRANSPORT_VEHICLE)
			kind = tv and kindOfCaps(tv.config.capacities, true) or nil
		end)
		return kind
	end

	-- Calibration over the player's lines of one carrier and cargo kind (cached for 10 s):
	-- { k = mean(rate*cycle/capacity), f = mean(length/(travel*topSpeed)), n = lines, kind = "pax"|"cargo"|"all" }
	-- cycle = frequency x vehicles (the game's round trip), travel = sum of the
	-- engine's section times (pure driving), so f is a straight-line speed factor
	-- free of dwell times.
	local calibCache = {}
	local function calibration(carrier, kind)
		local key = tostring(carrier) .. ":" .. tostring(kind)
		local cached = calibCache[key]
		if cached and cached.until_ > os.time() then return cached.value end
		local all, same = { k = 0, f = 0, n = 0, samples = {} }, { k = 0, f = 0, n = 0, samples = {} }
		local total, sameCarrier, skipped = 0, 0, { stats = 0, freq = 0, len = 0, top = 0, travel = 0 }
		local okC, errC = pcall(function()
			local player = api.engine.util.getPlayer()
			local lines = api.engine.system.lineSystem.getLinesForPlayer(player)
			for _, line in ipairs(lines) do
				total = total + 1
				local vs = api.engine.system.transportVehicleSystem.getLineVehicles(line)
				if type(vs) == "table" and #vs > 0 and vehicleCarrier(vs[1]) == carrier then
					sameCarrier = sameCarrier + 1
					local st = lineStats(line)
					local okF, freq = pcall(line_util.calculateFrequencySeconds, line)
					local len, nStops = lineStraightLength(line)
					local top = lineReferenceSpeed(line)
					local travel = lineTravelSeconds(line)
					if not (st and st.rate > 0 and st.capacity > 0) then
						skipped.stats = skipped.stats + 1
					elseif not (okF and type(freq) == "number" and freq > 0) then
						skipped.freq = skipped.freq + 1
						if not okF then roughLog("calculateFrequencySeconds failed: " .. tostring(freq)) end
					elseif not (len and len > 0) then
						skipped.len = skipped.len + 1
					elseif not (top and top > 0) then
						skipped.top = skipped.top + 1
					elseif not (travel and travel > 0) then
						skipped.travel = skipped.travel + 1
					else
						local cycle = freq * #vs
						local k, f = st.rate * cycle / st.capacity, len / (travel * top)
						local sample = { len = len, top = top, stops = nStops, travel = travel }
						all.k, all.f, all.n = all.k + k, all.f + f, all.n + 1
						all.samples[#all.samples + 1] = sample
						if kind ~= nil and vehicleKind(vs[1]) == kind then
							same.k, same.f, same.n = same.k + k, same.f + f, same.n + 1
							same.samples[#same.samples + 1] = sample
						end
					end
				end
			end
		end)
		if not okC then roughLog("calibration failed: " .. tostring(errC)) end
		local value = nil
		-- the travel model needs a handful of lines; prefer the same kind, else the carrier
		if same.n >= rate_model.MIN_FIT_SAMPLES or (same.n > 0 and all.n < rate_model.MIN_FIT_SAMPLES) then
			value = { k = same.k / same.n, f = same.f / same.n, n = same.n, kind = kind, travel = rate_model.fitTravel(same.samples) }
		elseif all.n > 0 then
			value = { k = all.k / all.n, f = all.f / all.n, n = all.n, kind = "all", travel = rate_model.fitTravel(all.samples) }
		end
		if value and value.travel == nil then value = nil end
		calibCache[key] = { value = value, until_ = os.time() + 10 }
		roughLog(string.format("calibration carrier=%s kind=%s: lines=%d sameCarrier=%d sameKind=%d used=%d(%s) skipped(stats=%d freq=%d len=%d top=%d travel=%d) k=%s f=%s",
			tostring(carrier), tostring(kind), total, sameCarrier, same.n, value and value.n or 0, value and value.kind or "-",
			skipped.stats, skipped.freq, skipped.len, skipped.top, skipped.travel,
			value and string.format("%.3g", value.k) or "-", value and string.format("%.3g", value.f) or "-")
			.. (value and string.format(" travel[%s]: p=%.3f q=%.4f b=%.1f", value.travel.mode, value.travel.p, value.travel.q, value.travel.b) or ""))
		return value
	end

	-- Estimated rate for a new consist on the (empty) line, or nil.
	-- consist = { capacity, topSpeed (m/s), kind = "pax"|"cargo", loadSpeed, cargoClasses }
	-- cycle = straight-line round trip / (f x top speed) + dwell time of every
	-- stop (door times, waiting, loading at the terminal's load speed modifier),
	-- see rate_model.lua; rate = capacity x k / cycle.
	local DEFAULT_LOAD_SPEED = { pax = 3, cargo = 5 }
	local function roughRate(line, carrier, consist)
		if not roughEnabled then return nil end
		local capacity, topSpeed, kind = consist.capacity, consist.topSpeed, consist.kind
		if capacity <= 0 or type(topSpeed) ~= "number" or topSpeed <= 0 or topSpeed == math.huge then
			roughLog("line " .. tostring(line) .. ": capacity=" .. tostring(capacity) .. " topSpeed=" .. tostring(topSpeed) .. " -> no estimate")
			return nil
		end
		if carrier == nil then
			roughLog("line " .. tostring(line) .. ": carrier unknown -> no estimate")
			return nil
		end
		kind = kind or "cargo"
		local cal = calibration(carrier, kind)
		local len, nStops = lineStraightLength(line)
		if not cal or not len or not nStops or nStops < 1 then
			roughLog("line " .. tostring(line) .. ": cal=" .. tostring(cal and cal.n) .. " len=" .. tostring(len) .. " -> no estimate")
			return nil
		end
		local loadSpeed = consist.loadSpeed
		if type(loadSpeed) ~= "number" or loadSpeed <= 0 then loadSpeed = DEFAULT_LOAD_SPEED[kind] end
		local classes = consist.cargoClasses
		if type(classes) ~= "table" or #classes == 0 then classes = { kind == "pax" and "PASSENGERS" or "UNIVERSAL" } end
		local mods = lineTerminalModifiers(line, classes)
		local penalties = {}
		for i = 1, nStops do penalties[i] = rate_model.penalty(mods[i], 1) end
		-- the dwell model is per vehicle: several vehicles load in parallel on their own stops
		local perVehicle = capacity / math.max(1, consist.vehicles or 1)
		local stops = rate_model.stopsForNewLine(kind, perVehicle, loadSpeed, penalties)
		local travel = rate_model.travelSeconds(len, topSpeed, nStops, cal.travel)
		local cycle = rate_model.cycleSeconds(len, topSpeed, stops, cal.travel)
		local rate = rate_model.rate(capacity, cal.k, cycle)
		if rate == nil or travel == nil then
			roughLog("line " .. tostring(line) .. ": travel model gave nil -> no estimate")
			return nil
		end
		local modsText = {}
		for i = 1, nStops do modsText[i] = tostring(mods[i] or "?") end
		roughLog(string.format("line %s: len=%.0f m stops=%d topSpeed=%.1f m/s travel=%.0f s dwell=%.0f s cycle=%.0f s capacity=%d/%d kind=%s loadSpeed=%s classes=%s termMods=[%s] cal=%s/%d k=%.0f travel[%s] -> rate %.1f",
			tostring(line), len, nStops, topSpeed, travel, cycle - travel, cycle, capacity, consist.vehicles or 1, kind, tostring(loadSpeed),
			table.concat(classes, "+"), table.concat(modsText, ","), cal.kind, cal.n, cal.k, cal.travel.mode, rate))
		return rate
	end

	local function rateText(newCapacityTotal, oldCapacityOverride, newSpeed, newConsist)
		if ctx == nil then
			return nil
		end
		local stats = lineStats(ctx.line)
		if stats == nil then
			return nil
		end
		if stats.count == 0 and newCapacityTotal > 0 then
			local consist = newConsist or {}
			consist.capacity, consist.topSpeed = newCapacityTotal, newSpeed
			local okR, rough = pcall(roughRate, ctx.line, ctx.carrier, consist)
			if not okR then roughLog("roughRate failed: " .. tostring(rough)) end
			if okR and rough then
				return "≈ " .. formatInt(rough) .. " " .. _("rate_rough")
			end
		end
		if stats.count == 0 or stats.capacity <= 0 or stats.rate <= 0 then
			local msg = string.format("[rate_preview] line %s: vehicles=%d capacity=%d rate=%s -> n/a",
				tostring(ctx.line), stats.count, stats.capacity, tostring(stats.rate))
			if msg ~= lastNaLog then
				lastNaLog = msg
				log.message(msg)
			end
			return _("rate_no_vehicles")
		end
		local futureCap = stats.capacity - (oldCapacityOverride or ctx.oldCapacity) + newCapacityTotal
		if futureCap < 0 then futureCap = 0 end
		local estimate = stats.rate * futureCap / stats.capacity
		return formatInt(stats.rate) .. "  →  ≈ " .. formatInt(estimate)
	end

	---------------------------------------------------------------------------
	-- hooks
	---------------------------------------------------------------------------
	if not builtin._kampfmoehreRatePreviewOrig then
		builtin._kampfmoehreRatePreviewOrig = true

		-- 1) target line for "Buy Vehicles" from the manager window
		local origBestDepot = line_util.getBestDepotForLine
		line_util.getBestDepotForLine = function(line, ...)
			pendingBuyLine = isEntity(line) and line or nil
			return origBestDepot(line, ...)
		end

		-- 2) store context from the open events
		local origFire = react.fireEvent
		react.fireEvent = function(a, name, param, ...)
			if name == "buyVehicles" or name == "replaceVehicles" or name == "modifyVehicles" then
				local ok, result = pcall(contextFromEvent, name, param)
				ctx = ok and result or nil
				if not ok then
					log.warning("[rate_preview] context failed: " .. tostring(result))
				end
				log.message(string.format("[rate_preview] %s -> line=%s mode=%s oldCap=%s n=%s",
					tostring(name), tostring(ctx and ctx.line), tostring(ctx and ctx.mode),
					tostring(ctx and ctx.oldCapacity), tostring(ctx and ctx.replaceCount)))
			end
			return origFire(a, name, param, ...)
		end

		-- 3) cart: one record per entry {cap, checked}, the amount, the bottom bar.
		-- Per entry the base code calls makeMultipleVehiclesFromParts ->
		-- collectVehicleData -> (CheckBox, only in Modify with >1 entries) ->
		-- TableLayout{-1,-1}. The select-all CheckBox comes after the last entry.
		local cartParts = nil
		local cartEntries = {}
		local pendingEntry = nil
		local cartAmount = 1

		-- Summed loadSpeed of the parts that have capacity (wagons load in
		-- parallel); nil if the vehicle list cannot be read.
		local function consistLoadSpeed(vehicles)
			local sum, any = 0, false
			local ok = pcall(function()
				for _, v in ipairs(vehicles) do
					local tv = v.tv
					local cap = 0
					for _, comp in ipairs(tv.compartments or {}) do
						for _, lc in ipairs(comp.loadConfigs or {}) do
							cap = cap + ((lc.cargoEntry and lc.cargoEntry.capacity) or 0)
						end
					end
					if cap > 0 and type(tv.loadSpeed) == "number" then
						sum, any = sum + tv.loadSpeed, true
					end
				end
			end)
			return (ok and any) and sum or nil
		end

		local origMake = vehicle_store_util.makeMultipleVehiclesFromParts
		local cartPartsFingerprint = nil
		vehicle_store_util.makeMultipleVehiclesFromParts = function(vehicleParts, ...)
			local result = origMake(vehicleParts, ...)
			cartParts = result
			local ok, fp = pcall(partsFingerprint, vehicleParts)
			cartPartsFingerprint = ok and fp or nil
			return result
		end
		local origCollect = vehicle_store_util.collectVehicleData
		vehicle_store_util.collectVehicleData = function(vehicles, ...)
			local result = origCollect(vehicles, ...)
			if cartParts ~= nil and vehicles == cartParts then
				cartParts = nil
				pendingEntry = {
					-- plain top speed: new vehicles have no maintenance penalty, and
					-- speedAdjusted is math.huge when no modifiers were passed
					speed = (type(result) == "table" and result.speed) or nil,
					cap = (type(result) == "table" and result.totalCapacity) or 0,
					loadingSpeed = consistLoadSpeed(vehicles) or (type(result) == "table" and result.loadingSpeed) or nil,
					capCargo = (type(result) == "table" and result.totalCapacityCargo) or 0,
					allCargoTypes = (type(result) == "table" and result.allCargoTypes) or nil,
					fingerprint = cartPartsFingerprint,
					checked = nil,
				}
			end
			return result
		end
		local origCheckBox = builtin.CheckBox
		builtin.CheckBox = function(...)
			local params = lastArg(...)
			if pendingEntry ~= nil and pendingEntry.checked == nil and type(params) == "table" and type(params.value) == "number" then
				pendingEntry.checked = (params.value ~= 0)
			end
			return origCheckBox(...)
		end
		local origTable = builtin.TableLayout
		builtin.TableLayout = function(...)
			local params = lastArg(...)
			if pendingEntry ~= nil and type(params) == "table" and type(params.columnWeights) == "table"
				and #params.columnWeights == 2 and params.columnWeights[1] == -1 and params.columnWeights[2] == -1 then
				cartEntries[#cartEntries + 1] = pendingEntry
				pendingEntry = nil
			end
			return origTable(...)
		end
		local origSpin = builtin.DoubleSpinBox
		builtin.DoubleSpinBox = function(...)
			local params = lastArg(...)
			if type(params) == "table" and params.min == 1 and params.max == 99 and type(params.value) == "number" then
				cartAmount = params.value
			end
			return origSpin(...)
		end

		local lastShownVehicleData = nil -- from the detail panel (single-vehicle carriers)

		-- Replace/Modify: the cart initially shows the current consists; remember
		-- their fingerprints once and only estimate after something changed.
		local function cartEdited()
			if ctx.initialFingerprints == nil then
				ctx.initialFingerprints = {}
				for i, e in ipairs(cartEntries) do ctx.initialFingerprints[i] = e.fingerprint end
				return false
			end
			if #cartEntries ~= #ctx.initialFingerprints then return true end
			for i, e in ipairs(cartEntries) do
				if e.fingerprint ~= ctx.initialFingerprints[i] then return true end
			end
			return false
		end

		local function bottomBarText()
			if ctx == nil then
				return nil
			end
			local kind = lineCargoTypes(ctx.line)
			-- speed of the new consist: slowest cart entry, or the shown vehicle
			local newSpeed = nil
			for _, e in ipairs(cartEntries) do
				if type(e.speed) == "number" and e.speed > 0 and e.speed ~= math.huge and (newSpeed == nil or e.speed < newSpeed) then newSpeed = e.speed end
			end
			if newSpeed == nil and lastShownVehicleData then
				newSpeed = lastShownVehicleData.speed
			end
			-- cargo kind, load speed and cargo classes of the new consist (rough estimate)
			local newKind, newLoadSpeed, newCaps = nil, nil, nil
			for _, e in ipairs(cartEntries) do
				local k = kindOfCaps(e.allCargoTypes, false)
				if k == "cargo" or (k == "pax" and newKind == nil) then newKind = k end
				if type(e.loadingSpeed) == "number" and e.loadingSpeed > 0 and (newLoadSpeed == nil or e.loadingSpeed < newLoadSpeed) then
					newLoadSpeed = e.loadingSpeed
				end
				newCaps = newCaps or e.allCargoTypes
			end
			if newKind == nil and lastShownVehicleData then
				newKind = kindOfCaps(lastShownVehicleData.allCargoTypes, false)
				newLoadSpeed = lastShownVehicleData.loadingSpeed
				newCaps = lastShownVehicleData.allCargoTypes
			end
			local newConsist = { kind = newKind, loadSpeed = newLoadSpeed, cargoClasses = newConsistCargoClasses(kind, newCaps),
				vehicles = (ctx.mode == "Replace") and ctx.replaceCount or math.max(1, cartAmount or 1) }
			-- Modify starts with the current consists -> estimate only after an edit.
			-- Replace starts with the first list entry, so every selection counts.
			if ctx.mode == "Modify" and #cartEntries > 0 and not cartEdited() then
				local stats = lineStats(ctx.line)
				if stats == nil or stats.rate <= 0 then return nil end
				return _("Line rate") .. ": " .. formatInt(stats.rate)
			end
			local text
			if ctx.mode == "Modify" then
				-- only checked entries are modified; entry i belongs to vehicle i
				if #cartEntries == 0 then return nil end
				local newCap, oldCap = 0, 0
				for i, e in ipairs(cartEntries) do
					if e.checked ~= false then
						newCap = newCap + relevantCapacity(e, kind)
						oldCap = oldCap + ((ctx.oldCaps and ctx.oldCaps[i]) or 0)
					end
				end
				text = rateText(newCap, oldCap)
			else
				local baseCap = nil
				if #cartEntries > 0 then
					baseCap = 0
					for _, e in ipairs(cartEntries) do baseCap = baseCap + relevantCapacity(e, kind) end
				elseif not vehicle_store_util.acceptsMultiVehicle(ctx.carrier) and lastShownVehicleData then
					baseCap = relevantCapacity(lastShownVehicleData, kind)
				end
				if baseCap == nil then return nil end
				if ctx.mode == "Replace" then
					text = rateText(baseCap * ctx.replaceCount, nil, newSpeed, newConsist)
				else
					text = rateText(baseCap * cartAmount, nil, newSpeed, newConsist)
					local added = math.max(1, #cartEntries) * cartAmount
					local freq = frequencyText(added)
					if text and freq then
						text = text .. "      " .. _("Frequency") .. ": " .. freq
					end
				end
			end
			if text == nil then return nil end
			local okH, hint = pcall(speedHint, newSpeed, ctx.line)
			return _("Line rate") .. ": " .. text .. ((okH and hint) or "")
		end

		-- the bar's stretch spacer sits right before the buy button; remember the
		-- most recent spacer node so our text can be inserted in front of it
		local lastSpacer = nil
		local origSpacer = gui_react_util.makeHorizontalSpacer
		gui_react_util.makeHorizontalSpacer = function(...)
			local node = origSpacer(...)
			lastSpacer = node
			return node
		end

		-- 4) detail panel: registry of list vehicleData + render markers
		local knownVehicleData = {}
		local statsActive = false
		local statsWeight, statsLength = nil, nil
		local statsVerticalCount = 0
		local labelTopSpeed, labelWeight, labelLength = _("Top Speed"), _("Weight"), _("Length")

		local origMakeVehicleData = vehicle_store_util.makeVehicleData
		vehicle_store_util.makeVehicleData = function(...)
			local vd = origMakeVehicleData(...)
			if type(vd) == "table" then
				knownVehicleData[#knownVehicleData + 1] = vd
				if #knownVehicleData > 4000 then
					table.remove(knownVehicleData, 1)
				end
			end
			return vd
		end
		local origProgressRow = vehicle_store_util.makeVehicleProgressBarRow
		vehicle_store_util.makeVehicleProgressBarRow = function(icon, tooltip, ...)
			if tooltip == labelTopSpeed then
				statsActive = true
				statsWeight, statsLength = nil, nil
				statsVerticalCount = 0
			end
			return origProgressRow(icon, tooltip, ...)
		end
		local origPropertyRow = vehicle_store_util.makeVehiclePropertyRow
		vehicle_store_util.makeVehiclePropertyRow = function(tooltip, text, icon, value, ...)
			if statsActive then
				if tooltip == labelWeight then statsWeight = value end
				if tooltip == labelLength then statsLength = value end
			end
			return origPropertyRow(tooltip, text, icon, value, ...)
		end

		local function findShownVehicleData()
			if statsWeight == nil or statsLength == nil then
				return nil
			end
			for i = #knownVehicleData, 1, -1 do
				local c = knownVehicleData[i]
				if c.weight == statsWeight and c.length == statsLength then
					return c
				end
			end
			return nil
		end

		-- 5) layout hooks
		local origBox = builtin.BoxLayout
		builtin.BoxLayout = function(...)
			local params = lastArg(...)
			if type(params) == "table" then
				-- cart bottom bar: insert before the stretch spacer (i.e. after the
				-- select-all checkbox / "Vehicles To Replace" widget), else at the end
				if params.meta and params.meta.class == "bottom-bar-layout" and type(params.children) == "table" then
					-- we are inside the VehicleCart recipe: re-render it every few
					-- seconds so the rate follows the game (e.g. right after a purchase)
					pcall(function()
						local tick = react.useState(0)
						react.onStepTimer(function()
							tick:set(tick:old() + 1)
						end, 3)
					end)
					local ok, text = pcall(bottomBarText)
					cartEntries, pendingEntry = {}, nil
					if ok and text then
						local node = builtin.TextView{
							meta = { class = "font-scale-body" },
							text = "   " .. text .. "   ",
						}
						local pos = #params.children + 1
						for i, child in ipairs(params.children) do
							if child == lastSpacer then pos = i break end
						end
						table.insert(params.children, pos, node)
					elseif not ok then
						log.warning("[rate_preview] bottom bar failed: " .. tostring(text))
					end
				end
				-- detail panel right column: identify the shown vehicle
				if statsActive and params.orientation == builtin.type.Orientation.Vertical and type(params.children) == "table" then
					statsVerticalCount = statsVerticalCount + 1
					if statsVerticalCount == 2 then
						statsActive = false
						local ok, vd = pcall(findShownVehicleData)
						if ok then lastShownVehicleData = vd end
					end
				end
			end
			return origBox(...)
		end

		log.message("[rate_preview] v" .. VERSION .. " hooks installed")
	end


	local rate_preview = {}
	rate_preview.EntryPlugin = react.RegisterPluginRecipe(
		{ id = "::ModEntryPointExtension" }, "KampfmoehreRatePreviewEntry",
		function()
			react.onMount(function()
				roughEnabled = false
				calibCache = {}
				local ok, all = pcall(api.engine.config.getModParams)
				local mine = ok and type(all) == "table" and all["kampfmoehre_rate_preview_1"] or nil
				if type(mine) == "table" and mine.roughEstimate == 2 then roughEnabled = true end
				log.message("[rate_preview] rough estimate for empty lines: " .. tostring(roughEnabled))
			end)
			return builtin.BoxLayout{ children = {} }
		end)
	return rate_preview
end
