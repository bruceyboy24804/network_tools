local ssu = require "::/gui/main/stylesheetutil.lua"

-- Key prompt lists of the Connect tool. The Network Tools panel's styles are in
-- panel/ntools_panel.css.lua.
function data()
	local result = { }
	local a = ssu.makeAdder(result)

	------------------------------------------------------------------------------------------------
	-- Key prompt lists (pattern from the MoveIt mod). "R::<recipe>" is the tool's recipe name.
	-- Entries without `text` use the prompt supplied by the recipe's input-action handler,
	-- and the engine shows the player's current key bindings.

	a("!input-mouse R::NtoolsConnectAction", {
		actionPromptList = {
			{ ia = "IA_MENU_BACK", sortKey = "ntools-0" },
			-- pairs (same prompt text from the recipe) share one row, keys in the game's order
			{ ia = "constructLower", sortKey = "ntools-1a" },
			{ ia = "constructRaise", sortKey = "ntools-1b" },
			{ ia = "constructOpt5", sortKey = "ntools-2a" },
			{ ia = "constructOpt6", sortKey = "ntools-2b" },
			{ ia = "constructOpt7", sortKey = "ntools-5a" },
			{ ia = "constructOpt8", sortKey = "ntools-5b" },
			{ ia = "constructAlignToTerrain", sortKey = "ntools-7" },
			{ ia = "constructNoSnap", sortKey = "ntools-8" },
			{ ia = "IA_PRECISION_MODE", text = _("(Hold) Fine steps, mouse controls in the tooltip"), sortKey = "ntools-9" },
			{ ia = "constructOpt2", sortKey = "ntools-10" },
		},
	})

	-- (on a game controller: the shared list for every tool, panel/ntools_panel.css.lua)

	-- the Parallel tool's prompt list is in ntools_parallel_tool.css.lua

	------------------------------------------------------------------------------------------------
	-- The tools' cursor tooltip (NtoolsTooltip in the connect tool script): the headline on the
	-- game's coloured tape, the details on a dark tape of the same shape below it. (Text views
	-- draw backgrounds - a BoxLayout behind them does not.)
	-- (the headline's padding is inline, in the connect tool script: tipHeadSheet)
	-- one rule for both selectors, as the game writes them
	a([[!ntools-tip-body,
		!ntools-tip-cost]], {
		backgroundImage1 = { fileName = "::/gui/builtin/button/default_surface.tga", horizontal = { 0, 9, 21, 30 }, vertical = { 0, 9, 21, 30 } },
		backgroundColor1 = { 0.06, 0.07, 0.08, 0.86 },
		color = { 0.86, 0.88, 0.90, 1 },
		padding = { 5, 10, 6, 10 },
		margin = { 3, 0, 0, 0 },
	})
	-- the controls: the details' dark tape (ntools-tip-body), set apart by a gap, in dimmer text
	a("!ntools-tip-keys", {
		margin = { 10, 0, 0, 0 },
		color = { 0.70, 0.73, 0.76, 1 },
	})

	return result
end
