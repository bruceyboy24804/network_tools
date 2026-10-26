-- "Network Tools" category in the rail construction menu.
function data()
	return {
		type = "menu_category",
		data = {
			category = "ntools_rail",
			order = 10100,   -- right after the game's Tools tab (10000)
			name = _("Network Tools"),
			icon = resolve("ntools_category.tga"),
			menu = "TRACKS",   -- the tracks menu ("RAIL" is the rail vehicles / stations menu)
		}
	}
end
