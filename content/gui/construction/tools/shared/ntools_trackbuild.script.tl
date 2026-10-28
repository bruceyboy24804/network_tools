-- Network Tools: building new track into the existing network, shared by the Crossover and Passing
-- loop tools. A builder collects the work - split an existing segment at points along it (as Add
-- node does: removed, re-added as parts through new nodes), add free nodes, add new segments between
-- any of those and existing nodes - and makes one proposal of it all.
--
--   local b = trackbuild.new()
--   local cuts = b.splitAt(edge, { 0.3, 0.7 })     -- { {node, pos, dir}, ... } in the order given
--   local n = b.node(pos)
--   b.segment(n0, p0, t0, n1, p1, t1, refEdge)      -- refEdge: the existing segment it copies the type of
--   b.touch(existingNode)                           -- an existing node gains a segment
--   local proposal = b.proposal()                   -- nil if b.why
--
-- New segments are on the ground (no bridge / tunnel - unless the panel's Structure forces one) with
-- the reference segment's track type, lanes and style. Segments with signals or other objects can't be split (b.why says so).

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
	point : function(pc : Piece, t : number) : P3
	tangent : function(pc : Piece, t : number) : P3
	closestT : function(pc : Piece, x : number, y : number) : number, number
end
local geom = require "network_tools_1::/gui/construction/tools/shared/ntools_geom.script.tl" as Geom

local record NetUtil
	rebuildCrossings : function(proposal : SimpleProposal, removedEdges : {Engine.Entity}, skipNodes? : {Engine.Entity}) : integer
	whyNotReplaceable : function(edge : Engine.Entity) : string
	configNodesFor : function(removedEdges : {Engine.Entity}, extraNodes? : {Engine.Entity}, skipNodes? : {Engine.Entity}) : {Engine.Entity}
	carryReplaced : function(proposal : SimpleProposal) : integer
end
local net_util = require "network_tools_1::/gui/construction/tools/shared/ntools_net_util.script.tl" as NetUtil

-- (the panel's Structure: new segments forced on the ground / onto a bridge / into a tunnel)
local record Terrain
	forceStructure : function(seg : Proposal.SegmentAndEntity, isTrack : boolean, bridgeId? : integer, tunnelId? : integer) : string
end
local terrain = require "network_tools_1::/gui/construction/tools/shared/ntools_terrain.script.tl" as Terrain

local MIN_PART = 2.0   -- metres: shortest part a split may leave

local record Cut
	node : Engine.Entity
	pos : P3
	dir : P3       -- unit, along the split segment's own direction (node0 -> node1)
	before : Engine.Entity   -- the new part ending at the cut (from node0's side)
	after : Engine.Entity    -- the new part starting there
end

-- a signal kept back for after the build (Builder.deferSignals): where, facing trains travelling
-- along `dir` (horizontal)
local record DeferredSignal
	pos : P3
	dir : P3
	model : string
	oneWay : boolean
end

local record Builder
	splitAt : function(edge : Engine.Entity, ts : {number}) : {Cut}
	node : function(pos : P3) : Engine.Entity
	segment : function(n0 : Engine.Entity, p0 : P3, t0 : P3, n1 : Engine.Entity, p1 : P3, t1 : P3, ref : Engine.Component.BaseEdge, keep? : boolean) : Engine.Entity
	touch : function(node : Engine.Entity)
	remove : function(edge : Engine.Entity) : boolean
	removeNode : function(node : Engine.Entity)
	signal : function(seg : Engine.Entity, param : number, left : boolean, model : string, oneWay? : boolean)
	-- a signal `dist` metres short of a switch at one end of a new segment, for trains heading into it
	protectSwitch : function(seg : Engine.Entity, switchAtStart : boolean, dist : number, model : string)
	-- deferred splits (a segment can be split once): ask for every place first, then cut them all
	want : function(edge : Engine.Entity, t : number) : string
	cutAll : function() : boolean
	cut : function(key : string) : Cut
	proposal : function() : SimpleProposal
	why : string
	template : string   -- set: new segments (not split parts) get this track type instead of ref's
	onNewSegment : function(seg : Proposal.SegmentAndEntity)   -- set: called for each new segment (not split parts)
	-- which new segment the game refuses (after proposal()): a tooltip line, or nil
	diagnose : function() : string
	-- set: signals aren't put in the proposal but kept in `deferred`, for placeSignals() after the
	-- build. A layout the game only accepts with cleanupStreetGraph (loops crossing other tracks) is
	-- refused with its signals in it: the cleanup rebuilds those segments
	deferSignals : boolean
	deferred : {DeferredSignal}
end

-- a street / track template by name, or nil
local function templateOf(name : string) : StreetTemplate
	if not name or name == "" then return nil end
	local ok, t = pcall(function() : StreetTemplate
		local id = api.res.streetTemplateRep.find(name)
		if id == nil or id < 0 then return nil end
		return api.res.streetTemplateRep.get(id)
	end)
	return ok and t or nil
end

local function getEdge(entity : Engine.Entity) : Engine.Component.BaseEdge
	if not entity or entity < 0 or not api.engine.entityExists(entity) then return nil end
	return api.engine.getComponent(entity, api.type.ComponentType.BASE_EDGE) as Engine.Component.BaseEdge
end

local function unit(v : P3) : P3
	local l = math.sqrt(v.x * v.x + v.y * v.y + v.z * v.z)
	if l < 1e-9 then return { x = 1, y = 0, z = 0 } end
	return { x = v.x / l, y = v.y / l, z = v.z / l }
end

-- (set below: the last builder whose proposal was made, and where its refused piece is)
local g_last : Builder = nil
local g_lastBad : P3 = nil

local function new() : Builder
	local b : Builder = {}
	local nextId = -1
	local function newId() : Engine.Entity
		local id = nextId
		nextId = nextId - 1
		return id
	end
	local nodes : {Proposal.NodeAndEntity} = {}
	local edges : {Proposal.SegmentAndEntity} = {}
	local removed : {Engine.Entity} = {}
	local touched : {Engine.Entity} = {}
	local nodesRemoved : {Engine.Entity} = {}
	local segById : {Engine.Entity : Proposal.SegmentAndEntity} = {}
	local objects : {SimpleStreetProposal.EdgeObject} = {}
	local objRefs : {Engine.Entity : {{Engine.Entity, EdgeObjectType}}} = {}
	-- (signal placeholders far below every other new entity, as the Signals tool)
	local nextPlaceholder = -400000000
	-- each segment's own ids and whether it's new track (not a split part) - proposal() renumbers the
	-- segments in place; diagnose() rebuilds parts of the proposal from these
	local record Spec
		entity : Engine.Entity
		n0 : Engine.Entity
		n1 : Engine.Entity
		isNew : boolean
	end
	local specs : {Spec} = {}
	local nodeIds : {Engine.Entity} = {}

	local function addSeg(n0 : Engine.Entity, p0 : P3, t0 : P3, n1 : Engine.Entity, p1 : P3, t1 : P3,
			ref : Engine.Component.BaseEdge, keepStructure : boolean, useTemplate? : boolean) : Engine.Entity
		local seg = api.type.SegmentAndEntity.new()
		seg.entity = newId()
		seg.comp.node0, seg.comp.node1 = n0, n1
		seg.comp.position0, seg.comp.position1 = geom.vec3(p0), geom.vec3(p1)
		seg.comp.tangent0, seg.comp.tangent1 = geom.vec3(t0), geom.vec3(t1)
		if keepStructure then
			seg.comp.type, seg.comp.typeIndex = ref.type, ref.typeIndex
		else
			seg.comp.type, seg.comp.typeIndex = api.type["enum"].BaseEdgeType.NORMAL, -1
		end
		seg.comp.laneConfigs = ref.laneConfigs
		seg.comp.roadTemplate = ref.roadTemplate
		seg.comp.roadStyle = ref.roadStyle
		seg.comp.roadType = ref.roadType
		seg.comp.roadDevelopmentLocked = ref.roadDevelopmentLocked
		seg.type = ref.roadType == api.type["enum"].RoadType.TRACK and 1 or 0
		-- (track: its spacing, as Connect sets it - left at 0 otherwise)
		if seg.type == 1 then pcall(function() seg.comp.distance = ref.distance end) end
		if useTemplate and b.template then
			local t = templateOf(b.template)
			if t then
				seg.comp.roadTemplate = b.template
				seg.comp.laneConfigs = t.laneConfigs
				seg.comp.roadStyle = t.streetStyle
				if seg.type == 1 and t.trackDistance and t.trackDistance > 0 then
					pcall(function() seg.comp.distance = t.trackDistance end)
				end
			end
		end
		if useTemplate and b.onNewSegment then b.onNewSegment(seg) end
		if useTemplate then terrain.forceStructure(seg, seg.type == 1) end
		edges[#edges + 1] = seg
		specs[#specs + 1] = { entity = seg.entity, n0 = n0, n1 = n1, isNew = useTemplate == true }
		segById[seg.entity] = seg
		return seg.entity
	end

	-- a signal on a new segment: param 0..1 along it, left = facing travel against its direction
	b.signal = function(segId : Engine.Entity, param : number, left : boolean, model : string, oneWay? : boolean)
		if not segById[segId] or not model then return end
		-- deferred (b.deferSignals): where it goes and which way it faces, placed after the build
		if b.deferSignals then
			pcall(function()
				local pc = geom.edgePiece((segById[segId].comp as any) as Engine.Component.BaseEdge)
				local d = geom.tangent(pc, param)
				local sgn = left and -1 or 1
				b.deferred = b.deferred or {}
				b.deferred[#b.deferred + 1] = { pos = geom.point(pc, param), dir = { x = d.x * sgn, y = d.y * sgn, z = 0 },
					model = model, oneWay = oneWay == true }
			end)
			return
		end
		local o = api.type.SimpleStreetProposal.EdgeObject.new()
		o.edgeEntity = segId
		o.param = param
		o.oneWay = oneWay == true
		o.left = left
		o.model = model
		o.playerEntity = api.engine.util.getPlayer()
		objects[#objects + 1] = o
		objRefs[segId] = objRefs[segId] or {}
		local refs = objRefs[segId]
		refs[#refs + 1] = { nextPlaceholder, api.type["enum"].EdgeObjectType.SIGNAL }
		nextPlaceholder = nextPlaceholder - 1
	end

	-- (switch at the start: trains heading to it run against the segment - left; near its start.
	-- At the end: with it - right, near its end. Not on a piece too short to hold one; at most mid-way,
	-- so two on one segment never meet - "edge objects too close" asserts)
	b.protectSwitch = function(segId : Engine.Entity, switchAtStart : boolean, dist : number, model : string)
		local seg = segById[segId]
		if not seg or not model then return end
		local c = seg.comp
		local L = math.sqrt((c.position1.x - c.position0.x) ^ 2 + (c.position1.y - c.position0.y) ^ 2)
		if L < 6 then return end
		local f = math.max(0.05, math.min(0.4, (dist or 10) / L))
		if switchAtStart then b.signal(segId, f, true, model) else b.signal(segId, 1 - f, false, model) end
	end

	b.node = function(pos : P3) : Engine.Entity
		local n = api.type.NodeAndEntity.new()
		n.entity = newId()
		n.comp.position = geom.vec3(pos)
		nodes[#nodes + 1] = n
		nodeIds[#nodes] = n.entity
		return n.entity
	end

	b.splitAt = function(edge : Engine.Entity, ts : {number}) : {Cut}
		local e = getEdge(edge)
		if not e then b.why = b.why or _("A segment is gone") return nil end
		local whyNot = net_util.whyNotReplaceable(edge)
		if whyNot then b.why = b.why or whyNot return nil end
		local pc = geom.edgePiece(e)
		local len = geom.length(pc)
		-- (in order along the segment, each far enough from its neighbours and the ends)
		local order : {integer} = {}
		for i in ipairs(ts) do order[#order + 1] = i end
		table.sort(order, function(a : integer, c : integer) : boolean return ts[a] < ts[c] end)
		local sorted : {number} = {}
		local prev = 0.0
		for __, i in ipairs(order) do
			local t = ts[i]
			if (t - prev) * len < MIN_PART or (1 - t) * len < MIN_PART then
				b.why = b.why or _("Too close to a node or to the end of the segment")
				return nil
			end
			sorted[#sorted + 1] = t
			prev = t
		end
		local parts = geom.split(pc, sorted)
		local ids : {Engine.Entity} = {}
		for k = 1, #sorted do ids[k] = b.node(parts[k].p1) end
		local partIds : {Engine.Entity} = {}
		for k, part in ipairs(parts) do
			local n0 = k == 1 and e.node0 or ids[k - 1]
			local n1 = k == #parts and e.node1 or ids[k]
			-- (the parts keep the segment's own bridge / tunnel)
			partIds[k] = addSeg(n0, part.p0, part.t0, n1, part.p1, part.t1, e, true)
		end
		removed[#removed + 1] = edge
		local cuts : {Cut} = {}
		for k, i in ipairs(order) do
			cuts[i] = { node = ids[k], pos = parts[k].p1, dir = unit(geom.tangent(pc, sorted[k])),
				before = partIds[k], after = partIds[k + 1] }
		end
		return cuts
	end

	-- (keep: the reference segment's own bridge / tunnel; else on the ground). Returns its id.
	b.segment = function(n0 : Engine.Entity, p0 : P3, t0 : P3, n1 : Engine.Entity, p1 : P3, t1 : P3, ref : Engine.Component.BaseEdge, keep? : boolean) : Engine.Entity
		return addSeg(n0, p0, t0, n1, p1, t1, ref, keep == true, true)
	end

	-- deferred splits: the same place (or one within 1 m) asked twice is one cut
	local wantT : {Engine.Entity : {number}} = {}
	local wantOrder : {Engine.Entity} = {}
	local wantKey : {string : {Engine.Entity, integer}} = {}
	local cutOfKey : {string : Cut} = {}
	b.want = function(edge : Engine.Entity, t : number) : string
		if not wantT[edge] then wantT[edge] = {}; wantOrder[#wantOrder + 1] = edge end
		local ts = wantT[edge]
		local at = 0
		local e = getEdge(edge)
		local len = e and geom.length(geom.edgePiece(e)) or 1
		for i, tt in ipairs(ts) do if math.abs(tt - t) * len < 1 then at = i end end
		if at == 0 then ts[#ts + 1] = t; at = #ts end
		local key = tostring(edge) .. "#" .. tostring(at)
		wantKey[key] = { edge, at }
		return key
	end
	b.cutAll = function() : boolean
		for __, edge in ipairs(wantOrder) do
			local cuts = b.splitAt(edge, wantT[edge])
			if not cuts then return false end
			for i, c in ipairs(cuts) do cutOfKey[tostring(edge) .. "#" .. tostring(i)] = c end
		end
		return true
	end
	b.cut = function(key : string) : Cut return cutOfKey[key] end

	b.touch = function(node : Engine.Entity)
		if not node or node < 0 then return end
		-- (a station's / depot's own node: its lanes can't be dropped - the game refuses the whole
		-- build, "Construction Not Possible" - and a new segment joins it without that)
		-- (a station's open track end isn't owned by the station itself, but its track is: as
		-- Connect, any segment there belonging to a construction leaves the node alone)
		local ok, owned = pcall(function() : boolean
			local sc = api.engine.system.streetConnectorSystem
			if (sc.getConstructionEntityForNode(node) or -1) >= 0 then return true end
			for __, s in ipairs(api.engine.system.streetSystem.getNodeSegments(node) or {}) do
				if (sc.getConstructionEntityForEdge(s) or -1) >= 0 then return true end
			end
			return false
		end)
		if not ok or owned then return end
		touched[#touched + 1] = node
	end

	-- an existing segment goes (to be re-added in a new shape); false and b.why if it can't
	b.remove = function(edge : Engine.Entity) : boolean
		local whyNot = net_util.whyNotReplaceable(edge)
		if whyNot then b.why = b.why or whyNot return false end
		removed[#removed + 1] = edge
		return true
	end

	-- an existing node goes too (every segment at it must be removed)
	b.removeNode = function(node : Engine.Entity)
		nodesRemoved[#nodesRemoved + 1] = node
	end

	b.proposal = function() : SimpleProposal
		if b.why or #edges == 0 then return nil end
		local proposal = api.type.SimpleProposal.new()
		-- renumber: segments -1..-n in list order, then nodes - an edge object names its segment by
		-- that place in the list (the engine asserts -n <= edgeEntity < 0)
		local newId : {Engine.Entity : Engine.Entity} = {}
		for k, seg in ipairs(edges) do newId[seg.entity] = -k end
		for k, n in ipairs(nodes) do newId[n.entity] = -(#edges + k) end
		local function map(id : Engine.Entity) : Engine.Entity return (id < 0 and newId[id]) or id end
		for __, seg in ipairs(edges) do
			seg.entity = map(seg.entity)
			seg.comp.node0, seg.comp.node1 = map(seg.comp.node0), map(seg.comp.node1)
		end
		for __, n in ipairs(nodes) do n.entity = map(n.entity) end
		for id, refs in pairs(objRefs) do segById[id].comp.objects = refs end
		for __, o in ipairs(objects) do o.edgeEntity = map(o.edgeEntity) end
		if #objects > 0 then proposal.streetProposal.edgeObjectsToAdd = objects end
		if #nodes > 0 then proposal.streetProposal.nodesToAdd = nodes end
		proposal.streetProposal.edgesToAdd = edges
		if #removed > 0 then proposal.streetProposal.edgesToRemove = removed end
		if #nodesRemoved > 0 then proposal.streetProposal.nodesToRemove = nodesRemoved end
		-- lane connections at the ends of what is removed, and at nodes that gain a segment: rebuilt
		-- (not at the nodes that go)
		local cfg = net_util.configNodesFor(removed, touched, nodesRemoved)
		if #cfg > 0 then proposal.streetProposal.nodeConfigsToRemove = cfg end
		if #removed > 0 then net_util.rebuildCrossings(proposal, removed, nodesRemoved) end
		g_last = b
		return proposal
	end

	-- A part of the proposal: every split part (the existing track as it was, in pieces) and the new
	-- segments `keep` names (their places in the list), with the nodes they use. No edge objects.
	local function subset(keep : {integer : boolean}) : SimpleProposal
		local p = api.type.SimpleProposal.new()
		local pick : {integer} = {}
		local usedNode : {Engine.Entity : boolean} = {}
		for k, sp in ipairs(specs) do
			if not sp.isNew or keep[k] then
				pick[#pick + 1] = k
				usedNode[sp.n0], usedNode[sp.n1] = true, true
			end
		end
		local newId : {Engine.Entity : Engine.Entity} = {}
		for i, k in ipairs(pick) do newId[specs[k].entity] = -i end
		local nodeList : {Proposal.NodeAndEntity} = {}
		for j, id in ipairs(nodeIds) do
			if usedNode[id] then
				local n = api.type.NodeAndEntity.new()
				n.entity = -(#pick + #nodeList + 1)
				n.comp.position = nodes[j].comp.position
				newId[id] = n.entity
				nodeList[#nodeList + 1] = n
			end
		end
		local function map(id : Engine.Entity) : Engine.Entity return (id < 0 and newId[id]) or id end
		local list : {Proposal.SegmentAndEntity} = {}
		for i, k in ipairs(pick) do
			local src, sp = edges[k], specs[k]
			local s = api.type.SegmentAndEntity.new()
			s.entity = -i
			s.type = src.type
			local c, o = s.comp, src.comp
			c.node0, c.node1 = map(sp.n0), map(sp.n1)
			c.position0, c.position1, c.tangent0, c.tangent1 = o.position0, o.position1, o.tangent0, o.tangent1
			c.type, c.typeIndex = o.type, o.typeIndex
			c.laneConfigs, c.roadTemplate, c.roadStyle, c.roadType = o.laneConfigs, o.roadTemplate, o.roadStyle, o.roadType
			c.roadDevelopmentLocked = o.roadDevelopmentLocked
			pcall(function() c.distance = o.distance end)
			list[#list + 1] = s
		end
		p.streetProposal.edgesToAdd = list
		if #nodeList > 0 then p.streetProposal.nodesToAdd = nodeList end
		if #removed > 0 then p.streetProposal.edgesToRemove = removed end
		if #nodesRemoved > 0 then p.streetProposal.nodesToRemove = nodesRemoved end
		local cfg = net_util.configNodesFor(removed, touched, nodesRemoved)
		if #cfg > 0 then p.streetProposal.nodeConfigsToRemove = cfg end
		if #removed > 0 then net_util.rebuildCrossings(p, removed, nodesRemoved) end
		return p
	end
	-- the game's verdict on a proposal, as the builds ask it (cleanupStreetGraph: without it a loop
	-- crossing other tracks is refused - every part with a crossing in it was blamed): its messages,
	-- "" = accepted
	local function verdict(p : SimpleProposal) : string
		local out = "?"
		pcall(function()
			local ctx = api.type.Context.new()
			ctx.player = api.engine.util.getPlayer()
			ctx.cleanupStreetGraph = true
			local pd = (api.engine.util.proposal.makeProposalData as function(SimpleProposal, Context) : ProposalData)(p, ctx)
			local msg = ""
			for __, m in ipairs(pd.errorState.messages or {}) do msg = msg .. m .. " " end
			out = msg
		end)
		return out
	end
	-- the tightest radius along a segment (plan view)
	local function minRadius(o : Engine.Component.BaseEdge) : number
		local best = math.huge
		local p0, t0, p1, t1 = o.position0, o.tangent0, o.position1, o.tangent1
		for i = 0, 16 do
			local s = i / 16
			local a0, a1, a2, a3 = 6 * s * s - 6 * s, 3 * s * s - 4 * s + 1, -6 * s * s + 6 * s, 3 * s * s - 2 * s
			local b0, b1, b2, b3 = 12 * s - 6, 6 * s - 4, -12 * s + 6, 6 * s - 2
			local dx = a0 * p0.x + a1 * t0.x + a2 * p1.x + a3 * t1.x
			local dy = a0 * p0.y + a1 * t0.y + a2 * p1.y + a3 * t1.y
			local ddx = b0 * p0.x + b1 * t0.x + b2 * p1.x + b3 * t1.x
			local ddy = b0 * p0.y + b1 * t0.y + b2 * p1.y + b3 * t1.y
			local cr = math.abs(dx * ddy - dy * ddx)
			local v = math.sqrt(dx * dx + dy * dy)
			if cr > 1e-9 then best = math.min(best, v * v * v / cr) end
		end
		return best
	end
	-- Which new segment the game refuses (delta debugging: the split alone first, then halves of the
	-- new segments, each half checked on its own, down to one). A line for the tooltip, or nil.
	b.diagnose = function() : string
		local newIdx : {integer} = {}
		for k, sp in ipairs(specs) do if sp.isNew then newIdx[#newIdx + 1] = k end end
		if #newIdx == 0 then return nil end
		local m0 = verdict(subset({}))
		if m0 ~= "" then return _("Refused: splitting the existing track itself") .. (m0 ~= "?" and (" (" .. m0 .. ")") or "") end
		local function setOf(list : {integer}) : {integer : boolean}
			local st : {integer : boolean} = {}
			for __, k in ipairs(list) do st[k] = true end
			return st
		end
		local function find(list : {integer}) : {integer}, string
			if #list == 1 then return list, verdict(subset(setOf(list))) end
			local half = math.floor(#list / 2)
			local L, R : {integer}, {integer} = {}, {}
			for i, k in ipairs(list) do if i <= half then L[#L + 1] = k else R[#R + 1] = k end end
			local mL = verdict(subset(setOf(L)))
			if mL ~= "" then return find(L) end
			local mR = verdict(subset(setOf(R)))
			if mR ~= "" then return find(R) end
			return list, ""
		end
		local bad, msg = find(newIdx)
		if #bad ~= 1 then
			return string.format(_("Refused only together: %d new pieces clash with each other (each is fine alone)"), #bad)
		end
		local k = bad[1]
		local o = edges[k].comp
		local len = math.sqrt((o.position1.x - o.position0.x) ^ 2 + (o.position1.y - o.position0.y) ^ 2)
		local grade = len > 0.1 and (o.position1.z - o.position0.z) / len * 100 or 0
		local r = minRadius(o)
		local place = 0
		for i, kk in ipairs(newIdx) do if kk == k then place = i end end
		g_lastBad = { x = (o.position0.x + o.position1.x) / 2, y = (o.position0.y + o.position1.y) / 2, z = (o.position0.z + o.position1.z) / 2 }
		return string.format(_("Refused piece %d of %d: %s- radius %s, grade %.1f%%, %d m long"), place, #newIdx,
			(msg ~= "" and msg ~= "?") and msg or "", r < 1e5 and string.format("%d m", math.floor(r + 0.5)) or _("straight"),
			grade, math.floor(len + 0.5))
	end

	return b
end

-- the last diagnosis (the builder whose proposal was made last - the one a tool previews - is g_last)
local g_diagKey : string = nil
local g_diagOut : string = nil
-- The refused piece of the previewed proposal (once per key - each check asks the game a few times)
local function diagnose(key : string) : string
	if key and key == g_diagKey then return g_diagOut end
	local out : string = nil
	if g_last then
		local ok, r = pcall(function() : string return g_last.diagnose() end)
		out = ok and r or nil
	end
	g_diagKey, g_diagOut = key, out
	return out
end

-- The signals the last proposal's builder kept back (deferSignals), or nil - taken when its build is
-- sent (the next plan makes a new builder)
local function deferredSignals() : {DeferredSignal}
	return g_last and g_last.deferSignals and g_last.deferred or nil
end

-- Signals kept back, placed onto the track as built: each spot's built segment found (the build may
-- have tidied the segments - cleanupStreetGraph), and re-added with its signals, as the Signals tool
-- puts signals on existing track. One proposal for all of them.
local function placeSignals(list : {DeferredSignal})
	if not list or #list == 0 then return end
	local ok, err = pcall(function()
		local record Spot
			param : number
			left : boolean
			model : string
			oneWay : boolean
		end
		local bySeg : {Engine.Entity : {Spot}} = {}
		local order : {Engine.Entity} = {}
		for __, sg in ipairs(list) do
			local best : Engine.Entity = nil
			local bestD, bestT = 1.5, 0.0
			for __, s in ipairs(api.engine.util.octree.findEntitiesInCircle(api.type.Vec2f.new(sg.pos.x, sg.pos.y), 6, api.type.ComponentType.BASE_EDGE)) do
				local e = getEdge(s)
				if e and e.roadType == api.type["enum"].RoadType.TRACK then
					local t, d = geom.closestT(geom.edgePiece(e), sg.pos.x, sg.pos.y)
					if d < bestD then best, bestD, bestT = s, d, t end
				end
			end
			-- (not right at a segment's end: a signal there belongs to its neighbour)
			if best and bestT > 0.02 and bestT < 0.98 then
				local tg = geom.tangent(geom.edgePiece(getEdge(best)), bestT)
				if not bySeg[best] then bySeg[best] = {}; order[#order + 1] = best end
				local spots = bySeg[best]
				spots[#spots + 1] = { param = bestT, left = tg.x * sg.dir.x + tg.y * sg.dir.y < 0, model = sg.model, oneWay = sg.oneWay }
			end
		end
		local edgesToAdd : {Proposal.SegmentAndEntity} = {}
		local edgesToRemove : {Engine.Entity} = {}
		local objects : {SimpleStreetProposal.EdgeObject} = {}
		local placeholder = -400000000
		for __, edge in ipairs(order) do
			local e = getEdge(edge)
			-- (fresh track: nothing on it to carry over - anything else is left alone)
			if e and #(e.objects or {}) == 0 then
				local seg = api.type.SegmentAndEntity.new()
				seg.entity = -(#edgesToAdd + 1)
				seg.comp = e
				seg.type = 1
				pcall(function()
					local po = api.engine.getComponent(edge, api.type.ComponentType.PLAYER_OWNED)
					if po then seg.playerOwned = po end
				end)
				local refs : {{Engine.Entity, EdgeObjectType}} = {}
				for __, sp in ipairs(bySeg[edge]) do
					local o = api.type.SimpleStreetProposal.EdgeObject.new()
					o.edgeEntity = seg.entity
					o.param = sp.param
					o.oneWay = sp.oneWay
					o.left = sp.left
					o.model = sp.model
					o.playerEntity = api.engine.util.getPlayer()
					objects[#objects + 1] = o
					refs[#refs + 1] = { placeholder, api.type["enum"].EdgeObjectType.SIGNAL }
					placeholder = placeholder - 1
				end
				seg.comp.objects = refs
				edgesToAdd[#edgesToAdd + 1] = seg
				edgesToRemove[#edgesToRemove + 1] = edge
			end
		end
		if #edgesToAdd == 0 then return end
		local p = api.type.SimpleProposal.new()
		p.streetProposal.edgesToAdd = edgesToAdd
		p.streetProposal.edgesToRemove = edgesToRemove
		p.streetProposal.edgeObjectsToAdd = objects
		local cfg = net_util.configNodesFor(edgesToRemove)
		if #cfg > 0 then
			p.streetProposal.nodeConfigsToRemove = cfg
			-- and give them back on the re-added segments (a node left without a config crashes the game)
			net_util.carryReplaced(p)
		end
		net_util.rebuildCrossings(p, edgesToRemove)
		api.cmd.sendCommand(api.cmd.makeWorldBuildProposalCmd(p, nil, false, true), function(__ : WorldBuildProposalCommandData, success : boolean)
			if not success then print("[network_tools] signals after the build: refused") end
		end)
	end)
	if not ok then print("[network_tools] signals after the build failed: " .. tostring(err)) end
end

local record M
	new : function() : Builder
	unit : function(v : P3) : P3
	deferredSignals : function() : {DeferredSignal}
	placeSignals : function(list : {DeferredSignal})
	-- the previewed proposal refused: which new piece, as a tooltip line (key: the preview's id - each
	-- diagnosis asks the game a few times, so once per shape); and where that piece is
	diagnose : function(key : string) : string
	lastBad : function() : P3
end
local m : M = { new = new, unit = unit, diagnose = diagnose, lastBad = function() : P3 return g_lastBad end,
	deferredSignals = deferredSignals, placeSignals = placeSignals }
return m
