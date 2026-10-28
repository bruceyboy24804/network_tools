-- Network Tools: Parallel (modelled on Network Multitool's CreateParallel for Cities: Skylines 1).
-- Select a stretch of road or track, then build a copy beside it at a chosen offset / height.
--
-- Selection: click a segment to start; click a segment joining either end to extend; click a
-- segment further away to add the whole path to it; click the first / last segment to remove it.
--
-- Loaded by the connect tool (ntools_connect_tool.script.tl), which runs it inside the Network
-- Tools panel. The geometry helpers and the state shared with the other tools (network picker,
-- Anarchy, the panel's Build button) stay in the connect tool and are handed over once by init().

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
local leave = require "network_tools_1::/gui/construction/tools/shared/ntools_leave.script.tl" as function(any)

local record NetUtil
	isProtectedNode : function(node : Engine.Entity) : boolean
	whyNotReplaceable : function(edge : Engine.Entity) : string
	configNodesFor : function(removedEdges : {Engine.Entity}, extraNodes? : {Engine.Entity}) : {Engine.Entity}
	isCrossingNode : function(node : Engine.Entity) : boolean
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

-- in-world tags of this tool's own: the gap to the original (shared/ntools_labels)
local record LabelRow
	icon : string
	text : string
end
local record LabelPoint
	x : number
	y : number
	z : number
	rows : {LabelRow}
end
local record Labels
	set : function(tags : {Engine.Entity : any}, points? : {LabelPoint})
	icons : {string : string}
end
local labels = require "network_tools_1::/gui/construction/tools/shared/ntools_labels.script.tl" as Labels

-- in-world handles (shared kit) and the curve helper they need
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

-- diagnostic traces: only with ntools_debug's DEBUG on
local dbg = (require "network_tools_1::/gui/construction/tools/shared/ntools_debug.script.tl" as {string : any}).log as function(string)

dbg("[network_tools] parallel tool script loaded (v39: Connect chain merge)")

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

local record UiState
	canBuild : boolean
end

-- What the connect tool shares with this one (see init()).
local record Host
	p3 : function(number, number, number) : P3
	clamp : function(number, number, number) : number
	dot2 : function(number, number, number, number) : number
	norm2 : function(number, number) : number, number, number
	getEdge : function(Engine.Entity) : Engine.Component.BaseEdge
	getNodePos : function(Engine.Entity) : P3
	isEdge : function(Engine.Entity) : boolean
	sanitizePieces : function({Piece}) : {Piece}
	vec3 : function(P3) : Vec3f
	laneWidth : function({LaneConfig}) : number
	templateById : function(integer) : StreetTemplate
	templateByName : function(string) : StreetTemplate
	applyNetwork : function(Proposal.SegmentAndEntity, boolean) : boolean
	fmtLen : function(number) : string
	tooltip : function(message : string, good : boolean, bad : boolean, cost? : integer) : TreeNodeId
	shortcutHandler : function(handler : function(), enabled : function() : (boolean), prompt? : string, repeatPresses? : boolean) : React.IaHandler
	safeUseInputAction : function(string, React.IaHandler) : boolean
	precise : function() : boolean
	networkId : function() : integer    -- the panel's network pick (nil = same as selected)
	anarchy : function() : boolean
	levelCrossingType : function() : integer   -- railroad crossing type from the toolbar (nil = none)
	ui : UiState                         -- the connect tool's UI state table (canBuild drives Build)
	toolbarEvents : {string}
end

local p3 : function(number, number, number) : P3
local clamp : function(number, number, number) : number
local dot2 : function(number, number, number, number) : number
local norm2 : function(number, number) : number, number, number
local getEdge : function(Engine.Entity) : Engine.Component.BaseEdge
local getNodePos : function(Engine.Entity) : P3
local isEdge : function(Engine.Entity) : boolean
local sanitizePieces : function({Piece}) : {Piece}
local vec3 : function(P3) : Vec3f
local laneWidth : function({LaneConfig}) : number
local templateById : function(integer) : StreetTemplate
local templateByName : function(string) : StreetTemplate
local applyNetwork : function(Proposal.SegmentAndEntity, boolean) : boolean
local fmtLen : function(number) : string
local tooltip : function(message : string, good : boolean, bad : boolean, cost? : integer) : TreeNodeId
local shortcutHandler : function(handler : function(), enabled : function() : (boolean), prompt? : string, repeatPresses? : boolean) : React.IaHandler
local safeUseInputAction : function(string, React.IaHandler) : boolean
local precise : function() : boolean
local g_host : Host = nil

local function init(host : Host)
	g_host = host
	p3, clamp, dot2, norm2 = host.p3, host.clamp, host.dot2, host.norm2
	getEdge, getNodePos, isEdge = host.getEdge, host.getNodePos, host.isEdge
	sanitizePieces, vec3 = host.sanitizePieces, host.vec3
	laneWidth, templateById, templateByName, applyNetwork = host.laneWidth, host.templateById, host.templateByName, host.applyNetwork
	fmtLen, tooltip = host.fmtLen, host.tooltip
	shortcutHandler, safeUseInputAction, precise = host.shortcutHandler, host.safeUseInputAction, host.precise
end

local record ChainLink
	edge : Engine.Entity
	fwd : boolean      -- true: the chain runs node0 -> node1 along this edge
end

-- options shared with the panel (nil offset = automatic: the width of the selected road)
local record Options
	offset : number
	autoOffset : number
	side : integer     -- +1 = left of the chain direction, -1 = right, 0 = both sides
	height : number
	crossings : boolean   -- join existing roads / tracks the copy runs over
	connectEnds : boolean -- join the copy's ends to the network where they land
	count : integer       -- copies side by side (copy k sits k x offset away); built one after another
end
local opts : Options = { offset = nil, autoOffset = 5.0, side = 1, height = 0.0, crossings = true, connectEnds = true, count = 1 }

-- bridges where the copy runs over water or high above the ground (shared with the other tools)
local record Terrain
	upgradeSegment : function(seg : Proposal.SegmentAndEntity, isTrack : boolean, bridgeId? : integer, tunnelId? : integer, noShore? : boolean) : string
end
local terrain = require "network_tools_1::/gui/construction/tools/shared/ntools_terrain.script.tl" as Terrain
local PAR_MAX_COUNT = 8

local PAR_MIN_OFFSET, PAR_MAX_OFFSET = 0.5, 500
local PAR_PATH_SEARCH_LIMIT = 4000

local function edgeWidth(edge : Engine.Component.BaseEdge) : number
	local w = 0.0
	for _, lc in ipairs(edge.laneConfigs or {}) do
		w = w + (lc.width or 0)
	end
	return w
end

local function linkEnds(link : ChainLink) : Engine.Entity, Engine.Entity
	local e = getEdge(link.edge)
	if not e then return nil, nil end
	if link.fwd then return e.node0, e.node1 end
	return e.node1, e.node0
end

-- The link's curve in chain direction: start position, start tangent, end position, end tangent.
local function linkCurve(link : ChainLink) : P3, P3, P3, P3
	local e = getEdge(link.edge)
	local a, b = getNodePos(e.node0), getNodePos(e.node1)
	local t0 = p3(e.tangent0.x, e.tangent0.y, e.tangent0.z)
	local t1 = p3(e.tangent1.x, e.tangent1.y, e.tangent1.z)
	if link.fwd then
		return a, t0, b, t1
	end
	return b, p3(-t1.x, -t1.y, -t1.z), a, p3(-t0.x, -t0.y, -t0.z)
end

local record PathStep
	node : Engine.Entity
	edge : Engine.Entity
	fwd : boolean
end

-- Shortest path (by segment count) from `fromNode` to `targetEdge` over segments of the same
-- road type. Returns the links in order, ending with the target segment, or nil.
local function findPath(fromNode : Engine.Entity, targetEdge : Engine.Entity, roadType : any, exclude : {Engine.Entity : boolean}) : {ChainLink}
	local te = getEdge(targetEdge)
	if not te then return nil end
	local prev : {Engine.Entity : PathStep} = { [fromNode] = { node = nil } }
	local queue : {Engine.Entity} = { fromNode }
	local head = 1
	while head <= #queue and head <= PAR_PATH_SEARCH_LIMIT do
		local n = queue[head]
		head = head + 1
		if n == te.node0 or n == te.node1 then
			local links : {ChainLink} = {}
			local cur = n
			while cur ~= fromNode do
				local step = prev[cur]
				table.insert(links, 1, { edge = step.edge, fwd = step.fwd })
				cur = step.node
			end
			links[#links + 1] = { edge = targetEdge, fwd = te.node0 == n }
			return links
		end
		local ok, segs = pcall(function() : {Engine.Entity}
			return api.engine.system.streetSystem.getNodeSegments(n)
		end)
		for _, s in ipairs(ok and segs or {}) do
			if s ~= targetEdge and not exclude[s] then
				local se = getEdge(s)
				if se and se.roadType == roadType then
					local other = se.node0 == n and se.node1 or se.node0
					if prev[other] == nil then
						prev[other] = { node = n, edge = s, fwd = se.node0 == n }
						queue[#queue + 1] = other
					end
				end
			end
		end
	end
	return nil
end

-- Offset every link of the chain sideways by `offset` (positive = left) and raise it by `dz`.
-- Corners between links are mitred so the copy follows the bend without gaps.
local function parallelPieces(chain : {ChainLink}, offset : number, dz : number) : {Piece}
	local m = #chain
	if m == 0 then return nil end
	local p0s : {P3} = {}
	local t0s : {P3} = {}
	local p1s : {P3} = {}
	local t1s : {P3} = {}
	for i, link in ipairs(chain) do
		p0s[i], t0s[i], p1s[i], t1s[i] = linkCurve(link)
	end
	local function leftNormal(t : P3) : number, number
		local x, y = norm2(-t.y, t.x)
		return x, y
	end
	local q : {P3} = {}
	for k = 0, m do
		local base : P3
		local nx, ny : number, number
		if k == 0 then
			base = p0s[1]
			nx, ny = leftNormal(t0s[1])
		elseif k == m then
			base = p1s[m]
			nx, ny = leftNormal(t1s[m])
		else
			base = p1s[k]
			local ax, ay = leftNormal(t1s[k])
			local bx, by = leftNormal(t0s[k + 1])
			local mx, my, ml = norm2(ax + bx, ay + by)
			if ml < 1e-3 then
				nx, ny = ax, ay
			else
				-- mitre: push the corner out so both neighbouring pieces keep their offset
				local c = math.max(0.35, dot2(mx, my, ax, ay))
				nx, ny = mx / c, my / c
			end
		end
		q[k + 1] = p3(base.x + nx * offset, base.y + ny * offset, base.z + dz)
	end
	local pieces : {Piece} = {}
	for i = 1, m do
		local oldLen = math.sqrt((p1s[i].x - p0s[i].x) ^ 2 + (p1s[i].y - p0s[i].y) ^ 2)
		local newLen = math.sqrt((q[i + 1].x - q[i].x) ^ 2 + (q[i + 1].y - q[i].y) ^ 2)
		-- scaling the tangents with the chord keeps arcs circular (radius r -> r +- offset)
		local s = oldLen > 0.1 and newLen / oldLen or 1
		pieces[i] = {
			p0 = q[i], t0 = p3(t0s[i].x * s, t0s[i].y * s, t0s[i].z),
			p1 = q[i + 1], t1 = p3(t1s[i].x * s, t1s[i].y * s, t1s[i].z),
		}
	end
	return pieces
end

----------------------------------------------------------------------------------------------------
-- Crossings: where the copy runs over an existing road or track at the same level, both are split
-- there and share a new node (a level crossing where road meets rail, a junction otherwise).
-- TF3 has no "split edge" command, so a crossed edge is removed and re-added in pieces.

local CROSS_Z_TOLERANCE = 5.0   -- metres: closer than this in height = same level, so join them
                                -- (the copy's pieces at the joint are regraded to meet it evenly)
local CROSS_NODE_SNAP = 3.0     -- metres: a crossing this close to an existing node joins at that node
local CROSS_MIN_PIECE = 1.5     -- metres: shortest piece a split may leave on the copy
local JOINT_SNAP = 8.0          -- metres: a crossing this close to one of the copy's own nodes moves
                                -- that node onto the crossing instead of splitting next to it
local CROSS_SEARCH_MARGIN = 400 -- metres added to the search circle (longest segment we expect / 2, and some)
local JOINT_ROAD_MARGIN = 2.0  -- metres beyond the crossed road's edge: a copy node this close moves
                                -- onto the crossing
local CROSS_DEDUPE = 2.0       -- metres: hits closer than this on one edge are the same crossing

local record Crossing
	piece : integer            -- index of the copy's piece
	tNew : number              -- parameter on that piece
	edge : Engine.Entity       -- existing edge crossed
	tOld : number              -- parameter on the existing edge
	pos : P3                   -- where the shared node goes
	node : Engine.Entity       -- existing node reused (snapped), or nil = new node
	id : Engine.Entity         -- entity id of the shared node in the proposal
	joint : integer            -- the copy's own node (0 .. m) moved onto the crossing, or nil = split the copy
end

local function hermitePoint(pc : Piece, t : number) : P3
	local t2, t3 = t * t, t * t * t
	local h00, h10, h01, h11 = 2 * t3 - 3 * t2 + 1, t3 - 2 * t2 + t, -2 * t3 + 3 * t2, t3 - t2
	return p3(h00 * pc.p0.x + h10 * pc.t0.x + h01 * pc.p1.x + h11 * pc.t1.x,
		h00 * pc.p0.y + h10 * pc.t0.y + h01 * pc.p1.y + h11 * pc.t1.y,
		h00 * pc.p0.z + h10 * pc.t0.z + h01 * pc.p1.z + h11 * pc.t1.z)
end

local function hermiteTangent(pc : Piece, t : number) : P3
	local t2 = t * t
	local d00, d10, d01, d11 = 6 * t2 - 6 * t, 3 * t2 - 4 * t + 1, -6 * t2 + 6 * t, 3 * t2 - 2 * t
	return p3(d00 * pc.p0.x + d10 * pc.t0.x + d01 * pc.p1.x + d11 * pc.t1.x,
		d00 * pc.p0.y + d10 * pc.t0.y + d01 * pc.p1.y + d11 * pc.t1.y,
		d00 * pc.p0.z + d10 * pc.t0.z + d01 * pc.p1.z + d11 * pc.t1.z)
end

local function scaled(v : P3, s : number) : P3
	return p3(v.x * s, v.y * s, v.z * s)
end

local function chordLength(pc : Piece) : number
	return math.sqrt((pc.p1.x - pc.p0.x) ^ 2 + (pc.p1.y - pc.p0.y) ^ 2 + (pc.p1.z - pc.p0.z) ^ 2)
end

-- Split a cubic Hermite piece at sorted parameters (exact: the halves trace the same curve).
local function splitPiece(pc : Piece, ts : {number}) : {Piece}
	local out : {Piece} = {}
	local cur = pc
	local done = 0.0
	for _, t in ipairs(ts) do
		local lt = (t - done) / (1 - done)
		local P = hermitePoint(cur, lt)
		local D = hermiteTangent(cur, lt)
		out[#out + 1] = { p0 = cur.p0, t0 = scaled(cur.t0, lt), p1 = P, t1 = scaled(D, lt) }
		cur = { p0 = P, t0 = scaled(D, 1 - lt), p1 = cur.p1, t1 = scaled(cur.t1, 1 - lt) }
		done = t
	end
	out[#out + 1] = cur
	return out
end

local function samplePiece(pc : Piece) : {P3}, integer
	local n = math.floor(math.max(4, math.min(48, math.ceil(chordLength(pc) / 6))))
	local pts : {P3} = {}
	for k = 0, n do pts[k + 1] = hermitePoint(pc, k / n) end
	return pts, n
end

-- Intersection parameters (u on ab, v on cd) of two 2D segments, or nil.
local function segCross(a : P3, b : P3, c : P3, d : P3) : number, number
	local rx, ry = b.x - a.x, b.y - a.y
	local sx, sy = d.x - c.x, d.y - c.y
	local den = rx * sy - ry * sx
	if math.abs(den) < 1e-9 then return nil, nil end
	local qx, qy = c.x - a.x, c.y - a.y
	local u = (qx * sy - qy * sx) / den
	local v = (qx * ry - qy * rx) / den
	if u < 0 or u > 1 or v < 0 or v > 1 then return nil, nil end
	return u, v
end

local function edgePiece(e : Engine.Component.BaseEdge) : Piece
	return {
		p0 = p3(e.position0.x, e.position0.y, e.position0.z), t0 = p3(e.tangent0.x, e.tangent0.y, e.tangent0.z),
		p1 = p3(e.position1.x, e.position1.y, e.position1.z), t1 = p3(e.tangent1.x, e.tangent1.y, e.tangent1.z),
	}
end

-- Every segment in the world with the box of its Bezier control points (a Hermite curve never
-- leaves that box). api.engine.util.octree.findEntitiesInCircle(BASE_EDGE) was tried first and
-- returned only streets near a track it should have found, so this walks all BASE_EDGEs instead,
-- cached for a few seconds because the preview rebuilds the proposal every frame.
local record EdgeBox
	edge : Engine.Entity
	minX : number
	maxX : number
	minY : number
	maxY : number
end
local EDGE_INDEX_TTL = 3.0      -- seconds
local g_edgeIndex : {EdgeBox} = nil
local g_edgeIndexTime = -math.huge

local function now() : number
	local ok, t = pcall(function() : number return os.clock() end)
	return ok and t or 0
end

local function edgeIndex() : {EdgeBox}
	local t = now()
	if g_edgeIndex and t - g_edgeIndexTime < EDGE_INDEX_TTL and t >= g_edgeIndexTime then
		return g_edgeIndex
	end
	local out : {EdgeBox} = {}
	local nTrack = 0
	local ok, err = pcall(function()
		for _, e in ipairs(api.engine.getEntitiesWithComponent(api.type.ComponentType.BASE_EDGE)) do
			local be = getEdge(e)
			if be then
				local x0, x3 = be.position0.x, be.position1.x
				local x1, x2 = x0 + be.tangent0.x / 3, x3 - be.tangent1.x / 3
				local y0, y3 = be.position0.y, be.position1.y
				local y1, y2 = y0 + be.tangent0.y / 3, y3 - be.tangent1.y / 3
				out[#out + 1] = {
					edge = e,
					minX = math.min(x0, x1, x2, x3), maxX = math.max(x0, x1, x2, x3),
					minY = math.min(y0, y1, y2, y3), maxY = math.max(y0, y1, y2, y3),
				}
				if be.roadType == api.type["enum"].RoadType.TRACK then nTrack = nTrack + 1 end
			end
		end
	end)
	if not ok then
		dbg("[network_tools] Parallel: edge index failed: " .. tostring(err))
	elseif not g_edgeIndex then
		dbg("[network_tools] Parallel: edge index built: " .. tostring(#out) .. " segments, " .. tostring(nTrack) .. " track")
	end
	g_edgeIndex = out
	g_edgeIndexTime = t
	return out
end

local g_searchFailLogged = false
-- diagnostics for the log: what the edge search saw (reset per proposal)
local g_diag : {string} = {}
local g_diagEdge : Engine.Entity = nil

-- level crossings / configured junctions can't have a segment removed (see ntools_net_util)
local isProtectedNode = net_util.isProtectedNode

-- An end node that keeps a crossed segment from being split (a level crossing doesn't: the
-- proposal re-creates it, net_util.rebuildCrossings)
local function blocksSplit(node : Engine.Entity) : boolean
	return isProtectedNode(node)
end

-- A node the copy must not be joined onto: protected, or a level crossing (adding a segment to a
-- crossing is not something the re-creation covers)
local function blocksJoin(node : Engine.Entity) : boolean
	return isProtectedNode(node) or net_util.isCrossingNode(node)
end

-- Signals on a crossed track are carried over to its pieces: each is removed (edgeObjectsToRemove)
-- and placed again on the piece it falls on, same model, facing and one-way (as the Automatic Signal
-- Spacing mod re-places signals). Stops and waypoints (lines refer to them) still block the split.
local SIGNAL_CLEAR = 4.0        -- metres: a signal closer than this to the crossing blocks it

local record SignalCopy
	entity : Engine.Entity
	param : number             -- 0..1 along the old edge
	model : string
	left : boolean
	oneWay : boolean
end

-- The edge's signals as they'd be placed again, or nil and why the edge can't be split
-- (shared with Auto-signal: shared/ntools_edge_signals)
local readSignals = (require "network_tools_1::/gui/construction/tools/shared/ntools_edge_signals.script.tl" as {string : any}).readSignals
	as function(e : Engine.Entity, oe : Engine.Component.BaseEdge) : {SignalCopy}, string

-- Where the copy's pieces cross existing edges at the same level. Returns the crossings and how
-- many were skipped (edge carries signals / other objects, or the crossing is too close to the
-- end of a piece of the copy).
local function findCrossings(chain : {ChainLink}, pieces : {Piece}) : {Crossing}, integer, {string}
	local NORMAL = api.type["enum"].BaseEdgeType.NORMAL
	local exclude : {Engine.Entity : boolean} = {}
	for _, l in ipairs(chain) do exclude[l.edge] = true end
	local crossings : {Crossing} = {}
	local skipped = 0
	local seenSkip : {string : boolean} = {}
	local reasons : {string} = {}
	local function skip(key : string, why : string)
		if not seenSkip[key] then
			seenSkip[key] = true
			skipped = skipped + 1
			reasons[#reasons + 1] = key .. " " .. why
		end
	end
	for i, pc in ipairs(pieces) do
		local src = getEdge(chain[i].edge)
		-- a bridge / tunnel copy passes over / under everything
		if src and src.type == NORMAL then
			local pts, n = samplePiece(pc)
			local minX, minY, maxX, maxY = math.huge, math.huge, -math.huge, -math.huge
			for _, q in ipairs(pts) do
				minX, maxX = math.min(minX, q.x), math.max(maxX, q.x)
				minY, maxY = math.min(minY, q.y), math.max(maxY, q.y)
			end
			-- candidates: segments the octree lists near the piece, plus every segment attached to a
			-- node near it. The octree's BASE_EDGE search missed a track the copy crossed, and
			-- BASE_EDGE can't be iterated ("Cannot loop over this component type"); a segment
			-- crossing the piece has its end nodes within half its length of it, hence the margin.
			local cx, cy = (minX + maxX) / 2, (minY + maxY) / 2
			local r = math.sqrt((maxX - minX) ^ 2 + (maxY - minY) ^ 2) / 2 + CROSS_SEARCH_MARGIN
			local found : {Engine.Entity} = {}
			local seen : {Engine.Entity : boolean} = {}
			local function addEdge(e : Engine.Entity)
				if e and not seen[e] then
					seen[e] = true
					found[#found + 1] = e
				end
			end
			local center = api.type.Vec2f.new(cx, cy)
			local okE, edgesNear = pcall(function() : {Engine.Entity}
				return api.engine.util.octree.findEntitiesInCircle(center, r, api.type.ComponentType.BASE_EDGE)
			end)
			local okN, nodesNear = pcall(function() : {Engine.Entity}
				return api.engine.util.octree.findEntitiesInCircle(center, r, api.type.ComponentType.BASE_NODE)
			end)
			if (not okE or not okN) and not g_searchFailLogged then
				g_searchFailLogged = true
				dbg("[network_tools] Parallel: search failed: edges " .. tostring(okE and "ok" or edgesNear) .. ", nodes " .. tostring(okN and "ok" or nodesNear))
			end
			for _, e in ipairs(okE and edgesNear or {}) do addEdge(e) end
			local nNodes = 0
			for _, nd in ipairs(okN and nodesNear or {}) do
				nNodes = nNodes + 1
				local okS, segs = pcall(function() : {Engine.Entity}
					return api.engine.system.streetSystem.getNodeSegments(nd)
				end)
				for _, s in ipairs(okS and segs or {}) do addEdge(s) end
			end
			local ok = true
			local newLen = chordLength(pc)
			g_diag[#g_diag + 1] = "piece " .. tostring(i) .. ": " .. tostring(#found) .. " candidate edges (" .. tostring(#(okE and edgesNear or {})) .. " from edge search, " .. tostring(nNodes) .. " nodes)"
			for _, e in ipairs(found) do
				local oe = not exclude[e] and getEdge(e) or nil
				-- quick reject: a Hermite curve stays inside the box of its Bezier control points
				local near = false
				if oe and oe.type == NORMAL then
					local qp = edgePiece(oe)
					local xs = { qp.p0.x, qp.p0.x + qp.t0.x / 3, qp.p1.x - qp.t1.x / 3, qp.p1.x }
					local ys = { qp.p0.y, qp.p0.y + qp.t0.y / 3, qp.p1.y - qp.t1.y / 3, qp.p1.y }
					near = math.max(xs[1], xs[2], xs[3], xs[4]) >= minX and math.min(xs[1], xs[2], xs[3], xs[4]) <= maxX
						and math.max(ys[1], ys[2], ys[3], ys[4]) >= minY and math.min(ys[1], ys[2], ys[3], ys[4]) <= maxY
				end
				local hits, bestDz = 0, math.huge
				if oe and (near or oe.roadType == api.type["enum"].RoadType.TRACK) then
					g_diagEdge = e
				end
				if near then
					local op = edgePiece(oe)
					local opts2, on = samplePiece(op)
					local oldLen = chordLength(op)
					for a = 1, n do
						for b = 1, on do
							local u, v = segCross(pts[a], pts[a + 1], opts2[b], opts2[b + 1])
							if u then
								local tNew, tOld = (a - 1 + u) / n, (b - 1 + v) / on
								local pn, po = hermitePoint(pc, tNew), hermitePoint(op, tOld)
								local key = tostring(e) .. "@" .. tostring(math.floor(tOld * oldLen / CROSS_DEDUPE))
								hits = hits + 1
								bestDz = math.min(bestDz, math.abs(pn.z - po.z))
								if math.abs(pn.z - po.z) < CROSS_Z_TOLERANCE then
									local snapNode : Engine.Entity = nil
									if tOld * oldLen < CROSS_NODE_SNAP then
										snapNode = oe.node0
									elseif (1 - tOld) * oldLen < CROSS_NODE_SNAP then
										snapNode = oe.node1
									end
									local sigs, sigWhy : {SignalCopy}, string = {}, nil
									if #(oe.objects or {}) > 0 then
										local okS, s, w = pcall(readSignals, e, oe)
										if not okS then sigs, sigWhy = nil, "objects: " .. tostring(s)
										else sigs, sigWhy = s, w end
									end
									local tooClose = false
									for _, sc in ipairs(sigs or {}) do
										if math.abs(sc.param - tOld) * oldLen < SIGNAL_CLEAR then tooClose = true end
									end
									if not sigs then
										skip(key, sigWhy)   -- splitting would delete them
									elseif tooClose then
										skip(key, "signal at the crossing")
									elseif snapNode and blocksJoin(snapNode) then
										skip(key, "next to a level crossing node / hand-edited junction")   -- joining there would add a segment to it
									elseif not snapNode and (blocksSplit(oe.node0) or blocksSplit(oe.node1)) then
										skip(key, "end node has hand-edited lanes / lights")   -- splitting would throw that configuration away (a plain level crossing is re-created instead)
									else
										-- next to one of the copy's own nodes: move that node onto the crossing
										-- (splitting beside it would leave a sliver the game refuses)
										-- or one standing on / beside the crossed road (the game's own tool leaves
										-- no node there: one by the road's edge was refused)
										local function onRoad(q : P3) : boolean
											local reach = edgeWidth(oe) / 2 + JOINT_ROAD_MARGIN
											for b2 = 0, on do
												local s = opts2[b2 + 1]
												if s and (s.x - q.x) ^ 2 + (s.y - q.y) ^ 2 < reach * reach then return true end
											end
											return false
										end
										local joint : integer = nil
										if tNew * newLen < JOINT_SNAP then
											joint = i - 1
										elseif (1 - tNew) * newLen < JOINT_SNAP then
											joint = i
										elseif tNew < 0.5 and onRoad(pc.p0) then
											joint = i - 1
										elseif tNew >= 0.5 and onRoad(pc.p1) then
											joint = i
										end
										local dup = false
										for _, c in ipairs(crossings) do
											if c.edge == e and math.abs(c.tOld - tOld) * oldLen < CROSS_DEDUPE then dup = true end
										end
										if not dup then
											-- the crossing sits halfway between the two heights, as the game's track
										-- tool puts it (it was the existing track's height: the copy then dipped
										-- into a sharp V at the crossing, which the game refused)
										-- A copied track over an existing road: the crossing takes the track's height
										-- and the road bends to it, as the game's tool does (halfway pulled the track
										-- into a dip it refused)
										local TRACK = api.type["enum"].RoadType.TRACK
										local z = (pn.z + po.z) / 2
										if src.roadType == TRACK and oe.roadType ~= TRACK then z = pn.z end
										local pos = snapNode and getNodePos(snapNode) or p3(po.x, po.y, z)
											crossings[#crossings + 1] = { piece = i, tNew = tNew, edge = e, tOld = tOld, pos = pos, node = snapNode, joint = joint }
										end
									end
								end
							end
						end
					end
				end
				if g_diagEdge == e then
					g_diagEdge = nil
					g_diag[#g_diag + 1] = "  edge " .. tostring(e) .. (oe.roadType == api.type["enum"].RoadType.TRACK and " track" or " street")
						.. " type=" .. tostring(oe.type) .. " near=" .. tostring(near) .. " hits=" .. tostring(hits)
						.. (hits > 0 and (" dz=" .. string.format("%.1f", bestDz)) or "")
				end
			end
		end
	end
	return crossings, skipped, reasons
end

local function setGeometry(seg : Proposal.SegmentAndEntity, n0 : Engine.Entity, n1 : Engine.Entity, pc : Piece, reversed : boolean)
	if not reversed then
		seg.comp.node0, seg.comp.node1 = n0, n1
		seg.comp.position0, seg.comp.position1 = vec3(pc.p0), vec3(pc.p1)
		seg.comp.tangent0, seg.comp.tangent1 = vec3(pc.t0), vec3(pc.t1)
	else
		seg.comp.node0, seg.comp.node1 = n1, n0
		seg.comp.position0, seg.comp.position1 = vec3(pc.p1), vec3(pc.p0)
		seg.comp.tangent0 = vec3(scaled(pc.t1, -1))
		seg.comp.tangent1 = vec3(scaled(pc.t0, -1))
	end
end

local g_lastCrossingLog = ""
local g_skipReasons : {string} = {}
-- set by copyProposal(): the copy runs against its source (the other carriageway of a dual road)
local g_flipCopy = false

local function byTNew(a : Crossing, b : Crossing) : boolean return a.tNew < b.tNew end
local function byTOld(a : Crossing, b : Crossing) : boolean return a.tOld < b.tOld end

-- New chain of nodes and segments; each segment copies its source (type, lanes, bridge / tunnel)
-- and keeps the source's direction so one-way roads stay the right way round. With `crossings`,
-- existing roads / tracks it runs over are joined to it (see findCrossings).
-- Returns the proposal, the number of crossings made and the number skipped.
-- Ends of the copy: join the network where they land (like the vanilla builder snapping) -
-- onto an existing node close by, or else by splitting the existing segment under the end.
local END_NODE_SNAP = 6.0     -- metres: an existing node this close takes the end
local END_EDGE_SNAP = 3.0     -- metres beyond the edge of a road: an end on / next to it joins it
local g_lastJoinLog : string = nil
local END_SEARCH = 400       -- metres searched for segments (the octree matches by position)

local record EndJoin
	k : integer               -- 0 = start of the copy, m = its end
	node : Engine.Entity      -- existing node the copy ends on, or nil
	edge : Engine.Entity      -- existing segment split under the end, or nil
	tOld : number
	pos : P3
	ahead : boolean           -- a loose track end straight ahead: the copy extended to it
end

local END_AHEAD = 80          -- metres: a loose track end this far straight ahead takes the end
local END_AHEAD_LAT = 2.0     -- ... lined up within this

local function findEndJoin(q : P3, excludeEdges : {Engine.Entity : boolean}, excludeNodes : {Engine.Entity : boolean}, ahead? : P3) : EndJoin
	local NORMAL = api.type["enum"].BaseEdgeType.NORMAL
	local center = api.type.Vec2f.new(q.x, q.y)
	local function near(r : number, ct : Engine.ComponentType) : {Engine.Entity}
		local ok, list = pcall(function() : {Engine.Entity}
			return api.engine.util.octree.findEntitiesInCircle(center, r, ct)
		end)
		return ok and list or {}
	end
	-- 1. an existing node close by
	local bestNode : Engine.Entity = nil
	local bestD = END_NODE_SNAP * END_NODE_SNAP
	for _, n in ipairs(near(END_NODE_SNAP + 1, api.type.ComponentType.BASE_NODE)) do
		if not excludeNodes[n] then
			local p = getNodePos(n)
			if p and math.abs(p.z - q.z) < CROSS_Z_TOLERANCE then
				local d = (p.x - q.x) ^ 2 + (p.y - q.y) ^ 2
				if d <= bestD and not blocksJoin(n) then bestNode, bestD = n, d end
			end
		end
	end
	if bestNode then
		return { node = bestNode, pos = getNodePos(bestNode) }
	end
	-- 1b. a loose track end straight ahead (a station's track, a dead end): the copy carries on to it
	-- - a line doubled up to a station whose track ends are staggered reaches its track
	if ahead then
		local bestA = END_AHEAD
		local found : Engine.Entity = nil
		for _, n in ipairs(near(END_AHEAD + 1, api.type.ComponentType.BASE_NODE)) do
			local p = not excludeNodes[n] and getNodePos(n) or nil
			if p and math.abs(p.z - q.z) < CROSS_Z_TOLERANCE * 2 then
				local dx, dy = p.x - q.x, p.y - q.y
				local along = dx * ahead.x + dy * ahead.y
				local lat = math.abs(-dx * ahead.y + dy * ahead.x)
				if along > 1 and along < bestA and lat < END_AHEAD_LAT and not blocksJoin(n) then
					-- (loose: one segment there, running on the same way)
					local ok, segs = pcall(function() : {Engine.Entity} return api.engine.system.streetSystem.getNodeSegments(n) end)
					local list = ok and segs or {}
					if #list == 1 then
						local se = getEdge(list[1])
						if se then
							local op = edgePiece(se)
							local tg = se.node0 == n and op.t0 or p3(-op.t1.x, -op.t1.y, -op.t1.z)
							local l = math.sqrt(tg.x * tg.x + tg.y * tg.y)
							if l > 1e-6 and (tg.x * ahead.x + tg.y * ahead.y) / l > 0.95 then
								found, bestA = n, along
							end
						end
					end
				end
			end
		end
		if found then
			return { node = found, pos = getNodePos(found), ahead = true }
		end
	end
	-- 2. an existing segment under the end
	local cands : {Engine.Entity} = {}
	local seen : {Engine.Entity : boolean} = {}
	for _, e in ipairs(near(END_SEARCH, api.type.ComponentType.BASE_EDGE)) do
		if not seen[e] then seen[e] = true; cands[#cands + 1] = e end
	end
	for _, n in ipairs(near(END_SEARCH, api.type.ComponentType.BASE_NODE)) do
		local ok, segs = pcall(function() : {Engine.Entity} return api.engine.system.streetSystem.getNodeSegments(n) end)
		for _, e in ipairs(ok and segs or {}) do
			if not seen[e] then seen[e] = true; cands[#cands + 1] = e end
		end
	end
	local best : EndJoin = nil
	local bestDist = math.huge
	for _, e in ipairs(cands) do
		local oe = not excludeEdges[e] and getEdge(e) or nil
		if oe and oe.type == NORMAL then
			local op = edgePiece(oe)
			local tBest, dBest = 0.0, math.huge
			for s = 0, 64 do
				local p = hermitePoint(op, s / 64)
				local d = (p.x - q.x) ^ 2 + (p.y - q.y) ^ 2
				if d < dBest then tBest, dBest = s / 64, d end
			end
			local dist = math.sqrt(dBest)
			local len = chordLength(op)
			local p = hermitePoint(op, tBest)
			-- anywhere on the road surface counts (half its width), plus a little
			if dist < edgeWidth(oe) / 2 + END_EDGE_SNAP and dist < bestDist and math.abs(p.z - q.z) < CROSS_Z_TOLERANCE
				and tBest * len >= CROSS_MIN_PIECE and (1 - tBest) * len >= CROSS_MIN_PIECE
				and net_util.whyNotReplaceable(e) == nil then
				best, bestDist = { edge = e, tOld = tBest, pos = p }, dist
			end
		end
	end
	return best
end

-- Give a piece an even grade between its two end heights. Used on the copy's pieces that meet a
-- joint (crossing / joined end): the joint takes the other road's height, and keeping the copy's
-- old end slopes would climb that difference in a few metres ("Too Much Incline").
local function regrade(pc : Piece)
	local hx, hy = pc.p1.x - pc.p0.x, pc.p1.y - pc.p0.y
	local hChord = math.sqrt(hx * hx + hy * hy)
	if hChord < 0.1 then return end
	local grade = (pc.p1.z - pc.p0.z) / hChord
	local function withGrade(v : P3) : P3
		return p3(v.x, v.y, grade * math.sqrt(v.x * v.x + v.y * v.y))
	end
	pc.t0 = withGrade(pc.t0)
	pc.t1 = withGrade(pc.t1)
end

-- avoid: the end points of copies built before this one (several copies): an end must not join
-- one of them, it would turn the neighbouring copy's end into a switch
local function makeParallelProposal(chain : {ChainLink}, rawPieces : {Piece}, crossings : boolean, connectEnds : boolean, avoid? : {P3}) : SimpleProposal, integer, integer, integer
	local pieces = sanitizePieces(rawPieces)
	if not pieces then return nil, 0, 0, 0 end
	local m = #pieces

	local found : {Crossing} = {}
	local skipped = 0
	if crossings then
		g_diag = {}
		found, skipped, g_skipReasons = findCrossings(chain, pieces)
	end
	-- log when the result changes (the recipe rebuilds the proposal every frame)
	local debugKey = tostring(m) .. "/" .. tostring(#found) .. "/" .. tostring(skipped) .. "/" .. tostring(crossings)
	if debugKey ~= g_lastCrossingLog then
		g_lastCrossingLog = debugKey
		dbg("[network_tools] Parallel: pieces=" .. tostring(m) .. " crossings=" .. tostring(#found) .. " skipped=" .. tostring(skipped) .. " enabled=" .. tostring(crossings) .. (#g_skipReasons > 0 and (" skips: " .. table.concat(g_skipReasons, "; ")) or ""))
		-- the angle each crossing is made at (a very shallow one may be what the game refuses)
		for _, c in ipairs(found) do
			pcall(function()
				local a = hermiteTangent(pieces[c.piece], c.tNew)
				local e = getEdge(c.edge)
				local b = hermiteTangent(edgePiece(e), c.tOld)
				local la, lb = math.sqrt(a.x * a.x + a.y * a.y), math.sqrt(b.x * b.x + b.y * b.y)
				local cosv = math.abs((a.x * b.x + a.y * b.y) / (la * lb))
				local ang = math.deg(math.acos(math.min(1, cosv)))
				dbg(string.format("[network_tools]   crossing with %d at %.1f %.1f: angle %.1f deg%s%s",
					c.edge, c.pos.x, c.pos.y, ang, c.node and (" -> node " .. tostring(c.node)) or "",
					c.joint and (" (moved onto copy node " .. tostring(c.joint) .. ")") or ""))
			end)
		end
		for _, line in ipairs(g_diag) do dbg("[network_tools]   " .. line) end
	end
	-- crossings per piece of the copy, and per existing edge that needs splitting
	local perPiece : {integer : {Crossing}} = {}
	local perEdge : {Engine.Entity : {Crossing}} = {}
	local edgeOrder : {Engine.Entity} = {}
	local jointAt : {integer : Crossing} = {}     -- copy node k -> the crossing it was moved onto
	local movedNode : {integer : boolean} = {}
	local endNode : {integer : Engine.Entity} = {}
	local nJoint = 0
	local kept : {Crossing} = {}
	for _, c in ipairs(found) do
		-- one crossing per copy node; a second one there is dropped
		local drop = c.joint ~= nil and jointAt[c.joint] ~= nil
		if drop then
			-- nothing
		elseif c.joint then
			jointAt[c.joint] = c
			nJoint = nJoint + 1
			movedNode[c.joint] = true
			local k = c.joint
			if k == 0 then
				pieces[1].p0 = c.pos
			elseif k == m then
				pieces[m].p1 = c.pos
			else
				pieces[k].p1 = c.pos
				pieces[k + 1].p0 = c.pos
			end
			if c.node then endNode[k] = c.node end
		else
			perPiece[c.piece] = perPiece[c.piece] or {}
			table.insert(perPiece[c.piece], c)
		end
		if not drop then kept[#kept + 1] = c end
		if not drop and not c.node then
			if not perEdge[c.edge] then
				perEdge[c.edge] = {}
				edgeOrder[#edgeOrder + 1] = c.edge
			end
			table.insert(perEdge[c.edge], c)
		end
	end
	found = kept
	-- a piece whose end moved onto a crossing is shorter / longer than its tangents now: scale them
	-- to its new length (as the game's tool makes them; the old lengths kinked the curve, refused)
	local function fitTangents(pc : Piece)
		local hx, hy = pc.p1.x - pc.p0.x, pc.p1.y - pc.p0.y
		local chord = math.sqrt(hx * hx + hy * hy)
		local function fit(v : P3) : P3
			local h = math.sqrt(v.x * v.x + v.y * v.y)
			if h < 0.01 then return v end
			local s = chord / h
			return p3(v.x * s, v.y * s, v.z * s)
		end
		pc.t0, pc.t1 = fit(pc.t0), fit(pc.t1)
	end
	for k in pairs(movedNode) do
		if k >= 1 then fitTangents(pieces[k]) end
		if k < m then fitTangents(pieces[k + 1]) end
	end
	if nJoint > 0 and not sanitizePieces(pieces) then return nil, 0, 0, 0 end

	-- ends of the copy that join the network (not onto a segment a crossing already splits)
	local joins : {EndJoin} = {}
	local joinedEdgeEnd : {integer : boolean} = {}
	if connectEnds then
		local exE : {Engine.Entity : boolean} = {}
		local exN : {Engine.Entity : boolean} = {}
		for _, l in ipairs(chain) do
			exE[l.edge] = true
			local e = getEdge(l.edge)
			if e then exN[e.node0], exN[e.node1] = true, true end
		end
		for _, c in ipairs(found) do exE[c.edge] = true end
		for _, k in ipairs(m > 0 and { 0, m } or {}) do
			local q = k == 0 and pieces[1].p0 or pieces[m].p1
			-- (the way out of the copy at that end: a loose track end straight ahead joins it too)
			local tq = k == 0 and pieces[1].t0 or pieces[m].t1
			local tl = math.sqrt(tq.x * tq.x + tq.y * tq.y)
			local out : P3 = nil
			if tl > 1e-6 then out = k == 0 and p3(-tq.x / tl, -tq.y / tl, 0) or p3(tq.x / tl, tq.y / tl, 0) end
			-- an end already moved onto a crossing is joined
			local j = (not jointAt[k]) and findEndJoin(q, exE, exN, out) or nil
			if j then
				-- a join onto the neighbouring copy's end node, or onto its segment right beside our
				-- end (that projection lands next to its end point too)
				for _, a in ipairs(avoid or {}) do
					if (j.pos.x - a.x) ^ 2 + (j.pos.y - a.y) ^ 2 < 3.0 * 3.0 then j = nil; break end
				end
			end
			if j then
				j.k = k
				joins[#joins + 1] = j
				-- the copy ends exactly there (carried on to a track end ahead: its last piece's tangents
				-- fitted to the longer stretch, its grade even)
				if k == 0 then pieces[1].p0 = j.pos else pieces[m].p1 = j.pos end
				if j.ahead then
					local pc = k == 0 and pieces[1] or pieces[m]
					fitTangents(pc)
					regrade(pc)
				end
				if j.node then
					endNode[k] = j.node
					exN[j.node] = true
				else
					joinedEdgeEnd[k] = true
					exE[j.edge] = true
					if not perEdge[j.edge] then
						perEdge[j.edge] = {}
						edgeOrder[#edgeOrder + 1] = j.edge
					end
					-- split like a crossing; the shared node is the copy's own end node (id set below)
					table.insert(perEdge[j.edge], { piece = -1, tNew = 0, edge = j.edge, tOld = j.tOld, pos = j.pos, node = nil, id = nil })
				end
			end
		end
		if not sanitizePieces(pieces) then return nil, 0, 0, 0 end
	end
	-- log what the ends joined, when it changes
	local joinKey = ""
	for _, j in ipairs(joins) do
		joinKey = joinKey .. " end" .. tostring(j.k) .. (j.node and (" -> node " .. tostring(j.node))
			or (" -> split edge " .. tostring(j.edge) .. string.format(" at %.2f", j.tOld)))
	end
	if joinKey ~= g_lastJoinLog then
		g_lastJoinLog = joinKey
		dbg("[network_tools] Parallel ends:" .. (joinKey ~= "" and joinKey or " none joined"))
	end

	-- new entity ids count down from -1: all edges first, then the copy's nodes (skipping ends that
	-- reuse an existing node, so the ids stay contiguous), then crossing nodes
	local nEdges = m + #found - nJoint
	for _, e in ipairs(edgeOrder) do nEdges = nEdges + #perEdge[e] + 1 end
	local idOf : {integer : Engine.Entity} = {}
	local nextNode = nEdges + 1
	local nodes : {Proposal.NodeAndEntity} = {}
	for k = 0, m do
		if endNode[k] then
			idOf[k] = endNode[k]
		else
			idOf[k] = -nextNode
			nextNode = nextNode + 1
			local node = api.type.NodeAndEntity.new()
			node.entity = idOf[k]
			node.comp.position = vec3(k == 0 and pieces[1].p0 or pieces[k].p1)
			nodes[#nodes + 1] = node
		end
	end
	local function nodeId(k : integer) : Engine.Entity
		return idOf[k]
	end
	-- the synthetic end crossings share the copy's end node
	for _, j in ipairs(joins) do
		if j.edge then
			for _, c in ipairs(perEdge[j.edge]) do
				if c.piece == -1 and c.id == nil and c.tOld == j.tOld then c.id = idOf[j.k] end
			end
		end
	end
	for _, c in ipairs(found) do
		if c.joint then
			c.id = idOf[c.joint]
		elseif c.node then
			c.id = c.node
		else
			c.id = -nextNode
			nextNode = nextNode + 1
			local node = api.type.NodeAndEntity.new()
			node.entity = c.id
			node.comp.position = vec3(c.pos)
			nodes[#nodes + 1] = node
		end
	end

	local edges : {Proposal.SegmentAndEntity} = {}
	local nextEdge = 1
	local function newSeg() : Proposal.SegmentAndEntity
		local seg = api.type.SegmentAndEntity.new()
		seg.entity = -nextEdge
		nextEdge = nextEdge + 1
		return seg
	end
	local applyRoad = (require "network_tools_1::/gui/construction/tools/shared/ntools_options.script.tl" as {string : any}).applyRoad as function(Proposal.SegmentAndEntity)
	local isTrackAt : {integer : boolean} = {}

	-- a crossing on a copy node between two pieces: both meet it with one slope (the mean of their
	-- grades), as inside a piece below - each climbing evenly on its own left a kink at the crossing,
	-- which the game refused (its own tool runs the grade straight through)
	local function gradeOf(pc : Piece) : number
		local h = math.sqrt((pc.p1.x - pc.p0.x) ^ 2 + (pc.p1.y - pc.p0.y) ^ 2)
		return h > 0.1 and (pc.p1.z - pc.p0.z) / h or 0
	end
	local jointSlope : {integer : number} = {}
	for k in pairs(movedNode) do
		if k >= 1 and k < m then jointSlope[k] = (gradeOf(pieces[k]) + gradeOf(pieces[k + 1])) / 2 end
	end
	local function withSlope(v : P3, s : number) : P3
		return p3(v.x, v.y, s * math.sqrt(v.x * v.x + v.y * v.y))
	end

	-- the copy, split at its crossings
	for i, piece in ipairs(pieces) do
		local link = chain[i]
		local src = getEdge(link.edge)
		if not src then return nil, 0, 0, 0 end
		local streetEdge = api.engine.getComponent(link.edge, api.type.ComponentType.BASE_EDGE_STREET) as Engine.Component.BaseEdgeStreet
		local cs = perPiece[i] or {}
		table.sort(cs, byTNew)
		local ts : {number} = {}
		for _, c in ipairs(cs) do ts[#ts + 1] = c.tNew end
		local parts = splitPiece(piece, ts)
		for j, part in ipairs(parts) do
			-- the joints sit exactly on the shared node
			if j > 1 then part.p0 = cs[j - 1].pos end
			if j < #parts then part.p1 = cs[j].pos end
			-- a part meeting a joint (or a joined end) climbs to it evenly
			local joinedStart = j == 1 and (movedNode[i - 1] or (i == 1 and (endNode[0] ~= nil or joinedEdgeEnd[0])))
			local joinedEnd = j == #parts and (movedNode[i] or (i == m and (endNode[m] ~= nil or joinedEdgeEnd[m])))
			if j > 1 or j < #parts or joinedStart or joinedEnd then
				regrade(part)
			end
			if j == 1 and jointSlope[i - 1] then part.t0 = withSlope(part.t0, jointSlope[i - 1]) end
			if j == #parts and jointSlope[i] then part.t1 = withSlope(part.t1, jointSlope[i]) end
		end
		-- the grade runs smoothly through each crossing: the two parts meeting there share one slope at
		-- the node (the mean of theirs) instead of each keeping its own - a kink there was refused
		for j = 1, #parts - 1 do
			local a, b = parts[j], parts[j + 1]
			local function slopeOf(pc : Piece) : number
				local h = math.sqrt((pc.p1.x - pc.p0.x) ^ 2 + (pc.p1.y - pc.p0.y) ^ 2)
				return h > 0.1 and (pc.p1.z - pc.p0.z) / h or 0
			end
			local s = (slopeOf(a) + slopeOf(b)) / 2
			a.t1 = p3(a.t1.x, a.t1.y, s * math.sqrt(a.t1.x * a.t1.x + a.t1.y * a.t1.y))
			b.t0 = p3(b.t0.x, b.t0.y, s * math.sqrt(b.t0.x * b.t0.x + b.t0.y * b.t0.y))
		end
		if not sanitizePieces(parts) then return nil, 0, 0, 0 end
		for j, part in ipairs(parts) do
			local n0 = j == 1 and nodeId(i - 1) or cs[j - 1].id
			local n1 = j == #parts and nodeId(i) or cs[j].id
			local seg = newSeg()
			setGeometry(seg, n0, n1, part, (not link.fwd) ~= g_flipCopy)
			seg.comp.type = src.type
			seg.comp.typeIndex = src.typeIndex
			seg.comp.laneConfigs = src.laneConfigs
			seg.comp.roadTemplate = src.roadTemplate
			seg.comp.roadStyle = src.roadStyle
			seg.comp.roadType = src.roadType
			-- network picked in the panel; the copy is not connected, so road / rail may differ
			local picked = applyNetwork(seg, nil)
			if picked == true or (picked == nil and src.roadType == api.type["enum"].RoadType.TRACK) then
				seg.type = 1
				isTrackAt[i] = true
				-- track spacing of the template: with 0 the game lays no shared ballast bed or
				-- catenary between neighbouring tracks (from the Parallel Tracks mod)
				pcall(function()
					local d = (src.distance and src.distance > 0) and src.distance or 5
					local tpl = api.res.streetTemplateRep.get(api.res.streetTemplateRep.find(seg.comp.roadTemplate))
					if tpl and tpl.trackDistance and tpl.trackDistance > 0 then d = tpl.trackDistance end
					seg.comp.distance = d
				end)
				pcall(function() seg.comp.edgeDecorations = src.edgeDecorations end)
			else
				seg.type = 0
				isTrackAt[i] = false
				if streetEdge then seg.streetEdge = streetEdge end
			end
			-- the copy over water / high above the ground: a bridge (shared rules); copies of bridges
			-- and tunnels keep theirs
			terrain.upgradeSegment(seg, seg.type == 1)
			-- the panel's new-road properties (catenary, bus lane, tram, lock, owner, decorations)
			applyRoad(seg)
			edges[#edges + 1] = seg
		end
	end

	-- crossed edges: removed and re-added in pieces through the shared nodes, same type and lanes
	local toRemove : {Engine.Entity} = {}
	local edgeObjects : {SimpleStreetProposal.EdgeObject} = {}
	local objectsRemoved : {Engine.Entity} = {}
	-- re-placed signals are referenced from their segment by placeholder ids far below every other
	-- new entity (as in the signals tool)
	local nextPlaceholder = -400000000
	for _, e in ipairs(edgeOrder) do
		local oe = getEdge(e)
		if not oe then return nil, 0, 0, 0 end
		local isTrack = oe.roadType == api.type["enum"].RoadType.TRACK
		local streetEdge : Engine.Component.BaseEdgeStreet = nil
		if not isTrack then
			streetEdge = api.engine.getComponent(e, api.type.ComponentType.BASE_EDGE_STREET) as Engine.Component.BaseEdgeStreet
		end
		local cs = perEdge[e]
		table.sort(cs, byTOld)
		local ts : {number} = {}
		for _, c in ipairs(cs) do ts[#ts + 1] = c.tOld end
		local parts = splitPiece(edgePiece(oe), ts)
		for j, part in ipairs(parts) do
			if j > 1 then part.p0 = cs[j - 1].pos end
			if j < #parts then part.p1 = cs[j].pos end
		end
		if not sanitizePieces(parts) then return nil, 0, 0, 0 end
		local sigs : {SignalCopy} = {}
		if #(oe.objects or {}) > 0 then
			local okS, s = pcall(readSignals, e, oe)
			if not okS or not s then return nil, 0, 0, 0 end
			sigs = s
		end
		for j, part in ipairs(parts) do
			local seg = newSeg()
			-- whole component of the old edge (every field), objects dropped: as the signals tool re-adds
			setGeometry(seg, j == 1 and oe.node0 or cs[j - 1].id, j == #parts and oe.node1 or cs[j].id, part, false)
			seg.comp.type = oe.type
			seg.comp.typeIndex = oe.typeIndex
			seg.comp.laneConfigs = oe.laneConfigs
			seg.comp.roadTemplate = oe.roadTemplate
			seg.comp.roadStyle = oe.roadStyle
			seg.comp.roadType = oe.roadType
			seg.comp.roadDevelopmentLocked = oe.roadDevelopmentLocked
			-- keep the crossed track's spacing (shared ballast / catenary) and decorations
			pcall(function() seg.comp.distance = oe.distance end)
			pcall(function() seg.comp.edgeDecorations = oe.edgeDecorations end)
			seg.type = isTrack and 1 or 0
			if streetEdge then seg.streetEdge = streetEdge end
			-- the old edge's signals that fall on this part, placed again along it
			local t0, t1 = j == 1 and 0 or ts[j - 1], j == #parts and 1 or ts[j]
			local refs : {{Engine.Entity, EdgeObjectType}} = {}
			for _, sc in ipairs(sigs) do
				if sc.param >= t0 and (sc.param < t1 or j == #parts) then
					local o = api.type.SimpleStreetProposal.EdgeObject.new()
					o.edgeEntity = seg.entity
					o.param = math.max(0, math.min(1, (sc.param - t0) / math.max(1e-6, t1 - t0)))
					o.oneWay = sc.oneWay
					o.left = sc.left
					o.model = sc.model
					o.playerEntity = api.engine.util.getPlayer()
					edgeObjects[#edgeObjects + 1] = o
					refs[#refs + 1] = { nextPlaceholder, api.type["enum"].EdgeObjectType.SIGNAL }
					nextPlaceholder = nextPlaceholder - 1
					objectsRemoved[#objectsRemoved + 1] = sc.entity
				end
			end
			if #refs > 0 then seg.comp.objects = refs end
			edges[#edges + 1] = seg
		end
		toRemove[#toRemove + 1] = e
	end

	local proposal = api.type.SimpleProposal.new()
	proposal.streetProposal.nodesToAdd = nodes
	proposal.streetProposal.edgesToAdd = edges
	if #toRemove > 0 then
		proposal.streetProposal.edgesToRemove = toRemove
	end
	if #edgeObjects > 0 then
		proposal.streetProposal.edgeObjectsToAdd = edgeObjects
		proposal.streetProposal.edgeObjectsToRemove = objectsRemoved
	end
	-- lane connections of existing nodes that lose a segment (split edges' ends) or gain one
	-- (crossings joined at an existing node) name segments by id: let the engine rebuild them
	local snapped : {Engine.Entity} = {}
	for _, c in ipairs(found) do
		if c.node then snapped[#snapped + 1] = c.node end
	end
	for _, j in ipairs(joins) do
		if j.node then snapped[#snapped + 1] = j.node end
	end
	local cfgNodes = net_util.configNodesFor(toRemove, snapped)
	if #cfgNodes > 0 then
		proposal.streetProposal.nodeConfigsToRemove = cfgNodes
	end

	-- road meets rail: level crossing on the shared node
	local rc : {Engine.Entity : integer} = {}
	local hasRc = false
	for _, c in ipairs(found) do
		local oe = getEdge(c.edge)
		local oldTrack = oe and oe.roadType == api.type["enum"].RoadType.TRACK
		if oe and oldTrack ~= isTrackAt[c.piece] then
			local rcId = g_host.levelCrossingType()
			if rcId then
				rc[c.id] = rcId
				hasRc = true
			end
		end
	end
	-- the ends too: road ending on rail (or rail on road) is a level crossing
	for _, j in ipairs(joins) do
		local copyTrack = isTrackAt[j.k == 0 and 1 or m]
		local otherTrack : boolean = nil
		if j.edge then
			local oe = getEdge(j.edge)
			if oe then otherTrack = oe.roadType == api.type["enum"].RoadType.TRACK end
		else
			local ok, segs = pcall(function() : {Engine.Entity} return api.engine.system.streetSystem.getNodeSegments(j.node) end)
			local s1 = ok and segs and segs[1] or nil
			local oe = s1 and getEdge(s1) or nil
			if oe then otherTrack = oe.roadType == api.type["enum"].RoadType.TRACK end
		end
		if otherTrack ~= nil and otherTrack ~= copyTrack then
			local rcId = g_host.levelCrossingType()
			if rcId then
				rc[idOf[j.k]] = rcId
				hasRc = true
			end
		end
	end
	if hasRc then
		pcall(function() proposal.streetProposal.node2rcType = rc end)
	end
	-- a split segment ending at an existing crossing: the engine re-creates that crossing
	net_util.rebuildCrossings(proposal, toRemove)
	return proposal, #found, skipped, #joins
end

-- The game's verdict on a proposal checked as it is built (street graph cleaned up, terrain
-- aligned): "" when it can be built. Cached per preview id (the preview reports every frame).
local g_cleanKey, g_cleanMsg = "", ""
local function cleanVerdict(key : string, sp : SimpleProposal) : string
	if key == g_cleanKey then return g_cleanMsg end
	local ok, msg = pcall(function() : string
		local ctx = api.type.Context.new()
		ctx.player = api.engine.util.getPlayer()
		ctx.cleanupStreetGraph = true
		ctx.checkTerrainAlignment = true
		local validate = api.engine.util.proposal.makeProposalData as function(SimpleProposal, Context) : ProposalData
		local pd = validate(sp, ctx)
		local m = ""
		for _, s in ipairs(pd.errorState.messages or {}) do m = m .. s .. " " end
		return m
	end)
	g_cleanKey, g_cleanMsg = key, ok and msg or _("Construction Not Possible")
	dbg("[network_tools] Parallel verdict with street cleanup: " .. (g_cleanMsg == "" and "OK" or g_cleanMsg))
	return g_cleanMsg
end

-- Several copies in ONE proposal (one preview, one cost, one undo): each copy's proposal is made on
-- its own, then their new entities are renumbered into one list - all edges first, then all nodes,
-- as the API wants. Only when no copy removes an existing segment (no crossings / ends splitting a
-- road): two copies splitting the same road would each remove it, which can't be combined. Returns
-- nil then, and the copies are built one after another instead.
local function mergeProposals(list : {SimpleProposal}) : SimpleProposal
	local edgesAll : {Proposal.SegmentAndEntity} = {}
	local nodesAll : {Proposal.NodeAndEntity} = {}
	local cfgAll : {Engine.Entity} = {}
	local rcAll : {Engine.Entity : integer} = {}
	local hasRc = false
	local ok, err = pcall(function()
		local totalEdges = 0
		for _, p in ipairs(list) do
			local sp = p.streetProposal
			if #(sp.edgesToRemove or {}) > 0 or #(sp.nodesToRemove or {}) > 0 then error("removes") end
			totalEdges = totalEdges + #(sp.edgesToAdd or {})
		end
		local edgeBase, nodeBase = 0, totalEdges
		for _, p in ipairs(list) do
			local sp = p.streetProposal
			local E = #(sp.edgesToAdd or {})
			-- this proposal's ids: edges -1..-E, nodes -(E+1)..
			local function mapId(id : Engine.Entity) : Engine.Entity
				if id >= 0 then return id end
				if -id <= E then return -(edgeBase - id) end
				return -(nodeBase + (-id - E))
			end
			local nN = 0
			for _, n in ipairs(sp.nodesToAdd or {}) do
				n.entity = mapId(n.entity)
				nodesAll[#nodesAll + 1] = n
				nN = nN + 1
			end
			for _, s in ipairs(sp.edgesToAdd or {}) do
				s.entity = mapId(s.entity)
				s.comp.node0 = mapId(s.comp.node0)
				s.comp.node1 = mapId(s.comp.node1)
				edgesAll[#edgesAll + 1] = s
			end
			for _, n in ipairs(sp.nodeConfigsToRemove or {}) do cfgAll[#cfgAll + 1] = n end
			pcall(function()
				for k, v in pairs(sp.node2rcType or {}) do rcAll[mapId(k as Engine.Entity)] = v as integer; hasRc = true end
			end)
			edgeBase = edgeBase + E
			nodeBase = nodeBase + nN
		end
	end)
	if not ok then
		if tostring(err):find("removes") == nil then dbg("[network_tools] Parallel: merge failed: " .. tostring(err)) end
		return nil
	end
	local merged = api.type.SimpleProposal.new()
	merged.streetProposal.nodesToAdd = nodesAll
	merged.streetProposal.edgesToAdd = edgesAll
	if #cfgAll > 0 then merged.streetProposal.nodeConfigsToRemove = cfgAll end
	if hasRc then pcall(function() merged.streetProposal.node2rcType = rcAll end) end
	return merged
end

-- Diagnostics: what the preview collides with, logged when it changes (the game's tooltip only
-- says "Collision"). Segments are described with their type and end nodes.
local g_lastCollisionLog = ""
local function logCollisions(pd : ProposalData, msg : string)
	local parts : {string} = {}
	pcall(function()
		for _, cd in ipairs(pd.collisionInfo.collisionEntities or {}) do
			local e = cd.entity
			local desc = tostring(e)
			local be = e and e >= 0 and api.engine.entityExists(e)
				and api.engine.getComponent(e, api.type.ComponentType.BASE_EDGE) as Engine.Component.BaseEdge or nil
			if be then
				desc = desc .. (be.roadType == api.type["enum"].RoadType.TRACK and " track" or " street")
					.. " " .. tostring(be.node0) .. "-" .. tostring(be.node1)
			elseif e and e >= 0 and api.engine.entityExists(e)
				and api.engine.getComponent(e, api.type.ComponentType.BASE_NODE) ~= nil then
				desc = desc .. " node"
			end
			parts[#parts + 1] = desc
		end
	end)
	local line = msg .. " | " .. table.concat(parts, ", ")
	if line ~= g_lastCollisionLog then
		g_lastCollisionLog = line
		if msg ~= "" or #parts > 0 then
			dbg("[network_tools] Parallel preview: " .. line)
		end
	end
end
-- Diagnostics: the proposal itself, when the game rejects it without naming a collision
-- ("Construction Not Possible"), logged once per distinct proposal.
local g_lastDump = ""
local function dumpProposal(p : SimpleProposal, msg : string)
	local lines : {string} = {}
	pcall(function()
		local sp = p.streetProposal
		for _, n in ipairs(sp.nodesToAdd or {}) do
			local q = n.comp.position
			lines[#lines + 1] = string.format("  node %d at %.1f %.1f %.1f", n.entity, q.x, q.y, q.z)
		end
		for _, s in ipairs(sp.edgesToAdd or {}) do
			local c = s.comp
			local l0 = math.sqrt(c.tangent0.x ^ 2 + c.tangent0.y ^ 2 + c.tangent0.z ^ 2)
			local l1 = math.sqrt(c.tangent1.x ^ 2 + c.tangent1.y ^ 2 + c.tangent1.z ^ 2)
			local chord = math.sqrt((c.position1.x - c.position0.x) ^ 2 + (c.position1.y - c.position0.y) ^ 2)
			local dist : any = nil
			pcall(function() dist = c.distance end)
			lines[#lines + 1] = string.format("  edge %d: %d -> %d  chord %.1f  tangents %.1f / %.1f  z %.2f -> %.2f  tz %.2f / %.2f  type %d edgeType %s typeIndex %s distance %s",
				s.entity, c.node0, c.node1, chord, l0, l1, c.position0.z, c.position1.z, c.tangent0.z, c.tangent1.z, s.type,
				tostring(c.type), tostring(c.typeIndex), tostring(dist))
		end
		lines[#lines + 1] = "  remove edges: " .. table.concat((function() : {string}
			local o : {string} = {}
			for _, e in ipairs(sp.edgesToRemove or {}) do o[#o + 1] = tostring(e) end
			return o
		end)(), ", ")
		lines[#lines + 1] = "  node configs removed: " .. table.concat((function() : {string}
			local o : {string} = {}
			for _, e in ipairs(sp.nodeConfigsToRemove or {}) do o[#o + 1] = tostring(e) end
			return o
		end)(), ", ")
	end)
	local text = table.concat(lines, "\n")
	if text ~= g_lastDump then
		g_lastDump = text
		dbg("[network_tools] Parallel rejected (" .. msg .. "):\n" .. text)
	end
end
local ParallelActionRecipe = react.RegisterRecipe("NtoolsParallelAction", function(params : ConstructionCustomActionParams<any>) : TreeNodeId
	react.onUnmount(preview.clear)   -- its speed / incline tags leave with the tool
	local chainState : ReactStateT<{ChainLink}> = react.useState({})
	local costState : ReactStateT<integer> = react.useState(0)
	local errorState : ReactStateT<string> = react.useState("")
	local aliveRef : ReactRefT<boolean> = react.useRef(true)
	-- true from Build until the command's callback: touching a half-built segment (hover filter)
	-- is an engine assertion, not a Lua error - so no picker and no proposal meanwhile
	local busyState : ReactStateT<boolean> = react.useState(false)
	-- offset handle: 1 while dragged / hovered
	local draggingState : ReactStateT<integer> = react.useState(0)
	local hoverState : ReactStateT<integer> = react.useState(0)

	-- options live in module state (panel + keys); poll them so changes re-render the preview
	local offsetUi = engine_react_util.useStepState(function() : number return opts.offset or -1 end)
	local networkUi = engine_react_util.useStepState(function() : integer return g_host.networkId() or 0 end)
	local sideUi = engine_react_util.useStepState(function() : integer return opts.side end)
	local heightUi = engine_react_util.useStepState(function() : number return opts.height end)
	local anarchyUi = engine_react_util.useStepState(function() : boolean return g_host.anarchy() end)
	local crossingsUi = engine_react_util.useStepState(function() : boolean return opts.crossings end)
	-- the panel's shared new-road options (catenary, tram, bus lane, decorations, ...): a change
	-- re-renders, and is part of the preview id so the preview is made again
	local sharedKeyUi = engine_react_util.useStepState(function() : string
		return ((require "network_tools_1::/gui/construction/tools/shared/ntools_options.script.tl" as {string : any}).key as function() : string)()
	end)
	local connectEndsUi = engine_react_util.useStepState(function() : boolean return opts.connectEnds end)
	local countUi = engine_react_util.useStepState(function() : integer return opts.count or 1 end)

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
	local chain = busy and {} or (chainState:old() or {})
	local _offsetPoll = offsetUi:old()  -- read so offset changes re-render
	local _networkPoll = networkUi:old()
	local _countPoll = countUi:old()
	local side = sideUi:old() or 1
	local dz = heightUi:old() or 0
	local anarchy = anarchyUi:old() == true
	local crossings = crossingsUi:old() ~= false
	local connectEnds = connectEndsUi:old() ~= false
	local networkId = g_host.networkId()

	-- automatic offset: the width of the selected road / track, so the copy sits right beside it
	local isTrack = false
	if #chain > 0 then
		local e = getEdge(chain[1].edge)
		if e then
			isTrack = e.roadType == api.type["enum"].RoadType.TRACK
			local srcTpl = templateByName(e.roadTemplate)
			local newTpl = templateById(networkId) or srcTpl
			local srcW = edgeWidth(e)
			local newW = newTpl and laneWidth(newTpl.laneConfigs) or srcW
			local bothTrack = isTrack and newTpl ~= nil and newTpl.roadType == api.type["enum"].RoadType.TRACK
			local spacing = bothTrack and (newTpl.trackDistance or 0) or 0
			if spacing > 0.5 then
				-- the network's standard distance between track centres
				opts.autoOffset = spacing
			else
				-- edge to edge: half of each road's width
				local w = (srcW + newW) / 2
				opts.autoOffset = w > 0.5 and w or (isTrack and 5 or 12)
			end
		end
	end
	local offset = opts.offset or opts.autoOffset

	-- Where the copies go, in multiples of the offset (+ = left of the stretch, - = right): one side
	-- (side = +1 / -1) gives 1, 2, 3 ... on that side; both (side = 0) gives 1, -1, 2, -2 ...
	local wanted = math.max(1, math.min(PAR_MAX_COUNT, opts.count or 1))
	local slots : {number} = {}
	for k = 1, wanted do
		if side == 0 then
			slots[#slots + 1] = k
			slots[#slots + 1] = -k
		else
			slots[#slots + 1] = side * k
		end
	end
	-- the first copy's side: the handle sits on it
	local handleSide = side ~= 0 and side or 1

	local proposal : SimpleProposal = nil
	local nCrossings, nSkipped, nJoins = 0, 0, 0
	if #chain > 0 then
		proposal, nCrossings, nSkipped, nJoins = makeParallelProposal(chain, parallelPieces(chain, offset * slots[1], dz), crossings, connectEnds)
	end
	-- several copies: all in one proposal when none of them splits an existing road (one preview, one
	-- undo); otherwise they are built one after another (see build())
	local merged = false
	if proposal and #slots > 1 then
		local list : {SimpleProposal} = { proposal }
		for k = 2, #slots do
			local p = makeParallelProposal(chain, parallelPieces(chain, offset * slots[k], dz), crossings, connectEnds)
			if not p then list = nil; break end
			list[#list + 1] = p
		end
		local m = list and mergeProposals(list) or nil
		if m then proposal, merged = m, true end
	end

	-- Offset handle (CS2 Network Tools style): sits on the middle of the copy; drag it sideways
	-- to set the offset, across the original to switch side. Stays in step with the panel slider.
	local handleList : {Handle} = {}
	local midLink : ChainLink = nil
	local midP0, midT0, midP1, midT1 : P3, P3, P3, P3
	local midQ : P3 = nil
	if #chain > 0 then
		local k = math.floor((#chain + 1) / 2)
		midLink = chain[k]
		midP0, midT0, midP1, midT1 = linkCurve(midLink)
		local copy = parallelPieces({ midLink }, offset * handleSide, dz)
		if copy and copy[1] then
			midQ = hermitePoint(copy[1], 0.5)
			handleList[1] = { x = midQ.x, y = midQ.y, z = midQ.z }
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
		onDrag = function(_i : integer, x : number, y : number)
			if not midLink then return end
			-- signed distance from the original (left of the stretch = positive)
			local pc : Piece = { p0 = midP0, t0 = midT0, p1 = midP1, t1 = midT1 }
			local bestT, bestD = 0.5, math.huge
			for s = 0, 40 do
				local q = hermitePoint(pc, s / 40)
				local d = (q.x - x) ^ 2 + (q.y - y) ^ 2
				if d < bestD then bestT, bestD = s / 40, d end
			end
			local foot = hermitePoint(pc, bestT)
			local tan = hermiteTangent(pc, bestT)
			local tx, ty = norm2(tan.x, tan.y)
			local d = tx * (y - foot.y) - ty * (x - foot.x)
			-- (with copies on both sides the handle sets only the offset)
			if opts.side ~= 0 then opts.side = d >= 0 and 1 or -1 end
			opts.offset = clamp(math.floor(math.abs(d) * 2 + 0.5) / 2, PAR_MIN_OFFSET, PAR_MAX_OFFSET)
		end,
	}
	local blocked = errorState:old() ~= "" and not anarchy
	g_host.ui.canBuild = proposal ~= nil and not blocked

	local function clear()
		if aliveRef:hasExpired() then return end
		chainState:set({})
		costState:set(0)
		errorState:set("")
	end

	-- Several copies are built one after another, each a normal Parallel build against the world as
	-- the copy before left it (so crossings and joined ends keep working): copy k sits k x offset
	-- from the original. Copy 1 is the previewed proposal; the others are made when their turn comes.
	-- (merged: every copy is already in the one proposal)
	local count = merged and 1 or #slots
	local function copyEnds(k : integer) : {P3}
		local out : {P3} = {}
		for i = 1, k - 1 do
			local pcs = parallelPieces(chain, offset * slots[i], dz)
			if pcs and #pcs > 0 then
				out[#out + 1] = pcs[1].p0
				out[#out + 1] = pcs[#pcs].p1
			end
		end
		return out
	end
	local function build()
		if not proposal or blocked or busy then return end
		local buildChain = chain
		local function send(k : integer, p : SimpleProposal)
			local context = api.type.Context.new()
			context.player = api.engine.util.getPlayer()
			-- like the game's track tool (as the Parallel Tracks mod does): level the terrain under the
			-- copy, lay the ballast bed, redo bridge pillars
			pcall(function()
				context.extendProposalRedoPillars = true
				context.checkTerrainAlignment = true
				context.gatherFields = true
				-- let the engine tidy the street graph round the new crossings, as its own track tool
				-- does: without it a crossing on a split road was refused
				context.cleanupStreetGraph = true
			end)
			local cmd = api.cmd.makeWorldBuildProposalCmd(p, context, anarchy, true)
			-- (the shared send every tool's build goes through; new roads: Player owned applies)
			((require "network_tools_1::/gui/construction/tools/shared/ntools_options.script.tl" as {string : any}).send as function(Command<WorldBuildProposalCommandData>, function(WorldBuildProposalCommandData, boolean), boolean))(cmd, function(__ : WorldBuildProposalCommandData, success : boolean)
				if not success then
					dbg("[network_tools] Parallel: build of copy " .. tostring(k) .. " failed")
				end
				if aliveRef:hasExpired() then return end
				local nextP : SimpleProposal = nil
				if success and k < count then
					-- the world changed: segments split by this copy are new entities
					g_edgeIndex = nil
					local ok, res = pcall(function() : SimpleProposal
						for _, l in ipairs(buildChain) do
							if not api.engine.entityExists(l.edge) then return nil end
						end
						local pcs = parallelPieces(buildChain, offset * slots[k + 1], dz)
						local np = makeParallelProposal(buildChain, pcs, crossings, connectEnds, copyEnds(k + 1))
						return np
					end)
					if ok then nextP = res else dbg("[network_tools] Parallel: copy " .. tostring(k + 1) .. ": " .. tostring(res)) end
				end
				if nextP then
					send(k + 1, nextP)
				else
					busyState:set(false)
					if success then clear() end
				end
			end, true)
		end
		busyState:set(true)
		send(1, proposal)
	end

	local function onSelect(entity : Engine.Entity) : boolean
		local e = getEdge(entity)
		if not e then return false end
		-- diagnostics: everything about the clicked segment and its end nodes (to compare a crossing
		-- the game's own track tool built with one this tool proposes)
		pcall(function()
			local function nodeInfo(n : Engine.Entity) : string
				local bn = api.engine.getComponent(n, api.type.ComponentType.BASE_NODE) as Engine.Component.BaseNode
				local segs = api.engine.system.streetSystem.getNodeSegments(n)
				local ids : {string} = {}
				for _, s in ipairs(segs) do ids[#ids + 1] = tostring(s) end
				local extra = ""
				if api.engine.getComponent(n, api.type.ComponentType.RAILROAD_CROSSING) then extra = extra .. " RC" end
				if api.engine.getComponent(n, api.type.ComponentType.BASE_NODE_CONFIG) then extra = extra .. " cfg" end
				return string.format("%d (%.1f %.1f %.2f) segs={%s}%s", n, bn.position.x, bn.position.y, bn.position.z,
					table.concat(ids, ","), extra)
			end
			local function edgeInfo(id : Engine.Entity, tag : string)
				local ee = getEdge(id)
				if not ee then return end
				local distance : any = nil
				pcall(function() distance = ee.distance end)
				dbg(string.format("[network_tools] Parallel %s %d: %s -> %s | t0 (%.1f %.1f %.2f) t1 (%.1f %.1f %.2f) | type %s typeIndex %s distance %s template %s",
					tag, id, nodeInfo(ee.node0), nodeInfo(ee.node1),
					ee.tangent0.x, ee.tangent0.y, ee.tangent0.z, ee.tangent1.x, ee.tangent1.y, ee.tangent1.z,
					tostring(ee.type), tostring(ee.typeIndex), tostring(distance), tostring(ee.roadTemplate)))
			end
			edgeInfo(entity, "picked")
			-- and every segment meeting it at either end (one click captures a whole crossing)
			local seen : {Engine.Entity : boolean} = { [entity] = true }
			for _, n in ipairs({ e.node0, e.node1 }) do
				for _, s in ipairs(api.engine.system.streetSystem.getNodeSegments(n)) do
					if not seen[s] then seen[s] = true; edgeInfo(s, "  neighbour") end
				end
			end
		end)
		costState:set(0)
		errorState:set("")
		if #chain == 0 then
			chainState:set({ { edge = entity, fwd = true } })
			return true
		end
		-- clicking the first / last segment removes it; the middle of the chain is left alone
		for i, link in ipairs(chain) do
			if link.edge == entity then
				if i == 1 or i == #chain then
					local nc : {ChainLink} = {}
					for j, l in ipairs(chain) do
						if j ~= i then nc[#nc + 1] = l end
					end
					chainState:set(nc)
				end
				return true
			end
		end
		local startNode = linkEnds(chain[1])
		local _startOfLast, endNode = linkEnds(chain[#chain])
		local nc : {ChainLink} = {}
		for _, l in ipairs(chain) do nc[#nc + 1] = l end
		if e.node0 == endNode or e.node1 == endNode then
			nc[#nc + 1] = { edge = entity, fwd = e.node0 == endNode }
		elseif e.node0 == startNode or e.node1 == startNode then
			table.insert(nc, 1, { edge = entity, fwd = e.node1 == startNode })
		else
			-- further away: add the whole path to it (from whichever chain end reaches it)
			local inChain : {Engine.Entity : boolean} = {}
			for _, l in ipairs(chain) do inChain[l.edge] = true end
			local roadType = getEdge(chain[1].edge).roadType
			local path = findPath(endNode, entity, roadType, inChain)
			if path then
				for _, l in ipairs(path) do nc[#nc + 1] = l end
			else
				local back = findPath(startNode, entity, roadType, inChain)
				if back then
					-- walked away from the start: reverse it to put it in front of the chain
					for _, l in ipairs(back) do
						table.insert(nc, 1, { edge = l.edge, fwd = not l.fwd })
					end
				else
					nc = { { edge = entity, fwd = true } }
				end
			end
		end
		chainState:set(nc)
		return true
	end

	-- keys: . / , offset, O / P height, [ / ] side (Shift = fine)
	local hasChain = function() : boolean return #chain > 0 end
	local function changeOffset(sign : number)
		local step = precise() and 0.5 or 1
		opts.offset = clamp(math.floor((offset + sign * step) / step + 0.5) * step, PAR_MIN_OFFSET, PAR_MAX_OFFSET)
	end
	local function changeHeight(sign : number)
		local step = precise() and 0.5 or 1
		opts.height = clamp(opts.height + sign * step, -50, 50)
	end
	safeUseInputAction("constructRaise", shortcutHandler(function() changeOffset(1) end, hasChain, _("Offset +"), true))
	safeUseInputAction("constructLower", shortcutHandler(function() changeOffset(-1) end, hasChain, _("Offset -"), true))
	safeUseInputAction("constructOpt6", shortcutHandler(function() changeHeight(1) end, hasChain, _("Height +"), true))
	safeUseInputAction("constructOpt5", shortcutHandler(function() changeHeight(-1) end, hasChain, _("Height -"), true))
	safeUseInputAction("constructOpt7", shortcutHandler(function() opts.side = 1 end, hasChain, _("Left side")))
	safeUseInputAction("constructOpt8", shortcutHandler(function() opts.side = -1 end, hasChain, _("Right side")))

	handlersRef:set({
		ntoolsResetShape = clear,
		ntoolsBuild = build,
	})

	-- the handle and a guide from the original to it (one EdgeRenderable per recipe)
	local function withHandleOverlay(children : {TreeNodeId}) : {TreeNodeId}
		if midQ and handleList[1] then
			local c = handles.canvas()
			-- outlines of the copies after the first (built one after another, see build())
			for k = 2, count do
				for _, pc in ipairs(parallelPieces(chain, offset * slots[k], dz) or {}) do
					local prev = pc.p0
					for s = 1, 8 do
						local q = hermitePoint(pc, s / 8)
						c.line(prev.x, prev.y, prev.z, q.x, q.y, q.z, handles.colors.guide, 1.0)
						prev = q
					end
				end
			end
			local a = hermitePoint({ p0 = midP0, t0 = midT0, p1 = midP1, t1 = midT1 }, 0.5)
			c.line(a.x, a.y, a.z, midQ.x, midQ.y, midQ.z, handles.colors.guide, 0.6)
			c.handle(handleList[1], dragging ~= 0 and 2 or (hover ~= 0 and 1 or 0))
			local node = c.node()
			if node then children[#children + 1] = node end
		end
		return children
	end

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
				children = { tooltip(_("Building..."), true, false) },
			}
		end
		local children : {TreeNodeId} = {
			builtin.Selector(padMod.selector(pad, {
				onSelect = function(entity : Engine.Entity, __ : {integer}, __ : Gui.SelectionDetails) : boolean
					-- a click on the handle is a drag, not a selection
					local cx, cy = handles.cursor()
					if dragging ~= 0 or (cx and handles.hit(handleList, cx, cy) > 0) then return true end
					return onSelect(entity)
				end,
				onProcessMouseEvent = function(evt : Gui.Mouse.Event) : boolean
					return handles.mouse(evt, dragCtl)
				end,
				filter = isEdge,
			}) as Builtin.SelectorParam),
		}
		if proposal then
			-- (offset and side apart: with copies on both sides side is 0, and offset * side stayed 0
			-- whatever the offset - the preview never refreshed)
			local id = "ntools_parallel," .. tostring(offset) .. "," .. tostring(side) .. "," .. tostring(dz) .. "," .. tostring(networkId) .. "," .. tostring(crossings) .. "," .. tostring(connectEnds) .. ",x" .. tostring(wanted) .. (merged and "m" or "") .. "," .. tostring(sharedKeyUi:old())
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
					-- the preview checks without build options; the build cleans up the street graph
					-- (see build()), which some crossings need: ask the game again the way it is built
					if msg ~= "" and #(proposalData.collisionInfo.collisionEntities or {}) == 0 then
						msg = cleanVerdict(id, proposal)
					end
					errorState:set(msg)
					logCollisions(proposalData, msg)
					if msg ~= "" and #(proposalData.collisionInfo.collisionEntities or {}) == 0 then
						dumpProposal(proposal, msg)
					end
				end,
				id = id,
			}
		end
		-- tags across the gap at both ends of every copy: its distance from the original (and how much
		-- higher / lower it sits)
		local gapTags : {LabelPoint} = {}
		if proposal and #chain > 0 then
			pcall(function()
				local orig = parallelPieces(chain, 0, 0)
				for __, slot in ipairs(slots) do
					local pcs = parallelPieces(chain, offset * slot, dz)
					if orig and pcs and #pcs > 0 then
						for __, ends in ipairs({ { orig[1].p0, pcs[1].p0 }, { orig[#orig].p1, pcs[#pcs].p1 } }) do
							local o, c = ends[1], ends[2]
							local rows : {LabelRow} = { { text = _("Gap") .. " " .. fmtLen(offset * math.abs(slot)) } }
							if math.abs(dz) >= 0.05 then
								rows[#rows + 1] = { icon = dz > 0 and labels.icons.up or labels.icons.down, text = string.format("%+.1f m", dz) }
							end
							gapTags[#gapTags + 1] = { x = (o.x + c.x) / 2, y = (o.y + c.y) / 2, z = math.max(o.z, c.z), rows = rows }
						end
					end
				end
			end)
		end
		labels.set({}, gapTags)

		local info = _("Segments") .. ": " .. tostring(#chain) .. "   " .. _("Offset") .. ": " .. fmtLen(offset)
			.. " " .. (side > 0 and _("left") or (side < 0 and _("right") or _("both sides"))) .. "   " .. _("Height") .. ": " .. (dz >= 0 and "+" or "") .. tostring(dz) .. " m"
		if nCrossings > 0 then info = info .. "   " .. _("Crossings") .. ": " .. tostring(nCrossings) end
		if nJoins > 0 then info = info .. "   " .. _("Ends joined") .. ": " .. tostring(nJoins) end
		if nSkipped > 0 then info = info .. "\n" .. _("Not joined (signals, a level crossing / junction config next to it, or too close to a joint)") .. ": " .. tostring(nSkipped) end
		if #chain == 0 then
			children[#children + 1] = tooltip(_("Click a road or track segment to copy"), false, false)
		elseif not proposal then
			children[#children + 1] = tooltip(_("This stretch can't be copied at this offset") .. "\n" .. info, false, true)
		elseif blocked then
			children[#children + 1] = tooltip(errorState:old() .. "\n" .. info, false, true, costState:old())
		else
			children[#children + 1] = tooltip(_("Click more segments to extend, the first / last to remove. Press Build to build") .. "\n" .. info, true, false, costState:old())
		end

		local highlighted : {Engine.Entity} = {}
		for _, l in ipairs(chain) do highlighted[#highlighted + 1] = l.edge end

		-- underground view (panel option, all tools)
		local under = ((require "network_tools_1::/gui/construction/tools/shared/ntools_options.script.tl" as {string : any}).layerNode as function() : TreeNodeId)()
		if under then children[#children + 1] = under end
		return builtin.ActionDescriptor{
			tool = "construction-menu-perks",
			onBack = function() leave(params) end,
			highlightedEntities = highlighted,
			crosshair = crosshair,
			terrainCirclePolicy = circle,
			children = (function() : {TreeNodeId}
				local list = withHandleOverlay(children)
				-- Anarchy preview strips the handle overlay didn't draw
				local lo = preview.leftover()
				if lo then list[#list + 1] = lo end
				-- speed / gradient tags on the new segments
				local tags = preview.tags()
				if tags then list[#list + 1] = tags end
				return list
			end)(),
		}
	end

	params.setActionFn(actionFn, "NtoolsParallelAction")
	return padMod.anchor(pad)
end)

-- For other tools (Connect's twin): a copy of `chain` `offset` metres to its side (+ = left), with
-- crossings and joined ends like a Parallel build; `flip` turns it round. nil if it can't be made.
local function copyProposal(chain : {ChainLink}, offset : number, flip : boolean) : SimpleProposal
	g_flipCopy = flip == true
	g_edgeIndex = nil     -- the network just changed
	local ok, p = pcall(function() : SimpleProposal
		return makeParallelProposal(chain, parallelPieces(chain, offset, 0), true, true)
	end)
	g_flipCopy = false
	if not ok then
		dbg("[network_tools] Parallel copy failed: " .. tostring(p))
		return nil
	end
	return p
end

-- For Connect's twin preview: `sp` (a proposal of new segments) plus a copy of its new segments
-- `offset` metres to their side (+ = left of each segment's direction; `flip` runs the copy the
-- other way). The copy has its own nodes and joins nothing - it only shows where the twin, built
-- after the connection with copyProposal(), will run. nil if it can't be made.
local function withTwinPreview(sp : SimpleProposal, offset : number, flip : boolean) : SimpleProposal
	local ok, res = pcall(function() : SimpleProposal
		local street = sp.streetProposal
		local edges = street.edgesToAdd or {}
		if #edges == 0 then return nil end
		-- node positions (new ones from the proposal, existing ones from the world)
		local pos : {Engine.Entity : P3} = {}
		for _, n in ipairs(street.nodesToAdd or {}) do
			pos[n.entity] = p3(n.comp.position.x, n.comp.position.y, n.comp.position.z)
		end
		local function posOf(id : Engine.Entity) : P3
			if not pos[id] then pos[id] = getNodePos(id) end
			return pos[id]
		end
		-- each node's sideways direction: the mean left normal of the new segments meeting it
		local nrm : {Engine.Entity : {number}} = {}
		local function addNormal(id : Engine.Entity, t : Vec3f)
			local x, y = norm2(-t.y, t.x)
			local cur = nrm[id] or { 0, 0, 0 }
			nrm[id] = { cur[1] + x, cur[2] + y, cur[3] + 1 }
		end
		for _, s in ipairs(edges) do
			addNormal(s.comp.node0, s.comp.tangent0)
			addNormal(s.comp.node1, s.comp.tangent1)
		end
		local nodes : {Proposal.NodeAndEntity} = {}
		local twinId : {Engine.Entity : Engine.Entity} = {}
		local twinPos : {Engine.Entity : P3} = {}
		local E = #edges
		local nOld = #(street.nodesToAdd or {})
		local out : {Proposal.SegmentAndEntity} = {}
		-- ids, as the API wants them: the original edges -1..-E, the twin's edges -(E+1)..-(2E), then
		-- the original nodes, then the twin's nodes. The original proposal may number its new entities
		-- in any order (Connect: nodes and edges from one counter), so each id is mapped explicitly.
		local newId : {Engine.Entity : Engine.Entity} = {}
		for i, s in ipairs(edges) do newId[s.entity] = -i end
		for k, n in ipairs(street.nodesToAdd or {}) do newId[n.entity] = -(2 * E + k) end
		local function remapOld(id : Engine.Entity) : Engine.Entity
			if id >= 0 then return id end
			if not newId[id] then error("unknown new entity " .. tostring(id)) end
			return newId[id]
		end
		local function twinNode(id : Engine.Entity) : Engine.Entity
			if twinId[id] then return twinId[id] end
			local p, n = posOf(id), nrm[id]
			if not p or not n then error("node " .. tostring(id)) end
			local x, y, l = norm2(n[1], n[2])
			if l < 1e-3 then error("no direction at " .. tostring(id)) end
			-- mitre at a bend (the mean normal is shorter than 1 there)
			local c = math.max(0.35, l / n[3])
			local q = p3(p.x + x * offset / c, p.y + y * offset / c, p.z)
			local tid = -(2 * E + nOld + #nodes + 1)
			local node = api.type.NodeAndEntity.new()
			node.entity = tid
			node.comp.position = vec3(q)
			nodes[#nodes + 1] = node
			twinId[id], twinPos[id] = tid, q
			return tid
		end
		for i, s in ipairs(edges) do
			local c = s.comp
			local a, b = twinNode(c.node0), twinNode(c.node1)
			local p0, p1 = posOf(c.node0), posOf(c.node1)
			local q0, q1 = twinPos[c.node0], twinPos[c.node1]
			local oldLen = math.sqrt((p1.x - p0.x) ^ 2 + (p1.y - p0.y) ^ 2)
			local newLen = math.sqrt((q1.x - q0.x) ^ 2 + (q1.y - q0.y) ^ 2)
			local k = oldLen > 0.1 and newLen / oldLen or 1
			local seg = api.type.SegmentAndEntity.new()
			seg.entity = -(E + i)
			seg.comp = c
			seg.type = s.type
			pcall(function() if s.streetEdge then seg.streetEdge = s.streetEdge end end)
			local pc : Piece = {
				p0 = q0, t0 = p3(c.tangent0.x * k, c.tangent0.y * k, c.tangent0.z),
				p1 = q1, t1 = p3(c.tangent1.x * k, c.tangent1.y * k, c.tangent1.z),
			}
			setGeometry(seg, a, b, pc, flip)
			seg.comp.objects = {}
			out[#out + 1] = seg
		end
		-- copies of the original edges and nodes, renumbered round the twin's edges (the original
		-- proposal is left as it is: it is the one built)
		local all : {Proposal.SegmentAndEntity} = {}
		for _, s in ipairs(edges) do
			local s2 = api.type.SegmentAndEntity.new()
			s2.entity = remapOld(s.entity)
			s2.comp = s.comp
			s2.type = s.type
			pcall(function() if s.streetEdge then s2.streetEdge = s.streetEdge end end)
			pcall(function() if s.playerOwned then s2.playerOwned = s.playerOwned end end)
			s2.comp.node0, s2.comp.node1 = remapOld(s.comp.node0), remapOld(s.comp.node1)
			all[#all + 1] = s2
		end
		for _, s in ipairs(out) do all[#all + 1] = s end
		local allNodes : {Proposal.NodeAndEntity} = {}
		for _, n in ipairs(street.nodesToAdd or {}) do
			local n2 = api.type.NodeAndEntity.new()
			n2.entity = remapOld(n.entity)
			n2.comp = n.comp
			allNodes[#allNodes + 1] = n2
		end
		for _, n in ipairs(nodes) do allNodes[#allNodes + 1] = n end
		local p = api.type.SimpleProposal.new()
		p.streetProposal.edgesToAdd = all
		p.streetProposal.nodesToAdd = allNodes
		pcall(function() if #(street.edgesToRemove or {}) > 0 then p.streetProposal.edgesToRemove = street.edgesToRemove end end)
		pcall(function() if #(street.nodeConfigsToRemove or {}) > 0 then p.streetProposal.nodeConfigsToRemove = street.nodeConfigsToRemove end end)
		pcall(function()
			local rc : {Engine.Entity : integer} = {}
			local any = false
			for k2, v in pairs(street.node2rcType or {}) do rc[remapOld(k2 as Engine.Entity)] = v as integer; any = true end
			if any then p.streetProposal.node2rcType = rc end
		end)
		return p
	end)
	if not ok then
		dbg("[network_tools] twin preview failed: " .. tostring(res))
		return nil
	end
	return res
end

-- For Connect's chained sections (A -> B -> C ...): one proposal of several, each made on its own
-- against the same world. Their new entities are renumbered (edges first, then nodes, as the API
-- wants - whatever order each section used), and a new node of a later section at the same spot as
-- one already taken (the point two sections share) becomes that node: its segments' ends are moved
-- onto it exactly. Existing segments removed by two sections can't be combined: nil then (`why`).
local function mergeSections(list : {SimpleProposal}) : SimpleProposal, string
	local ok, res, why = pcall(function() : SimpleProposal, string
		local JOIN = 0.75   -- metres: new nodes this close are the same point
		local allEdges : {Proposal.SegmentAndEntity} = {}
		local keptNodes : {{number}} = {}    -- {x, y, z} of each node kept, by its index
		local nodeComps : {Proposal.NodeAndEntity} = {}
		local removed : {Engine.Entity : boolean} = {}
		local removeList : {Engine.Entity} = {}
		local cfg : {Engine.Entity : boolean} = {}
		local cfgList : {Engine.Entity} = {}
		local rc : {Engine.Entity : integer} = {}
		local anyRc = false
		-- edges are numbered as they come; nodes get placeholder keys first, real ids at the end
		local nodeKeyOf : {{Engine.Entity : integer}} = {}
		for si, sp in ipairs(list) do
			local street = sp.streetProposal
			local map : {Engine.Entity : integer} = {}
			nodeKeyOf[si] = map
			for _, n in ipairs(street.nodesToAdd or {}) do
				local p = n.comp.position
				local found : integer = nil
				-- (only a node of an earlier section: two of one section are never the same point)
				for k, q in ipairs(keptNodes) do
					if q[4] < si and (q[1] - p.x) ^ 2 + (q[2] - p.y) ^ 2 < JOIN * JOIN then found = k; break end
				end
				if not found then
					keptNodes[#keptNodes + 1] = { p.x, p.y, p.z, si }
					local n2 = api.type.NodeAndEntity.new()
					n2.comp = n.comp
					nodeComps[#nodeComps + 1] = n2
					found = #keptNodes
				end
				map[n.entity] = found
			end
			for _, e in ipairs(street.edgesToRemove or {}) do
				if removed[e] then return nil, "two sections split the same segment " .. tostring(e) end
				removed[e] = true
				removeList[#removeList + 1] = e
			end
			for _, n in ipairs(street.nodeConfigsToRemove or {}) do
				if not cfg[n] then cfg[n] = true; cfgList[#cfgList + 1] = n end
			end
		end
		-- a branch off another section's middle: a new node lying on a new segment of a section (away
		-- from its ends, at its height) splits that segment there - one junction node
		-- (every render while dragging: each segment read once into plain numbers {p0, p1, t0, t1 as
		-- x, y, z}, and only nodes inside its curve's bounding box looked at - reading the game's
		-- vectors per sample, for every segment against every node, dropped the frame rate)
		local function segAt(g : {number}, t : number) : number, number, number, number, number, number
			local t2, t3 = t * t, t * t * t
			local h00, h10, h01, h11 = 2 * t3 - 3 * t2 + 1, t3 - 2 * t2 + t, -2 * t3 + 3 * t2, t3 - t2
			local d00, d10, d01, d11 = 6 * t2 - 6 * t, 3 * t2 - 4 * t + 1, -6 * t2 + 6 * t, 3 * t2 - 2 * t
			return h00 * g[1] + h10 * g[7] + h01 * g[4] + h11 * g[10],
				h00 * g[2] + h10 * g[8] + h01 * g[5] + h11 * g[11],
				h00 * g[3] + h10 * g[9] + h01 * g[6] + h11 * g[12],
				d00 * g[1] + d10 * g[7] + d01 * g[4] + d11 * g[10],
				d00 * g[2] + d10 * g[8] + d01 * g[5] + d11 * g[11],
				d00 * g[3] + d10 * g[9] + d01 * g[6] + d11 * g[12]
		end
		local splitAt : {string : {number}} = {}   -- "section:index" -> {t, kept node}
		local geomOf : {string : {number}} = {}     -- ... its curve (the cut's direction)
		-- the road split at a kept node: its horizontal direction and grade there {ux, uy, grade}. A
		-- junction on a slope is refused (critical, no message) unless the branch leaves on the main
		-- road's plane - flat across it, its grade along it (as a switch must)
		local plane : {integer : {number}} = {}
		local nSplits = 0
		local NEAR = 2 * JOIN
		for si, sp in ipairs(list) do
			for i, s in ipairs(sp.streetProposal.edgesToAdd or {}) do
				local c = s.comp
				local p0, p1, t0, t1 = c.position0, c.position1, c.tangent0, c.tangent1
				local g = { p0.x, p0.y, p0.z, p1.x, p1.y, p1.z, t0.x, t0.y, t0.z, t1.x, t1.y, t1.z }
				-- the curve lies inside its Bezier control points' box
				local xs = { g[1], g[1] + g[7] / 3, g[4] - g[10] / 3, g[4] }
				local ys = { g[2], g[2] + g[8] / 3, g[5] - g[11] / 3, g[5] }
				local x0, x1 = math.min(xs[1], xs[2], xs[3], xs[4]) - NEAR, math.max(xs[1], xs[2], xs[3], xs[4]) + NEAR
				local y0, y1 = math.min(ys[1], ys[2], ys[3], ys[4]) - NEAR, math.max(ys[1], ys[2], ys[3], ys[4]) + NEAR
				local key = tostring(si) .. ":" .. tostring(i)
				for k, q in ipairs(keptNodes) do
					if not splitAt[key] and q[1] >= x0 and q[1] <= x1 and q[2] >= y0 and q[2] <= y1
							and (g[1] - q[1]) ^ 2 + (g[2] - q[2]) ^ 2 > NEAR * NEAR
							and (g[4] - q[1]) ^ 2 + (g[5] - q[2]) ^ 2 > NEAR * NEAR then
						-- nearest t: samples, then halvings
						local bt, bd = 0.0, math.huge
						for j = 0, 24 do
							local px, py = segAt(g, j / 24)
							local d = (px - q[1]) ^ 2 + (py - q[2]) ^ 2
							if d < bd then bt, bd = j / 24, d end
						end
						local h = 1 / 24
						for _ = 1, 8 do
							h = h / 2
							for _, t in ipairs({ bt - h, bt + h }) do
								if t > 0 and t < 1 then
									local px, py = segAt(g, t)
									local d = (px - q[1]) ^ 2 + (py - q[2]) ^ 2
									if d < bd then bt, bd = t, d end
								end
							end
						end
						if bd < NEAR * NEAR then
							local _x, _y, pz, dx, dy, dz = segAt(g, bt)
							-- (no stub: a piece shorter than this next to the junction is refused by the
							-- game - Connect puts a branch that close onto the node instead)
							local L = 0.0
							local qx, qy = g[1], g[2]
							for j = 1, 16 do
								local rx, ry = segAt(g, j / 16)
								L = L + math.sqrt((rx - qx) ^ 2 + (ry - qy) ^ 2)
								qx, qy = rx, ry
							end
							local MIN_PIECE = 8
							if math.abs(pz - q[3]) < 1.5 and bt * L > MIN_PIECE and (1 - bt) * L > MIN_PIECE then
								splitAt[key], geomOf[key] = { bt, k }, g
								nSplits = nSplits + 1
								local l = math.sqrt(dx * dx + dy * dy)
								if l > 1e-6 then plane[k] = { dx / l, dy / l, dz / l } end
							end
						end
					end
				end
			end
		end
		-- final ids: edges -1..-E, nodes after
		local E = nSplits
		for _, sp in ipairs(list) do E = E + #(sp.streetProposal.edgesToAdd or {}) end
		for k, n2 in ipairs(nodeComps) do n2.entity = -(E + k) end
		local e = 0
		for si, sp in ipairs(list) do
			local street = sp.streetProposal
			local map = nodeKeyOf[si]
			local function nodeId(id : Engine.Entity) : Engine.Entity
				if id >= 0 then return id end
				if not map[id] then error("section " .. tostring(si) .. ": unknown node " .. tostring(id)) end
				return -(E + map[id])
			end
			for i, s in ipairs(street.edgesToAdd or {}) do
				-- (a split one: two halves, meeting at the branch's node)
				local cutKey = tostring(si) .. ":" .. tostring(i)
				local cut = splitAt[cutKey]
				for half = 1, cut and 2 or 1 do
					e = e + 1
					local s2 = api.type.SegmentAndEntity.new()
					s2.entity = -e
					s2.comp = s.comp
					s2.type = s.type
					pcall(function() if s.streetEdge then s2.streetEdge = s.streetEdge end end)
					pcall(function() if s.playerOwned then s2.playerOwned = s.playerOwned end end)
					local n0, n1 = s.comp.node0, s.comp.node1
					s2.comp.node0, s2.comp.node1 = nodeId(n0), nodeId(n1)
					-- an end on a shared point sits exactly on the node kept for it
					if n0 < 0 then local q = keptNodes[map[n0]]; s2.comp.position0 = api.type.Vec3f.new(q[1], q[2], q[3]) end
					if n1 < 0 then local q = keptNodes[map[n1]]; s2.comp.position1 = api.type.Vec3f.new(q[1], q[2], q[3]) end
					-- a branch's end at a split node: onto the main road's plane there
					local pl0 = n0 < 0 and plane[map[n0]] or nil
					local pl1 = n1 < 0 and plane[map[n1]] or nil
					if pl0 then
						local tg = s2.comp.tangent0
						s2.comp.tangent0 = api.type.Vec3f.new(tg.x, tg.y, pl0[3] * (tg.x * pl0[1] + tg.y * pl0[2]))
					end
					if pl1 then
						local tg = s2.comp.tangent1
						s2.comp.tangent1 = api.type.Vec3f.new(tg.x, tg.y, pl1[3] * (tg.x * pl1[1] + tg.y * pl1[2]))
					end
					if cut then
						-- the curve cut at t: each half's tangents scale with its share of t
						local t = cut[1]
						local kN = math.floor(cut[2])
						local q = keptNodes[kN]
						local P = api.type.Vec3f.new(q[1], q[2], q[3])
						local mid = -(E + kN)
						local g = geomOf[cutKey]
						local _x, _y, _z, dx, dy, dz = segAt(g, t)
						if half == 1 then
							s2.comp.node1, s2.comp.position1 = mid, P
							s2.comp.tangent0 = api.type.Vec3f.new(g[7] * t, g[8] * t, g[9] * t)
							s2.comp.tangent1 = api.type.Vec3f.new(dx * t, dy * t, dz * t)
						else
							local u = 1 - t
							s2.comp.node0, s2.comp.position0 = mid, P
							s2.comp.tangent0 = api.type.Vec3f.new(dx * u, dy * u, dz * u)
							s2.comp.tangent1 = api.type.Vec3f.new(g[10] * u, g[11] * u, g[12] * u)
						end
					end
					allEdges[#allEdges + 1] = s2
				end
			end
			pcall(function()
				for k2, v in pairs(street.node2rcType or {}) do
					local id = k2 as Engine.Entity
					rc[id < 0 and nodeId(id) or id] = v as integer
					anyRc = true
				end
			end)
		end
		local p = api.type.SimpleProposal.new()
		p.streetProposal.edgesToAdd = allEdges
		p.streetProposal.nodesToAdd = nodeComps
		if #removeList > 0 then p.streetProposal.edgesToRemove = removeList end
		if #cfgList > 0 then p.streetProposal.nodeConfigsToRemove = cfgList end
		if anyRc then pcall(function() p.streetProposal.node2rcType = rc end) end
		-- town houses each section demolishes
		pcall(function()
			local seen : {Engine.Entity : boolean} = {}
			local houses : {Engine.Entity} = {}
			for _, sp in ipairs(list) do
				for _, h in ipairs(((sp as {string : any}).constructionsToRemove or {}) as {Engine.Entity}) do
					if not seen[h] then seen[h] = true; houses[#houses + 1] = h end
				end
			end
			if #houses > 0 then (p as {string : any}).constructionsToRemove = houses end
		end)
		return p, nil
	end)
	if not ok then
		dbg("[network_tools] merging sections failed: " .. tostring(res))
		return nil, tostring(res)
	end
	return res, why
end

return {
	init = init,
	opts = opts,
	copyProposal = copyProposal,
	withTwinPreview = withTwinPreview,
	mergeSections = mergeSections,
	ParallelActionRecipe = ParallelActionRecipe,
}
