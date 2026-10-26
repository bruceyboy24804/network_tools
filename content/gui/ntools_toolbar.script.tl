-- Network Tools toolbar button (top-left, next to the other mod buttons - pattern from the
-- Timetables mod). Toggles the Network Tools panel, which lists the tools and runs them directly.

local builtin = ug_require "::/gui/main/builtin.lua" as Builtin
local main_mod_button_area = ug_require "::/gui/main/main_mod_button_area.tl" as MainModButtonArea
local react = ug_require "::/gui/main/react.lua" as React

-- Same module name the construction menu loads it under, so both share one instance.
local connect = require "network_tools_1::/gui/construction/tools/connect/ntools_connect_tool.script.tl" as table

-- the gap to the button before ours, as left padding on our row (a margin on the button had no effect
-- in the mod button area); inline, not a stylesheet rule - the game limits the total number of
-- stylesheet rules across all mods
local okRow, rowSheet = pcall(function() : StyleSheet
	local s = api.gui.StyleSheet.new()
	s.padding = api.type.Vec4f.new(0, 0, 0, 10)
	return s
end)

local togglePanel = connect.togglePanel as function(boolean)
local isPanelOpen = connect.isPanelOpen as function() : boolean
local NetworkToolsButton = react.RegisterPluginRecipe(
	main_mod_button_area.MainModButtonAreaExtension,
	"NetworkToolsButton",
	function() : TreeNodeId
		-- follows the panel, which can also close by its X button or Escape: plain state plus an
		-- onStep poll (as the game's TileElement), NOT engine_react_util.useStepState - Visual Auto
		-- Namer replaces useStepState with a wrapper that asks react.getCurrentRecipeName(), and in
		-- this toolbar plugin that crashed the game natively on the first in-game frame (2026-10-11;
		-- the Timetables button, built with useState, was fine)
		local openState = react.useState(false) as ReactStateT<boolean>
		react.onStep(function()
			local open = isPanelOpen() == true
			if openState:old() ~= open then openState:set(open) end
		end)
		return builtin.BoxLayout{
			meta = { styleSheet = okRow and rowSheet or nil },
			children = {
				builtin.ToggleButton{
					meta = { tooltip = _("Network Tools"), class = "ntools-toolbar-btn" },
					content = builtin.ImageView{
						meta = { class = "ntools-toolbar-icon" },
						path = "network_tools_1::/gui/icons/ntools_toolbar.tga",
						scaling = builtin.type.ImageViewScaling.AutoFit,
					},
					value = (openState:old() == true) and 1 or 0,
					onValueChange = function(value : integer)
						togglePanel(value == 1)
					end,
				},
			},
		}
	end
)

return {
	NetworkToolsButton = NetworkToolsButton,
}
