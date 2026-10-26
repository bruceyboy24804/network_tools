local ssu = require "::/gui/main/stylesheetutil.lua"

-- Styles for the Network Tools panel (ntools_panel.script.tl: window id ntools.window,
-- content recipe NtoolsPanelContent). Panel styling follows the Timetables mod (see UI_NOTES.md
-- in the mod folder).
function data()
	local result = { }
	local a = ssu.makeAdder(result)

	-- Theme colours, loaded defensively: a failing stylesheet silently removes the mod's UI.
	-- Current builds ship default_colors.gres, older ones default.gres.
	local function readGres(path)
		local ok, data = pcall(function()
			return api.gui.genericRep.get(api.gui.genericRep.find(path)).data
		end)
		return ok and data or nil
	end
	local colors = readGres("::/gui/main/default_colors.gres") or readGres("::/gui/main/default.gres") or {}

	-- the window is sized with `size` (minSize is ignored on windows); no padding here, so the
	-- engine close button keeps its corner
	a("Window#ntools.window", {
		-- wide enough for four tool tiles and name | slider | value rows; tall enough for the tabs
		-- and the longest tool's options (longer ones scroll). 560 (was 460, 2026-10-11): the Structure
		-- row's four buttons ran off the card. The fixed widths inside (slider, switches, notes, chart,
		-- Sections table) grew by the same 100 px
		size = { 560, 720 },
		-- where it opens (and where Reset panel position puts it back), as the Timetables mod places
		-- its window: the window's top-left corner (anchorPoint) at the screen's top left (gravity),
		-- pushed down under the toolbar row its button sits in, and a little in from the edge - the
		-- game offsets its windows the same way (vehicle store: gravity 0, 0 + margin { 75, ... }).
		-- { top, right, bottom, left }, measured off the user's screenshot of where it should sit
		anchorPoint = { 0, 0 },
		gravity = { 0, 0 },
		margin = { 64, 0, 0, 7 },   -- (50 touched the toolbar buttons, which end ~53 px down)
	})
	-- the road / track list window: right beside the panel, a little lower than its top (measured off
	-- the user's screenshot). From the panel's own numbers: left = its left margin 7 + its width
	-- 560 + an 8 px gap; top = its top margin 64 + 30. Change those above and change these with them
	a("Window#ntools.network.window", {
		anchorPoint = { 0, 0 },
		gravity = { 0, 0 },
		margin = { 94, 0, 0, 575 },
	})

	-- the key prompt list (bottom right) of every tool whose only prompt is Back: the panel gives
	-- their recipe nodes this class (ntools_panel.script.tl, toolParams.meta) so one rule serves all
	-- of them. Connect, Parallel and Signals have their own lists in their tool's css.
	a("!input-mouse !ntools-basic-prompts", {
		actionPromptList = {
			{ ia = "IA_MENU_BACK", sortKey = "ntools-0" },
		},
	})
	-- ... and every tool's list on a game controller: shared/ntools_pad gives the tool's recipe node
	-- this class while the pad is in use. Confirm, the option bar, back, then the tools' shortcuts:
	-- the game binds the construct* actions on the pad too (D-pad, LB + D-pad) and Shift (the
	-- precision modifier) is RB held, Ctrl (the game's Flip modifier, IA_SECONDARY_MODE) LB held -
	-- each tool's handler gives the text and hides what doesn't apply
	a("!input-controller !ntools-pad-prompts", {
		actionPromptList = {
			{ ia = "IA_APPLY", sortKey = "ntools-pad-1" },
			{ ia = "IA_OPTION2", sortKey = "ntools-pad-3" },
			{ ia = "IA_MENU_BACK", sortKey = "ntools-pad-4" },
			-- (pairs with the same text share one row, as on the keyboard)
			{ ia = "constructLower", sortKey = "ntools-pad-5a" },
			{ ia = "constructRaise", sortKey = "ntools-pad-5b" },
			{ ia = "constructOpt5", sortKey = "ntools-pad-6a" },
			{ ia = "constructOpt6", sortKey = "ntools-pad-6b" },
			{ ia = "constructOpt7", sortKey = "ntools-pad-7a" },
			{ ia = "constructOpt8", sortKey = "ntools-pad-7b" },
			{ ia = "constructOpt2", sortKey = "ntools-pad-8" },
			{ ia = "constructOpt1", sortKey = "ntools-pad-9" },
			{ ia = "constructAlignToTerrain", sortKey = "ntools-pad-10" },
			{ ia = "IA_PRECISION_MODE", text = _("(Hold) Fine steps; with confirm: the Shift actions"), sortKey = "ntools-pad-11" },
			{ ia = "IA_SECONDARY_MODE", text = _("(Hold) With confirm: the Ctrl actions"), sortKey = "ntools-pad-12" },
		},
	})

	-- the tool tabs keep a margin to the window border (Timetables / the engine's company window)
	a("R::NtoolsPanelContent TabWidget", {
		margin = { 8, 0, 8, 0 },
		gravity = { -1, 0 },
	})
	a("R::NtoolsPanelContent !ntools-tab-body", {
		gravity = { -1, 0 },
		padding = { 6, 6, 6, 6 },
	})
	-- a tool tile: its build-menu icon (16:10) over its name, all tiles the same size
	-- sizes are pinned (size + minSize + maxSize, as Timetables pins its columns): otherwise the
	-- icon keeps its texture's 240 x 150 and the tiles overflow the window
	a("R::NtoolsPanelContent ToggleButton!ntools-tile", {
		-- 4 x (84 + 2 x 6 margin) = 384: fits the tab area, 12 px between tiles
		size = { 84, 62 },
		minSize = { 84, 62 },
		maxSize = { 84, 62 },
		margin = { 4, 6, 4, 6 },
		padding = { 2, 2, 2, 2 },
	})
	-- a toggle button's content centred: tiles and every segmented switch carry this class too, so one
	-- rule does it instead of a "> *" rule per class (the game has a limit on the total number of
	-- stylesheet rules across all mods - see tf3 notes, 2026-10-11 - so every rule saved counts)
	a("R::NtoolsPanelContent ToggleButton!ntools-centred > *", {
		gravity = { 0.5, 0.5 },
	})
	a("R::NtoolsPanelContent !ntools-tile-icon", {
		size = { 48, 30 },
		minSize = { 48, 30 },
		maxSize = { 48, 30 },
		gravity = { 0.5, 0 },
	})
	a("R::NtoolsPanelContent !ntools-tile-label", {
		gravity = { 0.5, 0 },
		padding = { 4, 0, 0, 0 },
	})
	-- compact panel (Settings tab): 5 x (66 + 2 x 5 margin) = 380, the same width as four full tiles
	a("R::NtoolsPanelContent ToggleButton!ntools-tile-compact", {
		size = { 66, 50 },
		minSize = { 66, 50 },
		maxSize = { 66, 50 },
		margin = { 3, 5, 3, 5 },
		padding = { 2, 2, 2, 2 },
	})
	a("R::NtoolsPanelContent !ntools-tile-icon-compact", {
		size = { 36, 22 },
		minSize = { 36, 22 },
		maxSize = { 36, 22 },
		gravity = { 0.5, 0 },
	})
	-- the empty state sits in the middle of the free space
	a("R::NtoolsPanelContent !ntools-empty", {
		gravity = { 0.5, 0.5 },
		padding = { 40, 0, 40, 0 },
	})

	-- padding on the content Component instead
	a("R::NtoolsPanelContent !ntools-content", {
		gravity = { -1, -1 },
		-- { top, right, bottom, left } (CSS order); no top padding: the window title already leaves a gap
		padding = { 0, 12, 12, 12 },
	})

	-- (the section titles' padding, the detail lines' dim colour and the height chart's size are inline
	-- styles in the panel script - cardTitleSheet, dimText, chartStyle - not rules here)

	-- engine card box (same nine-patch surface + contour as the line manager / Timetables)
	local card = {
		backgroundImage1 = {
			fileName = "::/gui/entity_window/design/card_surface.tga",
			horizontal = { 0, 6, 26, 32 },
			vertical = { 0, 6, 26, 32 },
		},
		borderImage = {
			fileName = "::/gui/entity_window/design/card_contour.tga",
			horizontal = { 0, 6, 26, 32 },
			vertical = { 0, 6, 26, 32 },
		},
		gravity = { -1, 0 },
		padding = { 6, 6, 6, 6 },
	}
	if colors.BaseVeryLight then card.borderColor = colors.BaseVeryLight end
	if colors.BaseMedium then card.backgroundColor1 = colors.BaseMedium end
	a("R::NtoolsPanelContent !ntools-card", card)

	-- the options scroll area takes all the height between the Tools card and Reset / Build
	a("R::NtoolsPanelContent !ntools-scroll", {
		gravity = { -1, -1 },
	})
	-- its content spans the width (cards stretch) and fills at least the visible height; the right
	-- gutter keeps the scrollbar off the cards' edges ({ top, right, bottom, left })
	a("R::NtoolsPanelContent !ntools-scroll-content", {
		gravity = { -1, -1 },
		padding = { 0, 10, 0, 0 },
	})

	-- the game's native param row (name | slider | value) has no gaps of its own: pad each of its
	-- direct children 6 px left and right ({ top, right, bottom, left }) -> 12 px between them
	a("R::NtoolsPanelContent !ntools-native > *", {
		padding = { 0, 6, 0, 6 },
	})
	-- imitate the build-menu toolbar's layout (whose stylesheet we can't see): room between rows,
	-- fixed columns for the name and the value so the sliders line up, the slider takes the rest
	a("R::NtoolsPanelContent !ntools-native", {
		padding = { 6, 0, 6, 0 },
		gravity = { -1, 0 },
	})
	a("R::NtoolsPanelContent !ntools-native > TextView", {
		minSize = { 90, 0 },
	})
	a("R::NtoolsPanelContent !ntools-native > Slider", {
		gravity = { -1, 0 },
	})

	-- label / slider / value rows (like the game's street and overpass builders)
	a("R::NtoolsPanelContent !ntools-row", {
		gravity = { -1, 0 },
		padding = { 4, 4, 4, 4 },
	})
	-- fixed label and value columns so the sliders line up; the slider takes the rest
	-- gaps: 12 px after the name, 12 px before the value ({ top, right, bottom, left })
	a("R::NtoolsPanelContent !ntools-row-label", {
		-- the same column as the slider rows' names (ntools-wt-label, 100 px)
		minSize = { 100, 0 },
		gravity = { 0, -1 },
		padding = { 0, 4, 0, 0 },
	})

	-- an explanation line under a control: wraps onto more lines inside the card (a plain TextView
	-- runs off the card's edge). Wrapping needs a fixed width - stretching to the card wasn't enough -
	-- so the card's inner width (4 x 119 px, as the full-width switches)
	a("R::NtoolsPanelContent TextView!ntools-note", {
		size = { 480, -1 },
		textAutoWrap = true,
		padding = { 2, 4, 4, 4 },
	})

	-- slider rows in the style of the game's departure settings (line_vehicle_mgmt.css.lua:
	-- waittime-label 200 px, wrapping; slider a fixed width; the value right after it)
	a("R::NtoolsPanelContent !ntools-wt-row", {
		gravity = { -1, 0 },
		padding = { 5, 4, 5, 4 },
	})
	-- (a narrower name column so the longer slider still fits the panel)
	a("R::NtoolsPanelContent TextView!ntools-wt-label", {
		size = { 100, -1 },
		textAutoWrap = true,
		gravity = { 0, 0.5 },
	})
	a("R::NtoolsPanelContent Slider!ntools-wt-slider", {
		size = { 320, -1 },
		gravity = { 0, 0.5 },
	})
	a("R::NtoolsPanelContent TextView!ntools-wt-value", {
		minSize = { 64, 0 },
		gravity = { 0, 0.5 },
		padding = { 0, 0, 0, 12 },
	})

	-- the options of a segmented switch (Left / Right ...): wide, text centred
	-- 82 px each: four options (Structure: Auto ... Tunnel) beside the name column end with the
	-- dropdowns under them. (Measured in game: each button is 16 px wider than its minSize - its own
	-- padding - and the room after the name column is ~396 px: 4 x (82 + 16) = 392. At 100 they ran
	-- ~70 px off the card)
	a("R::NtoolsPanelContent ToggleButton!ntools-seg-btn", {
		minSize = { 82, 0 },
	})
	-- the same ~392 px for other option counts (each n x (w + 16) ≈ 392), so every switch beside a
	-- name ends where the 4-option ones and the dropdowns do
	a("R::NtoolsPanelContent ToggleButton!ntools-seg-btn2", { minSize = { 180, 0 } })
	a("R::NtoolsPanelContent ToggleButton!ntools-seg-btn3", { minSize = { 114, 0 } })
	a("R::NtoolsPanelContent ToggleButton!ntools-seg-btn5", { minSize = { 62, 0 } })
	a("R::NtoolsPanelContent ToggleButton!ntools-seg-btn6", { minSize = { 49, 0 } })
	-- full-width switches (no name column): 4 x 119 px fills the card (the card's inner width grew
	-- ~91 px with the panel: the old 96 / 128 / 76 plus a quarter / third / fifth of that)
	a("R::NtoolsPanelContent ToggleButton!ntools-seg-btn-wide", {
		minSize = { 119, 0 },
	})
	-- full-width switches with five options: 5 x 94 px fills the card the same way
	a("R::NtoolsPanelContent ToggleButton!ntools-seg-btn-wide5", {
		minSize = { 94, 0 },
	})

	-- sub-options under the option they belong to (Signals: Before splits / its distance under At
	-- switches...): pushed in 22 px; an indented slider is 22 px shorter, so its value still lines up
	-- with the rows above
	a("R::NtoolsPanelContent !ntools-indent", {
		gravity = { -1, 0 },
		padding = { 0, 0, 0, 22 },
	})
	a("R::NtoolsPanelContent !ntools-indent Slider!ntools-wt-slider", {
		size = { 298, -1 },
	})

	-- a card's action button (Settings: Reset panel position, Reset all settings), the game's
	-- "secondary" style: on the left, a little apart from the rows above
	a("R::NtoolsPanelContent Button!ntools-action-btn", {
		gravity = { 0, 0.5 },
		margin = { 6, 4, 2, 4 },
		padding = { 5, 14, 5, 14 },
	})

	-- the footer's Reset / Build: two equal buttons across the panel (~530 px inside the window).
	-- Pinned as the feature toggles (a lone button ignores minSize alone); drawn ~ size + padding +
	-- ~3 px edge: 2 x (236 + 16 + 3) + 2 x 2 x 3 margin = 522
	a("R::NtoolsPanelContent Button!ntools-footer-btn", {
		size = { 236, 26 },
		minSize = { 236, 26 },
		maxSize = { 236, 26 },
		margin = { 4, 3, 0, 3 },
		padding = { 6, 8, 6, 8 },
	})

	-- the game's CollapsibleCheckboxList (Connect's Options): its header a flat, full-width line, as
	-- the mod manager's tag filters style it (mod_browser.css.lua)
	a("R::NtoolsPanelContent R::CollapsibleCheckboxList", {
		gravity = { -1, 0 },
	})
	a("R::NtoolsPanelContent R::CollapsibleCheckboxList Button", {
		gravity = { -1, -1 },
		backgroundImage1 = { fileName = "" },
		borderImage = { fileName = "" },
	})
	a("R::NtoolsPanelContent R::CollapsibleCheckboxList Button:hover", {
		backgroundColor = { 1, 1, 1, 0.06 },
	})
	a("R::NtoolsPanelContent R::CollapsibleCheckboxList Button::Layout > *", {
		gravity = { 0, 0.5 },
	})

	-- sliders span the card
	a("R::NtoolsPanelContent !ntools-slider", {
		gravity = { -1, 0 },
	})

	-- Network picker: the search box spans the card; each entry shows the build menu's icon
	-- (16:10, pinned like the tool tiles' icons) in front of its name. The icon rule has no
	-- R:: prefix: the dropdown's list opens in a popup outside the panel.
	a("R::NtoolsPanelContent !ntools-net-search", {
		gravity = { -1, 0 },
		margin = { 0, 0, 6, 0 },
	})
	-- New roads & tracks: the build menu's icon with its name beside it, two to a row, all the same
	-- size. Pinned with size + minSize + maxSize as the tool tiles are (minSize alone did nothing on a
	-- lone ToggleButton: each was only as wide as its text). Drawn size = size + padding + ~4 px of
	-- edge (240 x 40 drew ~264 x 47 and ran off the card; 210 left ~55 px spare on the right):
	-- 236 fills the card's width with the same edge both sides; ~30 px tall
	a("R::NtoolsPanelContent ToggleButton!ntools-feature", {
		size = { 236, 24 },
		minSize = { 236, 24 },
		maxSize = { 236, 24 },
		margin = { 2, 3, 2, 3 },
		padding = { 2, 6, 2, 6 },
	})
	a("R::NtoolsPanelContent !ntools-feature-icon", {
		size = { 20, 20 },
		minSize = { 20, 20 },
		maxSize = { 20, 20 },
	})
	-- off: the game paints an unchecked ToggleButton the card's own colour (BaseMedium), so it vanished
	-- into the card - a darker fill and a faint edge make it read as a button (on: the game's blue)
	a("R::NtoolsPanelContent ToggleButton!ntools-feature!unchecked", {
		backgroundColor1 = { 0, 0, 0, 0.25 },
		borderColor = { 1, 1, 1, 0.16 },
	})
	a("R::NtoolsPanelContent ToggleButton!ntools-feature!unchecked:hover", {
		borderColor = { 0.45, 0.68, 0.98, 1 },
	})
	-- icon and name on the left, centred vertically
	a("R::NtoolsPanelContent ToggleButton!ntools-feature > FloatingLayout > *", {
		gravity = { 0, 0.5 },
	})
	a("R::NtoolsPanelContent ToggleButton!ntools-feature BoxLayout", {
		innerSpacing = { 8, 0 },
	})

	-- a network entry: a full-width button holding icon + name
	-- (no R::NtoolsPanelContent prefix: these rows are in the list's own window, NtoolsNetWindow)
	a("ToggleButton!ntools-net-row", {
		gravity = { -1, 0 },
		margin = { 1, 0, 1, 0 },
		padding = { 3, 6, 3, 6 },
	})
	-- content on the left in every state (the picked button centred it)
	a("ToggleButton!ntools-net-row > *", {
		gravity = { 0, 0.5 },
	})
	-- the game's collapsible cards in the panel: their floating arrow hidden (it overflows the card's
	-- bounds - a card scrolled half out of the panel left it over the world); each card's own line
	-- carries an arrow instead (withArrow in the panel script)
	a("R::NtoolsPanelContent R::ContentCard !arrow-component", {
		visibility = "none",
	})
	-- Connect's Sections table: the Span and State columns a fixed width, header and cells alike -
	-- as the game's industry window's consumer list does its figures (entity_window_util.css.lua);
	-- the Section column takes the rest
	-- (and the Network table's Kind / Speed / Lanes, its Type column taking the rest)
	a([[R::NtoolsSectionSpanCell,
		R::NtoolsSectionStateCell,
		R::NtoolsNetKindCell,
		R::NtoolsNetSpeedCell,
		DataTable::HeaderItem TextView!ntools-col-narrow]], {
		size = { 76, -1 },
	})
	-- the Network table's Lanes: one or two digits, narrower still (the Type column gets the room)
	a([[R::NtoolsNetLanesCell,
		DataTable::HeaderItem TextView!ntools-col-lanes]], {
		size = { 56, -1 },
	})
	-- Connect's Mode card: a mode's description wraps to the card's width (as the notes)
	a("R::NtoolsPanelContent TextView!ntools-mode-desc", {
		size = { 430, -1 },   -- (room for the card's arrow beside it)
		textAutoWrap = true,
	})
	a("!ntools-net-icon", {
		size = { 48, 30 },
		minSize = { 48, 30 },
		maxSize = { 48, 30 },
		margin = { 2, 8, 2, 0 },
		gravity = { 0, 0.5 },
	})
	-- a white game symbol in the icon's slot ("Same as selected"): smaller, centred in the same
	-- 48 px column so the names line up ({ top, right, bottom, left })
	a("!ntools-net-symbol", {
		size = { 22, 22 },
		minSize = { 22, 22 },
		maxSize = { 22, 22 },
		margin = { 6, 21, 6, 13 },
		gravity = { 0, 0.5 },
	})
	-- the Network card's row: the buttons centred on the name block, a little apart
	-- (no R::NtoolsPanelContent prefix: the card's row is rendered by the ContentCard's own host,
	-- where those rules didn't reach)
	a("BoxLayout!ntools-net-picked", {
		gravity = { -1, 0 },
		innerSpacing = { 4, 0 },
	})
	a("Button!ntools-net-action", {
		size = { 30, 30 },
		minSize = { 30, 30 },
		maxSize = { 30, 30 },
		padding = { 6, 6, 6, 6 },
		gravity = { 0, 0.5 },
	})
	a("!ntools-net-action-icon", {
		size = { 16, 16 },
		minSize = { 16, 16 },
		maxSize = { 16, 16 },
		gravity = { 0.5, 0.5 },
	})

	return result
end
