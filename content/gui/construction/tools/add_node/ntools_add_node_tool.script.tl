-- Network Tools: Add node (modelled on Network Multitool's AddNode for Cities: Skylines 1 and
-- Network Tools' Add Node for Cities: Skylines 2).
-- Click a road or track where you want a node: the segment is split there with a plain node and
-- keeps exactly its shape, type and lanes. One click, no Build button.
--
-- TF3 has no split command: the segment is removed and re-added as two halves through a new node,
-- and the end nodes' lane connections are dropped so the engine rebuilds them (see net_util).
-- Loaded by the connect tool, which hands over shared helpers through init().

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
	vec3 : function(p : P3) : Vec3f
	edgePiece : function(e : Engine.Component.BaseEdge) : Piece
	split : function(pc : Piece, ts : {number}) : {Piece}
	length : function(pc : Piece) : number
	closestT : function(pc : Piece, x : number, y : number) : number, number
	point : function(pc : Piece, t : number) : P3
	tangent : function(pc : Piece, t : number) : P3
end
local geom = require "network_tools_1::/gui/construction/tools/shared/ntools_geom.script.tl" as Geom

local record NetUtil
	rebuildCrossings : function(proposal : SimpleProposal, removedEdges : {Engine.Entity}, skipNodes? : {Engine.Entity}) : integer
	whyNotReplaceable : function(edge : Engine.Entity) : string
	configNodesFor : function(removedEdges : {Engine.Entity}, extraNodes? : {Engine.Entity}, skipNodes? : {Engine.Entity}) : {Engine.Entity}
end
local net_util = require "network_tools_1::/gui/construction/tools/shared/ntools_net_util.script.tl" as NetUtil

-- in-world drawing (shared handle kit)
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
local record Handles
	canvas : function() : Canvas
	cursor : function() : number, number
	colors : {string : Vec4f}
end
local handles = require "network_tools_1::/gui/construction/tools/shared/ntools_handles.script.tl" as Handles

do ((require "network_tools_1::/gui/construction/tools/shared/ntools_debug.script.tl" as {string : any}).log as function(string))("[network_tools] add node tool script loaded (v2: ghost node)") end

local MIN_PART = 2.0   -- metres: shortest half a split may leave

local record Host
	getEdge : function(Engine.Entity) : Engine.Component.BaseEdge
	isEdge : function(Engine.Entity) : boolean
	tooltip : function(message : string, good : boolean, bad : boolean, cost? : integer) : TreeNodeId
	anarchy : function() : boolean
end

local g_host : Host = nil
local getEdge : function(Engine.Entity) : Engine.Component.BaseEdge
local isEdge : function(Engine.Entity) : boolean
local tooltip : function(message : string, good : boolean, bad : boolean, cost? : integer) : TreeNodeId

local function init(host : Host)
	g_host = host
	getEdge, isEdge, tooltip = host.getEdge, host.isEdge, host.tooltip
end

-- Split `edge` at the point closest to (x, y). Returns the proposal, or nil and why not.
local function makeAddNodeProposal(edge : Engine.Entity, x : number, y : number) : SimpleProposal, string
	local why = net_util.whyNotReplaceable(edge)
	if why then return nil, why end
	local e = getEdge(edge)
	local pc = geom.edgePiece(e)
	local t = geom.closestT(pc, x, y)
	local len = geom.length(pc)
	if t * len < MIN_PART or (1 - t) * len < MIN_PART then
		return nil, _("Too close to the end of the segment - there is a node there already")
	end
	local parts = geom.split(pc, { t })

	-- ids count down from -1: edges first, then the node
	local NEW_NODE : Engine.Entity = -3
	local node = api.type.NodeAndEntity.new()
	node.entity = NEW_NODE
	node.comp.position = geom.vec3(parts[1].p1)

	local street : Engine.Component.BaseEdgeStreet = nil
	if e.roadType ~= api.type["enum"].RoadType.TRACK then
		street = api.engine.getComponent(edge, api.type.ComponentType.BASE_EDGE_STREET) as Engine.Component.BaseEdgeStreet
	end
	local edges : {Proposal.SegmentAndEntity} = {}
	for i, part in ipairs(parts) do
		local seg = api.type.SegmentAndEntity.new()
		seg.entity = -i
		seg.comp.node0 = i == 1 and e.node0 or NEW_NODE
		seg.comp.node1 = i == 1 and NEW_NODE or e.node1
		seg.comp.position0, seg.comp.position1 = geom.vec3(part.p0), geom.vec3(part.p1)
		seg.comp.tangent0, seg.comp.tangent1 = geom.vec3(part.t0), geom.vec3(part.t1)
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
			if street then seg.streetEdge = street end
		end
		edges[#edges + 1] = seg
	end

	local proposal = api.type.SimpleProposal.new()
	proposal.streetProposal.nodesToAdd = { node }
	proposal.streetProposal.edgesToAdd = edges
	proposal.streetProposal.edgesToRemove = { edge }
	local cfgNodes = net_util.configNodesFor({ edge })
	if #cfgNodes > 0 then
		proposal.streetProposal.nodeConfigsToRemove = cfgNodes
	end
	-- a segment ending at a level crossing: the engine re-creates the crossing
	net_util.rebuildCrossings(proposal, { edge })
	return proposal, nil
end

local AddNodeActionRecipe = react.RegisterRecipe("NtoolsAddNodeAction", function(params : ConstructionCustomActionParams<any>) : TreeNodeId
	local aliveRef : ReactRefT<boolean> = react.useRef(true)
	-- true from the click until the command's callback: touching the half-built segment under the
	-- cursor (hover filter) is an engine assertion, not a Lua error
	local busyState : ReactStateT<boolean> = react.useState(false)
	local messageState : ReactStateT<string> = react.useState("")
	-- ghost node: the segment under the cursor, and the cursor (rounded, to re-render on moves)
	local hoverEdgeState : ReactStateT<Engine.Entity> = react.useState(-1)
	local cursorState : ReactStateT<string> = react.useState("")

	react.setForceFocusable(true)
	react.setRestrictMouseFocus(true)
	local pad = padMod.use()

	-- (on a pad isActive flickers off on the confirm press: the tool stays while its layer is up)
	if not params.isActive and not padMod.isLive(pad) then
		return
	end

	local busy = busyState:old() == true

	local function onSelect(entity : Engine.Entity) : boolean
		if busy or not getEdge(entity) then return false end
		if not api.gui.mouse.hasTerrainPosition() then return false end
		local m = api.gui.mouse.getTerrainPosition()
		local proposal, why = makeAddNodeProposal(entity, m.x, m.y)
		if not proposal then
			messageState:set(why or "")
			return true
		end
		messageState:set("")
		local context = api.type.Context.new()
		context.player = api.engine.util.getPlayer()
		local cmd = api.cmd.makeWorldBuildProposalCmd(proposal, context, g_host.anarchy(), true)
		busyState:set(true)
		-- (the shared send every tool's build goes through)
		((require "network_tools_1::/gui/construction/tools/shared/ntools_options.script.tl" as {string : any}).send as function(Command<WorldBuildProposalCommandData>, function(WorldBuildProposalCommandData, boolean)))(cmd, function(__ : WorldBuildProposalCommandData, success : boolean)
			if not success then
				do ((require "network_tools_1::/gui/construction/tools/shared/ntools_debug.script.tl" as {string : any}).log as function(string))("[network_tools] Add node: build failed") end
			end
			if aliveRef:hasExpired() then return end
			busyState:set(false)
			if not success then messageState:set(_("The game refused this node here")) end
		end)
		return true
	end

	-- Ghost node: where a click would split, snapped onto the hovered segment; red when the
	-- split would be too close to an existing node
	local function ghostNode() : TreeNodeId
		local _key = cursorState:old()   -- read so cursor moves re-render
		local edge = hoverEdgeState:old() or -1
		if edge < 0 or not api.engine.entityExists(edge) then return nil end
		local e = getEdge(edge)
		local x, y = handles.cursor()
		if not e or not x then return nil end
		local pc = geom.edgePiece(e)
		local t = geom.closestT(pc, x, y)
		local len = geom.length(pc)
		local ok = t * len >= MIN_PART and (1 - t) * len >= MIN_PART
		local p = geom.point(pc, t)
		local d = geom.tangent(pc, t)
		local dl = math.sqrt(d.x * d.x + d.y * d.y)
		local c = handles.canvas()
		local color = ok and handles.colors.good or handles.colors.bad
		c.circle(p.x, p.y, p.z, 3.0, color, 1.4)
		if dl > 1e-6 then
			-- a tick across the road where it would be cut
			local nx, ny = -d.y / dl * 6, d.x / dl * 6
			c.line(p.x - nx, p.y - ny, p.z, p.x + nx, p.y + ny, p.z, color, 1.0)
		end
		return c.node()
	end

	padMod.actions(pad, _("Add node here"), function() params.abort() end, _("Leave the tool"))

	local actionFn = function() : TreeNodeId
		padMod.trackLayer(pad)
		local crosshair, circle = padMod.crosshair(pad)
		local children : {TreeNodeId} = {}
		if busy then
			children[#children + 1] = tooltip(_("Adding node..."), true, false)
		else
			children[#children + 1] = builtin.Selector(padMod.selector(pad, {
				onSelect = function(entity : Engine.Entity, __ : {integer}, __ : Gui.SelectionDetails) : boolean
					return onSelect(entity)
				end,
				onHover = function(entity : Engine.Entity, __ : {integer}, __ : Gui.SelectionDetails)
					local e : Engine.Entity = (entity and isEdge(entity)) and entity or -1
					if e ~= (hoverEdgeState:old() or -1) then hoverEdgeState:set(e) end
				end,
				onProcessMouseEvent = function(evt : Gui.Mouse.Event) : boolean
					if evt.type == api.gui.mouse.Event.Type.Moved then
						local x, y = handles.cursor()
						local key = x and (tostring(math.floor(x * 2)) .. "," .. tostring(math.floor(y * 2))) or ""
						if key ~= (cursorState:old() or "") then cursorState:set(key) end
					end
					return false
				end,
				filter = isEdge,
			}) as Builtin.SelectorParam)
			local ghost = ghostNode()
			if ghost then children[#children + 1] = ghost end
			local msg = messageState:old() or ""
			if msg ~= "" then
				children[#children + 1] = tooltip(msg, false, true)
			else
				children[#children + 1] = tooltip(_("Click a road or track where you want a node"), true, false)
			end
		end
		-- underground view (panel option, all tools)
		local under = ((require "network_tools_1::/gui/construction/tools/shared/ntools_options.script.tl" as {string : any}).layerNode as function() : TreeNodeId)()
		if under then children[#children + 1] = under end
		return builtin.ActionDescriptor{
			tool = "construction-menu-perks",
			onBack = function() params.abort() end,
			crosshair = crosshair,
			terrainCirclePolicy = circle,
			children = children,
		}
	end

	params.setActionFn(actionFn, "NtoolsAddNodeAction")
	return padMod.anchor(pad)
end)

return {
	init = init,
	AddNodeActionRecipe = AddNodeActionRecipe,
	-- (for Connect: an end placed along a road gets a real node there first - its preview then
	-- shows the road as it is, not split over it)
	makeAddNodeProposal = makeAddNodeProposal,
}
