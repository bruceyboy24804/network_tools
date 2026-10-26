-- Network Tools: game controller support for the tools in the build menu (on console the only way
-- in). Modelled on the Overpass Builder's controller path, which follows the game's own scripted
-- selection tools (construction_react_util, selector_react_util):
--   * the input mode as state, sampled every step (a plain read goes stale after a switch)
--   * the world layer shows the crosshair and the focus circle; the "mouse" terrain position then
--     follows the crosshair
--   * a focus anchor: gamepad input actions reach only the focused node and its ancestors, and a
--     construction custom action leaves the focus on its menu button - so the tool returns this
--     invisible, force-focusable node, which focuses itself, and its handlers come onto the path
--   * the confirm (IA_APPLY / IA_SELECT, and the Selector's onSelect a pad confirm also arrives
--     by) debounced through one function; IA_OPTION2 hands the pad to the option bar at the
--     bottom (Reset / Build are there); IA_MENU_BACK leaves the tool
--   * the construction menu's focus followed (constructionMenuChangeFocusMode): while the option
--     bar has the pad, the tool keeps its hands off the buttons, and takes the focus back after

local react = ug_require "::/gui/main/react.lua" as React
local builtin = ug_require "::/gui/main/builtin.lua" as Builtin

local function isGamepad() : boolean
	local ok, g = pcall(function() : boolean
		return api.util.getInputMode() == api.type["enum"].InputMode.Gamepad
	end)
	return ok and g == true
end

-- the focus anchor (see above)
local PadFocus = react.RegisterRecipe("NtoolsPadFocus", function(_p : any) : TreeNodeId
	local selfRef = react.useSelfRef()
	react.onMount(function()
		pcall(function()
			local node = ((selfRef as any) as ReactRefWrap):get()
			if node then node:focus() end
		end)
	end)
	return nil
end)

-- A tool's controller state, kept in one table (the tools' render functions are near Lua's local
-- limit). Made each render with use(); the fields:
--   gamepad   state: the input mode is the pad
--   mounted   state: the tool's world layer is up (an unmount re-renders the tool)
--   live      the same, read by the predicates (a render-time stamp goes stale while the
--             crosshair rests)
--   focusMode "Action" (the world, the tool), "BottomBar" (the option bar) or "Params"
--   node      the focus anchor's node ref
--   confirm   the tool's confirm (set by the tool; the Selector's onSelect calls it too)
--   onStep    the tool's per-step work while on the pad (a drag following the crosshair)
local record Pad
	gamepad : ReactStateT<boolean>
	mounted : ReactStateT<boolean>
	live : boolean
	focusMode : string
	node : any
	confirm : function(source : string)
	onStep : function()
	lastConfirm : number
	-- (selector(): what the crosshair is over, a handle held, putting it down)
	hovered : Engine.Entity
	hoverIdx : {integer}
	hoverDetails : Gui.SelectionDetails
	holding : boolean
	release : function()
	-- a mouse event of this type (api.gui.mouse.Event.Type) at the crosshair, into the tool's
	-- onProcessMouseEvent; true if it took it (for a tool's own pad buttons, e.g. Signals' X)
	send : function(t : any) : boolean
end

local function use() : Pad
	local pad = react.useRef({}):get() as Pad
	pad.gamepad = react.useState(isGamepad()) as ReactStateT<boolean>
	pad.mounted = react.useState(false) as ReactStateT<boolean>
	pad.focusMode = pad.focusMode or "Action"
	pad.node = react.useNodeRef(PadFocus)
	-- the controller's prompt list (one shared stylesheet rule for every tool: the game limits the
	-- rules across all mods - panel/ntools_panel.css.lua)
	if pad.gamepad:old() then react.setStyleClasses("ntools-pad-prompts") end
	react.onStep(function()
		local g = isGamepad()
		if g ~= pad.gamepad:old() then pad.gamepad:set(g) end
		if g and pad.live and pad.focusMode == "Action" and pad.onStep then pcall(pad.onStep) end
	end)
	react.onEvent("constructionMenuChangeFocusMode", function(__ : string, mode : string)
		pad.focusMode = mode or "Action"
		-- back from the option bar: the menu refocuses its button - take the focus back
		if pad.focusMode == "Action" then
			pcall(function()
				local node = (pad.node as ReactRefWrap):get()
				if node then node:focus() end
			end)
		end
	end)
	return pad
end

-- For the world layer (its actionFn): mark it mounted while it is up
local function trackLayer(pad : Pad)
	react.onMount(function() pad.live = true; pad.mounted:set(true) end)
	react.onUnmount(function() pad.live = false; pad.mounted:set(false) end)
end

-- A confirm, debounced: one press can arrive by IA_APPLY, IA_SELECT and the Selector's onSelect
local function debounced(pad : Pad) : boolean
	local now = os.clock()
	if now - (pad.lastConfirm or -1) < 0.15 then return false end
	pad.lastConfirm = now
	return true
end

-- The controller's input actions, registered after the tool's gate (only while it is in use:
-- registered before activation they took the press that activates it). confirmText: the
-- confirm's prompt; back: what Circle does (leave the tool, or put a dragged handle down)
local function actions(pad : Pad, confirmText : string, back : function(), backText : string)
	local function live() : boolean return pad.live == true and pad.focusMode == "Action" end
	-- (as the tools' shortcutHandler; bound through pcall - an unknown action name throws and kills
	-- the construction menu)
	local function use(name : string, fn : function(), text? : string)
		pcall(function()
			react.useInputAction(name, react.iaHandler(fn, function() : Gui.InputAction.InputActionState
				return live() and api.gui.inputAction.InputActionState.Enabled
					or api.gui.inputAction.InputActionState.Disabled
			end, text))
		end)
	end
	use("IA_APPLY", function() if pad.confirm then pad.confirm("IA_APPLY") end end, confirmText)
	use("IA_SELECT", function() if pad.confirm then pad.confirm("IA_SELECT") end end)
	-- the option bar (mode, sliders, Reset / Build): the menu moves the focus there and its own back
	-- button brings it home
	use("IA_OPTION2", function() react.fireEvent(nil, "constructionMenuToggleBottomBarFocus") end, _("Options"))
	-- (a handle held: put it down first)
	use("IA_MENU_BACK", function()
		if pad.holding and pad.release then pad.release() else back() end
	end, pad.holding and _("Put down") or backText)
end

-- A tool's Selector params, made ready for the pad (mouse: unchanged). The crosshair is the mouse:
-- the tool's onProcessMouseEvent gets a Moved each step (handle hover; a held handle follows), and a
-- confirm is a click - a Pressed first (a handle takes it: held until the next confirm, a Released),
-- else the tool's onSelect on what the crosshair is over (recorded by onHover). The engine also
-- delivers a pad confirm through onSelect: one route, debounced.
local function selector(pad : Pad, p : {string : any}) : {string : any}
	if not pad.gamepad:old() then return p end
	local onSelect = p.onSelect as function(Engine.Entity, {integer}, Gui.SelectionDetails) : boolean
	local onHover = p.onHover as function(Engine.Entity, {integer}, Gui.SelectionDetails)
	local onMouse = p.onProcessMouseEvent as function(Gui.Mouse.Event) : boolean
	local T = api.gui.mouse.Event.Type
	local function fake(t : any) : Gui.Mouse.Event return ({ type = t, button = 0 } as any) as Gui.Mouse.Event end
	local function send(t : any) : boolean
		if not onMouse then return false end
		local ok, took = pcall(onMouse, fake(t))
		return ok and took == true
	end
	pad.send = send
	pad.release = function()
		pad.holding = false
		send(T.Released)
	end
	pad.confirm = function(source : string)
		if not debounced(pad) then return end
		-- a handle held: put it down (a Released only acts on a real drag - if none, the press goes on)
		if pad.holding then
			pad.holding = false
			if send(T.Released) then return end
		end
		if send(T.Pressed) then pad.holding = true; return end
		local h = pad.hovered
		if onSelect and h and h >= 0 then
			pcall(onSelect, h, pad.hoverIdx or {}, pad.hoverDetails)
		end
	end
	pad.onStep = function() send(T.Moved) end
	local q : {string : any} = {}
	for k, v in pairs(p) do q[k] = v end
	q.onHover = function(e : Engine.Entity, idx : {integer}, d : Gui.SelectionDetails)
		pad.hovered, pad.hoverIdx, pad.hoverDetails = e, idx, d
		if onHover then onHover(e, idx, d) end
	end
	q.onSelect = function(e : Engine.Entity, idx : {integer}, d : Gui.SelectionDetails) : boolean
		if e and e >= 0 then pad.hovered, pad.hoverIdx, pad.hoverDetails = e, idx, d end
		pad.confirm("selector")
		return true
	end
	return q
end

-- The focus anchor for the tool's recipe to return while on the pad with its world layer up
-- (nil otherwise)
local function anchor(pad : Pad) : TreeNodeId
	if not (pad.gamepad:old() and pad.live) then return nil end
	return builtin.BoxLayout{ children = {
		(PadFocus as function(any, any) : TreeNodeId)(react.ref(pad.node), { meta = { forceFocusable = true } }),
	} }
end

-- The tool's world layer is up (the tool's gate: on a pad isActive flickers off on the confirm
-- press, so the tool stays while this holds)
local function isLive(pad : Pad) : boolean
	return pad.live == true
end

-- The world layer's ActionDescriptor fields for the pad: the crosshair and the focus circle
local function crosshair(pad : Pad) : boolean, string
	local g = pad.gamepad:old() == true
	return g, g and "FocusSelection" or "Never"
end

local record M
	isGamepad : function() : boolean
	PadFocus : any
	use : function() : Pad
	trackLayer : function(pad : Pad)
	actions : function(pad : Pad, confirmText : string, back : function(), backText : string)
	debounced : function(pad : Pad) : boolean
	selector : function(pad : Pad, p : {string : any}) : {string : any}
	anchor : function(pad : Pad) : TreeNodeId
	crosshair : function(pad : Pad) : boolean, string
	isLive : function(pad : Pad) : boolean
end
local m : M = {
	isGamepad = isGamepad,
	PadFocus = PadFocus,
	use = use,
	trackLayer = trackLayer,
	actions = actions,
	debounced = debounced,
	selector = selector,
	anchor = anchor,
	crosshair = crosshair,
	isLive = isLive,
}
return m
