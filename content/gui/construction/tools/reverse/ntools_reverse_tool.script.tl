-- Network Tools: Reverse (modelled on Network Multitool's InvertSegment for Cities: Skylines 1).
-- Click road or track segments to select them (click again to drop one), then Build to flip their
-- direction: one-way roads then run the other way. Shape, lanes and type stay the same.
--
-- TF3 has no command to flip a segment, so each one is removed and re-added with its ends swapped.
-- Loaded by the connect tool, which runs it inside the Network Tools panel and hands over the
-- shared helpers and state once through init() (same pattern as the Parallel tool).

local builtin = ug_require "::/gui/main/builtin.lua" as Builtin
local engine_react_util = ug_require "::/gui/main/engine_react_util.tl" as EngineReactUtil
local react = ug_require "::/gui/main/react.lua" as React

local record NetUtil
	isProtectedNode : function(node : Engine.Entity) : boolean
	whyNotReplaceable : function(edge : Engine.Entity) : string
	configNodesFor : function(removedEdges : {Engine.Entity}, extraNodes? : {Engine.Entity}) : {Engine.Entity}
	rebuildCrossings : function(proposal : SimpleProposal, removedEdges : {Engine.Entity}, skipNodes? : {Engine.Entity}) : integer
end
local net_util = require "network_tools_1::/gui/construction/tools/shared/ntools_net_util.script.tl" as NetUtil

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

do ((require "network_tools_1::/gui/construction/tools/shared/ntools_debug.script.tl" as {string : any}).log as function(string))("[network_tools] reverse tool script loaded (v3: picker off while building)") end

local record UiState
	canBuild : boolean
end

-- What the connect tool shares with this one (see init()).
local record Host
	getEdge : function(Engine.Entity) : Engine.Component.BaseEdge
	isEdge : function(Engine.Entity) : boolean
	tooltip : function(message : string, good : boolean, bad : boolean, cost? : integer) : TreeNodeId
	anarchy : function() : boolean
	ui : UiState
	toolbarEvents : {string}
end

local g_host : Host = nil
local getEdge : function(Engine.Entity) : Engine.Component.BaseEdge
local isEdge : function(Engine.Entity) : boolean
local tooltip : function(message : string, good : boolean, bad : boolean, cost? : integer) : TreeNodeId

local function init(host : Host)
	g_host = host
	getEdge, isEdge, tooltip = host.getEdge, host.isEdge, host.tooltip
end

local function v3(x : number, y : number, z : number) : Vec3f
	return api.type.Vec3f.new(x, y, z)
end

-- One proposal flipping every selected segment: removed, and re-added between the same nodes
-- the other way round (node0 <-> node1, positions swapped, tangents swapped and negated). Street
-- priority settings belong to an end, so they swap too. Returns nil and a reason if one can't be done.
local function makeReverseProposal(edges : {Engine.Entity}) : SimpleProposal, string
	if #edges == 0 then return nil, nil end
	local toAdd : {Proposal.SegmentAndEntity} = {}
	for i, edge in ipairs(edges) do
		local why = net_util.whyNotReplaceable(edge)
		if why then return nil, why end
		local e = getEdge(edge)
		local seg = api.type.SegmentAndEntity.new()
		seg.entity = -i
		seg.comp.node0, seg.comp.node1 = e.node1, e.node0
		seg.comp.position0 = v3(e.position1.x, e.position1.y, e.position1.z)
		seg.comp.position1 = v3(e.position0.x, e.position0.y, e.position0.z)
		seg.comp.tangent0 = v3(-e.tangent1.x, -e.tangent1.y, -e.tangent1.z)
		seg.comp.tangent1 = v3(-e.tangent0.x, -e.tangent0.y, -e.tangent0.z)
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
			if street then
				pcall(function()
					street.precedenceNode0, street.precedenceNode1 = street.precedenceNode1, street.precedenceNode0
				end)
				seg.streetEdge = street
			end
		end
		toAdd[#toAdd + 1] = seg
	end
	local proposal = api.type.SimpleProposal.new()
	proposal.streetProposal.edgesToAdd = toAdd
	proposal.streetProposal.edgesToRemove = edges
	-- the end nodes' lane connections name the removed segments: let the engine rebuild them
	local cfgNodes = net_util.configNodesFor(edges)
	if #cfgNodes > 0 then
		proposal.streetProposal.nodeConfigsToRemove = cfgNodes
	end
	-- an end at a level crossing: the engine re-creates the crossing
	net_util.rebuildCrossings(proposal, edges)
	return proposal, nil
end

local ReverseActionRecipe = react.RegisterRecipe("NtoolsReverseAction", function(params : ConstructionCustomActionParams<any>) : TreeNodeId
	react.onUnmount(preview.clear)   -- its speed / incline tags leave with the tool
	local selState : ReactStateT<{Engine.Entity}> = react.useState({})
	local costState : ReactStateT<integer> = react.useState(0)
	local errorState : ReactStateT<string> = react.useState("")
	local aliveRef : ReactRefT<boolean> = react.useRef(true)
	-- true from Build until the command's callback: the segments are being replaced, and touching
	-- one that is half-built (hover filter, selection check) is an engine assertion, not a Lua error
	local busyState : ReactStateT<boolean> = react.useState(false)
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
	-- drop segments that no longer exist (built over, bulldozed) - not while our own build runs
	local sel : {Engine.Entity} = {}
	if not busy then
		for _, e in ipairs(selState:old() or {}) do
			if api.engine.entityExists(e) and getEdge(e) then sel[#sel + 1] = e end
		end
	end
	local anarchy = anarchyUi:old() == true

	local proposal, why : SimpleProposal, string = nil, nil
	if not busy then
		proposal, why = makeReverseProposal(sel)
	end
	local blocked = errorState:old() ~= "" and not anarchy
	g_host.ui.canBuild = proposal ~= nil and not blocked

	local function clear()
		if aliveRef:hasExpired() then return end
		selState:set({})
		costState:set(0)
		errorState:set("")
	end

	local function build()
		if not proposal or blocked or busy then return end
		local context = api.type.Context.new()
		context.player = api.engine.util.getPlayer()
		local cmd = api.cmd.makeWorldBuildProposalCmd(proposal, context, anarchy, true)
		-- the selected segments are about to be replaced: forget them now, and keep the picker off
		-- until the engine reports back
		selState:set({})
		busyState:set(true)
		-- (the shared send every tool's build goes through)
		((require "network_tools_1::/gui/construction/tools/shared/ntools_options.script.tl" as {string : any}).send as function(Command<WorldBuildProposalCommandData>, function(WorldBuildProposalCommandData, boolean)))(cmd, function(__ : WorldBuildProposalCommandData, success : boolean)
			if not success then
				do ((require "network_tools_1::/gui/construction/tools/shared/ntools_debug.script.tl" as {string : any}).log as function(string))("[network_tools] Reverse: build failed") end
			end
			if aliveRef:hasExpired() then return end
			busyState:set(false)
			clear()
		end)
	end

	local function onSelect(entity : Engine.Entity) : boolean
		if not getEdge(entity) then return false end
		costState:set(0)
		errorState:set("")
		local ns : {Engine.Entity} = {}
		local removed = false
		for _, e in ipairs(sel) do
			if e == entity then removed = true else ns[#ns + 1] = e end
		end
		if not removed then ns[#ns + 1] = entity end
		selState:set(ns)
		return true
	end

	handlersRef:set({
		ntoolsResetShape = clear,
		ntoolsBuild = build,
	})
	padMod.actions(pad, _("Pick segment"), function() params.abort() end, _("Leave the tool"))

	local actionFn = function() : TreeNodeId
		padMod.trackLayer(pad)
		local crosshair, circle = padMod.crosshair(pad)
		local children : {TreeNodeId} = {}
		if busy then
			children[#children + 1] = tooltip(_("Reversing..."), true, false)
			return builtin.ActionDescriptor{
				tool = "construction-menu-perks",
				onBack = function() params.abort() end,
				crosshair = crosshair,
				terrainCirclePolicy = circle,
				children = children,
			}
		end
		children[#children + 1] = builtin.Selector(padMod.selector(pad, {
			onSelect = function(entity : Engine.Entity, __ : {integer}, __ : Gui.SelectionDetails) : boolean
				return onSelect(entity)
			end,
			filter = isEdge,
		}) as Builtin.SelectorParam)
		if proposal then
			local id = "ntools_reverse"
			for _, e in ipairs(sel) do id = id .. "," .. tostring(e) end
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

		local info = _("Segments") .. ": " .. tostring(#sel)
		if #sel == 0 then
			children[#children + 1] = tooltip(_("Click road or track segments to reverse"), false, false)
		elseif why then
			children[#children + 1] = tooltip(why .. "\n" .. _("Click it again to drop it") .. "\n" .. info, false, true)
		elseif blocked then
			children[#children + 1] = tooltip(errorState:old() .. "\n" .. info, false, true, costState:old())
		else
			children[#children + 1] = tooltip(_("Click more segments to add, a selected one to drop it. Press Build to reverse") .. "\n" .. info, true, false, costState:old())
		end
		-- Anarchy preview strips (this tool draws no other overlay)
		local lo = preview.leftover()
		if lo then children[#children + 1] = lo end
		-- speed / gradient tags on the new segments
		local tags = preview.tags()
		if tags then children[#children + 1] = tags end

		-- underground view (panel option, all tools)
		local under = ((require "network_tools_1::/gui/construction/tools/shared/ntools_options.script.tl" as {string : any}).layerNode as function() : TreeNodeId)()
		if under then children[#children + 1] = under end
		return builtin.ActionDescriptor{
			tool = "construction-menu-perks",
			onBack = function() params.abort() end,
			highlightedEntities = sel,
			crosshair = crosshair,
			terrainCirclePolicy = circle,
			children = children,
		}
	end

	params.setActionFn(actionFn, "NtoolsReverseAction")
	return padMod.anchor(pad)
end)

return {
	init = init,
	ReverseActionRecipe = ReverseActionRecipe,
}
