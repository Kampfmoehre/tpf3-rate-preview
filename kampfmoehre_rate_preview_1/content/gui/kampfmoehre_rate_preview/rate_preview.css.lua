local ssu = require "::/gui/main/stylesheetutil.lua"

-- Our text block inside the cart entry (Replace mode, see rate_preview.script.lua):
-- bottom right, left of the entry's delete button.
function data()
	local result = {}
	local a = ssu.makeAdder(result)

	a("R::VehicleCart !vehicle-list-container BoxLayout!kampfmoehre-rate-cart", {
		gravity = { 1, 1 },
	})

	return result
end
