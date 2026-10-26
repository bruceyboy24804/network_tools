-- Network Tools panel - its own file (it used to live in the Connect tool's script, which had
-- outgrown Lua's local-variable limits). The Connect script loads every tool module and hands
-- them, the shared option tables and accessors for its own settings to init() once, at load.
--
-- Network Tools panel (like the CS2 Network Tools panel): a window opened from the toolbar button
-- that lists the tools and their options and runs the selected tool directly - no build menu.
--
-- It is a tool on the game's tool stack, written like tool_react_util.registerToolWithWindow but
-- using the default window container, so it needs no GameContext (toolbar plugins don't get one).
-- The tool stack hands us setActionFn (world interaction) and popSelf (close); the Connect recipe
-- runs unchanged inside the window with those.

local builtin = ug_require "::/gui/main/builtin.lua" as Builtin
local engine_react_util = ug_require "::/gui/main/engine_react_util.tl" as EngineReactUtil
local react = ug_require "::/gui/main/react.lua" as React
local game_react_globals = ug_require "::/gui/main/game_react_globals.tl" as GameReactGlobals
local gui_react_util = ug_require "::/gui/main/gui_react_util.tl" as GuiReactUtil
local menu_category_util = ug_require "::/gui/main/menu_category_util.tl" as MenuCategoryUtil
local content_card = ug_require "::/gui/main/content_card.tl" as ContentCard
local checkbox_list = ug_require "::/gui/main/collapsible_checkbox_list.tl" as CheckboxList

-- The game's own Window recipe, for our two windows. Other mods replace builtin.Window with a plain
-- function (Town Rename Sync, BlockadeRadar's "Nativer Window-Wrapper"): a window wrapped around that
-- registers as "wrapper around nil", and the game crashed natively the moment the panel opened
-- (NodeStorage::Get assertion in the WindowContainer - mod.io reports, 2026-10-12). So the original
-- is looked up through such wrappers (their upvalues, as Visual Auto Namer does), once, at load, and
-- our windows are registered around it AND built with it - never with builtin.Window at render time.
local getRecipeId = react.GetRecipeId as function(any) : number
local getRecipeName = react.GetRecipeName as function(any) : string
-- (pcall: the debug library may be missing from the game's Lua - then only an unreplaced Window is found)
local okUp, upFn = pcall(function() : any return debug.getupvalue end)
local getUpvalue = (okUp and upFn or nil) as function(any, integer) : (string, any)
local function isRecipe(f : any) : boolean
	if type(f) ~= "function" then return false end
	local ok, id = pcall(getRecipeId, f)
	return ok and type(id) == "number" and (id as number) >= 0
end
-- the Window recipe among fn's upvalues, else among the upvalues of the plain functions there (a
-- wrapper around another mod's wrapper), a few levels deep
local function windowInUpvalues(fn : any, depth : integer, seen : {any : boolean}) : any
	if depth > 4 or seen[fn] then return nil end
	seen[fn] = true
	local nested : {any} = {}
	for i = 1, 60 do
		local name, value = getUpvalue(fn, i)
		if name == nil then break end
		if isRecipe(value) then
			local okName, rn = pcall(getRecipeName, value)
			if okName and rn == "Window" then return value end
		elseif type(value) == "function" then
			nested[#nested + 1] = value
		end
	end
	for __, f in ipairs(nested) do
		local w = windowInUpvalues(f, depth + 1, seen)
		if w then return w end
	end
	return nil
end
local function findNativeWindow() : Recipe<Builtin.WindowParam>
	local fn : any = builtin.Window
	-- (a recipe as it is - the game's, or another mod's registered wrapper around it)
	if isRecipe(fn) then return fn as Recipe<Builtin.WindowParam> end
	if type(fn) ~= "function" or not getUpvalue then return nil end
	local ok, w = pcall(windowInUpvalues, fn, 1, {})
	return (ok and w or nil) as Recipe<Builtin.WindowParam>
end
local NativeWindow = findNativeWindow()
-- Window params set only off console: the PS5 build's Window has no 'closable' ("Cannot assign value
-- to userdata 'closable'" - player report, 2026-10-25). Timetables, which works there, sets neither
-- closable nor movable (its "closeable" is a misspelling the engine ignores)
local okConsole, isConsole = pcall(function() : boolean return api.util.isConsoleMode() end)
local ON_CONSOLE = okConsole and isConsole == true
local function desktopWindowParams(p : Builtin.WindowParam) : Builtin.WindowParam
	if not ON_CONSOLE then
		p.closable = true
		p.movable = true
	end
	return p
end
if not NativeWindow then
	print("[network_tools] the game's Window recipe was replaced by another mod and couldn't be found - the panel stays closed")
end

-- Inline styles for things that were one-property stylesheet rules: the game limits the total number
-- of stylesheet rules across all mods (and crashes past it), so what an inline StyleSheet can carry
-- (colours, padding, size) is set here. One shared sheet each, made once.
local g_sheets : {string : StyleSheet} = {}
local function sharedSheet(key : string, fill : function(StyleSheet)) : StyleSheet
	if g_sheets[key] == nil then
		local ok, st = pcall(function() : StyleSheet
			local s = api.gui.StyleSheet.new()
			fill(s)
			return s
		end)
		g_sheets[key] = ok and st or nil
	end
	return g_sheets[key]
end
-- a detail line's dimmer text (was !ntools-net-details)
local function dimText() : StyleSheet
	return sharedSheet("dim", function(s : StyleSheet) s.color = api.type.Vec4f.new(0.70, 0.73, 0.76, 1) end)
end
-- the section title above a card, its left inset lining the text up with the card contour
-- (Timetables' card-title: { 2, 0, 4, 6 }; was !ntools-card-title)
local function cardTitleSheet() : StyleSheet
	return sharedSheet("cardTitle", function(s : StyleSheet) s.padding = api.type.Vec4f.new(8, 0, 4, 6) end)
end

-- options shared by all tools (underground view, bridge / tunnel heights, new-road properties,
-- Connect's height offset / incline / snapping / override lanes)
local record SharedOptions
	record Opts
		underground : boolean
		bridgeHeight : number
		tunnelDepth : number
		structure : integer   -- 1 automatic, 2 ground, 3 bridge, 4 tunnel (every tool's new segments)
		heightOffset : number
		incline : number
		snapToRoads : boolean
		overrideLanes : boolean
		pointLabel : string
		pointHeight : number
		pointCircle : boolean
		pointHeightEnd : number
		pointRadius : number
		pointStructure : integer
		pointMovable : boolean
		pointMove : {number}
		catenary : integer
		busLane : boolean
		tram : integer
		lockDevelopment : boolean
		playerOwned : boolean
		decorations : boolean
		-- general settings (the Settings tab)
		hudIcons : boolean
		footprints : boolean
		saveSettings : boolean
		labels : boolean
		labelSpeed : boolean
		labelGrade : boolean
		labelRadius : boolean
		labelHeight : boolean
		labelTotal : boolean
		labelDetail : boolean
		labelSize : integer
		labelRange : number
		colorPreset : integer
		lineScale : number
		handleScale : number
		markerDetail : boolean
		panelLastTool : boolean
		compactPanel : boolean
		anarchyDefault : boolean
		buildMenu : boolean
	end
	opts : Opts
	key : function() : string
	keyName : function(cmd : string, fallback : string) : string   -- the player's bound key for a command
end
local shared = require "network_tools_1::/gui/construction/tools/shared/ntools_options.script.tl" as SharedOptions

----------------------------------------------------------------------------------------------------
-- What the Connect script hands over (init)

-- the tools' option tables (shared: the tools, the build-menu toolbar and this panel edit them)
local record ParallelOptions
	offset : number        -- nil = automatic
	autoOffset : number
	side : integer         -- +1 = left, -1 = right
	height : number
	crossings : boolean
	connectEnds : boolean
	count : integer
end
local record SlopeOptions
	mode : integer
	arch : number
	easeIn : number
	easeOut : number
end
local record ShapeOptions
	mode : integer
	strength : number
	transition : number
	curveMirror : boolean
	curveFree : boolean
	curveReset : integer
	curveSelLabel : string   -- Curve: the selected node (set by the tool)
	curveHeight : number     -- its height change: the slider writes it
end
local record GenerateOptions
	shape : integer
	radius : number
	radiusY : number
	cols : integer
	rows : integer
	spacing : number
	rotation : number
	turns : number
	grade : number
	clockwise : boolean
end
-- the signal tool's readout of the planned stretch (written by it every render)
local record SignalStats
	signals : integer
	blocks : integer
	shortest : number
	longest : number
	average : number
	added : integer
	locked : integer
	removed : integer
	skipped : integer
	existing : integer
	replaced : integer
	tracks : integer
end
local record SignalOptions
	spacing : number
	spacingType : integer     -- 1 equal blocks, 2 fixed interval, 3 by line speed, 4 by count
	blockCount : integer
	oneWay : boolean
	reverse : boolean
	beforeSwitches : boolean
	beforeCrossings : boolean
	switchDistance : number
	crossingDistance : number
	besideTracks : boolean
	besideSameWay : boolean
	removeMode : boolean
	stationMode : boolean
	pattern : integer          -- 1 opposite, 2 same, 3 alternate, 4 pairs, 5 auto
	runningSide : integer      -- (auto) 1 keep left, 2 keep right
	model : string
	twoWay : boolean
	existingMode : integer    -- 1 keep, 2 replace, 3 ignore
	minGap : number
	endClearance : number
	minBlock : number
	maxBlock : number
	atSplits : boolean
	atJoins : boolean
	joinDistance : number
	kindModels : {string : string}
	exitDistance : number
	stationEntry : boolean
	entryDistance : number
	pathMode : integer         -- ntools_chain's MODE_* (1 fewest segments ... 16 alternative route)
	pathAvoidStations : boolean
	pathElectric : boolean
	nameStyle : integer        -- 1 like the game's (town), 2 custom, 3 none
	namePrefix : string
	nameKind : boolean
	stats : SignalStats
end
local record SignalModel
	name : string
	label : string
	oneWay : boolean
end
local record Network
	id : integer
	name : string
	isTrack : boolean
	icon : string
	country : boolean
	oneWay : boolean
	electric : boolean
	lanes : integer
	speed : number
	filters : {string}
	categories : {string}
end
local record UiState
	canBuild : boolean
end

local record Recipes
	connect : function(ConstructionCustomActionParams<any>) : TreeNodeId
	parallel : function(ConstructionCustomActionParams<any>) : TreeNodeId
	reverse : function(ConstructionCustomActionParams<any>) : TreeNodeId
	addNode : function(ConstructionCustomActionParams<any>) : TreeNodeId
	removeNode : function(ConstructionCustomActionParams<any>) : TreeNodeId
	slope : function(ConstructionCustomActionParams<any>) : TreeNodeId
	shape : function(ConstructionCustomActionParams<any>) : TreeNodeId
	arrangeLine : function(ConstructionCustomActionParams<any>) : TreeNodeId
	arrangeCircle : function(ConstructionCustomActionParams<any>) : TreeNodeId
	generate : function(ConstructionCustomActionParams<any>) : TreeNodeId
	signals : function(ConstructionCustomActionParams<any>) : TreeNodeId
	upgrade : function(ConstructionCustomActionParams<any>) : TreeNodeId
	crossover : function(ConstructionCustomActionParams<any>) : TreeNodeId
	loop : function(ConstructionCustomActionParams<any>) : TreeNodeId
	junction : function(ConstructionCustomActionParams<any>) : TreeNodeId
	siding : function(ConstructionCustomActionParams<any>) : TreeNodeId
end
-- Junction builder (junction/): the radius under which it warns, the side a click starts the handle on
local record JunctionOptions
	minRadius : number
	side : integer
	mode : integer      -- the Branch tile's type: 1 junction, 2 siding, 3 passing loop
	siding : integer    -- the last siding End chosen (2 dead end, 3 rejoin), restored from Junction
	speed : number      -- turnout speed km/h (0 = free: the handle shapes the curve)
	doubleSlip : boolean -- crossings the branches make become double-slip switches
	fanStation : boolean -- dropped on a station's track end: a branch to each of its tracks there
end
-- Siding (siding/): track spacing, turnout length (m), starting side, sidings per side, both sides
local record SidingOptions
	spacing : number
	turnout : number
	side : integer
	count : integer
	both : boolean
	alongside : integer
	radius : number
	rejoin : boolean   -- (set here: Rejoin with Drag handles runs the Siding tool as a passing loop)
	speed : number     -- turnout speed km/h (0 = the Switch radius)
	feedAll : boolean  -- Dead end on a station's track end: a siding to each of its open tracks there
	feedStyle : integer -- ... 1 nested, 2 ladder, 3 diagonal
	feedCross : boolean -- ... double-track line: crossovers between the mains first
end
-- Crossover (crossover/): 1 single / 2 scissors, ahead (1) or behind (2) the first click, length (m)
local record CrossoverOptions
	kind : integer
	dir : integer
	length : number
	arrange : integer
end
-- Passing loop (loop/): side 1 left / 2 right, track spacing (m)
local record LoopOptions
	side : integer
	spacing : number
	count : integer
	alongside : integer
	handles : boolean  -- Rejoin: drag handles for both ends (the Siding tool) instead of picking segments
end
-- Track upgrade (upgrade/ntools_upgrade_tool): the type to change to (street template id, 0 = keep)
-- and catenary (1 keep, 2 electrify, 3 remove)
local record UpgradeOptions
	trackType : integer
	catenary : integer
end

local record Host
	-- the Connect script's own settings (plain variables there): "mode", "follow", "snap",
	-- "anarchy", "bridges", "network"
	get : function(key : string) : any
	set : function(key : string, value : any)
	ui : UiState
	modeConnection : integer
	listNetworks : function() : {Network}
	listSignals : function() : {SignalModel}
	clamp : function(v : number, lo : number, hi : number) : number
	recipes : Recipes
	par : ParallelOptions
	slope : SlopeOptions
	shape : ShapeOptions
	gen : GenerateOptions
	sig : SignalOptions
	upgrade : UpgradeOptions
	crossover : CrossoverOptions
	loop : LoopOptions
	junction : JunctionOptions
	siding : SidingOptions
end

local H : Host = nil
local g_par : ParallelOptions = nil
local g_slope : SlopeOptions = nil
local g_shape : ShapeOptions = nil
local g_gen : GenerateOptions = nil
local g_sig : SignalOptions = nil
local g_up : UpgradeOptions = nil
local g_cx : CrossoverOptions = nil
local g_loop : LoopOptions = nil
local g_jn : JunctionOptions = nil
local g_sd : SidingOptions = nil

-- the options are kept in the savegame (see ntools_persist)
local record PersistModule
	register : function(name : string, tbl : {string : any}, skip? : {string})
	init : function(host : any)
	tick : function()
	reset : function()
end
local persist = require "network_tools_1::/gui/construction/tools/shared/ntools_persist.script.tl" as PersistModule

-- the debug log switch (Settings tab)
local record DebugModule
	DEBUG : boolean
	setDebug : function(on : boolean)
end
local debugMod = require "network_tools_1::/gui/construction/tools/shared/ntools_debug.script.tl" as DebugModule

local function init(host : any)
	H = host as Host
	g_par, g_slope, g_shape = H.par, H.slope, H.shape
	g_gen, g_sig = H.gen, H.sig
	g_up = H.upgrade
	g_cx, g_loop = H.crossover, H.loop
	g_jn, g_sd = H.junction, H.siding
	-- (fields left out: the current selection, and Connect's view toggle)
	persist.register("shared", shared.opts as {string : any}, { "underground", "pointLabel", "pointHeight",
		"pointCircle", "pointHeightEnd", "pointRadius", "pointStructure", "pointMovable", "pointMove", "pointSent" })
	persist.register("parallel", g_par as {string : any}, { "autoOffset" })
	persist.register("slope", g_slope as {string : any})
	persist.register("shape", g_shape as {string : any}, { "curveSelLabel", "curveHeight", "curveReset" })
	persist.register("generate", g_gen as {string : any})
	persist.register("connect_extra", (require "network_tools_1::/gui/construction/tools/connect/extra/ntools_connect_extra.script.tl" as {string : any}).opts as {string : any})
	persist.register("signals", g_sig as {string : any}, { "stats" })
	if g_up then persist.register("upgrade", g_up as {string : any}) end
	if g_cx then persist.register("crossover", g_cx as {string : any}) end
	if g_loop then persist.register("loop", g_loop as {string : any}) end
	if g_jn then persist.register("junction", g_jn as {string : any}) end
	if g_sd then persist.register("siding", g_sd as {string : any}) end
	persist.init(H)
end

local function clamp(v : number, lo : number, hi : number) : number
	return H.clamp(v, lo, hi)
end

local script_param_util = ug_require "::/gui/main/script_param_util.tl" as ScriptParamUtil
local g_nativeParamFailLogged = false
-- the game's toolbar param widget for slider rows (off: our own departure-settings style rows)
local USE_NATIVE_PARAMS = false

local PANEL_WINDOW_ID = "ntools.window"
local g_panelOpen = false

local record PanelPayload
	setActionFn : function(fn? : (function() : TreeNodeId), key2? : string)
	close : function()
end

local record PanelWindowParams
	payload : PanelPayload
	onClose : function()
end

-- body-size text, as Timetables uses for its controls and lists
local function panelLabel(text : string) : TreeNodeId
	return builtin.TextView{ meta = { class = "font-scale-body" }, text = text }
end

local function panelHeading(text : string) : TreeNodeId
	return builtin.TextView{ meta = { class = "font-scale-body" }, text = text }
end

local function panelRow(children : {TreeNodeId}) : TreeNodeId
	return builtin.BoxLayout{ orientation = builtin.type.Orientation.Horizontal, children = children }
end

-- The tools, by tab. Each tile shows the tool's build-menu icon (<folder>/ntools_<x>.tga).
local record ToolDef
	id : string
	tab : string
	name : string
	tip : string
	icon : string
end
local record TabDef
	id : string
	name : string
end
local TOOL_ICON_DIR = "network_tools_1::/gui/construction/tools/"
local TILES_PER_ROW = 4
-- (texts are translated with _() when drawn, not while this file loads)
local TABS : {TabDef} = {
	{ id = "build", name = "Build" },
	{ id = "edit", name = "Edit" },
	{ id = "rail", name = "Rail" },
	-- general mod settings, no tools (its cards replace the running tool's options; the tool runs on)
	{ id = "settings", name = "Settings" },
	-- every tool's mouse and key controls (no tools either; the tool runs on, as on Settings)
	{ id = "controls", name = "Controls" },
}
local TOOLS : {ToolDef} = {
	{ id = "connect", tab = "build", name = "Connect", icon = "connect/ntools_connect",
		tip = "Join two nodes with arcs, a loop, a curve or a line" },
	{ id = "parallel", tab = "build", name = "Parallel", icon = "parallel/ntools_parallel",
		tip = "Build copies of a road or track beside it" },
	{ id = "generate", tab = "build", name = "Generate", icon = "generate/ntools_generate",
		tip = "Build a ring road, an oval or a street grid" },
	{ id = "slope", tab = "edit", name = "Set slope", icon = "slope/ntools_slope",
		tip = "Give a stretch of road or track an even gradient, an eased one, or an arch" },
	{ id = "shape", tab = "edit", name = "Smooth", icon = "shape/ntools_shape",
		tip = "Straighten a stretch, or smooth out its kinks" },
	{ id = "arrange_line", tab = "edit", name = "Line up", icon = "arrange_line/ntools_arrange_line",
		tip = "Spread a stretch's nodes evenly on a straight line" },
	{ id = "arrange_circle", tab = "edit", name = "Circle", icon = "arrange_circle/ntools_arrange_circle",
		tip = "Arrange a stretch's nodes evenly on a circle" },
	{ id = "reverse", tab = "edit", name = "Reverse", icon = "reverse/ntools_reverse",
		tip = "Flip the direction of road or track segments (one-way roads run the other way)" },
	{ id = "add_node", tab = "edit", name = "Add node", icon = "add_node/ntools_add_node",
		tip = "Click a road or track to split it there with a plain node" },
	{ id = "remove_node", tab = "edit", name = "Remove node", icon = "remove_node/ntools_remove_node",
		tip = "Click next to a plain node to merge its two segments into one" },
	{ id = "signals", tab = "rail", name = "Signals", icon = "signals/ntools_signals",
		tip = "Block signals along a stretch of track, at stations and before switches - or remove them" },
	{ id = "upgrade", tab = "rail", name = "Track upgrade", icon = "upgrade/ntools_upgrade",
		tip = "Change a stretch of track to another type, or add / remove its catenary - signals stay" },
	{ id = "crossover", tab = "rail", name = "Crossover", icon = "crossover/ntools_crossover",
		tip = "Join tracks side by side with pairs of switches - single or scissors, across as many tracks as you pick" },
	{ id = "junction", tab = "rail", name = "Branch", icon = "junction/ntools_junction",
		tip = "A junction, or a siding / passing loop - pick the type in the panel" },
}
local TOOL_TAB : {string : string} = {}
for _, d in ipairs(TOOLS) do TOOL_TAB[d.id] = d.tab end

-- remembered while the panel is closed (opened again where it was left)
local g_lastTool = "connect"
-- the Network search box's text (see networkSearch in the panel recipe)
local g_networkSearch = ""
-- the Network card's list is open (the card's arrow)
local g_netPickerOpen = false
-- Connect's Mode card's list is open (its arrow)
local g_modeListOpen = false
-- Connect's Sections card's table is open
local g_sectionsOpen = true

-- a ContentCard section: builds its nodes only when the card shows it (a node built but not
-- shown floods the log)
local record NodeHostParam
	make : function() : TreeNodeId
end
local NodeHost = react.RegisterRecipe("NtoolsNodeHost", function(p : NodeHostParam) : TreeNodeId
	-- (wrapped: a recipe's own node must be a layout - "Recipe child must be a layout" - and what
	-- make() builds may be a Component, as the Sections table)
	return builtin.BoxLayout{ child = p.make() }
end)

-- A collapsible card's always-shown part with its arrow at the right end of the line. The game's
-- card floats its arrow below the card outside its bounds (FloatingLayout overflow, placed for
-- the entity windows' width): in our scrolling panel a card scrolled half out left its arrow over
-- the world. That one is hidden in the panel (css), this one is clipped like the rest.
local g_arrowStyle : StyleSheet = nil
local function withArrow(make : function() : TreeNodeId, isOpen : function() : boolean) : function() : TreeNodeId
	return function() : TreeNodeId
		if not g_arrowStyle then
			pcall(function()
				local s = api.gui.StyleSheet.new()
				s.size = api.type.Vec2f.new(20, 12)
				s.color = api.type.Vec4f.new(0.62, 0.64, 0.68, 1)
				g_arrowStyle = s
			end)
		end
		return builtin.BoxLayout{
			orientation = builtin.type.Orientation.Horizontal,
			children = {
				make(),
				gui_react_util.makeHorizontalSpacer(),
				builtin.ImageView{
					meta = { mouseTransparent = true, styleSheet = g_arrowStyle },
					path = isOpen() and "::/gui/entity_window/design/collapse_up.tga" or "::/gui/entity_window/design/collapse_down.tga",
				},
			},
		}
	end
end

-- sub-options under the option they belong to, pushed in (css ntools-indent)
local function indented(rows : {TreeNodeId}) : TreeNodeId
	return builtin.Component{ meta = { class = "ntools-indent" },
		layout = builtin.BoxLayout{ orientation = builtin.type.Orientation.Vertical, children = rows } }
end

-- A folding card (the game's ContentCard, as Connect's Mode and Sections): a one-line summary of
-- its settings with the arrow, the settings under it. For settings changed rarely (the Signals
-- tool's clearances, path picking, names). Open / closed per key, remembered while the game runs
-- (netPickerOpenUi polls it, so a click on the arrow re-renders)
local g_foldOpen : {string : boolean} = {}
local function foldCard(title : string, summary : string, key : string, makeBody : function() : TreeNodeId, openDefault : boolean) : TreeNodeId
	local open = g_foldOpen[key]
	if open == nil then open = openDefault == true end
	return content_card.ContentCard{
		title = title,
		initialCalloutTextPermanent = "",
		recipeAndParamPermanent = content_card.makeRecipeAndParam(NodeHost, { make = withArrow(function() : TreeNodeId
			return builtin.TextView{ meta = { class = "font-scale-body", styleSheet = dimText() }, text = summary }
		end, function() : boolean return open end) }),
		initialCalloutTextCollapsible = "",
		recipeAndParamCollapsible = content_card.makeRecipeAndParam(NodeHost, { make = makeBody }),
		collapsibleExpanded = open,
		setCollapsibleExpanded = function(v : boolean) g_foldOpen[key] = v end,
	}
end
-- Network filters: the build menu's filter categories that are switched on (category -> true).
-- Like the game's ObjectFilterBox, a type is shown when it has ANY of them (none on: all shown).
local g_netFilter : {string : boolean} = {}
-- ... and its categories (road sizes / country / highway / tracks), the same way; a type must
-- match both rows when both have something switched on
local g_netCategory : {string : boolean} = {}

-- The build menu's categories (menu_category resources: roads_small, roads_country, tracks...),
-- read like menu_category_util.fetchMenuFilterCategories reads the filter categories
local function fetchMenuCategories() : {string : MenuCategoryUtil.FilterCategory}
	local data : {string : MenuCategoryUtil.FilterCategory} = {}
	pcall(function()
		local ids = api.res.genericRep.getAllOfType("menu_category")
		for i = 1, #ids do
			local d = api.res.genericRep.get(ids[i]).data as MenuCategoryUtil.FilterCategory
			if d and d.category then
				data[d.category] = { category = d.category, name = d.name, order = d.order or 0, icon = d.icon }
			end
		end
	end)
	return data
end
local g_lastTab : string = nil

-- Connect's height profile (connect/extra state.profile): the game's Chart (as its statistics
-- windows) with the ground (grey, filled) and the route coloured by how steep it is - one series per
-- run in the same grade band, a series having one colour - then a GradientLegend for the bands and a
-- ProgressBar of the steepest grade against the type's limit. nil without a planned route.
local PROFILE_BANDS = {
	{ 0.25, { 0.36, 0.74, 0.42, 1 } },    -- under a quarter of the type's limit: green
	{ 0.50, { 0.62, 0.80, 0.36, 1 } },
	{ 0.75, { 0.93, 0.78, 0.30, 1 } },    -- yellow
	{ 1.00, { 0.93, 0.52, 0.24, 1 } },    -- orange: near the limit
	{ math.huge, { 0.86, 0.26, 0.22, 1 } }, -- red: over it
}
local function profileNodes() : {TreeNodeId}
	local ex = require "network_tools_1::/gui/construction/tools/connect/extra/ntools_connect_extra.script.tl" as {string : any}
	local pf = (ex.state as {string : any}).profile as {string : any}
	if not pf then return nil end
	local s, z, gz, grade = pf.s as {number}, pf.z as {number}, pf.ground as {number}, pf.grade as {number}
	if #s < 2 then return nil end
	local limit = math.max(0.001, (pf.limit as number) or 0.04)
	local function vec(c : {number}) : Vec4f return api.type.Vec4f.new(c[1], c[2], c[3], c[4]) end
	-- (a Series' colour is one Vec4f - the type file says {Vec4f}, but a list fails: "Could not assign
	-- value to userdata 'color'"; the game's own charts pass a plain colour)
	local function lineColor(c : {number}) : {Vec4f} return (vec(c) as any) as {Vec4f} end
	local function bandOf(g : number) : integer
		local f = math.abs(g) / limit
		for i, bd in ipairs(PROFILE_BANDS) do if f < (bd[1] as number) then return i end end
		return #PROFILE_BANDS
	end
	-- axes: round marks over the heights of both lines, a little room above and below
	local lo, hi = math.huge, -math.huge
	for i = 1, #s do lo, hi = math.min(lo, z[i], gz[i]), math.max(hi, z[i], gz[i]) end
	local span = math.max(10, hi - lo)
	local stepY = ({ 1, 2, 5, 10, 20, 25, 50, 100, 200 })[1]
	for __, st in ipairs({ 1, 2, 5, 10, 20, 25, 50, 100, 200 }) do stepY = st; if span / st <= 5 then break end end
	local y0, y1 = math.floor((lo - span * 0.08) / stepY) * stepY, math.ceil((hi + span * 0.08) / stepY) * stepY
	local yMarks : {number} = {}
	local yv = y0
	while yv <= y1 + 1e-6 do yMarks[#yMarks + 1] = yv; yv = yv + stepY end
	local L = s[#s]
	local stepX = 50
	for __, st in ipairs({ 50, 100, 200, 250, 500, 1000, 2000, 5000 }) do stepX = st; if L / st <= 6 then break end end
	-- (round marks up to the route's end; the axis itself ends right at it - ending short, the line ran
	-- on past the chart and out of the card; ending at the next round mark left an empty strip)
	local xMarks : {number} = {}
	local xv = 0.0
	while xv <= L + 1e-6 do xMarks[#xMarks + 1] = xv; xv = xv + stepX end
	-- the series: the ground, then the route in runs of one grade band
	local series : {TreeNodeId} = {
		builtin.Series{ label = _("Ground"), type = "LINE", color = lineColor({ 0.55, 0.57, 0.60, 1 }), lineWidth = 1.5,
			xValues = s, yValues = gz, gradientFill = true },
	}
	local runX, runY : {number}, {number} = { s[1] }, { z[1] }
	local runBand = bandOf(grade[1] or 0)
	for i = 1, #s - 1 do
		local bd = bandOf(grade[i] or 0)
		if bd ~= runBand then
			series[#series + 1] = builtin.Series{ label = "", type = "LINE", color = lineColor(PROFILE_BANDS[runBand][2] as {number}),
				lineWidth = 3, xValues = runX, yValues = runY }
			runX, runY, runBand = { s[i] }, { z[i] }, bd
		end
		runX[#runX + 1], runY[#runY + 1] = s[i + 1], z[i + 1]
	end
	series[#series + 1] = builtin.Series{ label = _("Route"), type = "LINE", color = lineColor(PROFILE_BANDS[runBand][2] as {number}),
		lineWidth = 3, xValues = runX, yValues = runY }
	-- (its size set on it directly: the stylesheet rule didn't reach it - it came out flat, its axis
	-- labels on top of each other)
	local okS, chartStyle = pcall(function() : StyleSheet
		local st = api.gui.StyleSheet.new()
		st.size = api.type.Vec2f.new(525, 170)   -- (the card's inner width)
		return st
	end)
	local chart = builtin.Chart{
		meta = { class = "font-scale-annotation", styleSheet = okS and chartStyle or nil },
		xAxisLabelFormatter = function(v : number) : string
			if L >= 2000 then return string.format("%.1f km", v / 1000) end
			return string.format("%d m", math.floor(v + 0.5))
		end,
		yAxisLabelFormatter = function(v : number) : string return string.format("%d m", math.floor(v + 0.5)) end,
		xAxisMarkers = xMarks,
		yAxisMarkers = yMarks,
		xAxisMin = 0, xAxisMax = L,
		yAxisMin = yMarks[1], yAxisMax = yMarks[#yMarks],
		series = series,
	} as TreeNodeId
	-- the bands' legend: their grade bounds for this type
	local legend : {{string : any}} = {}
	for i, bd in ipairs(PROFILE_BANDS) do
		local upTo = bd[1] as number
		local label = upTo == math.huge and string.format("> %.1f%%", limit * 100) or (i == 1 and string.format("< %.1f%%", upTo * limit * 100) or string.format("%.1f%%", upTo * limit * 100))
		legend[#legend + 1] = { color = vec(bd[2] as {number}), label = label }
	end
	local steep = (pf.steep as number) or 0
	return {
		builtin.Component{ meta = { styleSheet = okS and chartStyle or nil }, layout = builtin.BoxLayout{ children = { chart } } },
		-- (labels inside the bands: without, the bands showed bare)
		builtin.GradientLegend{ meta = { class = "font-scale-annotation" }, colors = legend, horizontal = true, discrete = true, internalLabels = true },
		builtin.ProgressBar{
			meta = { tooltip = _("The steepest grade on the route, against what this road / track type allows") },
			value = math.max(0, math.min(1, steep / limit)),
			thresholds = { 0.75 },
			label = string.format(_("Steepest %.1f%% of %.1f%% allowed   (%s long)"), steep * 100, limit * 100,
				L >= 1000 and string.format("%.2f km", L / 1000) or string.format("%d m", math.floor(L + 0.5))),
		},
	}
end

-- Connect's Sections table: the game's DataTable, one row per section of a chain (M), the one being
-- edited lit; a click on one jumps there (Connect steps through the chain to it - verdict.chainTarget,
-- connect tool). Shown once there are two or more. A table hands new cells only their key and
-- doesn't update old ones, so the keys change with the chain (current, total, section).
local function chainInfo() : integer, integer, {{string : number}}
	local ex = require "network_tools_1::/gui/construction/tools/connect/extra/ntools_connect_extra.script.tl" as {string : any}
	local st = ex.state as {string : any}
	return math.floor((st.chainCur as number) or 1), math.floor((st.chainTotal as number) or 1), (st.chainSections or {}) as {{string : number}}
end
local function sectionOf(rowKey : integer) : integer return rowKey % 1000 end
-- the section's name cell, as the game's industry window's consumer list: the game's locate pin
-- (the camera to the section's middle) and the name as a button (jumps there to edit it)
local NtoolsSectionCell = react.RegisterRecipe("NtoolsSectionCell", function(param : Builtin.TableCellParam) : TreeNodeId
	local i = sectionOf(param.rowKey)
	local cur, total, secs = chainInfo()
	local sec = secs[i] or {}
	local line_react_util = ug_require "::/gui/line_vehicle_mgmt/line_react_util.tl" as {string : any}
	local LocateButton = line_react_util.LocateButton as function({string : any}) : TreeNodeId
	local kids : {TreeNodeId} = {}
	if sec.x then
		kids[#kids + 1] = LocateButton{
			tooltip = _("Show this section"),
			position = api.type.Vec3f.new(sec.x, sec.y, sec.z or 0),
		}
	end
	-- (a plain Button, as the game's name cells (line_react_util.makeEntityWindowButton): the game's
	-- table styles give it no padding and its text the column's width, left aligned - a ToggleButton
	-- missed those. The one being edited marked with an arrow)
	kids[#kids + 1] = builtin.Button{
		meta = { tooltip = i == cur and _("The section you're editing") or _("Go to this section to edit it") },
		-- (the one being edited in the game's highlight blue - a marker character was too small to notice)
		content = builtin.TextView{
			meta = { class = "font-scale-body", styleSheet = i == cur and (function() : StyleSheet
				local ok, st = pcall(function() : StyleSheet
					local s = api.gui.StyleSheet.new()
					s.color = api.type.Vec4f.new(0.45, 0.68, 0.98, 1)
					return s
				end)
				return ok and st or nil
			end)() or nil },
			text = string.format(_("Section %d"), i),
		},
		onClick = function()
			local v = require "network_tools_1::/gui/construction/tools/shared/ntools_verdict.script.tl" as {string : any}
			v.chainTarget = i
		end,
	}
	-- (a recipe's own node must be a layout)
	return builtin.BoxLayout{ orientation = builtin.type.Orientation.Horizontal, children = kids }
end)
local NtoolsSectionSpanCell = react.RegisterRecipe("NtoolsSectionSpanCell", function(param : Builtin.TableCellParam) : TreeNodeId
	local i = sectionOf(param.rowKey)
	local __c, __t, secs = chainInfo()
	local span = (secs[i] or {}).span or 0
	local text = span > 0 and (span >= 1000 and string.format("%.2f km", span / 1000) or string.format("%d m", math.floor(span + 0.5))) or "-"
	return builtin.BoxLayout{ child = builtin.TextView{ meta = { class = "font-scale-body" }, text = text } }
end)
local NtoolsSectionStateCell = react.RegisterRecipe("NtoolsSectionStateCell", function(param : Builtin.TableCellParam) : TreeNodeId
	local i = sectionOf(param.rowKey)
	local cur = chainInfo()
	local text = i == cur and _("Editing") or (i < cur and _("Kept") or _("Next"))
	return builtin.BoxLayout{ child = builtin.TextView{ meta = { class = "font-scale-body" }, text = text } }
end)
-- the table (the Sections card's open part)
local function sectionsTable() : TreeNodeId
	local cur, total = chainInfo()
	local keys : {integer} = {}
	for i = 1, total do keys[i] = ((cur % 100) * 100 + (total % 100)) * 1000 + i end
	local okS, st = pcall(function() : StyleSheet
		local s = api.gui.StyleSheet.new()
		s.size = api.type.Vec2f.new(480, math.min(220, 44 + 48 * total))
		return s
	end)
	return builtin.Component{
		meta = { styleSheet = okS and st or nil },
		layout = builtin.BoxLayout{ children = {
			builtin.DataTable{
				columns = {
					builtin.ColumnDesc{ name = _("Section"), weight = 1, recipe = NtoolsSectionCell },
					builtin.ColumnDesc{ tooltip = _("End to end, straight"), name = _("Span"), recipe = NtoolsSectionSpanCell, headerStyleClass = "ntools-col-narrow" },
					builtin.ColumnDesc{ name = _("State"), recipe = NtoolsSectionStateCell, headerStyleClass = "ntools-col-narrow" },
				},
				rowKeys = keys,
				disableSortKey = true,
				scrollPolicyHorizontal = builtin.type.ScrollBarPolicy.AlwaysOff,
				scrollPolicyVertical = builtin.type.ScrollBarPolicy.AsNeeded,
			},
		} },
	}
end
-- The Network card's list: the game's DataTable, built as its vehicle statistics table - a row per
-- road / track type (icon and name, kind, speed, lanes), always the same rows in the same order
-- (rowKeys: every type's id); search and the filters only hide rows (fnUserFilter); the picked one's
-- cell lights itself (it reads the pick each step); a click on a header sorts (getCompareValue, the
-- order kept by initialSortColumn / onSortColumnChange); a click on a name picks it
local g_netById : {integer : Network} = {}
local g_netShown : {integer : boolean} = {}   -- the types search / filters leave
local g_netCurrent = 0                         -- the picked one's id (0: Same as selected)
local g_netKeys : {integer} = {}               -- the rows: kept the same table while the types are
local g_netSortCol : {integer} = nil           -- the column sorted by and ascending (1/0)
local function netOfKey(rowKey : integer) : Network return g_netById[rowKey] end
local function netKind(n : Network) : integer return n.isTrack and 1 or (n.country and 2 or 3) end
local function inlineSheet(fill : function(StyleSheet)) : StyleSheet
	local ok, st = pcall(function() : StyleSheet
		local s = api.gui.StyleSheet.new()
		fill(s)
		return s
	end)
	return ok and st or nil
end

local NtoolsNetNameCell = react.RegisterRecipe("NtoolsNetNameCell", function(param : Builtin.TableCellParam) : TreeNodeId
	-- (lit while it's the picked one: read each step - the table doesn't hand old cells new keys)
	local pickedUi = engine_react_util.useStepState(function() : boolean return g_netCurrent == param.rowKey end)
	local n = netOfKey(param.rowKey)
	if not n then return builtin.BoxLayout{ child = builtin.TextView{ meta = { class = "font-scale-body" }, text = "?" } } end
	local picked = pickedUi:old() == true
	local kids : {TreeNodeId} = {}
	if n.icon then
		-- (inline size: the panel's CSS doesn't reach into a table's cells)
		kids[#kids + 1] = builtin.ImageView{
			meta = { styleSheet = inlineSheet(function(s : StyleSheet) s.size = api.type.Vec2f.new(30, 30) end) },
			path = n.icon, scaling = builtin.type.ImageViewScaling.AutoFit,
		}
	end
	-- (a long name would run past the column: shortened, the tooltip has it whole)
	local MAX_NAME = 40
	local text = n.name
	if #text > MAX_NAME then text = (text:sub(1, MAX_NAME - 1):gsub("%s+$", "")) .. "…" end
	-- (a ToggleButton's "on" look for the pick was tried 2026-10-11: the user preferred this)
	kids[#kids + 1] = builtin.Button{
		meta = { tooltip = picked and (n.name .. "\n" .. _("Picked - click again for \"Same as selected\"")) or n.name },
		-- (the picked one in the game's highlight blue, as the Sections table's current section)
		content = builtin.TextView{
			meta = { class = "font-scale-body", styleSheet = picked and inlineSheet(function(s : StyleSheet) s.color = api.type.Vec4f.new(0.45, 0.68, 0.98, 1) end) or nil },
			text = text,
			tooltipWhenClipped = n.name,
		},
		onClick = function() H.set("network", (not picked) and n.id or nil) end,
	}
	return builtin.BoxLayout{ orientation = builtin.type.Orientation.Horizontal, children = kids }
end)
local function netTextCell(name : string, textOf : function(Network) : string) : any
	return react.RegisterRecipe(name, function(param : Builtin.TableCellParam) : TreeNodeId
		local n = netOfKey(param.rowKey)
		return builtin.BoxLayout{ child = builtin.TextView{ meta = { class = "font-scale-body" }, text = n and textOf(n) or "" } }
	end)
end
local NtoolsNetKindCell = netTextCell("NtoolsNetKindCell", function(n : Network) : string
	return n.isTrack and _("Rail") or (n.country and _("Country") or _("Town"))
end)
local NtoolsNetSpeedCell = netTextCell("NtoolsNetSpeedCell", function(n : Network) : string
	return (n.speed and n.speed > 0) and string.format("%d km/h", math.floor(n.speed + 0.5)) or "-"
end)
local NtoolsNetLanesCell = netTextCell("NtoolsNetLanesCell", function(n : Network) : string
	return (n.lanes and n.lanes > 0) and tostring(n.lanes) or "-"
end)
-- each column's sort value of a type (Type, Kind, Speed, Lanes)
local NET_SORT : {function(Network) : any} = {
	function(n : Network) : any return n.name end,
	function(n : Network) : any return netKind(n) end,
	function(n : Network) : any return n.speed or 0 end,
	function(n : Network) : any return n.lanes or 0 end,
}
local record NetTableParam
	keys : {integer}     -- every type (the same table while the types stay the same)
	shown : integer      -- how many the filter leaves (the table's height)
	filterKey : string   -- the search / filters: a change gives the table a new filter to apply
end
local NtoolsNetTable = react.RegisterRecipe("NtoolsNetTable", function(p : NetTableParam) : TreeNodeId
	local function cmp(col : integer) : function(integer) : any
		return function(k : integer) : any
			local n = netOfKey(k)
			return n and NET_SORT[col](n) or 0
		end
	end
	-- (a recipe's own node must be a layout: the sized Component inside one)
	return builtin.BoxLayout{ child = builtin.Component{
		-- (in its own window: wide enough for most names in the Type column)
		-- (640: with Kind / Speed / Lanes narrow, the Type column fits a 40-letter name - at 560 they
		-- were cut mid-letter)
		meta = { styleSheet = inlineSheet(function(s : StyleSheet) s.size = api.type.Vec2f.new(640, math.min(440, 44 + 60 * math.max(1, p.shown))) end) },
		layout = builtin.BoxLayout{ children = {
			builtin.DataTable{
				columns = {
					builtin.ColumnDesc{ name = _("Type"), weight = 1, recipe = NtoolsNetNameCell, getCompareValue = cmp(1) },
					builtin.ColumnDesc{ name = _("Kind"), tooltip = _("Rail, country road or town street"), recipe = NtoolsNetKindCell, headerStyleClass = "ntools-col-narrow", getCompareValue = cmp(2) },
					builtin.ColumnDesc{ name = _("Speed"), tooltip = _("Top speed"), recipe = NtoolsNetSpeedCell, headerStyleClass = "ntools-col-narrow", getCompareValue = cmp(3) },
					builtin.ColumnDesc{ name = _("Lanes"), tooltip = _("Lanes (rail: tracks)"), recipe = NtoolsNetLanesCell, headerStyleClass = "ntools-col-lanes", getCompareValue = cmp(4) },
				},
				rowKeys = p.keys,
				-- (the order a header click chose, again when the table is made anew)
				initialSortColumn = g_netSortCol and { g_netSortCol[1], g_netSortCol[2] == 1 } or nil,
				onSortColumnChange = function(col : integer, asc : boolean) g_netSortCol = { col, asc and 1 or 0 } end,
				-- (search and filters: rows hidden, not taken out)
				fnUserFilter = function(k : integer) : boolean return g_netShown[k] == true end,
				scrollPolicyHorizontal = builtin.type.ScrollBarPolicy.AlwaysOff,
				scrollPolicyVertical = builtin.type.ScrollBarPolicy.AsNeeded,
			},
		} },
	} }
end)
-- the table for these types (every one; g_netShown the ones the search / filters leave), `current`
-- the picked one's id, filterKey the search and filters
local function networksTable(all : {Network}, current : integer, filterKey : string) : TreeNodeId
	local same = #all == #g_netKeys
	if same then
		for i, n in ipairs(all) do
			if g_netKeys[i] ~= n.id then same = false; break end
		end
	end
	if not same then
		g_netKeys = {}
		for i, n in ipairs(all) do g_netKeys[i] = n.id end
	end
	for __, n in ipairs(all) do g_netById[n.id] = n end
	g_netCurrent = current
	local shown = 0
	for __ in pairs(g_netShown) do shown = shown + 1 end
	return NtoolsNetTable{ keys = g_netKeys, shown = shown, filterKey = filterKey }
end

-- The road / track list in a window of its own (as the game's statistics tables: the table fills
-- it and scrolls itself - inside the panel's scroll area, a click on its header scrolled the panel
-- down every time). Opened from the Network card's arrow. Its content is the panel's own list
-- (search, filters, Same as selected, the table): the panel hands its builder over each render and
-- a key that changes with the search, filters and pick, so the window renders it again
local g_netListBuilder : function() : TreeNodeId = nil
local g_netWindowKey = ""
local NET_WINDOW_ID = "ntools.network.window"
local record NetWindowParams
	onClose : function()
end
local NtoolsNetWindowContent = react.RegisterRecipe("NtoolsNetWindowContent", function(_p : NetWindowParams) : TreeNodeId
	local _k = engine_react_util.useStepState(function() : string return g_netWindowKey end)
	local body = g_netListBuilder and g_netListBuilder()
		or builtin.TextView{ meta = { class = "font-scale-body" }, text = _("Open a Network Tools tool that builds (Connect, Parallel, Generate) to choose its type") }
	-- (a recipe's own node must be a layout; the contents kept off the window's edges)
	return builtin.BoxLayout{ child = builtin.Component{
		meta = { styleSheet = inlineSheet(function(s : StyleSheet) s.padding = api.type.Vec4f.new(4, 14, 14, 14) end) },
		layout = builtin.BoxLayout{ child = body },
	} }
end)
-- (nil when the game's Window couldn't be found - see NativeWindow)
local NtoolsNetWindow = NativeWindow and react.RegisterWrapperRecipe("NtoolsNetWindow", NativeWindow, function(p : NetWindowParams) : TreeNodeId
	return NativeWindow(desktopWindowParams({
		id = NET_WINDOW_ID,
		title = _("Road / track type"),
		onClose = p.onClose,
		-- (where it first opens: the css, Window#ntools.network.window)
		autoFocusOnBecomingVisible = false,
		content = NtoolsNetWindowContent(p),
	}))
end)
local function closeNetWindow()
	if not NtoolsNetWindow then return end
	pcall(function() game_react_globals.getDefaultWindowApi().removeAllWindows(NtoolsNetWindow) end)
end
local function openNetWindow()
	if not NtoolsNetWindow then return end
	pcall(function()
		game_react_globals.getDefaultWindowApi().addSingletonWindow(NtoolsNetWindow, { onClose = closeNetWindow })
	end)
end

-- the card's always-shown line: which section, how many
local function sectionsSummary() : TreeNodeId
	local cur, total = chainInfo()
	return builtin.BoxLayout{
		orientation = builtin.type.Orientation.Vertical,
		children = {
			builtin.TextView{ meta = { class = "font-scale-body, ntools-net-name" }, text = string.format(_("Editing section %d of %d"), cur, total) },
			builtin.TextView{ meta = { class = "font-scale-annotation, ntools-mode-desc", styleSheet = dimText() },
				-- (the keys as the player has them bound)
				text = (function() : string
					local kM = shared.keyName("constructOpt1", "M")
					return string.format(_("%s: next / continue   %s: previous   Build builds them all\nAn end dropped near another section's end snaps back onto it (Shift: no snapping)"),
						kM, shared.keyName("constructOptPrecise1", "Shift+" .. kM))
				end)() },
		},
	}
end

local NetworkToolsPanelContent = react.RegisterRecipe("NtoolsPanelContent", function(params : PanelWindowParams) : TreeNodeId
	-- which tool is running ("connect", "parallel", or nil = none: no world interaction) and which tab
	-- is shown; both remembered when the panel is closed and opened again
	local toolState : ReactStateT<string> = react.useState(g_lastTool)
	local tabState : ReactStateT<string> = react.useState(g_lastTab)

	-- mirror the shared option flags so the controls re-render when keys change them
	local modeUi = engine_react_util.useStepState(function() : integer return (H.get("mode") as integer) or H.modeConnection end)
	local followUi = engine_react_util.useStepState(function() : boolean return H.get("follow") as boolean end)
	local replaceUi = engine_react_util.useStepState(function() : boolean return H.get("replace") as boolean end)
	local liveUi = engine_react_util.useStepState(function() : boolean return H.get("live") as boolean end)
	local dubinsRadiusUi = engine_react_util.useStepState(function() : number return H.get("dubinsRadius") as number end)
	local sharedKeyUi = engine_react_util.useStepState(function() : string
		persist.tick()   -- options changed? into the savegame
		-- (+ the debug log switch: it lives in ntools_debug, not in the options - left out, its tick
		-- didn't follow a click)
		return shared.key() .. "/" .. tostring(debugMod.DEBUG)
	end)
	local snapUi = engine_react_util.useStepState(function() : boolean return H.get("snap") as boolean end)
	local anarchyUi = engine_react_util.useStepState(function() : boolean return H.get("anarchy") as boolean end)
	local bridgesUi = engine_react_util.useStepState(function() : boolean return H.get("bridges") as boolean end)
	-- the bridge / tunnel / crossing types (re-render when the build menu's pickers change them)
	local structUi = engine_react_util.useStepState(function() : string
		return tostring(H.get("bridgeType")) .. "/" .. tostring(H.get("tunnelType")) .. "/" .. tostring(H.get("rcType"))
	end)
	local twinUi = engine_react_util.useStepState(function() : integer return (H.get("twin") as integer) or 0 end)
	local canBuildUi = engine_react_util.useStepState(function() : boolean return H.ui.canBuild end)
	local parOffsetUi = engine_react_util.useStepState(function() : number return g_par.offset or g_par.autoOffset end)
	local networkPanelUi = engine_react_util.useStepState(function() : integer return (H.get("network") as integer) or 0 end)
	-- text typed in the Network search box (filters the list). Like the game's build-menu search
	-- (construction.tl): the box writes it to a plain variable on every keystroke - not into
	-- render state, which rebuilt the box mid-typing - and the list follows it every engine step.
	local networkSearch = engine_react_util.useStepState(function() : string return g_networkSearch end)
	-- (both collapsible cards' arrows - the Network card's and the Mode card's: one poll, re-renders on either)
	local netPickerOpenUi = engine_react_util.useStepState(function() : string
		local folds : {string} = {}
		for k, v in pairs(g_foldOpen) do folds[#folds + 1] = k .. "=" .. tostring(v) end
		table.sort(folds)
		return tostring(g_netPickerOpen) .. "/" .. tostring(g_modeListOpen) .. "/" .. tostring(g_sectionsOpen)
			.. "/" .. table.concat(folds, ",")
	end)
	-- Connect's extra modes' settings (connect/extra): their sliders re-render the panel
	-- (and the height profile's version: the Profile card follows the route Connect plans)
	local _extraUi = engine_react_util.useStepState(function() : string
		local exm = require "network_tools_1::/gui/construction/tools/connect/extra/ntools_connect_extra.script.tl" as {string : any}
		local o = exm.opts as {string : number}
		return tostring(o.easeLength) .. "/" .. tostring(o.helixRadius) .. "/" .. tostring(o.helixGrade) .. "/" .. tostring(o.gradeMax)
			.. "/" .. tostring((exm.state as {string : any}).version)
			.. "/" .. tostring((exm.state as {string : any}).chainCur) .. "/" .. tostring((exm.state as {string : any}).chainTotal)
	end):old()
	local netFilterUi = engine_react_util.useStepState(function() : string
		local on : {string} = {}
		for c, v in pairs(g_netFilter) do if v then on[#on + 1] = c end end
		for c, v in pairs(g_netCategory) do if v then on[#on + 1] = "#" .. c end end
		table.sort(on)
		return table.concat(on, ",")
	end)
	local parSideUi = engine_react_util.useStepState(function() : integer return g_par.side end)
	local parHeightUi = engine_react_util.useStepState(function() : number return g_par.height end)
	local parCrossingsUi = engine_react_util.useStepState(function() : boolean return g_par.crossings end)
	local parEndsUi = engine_react_util.useStepState(function() : boolean return g_par.connectEnds end)
	local parCountUi = engine_react_util.useStepState(function() : integer return g_par.count or 1 end)
	local parAutoUi = engine_react_util.useStepState(function() : boolean return g_par.offset == nil end)
	local slopeModeUi = engine_react_util.useStepState(function() : integer return g_slope.mode end)
	local slopeArchUi = engine_react_util.useStepState(function() : number return g_slope.arch end)
	local shapeModeUi = engine_react_util.useStepState(function() : integer return g_shape.mode end)
	local shapeStrengthUi = engine_react_util.useStepState(function() : number return g_shape.strength end)
	local shapeTransitionUi = engine_react_util.useStepState(function() : number return g_shape.transition end)
	local shapeCurveUi = engine_react_util.useStepState(function() : string
		return tostring(g_shape.curveMirror) .. "/" .. tostring(g_shape.curveFree) .. "/" .. tostring(g_shape.curveSelLabel)
			.. "/" .. tostring(g_shape.curveHeight)
	end)
	local railKeyUi = engine_react_util.useStepState(function() : string
		return (g_cx and (tostring(g_cx.kind) .. "/" .. tostring(g_cx.dir) .. "/" .. tostring(g_cx.length) .. "/" .. tostring(g_cx.arrange)) or "")
			.. "|" .. (g_loop and (tostring(g_loop.side) .. "/" .. tostring(g_loop.spacing) .. "/" .. tostring(g_loop.count) .. "/" .. tostring(g_loop.alongside)
				.. "/" .. tostring(g_loop.handles)) or "")
			.. "|" .. (g_jn and (tostring(g_jn.minRadius) .. "/" .. tostring(g_jn.side) .. "/" .. tostring(g_jn.mode)
				.. "/" .. tostring(g_jn.speed) .. "/" .. tostring(g_jn.doubleSlip)
			.. "/" .. tostring(g_jn.fanStation) .. "/" .. tostring(g_jn.siding)
				.. "/" .. tostring((g_jn as {string : any}).signals) .. "/" .. tostring((g_jn as {string : any}).signalModel)
				.. "/" .. tostring((g_jn as {string : any}).sigDist)) or "")
			.. "|" .. (g_sd and (tostring(g_sd.spacing) .. "/" .. tostring(g_sd.radius) .. "/" .. tostring(g_sd.side)
				.. "/" .. tostring(g_sd.count) .. "/" .. tostring(g_sd.both) .. "/" .. tostring(g_sd.alongside) .. "/" .. tostring(g_sd.speed)
			-- (every field a panel control writes: one left out leaves its tick / switch stale)
			.. "/" .. tostring(g_sd.feedAll) .. "/" .. tostring(g_sd.feedStyle) .. "/" .. tostring(g_sd.feedCross) .. "/" .. tostring(g_sd.rejoin)
				.. "/" .. tostring((g_sd as {string : any}).signals) .. "/" .. tostring((g_sd as {string : any}).signalModel)
				.. "/" .. tostring((g_sd as {string : any}).sigDist)) or "")
	end)
	local upKeyUi = engine_react_util.useStepState(function() : string
		return g_up and (tostring(g_up.trackType) .. "/" .. tostring(g_up.catenary)) or ""
	end)
	local sigKeyUi = engine_react_util.useStepState(function() : string
		return string.format("%.0f/%s/%s/%s/%s", g_sig.spacing, tostring(g_sig.oneWay), tostring(g_sig.reverse),
			tostring(g_sig.beforeSwitches) .. tostring(g_sig.beforeCrossings) .. tostring(g_sig.switchDistance) .. tostring(g_sig.crossingDistance), tostring(g_sig.model)) .. tostring(g_sig.besideTracks) .. tostring(g_sig.besideSameWay) .. tostring(g_sig.removeMode) .. tostring(g_sig.stationMode) .. tostring(g_sig.pattern) .. tostring(g_sig.runningSide)
			.. "/" .. tostring(g_sig.spacingType) .. "/" .. tostring(g_sig.blockCount)
			.. "/" .. tostring(g_sig.twoWay) .. tostring(g_sig.existingMode) .. tostring(g_sig.minGap) .. tostring(g_sig.endClearance)
			.. tostring(g_sig.minBlock) .. tostring(g_sig.maxBlock) .. tostring(g_sig.atSplits) .. tostring(g_sig.atJoins)
			.. tostring(g_sig.joinDistance) .. tostring(g_sig.exitDistance) .. tostring(g_sig.stationEntry) .. tostring(g_sig.entryDistance)
			.. "/" .. tostring(g_sig.pathMode) .. tostring(g_sig.pathAvoidStations) .. tostring(g_sig.pathElectric)
			-- (not namePrefix: the name box writes it on every keystroke, and a re-render would
			-- rebuild the box mid-typing - as the Network search box)
			.. "/" .. tostring(g_sig.nameStyle) .. tostring(g_sig.nameKind)
			.. (function() : string
				local km : {string} = {}
				for k, v in pairs(g_sig.kindModels or {}) do km[#km + 1] = k .. "=" .. v end
				table.sort(km)
				return table.concat(km, ",")
			end)()
			-- (the readout: re-render when it changes)
			.. (function() : string
				local s = g_sig.stats
				if not s then return "/-" end
				return string.format("/%d,%d,%.0f,%.0f,%.0f,%d,%d,%d,%d,%d,%d,%d", s.signals or 0, s.blocks or 0, s.shortest or 0,
					s.longest or 0, s.average or 0, s.added or 0, s.locked or 0, s.removed or 0, s.skipped or 0, s.existing or 0,
					s.replaced or 0, s.tracks or 0)
			end)()
	end)
	local genKeyUi = engine_react_util.useStepState(function() : string
		return string.format("%d/%.1f/%.1f/%d/%d/%.1f/%.1f/%.2f/%.1f/%s", g_gen.shape, g_gen.radius, g_gen.radiusY,
			g_gen.cols, g_gen.rows, g_gen.spacing, g_gen.rotation, g_gen.turns or 0, g_gen.grade or 0, tostring(g_gen.clockwise))
	end)
	local slopeEaseInUi = engine_react_util.useStepState(function() : number return g_slope.easeIn end)
	local slopeEaseOutUi = engine_react_util.useStepState(function() : number return g_slope.easeOut end)

	local tool = toolState:old()

	local children : {TreeNodeId} = {}
	local function add(node : TreeNodeId)
		if node == nil then return end
		children[#children + 1] = node
	end

	-- a tool tile: its build-menu icon over its name (tooltip: what it does)
	local function toolTile(def : ToolDef) : TreeNodeId
		-- (Settings: compact panel - smaller tiles, five to a row)
		local compact = shared.opts.compactPanel == true
		return builtin.ToggleButton{
			meta = { tooltip = _(def.tip), class = (compact and "ntools-tile-compact" or "ntools-tile") .. ", ntools-centred" },
			content = builtin.BoxLayout{
				orientation = builtin.type.Orientation.Vertical,
				children = {
					builtin.ImageView{
						meta = { class = compact and "ntools-tile-icon-compact" or "ntools-tile-icon" },
						path = TOOL_ICON_DIR .. def.icon .. ".tga",
						scaling = builtin.type.ImageViewScaling.AutoFit,
					},
					builtin.TextView{ meta = { class = "ntools-tile-label, font-scale-annotation" }, text = _(def.name) },
				},
			},
			value = tool == def.id and 1 or 0,
			onValueChange = function(value : integer)
				H.ui.canBuild = false
				local id = value == 1 and def.id or nil
				g_lastTool = id
				toolState:set(id)
			end,
		}
	end
	-- (enabled = false: greyed out, as the game shows an option that doesn't apply)
	local function option(labelText : string, tooltipText : string, value : boolean, set : function(boolean), enabled? : boolean) : TreeNodeId
		return builtin.CheckBox{
			meta = { tooltip = tooltipText, enabled = enabled ~= false },
			label = labelText,
			value = value and 1 or 0,
			onValueChange = function(v : integer) set(v == 1) end,
		}
	end
	local function smallButton(text : string, tip : string, onClick : function()) : TreeNodeId
		return builtin.Button{ meta = { tooltip = tip }, content = panelLabel(text), onClick = onClick }
	end
	-- the footer: Reset and Build side by side across the panel's width, in the game's own button
	-- styles (Build "primary", the accent one; Reset "secondary")
	local function resetAndBuild(buildTip : string) : TreeNodeId
		return panelRow({
			builtin.Button{
				meta = { tooltip = _("Start over"), class = "secondary, ntools-footer-btn" },
				content = panelLabel(_("Reset")),
				onClick = function() api.gui.fireReactEvent("ntoolsResetShape", {}) end,
			},
			builtin.Button{
				meta = { tooltip = buildTip, class = "primary, ntools-footer-btn", enabled = canBuildUi:old() == true },
				content = panelLabel(_("Build")),
				onClick = function() api.gui.fireReactEvent("ntoolsBuild", {}) end,
			},
		})
	end

	-- a titled card: title above, engine card box around the content (see UI_NOTES.md)
	local function card(title : string, content : {TreeNodeId}) : TreeNodeId
		return builtin.BoxLayout{
			orientation = builtin.type.Orientation.Vertical,
			children = {
				-- headline-size section title above the card (Timetables: "card-title, font-scale-headline")
				builtin.TextView{ meta = { class = "font-scale-headline", styleSheet = cardTitleSheet() }, text = title },
				builtin.Component{
					meta = { class = "ntools-card" },
					layout = builtin.BoxLayout{ orientation = builtin.type.Orientation.Vertical, children = content },
				},
			},
		}
	end
	-- The game's own parameter row (what the street / overpass builders show for a toolbar slider:
	-- name, slider and value on one line), built by script_param_util from a param definition.
	-- `labels` are the slider stops; the value passed around is the stop's index (numbers are the
	-- indices too, so it doesn't matter whether the widget reports index or number).
	local function nativeParam(name : string, tip : string, uiType : ScriptParamType, labels : {string},
			index : integer, onIndex : function(integer)) : TreeNodeId
		-- off: every slider row now uses sliderRow below, laid out like the game's own departure
		-- settings (line window) - the toolbar param widget squeezed name, slider and value together
		if not USE_NATIVE_PARAMS then return nil end
		local numbers : {number} = {}
		for i = 1, #labels do numbers[i] = i - 1 end
		local ok, node = pcall(function() : TreeNodeId
			return script_param_util.buildScriptParamCompSimple({
				meta = { class = "ntools-native" },
				scriptParam = {
					uiType = uiType,
					name = name,
					values = labels,
					numbers = numbers,
					tooltips = { tip },
					defaultIndex = index,
					allowCoalesce = false,
				},
				currentValue = index,
				onValueChange = function(v : number) onIndex(math.floor(v + 0.5)) end,
				vertical = false,
				-- spacing between name, slider and value
				addSpacer = true,
				updateCurrentValue = true,
			} as ScriptParamUtil.CompSimpleParam)
		end)
		if ok and node then return node end
		if not g_nativeParamFailLogged then
			g_nativeParamFailLogged = true
			do ((require "network_tools_1::/gui/construction/tools/shared/ntools_debug.script.tl" as {string : any}).log as function(string))("[network_tools] panel: native param widget failed: " .. tostring(node)) end
		end
		return nil
	end

	-- A row like the game's builders: name on the left (fixed column), then the controls
	-- (enabled = false: the name greyed too - the controls grey themselves)
	local function labelledRow(labelText : string, controls : {TreeNodeId}, enabled? : boolean) : TreeNodeId
		local on = enabled ~= false
		-- the name sits in a Component so it can carry padding (the gap before the slider)
		local items : {TreeNodeId} = {
			builtin.Component{
				meta = { class = "ntools-row-label", enabled = on },
				layout = builtin.BoxLayout{
					orientation = builtin.type.Orientation.Horizontal,
					children = { builtin.TextView{ meta = { enabled = on }, text = labelText } },
				},
			},
		}
		for _, c in ipairs(controls) do items[#items + 1] = c end
		-- a Component, because a bare BoxLayout ignores padding / sizes (UI_NOTES.md)
		return builtin.Component{
			meta = { class = "ntools-row", enabled = on },
			layout = builtin.BoxLayout{
				orientation = builtin.type.Orientation.Horizontal,
				children = items,
			},
		}
	end
	-- A segmented switch (the game's ToggleButtonGroup, as in its Yes / No and load-mode pickers):
	-- one option always selected, equal widths. `selected` is 1-based and drives it, so keys that
	-- change the value move it too.
	-- tip: one tooltip for all options; tips: one per option (wins). wide: the switch has the card's
	-- whole width (no name column in front), so its options are wider
	local function segmented(names : {string}, selected : integer, onSelect : function(integer), tip? : string, tips? : {string}, wide? : boolean, enabled? : boolean) : TreeNodeId
		local buttons : {Builtin.ToggleButtonGroupChildParam} = {}
		-- (wide: four fill the card; five need the narrower wide5)
		-- (beside a name column: a width per option count, so every switch ends at the same edge)
		local n = #names
		local cls = wide and (n >= 5 and "ntools-seg-btn-wide5" or "ntools-seg-btn-wide")
			or (n <= 2 and "ntools-seg-btn2") or (n == 3 and "ntools-seg-btn3") or (n == 4 and "ntools-seg-btn")
			or (n == 5 and "ntools-seg-btn5") or "ntools-seg-btn6"
		for i, n in ipairs(names) do
			-- (meta goes to each option's ToggleButton: the class gives it its width)
			-- (ntools-centred: one shared rule centres the text, instead of a rule per width class)
			buttons[i] = { meta = { tooltip = (tips and tips[i]) or tip, class = cls .. ", ntools-centred" }, content = panelLabel(n) }
		end
		-- default (Horizontal) layout, as the game's departure window: "Uniform" fills the space the
		-- parent offers, which inside a row is none - the switch collapsed to nothing
		return builtin.ToggleButtonGroup{
			-- (enabled = false: greyed out, as an option that doesn't apply)
			meta = { enabled = enabled ~= false },
			buttons = buttons,
			deselectAllowed = false,
			selected = selected,
			onValueChange = function(index : integer, _v : integer) onSelect(index) end,
		}
	end

	-- A slider row like the game's departure settings (line window, cargofilter_window.tl
	-- makeWaitTimeSlider): name in a fixed column | spacer | fixed-width slider | value. The fixed
	-- columns line every row's slider up.
	local function sliderRow(labelText : string, tip : string, minV : integer, maxV : integer, value : integer,
			onChange : function(integer), valueText : string, enabled? : boolean) : TreeNodeId
		local on = enabled ~= false
		return builtin.Component{
			meta = { class = "ntools-wt-row", enabled = on },
			layout = builtin.BoxLayout{
				orientation = builtin.type.Orientation.Horizontal,
				children = {
					builtin.TextView{ meta = { class = "font-scale-body, ntools-wt-label", tooltip = tip, enabled = on }, text = labelText },
					gui_react_util.makeHorizontalSpacer(),
					builtin.Slider{
						meta = { tooltip = tip, class = "ntools-wt-slider", enabled = on },
						horizontal = true,
						min = minV, max = maxV, step = 1, pageStep = 10,
						value = value,
						onValueChange = onChange,
					},
					builtin.TextView{ meta = { class = "font-scale-body, ntools-wt-value", enabled = on }, text = valueText },
				},
			},
		}
	end
	local function slider(tip : string, minV : integer, maxV : integer, value : integer, onChange : function(integer)) : TreeNodeId
		return builtin.Slider{
			meta = { tooltip = tip, class = "ntools-slider" },
			horizontal = true,
			min = minV, max = maxV, step = 1, pageStep = 10,
			value = value,
			onValueChange = onChange,
		}
	end
	-- a Signals card for a tool's options table (fields signals, signalModel, sigDist): on / off, the
	-- type (only while on - widgets built and not shown flood the log), how far short of the switch
	local function signalCard(o : {string : any}, what : string) : TreeNodeId
		local smodels = H.listSignals()
		if o.signalModel == nil and smodels[1] then o.signalModel = smodels[1].name end
		local rows : {TreeNodeId} = {
			option(_("Signals"), what, o.signals == true, function(v : boolean) o.signals = v end),
		}
		if #smodels > 0 and o.signals == true then
			local items : {TreeNodeId} = {}
			local cur = 1
			for i, m in ipairs(smodels) do
				items[#items + 1] = builtin.ComboBoxItem{ value = i, content = panelLabel(m.label) }
				if o.signalModel == m.name then cur = i end
			end
			rows[#rows + 1] = builtin.ComboBox{
				meta = { tooltip = _("Signal type to place"), class = "ntools-slider" },
				items = items,
				value = cur,
				onValueChange = function(v : integer|number|string)
					local i = math.floor(tonumber(v) or 0)
					if smodels[i] then o.signalModel = smodels[i].name end
				end,
			}
		end
		local dist = math.floor(((o.sigDist or 10) as number) + 0.5)
		rows[#rows + 1] = sliderRow(_("   Distance"), _("How far short of the switch the signal stands"),
			3, 50, dist, function(v : integer) o.sigDist = v end, string.format("%d m", dist), o.signals == true)
		return card(_("Signals"), rows)
	end

	-- the tools in tabs (like Timetables' Lines / Stations / Departures), each a tile with its
	-- build-menu icon and name; the tab of the running tool is shown
	local tabOfTool = tabState:old() or TOOL_TAB[tool or ""] or "build"
	local tabBodies : {TreeNodeId} = {}
	-- (loop variables are not called "_": that would hide the translation function _())
	local perRow = shared.opts.compactPanel == true and 5 or TILES_PER_ROW
	for __, t in ipairs(TABS) do
		local rows : {TreeNodeId} = {}
		local row : {TreeNodeId} = {}
		for ___, def in ipairs(TOOLS) do
			if def.tab == t.id then
				row[#row + 1] = toolTile(def)
				if #row == perRow then rows[#rows + 1] = panelRow(row); row = {} end
			end
		end
		if #row > 0 then rows[#rows + 1] = panelRow(row) end
		if t.id == "settings" then
			-- two lines: a TextView doesn't wrap, one long line ran past the panel's edge
			rows[#rows + 1] = panelLabel(_("Settings for the whole mod, below."))
			rows[#rows + 1] = panelLabel(_("The tool you picked keeps running."))
		elseif t.id == "controls" then
			rows[#rows + 1] = panelLabel(_("Each tool's mouse and key controls, below."))
			rows[#rows + 1] = panelLabel(_("Keys as bound in the game's settings."))
		end
		tabBodies[#tabBodies + 1] = builtin.TabWidgetChild{
			localKey = "tab-" .. t.id, value = t.id,
			indicator = builtin.TextView{ meta = { class = "font-scale-tab-widget-indicator" }, text = _(t.name) },
			-- TabWidgetChild.item must be a Component
			item = builtin.Component{
				meta = { class = "ntools-tab-body" },
				layout = builtin.BoxLayout{ orientation = builtin.type.Orientation.Vertical, children = rows },
			},
		}
	end
	add(builtin.TabWidget{
		orientation = builtin.type.TabOrientation.North,
		deselectAllowed = false,
		value = tabOfTool,
		onValueChange = function(v : string)
			tabState:set(v)
			g_lastTab = v
		end,
		tabs = tabBodies,
	})

	-- Settings tab: general settings in place of the running tool's options. The tool's own option
	-- widgets aren't built at all then (onSettings skips each section below): built and not shown,
	-- the engine logs "Preserved props ... not attached" for every one, every render - a 100 MB log
	-- and a frame-rate drop. Only its recipe is added, so the tool runs on.
	local onSettings = tabOfTool == "settings" or tabOfTool == "controls"
	if tabOfTool == "controls" then
		-- a folding card per tool (the running one open), a line per control under it
		-- (short lines: a TextView doesn't wrap). Keys as the player has them bound
		local k = shared.keyName
		local kM = k("constructOpt1", "M")
		local function pair(a : string, b : string) : string return k(a, "?") .. " / " .. k(b, "?") end
		local CONTROLS : {string : {string}} = {
			connect = {
				_("Click: first point, then second (node, road or ground)"),
				_("Drag a point: move it"),
				_("Shift+double-click: add a waypoint / circle"),
				_("Shift+click a waypoint / circle centre: remove it"),
				_("Drag a circle's rim: radius   Double-click centre: flip"),
				_("Replace mode: Shift+click a road takes its whole stretch"),
				pair("constructRaise", "constructLower") .. "  -  " .. _("radius"),
				pair("constructOpt6", "constructOpt5") .. "  -  " .. _("angle"),
				pair("constructOpt7", "constructOpt8") .. "  -  " .. _("select end / circle"),
				k("constructAlignToTerrain", "?") .. "  -  " .. _("follow terrain on / off"),
				kM .. "  -  " .. _("continue from end 2 / next section"),
				k("constructOptPrecise1", "Shift+" .. kM) .. "  -  " .. _("previous section"),
				k("constructOpt2", "N") .. "  -  " .. _("move ends on / off"),
			},
			parallel = {
				_("Click a segment, then more to extend; first / last drops"),
				pair("constructRaise", "constructLower") .. "  -  " .. _("offset + / -"),
				pair("constructOpt6", "constructOpt5") .. "  -  " .. _("height + / -"),
				k("constructOpt7", "?") .. "  -  " .. _("left side"),
				k("constructOpt8", "?") .. "  -  " .. _("right side"),
			},
			generate = {
				_("Click the ground: place the shape"),
				_("Drag the handles: move, resize or turn it"),
				_("Click elsewhere: move it there"),
			},
			slope = { _("Click segments to pick the stretch; first / last drops") },
			shape = {
				_("Click segments to pick the stretch; first / last drops"),
				_("Curve: click a node's handle to select it"),
				_("Curve: Shift+click more handles to select several"),
				_("Curve: drag a handle to change the curve"),
			},
			arrange_line = { _("Click segments to pick the stretch; first / last drops") },
			arrange_circle = {
				_("Click segments (or a closed loop) to pick the stretch"),
				_("Drag the centre / rim handles to adjust the circle"),
			},
			reverse = { _("Click segments to add; a selected one again drops it") },
			add_node = { _("Click a road or track: a node there") },
			remove_node = { _("Click a road or track next to the node to remove") },
			signals = {
				_("Click segments to pick the stretch; first / last drops"),
				_("Drag a signal: move it"),
				_("Click a signal: remove it (again: bring it back)"),
				_("Shift+click the track: add a signal"),
				_("Shift+click a signal: turn its whole track round"),
				_("Ctrl+click a signal: turn just that one"),
				k("constructOpt7", "?") .. "  -  " .. _("lock / unlock the signal under the cursor"),
				k("constructOpt8", "?") .. "  -  " .. _("next type for the signal under the cursor"),
			},
			upgrade = { _("Click a track segment, then one further along") },
			crossover = {
				_("Click a track where the crossovers start"),
				_("Click each track beside it; again drops it"),
				_("Click the first track again: start over"),
			},
			junction = {
				_("Click a track where the branch leaves it"),
				_("Drag the handle; drop on a track to join it"),
				_("Click tracks beside it to branch them too"),
				_("Siding: drag the handle along (length) / across (side)"),
				_("Loop: also drag the start handle along the track"),
			},
		}
		add(card(_("Every tool"), {
			panelLabel(_("Build (panel): build what's planned")),
			panelLabel(_("Right-click: cancel the tool")),
			panelLabel(_("The keys show at the bottom right while a tool runs")),
		}))
		for __, def in ipairs(TOOLS) do
			local lines = CONTROLS[def.id]
			if lines then
				add(foldCard(_(def.name), string.format(_("%d controls"), #lines), "controls." .. def.id, function() : TreeNodeId
					local rows : {TreeNodeId} = {}
					for ___, line in ipairs(lines) do rows[#rows + 1] = panelLabel(line) end
					return builtin.BoxLayout{ orientation = builtin.type.Orientation.Vertical, children = rows }
				end, def.id == tool))
			end
		end
	end
	if tabOfTool == "settings" then
		local so = shared.opts
		-- a card's action button in the game's "secondary" style (was a plain-text button)
		local function actionButton(text : string, tip : string, onClick : function()) : TreeNodeId
			return builtin.Button{ meta = { tooltip = tip, class = "secondary, ntools-action-btn" }, content = panelLabel(text), onClick = onClick }
		end
		-- what the tools draw in the world: their markers and icons, colours and sizes (shared/
		-- ntools_handles, the overlays). Was two cards, Display and Look
		local lineQ = math.floor(((so.lineScale or 1) * 4) + 0.5)       -- quarters: 2 .. 12 (0.5 .. 3)
		local handleQ = math.floor(((so.handleScale or 1) * 4) + 0.5)   -- quarters: 2 .. 10 (0.5 .. 2.5)
		add(card(_("World"), {
			labelledRow(_("Colours"), {
				segmented({ _("Default"), _("Colour-blind"), _("High contrast") }, so.colorPreset or 1,
					function(i : integer) so.colorPreset = i end, nil, {
						_("Blue highlights, green / red for good / bad"),
						_("Okabe-Ito colours: blue / orange instead of green / red, easy to tell apart with colour blindness"),
						_("Bright cyan, magenta and yellow: stands out on any ground"),
					}, false),
			}),
			sliderRow(_("Line"), _("Thickness of a selected stretch's highlight and its end dots"), 2, 12, lineQ,
				function(v : integer) so.lineScale = v / 4 end, string.format("x%.2g", lineQ / 4)),
			sliderRow(_("Handles"), _("Size of the drag handles, drawn and how near a click grabs them"), 2, 10, handleQ,
				function(v : integer) so.handleScale = v / 4 end, string.format("x%.2g", handleQ / 4)),
			option(_("Signal marker detail"), _("Signal markers with the tick pointing the way trains pass, and tags for switch / exit / crossing signals (off: rings only)"), so.markerDetail ~= false,
				function(v : boolean) so.markerDetail = v end),
			option(_("Build icons"), _("A short tick over each new signal and a cross where one was taken out, after building"), so.hudIcons ~= false,
				function(v : boolean) so.hudIcons = v end),
			option(_("Footprint"), _("Tint the ground a shape will take while you place it (Generate)"), so.footprints ~= false,
				function(v : boolean) so.footprints = v end),
		}))
		-- the tags the tools show in the world (shared/ntools_labels): folded, which tags are on in the
		-- summary line; the tags indented under the main switch, greyed with labels off
		do
			local labelsOn = so.labels ~= false
			local range = math.floor((so.labelRange or 4000) / 500 + 0.5)
			local TAGS : {{string, string, string}} = {
				{ "labelSpeed", _("Speed"), _("The speed a train or vehicle can run there") },
				{ "labelGrade", _("Gradient"), _("How steep it is, in %") },
				{ "labelRadius", _("Curve radius"), _("Where the curve limits the speed, or is too tight") },
				{ "labelHeight", _("Bridge / tunnel height"), _("How high a bridge stands, how deep a tunnel runs") },
				{ "labelTotal", _("Total length"), _("The whole build's length, on one label") },
				{ "labelDetail", _("More on hover"), _("Extra lines on the label under the cursor: length, height above ground, type") },
			}
			local sot = so as {string : any}
			local onNames : {string} = {}
			for __, t in ipairs(TAGS) do if sot[t[1]] ~= false then onNames[#onNames + 1] = t[2]:lower() end end
			local summary = labelsOn and (string.format(_("%d of %d tags"), #onNames, #TAGS) .. "  ·  "
				.. ({ _("auto size"), _("compact"), _("full size") })[so.labelSize or 1] .. "  ·  " .. string.format("%.1f km", range * 0.5))
				or _("Off")
			add(foldCard(_("Preview labels"), summary, "settings.labels", function() : TreeNodeId
				local tagRows : {TreeNodeId} = {}
				for __, t in ipairs(TAGS) do
					local key = t[1]
					tagRows[#tagRows + 1] = option(t[2], t[3], sot[key] ~= false, function(v : boolean) sot[key] = v end, labelsOn)
				end
				return builtin.BoxLayout{ orientation = builtin.type.Orientation.Vertical, children = {
					option(_("Show preview labels"), _("The tags over a preview and a selection: speed, gradient, radius, height ..."), labelsOn,
						function(v : boolean) so.labels = v end),
					indented(tagRows),
					labelledRow(_("Size"), {
						segmented({ _("Auto"), _("Compact"), _("Full") }, so.labelSize or 1,
							function(i : integer) so.labelSize = i end, nil, {
								_("Full near the camera, compact further off (as the game's own)"),
								_("Always the small labels"),
								_("Always the full-size labels"),
							}, false, labelsOn),
					}, labelsOn),
					sliderRow(_("Range"), _("Labels further from the camera than this aren't shown"), 1, 20, range,
						function(v : integer) so.labelRange = v * 500 end,
						string.format("%.1f km", range * 0.5), labelsOn),
				} }
			end, false))
		end
		add(card(_("Panel"), {
			option(_("Open on the last tool"), _("Open the panel on the tool used last (off: on the tool tiles, no tool running)"), so.panelLastTool ~= false,
				function(v : boolean) so.panelLastTool = v end),
			option(_("Compact panel"), _("Smaller tool tiles, five to a row"), so.compactPanel == true,
				function(v : boolean) so.compactPanel = v end),
			option(_("Anarchy on by default"), _("The tools start with Anarchy (no collision checks) on whenever the panel opens"), so.anarchyDefault == true,
				function(v : boolean) so.anarchyDefault = v end),
			option(_("Build menu tab"), _("The tools also in a Network Tools tab of the Roads / Tracks build menus, with the game's own option panel (the way in on console). Takes effect when the menus are next built - after a reload"), so.buildMenu ~= false,
				function(v : boolean) so.buildMenu = v end),
			actionButton(_("Reset panel position"), _("Put the panel back where it first opened"), function()
				pcall(function() api.gui.byId.resetMovedWindowPosition(PANEL_WINDOW_ID) end)
			end),
		}))
		-- saving and the debug log (were two cards, the log's alone)
		add(card(_("Saving & diagnostics"), {
			option(_("Remember settings with the savegame"), _("Every tool's settings are kept in the savegame and come back when you load it"), so.saveSettings ~= false,
				function(v : boolean) so.saveSettings = v end),
			option(_("Debug log"), _("Write the tools' traces and errors to the game's log (stdout.txt) - for bug reports; off for normal play"), debugMod.DEBUG == true,
				function(v : boolean) debugMod.setDebug(v) end),
			actionButton(_("Reset all settings"), _("Every tool's settings back to how they start (the road type and the current selection stay)"), function()
				persist.reset()
			end),
		}))
	end

	-- network dropdown (both tools): same as selected, or any road / track type of this year
	-- (no building tool: the list's window says so - set again below when there is one)
	g_netListBuilder = nil
	g_netWindowKey = "none"
	if not onSettings and (tool == "connect" or tool == "parallel" or tool == "generate") then
		-- each entry: the build menu's icon, then the name (rail types marked)
		-- icon | name, with the details (speed, lanes) in small text under it, so long names fit
		-- (iconClass: "ntools-net-symbol" for a white game symbol in the icon's slot)
		local function entry(icon : string, text : string, details? : string, iconClass? : string, maxName? : integer) : TreeNodeId
			local kids : {TreeNodeId} = {}
			if icon then
				kids[#kids + 1] = builtin.ImageView{ meta = { class = iconClass or "ntools-net-icon" }, path = icon, scaling = builtin.type.ImageViewScaling.AutoFit }
			end
			-- long names would run past the row's edge (the TextView doesn't clip): shortened, the
			-- row's tooltip has the full name
			local MAX_NAME = maxName or 46
			if #text > MAX_NAME then text = (text:sub(1, MAX_NAME - 1):gsub("%s+$", "")) .. "…" end
			local lines : {TreeNodeId} = { builtin.TextView{ meta = { class = "font-scale-body, ntools-net-name" }, text = text } }
			if details and details ~= "" then
				lines[#lines + 1] = builtin.TextView{ meta = { class = "font-scale-annotation", styleSheet = dimText() }, text = details }
			end
			kids[#kids + 1] = builtin.BoxLayout{ orientation = builtin.type.Orientation.Vertical, children = lines }
			return builtin.BoxLayout{ orientation = builtin.type.Orientation.Horizontal, children = kids }
		end
		-- search: every word typed must appear in the name (or "rail" / "road")
		local query = (networkSearch:old() or ""):lower()
		local words : {string} = {}
		for w in query:gmatch("%S+") do words[#words + 1] = w end
		-- filters: the build menu's filter categories (icons), any of the switched-on ones
		local _f = netFilterUi:old()   -- read so filter changes re-render
		local filterOn = next(g_netFilter) ~= nil
		local categoryOn = next(g_netCategory) ~= nil
		local anyOn = filterOn or categoryOn
		local function hasAny(list : {string}, on : {string : boolean}) : boolean
			for __, c in ipairs(list or {}) do
				if on[c] then return true end
			end
			return false
		end
		-- any of the switched-on categories, and any of the switched-on filters (a row with nothing
		-- on doesn't filter)
		local function passes(n : Network) : boolean
			if categoryOn and not hasAny(n.categories, g_netCategory) then return false end
			if filterOn and not hasAny(n.filters, g_netFilter) then return false end
			return true
		end
		local function matches(n : Network) : boolean
			if not passes(n) then return false end
			local hay = (n.name .. " " .. (n.isTrack and "rail track" or "road street")):lower()
			for __, w in ipairs(words) do
				if not hay:find(w, 1, true) then return false end
			end
			return true
		end
		-- the details line: kind, top speed, lanes / tracks, one-way / electrified
		local function details(n : Network) : string
			local facts : {string} = { n.isTrack and _("Rail") or (n.country and _("Country road") or _("Town street")) }
			if n.speed and n.speed > 0 then facts[#facts + 1] = string.format("%d km/h", math.floor(n.speed + 0.5)) end
			if n.lanes and n.lanes > 0 then
				if n.isTrack then
					facts[#facts + 1] = n.lanes == 1 and _("1 track") or string.format(_("%d tracks"), n.lanes)
				else
					facts[#facts + 1] = n.lanes == 1 and _("1 lane") or string.format(_("%d lanes"), n.lanes)
				end
			end
			if not n.isTrack and n.oneWay then facts[#facts + 1] = _("one-way") end
			if n.isTrack and n.electric then facts[#facts + 1] = _("electrified") end
			return table.concat(facts, "  ·  ")
		end
		-- the card's open part: search, filters, list (built only while the card is open)
		local function buildList() : TreeNodeId
		local filtering = #words > 0 or anyOn
		local current = networkPanelUi:old() or 0
		-- A list of buttons, not a ComboBox: a ComboBox entry must be a single TextView or ImageView
		-- (an icon + name layout in one crashed the engine: "downcast" assertion). The picked type
		-- comes first, then up to NET_ROWS matches; search / filters narrow the rest down.
		-- every match is listed (in a scrolling box ~8 rows tall); the cap only guards the frame rate
		local NET_ROWS = 300
		local function row(id : integer, icon : string, text : string, tip : string, more? : string, iconClass? : string) : TreeNodeId
			return builtin.ToggleButton{
				meta = { tooltip = tip, class = "ntools-net-row" },
				content = entry(icon, text, more, iconClass),
				value = current == id and 1 or 0,
				onValueChange = function(v : integer)
					-- clicking the picked one again goes back to "same as selected"
					local pick = (v == 1) and id or 0
					H.set("network", pick ~= 0 and pick or nil)
				end,
			}
		end
		local rows : {TreeNodeId} = {
			-- (as the Network card shows it: the copy symbol, a details line)
			row(0, "::/gui/line_vehicle_mgmt/icons/symbol_square_copy.tga", _("Same as selected"),
				_("Build the type of the road or track you start from"),
				_("Builds the type of the road or track you start from"), "ntools-net-symbol"),
		}
		local shown, listed = 0, 0
		-- every type goes to the table (the build menu's order; a header click there sorts them); the
		-- ones search / filters leave are marked - the others hidden, not taken out. The picked one
		-- stays in its place, lit, not moved up: a moving row confuses
		local allTypes = H.listNetworks()
		g_netShown = {}
		for __, n in ipairs(allTypes) do
			if matches(n) then
				shown = shown + 1
				listed = listed + 1
				g_netShown[n.id] = true
			end
		end
		-- the filter icons: every build-menu filter category one of the types uses, in the game's
		-- order, as icon toggles like the build menu's (rows of FILTERS_PER_ROW)
		local filterRows : {TreeNodeId} = {}
		do
			local FILTERS_PER_ROW = 9
			-- one row of icon toggles: every category of `known` that one of the types uses, in the
			-- game's order; `on` holds the switched-on ones
			local function iconRow(field : string, known : {string : MenuCategoryUtil.FilterCategory}, on : {string : boolean})
				local used : {string : boolean} = {}
				for __, n in ipairs(H.listNetworks()) do
					-- (the filters row: only the types in the switched-on categories - a filter none of
					-- them has is hidden)
					if field == "categories" or not categoryOn or hasAny(n.categories, g_netCategory) then
						local list = (field == "categories") and n.categories or n.filters
						for ___, c in ipairs(list or {}) do used[c] = true end
					end
				end
				-- a hidden filter left switched on would still filter (and nothing would show it): off
				if field ~= "categories" then
					for c, ___ in pairs(on) do if not used[c] then on[c] = nil end end
				end
				local cats : {MenuCategoryUtil.FilterCategory} = {}
				for c, ___ in pairs(used) do
					local fc = known and known[c]
					if fc and fc.icon and fc.icon ~= "" then cats[#cats + 1] = fc end
				end
				table.sort(cats, menu_category_util.filterCategoryLess)
				if #cats == 0 then return end
				-- the build menu's own filter bar (menu_category_util.CategoryFilterPanel): its icons,
				-- look and behaviour; Escape (its "give up focus") closes the list's window
				local selection : {boolean} = {}
				for i, fc in ipairs(cats) do selection[i] = on[fc.category] == true end
				filterRows[#filterRows + 1] = menu_category_util.CategoryFilterPanel{
					categories = cats,
					selection = selection,
					updateSelection = function(index : integer, isSelected : boolean)
						local fc = cats[index]
						if fc then on[fc.category] = isSelected or nil end
					end,
					isListEmpty = function() : boolean return false end,
					giveUpFocus = closeNetWindow,
				}
			end
			-- first the build menu's categories (small / medium / large streets, country roads,
			-- highways, tracks), then its filters (trees, trams, buses, barriers...)
			iconRow("categories", fetchMenuCategories(), g_netCategory)
			local okC, filterCats = pcall(menu_category_util.fetchMenuFilterCategories)
			iconRow("filters", okC and filterCats or {}, g_netFilter)
			if anyOn then
				filterRows[#filterRows + 1] = smallButton(_("Clear filters"), _("Show all types again"), function()
					for c, ___ in pairs(g_netFilter) do g_netFilter[c] = nil end
					for c, ___ in pairs(g_netCategory) do g_netCategory[c] = nil end
				end)
			end
		end
		local networkItems : {TreeNodeId} = {
			builtin.TextInputField{
				meta = { tooltip = _("Type to filter the road and track types (several words: all must match)"), class = "ntools-net-search, font-scale-body" },
				value = g_networkSearch,
				placeholderText = _("Search road / track types..."),
				onTyping = function(text : string) g_networkSearch = text or "" end,
				onValueChange = function(text : string) g_networkSearch = text or "" end,
				onCancel = function() g_networkSearch = "" end,
				-- take the keyboard from the running tool (its shortcuts) while typing, give it back after
				focusOnStartEditing = true,
				popFocusOnStopEditing = true,
			} as Builtin.TextInputFieldParam,
		}
		-- search, filter icons, then "Same as selected" and the table (as the build menu: filters
		-- above the types; the table scrolls itself, a header click sorts it)
		for __, r in ipairs(filterRows) do networkItems[#networkItems + 1] = r end
		for __, r in ipairs(rows) do networkItems[#networkItems + 1] = r end
		if shown > 0 then networkItems[#networkItems + 1] = networksTable(allTypes, current, query .. "|" .. tostring(_f)) end
		local hidden = shown - listed
		if hidden > 0 then
			networkItems[#networkItems + 1] = panelLabel(string.format(_("+ %d more - type to search or use the filters"), hidden))
		elseif filtering then
			networkItems[#networkItems + 1] = panelLabel(string.format(_("%d matching"), shown))
		end
		return builtin.BoxLayout{ orientation = builtin.type.Orientation.Vertical, children = networkItems }
		end
		-- the card's always-shown part: the picked type (as the warehouse's stock card)
		local function buildPicked() : TreeNodeId
			local picked = networkPanelUi:old() or 0
			for __, n in ipairs(H.listNetworks()) do
				if n.id == picked then
					-- shorter than the list's rows: the two buttons share the line (full name in the tooltip)
					return builtin.Component{ meta = { tooltip = n.name }, layout = entry(n.icon, n.name, details(n), nil, 44) }
				end
			end
			return entry("::/gui/line_vehicle_mgmt/icons/symbol_square_copy.tga", _("Same as selected"),
				_("Builds the type of the road or track you start from"), "ntools-net-symbol")
		end
		-- the list lives in its own window (NtoolsNetWindow): its builder and what it shows, handed
		-- over each render
		g_netListBuilder = buildList
		local nTypes = #H.listNetworks()
		g_netWindowKey = query .. "|" .. tostring(_f) .. "|" .. tostring(networkPanelUi:old() or 0) .. "|" .. tostring(nTypes)
		-- the card: the picked type, then small icon buttons in the game's "secondary" style (as the
		-- vehicle manager's): Change (opens the list's window) and, once a type is picked, × back to
		-- "Same as selected". Built here, not with button_react_util: its icon has no class, so it
		-- showed at the file's full size. No fold-out part: its arrow looked like the list would
		-- fold out here
		local function actionButton(icon : string, tip : string, onClick : function()) : TreeNodeId
			return builtin.Button{
				meta = { tooltip = tip, class = "secondary, ntools-net-action" },
				content = builtin.ImageView{ meta = { class = "ntools-net-action-icon" }, path = icon, scaling = builtin.type.ImageViewScaling.AutoFit },
				onClick = onClick,
			}
		end
		local function buildPickedRow() : TreeNodeId
			local kids : {TreeNodeId} = { buildPicked(), gui_react_util.makeHorizontalSpacer() }
			if (networkPanelUi:old() or 0) ~= 0 then
				kids[#kids + 1] = actionButton("::/gui/menu/icons/symbol_x.tga", _("Back to \"Same as selected\""),
					function() H.set("network", nil) end)
			end
			kids[#kids + 1] = actionButton("::/gui/line_vehicle_mgmt/icons/replace.tga",
				_("Change the road / track type (opens the list in its own window)"), openNetWindow)
			return builtin.BoxLayout{ meta = { class = "ntools-net-picked" }, orientation = builtin.type.Orientation.Horizontal, children = kids }
		end
		add(content_card.ContentCard{
			title = _("Network"),
			initialCalloutTextPermanent = "",
			recipeAndParamPermanent = content_card.makeRecipeAndParam(NodeHost, { make = buildPickedRow }),
		})
	end

	-- options shared by all tools (shared/ntools_options), like the game's road / track builders
	local _sk = sharedKeyUi:old()   -- read so changes re-render
	local so = shared.opts
	local builds = not onSettings and (tool == "connect" or tool == "parallel" or tool == "generate")
	-- Branch -> Junction: its free end takes Connect's height options, its branch can be a bridge / tunnel
	local junctionHeights = not onSettings and tool == "junction" and ((g_jn and g_jn.mode) or 1) == 1
	-- One Structures card: the structure first (in the name column, as the rows under it), then what
	-- each choice uses - Auto's heights, the bridge / tunnel types (Connect) - greyed while the choice
	-- doesn't use them (the game's way of showing an option that doesn't apply; hidden, the card
	-- would jump), then Underground (a view toggle) last
	if tool and not onSettings then
		-- the bridge / tunnel / level crossing types (the same choice as the build menu's pickers):
		-- Automatic, None, or any type of this year. A type for the wrong carrier (a road bridge on
		-- a track) is passed over for the automatic one when building. (Locals in this block: the
		-- render function is near Lua's 200-local limit)
		local function typeCombo(label : string, tip : string, rep : ResTypeRep<integer, table>, key : string, enabled : boolean) : TreeNodeId
			local okL, objects = pcall(function() : {MenuCategoryUtil.FilterObject}
				return menu_category_util.getAvailableObjectsSorted(rep, api.engine.util.getYear())
			end)
			objects = okL and objects or {}
			-- (a ComboBox entry must be a single TextView)
			local items : {TreeNodeId} = {
				builtin.ComboBoxItem{ value = 0, content = panelLabel(_("Automatic")) },
				builtin.ComboBoxItem{ value = -1, content = panelLabel(_("None")) },
			}
			local cur = H.get(key) as integer
			local current = cur == nil and 0 or (cur < 0 and -1 or 0)
			for i, o in ipairs(objects) do
				local carriers : {string} = {}
				-- (not `_` as the loop variable: it would hide the translation function)
				for __, c in ipairs(o.carriers or {}) do
					if c == api.type["enum"].Carrier.RAIL then carriers[#carriers + 1] = _("rail")
					elseif c == api.type["enum"].Carrier.ROAD then carriers[#carriers + 1] = _("road") end
				end
				local text = _(o.name or "?") .. (#carriers > 0 and ("  (" .. table.concat(carriers, ", ") .. ")") or "")
				items[#items + 1] = builtin.ComboBoxItem{ value = i, content = panelLabel(text) }
				if cur ~= nil and cur >= 0 and o.id == cur then current = i end
			end
			return labelledRow(label, {
				builtin.ComboBox{
					meta = { tooltip = tip, class = "ntools-slider", enabled = enabled },
					items = items,
					value = current,
					onValueChange = function(v : integer|number|string)
						local i = math.floor(tonumber(v) or 0)
						if i == 0 then H.set(key, nil)
						elseif i < 0 then H.set(key, -1)
						elseif objects[i] then H.set(key, objects[i].id) end
					end,
				},
			}, enabled)
		end
		local st = so.structure or 1   -- 1 Auto, 2 Ground, 3 Bridge, 4 Tunnel
		local auto = st == 1
		local structItems : {TreeNodeId} = {
			labelledRow(_("Structure"), {
				segmented({ _("Auto"), _("Ground"), _("Bridge"), _("Tunnel") }, st,
					function(i : integer) so.structure = i end, nil, {
						_("Bridges and tunnels where the new track or road runs high or deep (the heights below)"),
						_("Everything new on the ground, however high or deep it runs"),
						_("Everything new on a bridge"),
						_("Everything new in a tunnel"),
					}, false),
			}),
		}
		if builds or junctionHeights or tool == "slope" or tool == "shape" or tool == "arrange_line" or tool == "arrange_circle" then
			local why = auto and "" or ("\n" .. _("Only used with Structure: Auto"))
			structItems[#structItems + 1] = sliderRow(_("Bridge height"), _("A piece running at least this high above the ground (on average) becomes a bridge") .. why,
				1, 20, math.floor(so.bridgeHeight + 0.5), function(v : integer) so.bridgeHeight = v end, string.format("%d m", math.floor(so.bridgeHeight + 0.5)), auto)
			structItems[#structItems + 1] = sliderRow(_("Tunnel depth"), _("A piece running at least this deep below the ground (on average) becomes a tunnel") .. why,
				2, 30, math.floor(so.tunnelDepth + 0.5), function(v : integer) so.tunnelDepth = v end, string.format("%d m", math.floor(so.tunnelDepth + 0.5)), auto)
		end
		if tool == "connect" then
			local _poll = structUi:old()   -- read so a type picked by key re-renders
			structItems[#structItems + 1] = typeCombo(_("Bridge type"), _("Bridge type for the bridges this builds (Structure: Auto or Bridge)"),
				api.res.bridgeTypeRep as ResTypeRep<integer, table>, "bridgeType", st == 1 or st == 3)
			structItems[#structItems + 1] = typeCombo(_("Tunnel type"), _("Tunnel type for the tunnels this builds (Structure: Auto or Tunnel)"),
				api.res.tunnelTypeRep as ResTypeRep<integer, table>, "tunnelType", st == 1 or st == 4)
			structItems[#structItems + 1] = typeCombo(_("Crossing"), _("Level crossing type where a road meets rail (None: no crossing is made)"),
				api.res.railroadCrossingTypeRep as ResTypeRep<integer, table>, "rcType", true)
		end
		structItems[#structItems + 1] = option(_("Underground"), _("Show and pick only underground roads and tracks (tunnels), like the game's builders"), so.underground == true,
			function(v : boolean) so.underground = v end)
		add(card(_("Structures"), structItems))
	end
	if builds then
		-- the build menu's own icons (filter categories) as toggles: catenary, tram, bus, decorations
		local okI, cats = pcall(menu_category_util.fetchMenuFilterCategories)
		local function iconOf(cat : string) : string
			return okI and cats and cats[cat] and cats[cat].icon or nil
		end
		local electric = so.catenary == 2
		local tramOn = so.tram ~= 1
		-- the picked type: a track greys the road-only options (as Structures greys what its choice
		-- doesn't use). Same as selected: unknown until the click, nothing greyed
		local pickedTrack = false
		do
			local pid = networkPanelUi:old() or 0
			if pid ~= 0 then
				for __, n in ipairs(H.listNetworks()) do
					if n.id == pid then pickedTrack = n.isTrack == true; break end
				end
			end
		end
		local roadOnly = _("Roads only - the picked type is a track")
		-- the build menu's icon with its name beside it (as the game's makeIconToggleButton lays an
		-- icon and text out), two to a row
		local function featureToggle(cat : string, name : string, tip : string, on : boolean, set : function(boolean), enabled? : boolean) : TreeNodeId
			local icon = iconOf(cat)
			local kids : {TreeNodeId} = {}
			if icon then kids[#kids + 1] = builtin.ImageView{ meta = { class = "ntools-feature-icon" }, path = icon, scaling = builtin.type.ImageViewScaling.AutoFit } end
			kids[#kids + 1] = panelLabel(name)
			return builtin.ToggleButton{
				meta = { tooltip = (enabled == false) and (tip .. "\n" .. roadOnly) or tip, class = "ntools-feature", enabled = enabled ~= false },
				content = builtin.BoxLayout{ orientation = builtin.type.Orientation.Horizontal, children = kids },
				value = on and 1 or 0,
				onValueChange = function(v : integer) set(v == 1) end,
			}
		end
		add(card(_("New roads & tracks"), {
			panelRow({
				featureToggle("catenary", _("Catenary"), _("Catenary: electrified tracks - on a road, electric trams (only with Tram on)"), electric, function(v : boolean)
					so.catenary = v and 2 or 1
					if so.tram ~= 1 then so.tram = v and 3 or 2 end
				end),
				featureToggle("tram", _("Tram"), _("Tram track on the outer (or inner) lane of each direction"), tramOn, function(v : boolean)
					so.tram = v and (so.catenary == 2 and 3 or 2) or 1
				end, not pickedTrack),
			}),
			panelRow({
				featureToggle("bus", _("Bus lane"), _("Bus lane: the outer (or inner) lane of each direction is for buses (and trams) only"), so.busLane == true, function(v : boolean)
					so.busLane = v
				end, not pickedTrack),
				featureToggle("tree", _("Decorations"), _("The network's default decorations (trees, walls, fences...)"), so.decorations ~= false, function(v : boolean)
					so.decorations = v
				end),
			}),
			option(_("Lock development"), _("Towns may not upgrade or extend the new roads") .. (pickedTrack and ("\n" .. roadOnly) or ""), so.lockDevelopment == true,
				function(v : boolean) so.lockDevelopment = v end, not pickedTrack),
			option(_("Player owned"), _("The new roads belong to your company instead of the town") .. (pickedTrack and ("\n" .. roadOnly) or ""), so.playerOwned == true,
				function(v : boolean) so.playerOwned = v end, not pickedTrack),
		}))
	end
	if junctionHeights then
		local inc = so.incline
		local heightItems : {TreeNodeId} = {
			sliderRow(_("Height offset"), _("The branch's free end is built this far above (+) or below (-) the ground. 0: it carries on at the track's grade"),
				-20, 40, math.floor(so.heightOffset + 0.5), function(v : integer) so.heightOffset = v end, string.format("%+d m", math.floor(so.heightOffset + 0.5)), inc == nil),
			option(_("Fixed incline"), _("The branch climbs (or drops) at this grade from the switch to its free end, instead of the height offset"), inc ~= nil,
				function(v : boolean) so.incline = v and 0 or nil end),
			-- always there, greyed until Fixed incline is on (as Connect's)
			sliderRow(_("Incline"), _("Grade from the switch to the branch's end (negative: downhill)") .. (inc == nil and ("\n" .. _("Turn on Fixed incline to use it")) or ""),
				-24, 24, math.floor((inc or 0) * 2 + 0.5), function(v : integer) so.incline = v / 2 end, string.format("%+.1f %%", inc or 0), inc ~= nil),
		}
		heightItems[#heightItems + 1] = builtin.TextView{ meta = { class = "font-scale-body, ntools-note" },
			text = _("The branch leaves the switch at the track's own grade, then eases to the height.") }
		add(card(_("Height & placement"), heightItems))
	end
	if not onSettings and (tool == "connect" or tool == "generate") then
		local heightItems : {TreeNodeId} = {
			sliderRow(_("Height offset"), _("Points on bare ground are built this far above (+) or below (-) the ground"),
				-20, 40, math.floor(so.heightOffset + 0.5), function(v : integer) so.heightOffset = v end, string.format("%+d m", math.floor(so.heightOffset + 0.5))),
		}
		if tool == "connect" and so.pointLabel then
			-- the selected circle / waypoint's own height (Connect picks it up)
			local h = math.floor((so.pointHeight or 0) + 0.5)
			local split = so.pointCircle and so.pointHeightEnd ~= nil
			heightItems[#heightItems + 1] = sliderRow(split and (_("Arc start height") .. " (" .. so.pointLabel .. ")") or (_("Height at") .. " " .. so.pointLabel),
				_("The road is raised (+) or lowered (-) this much at the selected circle / waypoint, easing back towards its neighbours"),
				-20, 40, h, function(v : integer) so.pointHeight = v end, string.format("%+d m", h))
			if so.pointCircle then
				-- the selected circle: end-of-arc height, radius, structure, position (Connect applies them)
				heightItems[#heightItems + 1] = option(_("Different height at the arc's end"),
					_("The road climbs (or drops) round the circle: from the height above where it joins the arc to this one where it leaves"),
					split, function(v : boolean) so.pointHeightEnd = v and (so.pointHeight or 0) or nil end)
				if split then
					local he = math.floor(so.pointHeightEnd + 0.5)
					heightItems[#heightItems + 1] = sliderRow(_("Arc end height"), _("The height offset where the road leaves the circle"),
						-20, 60, he, function(v : integer) so.pointHeightEnd = v end, string.format("%+d m", he))
				end
				local r = math.floor((so.pointRadius or 0) + 0.5)
				heightItems[#heightItems + 1] = sliderRow(_("Radius"), _("The selected circle's radius (dragging its ring changes it too)"),
					5, 500, math.max(5, r), function(v : integer) so.pointRadius = v end, string.format("%d m", r))
				-- (the card's whole width, like Mode: four options don't fit beside a name column)
				heightItems[#heightItems + 1] = segmented({ _("Auto"), _("Ground"), _("Bridge"), _("Tunnel") }, so.pointStructure or 1,
					function(i : integer) so.pointStructure = i end,
					_("Structure of the road round this circle: Auto decides from the height above the ground; the others force it for this arc"),
					nil, true)
				if so.pointMovable then
					local function nudge(dx : number, dy : number) : function()
						return function() so.pointMove = { dx, dy } end
					end
					local tip = _("Move the selected circle's centre 5 m along the map's X / Y axis")
					heightItems[#heightItems + 1] = labelledRow(_("Move"), {
						smallButton("X -5", tip, nudge(-5, 0)),
						smallButton("X +5", tip, nudge(5, 0)),
						smallButton("Y -5", tip, nudge(0, -5)),
						smallButton("Y +5", tip, nudge(0, 5)),
					})
				end
			end
		end
		if tool == "connect" then
			-- (Height offset stays on with a fixed incline: it lifts the free end the grade starts from)
			local inc = so.incline
			heightItems[#heightItems + 1] = option(_("Fixed incline"), _("An end on bare ground takes its height from the other end and this grade (instead of the ground)"), inc ~= nil,
				function(v : boolean) so.incline = v and 0 or nil end)
			-- always there, greyed until Fixed incline is on (shown only then, the card jumped)
			heightItems[#heightItems + 1] = sliderRow(_("Incline"), _("Grade from the first point to the second (negative: downhill)") .. (inc == nil and ("\n" .. _("Turn on Fixed incline to use it")) or ""),
				-24, 24, math.floor((inc or 0) * 2 + 0.5), function(v : integer) so.incline = v / 2 end, string.format("%+.1f %%", inc or 0), inc ~= nil)
			-- (Snap to roads and Override lanes: in the Options list - they aren't about height)
		end
		add(card(_("Height & placement"), heightItems))
	end

	-- the running tool's Reset / Build row, added last (see the spacer below)
	local footer : TreeNodeId = nil

	local toolParams : ConstructionCustomActionParams<any> = {
		isActive = true,
		setActionFn = params.payload.setActionFn,
		abort = params.payload.close,
		getCurrentParams = function() : {string : number} return {} end,
		definition = nil,
	}
	-- the tools whose only key prompt is Back share one stylesheet rule through this class on their
	-- recipe node, instead of a rule each (the game limits the total number of stylesheet rules
	-- across all mods); Connect, Parallel and Signals keep their own lists (R::<recipe> rules)
	if tool ~= "connect" and tool ~= "parallel" and tool ~= "signals" then
		(toolParams as {string : any}).meta = { class = "ntools-basic-prompts" }
	end

	-- Branch (the "junction" tile): Junction, Siding or Passing loop, by its Type - each its own tool
	local branchKind : string = nil
	-- (a game saved while Siding / Passing loop were tiles of their own: now the Branch tile's types;
	-- the Station throat / Platforms type is gone - a game saved on it opens on Junction)
	if tool == "siding" or tool == "loop" or tool == "throat" then
		if g_jn then g_jn.mode = ({ siding = 2, loop = 3, throat = 1 } as {string : integer})[tool] end
		tool = "junction"
	end
	if g_jn and (g_jn.mode or 1) > 3 then g_jn.mode = 1 end
	if tool == "junction" then branchKind = ({ "junction", "siding", "loop" })[g_jn and g_jn.mode or 1] or "junction" end
	-- Rejoin with Drag handles: the Siding tool, as a passing loop between its two handles
	local rejoinHandles = branchKind == "loop" and g_loop ~= nil and g_loop.handles == true
	if g_sd then g_sd.rejoin = rejoinHandles end
	if rejoinHandles then branchKind = "siding" end
	-- (Siding and Passing loop are one type: its End picks which - a dead end, or rejoining the line)
	local function branchTypeCard()
		local mode = g_jn.mode or 1
		local rows : {TreeNodeId} = {
			labelledRow(_("Type"), {
				segmented({ _("Junction"), _("Siding") }, mode == 1 and 1 or 2,
					function(i : integer) g_jn.mode = i == 1 and 1 or (g_jn.siding or 2) end, nil, {
						_("A switch and a curving branch you drag out - its end left free"),
						_("Track beside the line: a dead-end siding, or a passing loop that rejoins it"),
					}, false),
			}),
		}
		if mode == 2 or mode == 3 then
			rows[#rows + 1] = labelledRow(_("End"), {
				segmented({ _("Dead end"), _("Rejoin") }, mode == 3 and 2 or 1,
					function(i : integer) g_jn.mode = i + 1; g_jn.siding = i + 1 end, nil, {
						_("A siding: click the track, drag the handle to its end"),
						_("A passing loop: pick a stretch (a segment, then one further along) - it rejoins the line, following its curves"),
					}, false),
			})
		end
		add(card(_("Branch"), rows))
	end

	-- (Settings tab: the running tool's recipe only - it keeps running, none of its options are built)
	local RECIPE_OF : {string : function(ConstructionCustomActionParams<any>) : TreeNodeId} = {
		connect = H.recipes.connect, parallel = H.recipes.parallel, reverse = H.recipes.reverse,
		slope = H.recipes.slope, shape = H.recipes.shape, arrange_line = H.recipes.arrangeLine,
		arrange_circle = H.recipes.arrangeCircle, generate = H.recipes.generate, signals = H.recipes.signals,
		upgrade = H.recipes.upgrade, crossover = H.recipes.crossover, loop = H.recipes.loop,
		junction = (branchKind == "siding" and H.recipes.siding) or (branchKind == "loop" and H.recipes.loop) or H.recipes.junction,
		add_node = H.recipes.addNode, remove_node = H.recipes.removeNode,
	}
	if onSettings and tool and RECIPE_OF[tool] then
		add(RECIPE_OF[tool](toolParams))
	elseif onSettings then
		-- no tool running: nothing to keep going
		params.payload.setActionFn(nil)
	elseif tool == "connect" then
		local mode = modeUi:old() or H.modeConnection
		local modeNames = { _("Link"), _("Loop"), _("Curve"), _("Line"), _("Min. R") }
		local modeTips = {
			_("Arcs joined by straights (drag circles, double-click a straight to add one)"),
			_("One circle touching both roads (corner or full loop)"),
			_("Smooth curve following both road directions"),
			_("Straight line"),
			_("Shortest path with no curve tighter than the radius (the game's own path finder)"),
		}
		-- the extra modes (connect/extra), on a second row: 6 Easement ... 11 Offset
		local extraNames = { _("Ease"), _("Helix"), _("Grade"), _("Spline"), _("Arc"), _("Offset") }
		local extraTips = {
			_("Like Min. R, with the curves eased in and out (transition curves): smoother for trains"),
			_("Like Min. R, with full turns added at the start to climb (or drop) to the other end at the set grade"),
			_("A route over the ground that never climbs steeper than the set grade (finds its way round hills)"),
			_("A smooth curve through the points you click"),
			_("One circular arc: leaving end 1 along its road, or through a point you click"),
			_("An S-shift: two reverse curves from end 1's direction over to a parallel line through end 2"),
		}
		-- The modes in the game's framed button groups (as its builders' options), one row per kind of
		-- mode, one chosen across the rows: the rows without the current mode show none (deselect allowed
		-- - with it not allowed a group lights its first button for "none", so two showed chosen). No
		-- tooltips (they ran out of the card): the chosen mode's description sits under the rows.
		local names : {integer : string} = {}
		local tips : {integer : string} = {}
		for i = 1, 5 do names[i], tips[i] = modeNames[i], modeTips[i] end
		for i = 1, 6 do names[i + 5], tips[i + 5] = extraNames[i], extraTips[i] end
		-- The mode as the Network card: the game's collapsible card - the current mode and what it
		-- does always shown, its arrow opening every mode by kind (each its name and a line on what it
		-- does; a click picks it and closes the list). Built only while open (NodeHost).
		local modeGroups : {{string, {integer}}} = {
			{ _("Shapes you draw"), { 1, 3, 4, 9 } },        -- Link, Curve, Line, Spline
			{ _("Shapes by rule"), { 10, 2, 11, 7 } },       -- Arc, Loop, Offset, Helix
			{ _("Routes found for you"), { 5, 6, 8 } },      -- Min. R, Ease, Grade
		}
		local function modeEntry(m : integer) : TreeNodeId
			return builtin.BoxLayout{
				orientation = builtin.type.Orientation.Vertical,
				children = {
					builtin.TextView{ meta = { class = "font-scale-body, ntools-net-name" }, text = names[m] or "?" },
					-- (wrapping: the longer descriptions ran past the card's edge)
					builtin.TextView{ meta = { class = "font-scale-annotation, ntools-mode-desc", styleSheet = dimText() }, text = tips[m] or "" },
				},
			}
		end
		local function buildModeList() : TreeNodeId
			local rows : {TreeNodeId} = {}
			for __, grp in ipairs(modeGroups) do
				rows[#rows + 1] = builtin.TextView{ meta = { class = "font-scale-annotation", styleSheet = dimText() }, text = grp[1] }
				for __, m in ipairs(grp[2]) do
					rows[#rows + 1] = builtin.ToggleButton{
						meta = { class = "ntools-net-row" },
						content = modeEntry(m),
						value = m == mode and 1 or 0,
						onValueChange = function(__v : integer)
							H.set("mode", m)
							g_modeListOpen = false
						end,
					}
				end
			end
			return builtin.BoxLayout{ orientation = builtin.type.Orientation.Vertical, children = rows }
		end
		local modeRows : {TreeNodeId} = {}
		local ex = require "network_tools_1::/gui/construction/tools/connect/extra/ntools_connect_extra.script.tl" as {string : any}
		local xo = ex.opts as {string : number}
		if mode == 6 then
			modeRows[#modeRows + 1] = sliderRow(_("Easement"), _("Length of each transition curve (where the curve tightens / opens up)"),
				10, 200, math.floor(xo.easeLength + 0.5), function(v : integer) xo.easeLength = v end, string.format("%d m", math.floor(xo.easeLength + 0.5)))
		elseif mode == 7 then
			modeRows[#modeRows + 1] = sliderRow(_("Radius"), _("The helix's turns' radius"),
				40, 400, math.floor(xo.helixRadius + 0.5), function(v : integer) xo.helixRadius = v end, string.format("%d m", math.floor(xo.helixRadius + 0.5)))
			modeRows[#modeRows + 1] = sliderRow(_("Grade"), _("Steepest climb: as many turns are added as it needs to reach the other end's height"),
				5, 60, math.floor(xo.helixGrade * 10 + 0.5), function(v : integer) xo.helixGrade = v / 10 end, string.format("%.1f %%", xo.helixGrade))
		elseif mode == 8 then
			modeRows[#modeRows + 1] = sliderRow(_("Max. grade"), _("The route never climbs steeper than this between two points"),
				5, 80, math.floor(xo.gradeMax * 10 + 0.5), function(v : integer) xo.gradeMax = v / 10 end, string.format("%.1f %%", xo.gradeMax))
		elseif mode == 9 or mode == 10 then
			modeRows[#modeRows + 1] = panelLabel(mode == 9 and _("Click points after both ends: the curve runs through them") or _("Click one point after both ends: the arc runs through it"))
		end
		if mode == 5 or mode == 6 then
			-- Min. radius: 15 .. 2000 m in 5 m steps (or drag a ring in the world)
			local labels : {string} = {}
			for i = 0, 397 do labels[i + 1] = tostring(15 + i * 5) .. " m" end
			local idx = math.floor(clamp(((dubinsRadiusUi:old() or 100) - 15) / 5, 0, 397) + 0.5)
			local tip = _("No curve on the new road is tighter than this. Or drag one of its rings in the world")
			modeRows[#modeRows + 1] = nativeParam(_("Min. radius"), tip, api.type["enum"].ScriptParamType.Slider, labels, idx,
				function(i : integer) H.set("dubinsRadius", 15 + i * 5) end)
				or sliderRow(_("Min. radius"), tip, 0, 397, idx, function(v : integer) H.set("dubinsRadius", 15 + v * 5) end, labels[idx + 1])
		end
		add(content_card.ContentCard{
			title = _("Mode"),
			initialCalloutTextPermanent = "",
			recipeAndParamPermanent = content_card.makeRecipeAndParam(NodeHost, { make = withArrow(function() : TreeNodeId return modeEntry(mode) end,
				function() : boolean return g_modeListOpen end) }),
			initialCalloutTextCollapsible = "",
			recipeAndParamCollapsible = content_card.makeRecipeAndParam(NodeHost, { make = buildModeList }),
			collapsibleExpanded = netPickerOpenUi:old() ~= nil and g_modeListOpen == true,
			setCollapsibleExpanded = function(v : boolean) g_modeListOpen = v end,
		})
		-- the chosen mode's own settings (radius, easement, ...) in a card under it
		if #modeRows > 0 then add(card(_("Mode settings"), modeRows)) end
		-- the planned route's height profile (only once there is one: widgets built and not shown
		-- flood the log)
		do
			local pn = profileNodes()
			if pn then add(card(_("Height profile"), pn)) end
			-- ... and a chain's sections (M): the game's collapsible card (as its industry window's
			-- stocks and consumers) - which section on top, the table under its arrow (each with a
			-- locate pin and a button to go and edit it). Once there are two or more.
			local __c, ctotal = chainInfo()
			if ctotal >= 2 then
				add(content_card.ContentCard{
					title = _("Sections"),
					initialCalloutTextPermanent = "",
					recipeAndParamPermanent = content_card.makeRecipeAndParam(NodeHost, { make = withArrow(sectionsSummary, function() : boolean return g_sectionsOpen end) }),
					initialCalloutTextCollapsible = "",
					recipeAndParamCollapsible = content_card.makeRecipeAndParam(NodeHost, { make = sectionsTable }),
					collapsibleExpanded = netPickerOpenUi:old() ~= nil and g_sectionsOpen == true,
					setCollapsibleExpanded = function(v : boolean) g_sectionsOpen = v end,
				})
			end
		end

		-- Twin: build a parallel copy too (double track, or the other carriageway of a one-way road)
		local twin = twinUi:old() or 0
		add(card(_("Twin"), {
			labelledRow(_("Twin"), {
				segmented({ _("Off"), _("Left"), _("Right") }, twin == 0 and 1 or (twin > 0 and 2 or 3),
					function(i : integer) H.set("twin", i == 1 and 0 or (i == 2 and 1 or -1)) end,
					_("Also build a parallel copy of the connection on this side: double track, or the second carriageway of a one-way road (it runs the other way). Its ends join the parallel line where they land")),
			}),
		}))

		-- the game's CollapsibleCheckboxList (as the mod manager's tag filters): its header (the
		-- game's arrow and how many are on) folds the list away; a click on a row toggles it.
		-- { name, tooltip, on, set, level }: level 2 is indented under the row above (Override lanes
		-- only does anything with Replace)
		do
			local opts : {{string, string, boolean, function(boolean), integer}} = {
				{ _("Live preview"), _("Preview the real road in the world. Off: a schematic of the planned road (coloured lines) instead - much lighter on the frame rate; the game still checks the road when you press Build"),
					liveUi:old() ~= false, function(v : boolean) H.set("live", v) end, 1 },
				{ _("Replace the road between"), _("Edit existing roads: the old road between the two points is removed and the new shape built in its place. Shift+click a road to take its whole stretch"),
					replaceUi:old() == true, function(v : boolean) H.set("replace", v) end, 1 },
				{ _("Override lanes"), _("With Replace: junctions whose lanes or traffic lights you edited may be rebuilt (they get automatic ones again)"),
					so.overrideLanes == true, function(v : boolean) so.overrideLanes = v end, 2 },
				{ _("Follow terrain"), _("Place new nodes on the ground instead of an even slope (T)"),
					followUi:old() == true, function(v : boolean) H.set("follow", v) end, 1 },
				{ _("Snapping"), _("Round radii and let neighbouring circles meet directly (C)"),
					snapUi:old() ~= false, function(v : boolean) H.set("snap", v) end, 1 },
				{ _("Snap to roads"), _("A click on bare ground right next to a road picks the road (hold Shift to place a free point anyway)"),
					so.snapToRoads ~= false, function(v : boolean) so.snapToRoads = v end, 1 },
				{ _("Bridges & tunnels"), _("Bridges where the road runs high, tunnels where it runs deep, and lift loops over themselves"),
					bridgesUi:old() ~= false, function(v : boolean) H.set("bridges", v) end, 1 },
				{ _("Anarchy"), _("Build without collision checks"),
					anarchyUi:old() == true, function(v : boolean) H.set("anarchy", v) end, 1 },
			}
			local nOn = 0
			for __, o in ipairs(opts) do if o[3] then nOn = nOn + 1 end end
			add(card(_("Options"), {
				checkbox_list.CollapsibleCheckboxList{
					-- (a node, as the mod manager passes it - the .d.tl says string, the recipe puts it in a layout)
					header = builtin.TextView{ meta = { class = "font-scale-body" }, text = string.format(_("%d of %d on"), nOn, #opts) } as string,
					hasArrow = true,
					makeEntries = function() : {{TreeNodeId, integer}}
						local entries : {{TreeNodeId, integer}} = {}
						for __, o in ipairs(opts) do
							entries[#entries + 1] = { builtin.TextView{ meta = { class = "font-scale-body", tooltip = o[2] }, text = o[1] }, o[5] }
						end
						return entries
					end,
					isToggled = function(i : integer) : boolean return opts[i] ~= nil and opts[i][3] == true end,
					onToggle = function(i : integer)
						local o = opts[i]
						if o then o[4](not o[3]) end
					end,
				},
			}))
		end
		-- (the bridge / tunnel / crossing types: in the shared Structures card above)
		footer = resetAndBuild(_("Build the connection"))

		add(H.recipes.connect(toolParams))
	elseif tool == "parallel" then
		local offset = parOffsetUi:old() or g_par.autoOffset
		local side = parSideUi:old() or 1
		local height = parHeightUi:old() or 0

		-- the game's own parameter rows (like the street / overpass builders), in half-metre stops;
		-- our own label / slider / value rows are the fallback if the native widget fails
		local offsetLabels, heightLabels : {string}, {string} = {}, {}
		for i = 1, 200 do offsetLabels[i] = string.format("%.1f m", i / 2) end          -- 0.5 .. 100
		for i = 0, 200 do heightLabels[i + 1] = string.format("%+.1f m", (i - 100) / 2) end -- -50 .. +50
		local offsetIdx = math.floor(clamp(offset, 0.5, 100) * 2 + 0.5) - 1
		local heightIdx = math.floor(clamp(height, -50, 50) * 2 + 0.5) + 100
		local offsetTip = _("Distance from the original (, / . keys; Shift = fine)")
		local heightTip = _("Raise or lower the copy (O / P keys)")
		local sideTip = _("Which side of the direction you selected in ([ / ] keys)")
		local SLIDER = api.type["enum"].ScriptParamType.Slider
		local countLabels : {string} = {}
		for i = 1, 8 do countLabels[i] = tostring(i) end
		local countIdx = math.floor(clamp(parCountUi:old() or 1, 1, 8)) - 1
		local countTip = _("How many copies side by side: copy 2 sits twice the offset away, and so on")
		add(card(_("Copy"), {
			nativeParam(_("Copies"), countTip, SLIDER, countLabels, countIdx,
				function(i : integer) g_par.count = i + 1 end)
			or sliderRow(_("Copies"), countTip, 1, 8, countIdx + 1,
				function(v : integer) g_par.count = v end, tostring(countIdx + 1)),
			nativeParam(_("Offset"), offsetTip, SLIDER, offsetLabels, offsetIdx,
				function(i : integer) g_par.offset = (i + 1) / 2 end)
			or sliderRow(_("Offset"), offsetTip, 1, 200, offsetIdx + 1,
				function(v : integer) g_par.offset = v / 2 end, string.format("%.1f m", offset)),
			nativeParam(_("Height"), heightTip, SLIDER, heightLabels, heightIdx,
				function(i : integer) g_par.height = (i - 100) / 2 end)
			or sliderRow(_("Height"), heightTip, -100, 100, heightIdx - 100,
				function(v : integer) g_par.height = v / 2 end, string.format("%+.1f m", height)),
			labelledRow(_("Side"), {
				-- Both: copies on both sides (side 0)
				segmented({ _("Left"), _("Both"), _("Right") }, side > 0 and 1 or (side == 0 and 2 or 3),
					function(i : integer) g_par.side = i == 1 and 1 or (i == 2 and 0 or -1) end, sideTip),
			}),
		}))

		add(card(_("Options"), {
			option(_("Automatic offset"), _("Put the copy right beside the original: the width of the selected road / track, or the standard distance between tracks"), parAutoUi:old() == true,
				function(v : boolean) g_par.offset = (not v) and offset or nil end),
			option(_("Connect ends"), _("Join the copy's ends to the road or track they land on: onto a node close by, or splitting the segment under them"), parEndsUi:old() ~= false,
				function(v : boolean) g_par.connectEnds = v end),
			option(_("Make crossings"), _("Join roads and tracks the copy runs over: a level crossing where road meets rail, a junction otherwise"), parCrossingsUi:old() ~= false,
				function(v : boolean) g_par.crossings = v end),
			option(_("Anarchy"), _("Build without collision checks"), anarchyUi:old() == true,
				function(v : boolean) H.set("anarchy", v) end),
		}))
		footer = resetAndBuild(_("Build the copy"))

		add(H.recipes.parallel(toolParams))
	elseif tool == "reverse" then
		add(card(_("Options"), {
			option(_("Anarchy"), _("Build without collision checks"), anarchyUi:old() == true,
				function(v : boolean) H.set("anarchy", v) end),
		}))
		footer = resetAndBuild(_("Reverse the selected segments"))

		add(H.recipes.reverse(toolParams))
	elseif tool == "slope" then
		local smode = slopeModeUi:old() or 1
		local sarch = slopeArchUi:old() or 0
		local rows : {TreeNodeId} = {
			labelledRow(_("Profile"), {
				segmented({ _("Linear"), _("Ease"), _("Arch") }, smode, function(i : integer) g_slope.mode = i end, nil, {
					_("One constant gradient from end to end"),
					_("Gentle at both ends, steepest in the middle"),
					_("Rise above the straight line in the middle, to go over something"),
				}),
			}),
		}
		if smode == 2 then
			-- CS2 Network Tools' starting / ending flatness: 0 .. 0.5 of the stretch, shown as 0 .. 100 %
			-- (x 200), 1 % stops; the handles on the road set them too
			local pctLabels : {string} = {}
			for i = 0, 100 do pctLabels[i + 1] = tostring(i) .. " %" end
			local function flatRow(name : string, tip : string, value : number, set : function(number)) : TreeNodeId
				local idx = math.floor(clamp(value, 0, 0.5) * 200 + 0.5)
				return nativeParam(name, tip, api.type["enum"].ScriptParamType.Slider, pctLabels, idx,
					function(i : integer) set(i / 200) end)
					or sliderRow(name, tip, 0, 100, idx, function(v : integer) set(v / 200) end, tostring(idx) .. " %")
			end
			rows[#rows + 1] = flatRow(_("Start flatness"),
				_("How long the road stays level at the start before it climbs - or drag the first handle along the road"),
				slopeEaseInUi:old() or 0.1, function(v : number) g_slope.easeIn = v end)
			rows[#rows + 1] = flatRow(_("End flatness"),
				_("How long the road is level again at the end - or drag the second handle along the road"),
				slopeEaseOutUi:old() or 0.1, function(v : number) g_slope.easeOut = v end)
		end
		if smode == 3 then
			-- -30 .. +30 m in half-metre stops (negative = a dip); the in-world handle sets it too
			local archLabels : {string} = {}
			for i = 0, 120 do archLabels[i + 1] = string.format("%+.1f m", (i - 60) / 2) end
			local archIdx = math.floor(clamp(sarch, -30, 30) * 2 + 0.5) + 60
			local archTip = _("How far the middle rises above (or dips below) a straight line between the ends - or drag the handle beside the road")
			rows[#rows + 1] = nativeParam(_("Arch"), archTip, api.type["enum"].ScriptParamType.Slider, archLabels, archIdx,
				function(i : integer) g_slope.arch = (i - 60) / 2 end)
				or sliderRow(_("Arch"), archTip, -60, 60, archIdx - 60,
					function(v : integer) g_slope.arch = v / 2 end, string.format("%+.1f m", sarch))
		end
		add(card(_("Slope"), rows))
		add(card(_("Options"), {
			option(_("Anarchy"), _("Build without collision checks"), anarchyUi:old() == true,
				function(v : boolean) H.set("anarchy", v) end),
		}))
		footer = resetAndBuild(_("Apply the slope"))

		add(H.recipes.slope(toolParams))
	elseif tool == "shape" then
		local smode = shapeModeUi:old() or 1
		-- (the card's whole width: four options don't fit beside a name column)
		local rows : {TreeNodeId} = {
			segmented({ _("Straighten"), _("Smooth"), _("Ease"), _("Curve") }, smode, function(i : integer) g_shape.mode = i end, nil, {
				_("Move the nodes onto the straight line between the ends"),
				_("Even out the kinks: nodes move towards their neighbours, curves become smooth"),
				_("Turn the bend into a railway curve: straight, transition spiral, arc, spiral, straight - as wide as the ends allow"),
				_("Edit the curve by hand: drag a node's centre to move it, its two handles to turn and bend the road through it; the ends' handles set how far the curve swings there"),
			}, true),
		}
		if smode == 3 then
			local pct : {string} = {}
			for i = 0, 100 do pct[i + 1] = tostring(i) .. " %" end
			local idx = math.floor(clamp(shapeTransitionUi:old() or 0.5, 0, 1) * 100 + 0.5)
			local tip = _("How much of the turn is made in the transition spirals, where the curvature builds up gradually (0 % = a plain arc, 100 % = all spiral). More nodes on the stretch follow the curve more closely")
			rows[#rows + 1] = nativeParam(_("Transition"), tip, api.type["enum"].ScriptParamType.Slider, pct, idx,
				function(i : integer) g_shape.transition = i / 100 end)
				or sliderRow(_("Transition"), tip, 0, 100, idx, function(v : integer) g_shape.transition = v / 100 end, tostring(idx) .. " %")
		end
		if smode == 2 then
			local pct : {string} = {}
			for i = 0, 100 do pct[i + 1] = tostring(i) .. " %" end
			local idx = math.floor(clamp(shapeStrengthUi:old() or 0.5, 0, 1) * 100 + 0.5)
			local tip = _("How far each node moves towards the midpoint of its neighbours (0 % = only the curves are smoothed)")
			rows[#rows + 1] = nativeParam(_("Strength"), tip, api.type["enum"].ScriptParamType.Slider, pct, idx,
				function(i : integer) g_shape.strength = i / 100 end)
				or sliderRow(_("Strength"), tip, 0, 100, idx, function(v : integer) g_shape.strength = v / 100 end, tostring(idx) .. " %")
		end
		if smode == 4 then
			-- Curve: how the handles behave
			local _poll = shapeCurveUi:old()
			if g_shape.curveSelLabel then
				-- the selected node's height (drag one of its handles to select it)
				local h = math.floor((g_shape.curveHeight or 0) + 0.5)
				rows[#rows + 1] = sliderRow(_("Height of") .. " " .. g_shape.curveSelLabel,
					_("Raise (+) or lower (-) the selected nodes; the slope between the nodes is spread evenly. Click one of a node's handles to select it, Shift+click to select several"),
					-20, 40, h, function(v : integer) g_shape.curveHeight = v end, string.format("%+d m", h))
			else
				-- (short: the panel doesn't wrap it)
				rows[#rows + 1] = panelLabel(_("Click a node to set its height"))
			end
			rows[#rows + 1] = option(_("Same length both sides"),
				_("Dragging one of a node's handles makes both that long: the curve swings through the node evenly"),
				g_shape.curveMirror == true, function(v : boolean) g_shape.curveMirror = v end)
			rows[#rows + 1] = option(_("Free handles (corner)"),
				_("A node's two handles turn on their own instead of staying in line: the road can turn a corner at the node"),
				g_shape.curveFree == true, function(v : boolean) g_shape.curveFree = v end)
			rows[#rows + 1] = panelRow({
				gui_react_util.makeHorizontalSpacer(),
				smallButton(_("Reset edits"), _("Back to the stretch's own curve (the selection stays)"),
					function() g_shape.curveReset = (g_shape.curveReset or 0) + 1 end),
			})
		end
		add(card(_("Shape"), rows))
		add(card(_("Options"), {
			option(_("Anarchy"), _("Build without collision checks"), anarchyUi:old() == true,
				function(v : boolean) H.set("anarchy", v) end),
		}))
		footer = resetAndBuild(_("Apply"))
		add(H.recipes.shape(toolParams))
	elseif tool == "arrange_line" or tool == "arrange_circle" then
		add(card(_("Options"), {
			option(_("Anarchy"), _("Build without collision checks"), anarchyUi:old() == true,
				function(v : boolean) H.set("anarchy", v) end),
		}))
		footer = resetAndBuild(_("Apply"))
		if tool == "arrange_line" then
			add(H.recipes.arrangeLine(toolParams))
		else
			add(panelLabel(_("Drag the centre and rim handles in the world to adjust the circle.")))
			add(H.recipes.arrangeCircle(toolParams))
		end
	elseif tool == "signals" then
		local _k = sigKeyUi:old()
		-- signal model: Automatic (first matching the one-way choice) or any path signal of this year
		local models = H.listSignals()
		local items : {TreeNodeId} = { builtin.ComboBoxItem{ value = 0, content = panelLabel(_("Automatic")) } }
		local current = 0
		for i, m in ipairs(models) do
			items[#items + 1] = builtin.ComboBoxItem{ value = i, content = panelLabel(m.label .. (m.oneWay and ("  (" .. _("one-way") .. ")") or "")) }
			if g_sig.model == m.name then current = i end
		end
		local spacingLabels : {string} = {}
		for i = 0, 38 do spacingLabels[i + 1] = tostring(100 + i * 50) .. " m" end
		local spIdx = math.floor(clamp((g_sig.spacing - 100) / 50, 0, 38) + 0.5)
		-- how the block signals are spaced: the Spacing slider means a different thing for each type;
		-- By count has a Blocks slider instead
		local spType = g_sig.spacingType or 1
		local spName = ({ _("Spacing"), _("Interval"), _("At 100 km/h"), _("Spacing") })[spType]
		local spTip = ({
			_("Distance between block signals - shorter blocks let trains follow closer"),
			_("A signal exactly this far apart, from the start of each gap; the last block takes what is left"),
			_("A block's length on 100 km/h track - longer blocks where the line is faster, shorter where it is slower"),
			"",
		})[spType]
		local count = math.floor(g_sig.blockCount or 3)
		-- (built only where it is shown - the Block spacing card, not in Remove mode: built and left
		-- out, its widgets flooded the log with "Preserved props" every frame)
		local function makeSpacingRow() : TreeNodeId
			if spType == 4 then
				return sliderRow(_("Blocks"), _("How many equal blocks between each pair of signals that stand anyway (the ends, switches, crossings, signals already there)"),
					1, 20, count, function(v : integer) g_sig.blockCount = v end, tostring(count))
			end
			return nativeParam(spName, spTip, api.type["enum"].ScriptParamType.Slider, spacingLabels, spIdx,
				function(i : integer) g_sig.spacing = 100 + i * 50 end)
				or sliderRow(spName, spTip, 0, 38, spIdx, function(v : integer) g_sig.spacing = 100 + v * 50 end, spacingLabels[spIdx + 1])
		end
		-- What the tool does comes first: Place, Stations (exit signals at platform ends, blocks
		-- between) or Remove - they were two checkboxes at the bottom of Options. Remove hides the
		-- cards only placing uses (it needs the stretch, the tracks alongside and the direction)
		local sigMode = g_sig.removeMode == true and 3 or (g_sig.stationMode == true and 2 or 1)
		local placing = sigMode ~= 3
		local twoWay = g_sig.twoWay == true
		add(card(_("Signals"), {
			labelledRow(_("Mode"), {
				segmented({ _("Place"), _("Stations"), _("Remove") }, sigMode,
					function(i : integer)
						g_sig.removeMode = i == 3
						g_sig.stationMode = i == 2
					end, nil, {
						_("Signal the stretch: block signals by the block spacing, plus the ones at switches and crossings"),
						_("An exit signal just outside each platform end, facing away from the station; between stations (and out to the stretch's ends) block signals by the block spacing"),
						_("Instead of placing signals: remove the signals on the stretch (and on the tracks alongside, if that is on)"),
					}, false),
			}),
			labelledRow(_("Type"), {
				builtin.ComboBox{
					meta = { tooltip = _("Signal type to place (Automatic: the first one that matches One-way below)"), class = "ntools-slider", enabled = placing },
					items = items,
					value = current,
					onValueChange = function(v : integer|number|string)
						local i = math.floor(tonumber(v) or 0)
						g_sig.model = (i > 0 and models[i]) and models[i].name or nil
					end,
				},
			}, placing),
			option(_("One-way signals"), _("Trains may pass only in the direction of travel")
					.. (twoWay and ("\n" .. _("Not with Two-way track (below): both ways must pass")) or ""),
				g_sig.oneWay == true, function(v : boolean) g_sig.oneWay = v end, placing and not twoWay),
		}))
		if placing then
			add(card(_("Block spacing"), {
				segmented({ _("Equal"), _("Fixed"), _("Line speed"), _("Count") }, spType,
					function(i : integer) g_sig.spacingType = i end, nil, {
						_("Equal blocks between the signals that stand anyway, as near the Spacing as a whole number of blocks gets"),
						_("A signal every Interval metres; the last block of each gap takes what is left"),
						_("Blocks that take trains equally long: longer on fast track, shorter on slow and curved track"),
						_("A set number of equal blocks between the signals that stand anyway"),
					}, true),
				makeSpacingRow(),
				-- (signals already on the track: was a card of its own with just this switch)
				labelledRow(_("Existing"), {
					segmented({ _("Keep"), _("Replace"), _("Ignore") }, g_sig.existingMode or 1,
						function(i : integer) g_sig.existingMode = i end, nil, {
							_("Signals already there: keep them, and plan the new ones around them (they count as block ends)"),
							_("Remove every signal already on the tracks being signalled (both ways), and plan from scratch"),
							_("Leave them where they are, but plan as if they weren't there"),
						}, false),
				}),
			}))
			-- clearances and limits (0 = no limit): folded, its values in the summary line
			local function metres(v : number) : string return v and v > 0 and string.format("%d m", math.floor(v + 0.5)) or _("Off") end
			local minGap = math.floor((g_sig.minGap or 30) + 0.5)
			local endCl = math.floor((g_sig.endClearance or 25) + 0.5)
			local minB = math.floor(((g_sig.minBlock or 0)) / 50 + 0.5)
			local maxB = math.floor(((g_sig.maxBlock or 0)) / 100 + 0.5)
			add(foldCard(_("Clearances and limits"),
				string.format(_("Gap %d m  ·  ends %d m  ·  blocks %s to %s"), minGap, endCl, metres(minB * 50), metres(maxB * 100)),
				"sig.clearances", function() : TreeNodeId
					return builtin.BoxLayout{ orientation = builtin.type.Orientation.Vertical, children = {
						sliderRow(_("Min gap"), _("Never two signals closer than this"), 5, 100, minGap,
							function(v : integer) g_sig.minGap = v end, string.format("%d m", minGap)),
						sliderRow(_("End clearance"), _("Kept free of block signals at the stretch's two ends"), 0, 200, endCl,
							function(v : integer) g_sig.endClearance = v end, string.format("%d m", endCl)),
						sliderRow(_("Min block"), _("No block shorter than this (Off: only the min gap)"), 0, 40, minB,
							function(v : integer) g_sig.minBlock = v * 50 end, metres(minB * 50)),
						sliderRow(_("Max block"), _("Blocks longer than this are cut finer (Off: no limit)"), 0, 50, maxB,
							function(v : integer) g_sig.maxBlock = v * 100 end, metres(maxB * 100)),
					} }
				end, false))
		end
		-- where signals stand besides the blocks: at switches, before level crossings - each option's
		-- distance under it, indented, greyed while the option is off (were "   " labels in Options)
		if placing then
			local atSw = g_sig.beforeSwitches ~= false
			local swDist = math.floor((g_sig.switchDistance or 25) + 0.5)
			local jnDist = math.floor((g_sig.joinDistance or g_sig.switchDistance or 25) + 0.5)
			local xDist = math.floor((g_sig.crossingDistance or 5) + 0.5)
			-- folded, what's on (and how far) in the summary line
			local splits = atSw and g_sig.atSplits ~= false
			local joins = atSw and g_sig.atJoins ~= false
			local swSummary = (splits and string.format(_("Splits %d m"), swDist) or _("Splits off"))
				.. "  ·  " .. (joins and string.format(_("joins %d m"), jnDist) or _("joins off"))
				.. "  ·  " .. (g_sig.beforeCrossings == true and string.format(_("crossings %d m"), xDist) or _("crossings off"))
			add(foldCard(_("Switches & crossings"), swSummary, "sig.switches", function() : TreeNodeId
				return builtin.BoxLayout{ orientation = builtin.type.Orientation.Vertical, children = {
					option(_("At switches"), _("Also a signal at each switch: before it where the track splits, past it where tracks join"), atSw,
						function(v : boolean) g_sig.beforeSwitches = v end),
					indented({
						option(_("Before splits"), _("A signal before each switch where the track splits (the path signal picks the branch)"), g_sig.atSplits ~= false,
							function(v : boolean) g_sig.atSplits = v end, atSw),
						sliderRow(_("Distance"), _("How far before a split its signal stands"),
							5, 100, swDist, function(v : integer) g_sig.switchDistance = v end, string.format("%d m", swDist),
							splits),
						option(_("After joins"), _("A signal past each switch where tracks join (frees the junction sooner)"), g_sig.atJoins ~= false,
							function(v : boolean) g_sig.atJoins = v end, atSw),
						sliderRow(_("Distance"), _("How far past a join its signal stands"),
							5, 100, jnDist, function(v : integer) g_sig.joinDistance = v end, string.format("%d m", jnDist),
							joins),
					}),
					option(_("Before level crossings"), _("Also put a signal shortly before each level crossing (on the segment before the one that touches it)"), g_sig.beforeCrossings == true,
						function(v : boolean) g_sig.beforeCrossings = v end),
					indented({
						sliderRow(_("Distance"), _("How far before the crossing its signal stands"),
							1, 100, xDist, function(v : integer) g_sig.crossingDistance = v end, string.format("%d m", xDist),
							g_sig.beforeCrossings == true),
					}),
				} }
			end, false))
		end
		-- Stations mode's own settings (only then: the mode switch above decides)
		if sigMode == 2 then
			local exD = math.floor((g_sig.exitDistance or 8) + 0.5)
			local enD = math.floor((g_sig.entryDistance or 8) + 0.5)
			add(card(_("Stations"), {
				sliderRow(_("Exit distance"), _("How far outside the platform end the exit signal stands"),
					1, 100, exD, function(v : integer) g_sig.exitDistance = v end, string.format("%d m", exD)),
				option(_("Entry signals"), _("Also a signal short of each platform the trains run into"), g_sig.stationEntry == true,
					function(v : boolean) g_sig.stationEntry = v end),
				indented({
					sliderRow(_("Distance"), _("How far short of the platform end the entry signal stands"),
						1, 300, enD, function(v : integer) g_sig.entryDistance = v end, string.format("%d m", enD),
						g_sig.stationEntry == true),
				}),
			}))
		end
		-- the tracks and the way trains run: tracks alongside, two-way, the pattern across a
		-- multi-track line (and click a marker in the world to turn one track), against the selection
		-- (do-blocks: the render function is near Lua's 200-local limit - these end with their card)
		do
		local pat = g_sig.pattern or 1
		local beside = g_sig.besideTracks ~= false
		local patOn = beside and not twoWay
		add(card(_("Tracks & direction"), {
			option(_("Tracks alongside too"), _("Multi-track lines: also signal (or clear) every track running beside the stretch"), beside,
				function(v : boolean) g_sig.besideTracks = v end),
			option(_("Two-way track"), _("Signal every track for both ways of travel (single track used both ways); one-way signals are never used then"), twoWay,
				function(v : boolean) g_sig.twoWay = v end, placing),
			-- (the pattern across the tracks: five names too long beside a name column - the card's
			-- width, as Block spacing's switch)
			segmented({ _("Opposite"), _("Same"), _("Alternate"), _("Pairs"), _("Auto") }, pat,
				function(i : integer) g_sig.pattern = i; g_sig.besideSameWay = false end,
				(not patOn) and (twoWay and _("Not with Two-way track: every track runs both ways") or _("Only with Tracks alongside too")) or nil,
				patOn and {
					_("Every other track runs against the one you selected (double track)"),
					_("All tracks run the same way"),
					_("Left, right, left, right... across the tracks"),
					_("Two one way, two the other, across the tracks"),
					_("Each track from the world: its signals, else the trains on it, else the running side below"),
				} or nil, true, patOn),
			-- (Auto) the running side for tracks with no signals or trains to go by
			labelledRow(_("Running side"), {
				segmented({ _("Keep left"), _("Keep right") }, g_sig.runningSide or 1,
					function(i : integer) g_sig.runningSide = i end, (patOn and pat == 5) and nil or _("Only with Auto above"),
					(patOn and pat == 5) and {
						_("Trains keep left (as in Britain or Japan): the left-hand track runs the way you look along"),
						_("Trains keep right (as in most of Europe and America)"),
					} or nil, false, patOn and pat == 5),
			}, patOn and pat == 5),
			option(_("Trains travel against the selection"), _("Turn the signals round: for traffic running from the last segment you picked towards the first"), g_sig.reverse == true,
				function(v : boolean) g_sig.reverse = v end),
			builtin.TextView{ meta = { class = "font-scale-body, ntools-note" },
				text = _("Click a signal marker in the world to turn its whole track round.") },
		}))
		end
		-- picking the stretch: what a click further along the line adds (the modes are ntools_chain's
		-- MODE_*, in the same order)
		do
		local PATH_MODES : {{string}} = {
			{ _("Fewest segments"), _("The path with the fewest pieces of track (may double back through a switch)") },
			{ _("Shortest distance"), _("The fewest metres of track") },
			{ _("Straightest"), _("The least turning at switches: follows the main line rather than sidings") },
			{ _("Same track type"), _("Stays on the track type you started on, leaving it only when it must") },
			{ _("Fastest"), _("The shortest travel time at each track's speed limit") },
			{ _("Flattest"), _("The least climbing and descending") },
			{ _("Fewest junctions"), _("Through the fewest switches and crossings") },
			{ _("Avoid bridges & tunnels"), _("Track on the ground wherever there is a way") },
			{ _("Shortest (A*)"), _("The shortest path found with A*: the same result, searching far less track") },
			{ _("Beeline"), _("Always heads for what is closest to the target as the crow flies: direct-looking, not always shortest") },
			{ _("Follow the line"), _("No search: takes the straightest branch at every switch until it reaches the target") },
			{ _("Keep left"), _("No search: takes the leftmost branch at every switch") },
			{ _("Keep right"), _("No search: takes the rightmost branch at every switch") },
			{ _("Highest minimum speed"), _("The route whose slowest piece is as fast as possible") },
			{ _("Gentlest steepest climb"), _("The route whose steepest gradient is as low as possible") },
			{ _("Alternative route"), _("Another way than the shortest one, where there is one") },
		}
		local pathMode = math.max(1, math.min(#PATH_MODES, g_sig.pathMode or 3))
		-- picking the stretch: folded, the path mode (and its filters) in the summary line. (The
		-- dropdown's items are built inside the card's body: built here, a folded card left them
		-- unattached - "Preserved props" in the log every frame)
		local pathSummary = PATH_MODES[pathMode][1]
			.. (g_sig.pathElectric == true and ("  ·  " .. _("electrified only")) or "")
			.. (g_sig.pathAvoidStations == true and ("  ·  " .. _("no stations")) or "")
		add(foldCard(_("Picking the stretch"), pathSummary, "sig.path", function() : TreeNodeId
			local modeItems : {TreeNodeId} = {}
			for i, m in ipairs(PATH_MODES) do modeItems[i] = builtin.ComboBoxItem{ value = i, content = panelLabel(m[1]) } end
			return builtin.BoxLayout{ orientation = builtin.type.Orientation.Vertical, children = {
				labelledRow(_("Path"), {
					builtin.ComboBox{
						meta = { tooltip = _("Click a segment further along the line: this decides which way the path to it goes"), class = "ntools-slider" },
						items = modeItems,
						value = pathMode,
						onValueChange = function(v : integer|number|string)
							local i = math.floor(tonumber(v) or 3)
							if PATH_MODES[i] then g_sig.pathMode = i end
						end,
					},
				}),
				builtin.TextView{ meta = { class = "font-scale-body, ntools-note" },
					text = PATH_MODES[pathMode][2] .. (pathMode ~= 1 and (". " .. _("Never doubles back through a switch.")) or "") },
				option(_("Electrified track only"), _("Only through electrified track"), g_sig.pathElectric == true,
					function(v : boolean) g_sig.pathElectric = v end),
				option(_("Avoid stations"), _("Never through a station's tracks"), g_sig.pathAvoidStations == true,
					function(v : boolean) g_sig.pathAvoidStations = v end),
			} }
		end, false))
		end
		-- names of the new signals (numbered on from the highest number the name already has):
		-- folded, the style in the summary line
		if placing then
			local nameStyle = g_sig.nameStyle or 1
			local styleNames = { _("Like the game"), _("Custom"), _("Don't name") }
			local nameSummary = styleNames[nameStyle] or styleNames[1]
			if nameStyle == 2 then nameSummary = nameSummary .. ": " .. ((g_sig.namePrefix ~= nil and g_sig.namePrefix ~= "") and g_sig.namePrefix or "-") end
			if nameStyle ~= 3 and g_sig.nameKind == true then nameSummary = nameSummary .. "  ·  " .. _("with what it is for") end
			add(foldCard(_("Signal names"), nameSummary, "sig.names", function() : TreeNodeId
				return builtin.BoxLayout{ orientation = builtin.type.Orientation.Vertical, children = {
					segmented(styleNames, nameStyle,
						function(i : integer) g_sig.nameStyle = i end, nil, {
							_("Named after the closest town, as the game's own signals: East Ham Signal #3"),
							_("Your own name, typed below: Main Line #3"),
							_("Leave the new signals unnamed"),
						}, true),
					builtin.TextInputField{
						meta = { tooltip = _("The name for Custom; the number is added (#1, #2 ...)"), class = "ntools-net-search, font-scale-body",
							enabled = nameStyle == 2 },
						value = g_sig.namePrefix or "",
						placeholderText = _("Custom name, e.g. Main Line"),
						onTyping = function(text : string) g_sig.namePrefix = text or "" end,
						onValueChange = function(text : string) g_sig.namePrefix = text or "" end,
						-- take the keyboard from the running tool (its shortcuts) while typing, give it back after
						focusOnStartEditing = true,
						popFocusOnStopEditing = true,
					} as Builtin.TextInputFieldParam,
					option(_("Add what it is for"), _("Put the signal's job in its name: Exit, Entry, Switch, Join or Crossing (plain block signals get none)"), g_sig.nameKind == true,
						function(v : boolean) g_sig.nameKind = v end, nameStyle ~= 3),
				} }
			end, false))
		end
		-- (the rest of the old Options card went to Signals, Switches & crossings, Stations and
		-- Tracks & direction)
		add(card(_("Options"), {
			option(_("Anarchy"), _("Build without collision checks"), anarchyUi:old() == true,
				function(v : boolean) H.set("anarchy", v) end),
		}))
		footer = resetAndBuild(_("Place the signals"))
		add(H.recipes.signals(toolParams))
	elseif tool == "upgrade" then
		-- the track type to change to (Keep: each segment's own), then catenary on / off / as it is
		local _k = upKeyUi:old()
		local types : {Network} = {}
		for __, n in ipairs(H.listNetworks()) do if n.isTrack then types[#types + 1] = n end end
		table.sort(types, function(a : Network, b : Network) : boolean return a.name < b.name end)
		local items : {TreeNodeId} = { builtin.ComboBoxItem{ value = 0, content = panelLabel(_("Keep each segment's type")) } }
		local current = 0
		for i, n in ipairs(types) do
			local text = n.name .. ((n.speed and n.speed > 0) and string.format("  (%d km/h)", math.floor(n.speed + 0.5)) or "")
			items[#items + 1] = builtin.ComboBoxItem{ value = i, content = panelLabel(text) }
			if n.id == g_up.trackType then current = i end
		end
		add(card(_("Track upgrade"), {
			labelledRow(_("Type"), {
				builtin.ComboBox{
					meta = { tooltip = _("The track type the stretch becomes"), class = "ntools-slider" },
					items = items,
					value = current,
					onValueChange = function(v : integer|number|string)
						local i = math.floor(tonumber(v) or 0)
						g_up.trackType = types[i] and types[i].id or 0
					end,
				},
			}),
			labelledRow(_("Catenary"), {
				segmented({ _("Keep"), _("Electrify"), _("Remove") }, g_up.catenary or 1,
					function(i : integer) g_up.catenary = i end, nil, {
						_("Leave the catenary as it is"),
						_("Electrified track: the type's electrified version"),
						_("No catenary: the type's plain version"),
					}, false),
			}),
			builtin.TextView{ meta = { class = "font-scale-body, ntools-note" },
				text = _("Click a track segment, then one further along. Signals stay where they are; station track is left out.") },
		}))
		add(card(_("Options"), {
			option(_("Anarchy"), _("Build without collision checks"), anarchyUi:old() == true,
				function(v : boolean) H.set("anarchy", v) end),
		}))
		footer = resetAndBuild(_("Upgrade the track"))
		add(H.recipes.upgrade(toolParams))
	elseif tool == "crossover" then
		local _k = railKeyUi:old()
		add(card(_("Crossover"), {
			labelledRow(_("Kind"), {
				segmented({ _("Single"), _("Scissors") }, g_cx.kind or 1,
					function(i : integer) g_cx.kind = i end, nil, {
						_("One pair of switches: an S-curve from one track to the other"),
						_("Two crossovers crossing in the middle: both directions"),
					}, false),
			}),
			labelledRow(_("Direction"), {
				segmented({ _("Ahead"), _("Behind") }, g_cx.dir or 1,
					function(i : integer) g_cx.dir = i end, nil, {
						_("Along the first track's direction from the click"),
						_("Against it"),
					}, false),
			}),
			sliderRow(_("Length"), _("How far along the tracks the crossover runs"),
				20, 200, math.floor((g_cx.length or 60) + 0.5), function(v : integer) g_cx.length = v end,
				string.format("%d m", math.floor((g_cx.length or 60) + 0.5))),
			labelledRow(_("Arrange"), {
				segmented({ _("Staggered"), _("Side by side") }, g_cx.arrange or 1,
					function(i : integer) g_cx.arrange = i end, nil, {
						_("More than two tracks: each crossover starts where the one before ends - a train can cross them all"),
						_("More than two tracks: all the crossovers at the same place (scissors are always staggered)"),
					}, false),
			}),
			builtin.TextView{ meta = { class = "font-scale-body, ntools-note" },
				text = _("Click a track where the crossovers start, then each track beside it (3 - 30 m apart; click again to drop). A crossover joins each neighbouring pair. The segments they meet must carry no signals.") },
		}))
		add(card(_("Options"), {
			option(_("Anarchy"), _("Build without collision checks"), anarchyUi:old() == true,
				function(v : boolean) H.set("anarchy", v) end),
		}))
		footer = resetAndBuild(_("Build the crossover"))
		add(H.recipes.crossover(toolParams))
	elseif branchKind == "loop" then
		local _k = railKeyUi:old()
		branchTypeCard()
		add(card(_("Passing loop"), {
			option(_("Drag handles (new)"), _("Set the loop's two ends with handles instead of picking segments: turnouts from the Switch radius, wherever the track's nodes are"),
				g_loop.handles == true, function(v : boolean) g_loop.handles = v end),
			labelledRow(_("Side"), {
				segmented({ _("Left"), _("Right"), _("Both") }, g_loop.side or 1,
					function(i : integer) g_loop.side = i end, nil, {
						_("Left of the stretch, looking from the first segment you picked"),
						_("Right of it"),
						_("Loops on both sides (the right-hand ones start one node further in)"),
					}, false),
			}),
			sliderRow(_("Tracks"), _("Loop tracks per side: each next one leaves the one before a node further in"),
				1, 6, math.floor(g_loop.count or 1), function(v : integer) g_loop.count = v end,
				tostring(math.floor(g_loop.count or 1))),
			-- (four choices: too wide beside a label - the label on its own line, the choices below)
			panelLabel(_("Tracks alongside")),
			segmented({ _("Off"), _("Outer"), _("Bundle"), _("Across") }, (g_loop.alongside or 0) + 1,
				function(i : integer) g_loop.alongside = i - 1 end, nil, {
					_("Just the clicked track"),
					_("Tracks running alongside: a loop beside the outermost track on each side (both directions)"),
					_("A loop for every track alongside, side by side - the further tracks' loops cross the tracks between"),
					_("One loop beside the outermost track, from the clicked track, crossing the tracks between"),
				}, false),
			option(_("Mirror"), _("Double track: the same passing loop on the other track too, facing outwards (as Tracks alongside: Outer)"),
				(g_loop.alongside or 0) == 1, function(v : boolean) g_loop.alongside = v and 1 or 0 end),
			sliderRow(_("Spacing"), _("Distance between the track centres"),
				4, 15, math.floor((g_loop.spacing or 5) + 0.5), function(v : integer) g_loop.spacing = v end,
				string.format("%d m", math.floor((g_loop.spacing or 5) + 0.5))),
			builtin.TextView{ meta = { class = "font-scale-body, ntools-note" },
				text = _("Click a track segment, then one further along. The loop leaves at the first node and joins at the last; the end segments need 25 m or more.") },
		}))
		add(card(_("Options"), {
			option(_("Anarchy"), _("Build without collision checks"), anarchyUi:old() == true,
				function(v : boolean) H.set("anarchy", v) end),
		}))
		footer = resetAndBuild(_("Build the passing loop"))
		add(H.recipes.loop(toolParams))
	elseif branchKind == "junction" then
		local _k = railKeyUi:old()
		branchTypeCard()
		add(card(_("Junction"), {
			labelledRow(_("Start side"), {
				segmented({ _("Right"), _("Left") }, g_jn.side or 1,
					function(i : integer) g_jn.side = i end, nil, {
						_("A click puts the handle to the right of the track"),
						_("To the left"),
					}, false),
			}),
			-- turnout speed: the curve's radius from the track type's own speed formula (Free: the handle)
			panelLabel(_("Turnout speed")),
			segmented({ _("Free"), "40", "60", "80", "100", "120" },
				({ [0] = 1, [40] = 2, [60] = 3, [80] = 4, [100] = 5, [120] = 6 } as {integer : integer})[math.floor(g_jn.speed or 0)] or 1,
				function(i : integer) g_jn.speed = ({ 0, 40, 60, 80, 100, 120 })[i] or 0 end, nil, {
					_("The handle shapes the curve (the tooltip shows the speed it allows)"),
					_("40 km/h: a tight turnout, then straight on to the handle"),
					_("60 km/h"), _("80 km/h"), _("100 km/h"),
					_("120 km/h: a long, wide turnout"),
				}, true),
			sliderRow((g_jn.speed or 0) > 0 and _("Onto a track") or _("Warn below"),
				(g_jn.speed or 0) > 0 and _("The tightest curve a branch dropped on a track may use (a turnout speed sets its own)")
					or _("The tooltip warns when the branch's radius is tighter than this; also the tightest curve of a branch dropped on a track"),
				100, 1000, math.floor((g_jn.minRadius or 300) + 0.5), function(v : integer) g_jn.minRadius = v end,
				string.format("%d m", math.floor((g_jn.minRadius or 300) + 0.5))),
			option(_("Double-slip switches"), _("Where parallel branches cross the other tracks, make the crossings double-slip switches after the build (trains can change track there)"),
				g_jn.doubleSlip == true, function(v : boolean) g_jn.doubleSlip = v end),
			option(_("Feed every track"), _("Drop the handle on a station's track end: a branch to every open track at that end of the station, switches one after another from the click (the outer tracks leave first, so none cross). Off: just the track it's dropped on"),
				g_jn.fanStation ~= false, function(v : boolean) g_jn.fanStation = v end),
			builtin.TextView{ meta = { class = "font-scale-body, ntools-note" },
				text = _("Click a track where the branch leaves it, then drag the handle - drop it on another track to join it there, or on a station's track end to feed every track at that end (Feed every track). Click the tracks beside it (a double-track line) to branch them too: parallel branches, crossing the other tracks where they must. Otherwise the ends are left free to carry on from.") },
		}))
		add(card(_("Options"), {
			option(_("Anarchy"), _("Build without collision checks"), anarchyUi:old() == true,
				function(v : boolean) H.set("anarchy", v) end),
		}))
		add(signalCard(g_jn as {string : any}, _("A signal on each branch short of its switch (and of the track it joins), for trains heading into it")))
		footer = resetAndBuild(_("Build the junction"))
		add(H.recipes.junction(toolParams))
	elseif branchKind == "siding" then
		local _k = railKeyUi:old()
		branchTypeCard()
		-- three cards, each one job: the siding's shape; its turnouts; feeding a station's tracks. Every
		-- switch sits beside its name (the same edge as the sliders); what a choice makes useless is
		-- greyed, saying why in its tooltip. (Mirror is gone: it was Alongside: Outer under another name)
		local both = g_sd.both == true
		local feedOn = g_sd.feedAll ~= false
		local free = (g_sd.speed or 0) == 0
		local sdItems : {TreeNodeId} = {
			labelledRow(_("Start side"), {
				-- (Both: the handle's side first, the same on the other side too - its switch 8 m further
				-- on; on a double track one set off each outer track, as Alongside: Outer)
				segmented({ _("Right"), _("Left"), _("Both") }, both and 3 or (g_sd.side or 1),
					function(i : integer)
						g_sd.both = i == 3
						if i ~= 3 then g_sd.side = i end
					end, nil, {
						_("A click puts the siding to the right of the track"),
						_("To the left"),
						_("Both sides of the line (on a double track: one set off each outer track)"),
					}, false),
			}),
			sliderRow(_("Sidings"), _("Sidings per side: each leaves the one before, like a small yard ladder (Bundle / Across: that many loops per track, side by side)"),
				1, 6, math.floor(g_sd.count or 1), function(v : integer) g_sd.count = v end,
				tostring(math.floor(g_sd.count or 1))),
			sliderRow(_("Spacing"), _("Distance between the track centres"),
				4, 15, math.floor((g_sd.spacing or 5) + 0.5), function(v : integer) g_sd.spacing = v end,
				string.format("%d m", math.floor((g_sd.spacing or 5) + 0.5))),
			labelledRow(_("Alongside"), {
				segmented({ _("Off"), _("Outer"), _("Bundle"), _("Across") }, (g_sd.alongside or 0) + 1,
					function(i : integer) g_sd.alongside = i - 1 end, nil, {
						_("Just the clicked track"),
						_("Tracks running alongside: a siding off the outermost track on each side - on a double track, the same siding on the other track too, facing outwards"),
						_("A siding for every track alongside, side by side - the further tracks' sidings cross the tracks between"),
						_("One siding beside the outermost track, from the clicked track, crossing the tracks between"),
					}, false),
			}),
			builtin.TextView{ meta = { class = "font-scale-body, ntools-note" },
				text = rejoinHandles and _("Click a track where the loop starts, then drag the end handle along for its length (across: other side), and the start handle to move the start.")
					or _("Click a track where the siding leaves it, then drag the handle: along for its length, across for the other side. Drop it on a loose track end beside the line to join that track.") },
		}
		if rejoinHandles then
			table.insert(sdItems, 1, option(_("Drag handles (new)"), _("Untick to pick segments for the passing loop instead (the older way)"),
				true, function(v : boolean) g_loop.handles = v end))
		end
		add(card(rejoinHandles and _("Passing loop") or _("Siding"), sdItems))
		-- turnouts: a speed (the track type's own formula gives the curve) or Free with a radius
		do
			local speeds = { 0, 40, 60, 80, 100, 120 }
			local sel = 1
			for i, v in ipairs(speeds) do if v == math.floor(g_sd.speed or 0) then sel = i end end
			add(card(_("Turnouts"), {
				labelledRow(_("Speed"), {
					segmented({ _("Free"), "40", "60", "80", "100", "120" }, sel,
						function(i : integer) g_sd.speed = speeds[i] or 0 end, nil, {
							_("Free: the Switch radius below sets the curves (the tooltip shows their speed)"),
							_("40 km/h: tight, short turnouts"), _("60 km/h"), _("80 km/h"), _("100 km/h"),
							_("120 km/h: wide, long turnouts"),
						}, false),
				}),
				sliderRow(_("Switch radius"), _("How wide the switch curves are - wider is faster, and needs a longer turnout")
						.. (free and "" or ("\n" .. _("Only used with Speed: Free"))),
					2, 12, math.floor((g_sd.radius or 300) / 50 + 0.5), function(v : integer) g_sd.radius = v * 50 end,
					string.format("%d m", math.floor((g_sd.radius or 300) + 0.5)), free),
			}))
		end
		-- a dead end dropped on a station's track end: how its tracks are fed
		add(card(_("Station tracks"), {
			option(_("Feed every track"), _("Dead end dropped on a station's track end: a siding to every open track at that end of the station - the handle's side, or both sides with Start side Both. Outermost first, switches one after another from the click, so none cross. Off: just the track it's dropped on"),
				feedOn, function(v : boolean) g_sd.feedAll = v end),
			labelledRow(_("Feed style"), {
				segmented({ _("Nested"), _("Ladder"), _("Diagonal") }, math.floor(g_sd.feedStyle or 1),
					function(i : integer) g_sd.feedStyle = i end, feedOn and nil or _("Only used with Feed every track"), feedOn and {
						_("Each siding leaves the main line, outermost track first, switches one after another - simple, uses the most line"),
						_("One switch on the line per side; each next track's siding leaves the one inside it (a yard ladder) - shorter"),
						_("One switch on the line per side, a straight throat track at the turnout angle with a switch for each track - the shortest"),
					} or nil, false, feedOn),
			}, feedOn),
			option(_("Crossovers between the mains"), _("Double-track line, Start side Both: two crossovers between the main tracks before the throat, one each way - every platform reached from either main and left onto either (for a line run one way on each track)")
					.. ((feedOn and both) and "" or ("\n" .. _("Needs Feed every track and Start side: Both"))),
				g_sd.feedCross ~= false, function(v : boolean) g_sd.feedCross = v end, feedOn and both),
		}))
		add(card(_("Options"), {
			option(_("Anarchy"), _("Build without collision checks"), anarchyUi:old() == true,
				function(v : boolean) H.set("anarchy", v) end),
		}))
		add(signalCard(g_sd as {string : any}, rejoinHandles
			and _("Exit signals at both ends of each loop track, short of the switches, for trains heading out onto the line")
			or _("An exit signal on each siding short of its switch, for trains heading out onto the line")))
		footer = resetAndBuild(rejoinHandles and _("Build the passing loop") or _("Build the siding"))
		add(H.recipes.siding(toolParams))
	elseif tool == "generate" then
		local _k = genKeyUi:old()
		local gshape = g_gen.shape
		local SLIDER = api.type["enum"].ScriptParamType.Slider
		local function stepRow(name : string, tip : string, lo : number, hi : number, step : number, unit : string,
				value : number, set : function(number)) : TreeNodeId
			local labels : {string} = {}
			local n = math.floor((hi - lo) / step + 0.5)
			for i = 0, n do labels[i + 1] = string.format("%g", lo + i * step) .. unit end
			local idx = math.floor(clamp((value - lo) / step, 0, n) + 0.5)
			return nativeParam(name, tip, SLIDER, labels, idx, function(i : integer) set(lo + i * step) end)
				or sliderRow(name, tip, 0, n, idx, function(v : integer) set(lo + v * step) end, labels[idx + 1])
		end
		-- four shapes: full width (beside a name column they don't fit the card)
		local rows : {TreeNodeId} = {
			segmented({ _("Circle"), _("Oval"), _("Grid"), _("Helix") }, gshape, function(i : integer) g_gen.shape = i end,
				_("A ring road / round track, an oval, a street grid, or a helix (a spiral that gains height)"), nil, true),
		}
		if gshape == 4 then
			rows[#rows + 1] = stepRow(_("Turns"), _("How many times the helix goes round"), 0.25, 10, 0.25, "", g_gen.turns, function(v : number) g_gen.turns = v end)
			rows[#rows + 1] = stepRow(_("Grade"), _("Climb along the helix (negative: it goes down - a spiral tunnel). Each turn rises grade x circumference: keep that above ~7 m so the turns clear each other"),
				-8, 8, 0.5, " %", g_gen.grade, function(v : number) g_gen.grade = v end)
			rows[#rows + 1] = labelledRow(_("Turning"), {
				segmented({ _("Left"), _("Right") }, g_gen.clockwise and 2 or 1, function(i : integer) g_gen.clockwise = i == 2 end,
					_("Which way the helix turns, seen from above")),
			})
		end
		if gshape == 3 then
			rows[#rows + 1] = stepRow(_("Columns"), _("Blocks across"), 1, 10, 1, "", g_gen.cols, function(v : number) g_gen.cols = math.floor(v) end)
			rows[#rows + 1] = stepRow(_("Rows"), _("Blocks down"), 1, 10, 1, "", g_gen.rows, function(v : number) g_gen.rows = math.floor(v) end)
			rows[#rows + 1] = stepRow(_("Block"), _("Block size (or drag the corner handle)"), 20, 300, 5, " m", g_gen.spacing, function(v : number) g_gen.spacing = v end)
		else
			rows[#rows + 1] = stepRow(gshape == 2 and _("Radius X") or _("Radius"), _("Or drag the size handle"), 15, 1000, 5, " m", g_gen.radius, function(v : number) g_gen.radius = v end)
			if gshape == 2 then
				rows[#rows + 1] = stepRow(_("Radius Y"), _("Or drag the second size handle"), 10, 1000, 5, " m", g_gen.radiusY, function(v : number) g_gen.radiusY = v end)
			end
		end
		rows[#rows + 1] = stepRow(_("Rotation"), _("Or drag the rotation handle"), 0, 355, 5, "°", g_gen.rotation, function(v : number) g_gen.rotation = v end)
		add(card(_("Generate"), rows))
		add(card(_("Options"), {
			option(_("Anarchy"), _("Build without collision checks"), anarchyUi:old() == true,
				function(v : boolean) H.set("anarchy", v) end),
		}))
		footer = resetAndBuild(_("Build it"))
		add(H.recipes.generate(toolParams))
	elseif tool == "add_node" or tool == "remove_node" then
		add(card(_("Options"), {
			option(_("Anarchy"), _("Build without collision checks"), anarchyUi:old() == true,
				function(v : boolean) H.set("anarchy", v) end),
		}))
		if tool == "add_node" then
			add(H.recipes.addNode(toolParams))
		else
			add(H.recipes.removeNode(toolParams))
		end
	else
		-- no tool selected: hand the world back to normal selection
		params.payload.setActionFn(nil)
		-- centred empty state (as Timetables' "Select a line")
		add(builtin.Component{
			meta = { class = "ntools-empty" },
			layout = builtin.BoxLayout{ children = { panelLabel(_("Pick a tool above")) } },
		})
	end

	-- Layout: the Tools card fixed at the top, the running tool's options in a scroll area that takes
	-- the rest of the height (a spacer keeps short option lists at its top instead of centred), and
	-- Reset / Build fixed at the bottom. The window has a fixed size, so without the scroll area a
	-- long tool (Parallel) pushed Reset / Build out past its bottom edge.
	local header = children[1]
	local body : {TreeNodeId} = {}
	for i = 2, #children do body[#body + 1] = children[i] end
	body[#body + 1] = gui_react_util.makeVerticalSpacer()

	local parts : {TreeNodeId} = {
		header,
		builtin.ScrollArea{
			meta = { class = "ntools-scroll" },
			horizontalPolicy = builtin.type.ScrollBarPolicy.AlwaysOff,
			verticalPolicy = builtin.type.ScrollBarPolicy.AsNeeded,
			-- (no focus-following: a click on a table's header focuses the table, and the panel scrolled
			-- to show it whole - it jumped down)
			disableGamepadNavigation = true,
			-- ScrollArea takes a component, not a layout ("ScrollArea does not accept a Layout as content")
			content = builtin.Component{
				meta = { class = "ntools-scroll-content" },
				layout = builtin.BoxLayout{
					orientation = builtin.type.Orientation.Vertical,
					children = body,
				},
			},
		},
	}
	if footer then parts[#parts + 1] = footer end

	-- padding lives on a Component around the content, not on the window (see UI_NOTES.md);
	-- a recipe's root must be a layout, so the Component sits inside a BoxLayout
	return builtin.BoxLayout{
		orientation = builtin.type.Orientation.Vertical,
		children = {
			builtin.Component{
				meta = { class = "ntools-content" },
				layout = builtin.BoxLayout{
					orientation = builtin.type.Orientation.Vertical,
					children = parts,
				},
			},
		},
	}
end)

-- (nil when the game's Window couldn't be found - see NativeWindow; the panel then doesn't open)
local NetworkToolsWindow = NativeWindow and react.RegisterWrapperRecipe(
	"NtoolsWindow",
	NativeWindow,
	function(params : PanelWindowParams) : TreeNodeId
		return NativeWindow(desktopWindowParams({
			id = PANEL_WINDOW_ID,
			title = _("Network Tools"),
			onClose = params.onClose,
			-- (where it first opens: the css, Window#ntools.window - as the Timetables mod does it)
			autoFocusOnBecomingVisible = false,
			content = NetworkToolsPanelContent(params),
		}))
	end
)

local NetworkToolsTool = react.RegisterTool({
	name = "NetworkTools",
	push = function(ctx : Builtin.ToolStackContext<any>, _param : any)
		local windowParams : PanelWindowParams = {
			payload = { setActionFn = ctx.setActionFn, close = ctx.popSelf },
			onClose = ctx.popSelf,
		}
		game_react_globals.getDefaultWindowApi().addSingletonWindow(NetworkToolsWindow, windowParams)
		g_panelOpen = true
	end,
	pop = function(_ctx : Builtin.ToolStackContext<any>, _param : any)
		game_react_globals.getDefaultWindowApi().removeAllWindows(NetworkToolsWindow)
		-- (and the road / track list's window with it)
		closeNetWindow()
		g_netListBuilder = nil
		g_panelOpen = false
	end,
	shelve = function(_ctx : Builtin.ToolStackContext<any>, _param : any, shelve : boolean)
		pcall(function() api.gui.byId.setVisible(PANEL_WINDOW_ID, not shelve) end)
	end,
} as ReactToolDefinition<any>)

-- Open / close the panel (used by the toolbar button).
local function togglePanel(open : boolean)
	local stack = game_react_globals.getDefaultToolStackApi()
	-- no window to open it in (see NativeWindow): the button stays up instead of crashing the game
	if open and not NetworkToolsWindow then return end
	if open then
		-- the Settings tab: open on the tiles (no tool) rather than the last tool; Anarchy as set
		if shared.opts.panelLastTool == false then g_lastTool = nil; g_lastTab = nil end
		if H then pcall(H.set, "anarchy", shared.opts.anarchyDefault == true) end
		stack.push(NetworkToolsTool, nil, {}, false)
	else
		stack.pop(NetworkToolsTool, nil)
	end
end

local function isPanelOpen() : boolean
	return g_panelOpen
end

return {
	init = init,
	togglePanel = togglePanel,
	isPanelOpen = isPanelOpen,
}
