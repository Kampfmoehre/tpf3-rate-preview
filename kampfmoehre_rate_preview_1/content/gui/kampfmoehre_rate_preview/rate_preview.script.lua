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
	local VERSION = "0.11.0"

	local react = ug_require "::/gui/main/react.lua"
	local builtin = ug_require "::/gui/main/builtin.lua"
	local vehicle_store_util = ug_require "::/gui/line_vehicle_mgmt/vehicle_store_util.tl"
	local line_util = ug_require "::/gui/line_vehicle_mgmt/line_util.tl"
	local gui_react_util = ug_require "::/gui/main/gui_react_util.tl"
	local statistics_react_util = ug_require "::/gui/statistics/statistics_react_util.tl"
	local cargo_util = ug_require "::/gui/main/cargo_util.tl"

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
	-- per-type sum is capped at the physical capacity (freight-only when the
	-- line carries no passengers).
	local function relevantCapacity(e, types)
		if e == nil then return 0 end
		local total = e.cap or e.totalCapacity or 0
		local all = e.allCargoTypes
		if types == nil or type(all) ~= "table" then
			return total
		end
		local okP, paxId = pcall(cargo_util.getPassengerCargoTypeId)
		paxId = (okP and type(paxId) == "number") and paxId or 0
		local sum, any, linePax = 0, false, false
		for _, t in ipairs(types) do
			if t == paxId then linePax = true end
			local c = all[t]
			if type(c) == "number" then
				sum = sum + c
				any = true
			end
		end
		if not any then
			return total
		end
		local limit = total
		if not linePax then
			local cargoOnly = e.capCargo or e.totalCapacityCargo
			if type(cargoOnly) == "number" and cargoOnly > 0 then limit = cargoOnly end
		end
		return math.min(sum, limit)
	end

	-- fingerprint of a cart entry's parts (model ids), to detect edits in
	-- Replace/Modify mode where the cart starts out as the current consist
	local function partsFingerprint(vehicleParts)
		local ids = {}
		if type(vehicleParts) == "table" then
			for _, list in ipairs(vehicleParts) do
				if type(list) == "table" then
					for _, part in ipairs(list) do
						-- parts are C++ userdata, so read the id guarded instead of type-checking
						local ok, modelId = pcall(function() return part.part.modelId end)
						ids[#ids + 1] = tostring(ok and modelId or "?")
					end
					ids[#ids + 1] = "|"
				end
			end
		end
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
			local line, oldCapacity, oldCaps = nil, 0, {}
			for _, v in ipairs(vehicles) do
				line = line or vehicleLine(v)
				local c = vehicleCapacity(v)
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

	local function rateText(newCapacityTotal, oldCapacityOverride)
		if ctx == nil then
			return nil
		end
		local stats = lineStats(ctx.line)
		if stats == nil then
			return nil
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
					cap = (type(result) == "table" and result.totalCapacity) or 0,
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
			if (ctx.mode == "Replace" or ctx.mode == "Modify") and #cartEntries > 0 and not cartEdited() then
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
					text = rateText(baseCap * ctx.replaceCount)
				else
					text = rateText(baseCap * cartAmount)
					local added = math.max(1, #cartEntries) * cartAmount
					local freq = frequencyText(added)
					if text and freq then
						text = text .. "      " .. _("Frequency") .. ": " .. freq
					end
				end
			end
			if text == nil then return nil end
			return _("Line rate") .. ": " .. text
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
			return builtin.BoxLayout{ children = {} }
		end)
	return rate_preview
end
