-- Network Tools: Crossover (Rail tab). Click a track where the crossover starts, then the track
-- beside it: a pair of switches joined by a smooth S-curve is built between them (Single), or two
-- crossing diagonals meeting at a diamond in the middle (Scissors). It runs ahead of the first click
-- (along that track's direction) or behind it; its length is set in the panel.
--
-- Built with shared/ntools_trackbuild: both tracks are split where the crossover meets them, the new
-- segments copy the first track's type. The tracks must run side by side (3 - 30 m apart), and the
-- segments it splits must be long enough and carry no signals.

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
	edgePiece : function(e : Engine.Component.BaseEdge) : Piece
	length : function(pc : Piece) : number
	closestT : function(pc : Piece, x : number, y : number) : number, number
	point : function(pc : Piece, t : number) : P3
	tangent : function(pc : Piece, t : number) : P3
end
local geom = require "network_tools_1::/gui/construction/tools/shared/ntools_geom.script.tl" as Geom

local record Cut
	node : Engine.Entity
	pos : P3
	dir : P3
end
local record Builder
	splitAt : function(edge : Engine.Entity, ts : {number}) : {Cut}
	node : function(pos : P3) : Engine.Entity
	segment : function(n0 : Engine.Entity, p0 : P3, t0 : P3, n1 : Engine.Entity, p1 : P3, t1 : P3, ref : Engine.Component.BaseEdge)
	proposal : function() : SimpleProposal
	why : string
end
local record TrackBuild
	new : function() : Builder
	unit : function(v : P3) : P3
	diagnose : function(key : string) : string   -- the refused piece of the previewed proposal
end
local trackbuild = require "network_tools_1::/gui/construction/tools/shared/ntools_trackbuild.script.tl" as TrackBuild

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

local record Canvas
	circle : function(cx : number, cy : number, z : number, r : number, color : Vec4f, width : number)
	node : function() : TreeNodeId
end
local record Handles
	canvas : function() : Canvas
	cursor : function() : number, number
	colors : {string : Vec4f}
end
local handles = require "network_tools_1::/gui/construction/tools/shared/ntools_handles.script.tl" as Handles

local dbg = (require "network_tools_1::/gui/construction/tools/shared/ntools_debug.script.tl" as {string : any}).log as function(string)
local shared = require "network_tools_1::/gui/construction/tools/shared/ntools_options.script.tl" as {string : any}

dbg("[network_tools] crossover tool script loaded (v1)")

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

-- options (the panel; saved with the game): 1 single / 2 scissors, ahead of the first click (1) or
-- behind it (2), length in metres; with more than two tracks: 1 staggered (each crossover starts
-- where the one before ends) / 2 side by side (all at the same place)
local record Options
	kind : integer
	dir : integer
	length : number
	arrange : integer
end
local opts : Options = { kind = 1, dir = 1, length = 60, arrange = 1 }

local record Pick
	edge : Engine.Entity
	t : number
end

local function add(a : P3, b : P3) : P3 return { x = a.x + b.x, y = a.y + b.y, z = a.z + b.z } end
local function sub(a : P3, b : P3) : P3 return { x = a.x - b.x, y = a.y - b.y, z = a.z - b.z } end
local function scale(a : P3, s : number) : P3 return { x = a.x * s, y = a.y * s, z = a.z * s } end
local function dist2d(a : P3, b : P3) : number return math.sqrt((a.x - b.x) ^ 2 + (a.y - b.y) ^ 2) end
local function dot2d(a : P3, b : P3) : number return a.x * b.x + a.y * b.y end

-- a track taking part: its segment, piece, sideways offset from the first click (+ left of d)
local record Lane
	edge : Engine.Entity
	e : Engine.Component.BaseEdge
	pc : Piece
	off : number
end
-- a split wanted on a track: at `along` metres (along d) from the first click
local record Want
	along : number
	key : string
end
-- the places one segment is split at
local record At
	t : number
	keys : {string}
end
-- one crossover: from a track to the next one out, starting `s` metres along
local record PairPlan
	from : Lane
	to : Lane
	s : number
	key : string
end

-- The crossovers between the picked tracks (each neighbouring pair, sorted side to side): the
-- proposal, or nil and why not
local function plan(picks : {Pick}) : SimpleProposal, string
	local pa = picks[1]
	local eA = g_host.getEdge(pa.edge)
	if not eA then return nil, _("A segment is gone") end
	local pcA = geom.edgePiece(eA)
	local L = math.max(10, opts.length or 60)
	local pA = geom.point(pcA, pa.t)
	local dA = trackbuild.unit(geom.tangent(pcA, pa.t))
	if opts.dir == 2 then dA = scale(dA, -1) end
	local fl = trackbuild.unit({ x = dA.x, y = dA.y, z = 0 })

	-- the tracks, sorted side to side
	local lanes : {Lane} = { { edge = pa.edge, e = eA, pc = pcA, off = 0 } }
	for i = 2, #picks do
		local p = picks[i]
		if p.edge == pa.edge then return nil, _("Click the tracks beside it - not the same one") end
		local e = g_host.getEdge(p.edge)
		if not e then return nil, _("A segment is gone") end
		local pc = geom.edgePiece(e)
		local q = geom.point(pc, geom.closestT(pc, pA.x, pA.y))
		lanes[#lanes + 1] = { edge = p.edge, e = e, pc = pc, off = -fl.y * (q.x - pA.x) + fl.x * (q.y - pA.y) }
	end
	table.sort(lanes, function(x : Lane, y : Lane) : boolean return x.off < y.off end)
	for i = 2, #lanes do
		local gap = lanes[i].off - lanes[i - 1].off
		if gap < 3 or gap > 30 then return nil, _("Neighbouring tracks should run side by side, 3 to 30 m apart") end
	end

	-- where each pair's crossover goes: from the track nearer the first click to the next one out
	-- (staggered: each starts where the one before ends; side by side: all at the start; scissors
	-- are always staggered - two diamonds can't share a track's switches)
	local staggered = opts.arrange ~= 2 or opts.kind == 2
	local first = 1
	for i, ln in ipairs(lanes) do if ln.edge == pa.edge then first = i end end
	local wants : {Engine.Entity : {Want}} = {}
	local function want(ln : Lane, along : number, key : string)
		wants[ln.edge] = wants[ln.edge] or {}
		local w = wants[ln.edge]
		w[#w + 1] = { along = along, key = key }
	end
	local pairs_ : {PairPlan} = {}
	local function addPair(from : Lane, to : Lane, n : integer)
		local s = staggered and (n - 1) * (L + 5) or 0
		local key = "x" .. tostring(#pairs_ + 1)
		pairs_[#pairs_ + 1] = { from = from, to = to, s = s, key = key }
		want(from, s, key .. "a0")
		want(to, s + L, key .. "b1")
		if opts.kind == 2 then
			want(from, s + L, key .. "a1")
			want(to, s, key .. "b0")
		end
	end
	-- outwards from the first click on each side
	for i = first + 1, #lanes do addPair(lanes[i - 1], lanes[i], i - first) end
	for i = first - 1, 1, -1 do addPair(lanes[i + 1], lanes[i], first - i) end

	-- each place wanted: on whichever segment of that track is there (a staggered run carries on
	-- past the clicked segment); then one split per segment, at all its places
	local nx, ny = -fl.y, fl.x
	local function segmentAt(ln : Lane, q : P3) : Engine.Entity, Piece, number
		-- the clicked segment if it reaches; else the track segment under the place, near its line
		local t, dd = geom.closestT(ln.pc, q.x, q.y)
		if dd < 1.5 then return ln.edge, ln.pc, t end
		local ok, found = pcall(function() : {Engine.Entity}
			return api.engine.util.octree.findEntitiesInCircle(api.type.Vec2f.new(q.x, q.y), 20, api.type.ComponentType.BASE_EDGE)
		end)
		local best : Engine.Entity = nil
		local bestPc : Piece = nil
		local bestT, bestD = 0.0, 1.5
		for __, ex in ipairs(ok and found or {}) do
			local oe = g_host.getEdge(ex)
			if oe and oe.roadType == api.type["enum"].RoadType.TRACK then
				local pc = geom.edgePiece(oe)
				local tt, d2 = geom.closestT(pc, q.x, q.y)
				if d2 < bestD then best, bestPc, bestT, bestD = ex, pc, tt, d2 end
			end
		end
		return best, bestPc, bestT
	end
	local perEdge : {Engine.Entity : {At}} = {}
	local pcOf : {Engine.Entity : Piece} = {}
	local edgeOrder : {Engine.Entity} = {}
	for __, ln in ipairs(lanes) do
		for __, w in ipairs(wants[ln.edge] or {}) do
			-- (on the track's line: beside the first click's line by its offset)
			local q = add(pA, scale(fl, w.along))
			q = { x = q.x + nx * ln.off, y = q.y + ny * ln.off, z = q.z }
			local ex, pc, t = segmentAt(ln, q)
			if not ex then
				return nil, _("A track ends (or bends away) before a crossover's switch - click further from its end, or make the crossovers shorter")
			end
			if not perEdge[ex] then perEdge[ex] = {}; pcOf[ex] = pc; edgeOrder[#edgeOrder + 1] = ex end
			local list = perEdge[ex]
			local at : At = nil
			for __, a2 in ipairs(list) do if math.abs(a2.t - t) < 1e-4 then at = a2 end end
			if not at then at = { t = t, keys = {} }; list[#list + 1] = at end
			at.keys[#at.keys + 1] = w.key
		end
	end
	local b = trackbuild.new()
	local cutOf : {string : Cut} = {}
	local dirOf : {string : P3} = {}
	for __, ex in ipairs(edgeOrder) do
		local list = perEdge[ex]
		local ts : {number} = {}
		for i, a2 in ipairs(list) do ts[i] = a2.t end
		local cuts = b.splitAt(ex, ts)
		if not cuts then return nil, b.why end
		for j, c in ipairs(cuts) do
			-- (the track's direction there, the same way as the first click's)
			local dd2 = trackbuild.unit(geom.tangent(pcOf[ex], ts[j]))
			if dot2d(dd2, dA) < 0 then dd2 = scale(dd2, -1) end
			for __, k in ipairs(list[j].keys) do cutOf[k], dirOf[k] = c, dd2 end
		end
	end

	for __, pp in ipairs(pairs_) do
		local A0, B1 = cutOf[pp.key .. "a0"], cutOf[pp.key .. "b1"]
		local dA0, dB1 = dirOf[pp.key .. "a0"], dirOf[pp.key .. "b1"]
		if opts.kind ~= 2 then
			-- single: one S-curve from one track to the next one out
			local k = dist2d(A0.pos, B1.pos)
			b.segment(A0.node, A0.pos, scale(dA0, k), B1.node, B1.pos, scale(dB1, k), pp.from.e)
		else
			-- scissors: two diagonals crossing at a node in the middle (a diamond)
			local A1, B0 = cutOf[pp.key .. "a1"], cutOf[pp.key .. "b0"]
			local dA1, dB0 = dirOf[pp.key .. "a1"], dirOf[pp.key .. "b0"]
			local c : P3 = scale(add(add(A0.pos, A1.pos), add(B0.pos, B1.pos)), 0.25)
			local mid = b.node(c)
			local d1 = trackbuild.unit(sub(B1.pos, A0.pos))
			local d2 = trackbuild.unit(sub(A1.pos, B0.pos))
			local h1 = dist2d(A0.pos, B1.pos) / 2
			local h2 = dist2d(B0.pos, A1.pos) / 2
			b.segment(A0.node, A0.pos, scale(dA0, h1), mid, c, scale(d1, h1), pp.from.e)
			b.segment(mid, c, scale(d1, h1), B1.node, B1.pos, scale(dB1, h1), pp.from.e)
			b.segment(B0.node, B0.pos, scale(dB0, h2), mid, c, scale(d2, h2), pp.from.e)
			b.segment(mid, c, scale(d2, h2), A1.node, A1.pos, scale(dA1, h2), pp.from.e)
		end
	end
	local p = b.proposal()
	return p, b.why
end

local CrossoverActionRecipe = react.RegisterRecipe("NtoolsCrossoverAction", function(params : ConstructionCustomActionParams<any>) : TreeNodeId
	react.onUnmount(preview.clear)
	local picksState : ReactStateT<{Pick}> = react.useState({})
	local costState : ReactStateT<integer> = react.useState(0)
	local errorState : ReactStateT<string> = react.useState("")
	local aliveRef : ReactRefT<boolean> = react.useRef(true)
	local busyState : ReactStateT<boolean> = react.useState(false)
	local anarchyUi = engine_react_util.useStepState(function() : boolean return g_host.anarchy() end)
	local optsUi = engine_react_util.useStepState(function() : string
		return tostring(opts.kind) .. "/" .. tostring(opts.dir) .. "/" .. tostring(opts.length) .. "/" .. tostring(opts.arrange)
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
	local picks : {Pick} = {}
	if not busy then
		for __, p in ipairs(picksState:old() or {}) do
			if api.engine.entityExists(p.edge) and g_host.getEdge(p.edge) then picks[#picks + 1] = p end
		end
	end
	local anarchy = anarchyUi:old() == true
	local _o = optsUi:old()

	local proposal : SimpleProposal = nil
	local why : string = nil
	if not busy and #picks >= 2 then
		local ok, p, w = pcall(plan, picks)
		if ok then proposal, why = p, w else why = _("Can't be planned here"); dbg("[network_tools] crossover: " .. tostring(p)) end
	end
	local blocked = errorState:old() ~= "" and not anarchy
	g_host.ui.canBuild = proposal ~= nil and not blocked

	local function clear()
		if aliveRef:hasExpired() then return end
		picksState:set({})
		costState:set(0)
		errorState:set("")
	end

	local function build()
		if not proposal or blocked or busy then return end
		local context = api.type.Context.new()
		context.player = api.engine.util.getPlayer()
		local cmd = api.cmd.makeWorldBuildProposalCmd(proposal, context, anarchy, true)
		picksState:set({})
		busyState:set(true)
		local send = shared.send as function(Command<WorldBuildProposalCommandData>, function(WorldBuildProposalCommandData, boolean), boolean)
		send(cmd, function(__ : WorldBuildProposalCommandData, success : boolean)
			if not success then dbg("[network_tools] Crossover: build failed") end
			if aliveRef:hasExpired() then return end
			busyState:set(false)
			clear()
		end, true)
	end

	handlersRef:set({
		ntoolsResetShape = clear,
		ntoolsBuild = build,
	})

	padMod.actions(pad, _("Pick track"), function() params.abort() end, _("Leave the tool"))

	local actionFn = function() : TreeNodeId
		padMod.trackLayer(pad)
		local crosshair, circle = padMod.crosshair(pad)
		local children : {TreeNodeId} = {}
		if busy then
			children[#children + 1] = g_host.tooltip(_("Building..."), true, false)
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
				local x, y = handles.cursor()
				if not x then return true end
				local t = geom.closestT(geom.edgePiece(e), x, y)
				costState:set(0)
				errorState:set("")
				-- first click: where it starts; then each track beside (again: dropped); the first
				-- track again: start over from there
				if #picks == 0 or entity == picks[1].edge then
					picksState:set({ { edge = entity, t = t } })
				else
					local list : {Pick} = { picks[1] }
					local had = false
					for i = 2, #picks do
						if picks[i].edge == entity then had = true else list[#list + 1] = picks[i] end
					end
					if not had then list[#list + 1] = { edge = entity, t = t } end
					picksState:set(list)
				end
				return true
			end,
			filter = g_host.isEdge,
		}) as Builtin.SelectorParam)
		if proposal then
			local id = "ntools_crossover," .. _o
			for __, p in ipairs(picks) do id = id .. "," .. tostring(p.edge) .. string.format(":%.3f", p.t) end
			children[#children + 1] = preview.viewer{
				proposal = proposal,
				anarchy = anarchy,
				onData = function(proposalData : ProposalData)
					if aliveRef:hasExpired() then return end
					costState:set(proposalData.costs)
					local msg = ""
					for __, m in ipairs(proposalData.errorState.messages) do msg = msg .. m .. " " end
					-- (refused: which new piece - the game asked part by part)
					if msg ~= "" then
						local dg = trackbuild.diagnose(id)
						if dg then msg = msg .. "\n" .. dg end
					end
					errorState:set(msg)
				end,
				id = id,
			}
		end
		-- a dot where each click landed (start: the colour preset's start, the other track: its end)
		if #picks > 0 then
			local c = handles.canvas()
			for i, p in ipairs(picks) do
				local e = g_host.getEdge(p.edge)
				if e then
					local q = geom.point(geom.edgePiece(e), p.t)
					c.circle(q.x, q.y, q.z + 0.3, 0.55, i == 1 and (handles.colors.start or handles.colors.good) or (handles.colors.finish or handles.colors.drag), 1.1)
				end
			end
			local n = c.node()
			if n then children[#children + 1] = n end
		end

		if #picks == 0 then
			children[#children + 1] = g_host.tooltip(_("Click a track where the crossover starts"), false, false)
		elseif #picks == 1 then
			children[#children + 1] = g_host.tooltip(_("Now click the track beside it (and any more beyond)"), false, false)
		elseif why then
			children[#children + 1] = g_host.tooltip(why .. "\n" .. _("Click tracks to add or drop; the first track again starts over"), false, true)
		elseif blocked then
			children[#children + 1] = g_host.tooltip(errorState:old(), false, true, costState:old())
		else
			children[#children + 1] = g_host.tooltip(string.format(_("Tracks: %d. Click more to add or drop, Build to build"), #picks), true, false, costState:old())
		end
		local lo = preview.leftover()
		if lo then children[#children + 1] = lo end
		local tags = preview.tags()
		if tags then children[#children + 1] = tags end
		local under = (shared.layerNode as function() : TreeNodeId)()
		if under then children[#children + 1] = under end
		return builtin.ActionDescriptor{
			tool = "construction-menu-perks",
			onBack = function() params.abort() end,
			crosshair = crosshair,
			terrainCirclePolicy = circle,
			children = children,
		}
	end

	params.setActionFn(actionFn, "NtoolsCrossoverAction")
	return padMod.anchor(pad)
end)

return {
	init = init,
	opts = opts,
	CrossoverActionRecipe = CrossoverActionRecipe,
}
