local ssu = require "::/gui/main/stylesheetutil.lua"

-- The Network Tools toolbar button (top left, among the mod buttons). Sized like the game's
-- layers button and the Timetables button (32x32, padding 4, 24px glyph). The gap to the button
-- before it (the same as between the layers and Timetables buttons) is left padding on our own
-- row: a margin on the button had no effect in the mod button area. { top, right, bottom, left }.
function data()
	local result = { }
	local a = ssu.makeAdder(result)

	-- (the row's left padding is inline, in ntools_toolbar.script.tl)
	a("R::NetworkToolsButton ToggleButton!ntools-toolbar-btn", {
		size = { 32, 32 },
		minSize = { 32, 32 },
		maxSize = { 32, 32 },
		padding = { 4, 4, 4, 4 },
		margin = { 1, 1, 2, 1 },
		gravity = { 0.5, 0.5 },
	})
	a("R::NetworkToolsButton !ntools-toolbar-icon", {
		size = { 24, 24 },
		minSize = { 24, 24 },
		maxSize = { 24, 24 },
		gravity = { 0.5, 0.5 },
	})

	return result
end
