-- Network Tools: reshaping a stretch of road / track - the shared engine behind Smooth / Straighten,
-- Arrange on line and Arrange on circle (Set slope works the same way but keeps its own copy).
--
-- A tool supplies new positions for some nodes and new curves (tangents) for some segments; this
-- builds the proposal. TF3 has no "move node" command, so every moved node is replaced by a new
-- one and every segment touching it - side roads too - is removed and re-added. Side roads keep
-- their own curve, only their end moves. The untouched end nodes' lane connections name removed
-- segments, so their configs are dropped and the engine rebuilds them (see net_util).
--
-- It also registers a complete tool recipe from a small spec (create()): stretch selection,
-- handles, preview, tooltip, the busy guard after Build, and the panel's Reset / Build events.

local builtin = ug_require "::/gui/main/builtin.lua" as Builtin
-- game controller support (shared/ntools_pad)
local record PadModule
	use : function() : any
	isLive : function(pad : any) : boolean
	trackLayer : function(pad : any)
	actions : function(pad : any, confirmText : string, back : function(), backText : string)
	selector : function(pad : any, p : {string : any}) : {string : any}
	anchor : function(pad : any) : TreeNodeId
	crosshair : function(pad : any) : boolean, string
end
local padMod = require "network_tools_1::/gui/construction/tools/shared/ntools_pad.script.tl" as PadModule
local react = ug_require "::/gui/main/react.lua" as React
local leave = require "network_tools_1::/gui/construction/tools/shared/ntools_leave.script.tl" as function(any)
local engine_react_util = ug_require "::/gui/main/engine_react_util.tl" as EngineReactUtil

local record P3
	x : number
	y : number
	z : number
end
local record Piece
	p0 : P3
	t0 : P3
	p1 : P3
	t1 : P3
end
local record Geom
	p3 : function(x : number, y : number, z : number) : P3
	vec3 : function(p : P3) : Vec3f
	edgePiece : function(e : Engine.Component.BaseEdge) : Piece
	length : function(pc : Piece) : number
end
local geom = require "network_tools_1::/gui/construction/tools/shared/ntools_geom.script.tl" as Geom

local record NetUtil
	isProtectedNode : function(node : Engine.Entity) : boolean
	whyNotReplaceable : function(edge : Engine.Entity) : string
	configNodesFor : function(removedEdges : {Engine.Entity}, extraNodes? : {Engine.Entity}, skipNodes? : {Engine.Entity}) : {Engine.Entity}
	isCrossingNode : function(node : Engine.Entity) : boolean
	rebuildCrossings : function(proposal : SimpleProposal, removedEdges : {Engine.Entity}, skipNodes? : {Engine.Entity}) : integer
end
local net_util = require "network_tools_1::/gui/construction/tools/shared/ntools_net_util.script.tl" as NetUtil

-- bridges / tunnels where a reshaped segment runs high above / deep below the ground (shared rules)
local record Terrain
	upgradeSegment : function(seg : Proposal.SegmentAndEntity, isTrack : boolean, bridgeId? : integer, tunnelId? : integer, noShore? : boolean) : string
end
local terrain = require "network_tools_1::/gui/construction/tools/shared/ntools_terrain.script.tl" as Terrain

-- the build preview: the game's ProposalViewer, or our own green one in Anarchy (no red)
local record PreviewParams
	proposal : SimpleProposal
	id : string
	onData : function(ProposalData)
	anarchy : boolean
end
local record Preview
	viewer : function(p : PreviewParams) : TreeNodeId
	leftover : function() : TreeNodeId
	tags : function() : TreeNodeId
	clear : function()
end
local preview = require "network_tools_1::/gui/construction/tools/shared/ntools_preview.script.tl" as Preview

local record ChainLink
	edge : Engine.Entity
	fwd : boolean
end
local record Chain
	linkEnds : function(link : ChainLink) : Engine.Entity, Engine.Entity
	nodes : function(chain : {ChainLink}) : {Engine.Entity}
	click : function(chain : {ChainLink}, entity : Engine.Entity) : {ChainLink}
end
local chain_util = require "network_tools_1::/gui/construction/tools/shared/ntools_chain.script.tl" as Chain

local record Handle
	x : number
	y : number
	z : number
end
local record Canvas
	line : function(x0 : number, y0 : number, z0 : number, x1 : number, y1 : number, z1 : number, color : Vec4f, width : number)
	circle : function(cx : number, cy : number, z : number, r : number, color : Vec4f, width : number)
	handle : function(h : Handle, state : integer)
	node : function() : TreeNodeId
end
local record DragCtl
	handles : {Handle}
	dragging : integer
	setDragging : function(i : integer)
	hover : integer
	setHover : function(i : integer)
	onDrag : function(i : integer, x : number, y : number)
	onRelease : function(i : integer)
	onPress : function(i : integer)
end
local record Handles
	canvas : function() : Canvas
	hit : function(handles : {Handle}, x : number, y : number) : integer
	mouse : function(evt : Gui.Mouse.Event, ctl : DragCtl) : boolean
	cursor : function() : number, number
	colors : {string : Vec4f}
end
local handles = require "network_tools_1::/gui/construction/tools/shared/ntools_handles.script.tl" as Handles

do ((require "network_tools_1::/gui/construction/tools/shared/ntools_debug.script.tl" as {string : any}).log as function(string))("[network_tools] reshape engine loaded (v1)") end

----------------------------------------------------------------------------------------------------
-- Host (handed over once by the connect tool)

local record UiState
	canBuild : boolean
end
local record Host
	getEdge : function(Engine.Entity) : Engine.Component.BaseEdge
	isEdge : function(Engine.Entity) : boolean
	getNodePos : function(Engine.Entity) : P3
	tooltip : function(message : string, good : boolean, bad : boolean, cost? : integer) : TreeNodeId
	anarchy : function() : boolean
	ui : UiState
	toolbarEvents : {string}
end
local g_host : Host = nil
local function init(host : any) g_host = host as Host end

----------------------------------------------------------------------------------------------------
-- Proposal

-- A segment's new curve, in the segment's own direction (node0 -> node1).
local record Curve
	t0 : P3
	t1 : P3
end

local function copyEdge(seg : Proposal.SegmentAndEntity, edge : Engine.Entity, e : Engine.Component.BaseEdge)
	seg.comp.type = e.type
	seg.comp.typeIndex = e.typeIndex
	seg.comp.laneConfigs = e.laneConfigs
	seg.comp.roadTemplate = e.roadTemplate
	seg.comp.roadStyle = e.roadStyle
	seg.comp.roadType = e.roadType
	seg.comp.roadDevelopmentLocked = e.roadDevelopmentLocked
	if e.roadType == api.type["enum"].RoadType.TRACK then
		seg.type = 1
	else
		seg.type = 0
		local street = api.engine.getComponent(edge, api.type.ComponentType.BASE_EDGE_STREET) as Engine.Component.BaseEdgeStreet
		if street then seg.streetEdge = street end
	end
end

-- moves: node -> new position. curves: segment -> new tangents (others keep theirs). Returns the
-- proposal, or nil and why not.
local function makeReshapeProposal(moves : {Engine.Entity : P3}, curves : {Engine.Entity : Curve}) : SimpleProposal, string
	local moved : {Engine.Entity} = {}
	for n, _p in pairs(moves) do
		-- (a moved node is removed and re-added: a level crossing can't be, it is re-created only
		-- where its node stays)
		if net_util.isProtectedNode(n) or net_util.isCrossingNode(n) then
			return nil, _("A node that would move is a level crossing or has hand-edited lanes / lights")
		end
		moved[#moved + 1] = n
	end
	table.sort(moved)
	-- segments to re-add: the reshaped ones plus every segment touching a moved node
	local toReAdd : {Engine.Entity} = {}
	local seen : {Engine.Entity : boolean} = {}
	local function addEdge(e : Engine.Entity)
		if not seen[e] then seen[e] = true; toReAdd[#toReAdd + 1] = e end
	end
	local curveEdges : {Engine.Entity} = {}
	for e, _c in pairs(curves) do curveEdges[#curveEdges + 1] = e end
	table.sort(curveEdges)
	for _, e in ipairs(curveEdges) do addEdge(e) end
	for _, n in ipairs(moved) do
		local ok, segs = pcall(function() : {Engine.Entity}
			return api.engine.system.streetSystem.getNodeSegments(n)
		end)
		for _, s in ipairs(ok and segs or {}) do addEdge(s) end
	end
	if #toReAdd == 0 then return nil, nil end
	for _, e in ipairs(toReAdd) do
		local why = net_util.whyNotReplaceable(e)
		if why then return nil, why end
	end

	-- ids count down from -1: segments first, then the replacement nodes
	local E = #toReAdd
	local newId : {Engine.Entity : Engine.Entity} = {}
	local nodesToAdd : {Proposal.NodeAndEntity} = {}
	for j, n in ipairs(moved) do
		newId[n] = -(E + j)
		local node = api.type.NodeAndEntity.new()
		node.entity = newId[n]
		node.comp.position = geom.vec3(moves[n])
		nodesToAdd[#nodesToAdd + 1] = node
	end
	local edgesToAdd : {Proposal.SegmentAndEntity} = {}
	for i, edge in ipairs(toReAdd) do
		local e = g_host.getEdge(edge)
		if not e then return nil, nil end
		local pc = geom.edgePiece(e)
		if moves[e.node0] then pc.p0 = moves[e.node0] end
		if moves[e.node1] then pc.p1 = moves[e.node1] end
		local c = curves[edge]
		if c then pc.t0, pc.t1 = c.t0, c.t1 end
		local seg = api.type.SegmentAndEntity.new()
		seg.entity = -i
		seg.comp.node0 = newId[e.node0] or e.node0
		seg.comp.node1 = newId[e.node1] or e.node1
		seg.comp.position0, seg.comp.position1 = geom.vec3(pc.p0), geom.vec3(pc.p1)
		seg.comp.tangent0, seg.comp.tangent1 = geom.vec3(pc.t0), geom.vec3(pc.t1)
		copyEdge(seg, edge, e)
		edgesToAdd[#edgesToAdd + 1] = seg
	end

	local proposal = api.type.SimpleProposal.new()
	if #nodesToAdd > 0 then proposal.streetProposal.nodesToAdd = nodesToAdd end
	-- a segment now high above the ground becomes a bridge, deep below it a tunnel (not the shore
	-- rule: these are existing roads)
	for _, seg in ipairs(edgesToAdd) do
		terrain.upgradeSegment(seg, seg.type == 1, nil, nil, true)
	end
	proposal.streetProposal.edgesToAdd = edgesToAdd
	proposal.streetProposal.edgesToRemove = toReAdd
	if #moved > 0 then proposal.streetProposal.nodesToRemove = moved end
	local cfgNodes = net_util.configNodesFor(toReAdd, nil, moved)
	if #cfgNodes > 0 then proposal.streetProposal.nodeConfigsToRemove = cfgNodes end
	-- an untouched end at a level crossing: the engine re-creates the crossing
	net_util.rebuildCrossings(proposal, toReAdd, moved)
	return proposal, nil
end

-- A curve given in the stretch's direction (start tangent, end tangent), turned into the
-- segment's own direction.
local function linkCurve(link : ChainLink, t0 : P3, t1 : P3) : Curve
	if link.fwd then return { t0 = t0, t1 = t1 } end
	return {
		t0 = geom.p3(-t1.x, -t1.y, -t1.z),
		t1 = geom.p3(-t0.x, -t0.y, -t0.z),
	}
end

-- Plan tangent (dx, dy, scaled to len) with the climb of a segment from z0 to z1 spread evenly.
local function gradedTangent(dx : number, dy : number, len : number, z0 : number, z1 : number, hChord : number) : P3
	local l = math.sqrt(dx * dx + dy * dy)
	if l < 1e-9 then return geom.p3(0, 0, 0) end
	local grade = hChord > 0.01 and (z1 - z0) / hChord or 0
	return geom.p3(dx / l * len, dy / l * len, grade * len)
end

----------------------------------------------------------------------------------------------------
-- Tool recipe factory

-- What a tool computes for the current stretch every render.
local record Shape
	moves : {Engine.Entity : P3}
	curves : {Engine.Entity : Curve}
	why : string                         -- shown instead of building
	info : string                        -- extra tooltip line
	handles : {Handle}                   -- optional in-world handles
	onDrag : function(i : integer, x : number, y : number)
	onPress : function(i : integer)      -- optional: a handle pressed (before any drag)
	draw : function(c : Canvas)          -- optional extra overlay (guides)
	tags : {any}                         -- optional in-world tags (shared/ntools_labels points)
end

local labels = require "network_tools_1::/gui/construction/tools/shared/ntools_labels.script.tl" as {string : any}
local setLabels = labels.set as function(tags : {Engine.Entity : any}, points : {any})

local record Spec
	recipeName : string                  -- also the CSS / key-prompt scope (R::<name>)
	hint : string                        -- tooltip with nothing selected
	buildHint : string                   -- tooltip when ready
	minLinks : integer                   -- shortest stretch it works on
	compute : function(chain : {ChainLink}, nodes : {Engine.Entity}) : Shape
	key : function() : string            -- options folded into the preview id (re-preview on change)
end

local function create(spec : Spec) : function(ConstructionCustomActionParams<any>) : TreeNodeId
	return react.RegisterRecipe(spec.recipeName, function(params : ConstructionCustomActionParams<any>) : TreeNodeId
		react.onUnmount(preview.clear)   -- its speed / incline tags leave with the tool
		local chainState : ReactStateT<{ChainLink}> = react.useState({})
		local costState : ReactStateT<integer> = react.useState(0)
		local errorState : ReactStateT<string> = react.useState("")
		local aliveRef : ReactRefT<boolean> = react.useRef(true)
		-- true from Build until the command's callback: touching a half-built segment (hover
		-- filter) is an engine assertion, not a Lua error - no picker, no proposal meanwhile
		local busyState : ReactStateT<boolean> = react.useState(false)
		local draggingState : ReactStateT<integer> = react.useState(0)
		local hoverState : ReactStateT<integer> = react.useState(0)
		-- re-render when the tool's options change (panel / toolbar / handles)
		local keyUi = engine_react_util.useStepState(function() : string return spec.key and spec.key() or "" end)
		local anarchyUi = engine_react_util.useStepState(function() : boolean return g_host.anarchy() end)

		local handlersRef : ReactRefT<{string : function()}> = react.useRef({})
		for _, name in ipairs(g_host.toolbarEvents) do
			react.onEvent(name, function()
				local h = handlersRef:get()[name]
				if h then h() end
			end)
		end

		react.setForceFocusable(true)
		react.setRestrictMouseFocus(true)
		local pad = padMod.use()

		-- (on a pad isActive flickers off on the confirm press: the tool stays while its layer is up)
		if not params.isActive and not padMod.isLive(pad) then
			return
		end

		local busy = busyState:old() == true
		local chain : {ChainLink} = {}
		if not busy then
			for _, l in ipairs(chainState:old() or {}) do
				if api.engine.entityExists(l.edge) and g_host.getEdge(l.edge) then chain[#chain + 1] = l end
			end
		end
		local optKey = keyUi:old() or ""
		local anarchy = anarchyUi:old() == true

		local shape : Shape = nil
		local proposal : SimpleProposal = nil
		local why : string = nil
		if not busy and #chain >= (spec.minLinks or 1) then
			local nodes = chain_util.nodes(chain)
			local ok, res = pcall(function() : Shape return spec.compute(chain, nodes) end)
			if ok then shape = res else why = tostring(res) end
			if shape and shape.why then
				why = shape.why
			elseif shape then
				proposal, why = makeReshapeProposal(shape.moves or {}, shape.curves or {})
			end
		end
		local blocked = errorState:old() ~= "" and not anarchy
		g_host.ui.canBuild = proposal ~= nil and not blocked

		local function clear()
			if aliveRef:hasExpired() then return end
			chainState:set({})
			costState:set(0)
			errorState:set("")
		end

		local function build()
			if not proposal or blocked or busy then return end
			local context = api.type.Context.new()
			context.player = api.engine.util.getPlayer()
			local cmd = api.cmd.makeWorldBuildProposalCmd(proposal, context, anarchy, true)
			chainState:set({})
			busyState:set(true)
			-- (the shared send every tool's build goes through)
			((require "network_tools_1::/gui/construction/tools/shared/ntools_options.script.tl" as {string : any}).send as function(Command<WorldBuildProposalCommandData>, function(WorldBuildProposalCommandData, boolean)))(cmd, function(__ : WorldBuildProposalCommandData, success : boolean)
				if not success then
					do ((require "network_tools_1::/gui/construction/tools/shared/ntools_debug.script.tl" as {string : any}).log as function(string))("[network_tools] " .. spec.recipeName .. ": build failed") end
				end
				if aliveRef:hasExpired() then return end
				busyState:set(false)
				clear()
			end)
		end

		handlersRef:set({
			ntoolsResetShape = clear,
			ntoolsBuild = build,
		})

		local handleList : {Handle} = shape and shape.handles or {}
		local dragging = draggingState:old() or 0
		local hover = hoverState:old() or 0
		local dragCtl : DragCtl = {
			handles = handleList,
			dragging = dragging,
			setDragging = function(i : integer) draggingState:set(i) end,
			hover = hover,
			setHover = function(i : integer) hoverState:set(i) end,
			onDrag = function(i : integer, x : number, y : number)
				if shape and shape.onDrag then shape.onDrag(i, x, y) end
			end,
			onPress = function(i : integer)
				if shape and shape.onPress then shape.onPress(i) end
			end,
		}

		padMod.actions(pad, _("Pick segment / grab handle"), function() leave(params) end, _("Leave the tool"))

		local actionFn = function() : TreeNodeId
			padMod.trackLayer(pad)
			local crosshair, circle = padMod.crosshair(pad)
			if busy then
				return builtin.ActionDescriptor{
					tool = "construction-menu-perks",
					onBack = function() leave(params) end,
					crosshair = crosshair,
					terrainCirclePolicy = circle,
					children = { g_host.tooltip(_("Building..."), true, false) },
				}
			end
			local children : {TreeNodeId} = {
				builtin.Selector(padMod.selector(pad, {
					onSelect = function(entity : Engine.Entity, __ : {integer}, __ : Gui.SelectionDetails) : boolean
						-- a click on a handle is a drag, not a selection
						local cx, cy = handles.cursor()
						if dragging ~= 0 or (cx and handles.hit(handleList, cx, cy) > 0) then return true end
						if not g_host.getEdge(entity) then return false end
						costState:set(0)
						errorState:set("")
						chainState:set(chain_util.click(chain, entity))
						return true
					end,
					onProcessMouseEvent = function(evt : Gui.Mouse.Event) : boolean
						return handles.mouse(evt, dragCtl)
					end,
					filter = g_host.isEdge,
				}) as Builtin.SelectorParam),
			}
			if proposal then
				local id = spec.recipeName .. "," .. optKey
				for _, l in ipairs(chain) do id = id .. "," .. tostring(l.edge) end
				children[#children + 1] = preview.viewer{
					proposal = proposal,
					anarchy = anarchy,
					onData = function(proposalData : ProposalData)
						if aliveRef:hasExpired() then return end
						costState:set(proposalData.costs)
						local msg = ""
						for __, m in ipairs(proposalData.errorState.messages) do
							msg = msg .. m .. " "
						end
						errorState:set(msg)
					end,
					id = id,
				}
			end

			local info = _("Segments") .. ": " .. tostring(#chain)
			if shape and shape.info then info = info .. "   " .. shape.info end
			if #chain == 0 then
				children[#children + 1] = g_host.tooltip(spec.hint, false, false)
			elseif #chain < (spec.minLinks or 1) then
				children[#children + 1] = g_host.tooltip(_("Select a longer stretch") .. "\n" .. info, false, true)
			elseif why then
				children[#children + 1] = g_host.tooltip(why .. "\n" .. info, false, true)
			elseif not proposal then
				children[#children + 1] = g_host.tooltip(_("Nothing to change on this stretch") .. "\n" .. info, false, false)
			elseif blocked then
				children[#children + 1] = g_host.tooltip(errorState:old() .. "\n" .. info, false, true, costState:old())
			else
				children[#children + 1] = g_host.tooltip(spec.buildHint .. "\n" .. info, true, false, costState:old())
			end

			-- handles and guides (one EdgeRenderable per recipe)
			if shape and (#handleList > 0 or shape.draw) then
				local c = handles.canvas()
				if shape.draw then shape.draw(c) end
				for i, h in ipairs(handleList) do
					c.handle(h, dragging == i and 2 or (hover == i and 1 or 0))
				end
				local n = c.node()
				if n then children[#children + 1] = n end
			end

			local highlighted : {Engine.Entity} = {}
			for _, l in ipairs(chain) do highlighted[#highlighted + 1] = l.edge end
			-- Anarchy preview strips no overlay drew this frame
			local lo = preview.leftover()
			if lo then children[#children + 1] = lo end
			-- speed / gradient tags on the new segments, and the tool's own (radius, spacing)
			setLabels({}, shape and shape.tags or {})
			local tags = preview.tags()
			if tags then children[#children + 1] = tags end
			-- underground view (panel option, all tools)
			local under = ((require "network_tools_1::/gui/construction/tools/shared/ntools_options.script.tl" as {string : any}).layerNode as function() : TreeNodeId)()
			if under then children[#children + 1] = under end
			return builtin.ActionDescriptor{
				tool = "construction-menu-perks",
				onBack = function() leave(params) end,
				highlightedEntities = highlighted,
				crosshair = crosshair,
				terrainCirclePolicy = circle,
				children = children,
			}
		end

		params.setActionFn(actionFn, spec.recipeName)
		return padMod.anchor(pad)
	end)
end

local record Reshape
	init : function(host : any)
	create : function(spec : Spec) : function(ConstructionCustomActionParams<any>) : TreeNodeId
	makeReshapeProposal : function(moves : {Engine.Entity : P3}, curves : {Engine.Entity : Curve}) : SimpleProposal, string
	linkCurve : function(link : ChainLink, t0 : P3, t1 : P3) : Curve
	gradedTangent : function(dx : number, dy : number, len : number, z0 : number, z1 : number, hChord : number) : P3
end
local M : Reshape = {
	init = init,
	create = create,
	makeReshapeProposal = makeReshapeProposal,
	linkCurve = linkCurve,
	gradedTangent = gradedTangent,
}
return M
