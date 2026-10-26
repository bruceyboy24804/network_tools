-- "Track upgrade" in the Network Tools tab of the Roads / Tracks build menus. The definition lives in
-- the connect tool's script, where every tool module is loaded and handed its helpers.
function data()
	return {
		type = "construction_tool",
		data = {
			getDefinitionFn = {
				fileName = "network_tools_1::/gui/construction/tools/connect/ntools_connect_tool.script@getUpgradeDefinition",
			}
		}
	}
end
