local ssu = require "::/gui/main/stylesheetutil.lua"

-- Styles for the Auto-signal tool (ntools_signals_tool.script.tl). The panel it runs in is styled
-- in ntools_connect_tool.css.lua.
function data()
	local result = { }
	local a = ssu.makeAdder(result)

	-- Key prompt list (pattern from the MoveIt mod). "R::<recipe>" is the tool's recipe name.
	a("!input-mouse R::NtoolsSignalsAction", {
		actionPromptList = {
			{ ia = "IA_MENU_BACK", sortKey = "ntools-0" },
			{ ia = "constructOpt7", sortKey = "ntools-1" },
			{ ia = "constructOpt8", sortKey = "ntools-2" },
		},
	})

	return result
end