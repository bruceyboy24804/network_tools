function data()
	return {
		-- Toolbar button next to the other mod buttons (same mechanism as the Timetables mod).
		-- Extension-point ids are "<modId>::<name>"; base-game points are "::<name>".
		type = "react-plugin ::MainModButtonAreaExtension",
		data = {
			filePath = "network_tools_1::/gui/ntools_toolbar.script@NetworkToolsButton",
			order = 20,
		}
	}
end
