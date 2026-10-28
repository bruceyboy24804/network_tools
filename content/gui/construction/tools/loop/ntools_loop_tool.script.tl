-- Network Tools: Passing loop (Rail tab). Pick a stretch of track (click a segment, then one further
-- along, as Track upgrade): a second track is built beside it, leaving the stretch at its first node and
-- joining it again at its last, so trains can pass. Side and track spacing are set in the panel.
--
-- Built with shared/ntools_trackbuild: new nodes beside each node inside the stretch, joined by
-- segments that follow the stretch's own shape; the loop copies the first segment's track type.
-- The stretch needs at least two segments (the first and last carry the turn-outs).

local builtin = ug_require "::/gui/main/builtin.lua" as Builtin
local engine_react_util = ug_require "::/gui/main/engine_react_util.tl" as EngineReactUtil
local react = ug_require "::/gui/main/react.lua" as React
local leave = require "network_tools_1::/gui/construction/tools/shared/ntools_leave.script.tl" as function(any)

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
	point : function(pc : Piece, t : number) : P3
	split : function(pc : Piece, ts : {number}) : {Piece}
end
local geom = require "network_tools_1::/gui/construction/tools/shared/ntools_geom.script.tl" as Geom

local record Cut
	node : Engine.Entity
	pos : P3
end
local record Builder
	node : function(pos : P3) : Engine.Entity
	segment : function(n0 : Engine.Entity, p0 : P3, t0 : P3, n1 : Engine.Entity, p1 : P3, t1 : P3, ref : Engine.Component.BaseEdge)
	touch : function(node : Engine.Entity)
	want : function(edge : Engine.Entity, t : number) : string
	cutAll : function() : boolean
	cut : function(key : string) : Cut
	proposal : function() : SimpleProposal
	why : string
end

-- the tracks alongside (shared/ntools_alongside)
local record Lane
	edge : Engine.Entity
	off : number
end
local record Spot
	edge : Engine.Entity
	t : number
	pos : P3
	dir : P3
	grade : number
	node : Engine.Entity
	nodePos : P3
end
local record Alongside
	alongside : function(edge : Engine.Entity, p : P3, d : P3) : {Lane}
	trackAt : function(q : P3, d : P3) : Spot
	crossU : function(pc : Piece, base : P3, nx : number, ny : number, w : number) : number
end
local along_util = require "network_tools_1::/gui/construction/tools/shared/ntools_alongside.script.tl" as Alongside

-- a switch of an Alongside loop: an existing node, or a deferred cut on a track alongside
local record Sw
	node : Engine.Entity
	key : string
	pos : P3
end
-- a turnout piece and where it crosses tracks
local record Turn
	pc : Piece
	us : {number}
	keys : {string}
end
-- one loop: its switches, its turnouts, its own nodes beside nodes a+1 .. z-1
local record LoopRun
	a : integer
	z : integer
	w : number
	off : number      -- the track it leaves (the extra loops go further out, away from it)
	s0 : Sw
	s1 : Sw
	entry : Turn
	exit : Turn
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

local record ChainLink
	edge : Engine.Entity
	fwd : boolean
end
local record Chain
	click : function(chain : {ChainLink}, entity : Engine.Entity, avoid? : {Engine.Entity : boolean}, opts? : {string : any}) : {ChainLink}
	lastNote : function() : string
end
local chain_util = require "network_tools_1::/gui/construction/tools/shared/ntools_chain.script.tl" as Chain

local dbg = (require "network_tools_1::/gui/construction/tools/shared/ntools_debug.script.tl" as {string : any}).log as function(string)
local shared = require "network_tools_1::/gui/construction/tools/shared/ntools_options.script.tl" as {string : any}
-- the game builders' Context (cleanupStreetGraph) for the build and a second verdict
local speedUtil = require "network_tools_1::/gui/construction/tools/shared/ntools_speed.script.tl" as {string : any}

dbg("[network_tools] passing loop tool script loaded (v1)")

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

-- options (the panel; saved with the game): side 1 left / 2 right / 3 both (of the picking
-- direction), the distance between the track centres in metres, loop tracks per side
local record Options
	side : integer
	spacing : number
	count : integer
	alongside : integer   -- tracks alongside: 0 off, 1 a loop beside the outermost track on each
	                      -- side, 2 one per track side by side (crossing the tracks between), 3 one
	                      -- beside the outermost, from the clicked track
end
local opts : Options = { side = 1, spacing = 5, count = 1, alongside = 0 }

local MIN_END = 25   -- metres: the first and last segments carry the turn-outs
local MIN_LOOP_R = 60 -- metres: tightest curve a loop track may have (inside a bend: the line's radius less its offset)

-- a curve's arc length from its ends and their (flat) directions
local function arcLen(p0 : P3, t0 : P3, p1 : P3, t1 : P3) : number, number
	local chord = math.sqrt((p1.x - p0.x) ^ 2 + (p1.y - p0.y) ^ 2)
	local l0 = math.sqrt(t0.x * t0.x + t0.y * t0.y)
	local l1 = math.sqrt(t1.x * t1.x + t1.y * t1.y)
	if l0 < 1e-9 or l1 < 1e-9 then return chord, 0 end
	local c = math.max(-1, math.min(1, (t0.x * t1.x + t0.y * t1.y) / (l0 * l1)))
	local th = math.acos(c)
	if th < 1e-3 then return chord, th end
	return chord * th / (2 * math.sin(th / 2)), th
end

-- the tangents of a piece beside the line's piece pc, from q0 to q1: pc's, scaled to the new
-- piece's own length (pc's on a bend's inside overshoot - a kink, "Too Much Curvature"); and why
-- it can't be built (inside a bend tighter than MIN_LOOP_R), or nil
local function besideTangents(pc : Piece, q0 : P3, q1 : P3) : P3, P3, string
	local L, th = arcLen(pc.p0, pc.t0, pc.p1, pc.t1)
	local Lq = arcLen(q0, pc.t0, q1, pc.t1)
	local why : string = nil
	if th > 1e-3 and Lq < L then
		local r = Lq / th
		if r < MIN_LOOP_R then
			why = string.format(_("The line bends too tightly here for a loop track on the inside (about %d m: under %d m) - fewer tracks, less spacing, or loop on the outside"),
				math.floor(r + 0.5), MIN_LOOP_R)
		end
	end
	local k = L > 1e-6 and Lq / L or 1
	return { x = pc.t0.x * k, y = pc.t0.y * k, z = pc.t0.z * k }, { x = pc.t1.x * k, y = pc.t1.y * k, z = pc.t1.z * k }, why
end

-- the link's piece in the stretch's direction, and its start / end nodes
local function oriented(l : ChainLink, e : Engine.Component.BaseEdge) : Piece, Engine.Entity, Engine.Entity
	local pc = geom.edgePiece(e)
	if l.fwd then return pc, e.node0, e.node1 end
	local function neg(v : P3) : P3 return { x = -v.x, y = -v.y, z = -v.z } end
	return { p0 = pc.p1, t0 = neg(pc.t1), p1 = pc.p0, t1 = neg(pc.t0) }, e.node1, e.node0
end

local function plan(chain : {ChainLink}) : SimpleProposal, string
	if #chain < 2 then return nil, _("Pick a longer stretch: at least two segments") end
	local pieces : {Piece} = {}
	local ends : {{Engine.Entity}} = {}
	local edges : {Engine.Component.BaseEdge} = {}
	for i, l in ipairs(chain) do
		local e = g_host.getEdge(l.edge)
		if not e then return nil, _("A segment is gone") end
		local pc, a, z = oriented(l, e)
		pieces[i], ends[i], edges[i] = pc, { a, z }, e
	end
	if geom.length(pieces[1]) < MIN_END or geom.length(pieces[#pieces]) < MIN_END then
		return nil, string.format(_("The first and last segments must be at least %d m long (the turn-outs)"), MIN_END)
	end
	local s = math.max(3.5, opts.spacing or 5)
	local count = math.max(1, math.min(6, math.floor(opts.count or 1)))
	local n = #pieces
	-- the stretch's nodes 0..n: the existing ones, where they are, the track's direction there
	local mainNode : {integer : Engine.Entity} = { [0] = ends[1][1] }
	local mainPos : {integer : P3} = { [0] = pieces[1].p0 }
	local mainDir : {integer : P3} = { [0] = pieces[1].t0 }
	for k = 1, n do mainNode[k], mainPos[k], mainDir[k] = ends[k][2], pieces[k].p1, pieces[k].t1 end
	-- beside a node of the stretch: `lat` metres across the track there (+ left)
	local function beside(k : integer, lat : number) : P3
		local p, t = mainPos[k], mainDir[k]
		local u = trackbuild.unit({ x = t.x, y = t.y, z = 0 })
		return { x = p.x - u.y * lat, y = p.y + u.x * lat, z = p.z }
	end
	-- Alongside: loops for the tracks running beside the stretch
	if (opts.alongside or 0) > 0 then
		local d0 = trackbuild.unit({ x = mainDir[0].x, y = mainDir[0].y, z = 0 })
		local lanes = along_util.alongside(chain[1].edge, mainPos[0], d0)
		if #lanes > 1 then
			local b = trackbuild.new()
			local runs : {LoopRun} = {}
			local function normalAt(k : integer) : number, number
				local u = trackbuild.unit({ x = mainDir[k].x, y = mainDir[k].y, z = 0 })
				return -u.y, u.x
			end
			-- a switch on the track `off` across, beside node k
			local function switchAt(k : integer, off : number) : Sw, string
				if off == 0 then return { node = mainNode[k], pos = mainPos[k] }, nil end
				local q = beside(k, off)
				local spot = along_util.trackAt(q, trackbuild.unit({ x = mainDir[k].x, y = mainDir[k].y, z = 0 }))
				if not spot then return nil, _("A track alongside ends (or bends away) where a switch must go - pick another stretch") end
				if spot.node then return { node = spot.node, pos = spot.nodePos }, nil end
				return { key = b.want(spot.edge, spot.t), pos = spot.pos }, nil
			end
			-- a turnout between node k0 (at offset o0) and k1 (at o1), following the stretch's piece
			-- k1, and where it crosses the tracks whose offsets lie between
			local function turnout(p0 : P3, p1 : P3, pieceIx : integer, baseK : integer, o0 : number, o1 : number) : Turn, string
				local src = pieces[pieceIx]
				local pc : Piece = { p0 = p0, t0 = src.t0, p1 = p1, t1 = src.t1 }
				local tn : Turn = { pc = pc, us = {}, keys = {} }
				local nx, ny = normalAt(baseK)
				local lo, hi = math.min(o0, o1), math.max(o0, o1)
				for __, ln in ipairs(lanes) do
					if ln.off > lo + 0.5 and ln.off < hi - 0.5 then
						local u = along_util.crossU(pc, mainPos[baseK], nx, ny, ln.off)
						if not u then return nil, _("Can't find where a loop crosses a track") end
						local x = geom.point(pc, u)
						local spot = along_util.trackAt(x, trackbuild.unit({ x = mainDir[baseK].x, y = mainDir[baseK].y, z = 0 }))
						if not spot then return nil, _("A loop crosses a track beyond its segment - pick another stretch") end
						tn.us[#tn.us + 1] = u
						tn.keys[#tn.keys + 1] = b.want(spot.edge, spot.t)
					end
				end
				return tn, nil
			end
			local function addRun(off : number, w : number, a : integer, z : integer) : string
				if z - a < 2 then return _("Pick a longer stretch for these loops (more segments)") end
				local s0, w0 = switchAt(a, off)
				if not s0 then return w0 end
				local s1, w1 = switchAt(z, off)
				if not s1 then return w1 end
				local entry, we = turnout(s0.pos, beside(a + 1, w), a + 1, a, off, w)
				if not entry then return we end
				local exit, wx = turnout(beside(z - 1, w), s1.pos, z, z, w, off)
				if not exit then return wx end
				-- (the extra loops need room: one node further in at each end per loop)
				if z - a < 2 * count then
					return string.format(_("Pick a longer stretch: %d loops need at least %d segments"), count, 2 * count + a + (n - z))
				end
				runs[#runs + 1] = { a = a, z = z, w = w, off = off, s0 = s0, s1 = s1, entry = entry, exit = exit }
				return nil
			end
			local mode = opts.alongside
			local sgSide = opts.side == 2 and -1 or 1
			local why : string = nil
			if mode == 1 then
				-- a loop beside each side's outermost track, outwards
				local lo, hi = lanes[1], lanes[#lanes]
				why = addRun(hi.off, hi.off + s, 0, n)
				if not why then why = addRun(lo.off, lo.off - s, 0, n) end
			elseif mode == 3 then
				local wmax = 0.0
				for __, ln in ipairs(lanes) do wmax = math.max(wmax, ln.off * sgSide) end
				why = addRun(0, (wmax + s) * sgSide, 0, n)
			else
				-- one per track side by side: the track nearest the loop side innermost; a track
				-- further across leaves a node earlier (its turnout before the inner ones' - crossing
				-- only the tracks, not their loops)
				local order : {Lane} = {}
				for __, ln in ipairs(lanes) do order[#order + 1] = ln end
				table.sort(order, function(x : Lane, y : Lane) : boolean return x.off * sgSide > y.off * sgSide end)
				local wmax = order[1].off * sgSide
				local m = #order
				-- (each track's `count` loops have their own band of places across)
				for r, ln in ipairs(order) do
					why = why or addRun(ln.off, (wmax + s * ((r - 1) * count + 1)) * sgSide, m - r, n - (m - r))
				end
			end
			if why then return nil, why end
			if not b.cutAll() then return nil, b.why end
			local function swNode(sw : Sw) : Engine.Entity
				if sw.node then b.touch(sw.node) return sw.node end
				return b.cut(sw.key).node
			end
			local function buildTurn(n0 : Engine.Entity, p0 : P3, tn : Turn, n1 : Engine.Entity, p1 : P3)
				local idx : {integer} = {}
				for k in ipairs(tn.us) do idx[k] = k end
				table.sort(idx, function(x : integer, y : integer) : boolean return tn.us[x] < tn.us[y] end)
				local sorted : {number} = {}
				for k, ix in ipairs(idx) do sorted[k] = tn.us[ix] end
				local parts = #sorted > 0 and geom.split(tn.pc, sorted) or { tn.pc }
				local pn, pp = n0, p0
				for k, part in ipairs(parts) do
					local nn, np : Engine.Entity, P3 = n1, p1
					if k <= #sorted then
						local c = b.cut(tn.keys[idx[k]])
						nn, np = c.node, c.pos
					end
					b.segment(pn, pp, part.t0, nn, np, part.t1, edges[1])
					pn, pp = nn, np
				end
			end
			for __, r in ipairs(runs) do
				local own : {integer : Engine.Entity} = {}
				local ownPos : {integer : P3} = {}
				for k = r.a + 1, r.z - 1 do
					ownPos[k] = beside(k, r.w)
					own[k] = b.node(ownPos[k])
				end
				buildTurn(swNode(r.s0), r.s0.pos, r.entry, own[r.a + 1], ownPos[r.a + 1])
				for k = r.a + 2, r.z - 1 do
					local t0, t1, whyT = besideTangents(pieces[k], ownPos[k - 1], ownPos[k])
					if whyT then return nil, whyT end
					b.segment(own[k - 1], ownPos[k - 1], t0, own[k], ownPos[k], t1, edges[1])
				end
				buildTurn(own[r.z - 1], ownPos[r.z - 1], r.exit, swNode(r.s1), r.s1.pos)
				-- the extra loops: each off the loop before, one node further in at each end, one
				-- spacing further out
				local outward = r.w >= r.off and 1 or -1
				local parentNode, parentPos = own, ownPos
				for kk = 2, count do
					local a2, z2 = r.a + kk - 1, r.z - kk + 1
					local w2 = r.w + outward * s * (kk - 1)
					local nn : {integer : Engine.Entity} = {}
					local np : {integer : P3} = {}
					for k = a2 + 1, z2 - 1 do
						np[k] = beside(k, w2)
						nn[k] = b.node(np[k])
					end
					nn[a2], np[a2] = parentNode[a2], parentPos[a2]
					nn[z2], np[z2] = parentNode[z2], parentPos[z2]
					for k = a2 + 1, z2 do
						local t0, t1, whyT = besideTangents(pieces[k], np[k - 1], np[k])
						if whyT then return nil, whyT end
						b.segment(nn[k - 1], np[k - 1], t0, nn[k], np[k], t1, edges[1])
					end
					parentNode, parentPos = nn, np
				end
			end
			return b.proposal(), b.why
		end
	end

	-- Loop track j (1 = next to the line) runs beside nodes j..n-j and leaves / rejoins the track
	-- inside it one node earlier / later: loop 1 the line itself, loop j loop j-1 (each a switch of
	-- its own). Both sides: the right-hand loops start one node further in, so no node gets more
	-- than one new switch.
	local sides : {integer} = opts.side == 3 and { 1, -1 } or { opts.side == 2 and -1 or 1 }
	local b = trackbuild.new()
	for __, sg in ipairs(sides) do
		local o = (#sides == 2 and sg == -1) and 1 or 0
		local parentNode : {integer : Engine.Entity} = mainNode
		local parentPos : {integer : P3} = mainPos
		for j = 1, count do
			local a, z = j - 1 + o, n - (j - 1) - o
			if z - a < 2 then
				return nil, string.format(_("Pick a longer stretch: %d loop tracks need at least %d segments"), count + o, 2 * (count + o))
			end
			local ownNode : {integer : Engine.Entity} = {}
			local ownPos : {integer : P3} = {}
			for k = a + 1, z - 1 do
				ownPos[k] = beside(k, s * j * sg)
				ownNode[k] = b.node(ownPos[k])
			end
			ownNode[a], ownPos[a] = parentNode[a], parentPos[a]
			ownNode[z], ownPos[z] = parentNode[z], parentPos[z]
			for k = a + 1, z do
				local t0, t1, whyT = besideTangents(pieces[k], ownPos[k - 1], ownPos[k])
				if whyT then return nil, whyT end
				b.segment(ownNode[k - 1], ownPos[k - 1], t0, ownNode[k], ownPos[k], t1, edges[1])
			end
			if j == 1 then
				b.touch(mainNode[a])
				b.touch(mainNode[z])
			end
			parentNode, parentPos = ownNode, ownPos
		end
	end
	return b.proposal(), b.why
end

local LoopActionRecipe = react.RegisterRecipe("NtoolsLoopAction", function(params : ConstructionCustomActionParams<any>) : TreeNodeId
	react.onUnmount(preview.clear)
	local chainState : ReactStateT<{ChainLink}> = react.useState({})
	local costState : ReactStateT<integer> = react.useState(0)
	local errorState : ReactStateT<string> = react.useState("")
	local noteState : ReactStateT<string> = react.useState("")
	local aliveRef : ReactRefT<boolean> = react.useRef(true)
	local busyState : ReactStateT<boolean> = react.useState(false)
	local anarchyUi = engine_react_util.useStepState(function() : boolean return g_host.anarchy() end)
	local optsUi = engine_react_util.useStepState(function() : string
		return tostring(opts.side) .. "/" .. tostring(opts.spacing) .. "/" .. tostring(opts.count) .. "/" .. tostring(opts.alongside)
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

	if not params.isActive then
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
	local _o = optsUi:old()

	local proposal : SimpleProposal = nil
	local why : string = nil
	if not busy and #chain > 0 then
		local ok, p, w = pcall(plan, chain)
		if ok then proposal, why = p, w else why = _("Can't be planned here"); dbg("[network_tools] loop: " .. tostring(p)) end
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
		local context = (speedUtil.buildContext as function() : Context)()
		local cmd = api.cmd.makeWorldBuildProposalCmd(proposal, context, anarchy, true)
		chainState:set({})
		busyState:set(true)
		local send = shared.send as function(Command<WorldBuildProposalCommandData>, function(WorldBuildProposalCommandData, boolean), boolean)
		send(cmd, function(__ : WorldBuildProposalCommandData, success : boolean)
			if not success then dbg("[network_tools] Passing loop: build failed") end
			if aliveRef:hasExpired() then return end
			busyState:set(false)
			clear()
		end, true)
	end

	handlersRef:set({
		ntoolsResetShape = clear,
		ntoolsBuild = build,
	})

	local actionFn = function() : TreeNodeId
		local children : {TreeNodeId} = {}
		if busy then
			children[#children + 1] = g_host.tooltip(_("Building..."), true, false)
			return builtin.ActionDescriptor{
				tool = "construction-menu-perks",
				onBack = function() leave(params) end,
				terrainCirclePolicy = "Never",
				children = children,
			}
		end
		children[#children + 1] = builtin.Selector{
			onSelect = function(entity : Engine.Entity, __ : {integer}, __ : Gui.SelectionDetails) : boolean
				local e = g_host.getEdge(entity)
				if not e or e.roadType ~= api.type["enum"].RoadType.TRACK then return false end
				costState:set(0)
				errorState:set("")
				chainState:set(chain_util.click(chain, entity, nil, { mode = 3 }))
				noteState:set(chain_util.lastNote())
				return true
			end,
			filter = g_host.isEdge,
		}
		if proposal then
			local id = "ntools_loop," .. _o
			for __, l in ipairs(chain) do id = id .. "," .. tostring(l.edge) end
			children[#children + 1] = preview.viewer{
				proposal = proposal,
				anarchy = anarchy,
				onData = function(proposalData : ProposalData)
					if aliveRef:hasExpired() then return end
					costState:set(proposalData.costs)
					local msg = ""
					for __, m in ipairs(proposalData.errorState.messages) do msg = msg .. m .. " " end
					-- (refused here: asked again with the build's Context, it may pass)
					if msg ~= "" and (speedUtil.verdictWithCleanup as function(SimpleProposal) : string)(proposal) == "" then msg = "" end
					-- (still refused: which new piece - the game asked part by part)
					if msg ~= "" then
						local dg = trackbuild.diagnose(id)
						if dg then msg = msg .. "\n" .. dg end
					end
					errorState:set(msg)
				end,
				id = id,
			}
		end

		local info = _("Segments") .. ": " .. tostring(#chain)
		local note = noteState:old() or ""
		if note ~= "" then info = _(note) .. "\n" .. info end
		if #chain == 0 then
			children[#children + 1] = g_host.tooltip(_("Click a track segment, then one further along: the loop runs beside the stretch between"), false, false)
		elseif why then
			children[#children + 1] = g_host.tooltip(why .. "\n" .. info, false, true)
		elseif blocked then
			children[#children + 1] = g_host.tooltip(errorState:old() .. "\n" .. info, false, true, costState:old())
		elseif proposal then
			children[#children + 1] = g_host.tooltip(_("Press Build to build the passing loop") .. "\n" .. info, true, false, costState:old())
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
			onBack = function() leave(params) end,
			highlightedEntities = hl,
			terrainCirclePolicy = "Never",
			children = children,
		}
	end

	params.setActionFn(actionFn, "NtoolsLoopAction")
end)

return {
	init = init,
	opts = opts,
	LoopActionRecipe = LoopActionRecipe,
}
