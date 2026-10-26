-- "Network Tools" category in the road construction menu. Opened directly by the
-- Network Tools toolbar button (see gui/ntools_toolbar.script.tl).
function data()
	return {
		type = "menu_category",
		data = {
			category = "ntools_road",
			order = 10100,   -- right after the game's Tools tab (10000)
			name = _("Network Tools"),
			icon = resolve("ntools_category.tga"),
			menu = "ROADS",   -- the streets menu ("ROAD" is the road vehicles / stations menu)
		}
	}
end
