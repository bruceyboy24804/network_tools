-- Network Tools: Set slope (modelled on Network Multitool's SetSlope for Cities: Skylines 1 and the
-- slope transforms of Network Tools for Cities: Skylines 2).
-- Select a stretch of road or track, pick a profile, then Build: the two ends keep their height and
-- every node in between is lifted or lowered onto the profile, measured along the road.
--   Linear - one constant gradient from end to end
--   Ease   - gentle at both ends, steepest in the middle (smoothstep)
--   Arch   - linear plus a hump of the chosen height in the middle (to go over something)
-- The segments' end slopes follow the profile too, so the road bends smoothly rather than at nodes.
--
-- TF3 has no command to move a node: each moved node is replaced by a new one at the new height,
-- and every segment touching it (side roads included) is removed and re-added. Side roads keep
-- their own slope; only their end moves. Loaded by the connect tool (init() hand-over).

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
	p3 : function(x : number, y : number, z : number) : P3
	vec3 : function(p : P3) : Vec3f
	edgePiece : function(e : Engine.Component.BaseEdge) : Piece
	length : function(pc : Piece) : number
	point : function(pc : Piece, t : number) : P3
	tangent : function(pc : Piece, t : number) : P3
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

-- bridges / tunnels where the new profile runs high above / deep below the ground (shared rules)
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
	noTags : boolean
end
local record Preview
	viewer : function(p : PreviewParams) : TreeNodeId
	leftover : function() : TreeNodeId
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

-- in-world handles (shared kit)
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
end
local record Handles
	canvas : function() : Canvas
	hit : function(handles : {Handle}, x : number, y : number) : integer
	mouse : function(evt : Gui.Mouse.Event, ctl : DragCtl) : boolean
	cursor : function() : number, number
	colors : {string : Vec4f}
end
local handles = require "network_tools_1::/gui/construction/tools/shared/ntools_handles.script.tl" as Handles

-- in-world tags on segments (like the street builder's gradient tags) and nodes (shared/ntools_labels)
local record Tag
	grade : number      -- gradient % to show (nil = the segment's own)
	text : string
end
local record LabelRow
	icon : string
	text : string
end
local record LabelPoint
	x : number
	y : number
	z : number
	rows : {LabelRow}
	detail : {LabelRow}
end
local record Labels
	set : function(tags : {Engine.Entity : Tag}, points? : {LabelPoint})
	node : function() : TreeNodeId
	icons : {string : string}
end
local labels = require "network_tools_1::/gui/construction/tools/shared/ntools_labels.script.tl" as Labels

do ((require "network_tools_1::/gui/construction/tools/shared/ntools_debug.script.tl" as {string : any}).log as function(string))("[network_tools] slope tool script loaded (v4: gradient tags)") end

local ARCH_MIN, ARCH_MAX = -30, 30   -- metres; negative = a dip

local MODE_LINEAR, MODE_EASE, MODE_ARCH = 1, 2, 3

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

-- options shared with the panel
local record Options
	mode : integer      -- MODE_LINEAR / MODE_EASE / MODE_ARCH
	arch : number       -- metres the arch rises above the straight line (negative = a dip)
	easeIn : number     -- Ease: share of the stretch (0 .. 0.5) that stays flat-ish at the start
	easeOut : number    -- Ease: the same at the end
end
local opts : Options = { mode = MODE_LINEAR, arch = 5.0, easeIn = 0.1, easeOut = 0.1 }
local EASE_MAX = 0.5

local g_host : Host = nil
local getEdge : function(Engine.Entity) : Engine.Component.BaseEdge
local isEdge : function(Engine.Entity) : boolean
local getNodePos : function(Engine.Entity) : P3
local tooltip : function(message : string, good : boolean, bad : boolean, cost? : integer) : TreeNodeId

local function init(host : Host)
	g_host = host
	getEdge, isEdge, getNodePos, tooltip = host.getEdge, host.isEdge, host.getNodePos, host.tooltip
end

-- Ease profile, as CS2 Network Tools' SlopeEaseInOutTransform: a cubic Bezier in (u, height)
-- through (0, z0), (easeIn, z0), (1 - easeOut, z1), (1, z1) - the two inner points set how long
-- the road stays level before it starts to climb / after it stops. Solve x(t) = u by Newton
-- (CS2 FindParameterForPathRatio), then read the height and its slope per u there.
local function easeProfile(z0 : number, z1 : number, ein : number, eout : number, u : number) : number, number
	local x1, x2 = ein, 1 - eout
	local function bx(t : number) : number
		local s = 1 - t
		return 3 * s * s * t * x1 + 3 * s * t * t * x2 + t * t * t
	end
	local function dbx(t : number) : number
		local s = 1 - t
		return 3 * s * s * x1 + 6 * s * t * (x2 - x1) + 3 * t * t * (1 - x2)
	end
	local t = u
	for _ = 1, 12 do
		local err = bx(t) - u
		if math.abs(err) < 1e-6 then break end
		local d = dbx(t)
		if math.abs(d) < 1e-6 then break end
		t = math.max(0, math.min(1, t - err / d))
	end
	local s = 1 - t
	local z = s * s * s * z0 + 3 * s * s * t * z0 + 3 * s * t * t * z1 + t * t * t * z1
	local dz = 6 * s * t * (z1 - z0)          -- dy/dt (the outer control segments are level)
	local dx = dbx(t)
	return z, math.abs(dx) > 1e-6 and dz / dx or 0
end

-- Height and height per unit of u (0..1 along the stretch) of the profile.
local function profile(mode : integer, z0 : number, rise : number, arch : number, ein : number, eout : number, u : number) : number, number
	if mode == MODE_EASE then
		return easeProfile(z0, z0 + rise, ein, eout, u)
	elseif mode == MODE_ARCH then
		return z0 + rise * u + arch * 4 * u * (1 - u), rise + arch * (4 - 8 * u)
	end
	return z0 + rise * u, rise
end

local record Result
	proposal : SimpleProposal
	why : string
	length : number       -- along the road, metres
	rise : number         -- end height minus start height
	maxGrade : number     -- steepest point of the profile, percent
	moved : integer       -- nodes lifted / lowered
	grades : {Engine.Entity : number}   -- each selected segment's new gradient in %, along the stretch
	nodeZ : {Engine.Entity : number}    -- each node of the stretch's height after Build
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

local function hlen(v : P3) : number
	return math.sqrt(v.x * v.x + v.y * v.y)
end

local function makeSlopeProposal(chain : {ChainLink}, mode : integer, arch : number, ein : number, eout : number) : Result
	local res : Result = { length = 0, rise = 0, maxGrade = 0, moved = 0 }
	if #chain == 0 then return res end
	local nodeList = chain_util.nodes(chain)
	if nodeList[1] == nodeList[#nodeList] then
		res.why = _("The stretch is a loop - pick one that has two ends")
		return res
	end

	-- distance along the road to every node
	local s : {number} = { 0 }
	for i, link in ipairs(chain) do
		local e = getEdge(link.edge)
		if not e then return res end
		s[i + 1] = s[i] + geom.length(geom.edgePiece(e))
	end
	local S = s[#s]
	if S < 1 then return res end
	local zStart = getNodePos(nodeList[1]).z
	local rise = getNodePos(nodeList[#nodeList]).z - zStart
	res.length, res.rise = S, rise

	-- profile height and slope (dz per metre along the road) at every node
	local zAt : {number} = {}
	local slopeAt : {number} = {}
	for k = 1, #nodeList do
		local z, dzdu = profile(mode, zStart, rise, arch, ein, eout, s[k] / S)
		zAt[k], slopeAt[k] = z, dzdu / S
	end
	res.nodeZ = {}
	for k, n in ipairs(nodeList) do res.nodeZ[n] = zAt[k] end
	res.grades = {}
	for i, link in ipairs(chain) do
		local ds = s[i + 1] - s[i]
		if ds > 0.01 then res.grades[link.edge] = (zAt[i + 1] - zAt[i]) / ds * 100 end
	end
	for i = 0, 50 do
		local _z, dzdu = profile(mode, zStart, rise, arch, ein, eout, i / 50)
		res.maxGrade = math.max(res.maxGrade, math.abs(dzdu / S) * 100)
	end

	-- nodes that move: every node between the ends
	local idxOf : {Engine.Entity : integer} = {}
	for k, n in ipairs(nodeList) do idxOf[n] = k end
	local moved : {Engine.Entity} = {}
	for k = 2, #nodeList - 1 do
		local n = nodeList[k]
		-- (a moved node is removed and re-added: a level crossing can't be, it is re-created only
		-- where its node stays - at the stretch's ends that works, see rebuildCrossings below)
		if net_util.isProtectedNode(n) or net_util.isCrossingNode(n) then
			res.why = _("A node inside the stretch is a level crossing or has hand-edited lanes / lights")
			return res
		end
		moved[#moved + 1] = n
	end
	local isMoved : {Engine.Entity : boolean} = {}
	for _, n in ipairs(moved) do isMoved[n] = true end
	res.moved = #moved

	-- segments to re-add: the stretch, plus every segment touching a moved node
	local chainLink : {Engine.Entity : ChainLink} = {}
	local toReAdd : {Engine.Entity} = {}
	local seen : {Engine.Entity : boolean} = {}
	local function addEdge(edge : Engine.Entity)
		if not seen[edge] then
			seen[edge] = true
			toReAdd[#toReAdd + 1] = edge
		end
	end
	for _, link in ipairs(chain) do
		chainLink[link.edge] = link
		addEdge(link.edge)
	end
	for _, n in ipairs(moved) do
		local ok, segs = pcall(function() : {Engine.Entity}
			return api.engine.system.streetSystem.getNodeSegments(n)
		end)
		for _, sg in ipairs(ok and segs or {}) do addEdge(sg) end
	end
	for _, edge in ipairs(toReAdd) do
		local why = net_util.whyNotReplaceable(edge)
		if why then
			res.why = why
			return res
		end
	end

	-- ids count down from -1: edges first, then the replacement nodes
	local E = #toReAdd
	local newId : {Engine.Entity : Engine.Entity} = {}
	local nodesToAdd : {Proposal.NodeAndEntity} = {}
	for j, n in ipairs(moved) do
		newId[n] = -(E + j)
		local p = getNodePos(n)
		local node = api.type.NodeAndEntity.new()
		node.entity = newId[n]
		node.comp.position = geom.vec3(geom.p3(p.x, p.y, zAt[idxOf[n]]))
		nodesToAdd[#nodesToAdd + 1] = node
	end

	local edgesToAdd : {Proposal.SegmentAndEntity} = {}
	for i, edge in ipairs(toReAdd) do
		local e = getEdge(edge)
		local pc = geom.edgePiece(e)
		if isMoved[e.node0] then pc.p0 = geom.p3(pc.p0.x, pc.p0.y, zAt[idxOf[e.node0]]) end
		if isMoved[e.node1] then pc.p1 = geom.p3(pc.p1.x, pc.p1.y, zAt[idxOf[e.node1]]) end
		local link = chainLink[edge]
		if link then
			-- on the stretch: both end slopes follow the profile (sign flips if the segment runs
			-- against the stretch's direction)
			local k0, k1 = idxOf[e.node0], idxOf[e.node1]
			local sign = link.fwd and 1 or -1
			pc.t0 = geom.p3(pc.t0.x, pc.t0.y, sign * slopeAt[k0] * hlen(pc.t0))
			pc.t1 = geom.p3(pc.t1.x, pc.t1.y, sign * slopeAt[k1] * hlen(pc.t1))
		end
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
	-- a segment lifted high above the ground becomes a bridge, one lowered deep into it a tunnel
	-- (not the shore rule: these are existing roads)
	for _, seg in ipairs(edgesToAdd) do
		terrain.upgradeSegment(seg, seg.type == 1, nil, nil, true)
	end
	proposal.streetProposal.edgesToAdd = edgesToAdd
	proposal.streetProposal.edgesToRemove = toReAdd
	if #moved > 0 then proposal.streetProposal.nodesToRemove = moved end
	-- the untouched ends' lane connections name removed segments: let the engine rebuild them
	-- (the moved nodes are removed, and a removed node's config can't be removed separately)
	local cfgNodes = net_util.configNodesFor(toReAdd, nil, moved)
	if #cfgNodes > 0 then proposal.streetProposal.nodeConfigsToRemove = cfgNodes end
	-- an untouched end at a level crossing: the engine re-creates the crossing
	net_util.rebuildCrossings(proposal, toReAdd, moved)
	res.proposal = proposal
	return res
end

local SlopeActionRecipe = react.RegisterRecipe("NtoolsSlopeAction", function(params : ConstructionCustomActionParams<any>) : TreeNodeId
	react.onUnmount(preview.clear)   -- its speed / incline tags leave with the tool
	local chainState : ReactStateT<{ChainLink}> = react.useState({})
	local costState : ReactStateT<integer> = react.useState(0)
	local errorState : ReactStateT<string> = react.useState("")
	local aliveRef : ReactRefT<boolean> = react.useRef(true)
	-- true from Build until the command's callback: touching a half-built segment (hover filter)
	-- is an engine assertion, not a Lua error - so no picker and no proposal meanwhile
	local busyState : ReactStateT<boolean> = react.useState(false)
	local draggingState : ReactStateT<integer> = react.useState(0)
	local hoverState : ReactStateT<integer> = react.useState(0)
	local modeUi = engine_react_util.useStepState(function() : integer return opts.mode end)
	local archUi = engine_react_util.useStepState(function() : number return opts.arch end)
	local easeInUi = engine_react_util.useStepState(function() : number return opts.easeIn end)
	local easeOutUi = engine_react_util.useStepState(function() : number return opts.easeOut end)
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
			if api.engine.entityExists(l.edge) and getEdge(l.edge) then chain[#chain + 1] = l end
		end
	end
	local mode = modeUi:old() or MODE_LINEAR
	local arch = archUi:old() or 0
	local ein = easeInUi:old() or 0.1
	local eout = easeOutUi:old() or 0.1
	local anarchy = anarchyUi:old() == true

	local res : Result = { length = 0, rise = 0, maxGrade = 0, moved = 0 }
	if not busy and #chain > 0 then
		res = makeSlopeProposal(chain, mode, arch, ein, eout)
	end
	local proposal = res.proposal

	-- tags on the selected segments: the gradient each will have after Build
	local tags : {Engine.Entity : Tag} = {}
	for _, l in ipairs(chain) do
		local g = res.grades and res.grades[l.edge]
		-- the stretch's grade, turned round for segments that run against it (tags read along
		-- the segment's own direction, like the game's)
		if g then tags[l.edge] = { grade = l.fwd and g or -g } end
	end
	-- tags on the stretch's nodes: how far each moves up / down (on hover: its height after Build)
	local nodeTags : {LabelPoint} = {}
	local tagNodes : {Engine.Entity} = {}
	for n in pairs(res.nodeZ or {}) do tagNodes[#tagNodes + 1] = n end
	table.sort(tagNodes)   -- (a stable order: the tags keep their places)
	for __, n in ipairs(tagNodes) do
		local z = res.nodeZ[n]
		local p = getNodePos(n)
		if p then
			local dz = z - p.z
			local rows : {LabelRow} = {}
			if math.abs(dz) >= 0.05 then
				rows[1] = { icon = dz > 0 and labels.icons.up or labels.icons.down, text = string.format("%+.1f m", dz) }
			end
			nodeTags[#nodeTags + 1] = {
				x = p.x, y = p.y, z = z,
				rows = rows,
				detail = { { icon = labels.icons.height, text = string.format("%.1f m", z) } },
			}
		end
	end
	labels.set(tags, nodeTags)

	-- The stretch sampled along the road (position + distance), to place handles by share of the
	-- length and to read a dragged handle back as a share.
	local samples : {P3} = {}
	local sampleS : {number} = {}
	do
		local acc = 0.0
		for i, l in ipairs(chain) do
			local pc = geom.edgePiece(getEdge(l.edge))
			local n = 16
			for k = (i == 1 and 0 or 1), n do
				local t = k / n
				if not l.fwd then t = 1 - t end
				local q = geom.point(pc, t)
				local prev = samples[#samples]
				if prev then acc = acc + math.sqrt((q.x - prev.x) ^ 2 + (q.y - prev.y) ^ 2 + (q.z - prev.z) ^ 2) end
				samples[#samples + 1] = q
				sampleS[#sampleS + 1] = acc
			end
		end
	end
	local totalS = sampleS[#sampleS] or 0
	-- point and plan direction at share u of the length
	local function pointAt(u : number) : P3, number, number
		local target = u * totalS
		for j = 2, #samples do
			if sampleS[j] >= target or j == #samples then
				local a, b = samples[j - 1], samples[j]
				local seg = sampleS[j] - sampleS[j - 1]
				local f = seg > 1e-6 and math.max(0, math.min(1, (target - sampleS[j - 1]) / seg)) or 0
				local dx, dy = b.x - a.x, b.y - a.y
				local dl = math.sqrt(dx * dx + dy * dy)
				if dl < 1e-6 then dl = 1 end
				return geom.p3(a.x + (b.x - a.x) * f, a.y + (b.y - a.y) * f, a.z + (b.z - a.z) * f), dx / dl, dy / dl
			end
		end
		return nil, 0, 0
	end
	-- share of the length nearest to (x, y)
	local function ratioOf(x : number, y : number) : number
		local bestS, bestD = 0.0, math.huge
		for j = 2, #samples do
			local a, b = samples[j - 1], samples[j]
			local vx, vy = b.x - a.x, b.y - a.y
			local vv = vx * vx + vy * vy
			local f = vv > 1e-9 and math.max(0, math.min(1, ((x - a.x) * vx + (y - a.y) * vy) / vv)) or 0
			local px, py = a.x + vx * f, a.y + vy * f
			local d = (px - x) ^ 2 + (py - y) ^ 2
			if d < bestD then bestD, bestS = d, sampleS[j - 1] + (sampleS[j] - sampleS[j - 1]) * f end
		end
		return totalS > 0 and bestS / totalS or 0
	end

	-- Handles (CS2 Network Tools style), in step with the panel sliders:
	--   Ease: two handles ON the road at the ends of the level zones - slide them along the road
	--         (CS2's AxisHandles for starting / ending flatness)
	--   Arch: one handle beside the middle, as far from the road as the arch is high - left of the
	--         stretch's direction lifts the middle, right lowers it (a dip)
	local handleList : {Handle} = {}
	local handleKind : {string} = {}
	local midP : P3 = nil
	local nx, ny = 0.0, 0.0
	if #samples >= 2 and totalS > 1 then
		if mode == MODE_EASE then
			local p1 = pointAt(ein)
			local p2 = pointAt(1 - eout)
			-- on the ground under the road (z = nil), like the Arch handle
			handleList[1], handleKind[1] = { x = p1.x, y = p1.y, z = nil }, "easeIn"
			handleList[2], handleKind[2] = { x = p2.x, y = p2.y, z = nil }, "easeOut"
		elseif mode == MODE_ARCH then
			local dx, dy : number, number
			midP, dx, dy = pointAt(0.5)
			nx, ny = -dy, dx
			handleList[1], handleKind[1] = { x = midP.x + nx * arch, y = midP.y + ny * arch, z = nil }, "arch"
		end
	end
	local dragging = draggingState:old() or 0
	local hover = hoverState:old() or 0
	local dragCtl : DragCtl = {
		handles = handleList,
		dragging = dragging,
		setDragging = function(i : integer) draggingState:set(i) end,
		hover = hover,
		setHover = function(i : integer) hoverState:set(i) end,
		onDrag = function(i : integer, x : number, y : number)
			local kind = handleKind[i]
			if kind == "easeIn" then
				opts.easeIn = math.max(0, math.min(EASE_MAX, math.floor(ratioOf(x, y) * 200 + 0.5) / 200))
			elseif kind == "easeOut" then
				opts.easeOut = math.max(0, math.min(EASE_MAX, math.floor((1 - ratioOf(x, y)) * 200 + 0.5) / 200))
			elseif kind == "arch" and midP then
				local d = nx * (x - midP.x) + ny * (y - midP.y)
				opts.arch = math.max(ARCH_MIN, math.min(ARCH_MAX, math.floor(d * 2 + 0.5) / 2))
			end
		end,
	}
	local function withHandleOverlay(children : {TreeNodeId}) : {TreeNodeId}
		if #handleList == 0 then return children end
		local c = handles.canvas()
		for i, h in ipairs(handleList) do
			local kind = handleKind[i]
			if kind == "arch" and midP then
				c.line(midP.x, midP.y, nil, h.x, h.y, nil, handles.colors.guide, 0.6)
			elseif kind == "easeIn" or kind == "easeOut" then
				-- a tick across the road marking where the level zone ends
				local u = kind == "easeIn" and ein or (1 - eout)
				local p, dx, dy = pointAt(u)
				if p then
					c.line(p.x + dy * 6, p.y - dx * 6, nil, p.x - dy * 6, p.y + dx * 6, nil, handles.colors.guide, 0.6)
				end
			end
			c.handle(h, dragging == i and 2 or (hover == i and 1 or 0))
		end
		local node = c.node()
		if node then children[#children + 1] = node end
		return children
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
		-- the selected segments are about to be replaced: forget them now, picker off until done
		chainState:set({})
		busyState:set(true)
		-- (the shared send every tool's build goes through)
		((require "network_tools_1::/gui/construction/tools/shared/ntools_options.script.tl" as {string : any}).send as function(Command<WorldBuildProposalCommandData>, function(WorldBuildProposalCommandData, boolean)))(cmd, function(__ : WorldBuildProposalCommandData, success : boolean)
			if not success then
				do ((require "network_tools_1::/gui/construction/tools/shared/ntools_debug.script.tl" as {string : any}).log as function(string))("[network_tools] Set slope: build failed") end
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
	padMod.actions(pad, _("Pick segment / grab handle"), function() params.abort() end, _("Leave the tool"))

	local actionFn = function() : TreeNodeId
		padMod.trackLayer(pad)
		local crosshair, circle = padMod.crosshair(pad)
		if busy then
			return builtin.ActionDescriptor{
				tool = "construction-menu-perks",
				onBack = function() params.abort() end,
				crosshair = crosshair,
				terrainCirclePolicy = circle,
				children = { tooltip(_("Building..."), true, false) },
			}
		end
		local children : {TreeNodeId} = {
			builtin.Selector(padMod.selector(pad, {
				onSelect = function(entity : Engine.Entity, __ : {integer}, __ : Gui.SelectionDetails) : boolean
					-- a click on the handle is a drag, not a selection
					local cx, cy = handles.cursor()
					if dragging ~= 0 or (cx and handles.hit(handleList, cx, cy) > 0) then return true end
					if not getEdge(entity) then return false end
					costState:set(0)
					errorState:set("")
					chainState:set(chain_util.click(chain, entity))
					return true
				end,
				onProcessMouseEvent = function(evt : Gui.Mouse.Event) : boolean
					return handles.mouse(evt, dragCtl)
				end,
				filter = isEdge,
			}) as Builtin.SelectorParam),
		}
		if proposal then
			local id = "ntools_slope," .. tostring(mode) .. "," .. tostring(arch) .. "," .. tostring(ein) .. "," .. tostring(eout)
			for _, l in ipairs(chain) do id = id .. "," .. tostring(l.edge) end
			children[#children + 1] = preview.viewer{
				proposal = proposal,
				anarchy = anarchy,
				noTags = true,   -- (the selected segments carry this tool's own gradient tags)
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
			.. "   " .. _("Length") .. ": " .. string.format("%.0f m", res.length)
			.. "   " .. _("Rise") .. ": " .. string.format("%+.1f m", res.rise)
			.. "\n" .. _("Gradient") .. ": " .. string.format("%.1f %%", res.length > 0 and math.abs(res.rise) / res.length * 100 or 0)
			.. "   " .. _("Steepest") .. ": " .. string.format("%.1f %%", res.maxGrade)
		if #chain == 0 then
			children[#children + 1] = tooltip(_("Click a road or track segment to start the stretch"), false, false)
		elseif res.why then
			children[#children + 1] = tooltip(res.why .. "\n" .. info, false, true)
		elseif not proposal then
			children[#children + 1] = tooltip(_("This stretch can't be sloped") .. "\n" .. info, false, true)
		elseif blocked then
			children[#children + 1] = tooltip(errorState:old() .. "\n" .. info, false, true, costState:old())
		else
			children[#children + 1] = tooltip(_("Click more segments to extend, the first / last to remove. Press Build to apply") .. "\n" .. info, true, false, costState:old())
		end

		local highlighted : {Engine.Entity} = {}
		for _, l in ipairs(chain) do highlighted[#highlighted + 1] = l.edge end
		-- underground view (panel option, all tools)
		local under = ((require "network_tools_1::/gui/construction/tools/shared/ntools_options.script.tl" as {string : any}).layerNode as function() : TreeNodeId)()
		if under then children[#children + 1] = under end
		return builtin.ActionDescriptor{
			tool = "construction-menu-perks",
			onBack = function() params.abort() end,
			highlightedEntities = highlighted,
			crosshair = crosshair,
			terrainCirclePolicy = circle,
			children = (function() : {TreeNodeId}
				local list = withHandleOverlay(children)
				local tags = labels.node()
				if tags then list[#list + 1] = tags end
				-- Anarchy preview strips the handle overlay didn't draw (no handles in Linear)
				local lo = preview.leftover()
				if lo then list[#list + 1] = lo end
				return list
			end)(),
		}
	end

	params.setActionFn(actionFn, "NtoolsSlopeAction")
	return padMod.anchor(pad)
end)

return {
	init = init,
	opts = opts,
	SlopeActionRecipe = SlopeActionRecipe,
}
