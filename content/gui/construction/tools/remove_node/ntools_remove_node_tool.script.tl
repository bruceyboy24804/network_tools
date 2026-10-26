-- Network Tools: Remove node (modelled on Network Multitool's RemoveNode for Cities: Skylines 1 and
-- Network Tools' Remove Node for Cities: Skylines 2).
-- Click a road or track next to a plain node (one joining exactly two matching segments): the two
-- segments become one smooth segment and the node goes. One click, no Build button.
--
-- The merged curve leaves the far ends in the old directions, with tangents as long as the two
-- segments together (the usual Hermite fit), so a straight stays straight and a gentle bend stays
-- a gentle bend. Loaded by the connect tool, which hands over shared helpers through init().

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
	p3 : function(x : number, y : number, z : number) : P3
	scaled : function(v : P3, s : number) : P3
	len3 : function(v : P3) : number
	vec3 : function(p : P3) : Vec3f
	edgePiece : function(e : Engine.Component.BaseEdge) : Piece
	length : function(pc : Piece) : number
end
local geom = require "network_tools_1::/gui/construction/tools/shared/ntools_geom.script.tl" as Geom

local record NetUtil
	whyNotReplaceable : function(edge : Engine.Entity) : string
	configNodesFor : function(removedEdges : {Engine.Entity}, extraNodes? : {Engine.Entity}, skipNodes? : {Engine.Entity}) : {Engine.Entity}
	rebuildCrossings : function(proposal : SimpleProposal, removedEdges : {Engine.Entity}, skipNodes? : {Engine.Entity}) : integer
end
local net_util = require "network_tools_1::/gui/construction/tools/shared/ntools_net_util.script.tl" as NetUtil

do ((require "network_tools_1::/gui/construction/tools/shared/ntools_debug.script.tl" as {string : any}).log as function(string))("[network_tools] remove node tool script loaded (v1)") end

local record Pick
	node : Engine.Entity
	edge : Engine.Entity
end

local record Host
	getEdge : function(Engine.Entity) : Engine.Component.BaseEdge
	isEdge : function(Engine.Entity) : boolean
	pickNodeOnEdge : function(Engine.Entity) : Pick
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

local function sameKind(a : Engine.Component.BaseEdge, b : Engine.Component.BaseEdge) : boolean
	return a.roadType == b.roadType and a.roadTemplate == b.roadTemplate and a.roadStyle == b.roadStyle
		and a.type == b.type and a.typeIndex == b.typeIndex
		and #(a.laneConfigs or {}) == #(b.laneConfigs or {})
end

local function unit(v : P3) : P3
	local l = geom.len3(v)
	if l < 1e-6 then return v end
	return geom.scaled(v, 1 / l)
end

-- Merge the two segments at `node` into one. Returns the proposal, or nil and why not.
local function makeRemoveNodeProposal(node : Engine.Entity) : SimpleProposal, string
	local ok, segs = pcall(function() : {Engine.Entity}
		return api.engine.system.streetSystem.getNodeSegments(node)
	end)
	if not ok or not segs or #segs ~= 2 then
		return nil, _("Only a node joining exactly two segments can be removed")
	end
	local s1, s2 = segs[1], segs[2]
	for _, s in ipairs({ s1, s2 }) do
		local why = net_util.whyNotReplaceable(s)
		if why then return nil, why end
	end
	local e1, e2 = getEdge(s1), getEdge(s2)
	if not sameKind(e1, e2) then
		return nil, _("The two segments are different types - they can't become one")
	end
	-- order them along the road: first runs A -> node, second runs node -> B
	local first, second : Engine.Entity, Engine.Entity
	if e1.node1 == node and e2.node0 == node then
		first, second = s1, s2
	elseif e2.node1 == node and e1.node0 == node then
		first, second = s2, s1
	else
		return nil, _("The two segments point opposite ways - Reverse one of them first")
	end
	local f, s = getEdge(first), getEdge(second)
	if f.node0 == s.node1 then
		return nil, _("The two segments form a loop - it can't become one segment")
	end

	local pf, ps = geom.edgePiece(f), geom.edgePiece(s)
	local L = geom.length(pf) + geom.length(ps)
	local p0, p1 = pf.p0, ps.p1
	local t0 = geom.scaled(unit(pf.t0), L)
	local t1 = geom.scaled(unit(ps.t1), L)

	local seg = api.type.SegmentAndEntity.new()
	seg.entity = -1
	seg.comp.node0, seg.comp.node1 = f.node0, s.node1
	seg.comp.position0, seg.comp.position1 = geom.vec3(p0), geom.vec3(p1)
	seg.comp.tangent0, seg.comp.tangent1 = geom.vec3(t0), geom.vec3(t1)
	seg.comp.type = f.type
	seg.comp.typeIndex = f.typeIndex
	seg.comp.laneConfigs = f.laneConfigs
	seg.comp.roadTemplate = f.roadTemplate
	seg.comp.roadStyle = f.roadStyle
	seg.comp.roadType = f.roadType
	seg.comp.roadDevelopmentLocked = f.roadDevelopmentLocked
	if f.roadType == api.type["enum"].RoadType.TRACK then
		seg.type = 1
	else
		seg.type = 0
		-- give-way settings belong to an end: the start end from the first, the far end from the second
		local sf = api.engine.getComponent(first, api.type.ComponentType.BASE_EDGE_STREET) as Engine.Component.BaseEdgeStreet
		local ss = api.engine.getComponent(second, api.type.ComponentType.BASE_EDGE_STREET) as Engine.Component.BaseEdgeStreet
		if sf then
			if ss then pcall(function() sf.precedenceNode1 = ss.precedenceNode1 end) end
			seg.streetEdge = sf
		end
	end

	local proposal = api.type.SimpleProposal.new()
	proposal.streetProposal.edgesToAdd = { seg }
	proposal.streetProposal.edgesToRemove = { first, second }
	proposal.streetProposal.nodesToRemove = { node }
	-- rebuild the far ends' lane connections; the removed node's config goes with it
	local cfgNodes = net_util.configNodesFor({ first, second }, nil, { node })
	if #cfgNodes > 0 then
		proposal.streetProposal.nodeConfigsToRemove = cfgNodes
	end
	-- a far end at a level crossing: the engine re-creates the crossing
	net_util.rebuildCrossings(proposal, { first, second }, { node })
	return proposal, nil
end

local RemoveNodeActionRecipe = react.RegisterRecipe("NtoolsRemoveNodeAction", function(params : ConstructionCustomActionParams<any>) : TreeNodeId
	local aliveRef : ReactRefT<boolean> = react.useRef(true)
	-- true from the click until the command's callback: touching the half-built segment under the
	-- cursor (hover filter) is an engine assertion, not a Lua error
	local busyState : ReactStateT<boolean> = react.useState(false)
	local messageState : ReactStateT<string> = react.useState("")

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
		local pick = g_host.pickNodeOnEdge(entity)
		if not pick or not pick.node then return false end
		local proposal, why = makeRemoveNodeProposal(pick.node)
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
				do ((require "network_tools_1::/gui/construction/tools/shared/ntools_debug.script.tl" as {string : any}).log as function(string))("[network_tools] Remove node: build failed") end
			end
			if aliveRef:hasExpired() then return end
			busyState:set(false)
			if not success then messageState:set(_("The game refused to merge these segments")) end
		end)
		return true
	end

	padMod.actions(pad, _("Remove node"), function() params.abort() end, _("Leave the tool"))

	local actionFn = function() : TreeNodeId
		padMod.trackLayer(pad)
		local crosshair, circle = padMod.crosshair(pad)
		local children : {TreeNodeId} = {}
		if busy then
			children[#children + 1] = tooltip(_("Removing node..."), true, false)
		else
			children[#children + 1] = builtin.Selector(padMod.selector(pad, {
				onSelect = function(entity : Engine.Entity, __ : {integer}, __ : Gui.SelectionDetails) : boolean
					return onSelect(entity)
				end,
				filter = isEdge,
			}) as Builtin.SelectorParam)
			local msg = messageState:old() or ""
			if msg ~= "" then
				children[#children + 1] = tooltip(msg, false, true)
			else
				children[#children + 1] = tooltip(_("Click a road or track next to the node to remove"), true, false)
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

	params.setActionFn(actionFn, "NtoolsRemoveNodeAction")
	return padMod.anchor(pad)
end)

return {
	init = init,
	RemoveNodeActionRecipe = RemoveNodeActionRecipe,
	-- (for Connect: a node it added for an end, merged away again once that end moves off it)
	makeRemoveNodeProposal = makeRemoveNodeProposal,
}
