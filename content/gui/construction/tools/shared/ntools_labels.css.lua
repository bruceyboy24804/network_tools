local ssu = require "::/gui/main/stylesheetutil.lua"

-- Segment / node labels (ntools_labels.script.tl). The tag's box (tooltip surface, colour, padding,
-- anchor) and its icons' size are inline styles in the script (boxStyle / iconStyle) - not rules here:
-- the game limits the total number of stylesheet rules across all mods. What's left can't be inline.
function data()
	local result = { }
	local a = ssu.makeAdder(result)

	-- the full-screen layer the tags float on: stretched to fill the screen (gravity -1 = fill, as
	-- the game's callout layer: FloatingLayoutChild h = -1, v = -1), so a tag's h / v is a share of it
	a("R::NtoolsLabelOverlay", { gravity = { -1, -1 } })
	a("FloatingLayout!ntools-label-layer", { gravity = { -1, -1 } })

	return result
end
