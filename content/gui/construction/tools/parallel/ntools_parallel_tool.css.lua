local ssu = require "::/gui/main/stylesheetutil.lua"

-- Styles for the Parallel tool (ntools_parallel_tool.script.tl). The panel it runs in is styled
-- in ntools_connect_tool.css.lua.
function data()
	local result = { }
	local a = ssu.makeAdder(result)

	------------------------------------------------------------------------------------------------
	-- Key prompt list (pattern from the MoveIt mod). "R::<recipe>" is the tool's recipe name.
	-- Entries without `text` use the prompt supplied by the recipe's input-action handler,
	-- and the engine shows the player's current key bindings.

	a("!input-mouse R::NtoolsParallelAction", {
		actionPromptList = {
			{ ia = "IA_MENU_BACK", sortKey = "ntools-0" },
			{ ia = "constructRaise", sortKey = "ntools-1" },
			{ ia = "constructLower", sortKey = "ntools-2" },
			{ ia = "constructOpt6", sortKey = "ntools-3" },
			{ ia = "constructOpt5", sortKey = "ntools-4" },
			{ ia = "constructOpt7", sortKey = "ntools-5" },
			{ ia = "constructOpt8", sortKey = "ntools-6" },
			{ ia = "IA_PRECISION_MODE", text = _("(Hold) Fine steps"), sortKey = "ntools-9" },
		},
	})

	return result
end
