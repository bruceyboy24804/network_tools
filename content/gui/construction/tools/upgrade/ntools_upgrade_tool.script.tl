-- Network Tools: Track upgrade (Rail tab). Pick a stretch of track (click a segment, then one further
-- along: the path between is added, as in the Signals tool), choose a track type and / or catenary,
-- Build: each segment is removed and re-added with the new type, same shape and ends. Its signals
-- are placed again on the new segment (same place, facing, one-way and model), as the Signals tool
-- re-adds track. Segments that belong to a station, or carry a waypoint / stop, are left out.
--
-- The new type comes from the game's own templates: the chosen track type, then its electrified
-- (catenaryAdd) or plain (catenaryRemove) twin when catenary is to be added or removed.
-- Loaded by the connect tool, which hands over the shared helpers through init() (as Reverse).

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
local engine_react_util = ug_require "::/gui/main/engine_react_util.tl" as EngineReactUtil
local react = ug_require "::/gui/main/react.lua" as React

local record NetUtil
	configNodesFor : function(removedEdges : {Engine.Entity}, extraNodes? : {Engine.Entity}) : {Engine.Entity}
	rebuildCrossings : function(proposal : SimpleProposal, removedEdges : {Engine.Entity}, skipNodes? : {Engine.Entity}) : integer
	carryReplaced : function(proposal : SimpleProposal) : integer
end
local net_util = require "network_tools_1::/gui/construction/tools/shared/ntools_net_util.script.tl" as NetUtil

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
	click : function(chain : {ChainLink}, entity : Engine.Entity, avoid? : {Engine.Entity : boolean}, opts? : {string : any}) : {ChainLink}
	lastNote : function() : string
end
local chain_util = require "network_tools_1::/gui/construction/tools/shared/ntools_chain.script.tl" as Chain

-- the signals on a segment, to place again on the re-added one (shared/ntools_edge_signals)
local record SignalCopy
	entity : Engine.Entity
	param : number
	model : string
	left : boolean
	oneWay : boolean
end
local readSignals = (require "network_tools_1::/gui/construction/tools/shared/ntools_edge_signals.script.tl" as {string : any}).readSignals
	as function(e : Engine.Entity, oe : Engine.Component.BaseEdge) : {SignalCopy}, string

local dbg = (require "network_tools_1::/gui/construction/tools/shared/ntools_debug.script.tl" as {string : any}).log as function(string)
local shared = require "network_tools_1::/gui/construction/tools/shared/ntools_options.script.tl" as {string : any}

dbg("[network_tools] track upgrade tool script loaded (v1)")

local record UiState
	canBuild : boolean
end

local record Host
	getEdge : function(Engine.Entity) : Engine.Component.BaseEdge
	isEdge : function(Engine.Entity) : boolean
	tooltip : function(message : string, good : boolean, bad : boolean, cost? : integer) : TreeNodeId
	anarchy : function() : boolean
	ui : UiState
	toolbarEvents : {string}
end

local g_host : Host = nil
local function init(host : any) g_host = host as Host end

-- options (the panel edits them; saved with the game): the track type to change to (a street
-- template id, 0 = keep each segment's own) and catenary (1 keep, 2 electrify, 3 remove)
local record Options
	trackType : integer
	catenary : integer
end
local opts : Options = { trackType = 0, catenary = 1 }

local function templateOf(name : string) : StreetTemplate
	if not name or name == "" then return nil end
	local ok, t = pcall(function() : StreetTemplate
		local id = api.res.streetTemplateRep.find(name)
		if id == nil or id < 0 then return nil end
		return api.res.streetTemplateRep.get(id)
	end)
	return ok and t or nil
end

local function templateName(id : integer) : string
	if not id or id <= 0 then return nil end
	local ok, n = pcall(function() : string return tostring(api.res.streetTemplateRep.getName(id)) end)
	return ok and n or nil
end

-- the template a segment becomes (its own when nothing changes), or nil and why not
local function targetOf(e : Engine.Component.BaseEdge) : string, string
	local name = tostring(e.roadTemplate)
	if opts.trackType and opts.trackType > 0 then
		name = templateName(opts.trackType)
		if not name then return nil, _("The chosen track type isn't available") end
	end
	local t = templateOf(name)
	if not t then return nil, _("Unknown track type") end
	if opts.catenary == 2 and t.catenaryAdd and t.catenaryAdd ~= "" then name = t.catenaryAdd
	elseif opts.catenary == 3 and t.catenaryRemove and t.catenaryRemove ~= "" then name = t.catenaryRemove end
	return name, nil
end

local function isStationEdge(edge : Engine.Entity) : boolean
	local ok, c = pcall(function() : Engine.Entity
		return api.engine.system.streetConnectorSystem.getConstructionEntityForEdge(edge)
	end)
	return ok and c ~= nil and c >= 0
end

-- One proposal re-adding every segment of the stretch that changes. Returns it (nil: nothing to do),
-- why not, how many change and how many are left out.
local function makeUpgradeProposal(chain : {ChainLink}) : SimpleProposal, string, integer, integer
	local edgesToAdd : {Proposal.SegmentAndEntity} = {}
	local edgesToRemove : {Engine.Entity} = {}
	local objects : {SimpleStreetProposal.EdgeObject} = {}
	local objectsRemoved : {Engine.Entity} = {}
	-- signals on re-added segments get placeholder ids far below every other new entity (as Signals)
	local nextPlaceholder = -400000000
	local skipped = 0
	for k, l in ipairs(chain) do
		local e = g_host.getEdge(l.edge)
		if e then
			local name, why = targetOf(e)
			if why then return nil, why, 0, 0 end
			local okS, sigs, sigWhy = pcall(readSignals, l.edge, e)
			if not okS then sigs, sigWhy = nil, tostring(sigs) end
			if isStationEdge(l.edge) or not sigs then
				-- (station track, or a waypoint / stop on it: it can't be re-added)
				skipped = skipped + 1
			elseif name ~= tostring(e.roadTemplate) then
				local t = templateOf(name)
				local seg = api.type.SegmentAndEntity.new()
				seg.entity = -k
				seg.comp = e
				seg.type = 1
				seg.comp.roadTemplate = name
				if t then
					seg.comp.laneConfigs = t.laneConfigs
					seg.comp.roadStyle = t.streetStyle
				end
				pcall(function()
					local po = api.engine.getComponent(l.edge, api.type.ComponentType.PLAYER_OWNED)
					if po then seg.playerOwned = po end
				end)
				local refs : {{Engine.Entity, EdgeObjectType}} = {}
				for __, sc in ipairs(sigs) do
					local o = api.type.SimpleStreetProposal.EdgeObject.new()
					o.edgeEntity = -k
					o.param = sc.param
					o.oneWay = sc.oneWay
					o.left = sc.left
					o.model = sc.model
					o.playerEntity = api.engine.util.getPlayer()
					objects[#objects + 1] = o
					refs[#refs + 1] = { nextPlaceholder, api.type["enum"].EdgeObjectType.SIGNAL }
					nextPlaceholder = nextPlaceholder - 1
					objectsRemoved[#objectsRemoved + 1] = sc.entity
				end
				seg.comp.objects = refs
				edgesToAdd[#edgesToAdd + 1] = seg
				edgesToRemove[#edgesToRemove + 1] = l.edge
			end
			if sigWhy then dbg("[network_tools] upgrade: segment " .. tostring(l.edge) .. " " .. tostring(sigWhy)) end
		end
	end
	if #edgesToAdd == 0 then return nil, nil, 0, skipped end
	local proposal = api.type.SimpleProposal.new()
	proposal.streetProposal.edgesToAdd = edgesToAdd
	proposal.streetProposal.edgesToRemove = edgesToRemove
	if #objects > 0 then proposal.streetProposal.edgeObjectsToAdd = objects end
	if #objectsRemoved > 0 then proposal.streetProposal.edgeObjectsToRemove = objectsRemoved end
	-- the end nodes' lane connections name the re-added segments: the engine rebuilds them
	local cfg = net_util.configNodesFor(edgesToRemove)
	if #cfg > 0 then
		proposal.streetProposal.nodeConfigsToRemove = cfg
		-- and give them back on the re-added segments (a node left without a config crashes the game)
		net_util.carryReplaced(proposal)
	end
	-- a re-added segment at a level crossing: the engine re-creates the crossing (same type)
	net_util.rebuildCrossings(proposal, edgesToRemove)
	return proposal, nil, #edgesToAdd, skipped
end

local UpgradeActionRecipe = react.RegisterRecipe("NtoolsUpgradeAction", function(params : ConstructionCustomActionParams<any>) : TreeNodeId
	react.onUnmount(preview.clear)
	local chainState : ReactStateT<{ChainLink}> = react.useState({})
	local costState : ReactStateT<integer> = react.useState(0)
	local errorState : ReactStateT<string> = react.useState("")
	local noteState : ReactStateT<string> = react.useState("")
	local aliveRef : ReactRefT<boolean> = react.useRef(true)
	local busyState : ReactStateT<boolean> = react.useState(false)
	local anarchyUi = engine_react_util.useStepState(function() : boolean return g_host.anarchy() end)
	local optsUi = engine_react_util.useStepState(function() : string
		return tostring(opts.trackType) .. "/" .. tostring(opts.catenary)
	end)

	local handlersRef : ReactRefT<{string : function()}> = react.useRef({})
	for __, name in ipairs(g_host.toolbarEvents) do
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
		for __, l in ipairs(chainState:old() or {}) do
			if api.engine.entityExists(l.edge) and g_host.getEdge(l.edge) then chain[#chain + 1] = l end
		end
	end
	local anarchy = anarchyUi:old() == true
	local _o = optsUi:old()   -- (read so option changes re-render)

	local proposal : SimpleProposal = nil
	local why : string = nil
	local nChange, nSkipped = 0, 0
	if not busy and #chain > 0 then
		proposal, why, nChange, nSkipped = makeUpgradeProposal(chain)
	end
	local blocked = errorState:old() ~= "" and not anarchy
	g_host.ui.canBuild = proposal ~= nil and not blocked

	local function clear()
		if aliveRef:hasExpired() then return end
		chainState:set({})
		costState:set(0)
		errorState:set("")
		noteState:set("")
	end

	local function build()
		if not proposal or blocked or busy then return end
		local context = api.type.Context.new()
		context.player = api.engine.util.getPlayer()
		local cmd = api.cmd.makeWorldBuildProposalCmd(proposal, context, anarchy, true)
		chainState:set({})
		busyState:set(true)
		-- (the shared send every tool's build goes through; through a local - a statement starting
		-- with "(" can be read as a call of the line before)
		local send = shared.send as function(Command<WorldBuildProposalCommandData>, function(WorldBuildProposalCommandData, boolean))
		send(cmd, function(__ : WorldBuildProposalCommandData, success : boolean)
			if not success then dbg("[network_tools] Track upgrade: build failed") end
			if aliveRef:hasExpired() then return end
			busyState:set(false)
			clear()
		end)
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
			children[#children + 1] = g_host.tooltip(_("Upgrading..."), true, false)
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
				local e = g_host.getEdge(entity)
				if not e or e.roadType ~= api.type["enum"].RoadType.TRACK then return false end
				costState:set(0)
				errorState:set("")
				-- a segment further along: the straightest path to it (as Signals' default)
				chainState:set(chain_util.click(chain, entity, nil, { mode = 3 }))
				noteState:set(chain_util.lastNote())
				return true
			end,
			filter = g_host.isEdge,
		}) as Builtin.SelectorParam)
		if proposal then
			local id = "ntools_upgrade," .. tostring(opts.trackType) .. "," .. tostring(opts.catenary)
			for __, l in ipairs(chain) do id = id .. "," .. tostring(l.edge) end
			children[#children + 1] = preview.viewer{
				proposal = proposal,
				anarchy = anarchy,
				onData = function(proposalData : ProposalData)
					if aliveRef:hasExpired() then return end
					costState:set(proposalData.costs)
					local msg = ""
					for __, m in ipairs(proposalData.errorState.messages) do msg = msg .. m .. " " end
					errorState:set(msg)
				end,
				id = id,
			}
		end

		local info = _("Segments") .. ": " .. tostring(#chain) .. "   " .. _("To change") .. ": " .. tostring(nChange)
		if nSkipped > 0 then info = info .. "\n" .. string.format(_("%d left out (station track, or a waypoint / stop on it)"), nSkipped) end
		local note = noteState:old() or ""
		if note ~= "" then info = _(note) .. "\n" .. info end
		if #chain == 0 then
			children[#children + 1] = g_host.tooltip(_("Click a track segment, then one further along: the stretch between is picked"), false, false)
		elseif why then
			children[#children + 1] = g_host.tooltip(why .. "\n" .. info, false, true)
		elseif not proposal then
			children[#children + 1] = g_host.tooltip(_("Nothing to change: the stretch already has this type") .. "\n" .. info, false, false)
		elseif blocked then
			children[#children + 1] = g_host.tooltip(errorState:old() .. "\n" .. info, false, true, costState:old())
		else
			children[#children + 1] = g_host.tooltip(_("Press Build to upgrade the stretch") .. "\n" .. info, true, false, costState:old())
		end
		local lo = preview.leftover()
		if lo then children[#children + 1] = lo end
		local tags = preview.tags()
		if tags then children[#children + 1] = tags end
		local under = (shared.layerNode as function() : TreeNodeId)()
		if under then children[#children + 1] = under end
		local hl : {Engine.Entity} = {}
		for __, l in ipairs(chain) do hl[#hl + 1] = l.edge end
		return builtin.ActionDescriptor{
			tool = "construction-menu-perks",
			onBack = function() params.abort() end,
			highlightedEntities = hl,
			crosshair = crosshair,
			terrainCirclePolicy = circle,
			children = children,
		}
	end

	params.setActionFn(actionFn, "NtoolsUpgradeAction")
	return padMod.anchor(pad)
end)

return {
	init = init,
	opts = opts,
	UpgradeActionRecipe = UpgradeActionRecipe,
}
