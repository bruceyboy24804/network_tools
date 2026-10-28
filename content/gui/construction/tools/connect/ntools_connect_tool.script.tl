-- Network Tools: Connect
-- Modelled on the connection modes of Network Multitool for Cities: Skylines 1
-- (MacSergey/NetworkMultitool, ToolModes/ConnectionModes).
--
-- Pick two nodes (click a road/track near its end), shape the connection, then press Build on the toolbar.
-- Clicking the first node again clears the selection. Once both ends are set, N toggles move ends
-- mode: then a press near the start / end point drags it (onto a road to join it), even where a
-- circle overlaps it. Shift+double-click adds a waypoint (Straight / Curve) or a circle
-- (Connection). Otherwise a click on bare ground does nothing, so the ends move only by dragging
-- their handles or clicking a road. (Ctrl+click would be the game's camera.)
--
-- Modes:
--   Connection - an arc leaving each road, joined by a straight (CS1 CreateConnection).
--                Drag a circle centre: along the road = move the arc, away = radius,
--                across the road = turn the other way.
--   Loop       - one circle tangent to both road lines, centred on their bisector (CS1 CreateLoop).
--                Drag the centre to change the radius; drag it past the lines' crossing point
--                to switch between a corner and a loop.
--   Curve      - smooth curve following both road directions (CS1 CreateCurve).
--   Straight   - direct line.
--
-- Like CS1, long curves are split into several segments and height is spread evenly.

local builtin = ug_require "::/gui/main/builtin.lua" as Builtin
local construction_react_util = ug_require "::/gui/construction/construction_react_util.tl" as ConstructionReactUtil
local engine_react_util = ug_require "::/gui/main/engine_react_util.tl" as EngineReactUtil
local menu_category_util = ug_require "::/gui/main/menu_category_util.tl" as MenuCategoryUtil
local react = ug_require "::/gui/main/react.lua" as React
local leave = require "network_tools_1::/gui/construction/tools/shared/ntools_leave.script.tl" as function(any)

-- in-world tags on segments and points (shared/ntools_labels)
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
	level : integer
end
local record Labels
	set : function(tags : {Engine.Entity : Tag}, points? : {LabelPoint})
	node : function() : TreeNodeId
	icons : {string : string}
end
local labels = require "network_tools_1::/gui/construction/tools/shared/ntools_labels.script.tl" as Labels

-- the build preview: the game's ProposalViewer, or our own green one in Anarchy (no red)
local record PreviewParams
	proposal : SimpleProposal
	id : string
	onData : function(ProposalData)
	anarchy : boolean
end
local record Preview
	viewer : function(p : PreviewParams) : TreeNodeId
	takeEdges : function() : {Builtin.Type.EdgeRenderable.Edge}
	leftover : function() : TreeNodeId
	clear : function()
end
local preview = require "network_tools_1::/gui/construction/tools/shared/ntools_preview.script.tl" as Preview

local MODE_PARAM = "ntools_mode"
local MODE_CONNECTION = 1
local MODE_LOOP = 2
local MODE_CURVE = 3
local MODE_STRAIGHT = 4

local MAX_PIECE_LENGTH = 100    -- metres per built segment (CS1: Settings.SegmentLength)
local MIN_PRIM_LENGTH = 1.0     -- path parts shorter than this are dropped
local MIN_RADIUS = 12
local MAX_RADIUS = 2000
local DEFAULT_RADIUS = 50
local MAX_GUIDE_T = 5000        -- CS1 rejects guide crossings further away than this

local HANDLE_RADIUS_M = 4
local HANDLE_HIT_RADIUS_M = 10
-- drag target for a point picked on bare ground: DRAG_POINT + 1 (end 1) / + 2 (end 2)
local DRAG_POINT = 1000
-- State shared between the toolbar params (evaluated in getDefinition context) and the recipe.
-- Pattern from the MoveIt mod: the recipe publishes what the toolbar needs to show/hide, the
-- toolbar's onChangeFn fires react events that the recipe handles.
local g_paramsApi : ConstructionMenuParamsAPI = nil
local g_followTerrain = false
-- set by the Mode toolbar buttons; toolbar params don't reliably show up in getCurrentParams()
local g_mode : integer = nil
local g_snap = true
-- Anarchy: build without collision checks (ignoreErrors on the build command, like MoveIt)
local g_anarchy = false
-- automatic bridges / tunnels and raising the path over its own crossings
local g_bridges = true
-- Replace: edit existing roads - the old road between the two points is removed and the new
-- shape built in its place
local g_replace = false
-- Live preview (like the Overpass Builder mod): the game previews the real proposal. Off: only a
-- schematic of the planned road in our own overlay - the game's preview, rebuilt on every change,
-- is what costs frames. Build then sends the proposal without that check (the game still refuses
-- an invalid one).
local g_livePreview = true
-- Twin: after building, a parallel copy of the connection (double track / dual carriageway).
-- side: 0 off, +1 left, -1 right; copy: Parallel's copyProposal (set once the tools are loaded)
local record Twin
	side : integer
	copy : function(chain : {{string : any}}, offset : number, flip : boolean) : SimpleProposal
	-- Parallel's withTwinPreview: the proposal plus where the twin will run, for the preview
	preview : function(sp : SimpleProposal, offset : number, flip : boolean) : SimpleProposal
	-- Parallel's mergeSections (chained sections into one proposal; lives with Twin's helpers)
	merge : function(list : {SimpleProposal}) : SimpleProposal, string
end
local g_twin : Twin = { side = 0 }
-- carrier of the connection being built (drives the bridge/tunnel pickers)
local g_isTrack = false
-- bridge / tunnel / level-crossing type picked on the toolbar: nil = automatic, -1 = none
local g_bridgeType : integer = nil
local g_tunnelType : integer = nil
local g_rcType : integer = nil
local record UiState
	ready : boolean
	mode : integer
	hasEnd : boolean      -- the selection has a road end (angle buttons)
	isMiddle : boolean    -- a middle circle is selected (remove button)
	canBuild : boolean
end
local g_ui : UiState = { ready = false, mode = 1, hasEnd = false, isMiddle = false, canBuild = false }

local FOLLOW_PARAM = "ntools_follow_terrain"
local SNAP_PARAM = "ntools_snap"
local ANARCHY_PARAM = "ntools_anarchy"
local BRIDGES_PARAM = "ntools_bridges"
local TOOLBAR_EVENTS = {
	"ntoolsRadiusDown", "ntoolsRadiusUp", "ntoolsPrev", "ntoolsNext",
	"ntoolsAngleDown", "ntoolsAngleUp", "ntoolsAddCircle", "ntoolsRemoveCircle",
	"ntoolsFlip", "ntoolsResetShape", "ntoolsBuild",
}

local function refreshToolbar()
	if g_paramsApi then
		pcall(function() g_paramsApi.updateVisibility() end)
	end
end

-- Keep a toolbar checkbox in step with a keyboard toggle. The checkbox onChangeFns derive their
-- flag from newValue (idempotent), so the re-fired onChangeFn doesn't flip it back.
local function syncCheckbox(key : string, value : boolean)
	if not g_paramsApi then return end
	pcall(function()
		local info = g_paramsApi.getParamByKey(key)
		local v = value and 2 or 1
		if info and info.value ~= v then
			g_paramsApi.changeParam(info.index, v)
		end
	end)
end

-- Min. radius mode: shortest path of arcs (at least the radius) and straights, from
-- connect/min_radius/ntools_dubins (the other modes' modules are set up further down, see ConnectModes)
local dubins = require "network_tools_1::/gui/construction/tools/connect/min_radius/ntools_dubins.script.tl" as {string : any}

-- Logged every time this file is (re)loaded, so hot reloads are visible in stdout.txt (debug only).
do ((require "network_tools_1::/gui/construction/tools/shared/ntools_debug.script.tl" as {string : any}).log as function(string))("[network_tools] connect tool script loaded (v29: modes split into connect/<mode>/)") end

----------------------------------------------------------------------------------------------------
-- Types

-- One end of the connection:
--   "node":  an existing node (edge: one of its segments - the end's direction and network)
--   "split": a point partway along `edge` at parameter t - the segment is split there
--   "free":  bare ground at pos - a new dead-end node
local record P3
	x : number
	y : number
	z : number
	lift : number     -- waypoints: the road's own height offset there (nil = 0)
	hx : number       -- Curve waypoints: their front handle, as an offset from the point (the road's
	hy : number       -- direction there, and a third of its tangent going on); nil = automatic
	hb : number       -- the back handle's length (it points the opposite way: a third of the tangent
	                  -- coming in); nil = as long as the front one
end

local record Pick
	kind : string
	node : Engine.Entity
	edge : Engine.Entity
	t : number
	pos : P3
	dir : {number}    -- a fixed way the road leaves this point (a chained section's start: the way
	                  -- the previous one arrived), else nil
	axis : {number}   -- a branch off another section of the chain: the line it leaves along (the
	                  -- side towards the other end), else nil
end

-- One cubic Hermite segment (position + tangent at both ends).
local record Piece
	p0 : P3
	t0 : P3
	p1 : P3
	t1 : P3
	over : string   -- "bridge" / "tunnel": it passes over / under an existing road or track (makeProposal)
end

-- 2D path primitive: a line or a circular arc (sweep > 0 = counter-clockwise).
local record Prim
	line : boolean
	px : number
	py : number
	qx : number
	qy : number
	cx : number
	cy : number
	r : number
	a0 : number
	sweep : number
end

-- 2D Hermite piece before heights are assigned.
local record Piece2
	x0 : number
	y0 : number
	tx0 : number
	ty0 : number
	x1 : number
	y1 : number
	tx1 : number
	ty1 : number
	len : number
end

-- Connection mode: one circle per end, described relative to that end's road direction.
local record ConnCircle
	offset : number   -- distance along the road direction where the arc starts
	radius : number
	side : number     -- +1 = centre left of the road direction, -1 = right
	lift : number     -- the road's height offset on this arc (nil = 0)
	liftEnd : number  -- at the arc's end, when it differs from its start (nil = lift all along)
	structure : integer -- the arc's structure: nil / 1 automatic, 2 ground, 3 bridge, 4 tunnel
end

-- A free circle between the two ends (CS1: inserted by double-clicking a straight).
local record MidCircle
	x : number
	y : number
	radius : number
	orient : number   -- +1 = travel counter-clockwise, -1 = clockwise
	lift : number     -- the road's height offset on this arc (nil = 0)
	liftEnd : number  -- see ConnCircle
	structure : integer
end

local record ConnState
	first : ConnCircle
	last : ConnCircle
	middle : {MidCircle}
end

-- A circle in travel order with its travel orientation.
local record Circ
	x : number
	y : number
	r : number
	w : number
end

local record LoopState
	radius : number
	loop : boolean    -- false = corner (circle inside the angle), true = loop (outside)
end

local record Circle2
	x : number
	y : number
	r : number
end

local record Line2
	x0 : number
	y0 : number
	x1 : number
	y1 : number
	w : number     -- endLines: a piece of a solid direction arrow, this wide (metres); nil = a thin line
end

-- one line of the schematic preview (live preview off): from p to q, coloured by kind
local record Schematic
	x0 : number
	y0 : number
	z0 : number
	x1 : number
	y1 : number
	z1 : number
	kind : string     -- "normal", "bridge", "tunnel" or "bad"
	pc : Piece        -- the piece's curve (drawn as one curved strip; z0 / z1 carry its lift)
end

local record GenResult
	pieces : {Piece}
	error : string
	handles : {P3}
	circles : {Circle2}
	guides : {Line2}
	straights : {Line2}   -- Connection: straight k joins circle k and k+1
	endLines : {Line2}    -- direction arrows at the picked nodes
	endRings : {Circle2}  -- rings around the picked nodes
	pointHandles : {P3}   -- handles at points picked on bare ground (drag to move them)
	snapRings : {Circle2} -- loose ends of the chain's other sections (M) an end snaps back onto
	snapHot : {Circle2}   -- ... the one the dragged end is snapped onto now
	schematic : {Schematic}  -- live preview off: the planned road as coloured lines
	twinLines : {Line2}   -- outline of the twin (built after the connection, see g_twin)
	twinPreviewed : boolean -- the game's preview shows the twin (then no outline)
	hideCircles : boolean   -- move ends mode: the circles and their handles aren't drawn
	hideEnds : boolean      -- circles shown: the two ends' rings / handles aren't drawn
	twinProposal : SimpleProposal -- the connection plus the twin (built so when no end is a node)
	info : string
end

local function p3(x : number, y : number, z : number) : P3
	return { x = x, y = y, z = z }
end

local function lerp(a : number, b : number, t : number) : number
	return a + (b - a) * t
end

local function clamp(v : number, lo : number, hi : number) : number
	return math.max(lo, math.min(hi, v))
end

local function cross2(ax : number, ay : number, bx : number, by : number) : number
	return ax * by - ay * bx
end

local function dot2(ax : number, ay : number, bx : number, by : number) : number
	return ax * bx + ay * by
end

local function norm2(x : number, y : number) : number, number, number
	local len = math.sqrt(x * x + y * y)
	if len < 1e-9 then
		return 0, 0, 0
	end
	return x / len, y / len, len
end

----------------------------------------------------------------------------------------------------
-- Engine helpers

local function getEdge(entity : Engine.Entity) : Engine.Component.BaseEdge
	if not entity or entity < 0 or not api.engine.entityExists(entity) then
		return nil
	end
	return api.engine.getComponent(entity, api.type.ComponentType.BASE_EDGE) as Engine.Component.BaseEdge
end

local function getNodePos(entity : Engine.Entity) : P3
	local node = api.engine.getComponent(entity, api.type.ComponentType.BASE_NODE) as Engine.Component.BaseNode
	if not node then
		return nil
	end
	return p3(node.position.x, node.position.y, node.position.z)
end

-- A segment, or a station / depot (a construction) under the mouse: the selector names the
-- construction, not its tracks. Then also its track (frozen edge) closest to the mouse, and that
-- track's end where the network joins the construction (a node that isn't frozen).
-- (One function: the script's main body is at Lua's 200-local limit. The other tools are handed a
-- segments-only check.)
local function isEdge(entity : Engine.Entity) : boolean, Engine.Entity, Engine.Entity
	if getEdge(entity) ~= nil then return true, nil, nil end
	local edgeOut, nodeOut : Engine.Entity, Engine.Entity = nil, nil
	pcall(function()
		if not api.gui.mouse.hasTerrainPosition() then return end
		local sc = api.engine.system.streetConnectorSystem
		local CT = api.type.ComponentType
		local function conOf(x : Engine.Entity) : {string : any}
			return x and x >= 0 and api.engine.getComponent(x, CT.CONSTRUCTION) as {string : any} or nil
		end
		-- the construction behind what the selector names: itself, or the construction of a
		-- subconstruction / station (the selector names the station) / station group / depot
		local owner = entity
		local con = conOf(owner)
		local function try(f : function() : Engine.Entity)
			if con then return end
			local ok, x = pcall(f)
			if ok and conOf(x) then owner, con = x, conOf(x) end
		end
		try(function() : Engine.Entity return sc.getConstructionEntityForSubconstruction(entity) end)
		try(function() : Engine.Entity return sc.getConstructionEntityForStation(entity) end)
		try(function() : Engine.Entity return sc.getConstructionEntityForDepot(entity) end)
		try(function() : Engine.Entity
			local g = api.engine.getComponent(entity, CT.STATION_GROUP) as {string : any}
			local st = g and (g.stations as {Engine.Entity}) or {}
			return st[1] and sc.getConstructionEntityForStation(st[1]) or nil
		end)
		-- else: the construction owning the frozen nodes near the mouse (not for the ground / world:
		-- a click on open ground near a station must stay a click on the ground)
		if api.engine.getComponent(entity, CT.TERRAIN) == nil and api.engine.getComponent(entity, CT.WORLD) == nil then try(function() : Engine.Entity
			local mp = api.gui.mouse.getTerrainPosition()
			local best, bestD : Engine.Entity, number = nil, math.huge
			for _, n in ipairs(api.engine.util.octree.findEntitiesInCircle(api.type.Vec2f.new(mp.x, mp.y), 60, CT.BASE_NODE)) do
				local c = sc.getConstructionEntityForNode(n)
				local p = c and c >= 0 and getNodePos(n) or nil
				if p then
					local d = (p.x - mp.x) ^ 2 + (p.y - mp.y) ^ 2
					if d < bestD then best, bestD = c, d end
				end
			end
			return best
		end) end
		if con == nil then return end
		local frozenNode : {Engine.Entity : boolean} = {}
		for _, n in ipairs((con.frozenNodes or {}) as {Engine.Entity}) do frozenNode[n] = true end
		local m = api.gui.mouse.getTerrainPosition()
		-- pass 1: open ends only; pass 2 (none open): the nearest end of any of its tracks
		for pass = 1, 2 do
			local best = math.huge
			for _, e in ipairs((con.frozenEdges or {}) as {Engine.Entity}) do
				local edge = getEdge(e)
				if edge then
					for _, n in ipairs({ edge.node0, edge.node1 }) do
						local p = (pass == 2 or not frozenNode[n]) and getNodePos(n) or nil
						if p then
							local d = (p.x - m.x) ^ 2 + (p.y - m.y) ^ 2
							if d < best then best, edgeOut, nodeOut = d, e, n end
						end
					end
				end
			end
			if edgeOut then
				if pass == 2 then ((require "network_tools_1::/gui/construction/tools/shared/ntools_debug.script.tl" as {string : any}).log as function(string))("[network_tools] Connect: station " .. tostring(owner) .. " has no open track end, using node " .. tostring(nodeOut)) end
				break
			end
		end
	end)
	return edgeOut ~= nil, edgeOut, nodeOut
end

local record GeomPiece
	p0 : P3
	t0 : P3
	p1 : P3
	t1 : P3
end
local record Geom
	vec3 : function(p : P3) : Vec3f
	edgePiece : function(e : Engine.Component.BaseEdge) : GeomPiece
	split : function(pc : GeomPiece, ts : {number}) : {GeomPiece}
	length : function(pc : GeomPiece) : number
	closestT : function(pc : GeomPiece, x : number, y : number) : number, number
	point : function(pc : GeomPiece, t : number) : P3
	tangent : function(pc : GeomPiece, t : number) : P3
end
local geom = require "network_tools_1::/gui/construction/tools/shared/ntools_geom.script.tl" as Geom

local NODE_SNAP_M = 12      -- a click this close to a segment's end picks its node
local ROAD_SNAP_M = 10      -- Snap to roads: a click on bare ground this close to a road picks the road
local MIN_SPLIT_PART = 4    -- metres: shortest piece a split may leave

-- What a click on `edgeEntity` at (x, y) picks: its end node when the click is near one,
-- otherwise the point on the segment under the click (it gets split there).
local function pickOnEdge(edgeEntity : Engine.Entity, x : number, y : number) : Pick
	local edge = getEdge(edgeEntity)
	if not edge then
		return nil
	end
	local p0 = getNodePos(edge.node0)
	local p1 = getNodePos(edge.node1)
	if not p0 or not p1 then
		return nil
	end
	local pc = geom.edgePiece(edge)
	local t = geom.closestT(pc, x, y)
	local len = geom.length(pc)
	local d0 = math.sqrt((x - p0.x) ^ 2 + (y - p0.y) ^ 2)
	local d1 = math.sqrt((x - p1.x) ^ 2 + (y - p1.y) ^ 2)
	local snap = math.min(NODE_SNAP_M, len / 3)
	if d0 <= snap or t * len < MIN_SPLIT_PART or d1 <= snap or (1 - t) * len < MIN_SPLIT_PART then
		return { kind = "node", node = d1 < d0 and edge.node1 or edge.node0, edge = edgeEntity }
	end
	return { kind = "split", edge = edgeEntity, t = t, pos = geom.point(pc, t) }
end

-- The end node of the edge closest to the mouse cursor (Remove node uses this).
local function pickNodeOnEdge(edgeEntity : Engine.Entity) : Pick
	local edge = getEdge(edgeEntity)
	if not edge then return nil end
	local p0, p1 = getNodePos(edge.node0), getNodePos(edge.node1)
	if not p0 or not p1 then return nil end
	local node = edge.node0
	if api.gui.mouse.hasTerrainPosition() then
		local m = api.gui.mouse.getTerrainPosition()
		if (m.x - p1.x) ^ 2 + (m.y - p1.y) ^ 2 < (m.x - p0.x) ^ 2 + (m.y - p0.y) ^ 2 then node = edge.node1 end
	end
	return { kind = "node", node = node, edge = edgeEntity }
end

-- ground height for a new node (above the water surface on water); set once the terrain module
-- is loaded further down
local nodeHeight : function(x : number, y : number) : number = nil

-- a point on bare ground
local function pickFree(x : number, y : number) : Pick
	local z : number = nil
	if nodeHeight then
		local okZ, h = pcall(nodeHeight, x, y)
		if okZ then z = h end
	end
	if not z then
		local okG, h = pcall(function() : number return api.engine.terrain.getHeightAt(api.type.Vec2f.new(x, y)) end)
		z = okG and h or 0
	end
	return { kind = "free", pos = p3(x, y, z) }
end

local function pickPos(pick : Pick) : P3
	if not pick then return nil end
	if pick.kind == "node" then return getNodePos(pick.node) end
	return pick.pos
end

-- identity of a pick (preview cache keys, "same point" tests)
local function pickKey(pick : Pick) : string
	if not pick then return "-" end
	if pick.kind == "node" then return "n" .. tostring(pick.node) end
	return string.format("%s%s@%.2f,%.2f", pick.kind, tostring(pick.edge), pick.pos.x, pick.pos.y)
end

-- Horizontal unit direction pointing away from the existing edge at the picked node,
-- i.e. the direction in which the road would naturally continue (CS1: the "trajectory").
local function continuationDir(pick : Pick) : number, number
	local edge = getEdge(pick.edge)
	if not edge then
		return nil, nil
	end
	local x, y : number, number
	if pick.node == edge.node0 then
		x, y = -edge.tangent0.x, -edge.tangent0.y
	else
		x, y = edge.tangent1.x, edge.tangent1.y
	end
	local ux, uy, len = norm2(x, y)
	if len < 1e-6 then
		return nil, nil
	end
	return ux, uy
end

----------------------------------------------------------------------------------------------------
-- Replace: the existing road between the two picks (edit mode)

local record NetUtil
	whyNotReplaceable : function(edge : Engine.Entity, allowUserConfig? : boolean) : string
	configNodesFor : function(removedEdges : {Engine.Entity}, extraNodes? : {Engine.Entity}, skipNodes? : {Engine.Entity}) : {Engine.Entity}
	isCrossingNode : function(node : Engine.Entity) : boolean
	rebuildCrossings : function(proposal : SimpleProposal, removedEdges : {Engine.Entity}, skipNodes? : {Engine.Entity}) : integer
	carryConfigs : function(proposal : SimpleProposal, nodes : {Engine.Entity}, remap : {Engine.Entity : {Engine.Entity : Engine.Entity | boolean}}) : integer
end
local net_util = require "network_tools_1::/gui/construction/tools/shared/ntools_net_util.script.tl" as NetUtil

-- options shared by all tools (panel): underground view, new-road properties, Connect's height
-- offset / incline / snapping / override lanes
local record SharedOptions
	record Opts
		underground : boolean
		heightOffset : number
		incline : number
		snapToRoads : boolean
		overrideLanes : boolean
		pointLabel : string
		pointHeight : number
		pointCircle : boolean
		pointHeightEnd : number
		pointRadius : number
		pointStructure : integer
		pointMovable : boolean
		pointMove : {number}
		pointSent : string
		buildMenu : boolean
	end
	opts : Opts
	key : function() : string
	layerNode : function() : TreeNodeId
	applyRoad : function(seg : Proposal.SegmentAndEntity)
	send : function(cmd : Command<WorldBuildProposalCommandData>, callback? : function(WorldBuildProposalCommandData, boolean), newRoads? : boolean)
	debug : function(msg : string)   -- diagnostic traces (ntools_debug)
end
local shared = require "network_tools_1::/gui/construction/tools/shared/ntools_options.script.tl" as SharedOptions

local record ReplacePlan
	edges : {Engine.Entity}              -- whole segments removed
	used : {Engine.Entity : string}      -- split segment -> part removed: "lo" (node0 side), "hi" (node1 side), "mid" (between two splits)
	nodes : {Engine.Entity}              -- nodes left without a segment (removed too)
	error : string
end

-- (cached: a segment keeps its shape for as long as it keeps its id - rebuilt ones get new ids)
local g_edgeLength : {Engine.Entity : number} = {}
local function edgeLength(entity : Engine.Entity) : number
	local cached = g_edgeLength[entity]
	if cached then return cached end
	local e = getEdge(entity)
	if not e then return math.huge end
	local L = geom.length(geom.edgePiece(e))
	g_edgeLength[entity] = L
	return L
end

local function segmentsAt(node : Engine.Entity) : {Engine.Entity}
	local ok, segs = pcall(function() : {Engine.Entity} return api.engine.system.streetSystem.getNodeSegments(node) end)
	return ok and segs or {}
end

-- The shortest stretch of existing road (same road / track kind) from pick a to pick b.
local function findReplacePath(a : Pick, b : Pick) : ReplacePlan
	if a.kind == "free" or b.kind == "free" then
		return { error = _("Replace: both points must be on the existing road") }
	end
	if a.kind == "split" and b.kind == "split" and a.edge == b.edge then
		return { edges = {}, used = { [a.edge] = "mid" }, nodes = {} }
	end
	local ea = getEdge(a.edge)
	if not ea then return { error = _("Replace: can't read the road") } end
	local roadType = ea.roadType

	-- sources (around a) and targets (around b): node -> { distance, part of the split segment used }
	local record End
		d : number
		side : string
	end
	local function ends(p : Pick) : {Engine.Entity : End}
		if p.kind == "node" then return { [p.node] = { d = 0 } } end
		local e = getEdge(p.edge)
		local L = edgeLength(p.edge)
		local out : {Engine.Entity : End} = {}
		out[e.node0] = { d = p.t * L, side = "lo" }
		local d1 = (1 - p.t) * L
		if not out[e.node1] or d1 < out[e.node1].d then out[e.node1] = { d = d1, side = "hi" } end
		return out
	end
	local sources, targets = ends(a), ends(b)
	-- a split segment is never walked whole
	local skip : {Engine.Entity : boolean} = {}
	if a.kind == "split" then skip[a.edge] = true end
	if b.kind == "split" then skip[b.edge] = true end

	local dist : {Engine.Entity : number} = {}
	local via : {Engine.Entity : Engine.Entity} = {}     -- node -> segment it was reached by
	local prev : {Engine.Entity : Engine.Entity} = {}    -- node -> node before it
	local origin : {Engine.Entity : Engine.Entity} = {}  -- node -> the source node its path starts at
	local done : {Engine.Entity : boolean} = {}
	for n, s in pairs(sources) do dist[n], origin[n] = s.d, n end
	local bestNode : Engine.Entity = nil
	local bestD = math.huge
	for _ = 1, 5000 do   -- at most this many nodes searched
		local cur : Engine.Entity = nil
		local cd = math.huge
		for n, d in pairs(dist) do
			if not done[n] and d < cd then cur, cd = n, d end
		end
		if not cur or cd >= bestD then break end
		done[cur] = true
		if targets[cur] and cd + targets[cur].d < bestD then bestNode, bestD = cur, cd + targets[cur].d end
		for _, s in ipairs(segmentsAt(cur)) do
			local e = getEdge(s)
			if e and not skip[s] and e.roadType == roadType then
				local nxt = e.node0 == cur and e.node1 or e.node0
				local nd = cd + edgeLength(s)
				if not done[nxt] and (dist[nxt] == nil or nd < dist[nxt]) then
					dist[nxt], via[nxt], prev[nxt], origin[nxt] = nd, s, cur, origin[cur]
				end
			end
		end
	end
	if not bestNode then
		return { error = _("Replace: these points aren't joined by the road") }
	end

	local plan : ReplacePlan = { edges = {}, used = {}, nodes = {} }
	local n = bestNode
	while via[n] do
		table.insert(plan.edges, 1, via[n])
		n = prev[n]
	end
	if a.kind == "split" then plan.used[a.edge] = sources[origin[bestNode]].side end
	if b.kind == "split" then plan.used[b.edge] = targets[bestNode].side end

	-- nodes the removal leaves without any segment (not the picked ends: they get the new road)
	local removedAt : {Engine.Entity : integer} = {}
	local function count(node : Engine.Entity) removedAt[node] = (removedAt[node] or 0) + 1 end
	for _, s in ipairs(plan.edges) do
		local e = getEdge(s)
		count(e.node0)
		count(e.node1)
	end
	for s, side in pairs(plan.used) do
		local e = getEdge(s)
		if side == "lo" then count(e.node0) elseif side == "hi" then count(e.node1) end
	end
	for node, k in pairs(removedAt) do
		if node ~= a.node and node ~= b.node and k >= #segmentsAt(node) then
			plan.nodes[#plan.nodes + 1] = node
		end
	end
	return plan
end

-- Unit direction the new road leaves pick p in (towards `other` when nothing else decides it).
-- With a replace plan, it continues the road that stays.
local function endDir(p : Pick, other : P3, plan : ReplacePlan, otherPick : Pick) : number, number
	-- a chained section's start carries on the way the previous section arrived
	if p.dir then return p.dir[1], p.dir[2] end
	local P = pickPos(p)
	-- a branch off another section: along its axis, on the other end's side
	if p.axis then
		local s = (other.x - P.x) * p.axis[1] + (other.y - P.y) * p.axis[2]
		if s < 0 then return -p.axis[1], -p.axis[2] end
		return p.axis[1], p.axis[2]
	end
	if p.kind == "free" then
		local ux, uy, len = norm2(other.x - P.x, other.y - P.y)
		if len < 1e-6 then return nil, nil end
		return ux, uy
	end
	if p.kind == "split" then
		local e = getEdge(p.edge)
		if not e then return nil, nil end
		local d = geom.tangent(geom.edgePiece(e), p.t)
		local ux, uy, len = norm2(d.x, d.y)
		if len < 1e-6 then return nil, nil end
		local side = plan and plan.used and plan.used[p.edge]
		if side == "mid" then
			-- the kept part on this pick's side: below the smaller t, above the larger
			side = (p.t < otherPick.t) and "hi" or "lo"
		end
		if side == "lo" then return -ux, -uy end    -- the node0 side goes: continue from the node1 part
		if side == "hi" then return ux, uy end
		-- a branch (a T-junction): square off the road, on the side the route goes to. (Along the
		-- road, the first arc ran over the road it branches from - a collision.) O / P still turn it.
		local nx, ny = -uy, ux
		if (other.x - P.x) * nx + (other.y - P.y) * ny < 0 then return -nx, -ny end
		return nx, ny
	end
	-- an existing node
	if plan and plan.edges then
		local removed : {Engine.Entity : boolean} = {}
		for _, s in ipairs(plan.edges) do removed[s] = true end
		for s, side in pairs(plan.used or {}) do
			local e = getEdge(s)
			if side == "mid" or (side == "lo" and e.node0 == p.node) or (side == "hi" and e.node1 == p.node) then removed[s] = true end
		end
		local roadType = getEdge(p.edge) and getEdge(p.edge).roadType
		-- continue the segment that stays (the one running most nearly straight on)
		local bx, by : number, number = nil, nil
		local bestDot = -math.huge
		local into : Engine.Entity = nil
		for _, s in ipairs(segmentsAt(p.node)) do
			local e = getEdge(s)
			if e and e.roadType == roadType then
				if removed[s] then
					into = into or s
				else
					local dx, dy = continuationDir({ kind = "node", node = p.node, edge = s })
					if dx then
						local dot = dx * (other.x - P.x) + dy * (other.y - P.y)
						if dot > bestDot then bx, by, bestDot = dx, dy, dot end
					end
				end
			end
		end
		if bx then return bx, by end
		-- a dead end: leave the way the old road did
		if into then
			local dx, dy = continuationDir({ kind = "node", node = p.node, edge = into })
			if dx then return -dx, -dy end
		end
	end
	-- a node with roads leaving it in several directions (partway along a road, a junction):
	-- straight on from the picked segment would run down the next one. Leave into the free gap
	-- between them that faces the other point (or the widest gap when that one is too narrow).
	local outs : {number} = {}
	for _, s in ipairs(segmentsAt(p.node)) do
		local dx, dy = continuationDir({ kind = "node", node = p.node, edge = s })
		-- (continuationDir points away from the segment: the segment itself leaves the other way)
		if dx then outs[#outs + 1] = math.atan2(-dy, -dx) end
	end
	if #outs >= 2 then
		table.sort(outs)
		local toOther = math.atan2(other.y - P.y, other.x - P.x)
		local MIN_GAP = math.pi / 3     -- a gap narrower than 60 degrees is no place for a road
		local bestMid, bestScore : number, number = nil, -math.huge
		for i = 1, #outs do
			local a0 = outs[i]
			local a1 = i < #outs and outs[i + 1] or outs[1] + 2 * math.pi
			local gap = a1 - a0
			local mid = a0 + gap / 2
			-- prefer the gap the other point lies in, then the widest
			local rel = (toOther - a0) % (2 * math.pi)
			local score = gap + ((rel < gap and gap >= MIN_GAP) and 10 or 0)
			if score > bestScore then bestMid, bestScore = mid, score end
		end
		return math.cos(bestMid), math.sin(bestMid)
	end
	return continuationDir(p)
end

----------------------------------------------------------------------------------------------------
-- Path primitives -> Hermite pieces

local function linePrim(px : number, py : number, qx : number, qy : number) : Prim
	return { line = true, px = px, py = py, qx = qx, qy = qy }
end

-- Arc on circle (cx, cy, r) from point s to point e, travelling with orientation `orient`
-- (+1 counter-clockwise, -1 clockwise).
local function arcPrim(cx : number, cy : number, r : number, sx : number, sy : number, ex : number, ey : number, orient : number) : Prim
	local a0 = math.atan2(sy - cy, sx - cx)
	local a1 = math.atan2(ey - cy, ex - cx)
	local sweep = a1 - a0
	local tau = 2 * math.pi
	if orient > 0 then
		while sweep < 0 do sweep = sweep + tau end
		while sweep >= tau do sweep = sweep - tau end
	else
		while sweep > 0 do sweep = sweep - tau end
		while sweep <= -tau do sweep = sweep + tau end
	end
	if math.abs(sweep) > tau - 1e-3 then
		sweep = 0
	end
	return { line = false, cx = cx, cy = cy, r = r, a0 = a0, sweep = sweep }
end

local function primLength(p : Prim) : number
	if p.line then
		return math.sqrt((p.qx - p.px) ^ 2 + (p.qy - p.py) ^ 2)
	end
	return p.r * math.abs(p.sweep)
end

local function emitPrim(out : {Piece2}, p : Prim)
	local total = primLength(p)
	if total < MIN_PRIM_LENGTH then
		return
	end
	if p.line then
		local n = math.max(1, math.ceil(total / MAX_PIECE_LENGTH))
		local dx, dy = (p.qx - p.px) / n, (p.qy - p.py) / n
		for i = 0, n - 1 do
			out[#out + 1] = {
				x0 = p.px + dx * i, y0 = p.py + dy * i, tx0 = dx, ty0 = dy,
				x1 = p.px + dx * (i + 1), y1 = p.py + dy * (i + 1), tx1 = dx, ty1 = dy,
				len = total / n,
			}
		end
	else
		-- no piece longer than MAX_PIECE_LENGTH or wider than 90 degrees
		local n = math.max(1, math.ceil(total / MAX_PIECE_LENGTH), math.ceil(math.abs(p.sweep) / (math.pi / 2)))
		local phi = p.sweep / n
		local sgn = phi >= 0 and 1 or -1
		-- Hermite tangent length that best approximates a circular arc of angle phi
		local m = 4 * p.r * math.tan(math.abs(phi) / 4)
		for i = 0, n - 1 do
			local a = p.a0 + phi * i
			local b = a + phi
			out[#out + 1] = {
				x0 = p.cx + p.r * math.cos(a), y0 = p.cy + p.r * math.sin(a),
				tx0 = -math.sin(a) * m * sgn, ty0 = math.cos(a) * m * sgn,
				x1 = p.cx + p.r * math.cos(b), y1 = p.cy + p.r * math.sin(b),
				tx1 = -math.sin(b) * m * sgn, ty1 = math.cos(b) * m * sgn,
				len = total / n,
			}
		end
	end
end

-- A single smooth Hermite curve, subdivided by length.
local function emitHermite(out : {Piece2}, ax : number, ay : number, t0x : number, t0y : number, bx : number, by : number, t1x : number, t1y : number)
	local function pos(t : number) : number, number
		local t2, t3 = t * t, t * t * t
		local h00, h10, h01, h11 = 2 * t3 - 3 * t2 + 1, t3 - 2 * t2 + t, -2 * t3 + 3 * t2, t3 - t2
		return h00 * ax + h10 * t0x + h01 * bx + h11 * t1x, h00 * ay + h10 * t0y + h01 * by + h11 * t1y
	end
	local function deriv(t : number) : number, number
		local t2 = t * t
		local d00, d10, d01, d11 = 6 * t2 - 6 * t, 3 * t2 - 4 * t + 1, -6 * t2 + 6 * t, 3 * t2 - 2 * t
		return d00 * ax + d10 * t0x + d01 * bx + d11 * t1x, d00 * ay + d10 * t0y + d01 * by + d11 * t1y
	end
	local total = 0.0
	local px, py = ax, ay
	for i = 1, 32 do
		local x, y = pos(i / 32)
		total = total + math.sqrt((x - px) ^ 2 + (y - py) ^ 2)
		px, py = x, y
	end
	if total < MIN_PRIM_LENGTH then
		return
	end
	local n = math.max(1, math.ceil(total / MAX_PIECE_LENGTH))
	for i = 0, n - 1 do
		local ta, tb = i / n, (i + 1) / n
		local xa, ya = pos(ta)
		local xb, yb = pos(tb)
		local dxa, dya = deriv(ta)
		local dxb, dyb = deriv(tb)
		out[#out + 1] = {
			x0 = xa, y0 = ya, tx0 = dxa / n, ty0 = dya / n,
			x1 = xb, y1 = yb, tx1 = dxb / n, ty1 = dyb / n,
			len = total / n,
		}
	end
end

local function terrainHeight(x : number, y : number) : number
	local ok, h = pcall(function() : number
		return api.engine.terrain.getHeightAt(api.type.Vec2f.new(x, y))
	end)
	return ok and h or nil
end

-- Heights ------------------------------------------------------------------------------------------
-- Heights along the path: a linear slope from A to B (CS1 SetSlope) or, with followTerrain, the
-- terrain height at every intermediate node (CS1 SetTerrain). With bridges enabled, places where
-- the new path crosses itself are separated: the crossing further from the path ends is raised by
-- CROSS_CLEARANCE on smooth ramps, so that part becomes a bridge over the other.

local CROSS_CLEARANCE = 8      -- metres the upper road is raised at a self-crossing
local MAX_RAMP_GRADE = 0.06    -- steepest ramp used to reach that height
local RAMP_PIECE_LENGTH = 25   -- pieces inside a ramp are split to at most this length

local function hermite2(part : Piece2, t : number) : number, number
	local t2, t3 = t * t, t * t * t
	local h00, h10, h01, h11 = 2 * t3 - 3 * t2 + 1, t3 - 2 * t2 + t, -2 * t3 + 3 * t2, t3 - t2
	return h00 * part.x0 + h10 * part.tx0 + h01 * part.x1 + h11 * part.tx1,
		h00 * part.y0 + h10 * part.ty0 + h01 * part.y1 + h11 * part.ty1
end

local function hermiteDeriv2(part : Piece2, t : number) : number, number
	local t2 = t * t
	local d00, d10, d01, d11 = 6 * t2 - 6 * t, 3 * t2 - 4 * t + 1, -6 * t2 + 6 * t, 3 * t2 - 2 * t
	return d00 * part.x0 + d10 * part.tx0 + d01 * part.x1 + d11 * part.tx1,
		d00 * part.y0 + d10 * part.ty0 + d01 * part.y1 + d11 * part.ty1
end

-- Split one piece into k pieces of equal parameter range.
local function splitPart(part : Piece2, k : integer) : {Piece2}
	local out : {Piece2} = {}
	for i = 0, k - 1 do
		local ta, tb = i / k, (i + 1) / k
		local xa, ya = hermite2(part, ta)
		local xb, yb = hermite2(part, tb)
		local dxa, dya = hermiteDeriv2(part, ta)
		local dxb, dyb = hermiteDeriv2(part, tb)
		out[#out + 1] = {
			x0 = xa, y0 = ya, tx0 = dxa / k, ty0 = dya / k,
			x1 = xb, y1 = yb, tx1 = dxb / k, ty1 = dyb / k,
			len = part.len / k,
		}
	end
	return out
end

local record Sample
	x : number
	y : number
	s : number
end

local function samplePath(parts : {Piece2}) : {Sample}
	local out : {Sample} = { { x = parts[1].x0, y = parts[1].y0, s = 0 } }
	local s = 0.0
	for _, part in ipairs(parts) do
		local px, py = out[#out].x, out[#out].y
		for k = 1, 8 do
			local x, y = hermite2(part, k / 8)
			s = s + math.sqrt((x - px) ^ 2 + (y - py) ^ 2)
			out[#out + 1] = { x = x, y = y, s = s }
			px, py = x, y
		end
	end
	return out
end

-- Intersection parameters (u on segment ab, v on segment cd), or nil.
local function segIntersect(ax : number, ay : number, bx : number, by : number, cx : number, cy : number, dx : number, dy : number) : number, number
	local rx, ry = bx - ax, by - ay
	local qx, qy = dx - cx, dy - cy
	local den = cross2(rx, ry, qx, qy)
	if math.abs(den) < 1e-9 then
		return nil
	end
	local u = cross2(cx - ax, cy - ay, qx, qy) / den
	local v = cross2(cx - ax, cy - ay, rx, ry) / den
	if u >= 0 and u <= 1 and v >= 0 and v <= 1 then
		return u, v
	end
	return nil
end

local record Bump
	center : number
	height : number
	half : number
end

-- Find where the path crosses itself and plan a ramp up over each crossing.
local function selfCrossingBumps(parts : {Piece2}, total : number) : {Bump}
	local samples = samplePath(parts)
	local bumps : {Bump} = {}
	local n = #samples
	for i = 1, n - 1 do
		local a, b = samples[i], samples[i + 1]
		for j = i + 2, n - 1 do
			local c, d = samples[j], samples[j + 1]
			local u, v = segIntersect(a.x, a.y, b.x, b.y, c.x, c.y, d.x, d.y)
			if u then
				local s1 = lerp(a.s, b.s, u)
				local s2 = lerp(c.s, d.s, v)
				if s2 - s1 > 20 then
					-- raise the crossing point that has more room to the path ends
					local centre = math.min(s2, total - s2) >= math.min(s1, total - s1) and s2 or s1
					local half = math.min(math.max(CROSS_CLEARANCE / MAX_RAMP_GRADE, 60), centre, total - centre)
					if half > 10 then
						bumps[#bumps + 1] = { center = centre, height = CROSS_CLEARANCE, half = half }
					end
				end
			end
		end
	end
	return bumps
end

local function bumpAt(bumps : {Bump}, s : number) : number
	local h = 0.0
	for _, b in ipairs(bumps) do
		local d = math.abs(s - b.center)
		if d < b.half then
			h = math.max(h, b.height * 0.5 * (1 + math.cos(math.pi * d / b.half)))
		end
	end
	return h
end

-- Water and valleys: the height profile and bridge rules are shared by all tools
-- (shared/ntools_terrain: water surface + clearance over water, valleys spanned at the maximum
-- grade with follow terrain, bridges starting before the waterline)
local record Terrain
	heights : function(parts : {Piece2}, zA : number, zB : number, follow : boolean, maxGrade : number, lift? : number) : {Piece2}, {number}
	classify : function(pc : Piece) : string
	nodeZ : function(x : number, y : number) : number
	forceStructure : function(seg : Proposal.SegmentAndEntity, isTrack : boolean, bridgeId? : integer, tunnelId? : integer) : string
	lastDiag : string     -- (our own field) last collision diagnostics logged
	lastTwinLog : string  -- (our own field) last twin preview state logged
end
local terrain = require "network_tools_1::/gui/construction/tools/shared/ntools_terrain.script.tl" as Terrain
nodeHeight = function(x : number, y : number) : number return terrain.nodeZ(x, y) end

-- steepest grade for follow terrain: the built road / track type's player limit (set each render)
local g_maxGrade = MAX_RAMP_GRADE
-- height offset: with follow terrain the road runs this far above / below the ground (set each render)
local g_lift = 0.0

-- the colliding entities last diagnosed (the diagnostics run only when they change)
local g_lastCollisionIds = ""

-- Replace: the last path search (key: the two picks)
local record PlanCache
	key : string
	plan : ReplacePlan
end
local g_planCache : PlanCache = { key = "" }

-- how many self-crossings the last toPieces call raised (shown in the tooltip)
local g_lastCrossings = 0

-- Per-point heights: each circle / waypoint with a height offset is an anchor; the road reaches
-- that offset where it passes closest to the anchor (on a circle: its arc) and eases back to the
-- neighbouring anchors (and to 0 at the ends). Set by the recipe before generating.
local record Anchor
	x : number
	y : number
	lift : number
	-- a circle's anchor: its radius; with liftEnd the arc runs from `lift` where the road joins it to
	-- `liftEnd` where it leaves; structure forces the arc's pieces (2 ground, 3 bridge, 4 tunnel)
	r : number
	liftEnd : number
	structure : integer
end
local g_anchors : {Anchor} = {}
-- the steepest grade the last profile's offsets needed (warned about in the tooltip)
local g_liftGrade = 0.0

local function toPieces(parts : {Piece2}, A : P3, B : P3, followTerrain? : boolean) : {Piece}
-- (the per-point height helpers live in here: the main body is at Lua's 200-local limit)
local LIFT_PIECE_LENGTH = 40   -- with anchors, pieces are split to at most this length

-- Stations along the path: { distance, offset }, from 0 at the start to 0 at the end.
local function liftStations(total : number) : {{number}}
	local any = false
	for _, an in ipairs(g_anchors) do
		if (an.lift or 0) ~= 0 or (an.liftEnd ~= nil and an.liftEnd ~= 0) then any = true end
	end
	if not any then return nil end
	local samples = samplePath(parts)
	local scale = total / math.max(samples[#samples].s, 1e-6)
	local st : {{number}} = {}
	for _, an in ipairs(g_anchors) do
		local bs, bd = 0.0, math.huge
		for _, smp in ipairs(samples) do
			local d = (smp.x - an.x) ^ 2 + (smp.y - an.y) ^ 2
			if d < bd then bs, bd = smp.s, d end
		end
		-- a circle with an end height: the stretch round its arc (the samples on the circle, in one
		-- run through the closest one) climbs from its start height to its end height
		local s0, s1 : number, number = nil, nil
		if an.liftEnd ~= nil and an.r then
			local tol = math.max(1.0, an.r * 0.02)
			local function onArc(smp : {string : number}) : boolean
				return math.abs(math.sqrt((smp.x - an.x) ^ 2 + (smp.y - an.y) ^ 2) - an.r) < tol
			end
			for k, smp in ipairs(samples) do
				if smp.s == bs then
					local i0, i1 = k, k
					while i0 > 1 and onArc(samples[i0 - 1] as {string : number}) do i0 = i0 - 1 end
					while i1 < #samples and onArc(samples[i1 + 1] as {string : number}) do i1 = i1 + 1 end
					if i1 > i0 then s0, s1 = samples[i0].s, samples[i1].s end
					break
				end
			end
		end
		if s0 then
			st[#st + 1] = { s0 * scale, an.lift or 0 }
			st[#st + 1] = { s1 * scale, an.liftEnd }
		else
			st[#st + 1] = { bs * scale, an.lift or 0 }
		end
	end
	table.sort(st, function(p : {number}, q : {number}) : boolean return p[1] < q[1] end)
	table.insert(st, 1, { 0, 0 })
	st[#st + 1] = { total, 0 }
	g_liftGrade = 0
	for i = 1, #st - 1 do
		local ds = st[i + 1][1] - st[i][1]
		if ds > 1e-3 then
			-- the cosine ease is pi/2 times steeper in its middle than a straight ramp
			g_liftGrade = math.max(g_liftGrade, math.abs(st[i + 1][2] - st[i][2]) / ds * math.pi / 2)
		end
	end
	return st
end

local function liftAt(st : {{number}}, s : number) : number
	for i = 1, #st - 1 do
		local s0, s1 = st[i][1], st[i + 1][1]
		if s <= s1 then
			if s1 - s0 < 1e-3 then return st[i + 1][2] end
			local u = clamp((s - s0) / (s1 - s0), 0, 1)
			return lerp(st[i][2], st[i + 1][2], 0.5 - 0.5 * math.cos(math.pi * u))
		end
	end
	return 0
end

	if #parts == 0 then
		return nil
	end
	local total = 0.0
	for _, part in ipairs(parts) do
		total = total + part.len
	end
	if total < MIN_PRIM_LENGTH then
		return nil
	end

	-- per-point heights: split finely enough to follow them
	g_liftGrade = 0
	local stations = liftStations(total)
	if stations then
		local fine : {Piece2} = {}
		for _, part in ipairs(parts) do
			if part.len > LIFT_PIECE_LENGTH then
				for _, p in ipairs(splitPart(part, math.ceil(part.len / LIFT_PIECE_LENGTH))) do fine[#fine + 1] = p end
			else
				fine[#fine + 1] = part
			end
		end
		parts = fine
	end

	-- grade separation for self-crossings (only when bridges are allowed)
	local bumps : {Bump} = {}
	if g_bridges then
		bumps = selfCrossingBumps(parts, total)
	end
	g_lastCrossings = #bumps

	-- split pieces inside ramps finely enough to follow them
	if #bumps > 0 then
		local fine : {Piece2} = {}
		local s = 0.0
		for _, part in ipairs(parts) do
			local s0, s1 = s, s + part.len
			s = s1
			local inRamp = false
			for _, b in ipairs(bumps) do
				if s1 > b.center - b.half and s0 < b.center + b.half then
					inRamp = true
				end
			end
			if inRamp and part.len > RAMP_PIECE_LENGTH then
				for _, p in ipairs(splitPart(part, math.ceil(part.len / RAMP_PIECE_LENGTH))) do
					fine[#fine + 1] = p
				end
			else
				fine[#fine + 1] = part
			end
		end
		parts = fine
	end

	-- the shared profile (water with bridges allowed; the ground with follow terrain), with extra
	-- nodes where it bends
	local profile : {number} = nil
	if g_bridges or followTerrain then
		local ok, refined, zs = pcall(terrain.heights, parts, A.z, B.z, followTerrain == true, followTerrain and g_maxGrade or MAX_RAMP_GRADE, g_lift)
		if ok and refined and zs then
			parts, profile = refined, zs
		elseif not ok then
			shared.debug("[network_tools] Connect: terrain profile failed: " .. tostring(refined))
		end
	end

	-- vertex positions, distances and heights
	local n = #parts
	local vs : {number} = { 0 }
	local vx : {number} = { A.x }
	local vy : {number} = { A.y }
	for i, part in ipairs(parts) do
		vs[i + 1] = vs[i] + part.len
		vx[i + 1], vy[i + 1] = part.x1, part.y1
	end
	vx[n + 1], vy[n + 1] = B.x, B.y
	-- the base profile (even slope, the shared terrain / water profile, or the ground), rounded where
	-- its grade changes - vertical curves (connect/extra smoothProfile) - then the self-crossing
	-- ramps and per-point heights on top (not rounded away)
	local vz : {number} = {}
	for k = 1, n + 1 do
		if k == 1 then
			vz[k] = A.z
		elseif k == n + 1 then
			vz[k] = B.z
		else
			local base = lerp(A.z, B.z, vs[k] / total)
			if profile then
				base = profile[k]
			elseif followTerrain then
				base = terrainHeight(vx[k], vy[k]) or base
			end
			vz[k] = base
		end
	end
	vz = ((require "network_tools_1::/gui/construction/tools/connect/extra/ntools_connect_extra.script.tl" as {string : any}).smoothProfile
		as function({number}, {number}, number) : {number})(vs, vz, 60)   -- (60 m: no new local - this file is at Lua's limit)
	-- Follow terrain: no step steeper than the type allows, from either end. The ends keep their
	-- heights (an end along a road: that road's), the vertices between take the ground's - and the
	-- first one after a short piece took it at once: a road on an embankment dropped a metre over a
	-- 3.5 m arc, "Too Much Incline", and the game refused the build outright (2026-10-25). Now it
	-- eases down over the length the grade needs. (Before the self-crossing ramps, which are their own)
	if followTerrain and n >= 2 then
		local G = (g_maxGrade or MAX_RAMP_GRADE) * 0.95
		for k = 2, n do
			local d = (vs[k] - vs[k - 1]) * G
			vz[k] = math.max(vz[k - 1] - d, math.min(vz[k - 1] + d, vz[k]))
		end
		for k = n, 2, -1 do
			local d = (vs[k + 1] - vs[k]) * G
			vz[k] = math.max(vz[k + 1] - d, math.min(vz[k + 1] + d, vz[k]))
		end
	end
	for k = 2, n do
		vz[k] = vz[k] + bumpAt(bumps, vs[k]) + (stations and liftAt(stations, vs[k]) or 0)
	end

	-- slope at each vertex (central difference) so heights change smoothly across nodes
	local slope : {number} = {}
	for k = 1, n + 1 do
		local lo, hi = math.max(1, k - 1), math.min(n + 1, k + 1)
		local ds = vs[hi] - vs[lo]
		slope[k] = ds > 1e-6 and (vz[hi] - vz[lo]) / ds or 0
	end

	local pieces : {Piece} = {}
	for i, part in ipairs(parts) do
		local L = part.len
		pieces[#pieces + 1] = {
			p0 = p3(vx[i], vy[i], vz[i]), t0 = p3(part.tx0, part.ty0, slope[i] * L),
			p1 = p3(vx[i + 1], vy[i + 1], vz[i + 1]), t1 = p3(part.tx1, part.ty1, slope[i + 1] * L),
		}
	end
	pieces[1].p0 = A
	pieces[#pieces].p1 = B
	return pieces
end

local function buildFromPrims(prims : {Prim}, A : P3, B : P3, followTerrain : boolean) : {Piece}
	local parts : {Piece2} = {}
	for _, p in ipairs(prims) do
		emitPrim(parts, p)
	end
	return toPieces(parts, A, B, followTerrain)
end

local function fmtLen(m : number) : string
	return tostring(math.floor(m + 0.5)) .. " m"
end

local function fmtDeg(rad : number) : string
	return tostring(math.floor(math.abs(rad) * 180 / math.pi + 0.5)) .. "°"
end

-- Rotate a unit direction by `deg` degrees (counter-clockwise positive).
local function rotateDir(x : number, y : number, deg : number) : number, number
	if not deg or deg == 0 then
		return x, y
	end
	local a = deg * math.pi / 180
	local c, s = math.cos(a), math.sin(a)
	return x * c - y * s, x * s + y * c
end

----------------------------------------------------------------------------------------------------
-- Generators

local SNAP_RADIUS_STEP = 5      -- radii snap to multiples of this (CS1 RoundToNearest(step))

-- Waypoints: extra points on bare ground the route passes through (clicked after both ends are
-- set). Straight and Curve run through them; Connection turns each into a middle circle.

-- A, the waypoints, B as one list
local function routePoints(A : P3, B : P3, wps : {P3}) : {P3}
	local pts : {P3} = { A }
	for _, w in ipairs(wps or {}) do pts[#pts + 1] = w end
	pts[#pts + 1] = B
	return pts
end

-- Where a new waypoint at (x, y) goes in the list: into the leg it lengthens the route least.
local function waypointSlot(A : P3, B : P3, wps : {P3}, x : number, y : number) : integer
	local pts = routePoints(A, B, wps)
	local best, bestCost = 1, math.huge
	for i = 1, #pts - 1 do
		local p, q = pts[i], pts[i + 1]
		local cost = math.sqrt((x - p.x) ^ 2 + (y - p.y) ^ 2) + math.sqrt((q.x - x) ^ 2 + (q.y - y) ^ 2)
			- math.sqrt((q.x - p.x) ^ 2 + (q.y - p.y) ^ 2)
		if cost < bestCost then best, bestCost = i, cost end
	end
	return best
end

-- One module per mode, in connect/<mode>/ (Min. radius: connect/min_radius/ntools_dubins). Each is
-- set up with the helpers here: the height profile (toPieces) depends on this tool's live settings.
local record ConnectModes
	record Straight
		genStraight : function(A : P3, B : P3, followTerrain : boolean, wps? : {P3}) : GenResult
	end
	record Curve
		CURVE_K_MIN : number
		CURVE_K_MAX : number
		CURVE_K_SNAP : number
		curveEndLengths : function(A : P3, B : P3, wps : {P3}) : number, number
		genCurve : function(A : P3, B : P3, ax : number, ay : number, bx : number, by : number, followTerrain : boolean, k0? : number, k1? : number, wps? : {P3}) : GenResult
	end
	record Loop
		genLoop : function(A : P3, B : P3, ax : number, ay : number, bx : number, by : number, st : LoopState, followTerrain : boolean) : GenResult
		dragLoop : function(A : P3, B : P3, ax : number, ay : number, bx : number, by : number, mx : number, my : number, snap : boolean) : LoopState
	end
	record Connection
		defaultConnState : function(A : P3, B : P3, ax : number, ay : number, bx : number, by : number, wps? : {P3}) : ConnState
		connCircles : function(A : P3, B : P3, ax : number, ay : number, bx : number, by : number, st : ConnState) : {Circ}, number, number, number, number
		genConnection : function(A : P3, B : P3, ax : number, ay : number, bx : number, by : number, st : ConnState, followTerrain : boolean) : GenResult
		connCount : function(st : ConnState) : integer
		copyConn : function(st : ConnState) : ConnState
		radiusOf : function(st : ConnState, idx : integer) : number
		withRadius : function(st : ConnState, idx : integer, r : number) : ConnState
		flipCircle : function(st : ConnState, idx : integer) : ConnState
		insertCircle : function(st : ConnState, k : integer, straight : Line2, x : number, y : number) : ConnState
		insertCircleThrough : function(st : ConnState, k : integer, straight : Line2, x : number, y : number) : ConnState
		removeCircle : function(st : ConnState, idx : integer) : ConnState
		moveMiddle : function(st : ConnState, idx : integer, x : number, y : number) : ConnState
		snapRadius : function(A : P3, B : P3, ax : number, ay : number, bx : number, by : number, st : ConnState, idx : integer, roundStep : number) : ConnState
		dragConnCircle : function(P : P3, gx : number, gy : number, c : ConnCircle, mx : number, my : number) : ConnCircle
		withCircle : function(st : ConnState, idx : integer, set : function(c : ConnCircle, m : MidCircle)) : ConnState
	end
end
local modeCtx : {string : any} = {
	MIN_PRIM_LENGTH = MIN_PRIM_LENGTH, MIN_RADIUS = MIN_RADIUS, MAX_RADIUS = MAX_RADIUS,
	DEFAULT_RADIUS = DEFAULT_RADIUS, MAX_GUIDE_T = MAX_GUIDE_T, SNAP_RADIUS_STEP = SNAP_RADIUS_STEP,
	p3 = p3, clamp = clamp, cross2 = cross2, dot2 = dot2, norm2 = norm2,
	routePoints = routePoints, linePrim = linePrim, arcPrim = arcPrim, primLength = primLength,
	emitHermite = emitHermite, toPieces = toPieces, buildFromPrims = buildFromPrims,
	fmtLen = fmtLen, fmtDeg = fmtDeg,
}
local straightMode = (require "network_tools_1::/gui/construction/tools/connect/straight/ntools_connect_straight.script.tl" as function({string : any}) : ConnectModes.Straight)(modeCtx)
local curveMode = (require "network_tools_1::/gui/construction/tools/connect/curve/ntools_connect_curve.script.tl" as function({string : any}) : ConnectModes.Curve)(modeCtx)
local loopMode = (require "network_tools_1::/gui/construction/tools/connect/loop/ntools_connect_loop.script.tl" as function({string : any}) : ConnectModes.Loop)(modeCtx)
local connMode = (require "network_tools_1::/gui/construction/tools/connect/connection/ntools_connect_connection.script.tl" as function({string : any}) : ConnectModes.Connection)(modeCtx)

----------------------------------------------------------------------------------------------------
-- Proposal

local MIN_PIECE_LENGTH = 1.0
local MIN_TANGENT_LENGTH = 0.5

local function len3(v : P3) : number
	return math.sqrt(v.x * v.x + v.y * v.y + v.z * v.z)
end

-- The engine hard-crashes (assertion 'len > 0' in transport::VisitEdge) on zero-length
-- edges or tangents. Reject pieces that are too short and replace degenerate tangents.
local function sanitizePieces(pieces : {Piece}) : {Piece}
	if not pieces or #pieces == 0 then
		return nil
	end
	for _, piece in ipairs(pieces) do
		local chord = p3(piece.p1.x - piece.p0.x, piece.p1.y - piece.p0.y, piece.p1.z - piece.p0.z)
		if len3(chord) < MIN_PIECE_LENGTH then
			return nil
		end
		if len3(piece.t0) < MIN_TANGENT_LENGTH then
			piece.t0 = chord
		end
		if len3(piece.t1) < MIN_TANGENT_LENGTH then
			piece.t1 = chord
		end
	end
	return pieces
end

local function vec3(p : P3) : Vec3f
	return api.type.Vec3f.new(p.x, p.y, p.z)
end

-- Network picker ------------------------------------------------------------------------------------
-- The panel's "Network" dropdown: nil = use the network of the selected road / track, otherwise the
-- id of a street template (road or track type) in api.res.streetTemplateRep.

local g_networkId : integer = nil

local record NetworkOption
	id : integer
	name : string
	isTrack : boolean
	icon : string      -- the build menu's icon (small one if there is one)
	-- for the panel's filters / labels
	country : boolean  -- a country road (not a town street)
	oneWay : boolean   -- all vehicle lanes run the same way
	electric : boolean -- track with catenary (it has a plain twin to remove it to)
	lanes : integer    -- vehicle lanes / tracks
	speed : number     -- top lane speed, km/h
	filters : {string} -- the build menu's filter categories (lvl_1, tree, tram, bus, barrier...)
	categories : {string} -- the build menu's categories (roads_small / _medium / _large / _country / _highway, tracks...)
end

local function laneWidth(laneConfigs : {LaneConfig}) : number
	local w = 0.0
	for _, lc in ipairs(laneConfigs or {}) do
		w = w + (lc.width or 0)
	end
	return w
end

local function templateById(id : integer) : StreetTemplate
	if not id then return nil end
	local ok, t = pcall(function() : StreetTemplate return api.res.streetTemplateRep.get(id) end)
	return ok and t or nil
end

local function templateByName(name : string) : StreetTemplate
	if not name then return nil end
	local ok, t = pcall(function() : StreetTemplate
		local id = api.res.streetTemplateRep.find(name)
		if id == nil or id < 0 then return nil end
		return api.res.streetTemplateRep.get(id)
	end)
	return ok and t or nil
end

-- Road and track types available this year, roads first, each group sorted by name
-- (like the build menu, which lists street templates from the same repository).
local function listNetworks() : {NetworkOption}
	local out : {NetworkOption} = {}
	pcall(function()
		local year = api.engine.util.getYear()
		for id, resName in pairs(api.res.streetTemplateRep.getAll()) do
			local t = api.res.streetTemplateRep.get(id)
			local av = t.availability
			local available = av == nil or ((av.yearFrom == 0 or av.yearFrom <= year) and (av.yearTo == 0 or year < av.yearTo))
			-- not the entrance roads stations / depots / industries build for themselves
			-- (street/constructions/entrance_*, ind_entrance_*)
			if tostring(resName):lower():find("entrance", 1, true) then available = false end
			local label = t.description and t.description.name or nil
			if available and label and label ~= "" then
				local d = t.description
				local icon = (d.iconSmall and d.iconSmall ~= "") and d.iconSmall or d.icon
				-- vehicle lanes: not sidewalks (people / nothing allowed)
				local lanes, fwd, bwd, speed = 0, 0, 0, 0.0
				local hasTram = false
				for _, lc in ipairs(t.laneConfigs or {}) do
					local modes = lc.transportModes or {}
					local TRAM = api.type["enum"].TransportMode.TRAM
					if TRAM ~= nil and modes[TRAM] then hasTram = true end
					local any = false
					for _, on in pairs(modes) do if on then any = true end end
					if any and not modes[api.type["enum"].TransportMode.PERSON] then
						lanes = lanes + 1
						if lc.forward then fwd = fwd + 1 else bwd = bwd + 1 end
						speed = math.max(speed, lc.speed or 0)
					end
				end
				local filters, categories : {string}, {string} = {}, {}
				pcall(function()
					for _, c in ipairs(t.menuCategory and t.menuCategory.categories or {}) do
						if c.category and c.category ~= "" then categories[#categories + 1] = c.category end
						for _, fc in ipairs(c.filterCategories or {}) do filters[#filters + 1] = fc end
					end
				end)
				-- the street templates carry no filter categories (all empty, seen 2026-10-09): the
				-- build menu's filter icons are worked out from the type instead
				if #filters == 0 then
					local rn = tostring(resName):lower()
					if hasTram then filters[#filters + 1] = "tram" end
					if t.catenaryRemove ~= nil and t.catenaryRemove ~= "" then filters[#filters + 1] = "catenary" end
					if rn:find("tree", 1, true) then filters[#filters + 1] = "tree" end
					if rn:find("barrier", 1, true) then filters[#filters + 1] = "barrier" end
				end
				out[#out + 1] = { id = id as integer, name = label, isTrack = t.roadType == api.type["enum"].RoadType.TRACK,
					filters = filters, categories = categories,
					icon = (icon and icon ~= "") and icon or nil,
					country = t.country == true,
					oneWay = lanes > 0 and (fwd == 0 or bwd == 0),
					electric = t.catenaryRemove ~= nil and t.catenaryRemove ~= "",
					lanes = lanes,
					speed = speed * 3.6 }
			end
		end
	end)
	table.sort(out, function(a : NetworkOption, b : NetworkOption) : boolean
		if a.isTrack ~= b.isTrack then return not a.isTrack end
		return a.name < b.name
	end)
	return out
end

-- Use the picked network for a new segment. `requireTrack` (true / false) limits it to rail / road,
-- nil allows either. Returns whether the applied network is a track, or nil if nothing was applied.
local function applyNetwork(seg : Proposal.SegmentAndEntity, requireTrack : boolean) : boolean
	local t = templateById(g_networkId)
	if not t then return nil end
	local isTrack = t.roadType == api.type["enum"].RoadType.TRACK
	if requireTrack ~= nil and isTrack ~= requireTrack then
		return nil
	end
	local names = api.res.streetTemplateRep.getAll()
	seg.comp.laneConfigs = t.laneConfigs
	seg.comp.roadTemplate = names[g_networkId]
	seg.comp.roadStyle = t.streetStyle
	seg.comp.roadType = t.roadType
	return isTrack
end

-- Bridges & tunnels ----------------------------------------------------------------------------------

local BRIDGE_CLEARANCE = 4.5   -- average height above ground that makes a piece a bridge
local TUNNEL_DEPTH = 8         -- average depth below ground that makes a piece a tunnel

-- Default bridge and tunnel type for this carrier in the current year, chosen like the game's own
-- bridge/tunnel picker (menu_category_util.getAvailableObjectsSorted), preferring auto-selectable types.
local function pickBridgeTunnel(isTrack : boolean) : integer, integer
	local carrier = isTrack and api.type["enum"].Carrier.RAIL or api.type["enum"].Carrier.ROAD
	local year = api.engine.util.getYear()
	local function pick(rep : ResTypeRep<integer, BridgeType>) : integer
		local ok, objects = pcall(function() : {MenuCategoryUtil.FilterObject}
			return menu_category_util.getAvailableObjectsSorted(rep as ResTypeRep<integer, table>, year)
		end)
		if not ok or not objects then
			return nil
		end
		local fallback : integer = nil
		for _, o in ipairs(objects) do
			local matches = false
			for _, c in ipairs(o.carriers or {}) do
				if c == carrier then matches = true end
			end
			if matches then
				if o.isAutoSelectable ~= false then
					return o.id
				end
				fallback = fallback or o.id
			end
		end
		return fallback
	end
	-- a type picked on the toolbar wins if it suits this carrier; -1 = the player chose none
	local function chosen(rep : ResTypeRep<integer, BridgeType>, id : integer) : integer, boolean
		if id == nil then return nil, false end
		if id < 0 then return nil, true end
		local ok, desc = pcall(function() : BridgeType return rep.get(id) end)
		if ok and desc then
			for _, c in ipairs(desc.carriers or {}) do
				if c == carrier then return id, true end
			end
		end
		return nil, false
	end
	local bridgeId, bridgeSet = chosen(api.res.bridgeTypeRep, g_bridgeType)
	local tunnelId, tunnelSet = chosen(api.res.tunnelTypeRep, g_tunnelType)
	if not bridgeSet then bridgeId = pick(api.res.bridgeTypeRep) end
	if not tunnelSet then tunnelId = pick(api.res.tunnelTypeRep) end
	return bridgeId, tunnelId
end

local function hermite3(piece : Piece, t : number) : number, number, number
	local t2, t3 = t * t, t * t * t
	local h00, h10, h01, h11 = 2 * t3 - 3 * t2 + 1, t3 - 2 * t2 + t, -2 * t3 + 3 * t2, t3 - t2
	return h00 * piece.p0.x + h10 * piece.t0.x + h01 * piece.p1.x + h11 * piece.t1.x,
		h00 * piece.p0.y + h10 * piece.t0.y + h01 * piece.p1.y + h11 * piece.t1.y,
		h00 * piece.p0.z + h10 * piece.t0.z + h01 * piece.p1.z + h11 * piece.t1.z
end

-- "bridge", "tunnel" or "normal" from how far the piece runs above / below the terrain.
local function classifyPiece(piece : Piece) : string
	-- a piece on the arc of a circle whose structure is set (Connect's circle options) is that
	for _, an in ipairs(g_anchors) do
		if an.r and an.structure and an.structure >= 2 then
			local x, y = hermite3(piece, 0.5)
			if math.abs(math.sqrt((x - an.x) ^ 2 + (y - an.y) ^ 2) - an.r) < math.max(1.5, an.r * 0.03) then
				return an.structure == 3 and "bridge" or (an.structure == 4 and "tunnel" or "normal")
			end
		end
	end
	-- the shared rules (incl. bridges starting before the waterline); the local copy below is the
	-- fallback if the module can't be used
	local okT, kind = pcall(terrain.classify, piece)
	if okT and kind then return kind end
	local sumClear, minClear = 0.0, math.huge
	local sumDepth, minDepth = 0.0, math.huge
	local samples = 5
	for i = 1, samples do
		local x, y, z = hermite3(piece, i / (samples + 1))
		local h = terrainHeight(x, y)
		if not h then
			return "normal"
		end
		sumClear, minClear = sumClear + (z - h), math.min(minClear, z - h)
		sumDepth, minDepth = sumDepth + (h - z), math.min(minDepth, h - z)
	end
	if sumClear / samples >= BRIDGE_CLEARANCE and minClear >= 2 then
		return "bridge"
	end
	if sumDepth / samples >= TUNNEL_DEPTH and minDepth >= 4 then
		return "tunnel"
	end
	-- at the shore: a normal road's embankment slopes reach into the water and collide with the
	-- water mesh, so (like the game's street builder) the bridge starts before the waterline: a
	-- piece on, over or within a few metres of water is a bridge (unless it runs below ground)
	if minDepth < 1 then
		local SHORE_MARGIN = 12
		for i = 0, 6 do
			local x, y = hermite3(piece, i / 6)
			for _, o in ipairs({ { 0, 0 }, { SHORE_MARGIN, 0 }, { -SHORE_MARGIN, 0 }, { 0, SHORE_MARGIN }, { 0, -SHORE_MARGIN } }) do
				local ok, w = pcall(function() : boolean return api.engine.terrain.isOnWater(api.type.Vec2f.new(x + o[1], y + o[2])) end)
				if ok and w == true then return "bridge" end
			end
		end
	end
	return "normal"
end

-- Returns the proposal plus how many pieces became bridges and tunnels.
-- Railroad crossing type for a road meeting rail: the toolbar pick, the first available one when
-- automatic, or nil when the player picked none.
local function levelCrossingType() : integer
	if g_rcType == -1 then return nil end
	local rcId = g_rcType
	if rcId == nil then
		local ok, objects = pcall(function() : {MenuCategoryUtil.FilterObject}
			return menu_category_util.getAvailableObjectsSorted(api.res.railroadCrossingTypeRep as ResTypeRep<integer, table>, api.engine.util.getYear())
		end)
		if ok and objects and objects[1] then rcId = objects[1].id end
	end
	return rcId
end

-- the network of a connection: the first picked road's, else the second's (nil for two free points)
local function templateEdgeOf(a : Pick, b : Pick) : Engine.Entity
	if a and a.edge and getEdge(a.edge) then return a.edge end
	if b and b.edge and getEdge(b.edge) then return b.edge end
	return nil
end

-- Returns the proposal, how many pieces became bridges and tunnels, why not (nil proposal), and -
-- when it removes segments - what the live preview shows of it: the new road alone (see
-- verdict.viewOf).
local function makeProposal(a : Pick, b : Pick, rawPieces : {Piece}, plan : ReplacePlan) : SimpleProposal, integer, integer, string, SimpleProposal
	local templateEdge = templateEdgeOf(a, b)
	local template = templateEdge and getEdge(templateEdge)
	local pieces = sanitizePieces(rawPieces)
	if not pieces then
		return nil
	end
	local picked = templateById(g_networkId)
	if not template and not picked then
		return nil, 0, 0, _("Two points on bare ground: pick the road or track type (Road / track type option, or the panel's Network list)")
	end
	local isTrack = (template and template.roadType or picked.roadType) == api.type["enum"].RoadType.TRACK
	local streetEdge : Engine.Component.BaseEdgeStreet = nil
	if not isTrack and template then
		streetEdge = api.engine.getComponent(templateEdge, api.type.ComponentType.BASE_EDGE_STREET) as Engine.Component.BaseEdgeStreet
	end

	-- existing segments the proposal removes: split ones (re-added in parts) and the replaced road
	local removeEdges : {Engine.Entity} = {}
	local removing : {Engine.Entity : boolean} = {}
	local function remove(s : Engine.Entity)
		if not removing[s] then removing[s] = true; removeEdges[#removeEdges + 1] = s end
	end
	for _, p in ipairs({ a, b }) do
		if p.kind == "split" then remove(p.edge) end
	end
	for _, s in ipairs(plan and plan.edges or {}) do remove(s) end

	-- Crossings: where the new road crosses an existing road of the same kind at ground level, both
	-- are split there and share a junction node (the game's road tool does the same). Not across
	-- bridges / tunnels, rail with road, or right at the two ends (those are the joins themselves).
	local record Crossing
		edge : Engine.Entity
		t : number         -- on the existing segment
		pos : P3           -- the junction (on the existing road)
		node : Engine.Entity -- an existing node the junction joins (near one of the segment's ends):
		                   -- the segment then isn't split, the new road runs through that node
	end
	local crossAt : {integer : Crossing} = {}   -- piece index -> the junction at its end (p1)
	do
		local CROSS_DZ = 2.5        -- metres: closer than this in height is "at ground level"
		local END_CLEAR = 15        -- metres: no junction this close to the two ends
		local SAMPLES = 8
		local endNodes : {Engine.Entity : boolean} = {}
		if a.kind == "node" then endNodes[a.node] = true end
		if b.kind == "node" then endNodes[b.node] = true end
		local wantType = isTrack and api.type["enum"].RoadType.TRACK or nil
		local P0, PN = pieces[1].p0, pieces[#pieces].p1
		local function nearEnd(x : number, y : number) : boolean
			return (x - P0.x) ^ 2 + (y - P0.y) ^ 2 < END_CLEAR ^ 2 or (x - PN.x) ^ 2 + (y - PN.y) ^ 2 < END_CLEAR ^ 2
		end
		local out : {Piece} = {}
		local seenEdge : {Engine.Entity : boolean} = {}
		local seenNode : {Engine.Entity : boolean} = {}   -- existing nodes joined (once each)
		for _, pc in ipairs(pieces) do
			local cuts : {{number}} = {}          -- { u on this piece, edge, t on the edge }
			local cutEdge : {Engine.Entity} = {}
			local cutNode : {integer : Engine.Entity} = {}   -- a cut joining an existing node (see below)
			-- passing over / under an existing road or track (further apart in height than a junction):
			-- { u on this piece, "bridge" / "tunnel" }. The game's builder makes that part a bridge /
			-- tunnel; built plain, a road raised a few metres to cross another collided with it
			-- (mod.io report 2026-10-13: "connection errors when using overpasses")
			local overs : {{any}} = {}
			local plain = not g_bridges or classifyPiece(pc) == "normal"
			if plain then
				local mx, my = (pc.p0.x + pc.p1.x) / 2, (pc.p0.y + pc.p1.y) / 2
				local r = math.sqrt((pc.p1.x - pc.p0.x) ^ 2 + (pc.p1.y - pc.p0.y) ^ 2) / 2 + 40
				local okF, found = pcall(function() : {Engine.Entity}
					return api.engine.util.octree.findEntitiesInCircle(api.type.Vec2f.new(mx, my), r, api.type.ComponentType.BASE_EDGE)
				end)
				for _, s in ipairs(okF and found or {}) do
					local e = getEdge(s)
					local sameKind = e and ((wantType ~= nil) == (e.roadType == api.type["enum"].RoadType.TRACK))
					if e and not removing[s] and not endNodes[e.node0] and not endNodes[e.node1] then
						local epc = geom.edgePiece(e)
						local L = geom.length(epc)
						-- both as polylines: the first crossing of the two
						local px, py, pz = hermite3(pc, 0)
						for k = 1, SAMPLES do
							local qx, qy, qz = hermite3(pc, k / SAMPLES)
							local e0 = geom.point(epc, 0)
							for j = 1, SAMPLES do
								local e1 = geom.point(epc, j / SAMPLES)
								local su, sv = segIntersect(px, py, qx, qy, e0.x, e0.y, e1.x, e1.y)
								if su then
									local u = (k - 1 + su) / SAMPLES
									local t = (j - 1 + sv) / SAMPLES
									local X = geom.point(epc, t)
									local z = lerp(pz, qz, su)
									if nearEnd(X.x, X.y) then
										-- (the joins themselves)
									elseif math.abs(z - X.z) < CROSS_DZ then
										-- same level: a junction (same kind, plain road only - rail meets road
										-- at the game's own level crossing)
										-- Near one of the segment's ends (as a click picks a node -
										-- pickOnEdge): the junction is that node, the segment isn't
										-- split - no stub piece, and the game's preview shows it as it
										-- is (a split shows red over the old road). Further in: split
										if sameKind and e.type == api.type["enum"].BaseEdgeType.NORMAL then
											local snap = math.min(NODE_SNAP_M, L / 3)
											if t * L <= snap or (1 - t) * L <= snap then
												cuts[#cuts + 1] = { u, t }
												cutEdge[#cuts] = s
												cutNode[#cuts] = (t * L <= snap) and e.node0 or e.node1
											elseif t * L > MIN_SPLIT_PART and (1 - t) * L > MIN_SPLIT_PART then
												cuts[#cuts + 1] = { u, t }
												cutEdge[#cuts] = s
											end
										end
									elseif z > X.z and e.type ~= api.type["enum"].BaseEdgeType.TUNNEL then
										overs[#overs + 1] = { u, "bridge" }
									elseif z < X.z and e.type ~= api.type["enum"].BaseEdgeType.BRIDGE then
										overs[#overs + 1] = { u, "tunnel" }
									end
								end
								e0 = e1
							end
							px, py, pz = qx, qy, qz
						end
					end
				end
			end
			if #cuts == 0 then
				-- (a copy when marked: the pieces may be the preview's cached ones)
				out[#out + 1] = overs[1] and { p0 = pc.p0, t0 = pc.t0, p1 = pc.p1, t1 = pc.t1, over = overs[1][2] as string } or pc
			else
				-- split this piece at its crossings (in order along it), one junction each
				local order : {integer} = {}
				for i = 1, #cuts do order[i] = i end
				table.sort(order, function(i : integer, j : integer) : boolean return cuts[i][1] < cuts[j][1] end)
				local us : {number} = {}
				local keep : {integer} = {}
				for _, i in ipairs(order) do
					local u = cuts[i][1]
					-- (one junction per spot: two segments meeting at a node both report the crossing)
					if (#us == 0 or u - us[#us] > 0.02) and not seenEdge[cutEdge[i]]
							and not (cutNode[i] and seenNode[cutNode[i]]) then
						us[#us + 1] = u
						keep[#keep + 1] = i
						if cutNode[i] then seenNode[cutNode[i]] = true end
					end
				end
				local parts = geom.split({ p0 = pc.p0, t0 = pc.t0, p1 = pc.p1, t1 = pc.t1 }, us)
				for pi, part in ipairs(parts) do
					local piece : Piece = { p0 = part.p0, t0 = part.t0, p1 = part.p1, t1 = part.t1 }
					-- passes over / under something between this part's two junctions
					for __, o in ipairs(overs) do
						local u = o[1] as number
						if u >= (us[pi - 1] or 0) and u <= (us[pi] or 1) then piece.over = o[2] as string; break end
					end
					out[#out + 1] = piece
					local ci = keep[pi]
					if ci then
						local s = cutEdge[ci]
						-- (joining an existing node: the junction is where that node is)
						local nd = cutNode[ci]
						local X = (nd and getNodePos(nd)) or geom.point(geom.edgePiece(getEdge(s)), cuts[ci][2])
						crossAt[#out] = { edge = s, t = cuts[ci][2], pos = X, node = nd }
						seenEdge[s] = true
						-- the junction sits on the existing road: meet it exactly there
						piece.p1 = X
						if parts[pi + 1] then parts[pi + 1].p0 = X end
					end
				end
			end
		end
		pieces = out
		-- (a junction at an existing node leaves its segment as it is)
		for _, c in pairs(crossAt) do
			if not c.node then remove(c.edge) end
		end
	end
	for _, s in ipairs(removeEdges) do
		local why = net_util.whyNotReplaceable(s, shared.opts.overrideLanes)
		if why then return nil, 0, 0, why end
	end
	-- Replace through a level crossing would leave it with only the road (a crossing is
	-- re-created only where the track goes on): a crossing inside the replaced stretch is refused,
	-- one at its ends is fine
	if plan and plan.edges then
		local seenAt : {Engine.Entity : integer} = {}
		for _, s in ipairs(plan.edges) do
			local e = getEdge(s)
			for _, nd in ipairs(e and { e.node0, e.node1 } or {}) do seenAt[nd] = (seenAt[nd] or 0) + 1 end
		end
		for nd, k in pairs(seenAt) do
			if k >= 2 and net_util.isCrossingNode(nd) then
				return nil, 0, 0, _("Replace: the stretch runs through a level crossing - pick points on either side of it")
			end
		end
	end

	local bridgeId, tunnelId : integer, integer = nil, nil
	-- a circle set to bridge / tunnel gets one even with automatic bridges off
	local forcedStructure = false
	for _, an in ipairs(g_anchors) do
		if an.structure and an.structure >= 2 then forcedStructure = true end
	end
	-- (the panel's Structure, not Automatic: every piece forced - the picked types too)
	local globalForce = ((shared.opts as {string : any}).structure as integer or 1) > 1
	if g_bridges or forcedStructure or globalForce then
		bridgeId, tunnelId = pickBridgeTunnel(isTrack)
	end
	local nBridges, nTunnels = 0, 0

	local n = #pieces
	local nodes : {Proposal.NodeAndEntity} = {}
	local edges : {Proposal.SegmentAndEntity} = {}
	local nextId = 0
	local function newId() : Engine.Entity
		nextId = nextId - 1
		return nextId
	end
	local function addNode(pos : P3) : Engine.Entity
		local node = api.type.NodeAndEntity.new()
		node.entity = newId()
		node.comp.position = vec3(pos)
		nodes[#nodes + 1] = node
		return node.entity
	end

	-- the two ends: the existing node, or a new one at the split / free point
	local endA = a.kind == "node" and a.node or addNode(pieces[1].p0)
	local endB = b.kind == "node" and b.node or addNode(pieces[n].p1)

	-- split segments: re-added in parts through the new end node(s), the replaced part left out
	local splits : {Engine.Entity : {{number, Engine.Entity}}} = {}
	if a.kind == "split" then splits[a.edge] = { { a.t, endA } } end
	if b.kind == "split" then
		splits[b.edge] = splits[b.edge] or {}
		table.insert(splits[b.edge], { b.t, endB })
	end
	-- crossings: one junction node each, shared by the new road and the crossed segment
	-- per existing end node of a split segment: old segment -> the new part there (false: none, the
	-- part is left out), for the node's lane connections (net_util.carryConfigs)
	local cfgRemap : {Engine.Entity : {Engine.Entity : Engine.Entity | boolean}} = {}
	local crossNode : {integer : Engine.Entity} = {}
	-- (existing nodes joined: their lane connections are dropped below, as at a picked node)
	local joinedNodes : {Engine.Entity} = {}
	for i, c in pairs(crossAt) do
		if c.node then
			crossNode[i] = c.node
			joinedNodes[#joinedNodes + 1] = c.node
		else
			crossNode[i] = addNode(c.pos)
			splits[c.edge] = splits[c.edge] or {}
			table.insert(splits[c.edge], { c.t, crossNode[i] })
		end
	end
	for s, cuts in pairs(splits) do
		table.sort(cuts, function(x : {number, Engine.Entity}, y : {number, Engine.Entity}) : boolean return x[1] < y[1] end)
		local e = getEdge(s)
		local ts : {number} = {}
		local chain : {Engine.Entity} = { e.node0 }
		for _, c in ipairs(cuts) do
			ts[#ts + 1] = c[1]
			chain[#chain + 1] = c[2]
		end
		chain[#chain + 1] = e.node1
		local parts = geom.split(geom.edgePiece(e), ts)
		local side = plan and plan.used and plan.used[s]
		local drop = (side == "lo" and 1) or (side == "hi" and #parts) or (side == "mid" and 2) or 0
		local street : Engine.Component.BaseEdgeStreet = nil
		if e.roadType ~= api.type["enum"].RoadType.TRACK then
			street = api.engine.getComponent(s, api.type.ComponentType.BASE_EDGE_STREET) as Engine.Component.BaseEdgeStreet
		end
		cfgRemap[e.node0] = cfgRemap[e.node0] or {}
		cfgRemap[e.node1] = cfgRemap[e.node1] or {}
		cfgRemap[e.node0][s] = false
		cfgRemap[e.node1][s] = false
		for i, part in ipairs(parts) do
			if i ~= drop then
				local seg = api.type.SegmentAndEntity.new()
				seg.entity = newId()
				if i == 1 then cfgRemap[e.node0][s] = seg.entity end
				if i == #parts then cfgRemap[e.node1][s] = seg.entity end
				seg.comp.node0, seg.comp.node1 = chain[i], chain[i + 1]
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
					pcall(function() seg.comp.distance = e.distance end)
				else
					seg.type = 0
					if street then seg.streetEdge = street end
				end
				edges[#edges + 1] = seg
			end
		end
	end
	-- (the split segments' re-added parts are edges[1 .. nRebuilt]; the new road's follow)
	local nRebuilt = #edges

	-- the new connection's own nodes
	local mids : {Engine.Entity} = {}
	for i = 1, n - 1 do mids[i] = crossNode[i] or addNode(pieces[i].p1) end
	local function nodeId(i : integer) : Engine.Entity
		if i == 0 then return endA end
		if i == n then return endB end
		return mids[i]
	end

	for i, piece in ipairs(pieces) do
		local seg = api.type.SegmentAndEntity.new()
		seg.entity = newId()
		seg.comp.node0 = nodeId(i - 1)
		seg.comp.node1 = nodeId(i)
		seg.comp.position0 = vec3(piece.p0)
		seg.comp.position1 = vec3(piece.p1)
		seg.comp.tangent0 = vec3(piece.t0)
		seg.comp.tangent1 = vec3(piece.t1)
		seg.comp.type = api.type["enum"].BaseEdgeType.NORMAL
		seg.comp.typeIndex = -1
		if g_bridges or forcedStructure then
			-- (automatic bridges off: only the circles' forced structures, the rest stays on the ground)
			local kind = classifyPiece(piece)
			-- over / under an existing road or track (see Crossings): a bridge / tunnel there, as the
			-- game's builder makes it, however low it runs above the ground
			if kind == "normal" and piece.over then kind = piece.over end
			if not g_bridges then
				local onForced = false
				for _, an in ipairs(g_anchors) do
					if an.r and an.structure and an.structure >= 2 then
						local x, y = hermite3(piece, 0.5)
						if math.abs(math.sqrt((x - an.x) ^ 2 + (y - an.y) ^ 2) - an.r) < math.max(1.5, an.r * 0.03) then onForced = true end
					end
				end
				if not onForced then kind = "normal" end
			end
			if kind == "bridge" and bridgeId then
				seg.comp.type = api.type["enum"].BaseEdgeType.BRIDGE
				seg.comp.typeIndex = bridgeId
				nBridges = nBridges + 1
			elseif kind == "tunnel" and tunnelId then
				seg.comp.type = api.type["enum"].BaseEdgeType.TUNNEL
				seg.comp.typeIndex = tunnelId
				nTunnels = nTunnels + 1
			end
		end
		if globalForce then
			local was = seg.comp.type
			local forced = terrain.forceStructure(seg, isTrack, bridgeId, tunnelId)
			if forced and was ~= seg.comp.type then
				if forced == "bridge" then nBridges = nBridges + 1 elseif forced == "tunnel" then nTunnels = nTunnels + 1 end
			end
		end
		-- copy the network type from the first picked edge
		if template then
			seg.comp.laneConfigs = template.laneConfigs
			seg.comp.roadTemplate = template.roadTemplate
			seg.comp.roadStyle = template.roadStyle
			seg.comp.roadType = template.roadType
		end
		-- network picked in the panel (road / rail must match the nodes being joined; any kind
		-- between two free points)
		applyNetwork(seg, template and isTrack or nil)
		if isTrack then
			seg.type = 1
			-- the template's track spacing: neighbouring tracks then share ballast and catenary
			pcall(function()
				local tpl = api.res.streetTemplateRep.get(api.res.streetTemplateRep.find(seg.comp.roadTemplate))
				local d = (tpl and tpl.trackDistance and tpl.trackDistance > 0) and tpl.trackDistance or (template and template.distance or 0)
				if d and d > 0 then seg.comp.distance = d end
			end)
		else
			seg.type = 0
			if streetEdge then
				seg.streetEdge = streetEdge
			end
		end
		-- the panel's new-road properties (catenary, bus lane, tram, lock, owner, decorations)
		shared.applyRoad(seg)
		edges[#edges + 1] = seg
	end

	-- every segment must carry lanes: a segment without any is an engine assertion (a hard crash) on
	-- Build. Refill an empty list from its road type; refuse rather than crash if that fails.
	for __, seg in ipairs(edges) do
		local n = 0
		pcall(function() n = #(seg.comp.laneConfigs or {}) end)
		if n == 0 then
			local tpl = templateByName(seg.comp.roadTemplate)
			if tpl and #(tpl.laneConfigs or {}) > 0 then
				seg.comp.laneConfigs = tpl.laneConfigs
				n = #tpl.laneConfigs
			end
			shared.debug(string.format("[network_tools] Connect: segment %d had no lanes (template %s, refilled %d)",
				seg.entity, tostring(seg.comp.roadTemplate), n))
			if n == 0 then
				return nil, 0, 0, _("A segment has no lanes (network unknown) - pick the road or track type in the Network list")
			end
		end
	end

	local proposal = api.type.SimpleProposal.new()
	if #nodes > 0 then
		proposal.streetProposal.nodesToAdd = nodes
	end
	proposal.streetProposal.edgesToAdd = edges
	if #removeEdges > 0 then
		proposal.streetProposal.edgesToRemove = removeEdges
	end
	local orphans = plan and plan.nodes or {}
	if #orphans > 0 then
		proposal.streetProposal.nodesToRemove = orphans
	end
	-- connecting road into a rail node (or rail into a road node) makes a level crossing there
	local other = b.kind == "node" and getEdge(b.edge) or nil
	if other and template and other.roadType ~= template.roadType then
		local rcId = levelCrossingType()
		if rcId then
			pcall(function() proposal.streetProposal.node2rcType = { [b.node] = rcId } end)
		end
	end
	-- a removed / split segment at a level crossing: the engine re-creates the crossing
	net_util.rebuildCrossings(proposal, removeEdges, orphans)
	-- The existing nodes the new road (or the removal) touches keep lane connections that don't
	-- include it: traffic can't turn onto it and the game marks the node "no entry", and a removed
	-- segment named there crashes the engine. Drop those configs so the engine builds fresh,
	-- automatic ones (ntools_net_util.configNodesFor); at an untouched pick node, lanes / light
	-- phases the player edited by hand are kept.
	local cfgNodes = net_util.configNodesFor(removeEdges, nil, orphans)
	local seen : {Engine.Entity : boolean} = {}
	for _, c in ipairs(cfgNodes) do seen[c] = true end
	-- (the picked end nodes, and existing nodes a crossing joins - both gain the new road)
	local touched : {Engine.Entity} = {}
	for _, p in ipairs({ a, b }) do
		if p.kind == "node" and p.node then touched[#touched + 1] = p.node end
	end
	for _, nd in ipairs(joinedNodes) do touched[#touched + 1] = nd end
	for _, nd in ipairs(touched) do
		pcall(function()
			-- (not a station's / depot's node: its lanes are the construction's, and dropping them
			-- crashed the engine - "startNode == segment.node0 || ..." in CreateConnectionCtx)
			local sc = api.engine.system.streetConnectorSystem
			local owned = nd and nd >= 0 and (sc.getConstructionEntityForNode(nd) or -1) >= 0
			for _, s in ipairs(nd and nd >= 0 and api.engine.system.streetSystem.getNodeSegments(nd) or {}) do
				if (sc.getConstructionEntityForEdge(s) or -1) >= 0 then owned = true end
			end
			if nd and nd >= 0 and not seen[nd] and not owned then
				local cfg = api.engine.getComponent(nd, api.type.ComponentType.BASE_NODE_CONFIG) as Engine.Component.BaseNodeConfig
				if cfg and (shared.opts.overrideLanes or (cfg.userModifiedLaneConnections ~= true and cfg.userModifiedTrafficLightStates ~= true)) then
					seen[nd] = true
					cfgNodes[#cfgNodes + 1] = nd
				end
			end
		end)
	end
	if #cfgNodes > 0 then
		pcall(function() proposal.streetProposal.nodeConfigsToRemove = cfgNodes end)
		-- a split segment's end nodes get their lanes back, renamed onto the new parts (left bare,
		-- the node had no config for a while and the game crashed later - mod.io report 2026-10-19)
		net_util.carryConfigs(proposal, cfgNodes, cfgRemap)
	end
	-- What the live preview shows when this removes segments: the new road alone, whole - no
	-- removals, no re-added parts, no node configs - as the Overpass Builder previews (its old road
	-- stays drawn until Build; where the new road meets it the game's preview may show red, the full
	-- build is fine). The proposal's own segments, read only: nothing here changes them
	local view : SimpleProposal = nil
	if #removeEdges > 0 or #orphans > 0 then
		view = api.type.SimpleProposal.new()
		if #nodes > 0 then view.streetProposal.nodesToAdd = nodes end
		local own : {Proposal.SegmentAndEntity} = {}
		for i = nRebuilt + 1, #edges do own[#own + 1] = edges[i] end
		view.streetProposal.edgesToAdd = own
		pcall(function() view.streetProposal.node2rcType = proposal.streetProposal.node2rcType end)
	end
	return proposal, nBridges, nTunnels, nil, view
end

----------------------------------------------------------------------------------------------------
-- Overlay drawing
-- Geometry setup follows the MoveIt mod: sub-geometry objects are created and assigned whole,
-- colors take three entries, and only ONE builtin.EdgeRenderable may be mounted per recipe
-- (the engine asserts otherwise), so everything goes into a single edge list.

-- Everything is drawn ON the terrain: lines and circles are split into short straight pieces, each at
-- the ground height under it (the MoveIt approach). Clicks are hit-tested against the terrain position
-- under the cursor, so what you see is exactly where you have to click.
-- (The drawing helpers sit in a do-block, only makeOverlay leaves it: the main body is at Lua's
-- 200-local limit.)

local makeOverlay : function(gen : GenResult, z : number, draggingIndex : integer, hasError : boolean, selectedIndex : integer) : TreeNodeId
do
local OVERLAY_LINE_STEP = 10     -- metres per piece for lines
local OVERLAY_CIRCLE_STEP = 6    -- metres per piece around circles

local function groundZ(x : number, y : number, fallback : number) : number
	return terrainHeight(x, y) or fallback
end

local function segmentEdge(x0 : number, y0 : number, z0 : number, x1 : number, y1 : number, z1 : number, color : Vec4f, width : number) : Builtin.Type.EdgeRenderable.Edge
	local len = math.sqrt((x1 - x0) ^ 2 + (y1 - y0) ^ 2)
	if len < 0.05 then
		return nil
	end
	local straight = api.type.EdgeGeometry.Straight.new()
	straight.pos = { api.type.Vec2f.new(x0, y0), api.type.Vec2f.new(x1, y1) }
	local geom = api.type.EdgeGeometry.new()
	geom.straight = straight
	geom.height = api.type.Vec2f.new(z0, z1)
	geom.width = 1.0
	geom.length = len
	local edge = builtin.type.EdgeRenderable.Edge.new(geom)
	edge.colors = { color, color, color }
	edge.stepSize = 1
	edge.width = width
	edge.offsetZ = 1.0
	return edge
end

local function groundLine(add : function(Builtin.Type.EdgeRenderable.Edge), x0 : number, y0 : number, x1 : number, y1 : number, zFallback : number, color : Vec4f, width : number)
	local len = math.sqrt((x1 - x0) ^ 2 + (y1 - y0) ^ 2)
	if len < 0.5 then
		return
	end
	local n = math.max(1, math.ceil(len / OVERLAY_LINE_STEP))
	local px, py = x0, y0
	local pz = groundZ(px, py, zFallback)
	for i = 1, n do
		local x, y = lerp(x0, x1, i / n), lerp(y0, y1, i / n)
		local z = groundZ(x, y, zFallback)
		add(segmentEdge(px, py, pz, x, y, z, color, width))
		px, py, pz = x, y, z
	end
end

-- One true arc piece (EdgeGeometry ARC) from angle a0 sweeping da radians, at heights z0 -> z1.
-- nil if the engine rejects arc geometry (the caller then falls back to straight pieces).
local function arcEdge(cx : number, cy : number, r : number, a0 : number, da : number, z0 : number, z1 : number, color : Vec4f, width : number) : Builtin.Type.EdgeRenderable.Edge
	local ok, edge = pcall(function() : Builtin.Type.EdgeRenderable.Edge
		local arc = api.type.EdgeGeometry.Arc.new()
		arc.center = api.type.Vec2f.new(cx, cy)
		arc.radius = r
		arc.startAngle = a0
		arc.angle = da
		local geom = api.type.EdgeGeometry.new()
		geom.type = api.type.EdgeGeometry.Type.ARC
		geom.arc = arc
		geom.height = api.type.Vec2f.new(z0, z1)
		geom.width = 1.0
		geom.length = math.abs(da) * r
		local e = builtin.type.EdgeRenderable.Edge.new(geom)
		e.colors = { color, color, color }
		e.stepSize = 1
		e.width = width
		e.offsetZ = 1.0
		return e
	end)
	return ok and edge or nil
end
local g_arcsOk = true

local function groundCircle(add : function(Builtin.Type.EdgeRenderable.Edge), cx : number, cy : number, r : number, zFallback : number, color : Vec4f, width : number)
	if r < 0.5 then
		return
	end
	-- real arcs (smooth at any size); big circles in a few arcs so each follows the ground
	if g_arcsOk then
		local n = math.floor(clamp(math.ceil(2 * math.pi * r / 25), 4, 24))
		local pieces : {Builtin.Type.EdgeRenderable.Edge} = {}
		for i = 0, n - 1 do
			local a0, a1 = 2 * math.pi * i / n, 2 * math.pi * (i + 1) / n
			local z0 = groundZ(cx + r * math.cos(a0), cy + r * math.sin(a0), zFallback)
			local z1 = groundZ(cx + r * math.cos(a1), cy + r * math.sin(a1), zFallback)
			local e = arcEdge(cx, cy, r, a0, a1 - a0, z0, z1, color, width)
			if not e then
				g_arcsOk = false
				break
			end
			pieces[#pieces + 1] = e
		end
		if g_arcsOk then
			for _, e in ipairs(pieces) do add(e) end
			return
		end
		shared.debug("[network_tools] overlay: arc geometry not accepted, drawing circles from straight pieces")
	end
	local n = math.floor(clamp(math.ceil(2 * math.pi * r / OVERLAY_CIRCLE_STEP), 12, 120))
	local px, py = cx + r, cy
	local pz = groundZ(px, py, zFallback)
	for i = 1, n do
		local a = 2 * math.pi * i / n
		local x, y = cx + r * math.cos(a), cy + r * math.sin(a)
		local z = groundZ(x, y, zFallback)
		add(segmentEdge(px, py, pz, x, y, z, color, width))
		px, py, pz = x, y, z
	end
end

makeOverlay = function(gen : GenResult, z : number, draggingIndex : integer, hasError : boolean, selectedIndex : integer) : TreeNodeId
	local ok, result = pcall(function() : TreeNodeId
		local circleColor = hasError and api.type.Vec4f.new(1.0, 0.3, 0.3, 0.6) or api.type.Vec4f.new(0.3, 1.0, 0.5, 0.45)
		local guideColor = api.type.Vec4f.new(1.0, 1.0, 1.0, 0.35)
		local handleColor = api.type.Vec4f.new(1.0, 0.8, 0.25, 0.95)
		local dragColor = api.type.Vec4f.new(1.0, 0.5, 0.0, 1.0)
		local edges : {Builtin.Type.EdgeRenderable.Edge} = {}
		local function add(e : Builtin.Type.EdgeRenderable.Edge)
			if e then edges[#edges + 1] = e end
		end
		local endColor = api.type.Vec4f.new(0.3, 0.7, 1.0, 0.9)
		for _, l in ipairs(gen.endLines or {}) do
			-- (the solid arrows white, as the game's; their head's slices are too short for groundLine,
			-- which skips pieces under 0.5 m: one strip each, on the ground at both ends)
			-- (opaque: where the side strips overlap the fill, a see-through white showed brighter)
			local c = l.w and api.type.Vec4f.new(0.95, 0.96, 0.94, 1.0) or endColor
			if l.w and (l.x1 - l.x0) ^ 2 + (l.y1 - l.y0) ^ 2 < 1 then
				add(segmentEdge(l.x0, l.y0, groundZ(l.x0, l.y0, z), l.x1, l.y1, groundZ(l.x1, l.y1, z), c, l.w))
			else
				groundLine(add, l.x0, l.y0, l.x1, l.y1, z, c, l.w or 1.2)
			end
		end
		for _, c in ipairs(not gen.hideEnds and gen.endRings or {}) do
			groundCircle(add, c.x, c.y, c.r, z, endColor, 1.2)
		end
		for _, l in ipairs(gen.guides or {}) do
			groundLine(add, l.x0, l.y0, l.x1, l.y1, z, guideColor, 0.5)
		end
		-- the chain's other sections: their loose ends (the reach an end snaps from, and a dot), and
		-- the one a dragged end is snapped onto now, bright
		for _, c in ipairs(gen.snapRings or {}) do
			groundCircle(add, c.x, c.y, c.r, z, guideColor, 0.6)
			groundCircle(add, c.x, c.y, 2.5, z, guideColor, 1.2)
		end
		for _, c in ipairs(gen.snapHot or {}) do
			local hotColor = api.type.Vec4f.new(0.3, 1.0, 0.5, 0.95)
			groundCircle(add, c.x, c.y, c.r, z, hotColor, 1.4)
			groundCircle(add, c.x, c.y, 2.5, z, hotColor, 1.6)
		end
		-- the twin's outline (it is built after the connection, so it can't be in the proposal)
		local twinColor = api.type.Vec4f.new(0.55, 0.8, 1.0, 0.8)
		for _, l in ipairs(gen.twinLines or {}) do
			groundLine(add, l.x0, l.y0, l.x1, l.y1, z, twinColor, 1.0)
		end
		local selectedColor = hasError and api.type.Vec4f.new(1.0, 0.3, 0.3, 0.9) or api.type.Vec4f.new(0.3, 1.0, 0.5, 0.9)
		-- (move ends mode: the circles are hidden, only the ends can be grabbed)
		for i, c in ipairs(not gen.hideCircles and gen.circles or {}) do
			-- the circle the keyboard controls act on is drawn brighter and thicker
			if i == selectedIndex then
				groundCircle(add, c.x, c.y, c.r, z, selectedColor, 1.4)
			else
				groundCircle(add, c.x, c.y, c.r, z, circleColor, 0.8)
			end
		end
		for i, h in ipairs(not gen.hideCircles and gen.handles or {}) do
			local color = i == draggingIndex and dragColor or handleColor
			groundCircle(add, h.x, h.y, HANDLE_RADIUS_M, z, color, 1.5)
			groundCircle(add, h.x, h.y, HANDLE_RADIUS_M * 0.4, z, color, 1.5)
		end
		-- live preview off: the planned road as lines (Overpass Builder's schematic), lifted a little
		-- above the ground so it stays visible
		local schematicColors : {string : Vec4f} = {
			normal = api.type.Vec4f.new(0.3, 1.0, 0.3, 0.9),
			bridge = api.type.Vec4f.new(1.0, 0.75, 0.2, 0.95),
			tunnel = api.type.Vec4f.new(0.35, 0.6, 1.0, 0.95),
			bad = api.type.Vec4f.new(1.0, 0.25, 0.25, 0.95),
		}
		for _, s in ipairs(gen.schematic or {}) do
			local color = hasError and schematicColors.bad or (schematicColors[s.kind] or schematicColors.normal)
			-- one curved strip along the piece's own curve (the game's renderer draws Hermite curves);
			-- a straight strip if it refuses the geometry
			local curved : Builtin.Type.EdgeRenderable.Edge = nil
			if s.pc then
				local okS, e = pcall(function() : Builtin.Type.EdgeRenderable.Edge
					local pc = s.pc
					local sp = api.type.EdgeGeometry.CubicSpline.new()
					sp.pos = { api.type.Vec2f.new(pc.p0.x, pc.p0.y), api.type.Vec2f.new(pc.p1.x, pc.p1.y) }
					sp.tangent = { api.type.Vec2f.new(pc.t0.x, pc.t0.y), api.type.Vec2f.new(pc.t1.x, pc.t1.y) }
					local geom = api.type.EdgeGeometry.new()
					geom.type = api.type.EdgeGeometry.Type.CUBIC_SPLINE
					geom.cubicSpline = sp
					geom.height = api.type.Vec2f.new(s.z0, s.z1)
					geom.tangent = api.type.Vec2f.new(pc.t0.z, pc.t1.z)
					geom.width = 1.0
					geom.length = math.sqrt((pc.p1.x - pc.p0.x) ^ 2 + (pc.p1.y - pc.p0.y) ^ 2)
					local edge = builtin.type.EdgeRenderable.Edge.new(geom)
					edge.colors = { color, color, color }
					edge.stepSize = 1
					edge.width = 2.5
					edge.offsetZ = 1.0
					return edge
				end)
				if okS then curved = e end
			end
			add(curved or segmentEdge(s.x0, s.y0, s.z0, s.x1, s.y1, s.z1, color, 2.5))
		end
		-- ground points: the same handle in the end colour (drag target DRAG_POINT + 1 / + 2, waypoint
		-- i DRAG_POINT + 2 + i); pairs: an end on a road leaves a gap
		for i, h in pairs(gen.pointHandles or {}) do
			-- (the two ends hidden with the circles shown: move ends mode is off)
			if not (gen.hideEnds and i <= 2) then
				local color = (DRAG_POINT + i) == draggingIndex and dragColor or endColor
				groundCircle(add, h.x, h.y, HANDLE_RADIUS_M * 1.5, z, color, 1.5)
				groundCircle(add, h.x, h.y, HANDLE_RADIUS_M * 0.5, z, color, 1.5)
			end
		end
		-- the Anarchy preview's green strips go in this one EdgeRenderable too (under the handles)
		local strips = preview.takeEdges()
		if #strips > 0 then
			for _, e in ipairs(edges) do strips[#strips + 1] = e end
			edges = strips
		end
		if #edges == 0 then
			return nil
		end
		return builtin.EdgeRenderable{ edges = edges, ignoreDepth = true }
	end)
	if not ok then
		shared.debug("[network_tools] overlay failed: " .. tostring(result))
		return nil
	end
	return result
end
end   -- do (drawing helpers)

----------------------------------------------------------------------------------------------------
-- UI

-- The tools' cursor tooltip. The game's SimpleTooltipRecipe draws the whole message as one
-- coloured block; ours makes the first line a coloured headline (green ok / red problem /
-- neutral), the remaining lines (numbers, key hints) smaller neutral text, and the cost a row of
-- its own (red when it can't be afforded).
local record TooltipParams
	message : string
	good : boolean
	bad : boolean
	cost : integer
	keys : string             -- mouse / key controls, in a box of their own below the rest
end

-- the headline's padding on its coloured tape, inline: it was a stylesheet rule (!ntools-tip-head), and
-- the game limits the total number of stylesheet rules across all mods. Made once, shared.
-- (one file-level local: this file is near Lua's limit of 200)
local tipHeadSheet : function() : StyleSheet
do
	local cached : StyleSheet = nil
	tipHeadSheet = function() : StyleSheet
		if cached == nil then
			local ok, st = pcall(function() : StyleSheet
				local s = api.gui.StyleSheet.new()
				s.padding = api.type.Vec4f.new(4, 10, 4, 10)
				return s
			end)
			cached = ok and st or nil
		end
		return cached
	end
end

local NtoolsTooltipRecipe = react.RegisterRecipe("NtoolsTooltip", function(params : TooltipParams) : TreeNodeId
	local poor = engine_react_util.useStepState(function() : boolean
		if not params.cost then return false end
		local money = api.engine.util.finance.getPlayersBalance(api.engine.util.getPlayer())
		return money ~= nil and params.cost > money
	end):old() == true

	local lines : {string} = {}
	for line in ((params.message or "") .. "\n"):gmatch("([^\n]*)\n") do
		if line ~= "" then lines[#lines + 1] = line end
	end
	-- one dark panel (ntools_connect_tool.css.lua): the headline on the game's coloured tape,
	-- the details in one compact block of light text below it
	local tone = params.good and "success-tape" or (params.bad and "error-tape" or "info-tape")
	local children : {TreeNodeId} = {}
	if lines[1] then
		children[#children + 1] = builtin.TextView{ meta = { class = tone .. ", font-scale-body", styleSheet = tipHeadSheet() }, text = lines[1] }
	end
	-- items run together with three spaces ("Length: 120 m   Signals: 4") get a separator, and a
	-- line longer than TIP_WRAP characters breaks between items (the panel's width can't be capped)
	local TIP_WRAP = 64
	local details : {string} = {}
	for i = 2, #lines do
		local cur = ""
		for item in (lines[i] .. "   "):gmatch("(.-)%s%s%s+") do
			if item:match("%S") then
				if cur ~= "" and #cur + 5 + #item > TIP_WRAP then
					details[#details + 1] = cur
					cur = item
				else
					cur = cur == "" and item or (cur .. "  ·  " .. item)
				end
			end
		end
		if cur ~= "" then details[#details + 1] = cur end
	end
	if #details > 0 then
		children[#children + 1] = builtin.TextView{ meta = { class = "font-scale-annotation, ntools-tip-body" }, text = table.concat(details, "\n") }
	end
	if params.cost and params.cost ~= 0 then
		children[#children + 1] = builtin.TextView{
			meta = { class = (poor and "error-tape" or "ntools-tip-cost") .. ", font-scale-body", styleSheet = poor and tipHeadSheet() or nil },
			text = _("Cost") .. ": " .. api.util.formatMoney(params.cost),
		}
	end
	if params.keys and params.keys ~= "" then
		children[#children + 1] = builtin.TextView{ meta = { class = "font-scale-annotation, ntools-tip-body, ntools-tip-keys" }, text = params.keys }
	end
	return builtin.BoxLayout{
		meta = { class = "ntools-tip" },
		orientation = builtin.type.Orientation.Vertical,
		children = children,
	}
end)

local function tooltip(message : string, good : boolean, bad : boolean, cost? : integer, keys? : string) : TreeNodeId
	-- the game's own tooltip if ours can't be built (so a tool never loses its tooltip)
	local ok, node = pcall(function() : TreeNodeId
		return builtin.ActionTooltip({
			recipe = NtoolsTooltipRecipe,
			param = { message = message, good = good, bad = bad, cost = cost, keys = keys } as TooltipParams,
		} as Builtin.ActionTooltipParam<any>)
	end)
	if ok and node then return node end
	local param : ConstructionReactUtil.SimpleTooltipRecipeParams = {
		message = { message = message, good = good, bad = bad },
		cost = cost,
	}
	return builtin.ActionTooltip({
		recipe = construction_react_util.SimpleTooltipRecipe,
		param = param,
	} as Builtin.ActionTooltipParam<any>)
end

local function paramInt(values : {string : number}, key : string, default : integer) : integer
	local v = values[key]
	return v and math.floor(v) or default
end

local function round(v : number) : string
	return tostring(math.floor(v * 10 + 0.5))
end

-- UG react.lua maps boolean false to Inactive, which still generates prompts; return
-- Disabled so unavailable shortcuts disappear (pattern from the MoveIt mod).
local function shortcutHandler(handler : function(), enabled : function() : (boolean), prompt? : string, repeatPresses? : boolean) : React.IaHandler
	return react.iaHandler(handler, function() : Gui.InputAction.InputActionState
		return enabled() and api.gui.inputAction.InputActionState.Enabled
			or api.gui.inputAction.InputActionState.Disabled
	end, prompt, repeatPresses)
end

-- An unknown input action name makes useInputAction throw (and kills the construction menu),
-- so bind through pcall (pattern from the MoveIt mod).
local function safeUseInputAction(name : string, handler : React.IaHandler) : boolean
	local ok = pcall(function() react.useInputAction(name, handler) end)
	return ok
end

local function precise() : boolean
	local ok, active = pcall(function() : boolean
		return api.gui.inputAction.modifierOnlyActionIsActive("IA_PRECISION_MODE")
	end)
	return ok and active
end

local RADIUS_STEP, RADIUS_STEP_FINE = 5, 1
local ANGLE_STEP, ANGLE_STEP_FINE = 2, 0.5   -- degrees (CS1 TurnAngle = 2 degrees)
local MAX_END_ANGLE = 60

----------------------------------------------------------------------------------------------------
-- Tags of this tool's own (the preview's segments are tagged by shared/ntools_preview): at each end
-- that joins the network, the angle between the new road and the nearest road there (amber when it
-- merges shallower than SHALLOW_MERGE); at each circle's centre, its radius.

local SHALLOW_MERGE = 20   -- degrees

-- unit direction in plan, or nil
local function unit2(x : number, y : number) : number, number
	local l = math.sqrt(x * x + y * y)
	if l < 1e-6 then return nil end
	return x / l, y / l
end

-- the ways existing roads leave the picked point (plan unit vectors)
local function waysAt(p : Pick) : {{number}}
	local ways : {{number}} = {}
	pcall(function()
		if p.kind == "node" then
			for __, sg in ipairs(api.engine.system.streetSystem.getNodeSegments(p.node)) do
				local e = getEdge(sg)
				if e then
					local x, y : number, number
					if e.node0 == p.node then x, y = unit2(e.tangent0.x, e.tangent0.y)
					else x, y = unit2(-e.tangent1.x, -e.tangent1.y) end
					if x then ways[#ways + 1] = { x, y } end
				end
			end
		elseif p.kind == "split" then
			-- along the split segment at t, both ways
			local e = getEdge(p.edge)
			if e then
				local t = p.t or 0.5
				local a1, b1, c1, d1 = 6 * t * t - 6 * t, 3 * t * t - 4 * t + 1, -6 * t * t + 6 * t, 3 * t * t - 2 * t
				local x, y = unit2(a1 * e.position0.x + b1 * e.tangent0.x + c1 * e.position1.x + d1 * e.tangent1.x,
					a1 * e.position0.y + b1 * e.tangent0.y + c1 * e.position1.y + d1 * e.tangent1.y)
				if x then
					ways[#ways + 1] = { x, y }
					ways[#ways + 1] = { -x, -y }
				end
			end
		end
	end)
	return ways
end

local function connectTags(a : Pick, b : Pick, gen : GenResult) : {LabelPoint}
	local out : {LabelPoint} = {}
	if not gen or not gen.pieces or #gen.pieces == 0 then return out end
	local first, last = gen.pieces[1], gen.pieces[#gen.pieces]
	-- the way the new road leaves each end
	local ends : {{any}} = {
		{ a, first.p0, first.t0.x, first.t0.y },
		{ b, last.p1, -last.t1.x, -last.t1.y },
	}
	for __, en in ipairs(ends) do
		local p, P = en[1] as Pick, en[2] as P3
		local nx, ny = unit2(en[3] as number, en[4] as number)
		if p and p.kind ~= "free" and P and nx then
			local best : number = nil
			for __, w in ipairs(waysAt(p)) do
				local d = math.max(-1, math.min(1, nx * w[1] + ny * w[2]))
				local deg = math.deg(math.acos(d))
				if not best or deg < best then best = deg end
			end
			if best then
				out[#out + 1] = {
					x = P.x, y = P.y, z = P.z,
					rows = { { icon = labels.icons.angle, text = string.format("%.0f°", best) } },
					level = best < SHALLOW_MERGE and 1 or 0,
				}
			end
		end
	end
	if not gen.hideCircles then
		for __, c in ipairs(gen.circles or {}) do
			local ok, z = pcall(function() : number return api.engine.terrain.getHeightAt(api.type.Vec2f.new(c.x, c.y)) end)
			out[#out + 1] = {
				x = c.x, y = c.y, z = ok and z or first.p0.z,
				rows = { { icon = labels.icons.radius, text = string.format("R %.0f m", c.r) } },
			}
		end
	end
	return out
end

----------------------------------------------------------------------------------------------------
-- Verdicts and demolitions (after the Overpass Builder mod): the game's verdict on a proposal
-- without the preview, town houses in the way demolished by the same proposal, which errors
-- really block, and the build latch. In shared/ntools_verdict (this main body is at Lua's
-- 200-local limit).
local record Verdict
	record Demolition
		key : string
		houses : {Engine.Entity}
	end
	of : function(sp : SimpleProposal) : ProposalData
	houses : function(pd : ProposalData) : {Engine.Entity}
	demolish : function(sp : SimpleProposal, houses : {Engine.Entity})
	blockReason : function(pd : ProposalData, sp : SimpleProposal) : string
	demolition : Demolition
	BUILD_TIMEOUT_S : number
	buildSince : number
	lastPreviewMsg : string
	chain : {SimpleProposal}   -- chained sections committed so far (see Continue)
	chainSnaps : {{string : any}}   -- their setups (to go back and edit one)
	after : {{string : any}}        -- sections after the current one: { proposal, snap }
	chainMerged : SimpleProposal -- (each render) them + the current section as one proposal
	chainWhy : string
	offCostKey : string
	-- (our own fields) one step back / on through the chain (M / Shift+M), and the section the
	-- panel's Sections table was clicked to (Connect steps there one section per render)
	stepChain : function(backward : boolean)
	chainTarget : integer
	-- (our own fields) what the live preview shows of a proposal that removes segments (an end along a
	-- road splits it, Replace, crossings): only the new road - no removals, the split road's re-added
	-- parts left out (makeProposal). As the Overpass Builder previews: the old road stays drawn until
	-- Build. A preview that removed a segment crashed the game natively once the game's selector met
	-- it ("it != components.end()" on BaseEdge in UI::CSelector, 2026-10-25). Keyed by the full
	-- proposal (weak); chainView: the chain's sections merged that way
	viewOf : {SimpleProposal : SimpleProposal}
	chainView : SimpleProposal
end
local verdict = require "network_tools_1::/gui/construction/tools/shared/ntools_verdict.script.tl" as Verdict
verdict.viewOf = setmetatable({}, { __mode = "k" }) as {SimpleProposal : SimpleProposal}

-- Probe (debug, M in Connect): the game's own street builder runs instead of Connect, and every
-- proposal it makes while you drag is logged - to copy how it joins onto existing roads.
-- (the builder takes a street template name and crashes the game - no Lua error - when it isn't
-- one: the name is checked by probeName before probe mode starts)
local g_probe = { on = false, last = "", name = "" }
local function probeName(networkId : integer) : string
	local ok, name = pcall(function() : string
		if not networkId then return nil end
		local n = api.res.streetTemplateRep.getName(networkId)
		if n and n ~= "" and api.res.streetTemplateRep.find(n) >= 0 then return n end
		return nil
	end)
	return ok and name or nil
end
local function probeAction(_networkId : integer) : TreeNodeId
	local seb = builtin.type.ConstructionAction.StreetEdgeBuilder.new()
	pcall(function()
		seb.resName = g_probe.name as ResName
		seb.curved = true
		seb.enableSnapping = true
		seb.bridgeTypeId, seb.tunnelTypeId, seb.railroadCrossingTypeId = -1, -1, -1
		seb.bridgeHeight, seb.bridgeMinHeight, seb.tunnelHeight, seb.tunnelMinHeight = 6.0, 11.0, 9.0, 15.0
	end)
	local function f(v : any) : string
		local t = v as {string : number}
		return t and string.format("(%.1f,%.1f,%.1f)", t.x or 0, t.y or 0, t.z or 0) or "?"
	end
	return builtin.ActionDescriptor{
		children = {
			builtin.ConstructionAction{
				streetEdgeBuilder = seb,
				getProposalStringsFn = function(proposal : Proposal, _pd : ProposalData) : {string}
					pcall(function()
						local sp = (proposal as {string : any}).streetProposal as {string : any}
						local lines : {string} = {}
						for _, n in ipairs((sp.nodesToAdd or {}) as {{string : any}}) do
							local c = n.comp as {string : any}
							lines[#lines + 1] = string.format("  +node %s at %s", tostring(n.entity), f(c.position))
						end
						for _, s in ipairs((sp.edgesToAdd or {}) as {{string : any}}) do
							local c = s.comp as {string : any}
							lines[#lines + 1] = string.format("  +edge %s n%s-n%s  p0 %s t0 %s  p1 %s t1 %s  type %s",
								tostring(s.entity), tostring(c.node0), tostring(c.node1), f(c.position0), f(c.tangent0),
								f(c.position1), f(c.tangent1), tostring(c.type))
						end
						for _, e in ipairs((sp.edgesToRemove or {}) as {any}) do lines[#lines + 1] = "  -edge " .. tostring(e) end
						for _, e in ipairs((sp.nodesToRemove or {}) as {any}) do lines[#lines + 1] = "  -node " .. tostring(e) end
						for _, e in ipairs((sp.nodeConfigsToRemove or {}) as {any}) do lines[#lines + 1] = "  -nodeConfig " .. tostring(e) end
						local text = table.concat(lines, "\n")
						if text ~= g_probe.last and #lines > 0 then
							g_probe.last = text
							print("[network_tools] PROBE game street proposal:\n" .. text)
						end
					end)
					return {}
				end,
			},
		},
	}
end

local ConnectActionRecipe = react.RegisterRecipe("NtoolsConnectAction", function(params : ConstructionCustomActionParams<any>) : TreeNodeId
	react.onUnmount(function()
		preview.clear()                -- its speed / incline tags leave with the tool
		shared.opts.pointLabel = nil   -- ... and the panel's point height slider
		-- ... and a chain's kept sections (M). They live in the shared verdict module: left there,
		-- the next Connect showed the first kept section's preview again (the inactive render
		-- below that clears them doesn't happen when the tool is closed outright)
		verdict.chain, verdict.chainMerged, verdict.chainWhy = {}, nil, nil
		verdict.chainSnaps, verdict.after = {}, {}
	end)
	local firstState : ReactStateT<Pick> = react.useState(nil)
	local secondState : ReactStateT<Pick> = react.useState(nil)
	local connState : ReactStateT<ConnState> = react.useState(nil)
	local loopState : ReactStateT<LoopState> = react.useState(nil)
	-- Curve mode: tangent length multipliers at end 1 / end 2 (nil = 1, 1)
	local curveState : ReactStateT<{number}> = react.useState(nil)
	-- points on bare ground the route passes through, in travel order (clicked after both ends)
	local waypointsState : ReactStateT<{P3}> = react.useState({})
	-- Straight / Curve: the waypoint the panel's point height slider edits (0 = none)
	local selectedWpState : ReactStateT<integer> = react.useState(0)
	-- move ends mode (toggled with N): a press near the start / end point drags it, over circles too
	-- (named addMode from when N added points)
	local addModeState : ReactStateT<boolean> = react.useState(false)
	-- the point and height last handed to the panel's slider (to tell its edits from ours)
	local pointLabelRef : ReactRefT<string> = react.useRef(nil)
	local pointLiftRef : ReactRefT<number> = react.useRef(0)
	-- this recipe's own node: the world action points back to it (ActionDescriptor.parent), so the
	-- key prompts of R::NtoolsConnectAction show in the Network Tools panel too, not only when the
	-- construction menu holds the recipe (the game's line manager does the same)
	local selfRef = react.useSelfRef() as ReactNodeRef
	-- ... and the prompt list follows keyboard focus: in the panel (whose window doesn't take focus
	-- when it opens) focus this node once when the tool starts
	local focusedRef : ReactRefT<boolean> = react.useRef(false)
	local draggingState : ReactStateT<integer> = react.useState(0)
	local costState : ReactStateT<integer> = react.useState(0)
	local errorState : ReactStateT<string> = react.useState("")
	-- which end the keyboard controls act on (CS1 SelectOffset / SelectCircle)
	local selectedState : ReactStateT<integer> = react.useState(1)
	-- extra turn at each end in degrees (CS1 FirstAngle / SecondAngle)
	local anglesState : ReactStateT<{number}> = react.useState({ 0, 0 })
	local aliveRef : ReactRefT<boolean> = react.useRef(true)
	-- the authoritative drag handle index lives in a ref so mouse callbacks see it immediately;
	-- draggingState only drives the handle colour
	local draggingRef : ReactRefT<integer> = react.useRef(0)
	-- the road under the cursor (-1 = none): a click with nothing under it picks bare ground
	local hoverRef : ReactRefT<Engine.Entity> = react.useRef(-1)

	-- An end along a road gets a real node there first (the Add node tool's proposal: the road's
	-- shape stays): the end is then that node, nothing is split by the connection, and the game's
	-- preview shows it clean - split over the old road it showed red (the preview may not remove a
	-- segment: crashes in UI::CSelector, 2026-10-25). Once the end settles (not mid-drag), one at
	-- a time. A node made so and no longer an end is merged away again (Remove node's proposal: only
	-- a node joining exactly two segments, so one the new road now uses is left alone), and those
	-- left when the tool closes. Not with Replace (its ends along a road bound the replaced stretch),
	-- nor with a chain (its kept sections were made against the road as it was). One table: this
	-- function is near Lua's local limit
	local pre = react.useRef({ made = {}, failed = {}, seen = {} }):get() as {string : any}
	-- (now: the tool is closing - no world layer left to wait for; else sent next step, after a render
	-- of just the tooltip: its two segments are replaced)
	pre.remove = function(node : Engine.Entity, now? : boolean)
		local mk = (require "network_tools_1::/gui/construction/tools/remove_node/ntools_remove_node_tool.script.tl" as {string : any}).makeRemoveNodeProposal as function(Engine.Entity) : SimpleProposal
		local okP, sp = pcall(mk, node)
		if not okP or not sp then return end
		shared.debug("[network_tools] Connect: the node made for an end merged away again (" .. tostring(node) .. ")")
		if now then
			shared.send(api.cmd.makeWorldBuildProposalCmd(sp, nil, false, true))
			return
		end
		pre.busy = true
		pre.merge, pre.mergePhase = sp, "release"
	end
	react.onUnmount(function()
		for node in pairs(pre.made as {Engine.Entity : boolean}) do (pre.remove as function(Engine.Entity, boolean))(node, true) end
		pre.made = {}
	end)
	react.onStep(function()
		-- (a merge: released this step, sent the next)
		if pre.merge then
			if pre.mergePhase == "release" then pre.mergePhase = "send"; return end
			if pre.mergePhase == "send" then
				pre.mergePhase = "wait"
				local send = shared.send as function(Command<WorldBuildProposalCommandData>, function(WorldBuildProposalCommandData, boolean))
				send(api.cmd.makeWorldBuildProposalCmd(pre.merge as SimpleProposal, nil, false, true), function(__d : WorldBuildProposalCommandData, __ok : boolean)
					pre.merge, pre.mergePhase = nil, nil
					pre.busy = false
				end)
			end
			return
		end
		-- (the node build, sent a step after the end let go of the segment - see below)
		if pre.job and pre.phase == "send" then
			pre.phase = "wait"
			local job = pre.job as {string : any}
			local st = job.st as ReactStateT<Pick>
			local key = job.key as string
			local orig = job.orig as Pick
			local send = shared.send as function(Command<WorldBuildProposalCommandData>, function(WorldBuildProposalCommandData, boolean, {{Engine.Entity, Engine.Revision}}))
			send(api.cmd.makeWorldBuildProposalCmd(job.sp as SimpleProposal, nil, false, true), function(__d : WorldBuildProposalCommandData, success : boolean, result : {{Engine.Entity, Engine.Revision}})
				pre.job, pre.phase = nil, nil
				-- the end: still the point the segment was let go for?
				local cur = st:old()
				local still = cur ~= nil and cur.kind == "free" and cur.pos ~= nil and orig.pos ~= nil
					and math.abs(cur.pos.x - orig.pos.x) < 0.01 and math.abs(cur.pos.y - orig.pos.y) < 0.01
				if not success then
					(pre.failed as {string : boolean})[key] = true
					pre.busy = false
					-- (the segment is still there: the end along it again, split by the connection)
					if still and not aliveRef:hasExpired() then st:set(orig) end
					return
				end
				-- the new node: the result's node at the end's spot
				local node : Engine.Entity = nil
				pcall(function()
					for __, r in ipairs(result or {}) do
						local e = r[1]
						local bn = e and e >= 0 and api.engine.getComponent(e, api.type.ComponentType.BASE_NODE) as Engine.Component.BaseNode
						if bn and (bn.position.x - orig.pos.x) ^ 2 + (bn.position.y - orig.pos.y) ^ 2 < 4 then node = e end
					end
				end)
				pre.busy = false
				if not node then return end
				-- (the tool closed meanwhile: its onUnmount has run - merged away here)
				if aliveRef:hasExpired() then (pre.remove as function(Engine.Entity, boolean))(node, true); return end
				-- (when it was made: one no end reaches is merged away after a few seconds)
				;(pre.made as {Engine.Entity : any})[node] = os.clock()
				if still then
					local segs = api.engine.system.streetSystem.getNodeSegments(node) or {}
					st:set({ kind = "node", node = node, edge = segs[1], dir = orig.dir })
					shared.debug("[network_tools] Connect: a node made for the end along the road (" .. tostring(node) .. ")")
				end
			end)
			return
		end
		-- (released this step: send next step, after a render without the segment)
		if pre.job and pre.phase == "release" then pre.phase = "send"; return end
		if aliveRef:hasExpired() or pre.busy or draggingRef:get() ~= 0 then return end
		local made = pre.made as {Engine.Entity : any}   -- node -> os.clock() when it was made
		local pa, pb = firstState:old(), secondState:old()
		-- nodes made for ends that have moved off them: merged away (one per step) - not while an end
		-- is along one of its two segments (the merge replaces them). Only once an end has been seen on
		-- the node: the end is set to it in the build's callback, and that takes a render to show - the
		-- step before, it looked unused and was merged away at once (2026-10-25). One no end reaches
		-- within a few seconds goes too
		local seen = pre.seen as {Engine.Entity : boolean}
		for node, since in pairs(made) do
			local isEnd = (pa and pa.node == node) or (pb and pb.node == node)
			if isEnd then seen[node] = true end
			local segs : {Engine.Entity : boolean} = {}
			pcall(function()
				for __, s in ipairs(api.engine.system.streetSystem.getNodeSegments(node) or {}) do segs[s] = true end
			end)
			local onIt = (pa and pa.edge and segs[pa.edge]) or (pb and pb.edge and segs[pb.edge])
			local due = seen[node] or (type(since) == "number" and os.clock() - (since as number) > 3)
			if due and not onIt and not isEnd then
				seen[node] = nil
				made[node] = nil
				;(pre.remove as function(Engine.Entity))(node)
				return
			end
		end
		if g_replace or #verdict.chain > 0 or #verdict.after > 0 then return end
		for __, st in ipairs({ firstState, secondState }) do
			local p = st:old()
			local key = p and p.kind == "split" and p.edge and pickKey(p) or nil
			if key and not (pre.failed as {string : boolean})[key] then
				local mk = (require "network_tools_1::/gui/construction/tools/add_node/ntools_add_node_tool.script.tl" as {string : any}).makeAddNodeProposal as function(Engine.Entity, number, number) : (SimpleProposal, string)
				local okP, sp, why = pcall(mk, p.edge, p.pos.x, p.pos.y)
				if not okP or not sp then
					-- (the split as before: signals on it, too near its end ...)
					(pre.failed as {string : boolean})[key] = true
					shared.debug("[network_tools] Connect: no node first for the end along the road (" .. tostring(okP and why or sp) .. ")")
					return
				end
				-- Let go of the segment first: the end a plain point on that spot (no segment, so no
				-- proposal, check, highlight or Selector touches it), the world layer just a tooltip
				-- (pre.busy - as the Add node tool while it builds); the build goes a step later, once
				-- that has rendered. Touching the segment while the game replaces it crashed it natively
				-- (BaseEdge / BaseNode "being added", in UI::CSelector and a street geometry worker,
				-- 2026-10-25)
				pre.busy = true
				pre.job = { st = st, key = key, sp = sp, orig = p }
				pre.phase = "release"
				st:set({ kind = "free", pos = p.pos, dir = p.dir })
				return
			end
		end
	end)

	-- Changing a menu parameter doesn't re-render this recipe, so poll the mode every engine
	-- step; the state change triggers a re-render and a new preview.
	local modeState = engine_react_util.useStepState(function() : integer
		return g_mode or paramInt(params.getCurrentParams(), MODE_PARAM, MODE_CONNECTION)
	end)
	-- follow terrain / snapping are toggled from the toolbar or with T / C
	local followTerrainState = engine_react_util.useStepState(function() : boolean return g_followTerrain end)
	local snapState = engine_react_util.useStepState(function() : boolean return g_snap end)
	local anarchyState = engine_react_util.useStepState(function() : boolean return g_anarchy end)
	local bridgesState = engine_react_util.useStepState(function() : boolean return g_bridges end)
	local twinState = engine_react_util.useStepState(function() : integer return g_twin.side end)
	local networkState = engine_react_util.useStepState(function() : integer return g_networkId or 0 end)
	local replaceState = engine_react_util.useStepState(function() : boolean return g_replace end)
	local sharedState = engine_react_util.useStepState(function() : string
		-- options changed (also from the build menu, without the panel)? into the savegame
		((require "network_tools_1::/gui/construction/tools/shared/ntools_persist.script.tl" as {string : any}).tick as function())()
		return shared.key()
	end)
	local livePreviewState = engine_react_util.useStepState(function() : boolean return g_livePreview end)	-- Min. radius: its radius is set from the panel, the keys and the ring drag
	local dubinsRadiusState = engine_react_util.useStepState(function() : number return (dubins.opts as {string : number}).radius end)
	-- the extra modes' settings (connect/extra, set from the panel): a change re-renders, a new shape
	-- (one local: this function is near Lua's 200-local limit)
	local _extraOpts = engine_react_util.useStepState(function() : string
		local o = (require "network_tools_1::/gui/construction/tools/connect/extra/ntools_connect_extra.script.tl" as {string : any}).opts as {string : number}
		return tostring(o.easeLength) .. "/" .. tostring(o.helixRadius) .. "/" .. tostring(o.helixGrade) .. "/" .. tostring(o.gradeMax)
			-- (and a section clicked in the panel's Sections table: a re-render steps towards it)
			.. "/" .. tostring(verdict.chainTarget) .. "/" .. tostring(#verdict.chain)
	end):old()
	-- live preview off: why the game refused the last Build (there is no preview verdict to show)
	local refusedState : ReactStateT<string> = react.useState("")

	-- Toolbar buttons fire react events; route them through a ref that always holds the handlers
	-- of the latest render, so they never act on stale state.
	local handlersRef : ReactRefT<{string : function()}> = react.useRef({})
	for _, name in ipairs(TOOLBAR_EVENTS) do
		react.onEvent(name, function()
			local h = handlersRef:get()[name]
			if h then h() end
		end)
	end

	react.setForceFocusable(true)
	react.setRestrictMouseFocus(true)

	-- game controller (shared/ntools_pad - the Overpass Builder's controller path): its state in one
	-- local, this function being near Lua's local limit
	local pad = ((require "network_tools_1::/gui/construction/tools/shared/ntools_pad.script.tl" as {string : any}).use as function() : {string : any})()

	-- (on a pad the engine sets isActive on the confirm press and clears it again in the same frame:
	-- the tool stays while its world layer is up - pad.live)
	if not params.isActive and not pad.live then
		shared.opts.pointLabel = nil
		focusedRef:set(false)
		-- a chain doesn't outlive the tool (its preview reads these when drawn)
		if #verdict.chain > 0 or #verdict.after > 0 then
			verdict.chain, verdict.chainMerged, verdict.chainWhy = {}, nil, nil
			verdict.chainSnaps, verdict.after = {}, {}
			firstState:set(nil)
			secondState:set(nil)
		end
		return
	end
	if not focusedRef:get() then
		-- (the node may not exist on the first render: then the next render tries again)
		local ok = pcall(function() ((selfRef as any) as ReactRefWrap):get():focus() end)
		focusedRef:set(ok)
		if ok then shared.debug("[network_tools] Connect: focused for the key prompts") end
	end

	local mode = modeState:old() or paramInt(params.getCurrentParams(), MODE_PARAM, MODE_CONNECTION)
	local followTerrain = followTerrainState:old() == true
	local snap = snapState:old() ~= false
	local anarchy = anarchyState:old() == true
	local bridges = bridgesState:old() ~= false
	local _networkPoll = networkState:old()  -- read so a network change re-renders
	local _replacePoll = replaceState:old()  -- ... and so does Replace
	local _sharedPoll = sharedState:old()    -- ... and the shared options (height, incline, road properties)
	local _twinPoll = twinState:old()        -- ... and a twin change redraws its outline	-- collision / placement errors from the preview only block building without Anarchy (and only
	-- with live preview: without it there is no current verdict, the game checks on Build)
	local livePreview = livePreviewState:old() ~= false
	local blocked = livePreview and errorState:old() ~= "" and not anarchy
	local selected = selectedState:old()
	local angles = anglesState:old()
	local addMode = addModeState:old() == true

	local a = firstState:old()
	local b = secondState:old()
	-- a pick whose road was rebuilt meanwhile (the segment is gone) is dropped
	if a and a.edge and not getEdge(a.edge) then a = nil end
	if b and b.edge and not getEdge(b.edge) then b = nil end
	local A : P3 = pickPos(a)
	local B : P3 = pickPos(b)
	local ready = A ~= nil and B ~= nil and pickKey(a) ~= pickKey(b)
	-- Height offset: points on bare ground sit this far above / below it (also the follow-terrain
	-- profile between them)
	local offset = shared.opts.heightOffset or 0
	if A and a.kind == "free" then A = p3(A.x, A.y, A.z + offset) end
	if B and b.kind == "free" then B = p3(B.x, B.y, B.z + offset) end
	g_lift = ((a and a.kind == "free") or (b and b.kind == "free")) and offset or 0
	-- Fixed incline: an end on bare ground takes its height from the other end and the grade
	local incline = shared.opts.incline
	local inclineActive = incline ~= nil and ready and (a.kind == "free" or b.kind == "free")
	if inclineActive then followTerrain = false end
	-- Replace: the existing road between the picks goes
	local plan : ReplacePlan = nil
	if ready and g_replace then
		-- the path search walks the network: only again when the picks change (or a segment of the
		-- last result is gone)
		local key = pickKey(a) .. "|" .. pickKey(b)
		local cached = g_planCache.key == key and g_planCache.plan or nil
		if cached then
			for _, s in ipairs(cached.edges or {}) do
				if not getEdge(s) then cached = nil; break end
			end
		end
		plan = cached or findReplacePath(a, b)
		g_planCache.key, g_planCache.plan = key, plan
	end
	-- waypoints: Straight and Curve run through them; Connection makes them middle circles (only
	-- until its shape is edited - then a click adds a circle directly); Loop and Min. radius have none
	local waypoints = waypointsState:old() or {}
	-- (the extra modes: only Spline and Arc (9, 10) run through waypoints)
	local wps : {P3} = (mode == MODE_LOOP or mode == dubins.MODE or plan ~= nil or mode == 6 or mode == 7 or mode == 8 or mode == 11) and {} or waypoints
	-- the waypoints have their own handles (in Connection their circles do)
	local wpHandles = (mode == MODE_STRAIGHT or mode == MODE_CURVE or mode == 9 or mode == 10) and #wps > 0
	local ax, ay : number, number = nil, nil
	local bx, by : number, number = nil, nil
	if ready then
		local okP = plan == nil or plan.error == nil
		-- a free end faces the nearest point of the route
		ax, ay = endDir(a, wps[1] or B, okP and plan or nil, b)
		if ax then ax, ay = rotateDir(ax, ay, angles[1]) end
		-- like the first end's: the way the new road leaves B
		bx, by = endDir(b, wps[#wps] or A, okP and plan or nil, a)
		if bx then bx, by = rotateDir(bx, by, angles[2]) end
	end

	-- follow terrain climbs at most as steeply as the game lets the player build this type
	-- (the type's limit also judges the per-point heights)
	g_maxGrade = MAX_RAMP_GRADE
	local typeGrade = MAX_RAMP_GRADE
	local templateEdge = templateEdgeOf(a, b)
	if templateEdge or g_networkId then
		local e = templateEdge and getEdge(templateEdge)
		local tpl = templateById(g_networkId) or (e and templateByName(e.roadTemplate))
		local g = tpl and tpl.maxSlopeBuild
		if g and g > 0 then typeGrade = g > 1 and g / 100 or g end
		if followTerrain then g_maxGrade = typeGrade end
	end

	-- per-point heights (see Anchor): the waypoints in Straight / Curve, the circles in Connection
	g_anchors = {}
	if ready and (mode == MODE_STRAIGHT or mode == MODE_CURVE or mode == 9 or mode == 10) then
		for _, w in ipairs(wps) do g_anchors[#g_anchors + 1] = { x = w.x, y = w.y, lift = w.lift } end
	elseif ready and mode == MODE_CONNECTION and ax and bx and plan == nil then
		local st = connState:old() or connMode.defaultConnState(A, B, ax, ay, bx, by, wps)
		local recs : {{string : any}} = { st.first as {string : any} }
		for _, m in ipairs(st.middle) do recs[#recs + 1] = m as {string : any} end
		recs[#recs + 1] = st.last as {string : any}
		for i, c in ipairs((connMode.connCircles(A, B, ax, ay, bx, by, st))) do
			local rc = recs[i] or {}
			g_anchors[#g_anchors + 1] = { x = c.x, y = c.y, lift = (rc.lift or 0) as number, r = c.r,
				liftEnd = rc.liftEnd as number, structure = rc.structure as integer }
		end
	end

	local function generate() : GenResult
		if plan and plan.error then
			return { error = plan.error }
		elseif mode == MODE_STRAIGHT then
			return straightMode.genStraight(A, B, followTerrain, wps)
		elseif not ax or not bx then
			return { error = _("Can't read the road direction at one of the nodes") }
		elseif mode >= 6 and mode <= 11 then
			-- the extra modes (connect/extra: Easement, Helix, Grade path, Spline, Arc, Offset) - their
			-- route as prims / parts (heights from here, as Min. radius's) or finished pieces (Helix)
			local ex = require "network_tools_1::/gui/construction/tools/connect/extra/ntools_connect_extra.script.tl" as {string : any}
			local res = (ex.generate as function(integer, {string : any}) : {string : any})(mode, {
				A = A, B = B, ax = ax, ay = ay, bx = bx, by = by, wps = wps,
				radius = dubinsRadiusState:old() or (dubins.opts as {string : number}).radius,
				typeGrade = typeGrade, path = dubins.path, ground = terrainHeight,
			})
			if res.error then return { error = res.error as string } end
			local follow = followTerrain or res.follow == true
			local pieces = res.pieces as {Piece}
			if not pieces and res.prims then pieces = buildFromPrims(res.prims as {Prim}, A, B, follow)
			elseif not pieces and res.parts then pieces = toPieces(res.parts as {Piece2}, A, B, follow) end
			if not pieces or #pieces == 0 then return { error = _("Too short") } end
			return { pieces = pieces, circles = (res.circles or {}) as {Circle2}, info = res.info as string }
		elseif mode == MODE_CURVE then
			local ks = curveState:old() or { 1, 1 }
			return curveMode.genCurve(A, B, ax, ay, bx, by, followTerrain, ks[1], ks[2], wps)
		elseif mode == MODE_LOOP then
			local st = loopState:old() or { radius = DEFAULT_RADIUS, loop = false }
			return loopMode.genLoop(A, B, ax, ay, bx, by, st, followTerrain)
		elseif mode == dubins.MODE then
			-- shortest path with no curve tighter than the radius; it arrives at B against B's direction
			local r = dubinsRadiusState:old() or (dubins.opts as {string : number}).radius
			local path = dubins.path as function(number, number, number, number, number, number, number, number, number) : {string : any}
			local res = path(A.x, A.y, ax, ay, B.x, B.y, -bx, -by, r)
			if res.error then return { error = res.error as string } end
			local prims = res.prims as {Prim}
			local circles : {Circle2} = {}
			for _, p in ipairs(prims) do
				if not p.line then circles[#circles + 1] = { x = p.cx, y = p.cy, r = p.r } end
			end
			return {
				pieces = buildFromPrims(prims, A, B, followTerrain),
				circles = circles,
				info = _("Length") .. " " .. fmtLen(res.length as number) .. "   " .. _("Min. radius") .. " " .. fmtLen(r)
					.. "   (" .. ((res.engine as boolean) and _("game's path") or (res.word as string)) .. ")",
			}
		end
		local st = connState:old() or connMode.defaultConnState(A, B, ax, ay, bx, by, wps)
		return connMode.genConnection(A, B, ax, ay, bx, by, st, followTerrain)
	end

	local gen : GenResult = nil
	if ready then
		gen = generate()
		-- Fixed incline: the shape's length decides the free end's height, then build it again
		if inclineActive and gen and gen.pieces and not gen.error then
			local L = 0.0
			for _, pc in ipairs(gen.pieces) do
				L = L + geom.length({ p0 = p3(pc.p0.x, pc.p0.y, 0), t0 = p3(pc.t0.x, pc.t0.y, 0), p1 = p3(pc.p1.x, pc.p1.y, 0), t1 = p3(pc.t1.x, pc.t1.y, 0) })
			end
			local rise = incline / 100 * L
			if b.kind == "free" then
				B = p3(B.x, B.y, A.z + rise)
			else
				A = p3(A.x, A.y, B.z - rise)
			end
			gen = generate()
			if gen and not gen.error then
				gen.info = (gen.info and (gen.info .. "\n") or "") .. string.format("%s: %+.1f%%  (%+.1f m)", _("Incline"), incline, rise)
			end
		elseif incline ~= nil and ready and gen and not gen.error then
			gen.info = (gen.info and (gen.info .. "\n") or "") .. _("Incline: needs an end on bare ground (both ends keep their heights)")
		end
	end

	-- the panel's height profile (connect/extra setProfile: kept there - this file is at Lua's local
	-- limit; a block, its locals gone after it)
	do
		local exP = require "network_tools_1::/gui/construction/tools/connect/extra/ntools_connect_extra.script.tl" as {string : any}
		local setP = exP.setProfile as function({Piece}, function(number, number) : number, number, function(Piece) : string)
		-- (each piece's structure as Connect builds it: classified only with bridges on, as its preview)
		setP((gen and not gen.error) and gen.pieces or nil, terrainHeight, typeGrade,
			function(pc : Piece) : string return g_bridges and classifyPiece(pc) or "normal" end)
		-- the chain (M) for the panel's Sections table: the section being edited, and how many
		local st = exP.state as {string : any}
		st.chainCur = #verdict.chain + 1
		st.chainTotal = #verdict.chain + 1 + #verdict.after
		-- each section's middle (the panel's locate pin) and span (end to end, straight): the kept
		-- ones, this one, the ones after
		local secs : {{string : number}} = {}
		local function secOf(pa : Pick, pb : Pick) : {string : number}
			local A = pa and pickPos(pa)
			local B = pb and pickPos(pb)
			if A and B then
				return { x = (A.x + B.x) / 2, y = (A.y + B.y) / 2, z = (A.z + B.z) / 2, span = math.sqrt((B.x - A.x) ^ 2 + (B.y - A.y) ^ 2) }
			elseif A then
				return { x = A.x, y = A.y, z = A.z, span = 0 }
			end
			return { span = 0 }
		end
		for __, sn in ipairs(verdict.chainSnaps) do secs[#secs + 1] = secOf(sn.a as Pick, sn.b as Pick) end
		secs[#secs + 1] = secOf(a, b)
		for __, af in ipairs(verdict.after) do
			local sn = af.snap as {string : any}
			secs[#secs + 1] = secOf(sn and sn.a as Pick, sn and sn.b as Pick)
		end
		st.chainSections = secs
	end

	if gen and not gen.error and g_liftGrade > typeGrade then
		gen.info = (gen.info and (gen.info .. "\n") or "") .. string.format("%s: %.1f%% (%s %.1f%%)",
			_("Point heights need a grade of"), g_liftGrade * 100, _("this type allows"), typeGrade * 100)
	end

	local proposal : SimpleProposal = nil
	if gen and not gen.error and gen.pieces then
		local nBridges, nTunnels : integer, integer
		local why : string
		local view : SimpleProposal
		proposal, nBridges, nTunnels, why, view = makeProposal(a, b, gen.pieces, plan)
		if proposal and view then verdict.viewOf[proposal] = view end
		if why then
			gen.error = why
		end
		if proposal and plan and plan.edges then
			local k = #plan.edges
			for _ in pairs(plan.used) do k = k + 1 end
			gen.info = (gen.info and (gen.info .. "\n") or "") .. _("Replacing segments") .. ": " .. tostring(k)
		end
		if proposal and bridges then
			-- total bridge / tunnel length (only what there is)
			local bridgeM, tunnelM = 0.0, 0.0
			if (nBridges or 0) + (nTunnels or 0) > 0 then
				for _, pc in ipairs(gen.pieces) do
					local kind = classifyPiece(pc)
					if kind == "bridge" or kind == "tunnel" then
						local L = geom.length({ p0 = pc.p0, t0 = pc.t0, p1 = pc.p1, t1 = pc.t1 })
						if kind == "bridge" then bridgeM = bridgeM + L else tunnelM = tunnelM + L end
					end
				end
			end
			local bits : {string} = {}
			if bridgeM > 0 then bits[#bits + 1] = _("Bridge") .. " " .. fmtLen(bridgeM) end
			if tunnelM > 0 then bits[#bits + 1] = _("Tunnel") .. " " .. fmtLen(tunnelM) end
			if g_lastCrossings > 0 then bits[#bits + 1] = _("Raised over own crossings") .. ": " .. tostring(g_lastCrossings) end
			if #bits > 0 then
				gen.info = (gen.info and (gen.info .. "\n") or "") .. table.concat(bits, "   ")
			end
		end
		-- town houses in the way are demolished with the build: ask the game what's in the way
		-- only when the shape changes, and put those houses into every proposal of that shape
		if proposal then
			local parts : {string} = { pickKey(a), pickKey(b), tostring(g_networkId), tostring(g_replace), tostring(bridges) }
			for _, pc in ipairs(gen.pieces) do
				parts[#parts + 1] = string.format("%.1f,%.1f,%.1f", pc.p1.x, pc.p1.y, pc.p1.z)
			end
			local key = table.concat(parts, "|")
			local dem = verdict.demolition
			if key ~= dem.key then
				dem.key = key
				dem.houses = verdict.houses(verdict.of(proposal))
				if #dem.houses > 0 then
					shared.debug("[network_tools] Connect: " .. tostring(#dem.houses) .. " town house(s) in the way - demolished with the build")
				end
			end
			verdict.demolish(proposal, dem.houses)
			if #dem.houses > 0 then
				gen.info = (gen.info and (gen.info .. "\n") or "") .. _("Houses demolished") .. ": " .. tostring(#dem.houses)
			end
		end
	end

	-- Chained sections (Continue): the ones committed so far plus the current one (if it has a
	-- proposal yet) as one proposal - the preview and Build use it
	verdict.chainMerged, verdict.chainWhy, verdict.chainView = nil, nil, nil
	if (#verdict.chain > 0 or #verdict.after > 0) and g_twin.merge then
		do
			-- (the sections before the current one, it, and those after it - when the player went back)
			local list : {SimpleProposal} = {}
			for _, sp in ipairs(verdict.chain) do list[#list + 1] = sp end
			if proposal then list[#list + 1] = proposal end
			for _, s in ipairs(verdict.after) do
				if s.proposal then list[#list + 1] = s.proposal as SimpleProposal end
			end
			verdict.chainMerged, verdict.chainWhy = g_twin.merge(list)
			-- ... and what the preview shows of it: each section's new road alone where it removes
			-- segments (verdict.viewOf)
			local views : {SimpleProposal} = {}
			local trimmed = false
			for i, sp in ipairs(list) do
				views[i] = verdict.viewOf[sp] or sp
				if verdict.viewOf[sp] then trimmed = true end
			end
			if trimmed and verdict.chainMerged then verdict.chainView = g_twin.merge(views) end
		end
	end

	local function reset()
		if aliveRef:hasExpired() then
			return
		end
		firstState:set(nil)
		secondState:set(nil)
		connState:set(nil)
		loopState:set(nil)
		curveState:set(nil)
		waypointsState:set({})
		addModeState:set(false)
		draggingRef:set(0)
		draggingState:set(0)
		costState:set(0)
		errorState:set("")
		refusedState:set("")
		selectedState:set(1)
		anglesState:set({ 0, 0 })
		verdict.chain, verdict.chainSnaps, verdict.after = {}, {}, {}
	end

	local function build()
		-- (a chain builds even while its next section has no second point yet)
		if (not proposal and not verdict.chainMerged) or blocked then
			return
		end
		-- sections that couldn't be combined: build nothing rather than only the last one
		if (#verdict.chain > 0 or #verdict.after > 0) and not verdict.chainMerged then
			refusedState:set(_("The sections can't be built together") .. ": " .. tostring(verdict.chainWhy))
			return
		end
		-- one proposal in flight at a time
		if verdict.buildSince and os.clock() - verdict.buildSince < verdict.BUILD_TIMEOUT_S then
			return
		end
		-- live preview off: no verdict yet - ask the game now and say why, instead of sending a
		-- proposal it refuses (Anarchy builds anyway)
		if not livePreview and not anarchy then
			local checked = verdict.chainMerged or proposal
			local reason = verdict.blockReason(verdict.of(checked), checked)
			if reason then
				shared.debug("[network_tools] Connect: not built - " .. reason)
				refusedState:set(reason)
				return
			end
		end
		verdict.buildSince = os.clock()
		local context = api.type.Context.new()
		context.player = api.engine.util.getPlayer()
		-- like the game's builders: level the terrain under the road, move colliding bridge pillars
		pcall(function()
			context.extendProposalRedoPillars = true
			context.checkTerrainAlignment = true
		end)
		-- (the twin follows the new road from the start node: only when both ends are existing nodes
		-- and nothing is replaced)
		-- (a chain: all its sections in one build; no twin - see the preview)
		local chained = verdict.chainMerged ~= nil
		local startNode : Engine.Entity = a and a.node or nil
		local endNode : Engine.Entity = b and b.node or nil
		local twinOk : boolean = (not chained) and a ~= nil and b ~= nil and a.kind == "node" and b.kind == "node" and plan == nil
		-- an end on open ground / a split: no node to follow the new road from afterwards, so the
		-- twin is built with the connection, as the preview shows it (it has nothing to join there)
		local toBuild = verdict.chainMerged or proposal
		if not chained and g_twin.side ~= 0 and not twinOk and plan == nil and gen and gen.twinProposal then
			toBuild = gen.twinProposal
		end
		-- Sent with ignoreErrors once the game's verdict on exactly this proposal has nothing that
		-- blocks (asked here, not taken from the preview: Build may be pressed before the preview's
		-- data arrives). What's left are errors that don't block - collisions with the road being split
		-- or replaced, houses this build demolishes - which made the game turn a build down the
		-- player had been allowed to press. A critical refusal still stops it, whatever the flag
		-- (Anarchy: no check, as before)
		local ignoreErrors = anarchy
		if not anarchy then
			local reason = verdict.blockReason(verdict.of(toBuild), toBuild)
			if reason then
				verdict.buildSince = nil
				shared.debug("[network_tools] Connect: not built - " .. reason)
				refusedState:set(reason)
				return
			end
			ignoreErrors = true
		end
		local cmd = api.cmd.makeWorldBuildProposalCmd(toBuild, context, ignoreErrors, true)
		-- the segments at the start before building: the new one is the one that isn't among them
		local before : {Engine.Entity : boolean} = {}
		pcall(function()
			if twinOk then
				for _, s in ipairs(api.engine.system.streetSystem.getNodeSegments(startNode)) do before[s] = true end
			end
		end)
		-- (the shared send every tool's build goes through; new roads: Player owned applies)
		((require "network_tools_1::/gui/construction/tools/shared/ntools_options.script.tl" as {string : any}).send as function(Command<WorldBuildProposalCommandData>, function(WorldBuildProposalCommandData, boolean), boolean))(cmd, function(__ : WorldBuildProposalCommandData, success : boolean)
			verdict.buildSince = nil
			if success then
				-- Twin: a copy of the new connection beside it (double track / dual carriageway),
				-- made by Parallel; its ends join the parallel line's ends where they land. Roads
				-- run the other way (the second carriageway of a one-way pair).
				if g_twin.side ~= 0 and g_twin.copy and twinOk then
					local ok, err = pcall(function()
						-- the new connection as a chain: from the start node along the new segments
						local chain : {{string : any}} = {}
						local cur, seg : Engine.Entity, Engine.Entity = startNode, nil
						for _, s in ipairs(api.engine.system.streetSystem.getNodeSegments(startNode)) do
							if not before[s] then seg = s end
						end
						for _ = 1, 500 do
							if not seg then break end
							local e = getEdge(seg)
							if not e then break end
							local fwd = e.node0 == cur
							chain[#chain + 1] = { edge = seg, fwd = fwd }
							local nxt = fwd and e.node1 or e.node0
							if nxt == endNode then break end
							local segs = api.engine.system.streetSystem.getNodeSegments(nxt)
							if #segs ~= 2 then break end
							seg = segs[1] == seg and segs[2] or segs[1]
							cur = nxt
						end
						if #chain == 0 then return end
						local first = getEdge(chain[1].edge as Engine.Entity)
						local track = first.roadType == api.type["enum"].RoadType.TRACK
						-- beside it: the track spacing, or the road's own width
						local offset = laneWidth(first.laneConfigs)
						if track then
							local tpl = templateByName(first.roadTemplate)
							offset = (tpl and tpl.trackDistance and tpl.trackDistance > 0) and tpl.trackDistance or 5
						end
						local twin = g_twin.copy(chain, offset * g_twin.side, not track)
						if not twin then return end
						local ctx = api.type.Context.new()
						ctx.player = api.engine.util.getPlayer()
						pcall(function()
							ctx.extendProposalRedoPillars = true
							ctx.checkTerrainAlignment = true
						end)
						shared.send(api.cmd.makeWorldBuildProposalCmd(twin, ctx, anarchy, true),
							function(__ : WorldBuildProposalCommandData, ok2 : boolean)
								if not ok2 then shared.debug("[network_tools] Connect: twin build failed") end
							end, true)
					end)
					if not ok then shared.debug("[network_tools] Connect: twin failed: " .. tostring(err)) end
				end
				reset()
			else
				shared.debug("[network_tools] Connect: build failed")
				if not aliveRef:hasExpired() and not g_livePreview then
					local reason = verdict.blockReason(verdict.of(toBuild), toBuild)
					refusedState:set(reason and (_("The game refused to build this") .. ": " .. reason)
						or _("The game refused to build this - turn on Live preview to see why"))
				end
			end
		end, true)
	end

	local function clearShape()
		costState:set(0)
		errorState:set("")
		refusedState:set("")
		connState:set(nil)
		loopState:set(nil)
		curveState:set(nil)
	end

	local function choose(pick : Pick)
		local key = pickKey(pick)
		if a == nil then
			firstState:set(pick)
		elseif not g_replace and pick.kind == "node" and a.kind == "node" and pick.edge == a.edge and pick.node ~= a.node then
			-- same road, other end: switch which end (and direction) end 1 uses
			-- (CS1 "click on node to change create direction")
			firstState:set(pick)
			clearShape()
		elseif not g_replace and b ~= nil and pick.kind == "node" and b.kind == "node" and pick.edge == b.edge and pick.node ~= b.node then
			secondState:set(pick)
			clearShape()
		elseif key == pickKey(a) then
			reset()
		elseif b ~= nil and key == pickKey(b) then
			-- already the second point: keep the current shape (building is done with the Build button)
		else
			clearShape()
			secondState:set(pick)
		end
	end

	-- Replace + Shift+click: the whole stretch the segment belongs to (out to the next junctions or
	-- dead ends) becomes A .. B
	local function chooseStretch(entity : Engine.Entity) : boolean
		local e = getEdge(entity)
		if not e then return false end
		local function walk(node : Engine.Entity, seg : Engine.Entity) : Engine.Entity, Engine.Entity
			for _ = 1, 1000 do
				local segs = segmentsAt(node)
				if #segs ~= 2 then break end
				local nxt = segs[1] == seg and segs[2] or segs[1]
				local ne = getEdge(nxt)
				if not ne or ne.roadType ~= e.roadType or nxt == entity then break end
				seg = nxt
				node = ne.node0 == node and ne.node1 or ne.node0
			end
			return node, seg
		end
		local n0, s0 = walk(e.node0, entity)
		local n1, s1 = walk(e.node1, entity)
		if n0 == n1 then return false end   -- a closed loop: no ends to keep
		firstState:set({ kind = "node", node = n0, edge = s0 })
		secondState:set({ kind = "node", node = n1, edge = s1 })
		clearShape()
		return true
	end

	local function onSelect(entity : Engine.Entity) : boolean
		if not isEdge(entity) or not api.gui.mouse.hasTerrainPosition() then
			return false
		end
		-- Move ends mode: the press is onMouse's (it drags an end) - the click must not re-pick an end
		-- (Shift too: a Shift+click on a road is the start of a Shift+double-click that adds a point)
		if ready and (addMode or precise()) then
			return true
		end
		if g_replace and precise() and chooseStretch(entity) then
			return true
		end
		local m = api.gui.mouse.getTerrainPosition()
		local pick : Pick = nil
		if getEdge(entity) then
			pick = pickOnEdge(entity, m.x, m.y)
		else
			-- a station's track: the new line joins it at its open end (its own track can't be split)
			local _, e, n = isEdge(entity)
			if e then pick = { kind = "node", node = n, edge = e } end
		end
		if not pick then
			return false
		end
		choose(pick)
		return true
	end

	local function setDragging(index : integer)
		draggingRef:set(index)
		draggingState:set(index)
	end

	local function currentConnState() : ConnState
		return connState:old() or connMode.defaultConnState(A, B, ax, ay, bx, by, wps)
	end

	-- number of selectable circles/ends in the current mode
	local function selectableCount() : integer
		if mode == MODE_CONNECTION and ready and ax and bx then
			return connMode.connCount(currentConnState())
		end
		return 2
	end
	local selectedClamped = math.min(math.max(selected, 1), selectableCount())

	-- Per-point height: the panel shows a slider for the selected circle (Connection) or waypoint
	-- (Straight / Curve). Our value goes to the slider when the selection or the value changes on
	-- our side; a slider move is stored into the point.
	local selectedWp = selectedWpState:old() or 0
	if selectedWp > #waypoints then selectedWp = 0 end
	local pointLabel : string = nil
	local pointLift = 0.0
	-- a circle (Connection) has more: its end-of-arc height, radius, structure, and a middle one can
	-- be moved. The panel edits shared.opts.point*; pointSent is what we last showed it.
	local so = shared.opts
	local circ : {string : any} = nil
	if ready and mode == MODE_CONNECTION and ax and bx and plan == nil then
		local st = currentConnState()
		local n = connMode.connCount(st)
		pointLabel = selectedClamped == 1 and _("end circle 1") or (selectedClamped == n and _("end circle 2")
			or (_("circle") .. " " .. tostring(selectedClamped)))
		local c : {string : any} = selectedClamped == 1 and (st.first as {string : any})
			or (selectedClamped == n and (st.last as {string : any}) or (st.middle[selectedClamped - 1] as {string : any}))
		pointLift = (c.lift or 0) as number
		circ = { liftEnd = c.liftEnd, radius = c.radius, structure = c.structure or 1, movable = selectedClamped > 1 and selectedClamped < n }
	elseif ready and wpHandles and selectedWp > 0 then
		pointLabel = _("waypoint") .. " " .. tostring(selectedWp)
		pointLift = waypoints[selectedWp].lift or 0
	end
	if circ then
		local function keyOf(label : string, lift : number, liftEnd : number, radius : number, structure : integer) : string
			return string.format("%s|%.2f|%s|%.1f|%d", tostring(label), lift or 0, liftEnd and string.format("%.2f", liftEnd) or "-", radius or 0, structure or 1)
		end
		local own = keyOf(pointLabel, pointLift, circ.liftEnd as number, circ.radius as number, circ.structure as integer)
		local panel = keyOf(so.pointLabel, so.pointHeight, so.pointHeightEnd, so.pointRadius, so.pointStructure)
		local move = so.pointMove
		-- (only once we have shown this circle: values left from another selection mean nothing)
		if so.pointCircle and so.pointSent ~= nil and so.pointLabel == pointLabel and (panel ~= so.pointSent or move) then
			-- the panel changed the selected circle: store it
			so.pointMove = nil
			local hs, he, r, s = so.pointHeight or 0, so.pointHeightEnd, so.pointRadius, so.pointStructure or 1
			connState:set(connMode.withCircle(currentConnState(), selectedClamped, function(cc : ConnCircle, m : MidCircle)
				local x : {string : any} = cc and (cc as {string : any}) or (m as {string : any})
				x.lift, x.liftEnd, x.structure = hs, he, s ~= 1 and s or nil
				if r and r >= 5 then x.radius = r end
				if m and move then m.x, m.y = m.x + move[1], m.y + move[2] end
			end))
			so.pointSent = panel
		elseif own ~= so.pointSent then
			-- the selection or the circle changed on our side: show it
			so.pointLabel, so.pointHeight, so.pointHeightEnd = pointLabel, pointLift, circ.liftEnd as number
			so.pointRadius, so.pointStructure, so.pointMovable = circ.radius as number, circ.structure as integer, circ.movable as boolean
			so.pointCircle, so.pointMove, so.pointSent = true, nil, own
			pointLabelRef:set(pointLabel)
			pointLiftRef:set(pointLift)
		end
	elseif pointLabel ~= pointLabelRef:get() or pointLift ~= pointLiftRef:get() then
		pointLabelRef:set(pointLabel)
		pointLiftRef:set(pointLift)
		shared.opts.pointLabel, shared.opts.pointHeight = pointLabel, pointLift
		so.pointCircle, so.pointSent = false, nil
	elseif pointLabel and (shared.opts.pointHeight or 0) ~= pointLift then
		local h = shared.opts.pointHeight or 0
		pointLiftRef:set(h)
		do
			local nw : {P3} = {}
			for i, w in ipairs(waypoints) do nw[i] = w end
			local w = waypoints[selectedWp]
			nw[selectedWp] = { x = w.x, y = w.y, z = w.z, lift = h, hx = w.hx, hy = w.hy, hb = w.hb }
			waypointsState:set(nw)
		end
	end

	-- which road end the angle keys act on (nil = the selection has no road end)
	local function selectedEnd() : integer
		if mode ~= MODE_CONNECTION then
			return selectedClamped
		end
		if selectedClamped == 1 then return 1 end
		if selectedClamped == selectableCount() then return 2 end
		return nil
	end

	-- Drag target: > 0 = centre of circle i, < 0 = rim of circle -i (CS1 CreateConnectionMoveCircle
	-- and CreateConnectionChangeRadius).
	local function applyDrag(target : integer, mx : number, my : number)
		if not ready or not ax or not bx then
			return
		end
		if mode == MODE_CONNECTION then
			local st = currentConnState()
			local n = connMode.connCount(st)
			local idx = math.abs(target)
			local nst : ConnState
			if target < 0 then
				local c = gen.circles[idx]
				if not c then return end
				local r = math.sqrt((mx - c.x) ^ 2 + (my - c.y) ^ 2)
				nst = connMode.withRadius(st, idx, r)
				nst = snap and connMode.snapRadius(A, B, ax, ay, bx, by, nst, idx, 1) or nst
			elseif idx == 1 or idx == n then
				nst = connMode.copyConn(st)
				if idx == 1 then
					nst.first = connMode.dragConnCircle(A, ax, ay, st.first, mx, my)
				else
					nst.last = connMode.dragConnCircle(B, bx, by, st.last, mx, my)
				end
			else
				nst = connMode.moveMiddle(st, idx, mx, my)
			end
			connState:set(nst)
		elseif mode == MODE_CURVE and math.abs(target) > 2 then
			-- a waypoint's handle (3, 4: waypoint 1's front / back; 5, 6: waypoint 2's ...): it turns
			-- the road's direction there (both handles stay in line) and sets how far the curve swings
			-- on its side; the other handle keeps its length
			local h = math.abs(target) - 3
			local j, back = math.floor(h / 2) + 1, h % 2 == 1
			local w = waypoints[j]
			if not w then return end
			local vx, vy = mx - w.x, my - w.y
			local vl = math.sqrt(vx * vx + vy * vy)
			if vl < 0.5 then return end
			-- the other handle's current length (as drawn)
			local other = gen.handles and gen.handles[back and math.abs(target) - 1 or math.abs(target) + 1]
			local ol = other and math.sqrt((other.x - w.x) ^ 2 + (other.y - w.y) ^ 2) or vl
			local fx, fy, fl, bl : number, number, number, number
			if back then
				fx, fy, fl, bl = -vx / vl, -vy / vl, ol, vl
			else
				fx, fy, fl, bl = vx / vl, vy / vl, vl, ol
			end
			local nw : {P3} = {}
			for i, v in ipairs(waypoints) do nw[i] = v end
			nw[j] = { x = w.x, y = w.y, z = w.z, lift = w.lift, hx = fx * fl, hy = fy * fl, hb = bl }
			waypointsState:set(nw)
		elseif mode == MODE_CURVE then
			-- slide a control point along its end's guide line
			local idx = math.abs(target)
			local len0, len1 = curveMode.curveEndLengths(A, B, wps)
			local len = idx == 2 and len1 or len0
			if len < MIN_PRIM_LENGTH then return end
			local P, dx, dy = A, ax, ay
			if idx == 2 then P, dx, dy = B, bx, by end
			local k = clamp(3 * ((mx - P.x) * dx + (my - P.y) * dy) / len, curveMode.CURVE_K_MIN, curveMode.CURVE_K_MAX)
			if snap then k = math.max(curveMode.CURVE_K_MIN, math.floor(k / curveMode.CURVE_K_SNAP + 0.5) * curveMode.CURVE_K_SNAP) end
			local ks = curveState:old() or { 1, 1 }
			local nks = { ks[1], ks[2] }
			nks[idx] = k
			curveState:set(nks)
		elseif mode == MODE_LOOP then
			if target < 0 then
				local c = gen.circles[1]
				if not c then return end
				local st = loopState:old() or { radius = DEFAULT_RADIUS, loop = false }
				local r = math.sqrt((mx - c.x) ^ 2 + (my - c.y) ^ 2)
				if snap then r = math.floor(r / SNAP_RADIUS_STEP + 0.5) * SNAP_RADIUS_STEP end
				loopState:set({ radius = clamp(r, MIN_RADIUS, MAX_RADIUS), loop = st.loop })
			else
				local st = loopMode.dragLoop(A, B, ax, ay, bx, by, mx, my, snap)
				if st then
					loopState:set(st)
				end
			end
		elseif mode == dubins.MODE and target < 0 then
			-- any arc's ring sets the minimum radius (all arcs share it)
			local c = gen.circles[-target]
			if not c then return end
			local r = math.sqrt((mx - c.x) ^ 2 + (my - c.y) ^ 2)
			if snap then r = math.floor(r / SNAP_RADIUS_STEP + 0.5) * SNAP_RADIUS_STEP end
			(dubins.opts as {string : number}).radius = clamp(r, MIN_RADIUS, MAX_RADIUS)
		end
	end

	local function hitCentre(mx : number, my : number) : integer
		for i, h in ipairs(gen.handles or {}) do
			if (mx - h.x) ^ 2 + (my - h.y) ^ 2 <= HANDLE_HIT_RADIUS_M ^ 2 then
				return i
			end
		end
		return 0
	end

	local function hitRim(mx : number, my : number) : integer
		for i, c in ipairs(gen.circles or {}) do
			local d = math.sqrt((mx - c.x) ^ 2 + (my - c.y) ^ 2)
			if math.abs(d - c.r) <= 5 then   -- CS1: the rim is grabbable within 5 m
				return i
			end
		end
		return 0
	end

	-- Mouse handling (pattern from the MoveIt mod: hit-test in world metres against the terrain
	-- cursor; clear a stale drag on the next press because a re-mounted Selector can swallow the
	-- Released event). CS1 gestures: drag centre = move, drag rim = radius, double-click centre =
	-- flip direction; Shift + click centre = remove (CS1: Shift + double-click). (CS1's double-click straight = add
	-- circle is Shift + double-click here.)
	local function handleMouse(evt : Gui.Mouse.Event) : boolean
		local Type = api.gui.mouse.Event.Type
		if evt.type == Type.Pressed and draggingRef:get() ~= 0 then
			setDragging(0)
		end
		-- (Min. radius has rings but no centre handles)
		if not gen or (#(gen.handles or {}) == 0 and #(gen.circles or {}) == 0) then
			return false
		end
		if (evt.type == Type.Pressed or evt.type == Type.DoubleClicked) and evt.button == 0 then
			if not api.gui.mouse.hasTerrainPosition() then
				return false
			end
			local m = api.gui.mouse.getTerrainPosition()
			local centre = hitCentre(m.x, m.y)
			if evt.type == Type.DoubleClicked then
				if mode == MODE_CONNECTION then
					if centre > 0 then
						-- (Shift: the first click already removed it - see below)
						if not precise() then
							connState:set(connMode.flipCircle(currentConnState(), centre))
						end
						return true
					end
					-- (a circle is added by a click in add points mode: addWaypoint)
				end
				-- Curve: double-click either of a waypoint's handles (3, 4: waypoint 1; 5, 6: waypoint
				-- 2 ...) - its direction is automatic again
				local wj = math.floor((centre - 3) / 2) + 1
				if mode == MODE_CURVE and centre > 2 and waypoints[wj] then
					local w = waypoints[wj]
					local nw : {P3} = {}
					for i, v in ipairs(waypoints) do nw[i] = v end
					nw[wj] = { x = w.x, y = w.y, z = w.z, lift = w.lift }
					waypointsState:set(nw)
					setDragging(0)
					return true
				end
				return centre > 0
			end
			-- Shift+click a middle circle's centre: remove it (like a waypoint; the end circles stay)
			if centre > 0 and precise() and mode == MODE_CONNECTION then
				local st = currentConnState()
				if centre > 1 and centre < connMode.connCount(st) then
					connState:set(connMode.removeCircle(st, centre))
					selectedState:set(math.max(1, centre - 1))
					return true
				end
			end
			if centre > 0 then
				setDragging(centre)
				if mode == MODE_CONNECTION then
					selectedState:set(centre)
				end
				return true
			end
			local rim = hitRim(m.x, m.y)
			if rim > 0 then
				setDragging(-rim)
				if mode == MODE_CONNECTION then
					selectedState:set(rim)
				end
				return true
			end
		elseif evt.type == Type.Moved and draggingRef:get() ~= 0 then
			if api.gui.mouse.hasTerrainPosition() then
				local m = api.gui.mouse.getTerrainPosition()
				applyDrag(draggingRef:get(), m.x, m.y)
			end
			return true
		elseif evt.type == Type.Released and draggingRef:get() ~= 0 then
			setDragging(0)
			return true
		end
		return false
	end

	-- the ground point whose handle is under (mx, my): 1 / 2 = an end, 2 + i = waypoint i; or 0
	local function hitPoint(mx : number, my : number) : integer
		local function near(p : P3) : boolean
			return (mx - p.x) ^ 2 + (my - p.y) ^ 2 <= HANDLE_HIT_RADIUS_M ^ 2
		end
		for i, p in ipairs(wpHandles and wps or {}) do
			if near(p) then return 2 + i end
		end
		if a and a.kind == "free" and near(a.pos) then return 1 end
		if b and b.kind == "free" and near(b.pos) then return 2 end
		return 0
	end

	-- a click on bare ground once both ends are set: Straight / Curve get a waypoint there,
	-- Connection a circle the road passes the point on
	local function addWaypoint(x : number, y : number)
		if mode == MODE_CONNECTION then
			if not gen or not gen.straights or #gen.straights == 0 then return end
			local best, bestD = 1, math.huge
			for k, s in ipairs(gen.straights) do
				local dx, dy = s.x1 - s.x0, s.y1 - s.y0
				local len2 = math.max(dx * dx + dy * dy, 1e-6)
				local t = clamp(((x - s.x0) * dx + (y - s.y0) * dy) / len2, 0, 1)
				local d = (x - s.x0 - dx * t) ^ 2 + (y - s.y0 - dy * t) ^ 2
				if d < bestD then best, bestD = k, d end
			end
			connState:set(connMode.insertCircleThrough(currentConnState(), best, gen.straights[best], x, y))
			selectedState:set(best + 1)
		elseif mode == MODE_STRAIGHT or mode == MODE_CURVE or mode == 9 or mode == 10 then
			local nw : {P3} = {}
			for i, w in ipairs(waypoints) do nw[i] = w end
			local slot = waypointSlot(A, B, waypoints, x, y)
			table.insert(nw, slot, pickFree(x, y).pos)
			waypointsState:set(nw)
			selectedWpState:set(slot)
		end
	end

	-- Snap to roads (Shift: off): the road / node within ROAD_SNAP_M of (x, y), or nil. Before that
	-- (Snap to roads on or off): an end of another section of the chain (M) close by - one the user
	-- pulled apart snaps back on, the way that section runs there - unless it is notAt's spot (the
	-- section's other end)
	local function snapToRoad(x : number, y : number, notAt : Pick) : Pick
		if precise() then return nil end
		-- (a branch off another section's middle comes after a built road: below)
		local chainBranch : Pick = nil
		if #verdict.chain + #verdict.after > 0 then
			local ex = require "network_tools_1::/gui/construction/tools/connect/extra/ntools_connect_extra.script.tl" as {string : any}
			-- (function casts in locals of their own: a cast's return list would swallow the arguments after it)
			local snapFn = ex.chainSnap as function(number, number, {string : any}, function(any) : (P3), P3) : Pick
			local posFn = pickPos as function(any) : P3
			local okJ, j = pcall(snapFn, x, y, verdict as {string : any}, posFn, pickPos(notAt))
			local jP = okJ and j and pickPos(j) or nil
			local oP = pickPos(notAt)
			if jP and not (oP and (jP.x - oP.x) ^ 2 + (jP.y - oP.y) ^ 2 < 1) then
				-- (a branch point is at the road's own height: the height offset a ground point gets
				-- added must not lift it off)
				if (j as {string : any}).branch then
					j.pos.z = j.pos.z - (shared.opts.heightOffset or 0)
					chainBranch = j
				else
					return j
				end
			end
		end
		if not shared.opts.snapToRoads then return chainBranch end
		local snapped : Pick = nil
		pcall(function()
			local best, bestD : Engine.Entity, number = nil, ROAD_SNAP_M
			for _, s in ipairs(api.engine.util.octree.findEntitiesInCircle(api.type.Vec2f.new(x, y), ROAD_SNAP_M + 20, api.type.ComponentType.BASE_EDGE)) do
				local e = getEdge(s)
				if e then
					local _t, d = geom.closestT(geom.edgePiece(e), x, y)
					if d < bestD then best, bestD = s, d end
				end
			end
			if best then snapped = pickOnEdge(best, x, y) end
		end)
		return snapped or chainBranch
	end

	local function onMouse(evt : Gui.Mouse.Event) : boolean
		local Type = api.gui.mouse.Event.Type
		-- dragging a ground point's handle moves the point; an end dragged onto a road joins it
		-- (the node near its end, or a split partway along - like a click; Shift: no snapping).
		-- The drag carries on, so the end can be pulled off the road again before letting go.
		if draggingRef:get() > DRAG_POINT then
			if evt.type == Type.Moved then
				if api.gui.mouse.hasTerrainPosition() then
					local m = api.gui.mouse.getTerrainPosition()
					local k = draggingRef:get() - DRAG_POINT
					local moved = pickFree(m.x, m.y)
					if k <= 2 then
						-- (not onto the other end itself)
						local other = k == 1 and b or a
						local onRoad = snapToRoad(m.x, m.y, other)
						if onRoad and pickKey(onRoad) ~= pickKey(other) then moved = onRoad end
						-- onto / off something that sets the end's direction (a road, a node, another
						-- section's end or middle): Connection's circles anew - their turning sides were
						-- made for the old direction (a branch turned 327° the long way round)
						local function anchorKey(p : Pick) : string
							if not p then return "-" end
							if p.kind == "free" and not p.dir and not p.axis then return "free" end
							return pickKey(p)
						end
						if anchorKey(moved) ~= anchorKey(k == 1 and a or b) then connState:set(nil) end
					end
					if k == 1 then
						firstState:set(moved)
					elseif k == 2 then
						secondState:set(moved)
					elseif waypoints[k - 2] then
						local nw : {P3} = {}
						for i, w in ipairs(waypoints) do nw[i] = w end
						-- (its Curve handle moves with it)
						nw[k - 2] = { x = moved.pos.x, y = moved.pos.y, z = moved.pos.z, lift = waypoints[k - 2].lift,
							hx = waypoints[k - 2].hx, hy = waypoints[k - 2].hy, hb = waypoints[k - 2].hb }
						waypointsState:set(nw)
					end
				end
				return true
			elseif evt.type == Type.Released or evt.type == Type.Pressed then
				local k = draggingRef:get() - DRAG_POINT
				if k <= 2 then
					local p = k == 1 and firstState:old() or secondState:old()
					-- (and the nearest built road there: found / how far - why it did or didn't join)
					local near = "none within 30 m"
					pcall(function()
						local P = pickPos(p)
						if not P then return end
						local bestD : number = nil
						local bestS : Engine.Entity = nil
						local n = 0
						for __, s in ipairs(api.engine.util.octree.findEntitiesInCircle(api.type.Vec2f.new(P.x, P.y), 30, api.type.ComponentType.BASE_EDGE)) do
							n = n + 1
							local e = getEdge(s)
							if e then
								local _t, d = geom.closestT(geom.edgePiece(e), P.x, P.y)
								if not bestD or d < bestD then bestD, bestS = d, s end
							end
						end
						if bestS then near = string.format("edge %d at %.1f m (%d found)", bestS, bestD, n)
						elseif n > 0 then near = string.format("%d found, none readable", n) end
					end)
					shared.debug(string.format("[network_tools] Connect: end %d dropped as %s (snap to roads %s, shift %s; nearest road: %s; chain %d+%d)", k,
						p and p.kind or "?", tostring(shared.opts.snapToRoads), tostring(precise()), near, #verdict.chain, #verdict.after))
				end
				setDragging(0)
				return true
			end
		end
		-- Shift+double-click (not on a handle): add a circle / waypoint there, over a road too
		if evt.type == Type.DoubleClicked and evt.button == 0 and ready and precise() and api.gui.mouse.hasTerrainPosition() then
			local m = api.gui.mouse.getTerrainPosition()
			local onHandle = hitPoint(m.x, m.y) > 0
				or (gen and gen.handles and #gen.handles > 0 and (hitCentre(m.x, m.y) > 0 or hitRim(m.x, m.y) > 0))
			if not onHandle then
				addWaypoint(m.x, m.y)
				return true
			end
		end
		-- Move ends mode (N): a press near the start / end point drags it (snapping onto roads as a
		-- ground point's drag does), even where a circle's handles overlap it; a road end is moved
		-- that way too (its ring has no handle otherwise)
		if evt.type == Type.Pressed and evt.button == 0 and ready and addMode and api.gui.mouse.hasTerrainPosition() then
			local m = api.gui.mouse.getTerrainPosition()
			local best, bestD = 0, 15 * 15   -- grab within 15 m of an end
			for k, p in ipairs({ a, b }) do
				local P = pickPos(p)
				if P then
					local d = (P.x - m.x) ^ 2 + (P.y - m.y) ^ 2
					if d < bestD then best, bestD = k, d end
				end
			end
			if best > 0 then
				setDragging(DRAG_POINT + best)
			end
			-- (a press elsewhere does nothing in this mode)
			return true
		end
		if evt.type == Type.Pressed and evt.button == 0 and api.gui.mouse.hasTerrainPosition() then
			local m = api.gui.mouse.getTerrainPosition()
			-- the circle handles take precedence where they overlap a point
			local onCircle = gen and gen.handles and #gen.handles > 0 and (hitCentre(m.x, m.y) > 0 or hitRim(m.x, m.y) > 0)
			local k = hitPoint(m.x, m.y)
			-- (hidden ends can't be grabbed: N - move ends mode - shows and moves them)
			if k > 0 and k <= 2 and gen and gen.hideEnds then k = 0 end
			if k > 0 and not onCircle then
				if k > 2 and precise() then
					-- Shift+click a waypoint: remove it
					local nw : {P3} = {}
					for i, w in ipairs(waypoints) do
						if i ~= k - 2 then nw[#nw + 1] = w end
					end
					waypointsState:set(nw)
					selectedWpState:set(0)
				else
					if k > 2 then selectedWpState:set(k - 2) end
					setDragging(DRAG_POINT + k)
				end
				return true
			end
		end
		if handleMouse(evt) then
			return true
		end
		-- a click on bare ground (no road under the cursor, no handle hit): a free point - or, with
		-- Snap to roads (Shift: off), the road / node right next to it
		if evt.type == Type.Pressed and evt.button == 0 and (hoverRef:get() or -1) < 0
				and api.gui.mouse.hasTerrainPosition() then
			local m = api.gui.mouse.getTerrainPosition()
			local snapped = snapToRoad(m.x, m.y, a)
			if snapped then
				choose(snapped)
			elseif ready then
				-- both ends set: the ends stay put (drag their handles to move them; N: move ends
				-- mode drags them from anywhere near, road ends too)
			else
				choose(pickFree(m.x, m.y))
			end
			return true
		end
		return false
	end

	------------------------------------------------------------------------------------------------
	-- Keyboard controls (CS1 shortcuts mapped onto the game's construction input actions)

	local hasPair = function() : boolean return ready end
	local hasRadius = function() : boolean return ready and (mode == MODE_CONNECTION or mode == MODE_LOOP or mode == dubins.MODE) end
	local hasAngles = function() : boolean return ready and mode ~= MODE_STRAIGHT and selectedEnd() ~= nil end

	local function changeRadius(sign : number)
		local step = precise() and RADIUS_STEP_FINE or RADIUS_STEP
		local function stepped(r : number) : number
			return clamp(math.floor((r + sign * step) / step + 0.5) * step, MIN_RADIUS, MAX_RADIUS)
		end
		if mode == MODE_CONNECTION then
			local st = currentConnState()
			connState:set(connMode.withRadius(st, selectedClamped, stepped(connMode.radiusOf(st, selectedClamped))))
		elseif mode == MODE_LOOP then
			local st = loopState:old() or { radius = DEFAULT_RADIUS, loop = false }
			-- start from the radius actually in use (the generator clamps it)
			local r = (gen and gen.circles and gen.circles[1]) and gen.circles[1].r or st.radius
			loopState:set({ radius = stepped(r), loop = st.loop })
		elseif mode == dubins.MODE then
			local o = dubins.opts as {string : number}
			o.radius = stepped(o.radius)
		end
	end

	local function changeAngle(sign : number)
		local e = selectedEnd()
		if not e then return end
		local step = precise() and ANGLE_STEP_FINE or ANGLE_STEP
		local na = { angles[1], angles[2] }
		na[e] = clamp(na[e] + sign * step, -MAX_END_ANGLE, MAX_END_ANGLE)
		anglesState:set(na)
	end

	-- [ / ]: step through the circles in Connection (CS1 Tab), pick end 1 / 2 in the other modes
	local function selectStep(dir : integer)
		if mode == MODE_CONNECTION then
			selectedState:set(math.floor(clamp(selectedClamped + dir, 1, selectableCount())))
		else
			selectedState:set(dir < 0 and 1 or 2)
		end
	end
	-- the two keys of a pair share one prompt text: the game then shows them as one row ("O / P
	-- Angle"), like its own road tool (pattern from the MoveIt mod)
	local selectPrompt = mode == MODE_CONNECTION and _("Select circle") or _("Select end")

	safeUseInputAction("constructRaise", shortcutHandler(function() changeRadius(1) end, hasRadius, _("Radius"), true))
	safeUseInputAction("constructLower", shortcutHandler(function() changeRadius(-1) end, hasRadius, _("Radius"), true))
	safeUseInputAction("constructOpt6", shortcutHandler(function() changeAngle(1) end, hasAngles, _("Angle"), true))
	safeUseInputAction("constructOpt5", shortcutHandler(function() changeAngle(-1) end, hasAngles, _("Angle"), true))
	safeUseInputAction("constructOpt7", shortcutHandler(function() selectStep(-1) end, hasPair, selectPrompt))
	safeUseInputAction("constructOpt8", shortcutHandler(function() selectStep(1) end, hasPair, selectPrompt))
	safeUseInputAction("constructAlignToTerrain", shortcutHandler(function() g_followTerrain = not followTerrain; syncCheckbox(FOLLOW_PARAM, g_followTerrain) end, hasPair,
		followTerrain and _("Follow terrain: on") or _("Follow terrain: off")))
	-- M - Continue (chain): the current section is kept as it is, and the next one starts at its
	-- second point, leaving the way this one arrives there (so the joint is smooth); pick the next
	-- point. Build builds every section at once.
	local canContinue = function() : boolean
		return ready and proposal ~= nil and gen ~= nil and gen.pieces ~= nil and #gen.pieces > 0 and plan == nil
	end
	-- Shift+M: back to the previous section to edit it (its setup is restored; its end is pinned to
	-- the way the next section leaves, so the joint stays smooth). M on a section with more after it:
	-- forward to the next one (its start takes this one's arrival direction again).
	local chainBusy = function() : boolean return ready or #verdict.chain > 0 or #verdict.after > 0 end
	-- (the step as a function on verdict: M / Shift+M call it, and the panel's Sections table steps
	-- through it to a clicked section)
	verdict.stepChain = function(backward : boolean)
		-- this section's setup, to come back to it
		local snap : {string : any} = { a = a, b = b, mode = mode, conn = connState:old(), loop = loopState:old(),
			curve = curveState:old(), wps = waypointsState:old() or {}, angles = anglesState:old() or { 0, 0 } }
		local function restore(s : {string : any})
			firstState:set(s.a as Pick)
			secondState:set(s.b as Pick)
			connState:set(s.conn as ConnState)
			loopState:set(s.loop as LoopState)
			curveState:set(s.curve as {number})
			waypointsState:set((s.wps or {}) as {P3})
			anglesState:set((s.angles or { 0, 0 }) as {number})
			g_mode = s.mode as integer
			selectedState:set(1)
			addModeState:set(false)
			costState:set(0)
			errorState:set("")
			refusedState:set("")
		end
		-- a pick with a fixed direction (a copy: picks are shared with the saved setups)
		local function withDir(p : Pick, dx : number, dy : number) : Pick
			return { kind = p.kind, node = p.node, edge = p.edge, t = p.t, pos = p.pos, dir = { dx, dy } }
		end

		if backward then
			-- back
			if #verdict.chain == 0 then return end
			table.insert(verdict.after, 1, { proposal = proposal, snap = snap })
			table.remove(verdict.chain)
			local prev = table.remove(verdict.chainSnaps) or {}
			-- its end leaves (into its own route) opposite to the way this section starts
			local d = a and a.dir
			if d and prev.b then
				prev.b = withDir(prev.b as Pick, -d[1], -d[2])
				local an = (prev.angles or { 0, 0 }) as {number}
				prev.angles = { an[1], 0 }
			end
			restore(prev)
			shared.debug("[network_tools] Connect: back to section " .. tostring(#verdict.chain + 1))
			return
		end

		if not canContinue() then return end
		-- the way the road arrives at the second point (the pieces run from the first point)
		local last = gen.pieces[#gen.pieces]
		local dx, dy, len = norm2(last.t1.x, last.t1.y)
		if len < 1e-6 then return end
		verdict.chain[#verdict.chain + 1] = proposal
		verdict.chainSnaps[#verdict.chainSnaps + 1] = snap
		if #verdict.after > 0 then
			-- forward to the next section: it starts the way this one now arrives
			local nxt = table.remove(verdict.after, 1)
			local s = nxt.snap as {string : any}
			if s.a then s.a = withDir(s.a as Pick, dx, dy) end
			restore(s)
			shared.debug("[network_tools] Connect: on to section " .. tostring(#verdict.chain + 1))
			return
		end
		local P = pickPos(b)
		local nextStart : Pick
		if b.kind == "node" then
			nextStart = { kind = "node", node = b.node, edge = b.edge, dir = { dx, dy } }
		else
			-- (a split point: the first section makes its node; the next section's start, on the same
			-- spot, becomes that node when the sections are merged)
			nextStart = { kind = "free", pos = p3(P.x, P.y, P.z), dir = { dx, dy } }
		end
		shared.debug("[network_tools] Connect: section " .. tostring(#verdict.chain) .. " kept, continuing from its end")
		firstState:set(nextStart)
		secondState:set(nil)
		clearShape()
		waypointsState:set({})
		anglesState:set({ 0, 0 })
		selectedState:set(1)
		addModeState:set(false)
	end
	-- (listed whenever there is something to do: a pair to continue from, or sections to go back to)
	safeUseInputAction("constructOpt1", shortcutHandler(function() verdict.stepChain(precise()) end, chainBusy,
		(#verdict.after > 0 and _("Next section (Shift: previous)"))
		or (canContinue() and (#verdict.chain > 0 and _("Continue (Shift: previous section)") or _("Continue from end 2")))
		or (#verdict.chain > 0 and _("Shift: previous section") or _("Continue (section not ready)"))))
	-- the panel's Sections table: a section clicked - one step a render towards it (each step's state
	-- changes take effect on the next render). Only through sections that exist; a step that can't
	-- go (the section not ready) ends it.
	do
		local tgt = verdict.chainTarget
		if tgt then
			local cur = #verdict.chain + 1
			if tgt < cur then
				verdict.stepChain(true)
			elseif tgt > cur and #verdict.after > 0 and canContinue() then
				verdict.stepChain(false)
			else
				verdict.chainTarget = nil
			end
		end
	end
	-- N: move ends mode on / off (the start / end point drags even under a circle)
	safeUseInputAction("constructOpt2", shortcutHandler(function() addModeState:set(not addMode) end, hasPair,
		addMode and _("Move ends: on") or _("Move ends: off")))
	-- probe mode (debug) - the game's street builder instead, its proposals logged. On construct
	-- option 3, which has no key by default (M is Continue): bind one in the game's key settings to use it
	safeUseInputAction("constructOpt3", shortcutHandler(function()
		if g_probe.on then
			g_probe.on = false
			print("[network_tools] PROBE off")
		else
			local name = probeName(g_networkId)
			if name then
				g_probe.on, g_probe.name, g_probe.last = true, name, ""
				print("[network_tools] PROBE on: drag a road with the game's builder (" .. name .. ")")
			else
				print("[network_tools] PROBE not started: pick a road type in the panel (network " .. tostring(g_networkId) .. " has no street template name)")
			end
		end
		addModeState:set(addMode)   -- (re-render)
		costState:set(-1)
	end, function() : boolean return true end, g_probe.on and _("Probe: on") or _("Probe: off")))
	safeUseInputAction("constructNoSnap", shortcutHandler(function() g_snap = not snap; syncCheckbox(SNAP_PARAM, g_snap) end, hasRadius,
		snap and _("Snapping: on") or _("Snapping: off")))

	------------------------------------------------------------------------------------------------
	-- Toolbar (construction toolbar, like MoveIt)

	local function addCircleFromToolbar()
		if mode ~= MODE_CONNECTION or not gen or not gen.straights or #gen.straights == 0 then return end
		-- split the straight after the selected circle (or before it for the last circle)
		local k = math.min(selectedClamped, #gen.straights)
		local s = gen.straights[k]
		local dx, dy, len = norm2(s.x1 - s.x0, s.y1 - s.y0)
		if len < 1 then return end
		local r = DEFAULT_RADIUS / 2
		-- centre one radius to the left of the straight's midpoint: the new circle just touches the
		-- current line, so the path changes as little as possible until you drag it
		local mx, my = (s.x0 + s.x1) / 2 - dy * r, (s.y0 + s.y1) / 2 + dx * r
		connState:set(connMode.insertCircle(currentConnState(), k, s, mx, my))
		selectedState:set(k + 1)
	end

	handlersRef:set({
		ntoolsRadiusDown = function() if hasRadius() then changeRadius(-1) end end,
		ntoolsRadiusUp = function() if hasRadius() then changeRadius(1) end end,
		ntoolsPrev = function() if hasPair() then selectStep(-1) end end,
		ntoolsNext = function() if hasPair() then selectStep(1) end end,
		ntoolsAngleDown = function() if hasAngles() then changeAngle(-1) end end,
		ntoolsAngleUp = function() if hasAngles() then changeAngle(1) end end,
		ntoolsAddCircle = addCircleFromToolbar,
		ntoolsRemoveCircle = function()
			if mode == MODE_CONNECTION and ready and ax and bx then
				connState:set(connMode.removeCircle(currentConnState(), selectedClamped))
				selectedState:set(math.max(1, selectedClamped - 1))
			end
		end,
		ntoolsFlip = function()
			if mode == MODE_CONNECTION and ready and ax and bx then
				connState:set(connMode.flipCircle(currentConnState(), selectedClamped))
			end
		end,
		ntoolsResetShape = function()
			connState:set(nil)
			loopState:set(nil)
			curveState:set(nil)
			waypointsState:set({})
			anglesState:set({ 0, 0 })
			selectedState:set(1)
		end,
		ntoolsBuild = build,
	})

	-- publish what the toolbar needs; refresh it only when something changed
	-- carrier for the bridge / tunnel pickers
	local isTrack = false
	if templateEdge then
		local e = getEdge(templateEdge)
		isTrack = e ~= nil and e.roadType == api.type["enum"].RoadType.TRACK
	elseif templateById(g_networkId) then
		isTrack = templateById(g_networkId).roadType == api.type["enum"].RoadType.TRACK
	end
	if isTrack ~= g_isTrack then
		g_isTrack = isTrack
		refreshToolbar()
	end
	local ui : UiState = {
		ready = ready,
		mode = mode,
		hasEnd = ready and mode ~= MODE_STRAIGHT and selectedEnd() ~= nil,
		isMiddle = ready and mode == MODE_CONNECTION and selectedClamped > 1 and selectedClamped < selectableCount(),
		canBuild = (proposal ~= nil or verdict.chainMerged ~= nil) and not blocked,
	}
	if ui.ready ~= g_ui.ready or ui.mode ~= g_ui.mode or ui.hasEnd ~= g_ui.hasEnd
			or ui.isMiddle ~= g_ui.isMiddle or ui.canBuild ~= g_ui.canBuild then
		-- update in place: the other tools were handed this table (host.ui) and write canBuild into
		-- it - replacing it left their Build button disabled after Connect had been used
		g_ui.ready, g_ui.mode, g_ui.hasEnd, g_ui.isMiddle, g_ui.canBuild = ui.ready, ui.mode, ui.hasEnd, ui.isMiddle, ui.canBuild
		refreshToolbar()
	end

	------------------------------------------------------------------------------------------------
	-- Game controller (shared/ntools_pad). The crosshair is the mouse: the terrain position under it
	-- is what onMouse reads. A confirm is a click there - the first grabs a handle (or picks the
	-- road / bare ground under the crosshair, as a click does), the next puts the handle down;
	-- in between the handle follows the crosshair each step. Circle puts a held handle down, else
	-- leaves the tool; the option bar (Mode, sliders, Reset / Build) is on Triangle.
	do
		local padMod = require "network_tools_1::/gui/construction/tools/shared/ntools_pad.script.tl" as {string : any}
		local T = api.gui.mouse.Event.Type
		local function fake(t : any) : Gui.Mouse.Event return ({ type = t, button = 0 } as any) as Gui.Mouse.Event end
		pad.confirm = function(source : string)
			if not (padMod.debounced as function(any) : boolean)(pad) then return end
			shared.debug("[network_tools] Connect: pad confirm (" .. source .. ", dragging " .. tostring(draggingRef:get()) .. ")")
			if draggingRef:get() ~= 0 then
				onMouse(fake(T.Released))
				setDragging(0)
				return
			end
			-- RB held (the pad's Shift): first as Shift+double-click - a waypoint / circle added where
			-- the crosshair isn't on a handle (a pad has no double-click); on a handle the press below
			-- goes on as Shift+click (a waypoint removed)
			if precise() and onMouse(fake(T.DoubleClicked)) then return end
			if onMouse(fake(T.Pressed)) then return end
			local h = hoverRef:get() or -1
			if h >= 0 then onSelect(h) end
		end
		pad.onStep = function()
			if draggingRef:get() ~= 0 then onMouse(fake(T.Moved)) end
		end
		local holding = draggingRef:get() ~= 0
		local confirmText = holding and _("Put down") or ((a and b) and _("Grab handle") or _("Place point"))
		;(padMod.actions as function(any, string, function(), string))(pad, confirmText, function()
			if draggingRef:get() ~= 0 then setDragging(0) else leave(params) end
		end, holding and _("Put down") or _("Leave the tool"))
	end

	local actionFn = function() : TreeNodeId
		-- (controller: the world layer is up while this is mounted - shared/ntools_pad)
		;((require "network_tools_1::/gui/construction/tools/shared/ntools_pad.script.tl" as {string : any}).trackLayer as function(any))(pad)
		local gamepad = (pad.gamepad as ReactStateT<boolean>):old() == true
		-- a node being made for an end along a road (pre, above): no Selector, preview or highlight
		-- while the game replaces that segment, as the Add node tool while it builds. The tooltip is
		-- the one that comes next anyway (no "making a node" step to see): those few frames only delay
		-- the preview
		if pre.busy then
			hoverRef:set(-1)
			local job = pre.job as {string : any}
			local firstEnd = job ~= nil and job.st == firstState
			return builtin.ActionDescriptor{
				tool = "construction-menu-perks",
				parent = selfRef,
				onBack = function() leave(params) end,
				crosshair = gamepad,
				terrainCirclePolicy = gamepad and "FocusSelection" or "Never",
				children = { (firstEnd and b == nil)
					and tooltip(_("Click the second point: a node, a point along a road, or bare ground"), false, false)
					or tooltip(_("Press Build to build"), true, false) },
			}
		end
		local children : {TreeNodeId} = {
			builtin.Selector{
				onSelect = function(entity : Engine.Entity, __ : {integer}, __ : Gui.SelectionDetails) : boolean
					-- (a pad's confirm arrives here too: one route, debounced)
					if gamepad then
						if pad.confirm then (pad.confirm as function(string))("selector") end
						return true
					end
					if draggingRef:get() ~= 0 then
						return true
					end
					return onSelect(entity)
				end,
				onHover = function(entity : Engine.Entity, __ : {integer}, __ : Gui.SelectionDetails)
					hoverRef:set((entity and isEdge(entity)) and entity or -1)
				end,
				onProcessMouseEvent = onMouse,
				filter = function(e : Engine.Entity) : boolean return (isEdge(e)) end,
			},
		}

		if proposal and not g_livePreview then
			-- live preview off: no game preview; the schematic lines (makeOverlay) show the plan
			labels.set({})
			gen.schematic = {}
			-- one curved strip per piece (its own Hermite curve) at the road's own height: the overlay
			-- ignores depth, so it shows through hills (a tunnel as it runs underground) - no lift, which
			-- only shifted it on screen and left steps between strips
			for _, pc in ipairs(gen.pieces or {}) do
				gen.schematic[#gen.schematic + 1] = { x0 = pc.p0.x, y0 = pc.p0.y, z0 = pc.p0.z,
					x1 = pc.p1.x, y1 = pc.p1.y, z1 = pc.p1.z, kind = g_bridges and classifyPiece(pc) or "normal", pc = pc }
			end
			-- the cost all the same: the game prices the proposal without showing it (verdict.of),
			-- asked again only when the shape or the options change
			local costKey = pickKey(a) .. "," .. pickKey(b) .. "," .. tostring(g_replace) .. "," .. tostring(mode)
				.. "," .. tostring(bridges) .. "," .. tostring(g_networkId) .. "," .. tostring(_sharedPoll)
				.. "," .. tostring(#verdict.chain)
			for _, piece in ipairs(gen.pieces) do
				costKey = costKey .. "," .. round(piece.p1.x) .. "," .. round(piece.p1.y) .. "," .. round(piece.p1.z)
			end
			if costKey ~= verdict.offCostKey then
				verdict.offCostKey = costKey
				local pd = verdict.of(verdict.chainMerged or proposal)
				costState:set(pd and pd.costs or 0)
			end
		elseif proposal then
			local id = "ntools_connect," .. pickKey(a) .. "," .. pickKey(b) .. "," .. tostring(g_replace) .. "," .. tostring(mode) .. "," .. tostring(bridges) .. "," .. tostring(g_bridgeType) .. "," .. tostring(g_tunnelType) .. "," .. tostring(g_rcType) .. "," .. tostring(g_networkId)
				.. "," .. tostring(_sharedPoll)   -- the panel's new-road options: a change makes the preview again
			for _, piece in ipairs(gen.pieces) do
				id = id .. "," .. round(piece.p1.x) .. "," .. round(piece.p1.y) .. "," .. round(piece.p1.z)
					.. "," .. round(piece.t0.x) .. "," .. round(piece.t0.y)
			end
			-- (a new preview once the houses to demolish are known)
			id = id .. ",d" .. tostring(#verdict.demolition.houses)
			-- Twin on: the preview also shows the twin's segments where it will run (it is built after
			-- the connection, joined to the network then; here it joins nothing). What blocks Build is
			-- still the connection's own verdict.
			-- (a proposal that removes segments: its new road alone - verdict.viewOf)
			local viewProposal = verdict.viewOf[proposal] or proposal
			local trimmed = viewProposal ~= proposal
			gen.twinPreviewed, gen.twinProposal = false, nil
			-- a chain: every section, as it will be built (no twin with a chain)
			if verdict.chainMerged then
				viewProposal = verdict.chainView or verdict.chainMerged
				trimmed = verdict.chainView ~= nil
				id = id .. ",c" .. tostring(#verdict.chain) .. "," .. tostring(#verdict.after)
			end
			-- (not when both ends are existing nodes: the real twin is built afterwards and joins the
			-- network there, and the preview twin's loose ends beside those nodes crashed the engine -
			-- "!candidates.empty()" in GetNodeStreetGroundTextures; the outline shows it instead)
			local twinJoins = a ~= nil and b ~= nil and a.kind == "node" and b.kind == "node"
			if g_twin.side ~= 0 and g_twin.preview and not verdict.chainMerged and not twinJoins then
				local okT, errT = pcall(function()
					-- the spacing from the picked segment's type, else (both ends on open ground) from the
					-- new connection's own first segment
					local e = templateEdge and getEdge(templateEdge)
					if not e then
						local first = (proposal.streetProposal.edgesToAdd or {})[1]
						e = first and first.comp or nil
					end
					if not e then error("no segment to take the spacing from") end
					local track = e.roadType == api.type["enum"].RoadType.TRACK
					local offset = laneWidth(e.laneConfigs)
					if track then
						local tpl = templateByName(e.roadTemplate)
						offset = (tpl and tpl.trackDistance and tpl.trackDistance > 0) and tpl.trackDistance or 5
					end
					-- (built from the new road alone when the full proposal removes segments; the build
					-- below takes the full one's twin - gen.twinProposal)
					local vp = g_twin.preview(viewProposal, offset * g_twin.side, not track)
					if vp then viewProposal, gen.twinPreviewed = vp, true end
					if trimmed then
						local okF, full = pcall(g_twin.preview, proposal, offset * g_twin.side, not track)
						gen.twinProposal = okF and full or nil
					else
						gen.twinProposal = vp
					end
				end)
				id = id .. ",t" .. tostring(g_twin.side)
				-- (logged when it changes)
				local tl = "twin preview: " .. (okT and (gen.twinPreviewed and ("shown, " .. tostring(#(viewProposal.streetProposal.edgesToAdd or {}))
					.. " segments") or "not made") or tostring(errT))
				if tl ~= terrain.lastTwinLog then
					terrain.lastTwinLog = tl
					shared.debug("[network_tools] Connect " .. tl)
				end
			end
			local onData = function(proposalData : ProposalData)
					if aliveRef:hasExpired() then
						return
					end
					costState:set(proposalData.costs)
					local msg = ""
					for __, m in ipairs(proposalData.errorState.messages) do
						msg = msg .. m .. " "
					end
					-- (a refusal without a message: say so, and what was previewed)
					if ((proposalData.errorState as any) as {string : any}).critical == true then
						msg = msg .. string.format("[critical, %d edges, %d nodes] ", #(viewProposal.streetProposal.edgesToAdd or {}),
							#(viewProposal.streetProposal.nodesToAdd or {}))
					end
					-- with the twin shown, the errors are the connection's alone (the twin's preview joins
					-- nothing, so its ends may touch the network where the real twin joins it); with the
					-- new road shown alone (trimmed), the full proposal's - the preview's own would be its
					-- collisions with the road it splits, still there in it
					if gen.twinPreviewed or trimmed then
						local own = verdict.of(verdict.chainMerged or proposal)
						if own then
							proposalData = own
							-- (the full build's cost: the split road's re-added parts, the removals' refund)
							if trimmed then costState:set(own.costs) end
						end
					end
					-- log the game's reason when it changes (the preview only shows red)
					-- only what really blocks counts: collisions with the replaced road / demolished
					-- houses don't
					local reason = verdict.blockReason(proposalData, verdict.chainMerged or proposal) or ""
					-- a chain refused outright (no message of its own) while this section alone isn't: the
					-- way they're joined - a branch whose road runs back over its junction or along the
					-- road it leaves. Say so (the game only says "Construction Not Possible")
					if verdict.chainMerged and ((proposalData.errorState as any) as {string : any}).critical == true then
						local own = verdict.of(proposal)
						if own and ((own.errorState as any) as {string : any}).critical ~= true then
							reason = _("These sections can't be joined like this: a branch must leave the road clear - put its far end out to the side, not ahead along the road it leaves")
						end
					end
					if msg ~= verdict.lastPreviewMsg then
						verdict.lastPreviewMsg = msg
						if msg ~= "" then
							shared.debug("[network_tools] Connect preview error: " .. msg .. (reason == "" and "(expected - not blocking)" or ""))
						end
					end
					-- collisions (red without a message): what it hits, and our segments' heights / types.
					-- Only when the set of colliding entities changes: naming them walks every component
					-- type and the whole map's water meshes - every preview update, that dropped frames.
					pcall(function()
						local ids : {string} = {}
						for _, cd in ipairs(proposalData.collisionInfo.collisionEntities or {}) do ids[#ids + 1] = tostring(cd.entity) end
						local idKey = table.concat(ids, ",")
						if idKey == g_lastCollisionIds then return end
						g_lastCollisionIds = idKey
						local hits : {string} = {}
						for _, cd in ipairs(proposalData.collisionInfo.collisionEntities or {}) do
							local e = cd.entity
							local kind = "?"
							if e and e >= 0 and api.engine.entityExists(e) then
								if api.engine.getComponent(e, api.type.ComponentType.BASE_EDGE) then
									-- removed by the proposal (split / replaced), or a neighbour of an end?
									kind = "edge"
									for _, r in ipairs(proposal.streetProposal.edgesToRemove or {}) do
										if r == e then kind = "edge(removed)" end
									end
									local ce = getEdge(e)
									if ce then
										kind = kind .. string.format("[n%d-n%d]", ce.node0, ce.node1)
									end
								elseif api.engine.getComponent(e, api.type.ComponentType.BASE_NODE) then kind = "node"
								elseif api.engine.getComponent(e, api.type.ComponentType.TERRAIN) then kind = "terrain"
								else
									-- name every component it has
									local names : {string} = {}
									for name, ct in pairs(api.type.ComponentType as {string : any}) do
										local okC, comp = pcall(function() : any return api.engine.getComponent(e, ct) end)
										if okC and comp ~= nil then names[#names + 1] = name end
									end
									table.sort(names)
									-- water meshes have no listed component: ask the river system
									pcall(function()
										local all = api.engine.system.riverSystem.getWaterMeshEntities(api.type.Vec2i.new(-10000, -10000), api.type.Vec2i.new(10000, 10000))
										for _, w in ipairs(all or {}) do
											if w == e then names[#names + 1] = "WATER_MESH" end
										end
									end)
									kind = "other[" .. table.concat(names, "+") .. "]"
								end
							elseif e and e < 0 then kind = "new"
							end
							hits[#hits + 1] = tostring(e) .. ":" .. kind
						end
						if #hits == 0 then return end
						local segs : {string} = {}
						for _, s in ipairs(proposal.streetProposal.edgesToAdd or {}) do
							local c = s.comp
							local gm = terrainHeight((c.position0.x + c.position1.x) / 2, (c.position0.y + c.position1.y) / 2) or 0
							segs[#segs + 1] = string.format("%d:%s z %.1f->%.1f ground-mid %.1f", s.entity,
								c.type == api.type["enum"].BaseEdgeType.BRIDGE and "BRIDGE" or (c.type == api.type["enum"].BaseEdgeType.TUNNEL and "TUNNEL" or "normal"),
								c.position0.z, c.position1.z, gm)
						end
						-- the two ends (an existing node / a split segment / bare ground)
						local function endText(p : Pick) : string
							if not p then return "-" end
							if p.kind == "node" then return "node n" .. tostring(p.node) end
							if p.kind == "split" then return string.format("split e%d t=%.2f", p.edge, p.t) end
							return "ground"
						end
						local line = "collides with " .. table.concat(hits, ", ") .. "\n    ends: " .. endText(a) .. " / " .. endText(b)
							.. "\n    " .. table.concat(segs, "\n    ")
						if line ~= terrain.lastDiag then
							terrain.lastDiag = line
							shared.debug("[network_tools] Connect preview " .. line)
						end
					end)
					errorState:set(reason)
				end
			-- the new road shown alone (trimmed - makeProposal) in the game's 3D preview, as the Overpass
			-- Builder does; the cost and errors are the full build's (onData asks the game for them)
			children[#children + 1] = preview.viewer{
				proposal = viewProposal,
				anarchy = anarchy,
				onData = onData,
				id = id,
			}
		elseif verdict.chainMerged then
			-- a chain whose next section has no second point yet: the sections kept so far (their new
			-- roads alone where they remove segments - verdict.viewOf; the cost and errors are the full
			-- chain's)
			children[#children + 1] = preview.viewer{
				proposal = verdict.chainView or verdict.chainMerged,
				anarchy = anarchy,
				onData = function(proposalData : ProposalData)
					if aliveRef:hasExpired() then return end
					if verdict.chainView then
						local own = verdict.of(verdict.chainMerged)
						if own then proposalData = own end
					end
					costState:set(proposalData.costs)
					errorState:set(verdict.blockReason(proposalData, verdict.chainMerged) or "")
				end,
				id = "ntools_connect_chain," .. tostring(#verdict.chain) .. "," .. tostring(#verdict.after) .. "," .. tostring(_sharedPoll),
			}
		end
		-- speed / gradient tags on the preview's new segments (the preview publishes them); the end
		-- angles and circle radii are this tool's own
		labels.set({}, (gen and ready) and connectTags(a, b, gen) or {})
		local tags = labels.node()
		if tags then children[#children + 1] = tags end

		-- ground points get a draggable handle; nodes / split points a ring
		local function markEnds(g : GenResult)
			g.endRings, g.pointHandles = {}, {}
			-- the other sections' loose ends (connect/extra chainSnapRings)
			g.snapRings, g.snapHot = {}, {}
			if #verdict.chain + #verdict.after > 0 then
				local exS = require "network_tools_1::/gui/construction/tools/connect/extra/ntools_connect_extra.script.tl" as {string : any}
				-- (function casts in locals of their own: a cast's return list would swallow the arguments after it)
				local ringsFn = exS.chainSnapRings as function({string : any}, function(any) : (P3), any, any, integer) : ({Circle2}, {Circle2})
				local posFn = pickPos as function(any) : P3
				local okR, rings, hot = pcall(ringsFn, verdict as {string : any}, posFn, a, b, (draggingState:old() or 0) - DRAG_POINT)
				if okR then g.snapRings, g.snapHot = rings or {}, hot or {} end
			end
			for i, p in ipairs({ a, b }) do
				local P = pickPos(p)
				if P then
					if p.kind == "free" then
						g.pointHandles[i] = P
					else
						g.endRings[#g.endRings + 1] = { x = P.x, y = P.y, r = 6 }
					end
				end
			end
			for i, w in ipairs(wpHandles and wps or {}) do
				g.pointHandles[2 + i] = w
			end
		end

		if not (gen and ready) and A then
			-- only the first point so far: mark it (and its handle on bare ground)
			local lone : GenResult = {}
			markEnds(lone)
			local overlay = makeOverlay(lone, A.z, draggingState:old(), false, 0)
			if overlay then children[#children + 1] = overlay end
		end

		if gen and ready then
			-- show which node and which direction each end uses
			markEnds(gen)
			-- N toggles between the circles (off) and the two ends (move ends mode); without circles
			-- (Straight / Curve) the ends always show
			-- (circles, not handles: Curve's handles are its ends' and waypoints' bend controls, and
			-- its ends stay shown)
			local hasCircles = #(gen.circles or {}) > 0
			gen.hideCircles = addMode
			gen.hideEnds = hasCircles and not addMode
			gen.endLines = {}
			-- a solid arrow flat on the ground, as the game's curve builder's "Set Direction" arrow:
			-- a 2.5 m shaft from 6 m out to 32 m, then a 6.5 m wide head narrowing to the tip at 42 m.
			-- An overlay strip has one width, so the head is filled with slices across it - their
			-- corners showed as teeth along its sides, at any number of slices - and a thin strip along
			-- each side covers the teeth, leaving a straight edge
			local function arrow(P : P3, dx : number, dy : number)
				if not dx then return end
				-- s along the arrow, n across it (left +)
				local function piece(s0 : number, n0 : number, s1 : number, n1 : number, w : number)
					gen.endLines[#gen.endLines + 1] = { x0 = P.x + dx * s0 - dy * n0, y0 = P.y + dy * s0 + dx * n0,
						x1 = P.x + dx * s1 - dy * n1, y1 = P.y + dy * s1 + dx * n1, w = w }
				end
				piece(6, 0, 32, 0, 2.5)
				for k = 0, 23 do
					piece(32 + k * 10 / 24, 0, 32 + (k + 1) * 10 / 24, 0, 6.5 * (1 - (k + 0.5) / 24))
				end
				piece(32, 3.25, 42, 0, 0.3)
				piece(32, -3.25, 42, 0, 0.3)
			end
			arrow(A, ax, ay)
			arrow(B, bx, by)
			-- the twin's outline: the planned connection moved sideways by the twin's spacing (the same
			-- spacing the build uses: track spacing, or the road's own width)
			gen.twinLines = {}
			if g_twin.side ~= 0 and gen.pieces and not gen.twinPreviewed then
				pcall(function()
					local e = templateEdge and getEdge(templateEdge)
					if not e and proposal then
						local first = (proposal.streetProposal.edgesToAdd or {})[1]
						e = first and first.comp or nil
					end
					if not e then return end
					local offset = laneWidth(e.laneConfigs)
					if e.roadType == api.type["enum"].RoadType.TRACK then
						local tpl = templateByName(e.roadTemplate)
						offset = (tpl and tpl.trackDistance and tpl.trackDistance > 0) and tpl.trackDistance or 5
					end
					local d = offset * g_twin.side
					gen.twinLines = {}
					for _, pc in ipairs(gen.pieces) do
						local px, py : number, number = nil, nil
						for s = 0, 8 do
							local t = s / 8
							local t2, t3 = t * t, t * t * t
							local h00, h10, h01, h11 = 2 * t3 - 3 * t2 + 1, t3 - 2 * t2 + t, -2 * t3 + 3 * t2, t3 - t2
							local d00, d10, d01, d11 = 6 * t2 - 6 * t, 3 * t2 - 4 * t + 1, -6 * t2 + 6 * t, 3 * t2 - 2 * t
							local x = h00 * pc.p0.x + h10 * pc.t0.x + h01 * pc.p1.x + h11 * pc.t1.x
							local y = h00 * pc.p0.y + h10 * pc.t0.y + h01 * pc.p1.y + h11 * pc.t1.y
							local tx = d00 * pc.p0.x + d10 * pc.t0.x + d01 * pc.p1.x + d11 * pc.t1.x
							local ty = d00 * pc.p0.y + d10 * pc.t0.y + d01 * pc.p1.y + d11 * pc.t1.y
							local tl = math.sqrt(tx * tx + ty * ty)
							if tl > 1e-6 then
								-- left of the direction of travel (A -> B) = positive
								local qx, qy = x - ty / tl * d, y + tx / tl * d
								if px then gen.twinLines[#gen.twinLines + 1] = { x0 = px, y0 = py, x1 = qx, y1 = qy } end
								px, py = qx, qy
							end
						end
					end
				end)
			end
			local overlay = makeOverlay(gen, (A.z + B.z) / 2, draggingState:old(), gen.error ~= nil or not proposal,
				mode == MODE_CONNECTION and selectedClamped or 0)
			if overlay then
				children[#children + 1] = overlay
			end
		end

		-- status line + measurements (CS1 shows these as labels in the world) + key hints
		local function details() : string
			local lines : {string} = {}
			if gen and gen.info then
				lines[#lines + 1] = gen.info
			end
			-- the selection on one line: what is selected, its height, the end angles
			local sel : {string} = {}
			local angleText = _("Angles") .. " " .. tostring(angles[1]) .. "° / " .. tostring(angles[2]) .. "°"
			if mode == MODE_CONNECTION then
				sel[#sel + 1] = _("Circle") .. " " .. tostring(selectedClamped) .. "/" .. tostring(selectableCount())
			elseif mode ~= MODE_STRAIGHT then
				sel[#sel + 1] = _("End") .. " " .. tostring(selectedClamped)
			end
			if pointLabel and mode ~= MODE_CONNECTION then
				sel[#sel + 1] = _("Waypoint") .. " " .. tostring(selectedWp) .. "/" .. tostring(#wps)
			end
			if pointLabel then sel[#sel + 1] = string.format("%+d m", math.floor(pointLift + 0.5)) end
			if mode ~= MODE_STRAIGHT then sel[#sel + 1] = angleText end
			if #sel > 0 then lines[#lines + 1] = table.concat(sel, "   ") end
			-- (the keys as the player has them bound, not the defaults)
			local keyOf = (shared as {string : any}).keyName as function(string, string) : string
			local kM = keyOf and keyOf("constructOpt1", "M") or "M"
			-- move ends mode is a state to see; the mouse controls only while Shift is held
			if addMode then
				lines[#lines + 1] = string.format(_("MOVE ENDS ON: drag the start / end point, onto a road to join it (%s: off)"),
					keyOf and keyOf("constructOpt2", "N") or "N")
			end
			-- chained sections: how many are kept, and whether they still fit together
			if #verdict.chain > 0 or #verdict.after > 0 then
				local kBack = keyOf and keyOf("constructOptPrecise1", "Shift+" .. kM) or ("Shift+" .. kM)
				lines[#lines + 1] = string.format("%s: %s %d / %d   %s", _("Chain"), _("section"), #verdict.chain + 1,
					#verdict.chain + 1 + #verdict.after, string.format(_("(%s: next / continue, %s: previous, Build builds all)"), kM, kBack))
				if verdict.chainWhy then lines[#lines + 1] = _("Sections can't be combined") .. ": " .. verdict.chainWhy end
			end
			if precise() then
				if mode == MODE_CONNECTION then
					lines[#lines + 1] = _("Drag centre: move   Drag rim: radius   Double-click centre: flip")
					lines[#lines + 1] = _("Shift+click centre: remove   Shift+double-click: add a circle")
				elseif mode == MODE_STRAIGHT or mode == MODE_CURVE then
					lines[#lines + 1] = _("Drag a point: move it   Shift+click a waypoint: remove   Shift+double-click: add one")
				end
			end
			return table.concat(lines, "\n")
		end

		if a == nil then
			children[#children + 1] = tooltip(g_replace
				and _("Replace: click the first point on the road to rebuild (near a node: that node; along a segment: a point there). Shift+click a road: its whole stretch")
				or _("Click where to start: near a node (that node), along a road (it is split there) or bare ground"), false, false)
		elseif b == nil then
			children[#children + 1] = tooltip(g_replace
				and _("Replace: click the second point - the road between the two is rebuilt")
				or _("Click the second point: a node, a point along a road, or bare ground"), false, false)
		elseif gen and gen.error then
			children[#children + 1] = tooltip(gen.error .. "\n" .. details(), false, true)
		elseif not proposal then
			children[#children + 1] = tooltip(_("These nodes cannot be connected this way") .. "\n" .. details(), false, true)
		elseif not livePreview and refusedState:old() ~= "" then
			children[#children + 1] = tooltip(refusedState:old() .. "\n" .. details(), false, true)
		elseif not livePreview then
			children[#children + 1] = tooltip(_("Schematic preview (Live preview off) - press Build to build") .. "\n" .. details(), true, false)
		elseif blocked then
			children[#children + 1] = tooltip(errorState:old() .. "\n" .. details(), false, true, costState:old())
		elseif errorState:old() ~= "" then
			children[#children + 1] = tooltip(_("Anarchy: building anyway, ignoring") .. " " .. errorState:old() .. "\n" .. details(), false, false, costState:old())
		elseif mode == MODE_CONNECTION then
			children[#children + 1] = tooltip(_("Drag a circle centre to move it, its ring to resize. Press Build to build") .. "\n" .. details(), true, false, costState:old())
		elseif mode == MODE_LOOP then
			children[#children + 1] = tooltip(_("Drag the centre to resize, or past the crossing to switch corner/loop. Press Build to build") .. "\n" .. details(), true, false, costState:old())
		elseif mode == dubins.MODE then
			children[#children + 1] = tooltip(_("Shortest path with no curve tighter than the radius. Drag a ring (or use the radius keys) to change it. Press Build to build") .. "\n" .. details(), true, false, costState:old())
		else
			children[#children + 1] = tooltip(_("Press Build to build") .. "\n" .. details(), true, false, costState:old())
		end

		local highlighted : {Engine.Entity} = {}
		if a and a.edge then highlighted[#highlighted + 1] = a.edge end
		if b and b.edge then highlighted[#highlighted + 1] = b.edge end
		-- the road that Replace removes
		for _, s in ipairs(plan and plan.edges or {}) do highlighted[#highlighted + 1] = s end
		-- underground view (panel option, all tools)
		local under = shared.layerNode()
		if under then children[#children + 1] = under end
		-- Anarchy preview strips no overlay drew this frame
		local lo = preview.leftover()
		if lo then children[#children + 1] = lo end

		return builtin.ActionDescriptor{
			tool = "construction-menu-perks",
			parent = selfRef,
			onBack = function() leave(params) end,
			highlightedEntities = highlighted,
			-- (controller: the crosshair and the focus circle, as the game's own tools)
			crosshair = gamepad,
			terrainCirclePolicy = gamepad and "FocusSelection" or "Never",
			children = children,
		}
	end

	if g_probe.on and g_probe.name ~= "" then
		params.setActionFn(function() : TreeNodeId return probeAction(g_networkId) end, "NtoolsConnectProbe")
		return
	end
	params.setActionFn(actionFn, "NtoolsConnectAction" .. tostring(params.definition))
	-- controller: the focus anchor, so the pad's input actions reach this recipe (shared/ntools_pad)
	if (pad.gamepad as ReactStateT<boolean>):old() and pad.live then
		local padMod = require "network_tools_1::/gui/construction/tools/shared/ntools_pad.script.tl" as {string : any}
		return builtin.BoxLayout{ children = {
			(padMod.PadFocus as function(any, any) : TreeNodeId)(react.ref(pad.node), { meta = { forceFocusable = true } }),
		} }
	end
end)

----------------------------------------------------------------------------------------------------
-- Toolbar params (rendered by the game's construction toolbar, pattern from the MoveIt mod).
-- Buttons fire react events handled in the recipe; checkboxes set module globals.

-- Lists the types available this year for the carrier being built; bridges and tunnels start
-- with a "none" entry. Returns the list and the index of the default (first auto-selectable) type.
local function makePicker(rep : ResTypeRep<integer, table>, objectType : MenuCategoryUtil.ObjectType) : function() : {MenuCategoryUtil.FilterObject}, integer
	return function() : {MenuCategoryUtil.FilterObject}, integer
		local objects : {MenuCategoryUtil.FilterObject} = {}
		local withNone = objectType ~= "RailroadCrossing"
		if withNone then
			objects[1] = menu_category_util.createNoObject(objectType)
		end
		local carrier = g_isTrack and api.type["enum"].Carrier.RAIL or api.type["enum"].Carrier.ROAD
		local ok, available = pcall(function() : {MenuCategoryUtil.FilterObject}
			return menu_category_util.getAvailableObjectsSorted(rep, api.engine.util.getYear())
		end)
		local default : integer = nil
		for _, o in ipairs(ok and available or {}) do
			local suits = not withNone
			for _, c in ipairs(o.carriers or {}) do
				if c == carrier then suits = true end
			end
			if suits then
				objects[#objects + 1] = o
				if default == nil and o.isAutoSelectable ~= false then default = #objects end
			end
		end
		if #objects == 0 then return objects, nil end
		return objects, default or 1
	end
end

local function toolbarParams() : {ConstructionMenuParam}
	local toolbar = api.type["enum"].ScriptParamLocation.Toolbar
	local button = api.type["enum"].ScriptParamType.Button
	local checkbox = api.type["enum"].ScriptParamType.CheckBox

	local function seed(paramsApi : ConstructionMenuParamsAPI)
		if paramsApi then g_paramsApi = paramsApi end
	end

	local function enabledIf(fn : function() : (boolean), hideOtherwise? : boolean) : function({string : number}) : ConstructionMenuParam.CheckEnabledResult
		return function(_values : {string : number}) : ConstructionMenuParam.CheckEnabledResult
			if fn() then return "Enabled" end
			return hideOtherwise and "Hidden" or "Disabled"
		end
	end

	local function actionButton(key : string, label : string, tooltipText : string, group : string, event : string,
			enabled : function() : (boolean), hideOtherwise? : boolean) : ConstructionMenuParam
		return {
			key = key,
			name = label,
			tooltip = tooltipText,
			values = { label },
			defaultIndex = 1,
			hideLabel = true,
			group = group,
			yearFrom = 0,
			yearTo = 0,
			uiType = button,
			location = toolbar,
			onChangeFn = function(_newValue : number, paramsApi : ConstructionMenuParamsAPI, _oldValue? : number)
				seed(paramsApi)
				api.gui.fireReactEvent(event, {})
			end,
			checkEnabledFn = enabledIf(enabled, hideOtherwise),
		}
	end


	-- The panel's Connect options as the game's own rows (the build menu has no panel - on console
	-- it is the only way in). Each row writes the same setting the panel does; rows that only apply
	-- to some choices are hidden otherwise (refreshToolbar after every change re-checks them)
	local so = shared.opts as {string : any}
	local xo = (require "network_tools_1::/gui/construction/tools/connect/extra/ntools_connect_extra.script.tl" as {string : any}).opts as {string : number}
	local dubinsOpts = dubins.opts as {string : number}
	local function visibleIf(fn : function() : (boolean)) : function({string : number}) : ConstructionMenuParam.CheckEnabledResult
		return function(_values : {string : number}) : ConstructionMenuParam.CheckEnabledResult
			return fn() and "Enabled" or "Hidden"
		end
	end
	local function modeIs(...: integer) : function() : (boolean)
		local set : {integer : boolean} = {}
		for __, m in ipairs({ ... }) do set[m] = true end
		return function() : boolean return set[g_mode or MODE_CONNECTION] == true end
	end
	-- a checkbox; visible() may hide it
	local function check(key : string, name : string, tip : string, on : boolean, set : function(boolean), visible? : function() : (boolean)) : ConstructionMenuParam
		return {
			key = key, name = name, tooltip = tip, values = { _("Off"), _("On") },
			defaultIndex = on and 2 or 1, yearFrom = 0, yearTo = 0,
			uiType = checkbox, location = toolbar,
			-- idempotent: the flag from newValue, so a re-fired callback can't flip it back
			onChangeFn = function(newValue : number, paramsApi : ConstructionMenuParamsAPI, _oldValue? : number)
				seed(paramsApi)
				set(newValue == 2)
				refreshToolbar()
			end,
			checkEnabledFn = visible and visibleIf(visible) or nil,
		}
	end
	-- a slider over the values from lo to hi in steps (its value is the number itself)
	local function slider(key : string, name : string, tip : string, lo : number, hi : number, step : number, fmt : string,
			cur : number, set : function(number), visible? : function() : (boolean)) : ConstructionMenuParam
		local labels, numbers : {string}, {number} = {}, {}
		local def = 1
		local n = math.floor((hi - lo) / step + 0.5)
		for i = 0, n do
			local v = lo + i * step
			numbers[#numbers + 1] = v
			labels[#labels + 1] = string.format(fmt, v)
			if cur and math.abs(v - cur) < step / 2 then def = #numbers end
		end
		return {
			key = key, name = name, tooltip = tip, values = labels, numbers = numbers,
			defaultIndex = def, yearFrom = 0, yearTo = 0,
			uiType = api.type["enum"].ScriptParamType.Slider, location = toolbar,
			onChangeFn = function(newValue : number, paramsApi : ConstructionMenuParamsAPI, _oldValue? : number)
				seed(paramsApi)
				if newValue then set(newValue) end
				refreshToolbar()
			end,
			checkEnabledFn = visible and visibleIf(visible) or nil,
		}
	end
	-- a row of buttons; onIndex gets the 1-based choice
	local function choice(key : string, name : string, tip : string, labels : {string}, cur : integer, onIndex : function(integer),
			visible? : function() : (boolean)) : ConstructionMenuParam
		local numbers : {number} = {}
		for i = 1, #labels do numbers[i] = i end
		return {
			key = key, name = name, tooltip = tip, values = labels, numbers = numbers,
			defaultIndex = cur, yearFrom = 0, yearTo = 0,
			uiType = button, displayMode = api.type["enum"].ScriptParamDisplayMode.Horizontal, location = toolbar,
			onChangeFn = function(newValue : number, paramsApi : ConstructionMenuParamsAPI, _oldValue? : number)
				seed(paramsApi)
				if newValue then onIndex(math.floor(newValue + 0.5)) end
				refreshToolbar()
			end,
			checkEnabledFn = visible and visibleIf(visible) or nil,
		}
	end
	local function structureAuto() : boolean return (so.structure or 1) == 1 end
	local function fixedIncline() : boolean return so.incline ~= nil end

	-- the road / track type to build (the panel's Network list - the build menu has no panel): the
	-- game's own picker over this year's types, "Same as selected" first (the picked road's type;
	-- between two points on bare ground a type must be picked)
	local networkPicker : ConstructionMenuParam = {
		key = "ntools_network",
		tooltip = _("Road / track type: what the connection is built as. Same as selected: the type of the road you picked"),
		-- (no label, as the bridge / tunnel pickers below: a labelled picker drew one big tile)
		hideLabel = true,
		defaultIndex = 1,
		yearFrom = 0,
		yearTo = 0,
		location = toolbar,
		getFilterObjectsFn = function() : {MenuCategoryUtil.FilterObject}, integer
			local same : MenuCategoryUtil.FilterObject = {}
			same.id = -1
			same.name = _("Same as selected")
			same.iconPath = "network_tools_1::/gui/icons/ntools_toolbar.tga"
			same.availability = { yearFrom = 0, yearTo = 0 }
			-- (as the game's own "none" entries: the picker shows a speed beside every entry that has
			-- one, and a nil speed was a Lua error in its formatSpeed)
			same.speedLimit = 0
			same.menuCategory = { categories = { { order = -1, filterCategories = {} } } }
			local objects : {MenuCategoryUtil.FilterObject} = { same }
			local current = 1
			pcall(function()
				for __, o in ipairs(menu_category_util.getAvailableObjectsSorted(api.res.streetTemplateRep as ResTypeRep<integer, table>, api.engine.util.getYear())) do
					objects[#objects + 1] = o
					if o.id == g_networkId then current = #objects end
				end
			end)
			return objects, current
		end,
		resetOnDefinitionChange = false,
		resetOnCategoryChange = false,
		resetOnMenuClose = false,
		-- the value is the picked type's id (-1: Same as selected)
		onChangeFn = function(newValue : number, paramsApi : ConstructionMenuParamsAPI, _oldValue? : number)
			seed(paramsApi)
			if newValue then g_networkId = newValue >= 0 and math.floor(newValue) or nil end
		end,
	}

	return {
		networkPicker,
		-- the mode: all eleven in a list (one button row ran out of the panel at five)
		{
			key = MODE_PARAM,
			name = _("Mode"),
			-- (short: a tooltip doesn't wrap - each mode's own line is in tooltips)
			tooltip = _("The shape of the connection"),
			values = { _("Link"), _("Loop"), _("Curve"), _("Line"), _("Min. R"), _("Ease"), _("Helix"), _("Grade"), _("Spline"), _("Arc"), _("Offset") },
			tooltips = {
				_("Arcs joined by straights"),
				_("One circle touching both roads"),
				_("A smooth curve"),
				_("A straight line"),
				_("Shortest path, no curve tighter than the radius"),
				_("Min. R with transition curves"),
				_("Full turns added to climb at the set grade"),
				_("Never climbs steeper than the set grade"),
				_("A smooth curve through the points you click"),
				_("One circular arc"),
				_("An S-shift over to a parallel line"),
			},
			numbers = { 1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11 },
			defaultIndex = g_mode or MODE_CONNECTION,
			uiType = api.type["enum"].ScriptParamType.ComboBox,
			location = toolbar,
			yearFrom = 0,
			yearTo = 0,
			onChangeFn = function(newValue : number, paramsApi : ConstructionMenuParamsAPI, _oldValue? : number)
				seed(paramsApi)
				if newValue then
					g_mode = math.floor(newValue + 0.5)
				end
				refreshToolbar()
			end,
		},
		-- the mode's own settings
		slider("ntools_min_radius", _("Min. radius"), _("No curve is tighter than this (or drag a ring in the world)"),
			15, 2000, 5, "%d m", dubinsOpts.radius or 100, function(v : number) dubinsOpts.radius = clamp(v, MIN_RADIUS, MAX_RADIUS) end, modeIs(5, 6)),
		slider("ntools_ease_length", _("Easement"), _("Length of each transition curve (where the curve tightens / opens up)"),
			10, 200, 5, "%d m", xo.easeLength, function(v : number) xo.easeLength = v end, modeIs(6)),
		slider("ntools_helix_radius", _("Radius"), _("The helix's turns' radius"),
			40, 400, 5, "%d m", xo.helixRadius, function(v : number) xo.helixRadius = v end, modeIs(7)),
		slider("ntools_helix_grade", _("Grade"), _("Steepest climb: as many turns are added as it needs to reach the other end's height"),
			0.5, 6, 0.1, "%.1f %%", xo.helixGrade, function(v : number) xo.helixGrade = v end, modeIs(7)),
		slider("ntools_grade_max", _("Max. grade"), _("The route never climbs steeper than this between two points"),
			0.5, 8, 0.1, "%.1f %%", xo.gradeMax, function(v : number) xo.gradeMax = v end, modeIs(8)),
		-- height & placement
		slider("ntools_height_offset", _("Height offset"), _("Points on bare ground are built this far above (+) or below (-) the ground"),
			-20, 40, 1, "%+d m", so.heightOffset or 0, function(v : number) so.heightOffset = v end),
		check("ntools_fixed_incline", _("Fixed incline"), _("An end on bare ground takes its height from the other end and this grade (instead of the ground)"),
			so.incline ~= nil, function(v : boolean) so.incline = v and (so.incline or 0) or nil end),
		slider("ntools_incline", _("Incline"), _("Grade from the first point to the second (negative: downhill)"),
			-12, 12, 0.5, "%+.1f %%", so.incline or 0, function(v : number) so.incline = v end, fixedIncline),
		-- structures
		choice("ntools_structure", _("Structure"), _("Auto: bridges / tunnels by the heights below. Others: everything new built that way"),
			{ _("Auto"), _("Ground"), _("Bridge"), _("Tunnel") }, so.structure or 1, function(i : integer) so.structure = i end),
		slider("ntools_bridge_height", _("Bridge height"), _("A piece running at least this high above the ground (on average) becomes a bridge"),
			1, 20, 1, "%d m", so.bridgeHeight or 4.5, function(v : number) so.bridgeHeight = v end, structureAuto),
		slider("ntools_tunnel_depth", _("Tunnel depth"), _("A piece running at least this deep below the ground (on average) becomes a tunnel"),
			2, 30, 1, "%d m", so.tunnelDepth or 8, function(v : number) so.tunnelDepth = v end, structureAuto),
		-- twin
		choice("ntools_twin", _("Twin"), _("Also build a parallel copy on this side: double track, or a second carriageway"),
			{ _("Off"), _("Left"), _("Right") }, g_twin.side == 0 and 1 or (g_twin.side > 0 and 2 or 3),
			function(i : integer) g_twin.side = i == 1 and 0 or (i == 2 and 1 or -1) end),
		-- options
		check("ntools_live", _("Live preview"), _("The real road in the world. Off: a lighter schematic of it"),
			g_livePreview, function(v : boolean) g_livePreview = v end),
		check("ntools_replace", _("Replace the road between"), _("Rebuild the existing road between the two points in the new shape"),
			g_replace, function(v : boolean) g_replace = v end),
		check("ntools_override_lanes", _("Override lanes"), _("With Replace: junctions with edited lanes / lights may be rebuilt"),
			so.overrideLanes == true, function(v : boolean) so.overrideLanes = v end, function() : boolean return g_replace end),
		{
			key = FOLLOW_PARAM,
			name = _("Follow terrain"),
			tooltip = _("Place the new nodes on the ground instead of an even slope (T key)"),
			values = { _("Off"), _("On") },
			defaultIndex = g_followTerrain and 2 or 1,
			yearFrom = 0,
			yearTo = 0,
			uiType = checkbox,
			location = toolbar,
			-- idempotent: derive the flag from newValue so a re-fired callback can't flip it back
			onChangeFn = function(newValue : number, paramsApi : ConstructionMenuParamsAPI, _oldValue? : number)
				seed(paramsApi)
				g_followTerrain = newValue == 2
			end,
		},
		{
			key = SNAP_PARAM,
			name = _("Snapping"),
			tooltip = _("Snap radii to round numbers and let neighbouring circles meet directly (C key)"),
			values = { _("Off"), _("On") },
			defaultIndex = g_snap and 2 or 1,
			yearFrom = 0,
			yearTo = 0,
			uiType = checkbox,
			location = toolbar,
			onChangeFn = function(newValue : number, paramsApi : ConstructionMenuParamsAPI, _oldValue? : number)
				seed(paramsApi)
				g_snap = newValue == 2
			end,
		},
		check("ntools_snap_roads", _("Snap to roads"), _("A click on bare ground right next to a road picks the road"),
			so.snapToRoads ~= false, function(v : boolean) so.snapToRoads = v end),
		check("ntools_underground", _("Underground"), _("Show and pick only underground roads and tracks (tunnels), like the game's builders"),
			so.underground == true, function(v : boolean) so.underground = v end),
		{
			key = ANARCHY_PARAM,
			name = _("Anarchy"),
			tooltip = _("Build without collision checks: the connection may overlap other roads, tracks and buildings"),
			values = { _("Off"), _("On") },
			defaultIndex = g_anarchy and 2 or 1,
			yearFrom = 0,
			yearTo = 0,
			uiType = checkbox,
			location = toolbar,
			-- idempotent: derive the flag from newValue
			onChangeFn = function(newValue : number, paramsApi : ConstructionMenuParamsAPI, _oldValue? : number)
				seed(paramsApi)
				g_anarchy = newValue == 2
				refreshToolbar()
			end,
		},
		{
			key = BRIDGES_PARAM,
			name = _("Bridges & tunnels"),
			tooltip = _("Automatically build bridges where the road runs high above the ground, tunnels where it runs deep below, and raise it over its own crossings"),
			values = { _("Off"), _("On") },
			defaultIndex = g_bridges and 2 or 1,
			yearFrom = 0,
			yearTo = 0,
			uiType = checkbox,
			location = toolbar,
			onChangeFn = function(newValue : number, paramsApi : ConstructionMenuParamsAPI, _oldValue? : number)
				seed(paramsApi)
				g_bridges = newValue == 2
			end,
		},
		{
			key = "ntools_bridge_type",
			tooltip = _("Bridge type used where the road runs high above the ground"),
			defaultIndex = 1,
			yearFrom = 0,
			yearTo = 0,
			location = toolbar,
			hideLabel = true,
			getFilterObjectsFn = makePicker(api.res.bridgeTypeRep as ResTypeRep<integer, table>, "Bridge"),
			resetOnDefinitionChange = false,
			resetOnCategoryChange = false,
			resetOnMenuClose = false,
			-- the value is the picked type's id (-1 = none)
			onChangeFn = function(newValue : number, paramsApi : ConstructionMenuParamsAPI, _oldValue? : number)
				seed(paramsApi)
				if newValue then g_bridgeType = math.floor(newValue) end
			end,
			checkEnabledFn = function(_values : {string : number}) : ConstructionMenuParam.CheckEnabledResult
				return g_bridges and "Enabled" or "Disabled"
			end,
		},
		{
			key = "ntools_tunnel_type",
			tooltip = _("Tunnel type used where the road runs deep below the ground"),
			defaultIndex = 1,
			yearFrom = 0,
			yearTo = 0,
			location = toolbar,
			hideLabel = true,
			getFilterObjectsFn = makePicker(api.res.tunnelTypeRep as ResTypeRep<integer, table>, "Tunnel"),
			resetOnDefinitionChange = false,
			resetOnCategoryChange = false,
			resetOnMenuClose = false,
			-- the value is the picked type's id (-1 = none)
			onChangeFn = function(newValue : number, paramsApi : ConstructionMenuParamsAPI, _oldValue? : number)
				seed(paramsApi)
				if newValue then g_tunnelType = math.floor(newValue) end
			end,
			checkEnabledFn = function(_values : {string : number}) : ConstructionMenuParam.CheckEnabledResult
				return g_bridges and "Enabled" or "Disabled"
			end,
		},
		{
			key = "ntools_rc_type",
			tooltip = _("Level crossing type used where a road meets rail"),
			defaultIndex = 1,
			yearFrom = 0,
			yearTo = 0,
			location = toolbar,
			hideLabel = true,
			getFilterObjectsFn = makePicker(api.res.railroadCrossingTypeRep as ResTypeRep<integer, table>, "RailroadCrossing"),
			resetOnDefinitionChange = false,
			resetOnCategoryChange = false,
			resetOnMenuClose = false,
			-- the value is the picked type's id (-1 = none)
			onChangeFn = function(newValue : number, paramsApi : ConstructionMenuParamsAPI, _oldValue? : number)
				seed(paramsApi)
				if newValue then g_rcType = math.floor(newValue) end
			end,
			checkEnabledFn = function(_values : {string : number}) : ConstructionMenuParam.CheckEnabledResult
				return true and "Enabled" or "Disabled"
			end,
		},
		actionButton("ntools_reset", _("Reset"), _("Go back to the default shape"), "ntools_final", "ntoolsResetShape", function() : boolean return g_ui.ready end),
		actionButton("ntools_build", _("Build"), _("Build the connection"), "ntools_final", "ntoolsBuild", function() : boolean return g_ui.canBuild end),
	}
end

----------------------------------------------------------------------------------------------------
----------------------------------------------------------------------------------------------------
-- The other tools, the Network Tools panel and the build-menu entries are set up inside makeUi():
-- a Lua chunk may only have 200 local variables, and this file's main body had reached that limit
-- ("too many local variables (limit is 200) in main function"). makeUi() returns what Ret exports.

local record UiExports
	togglePanel : function(boolean)
	isPanelOpen : function() : boolean
	getUpgradeDefinition : function(ResName, ConstructionActionRepository, table) : ConstructionDefinition
	getCrossoverDefinition : function(ResName, ConstructionActionRepository, table) : ConstructionDefinition
	getJunctionDefinition : function(ResName, ConstructionActionRepository, table) : ConstructionDefinition
	getSidingDefinition : function(ResName, ConstructionActionRepository, table) : ConstructionDefinition
	getSignalsDefinition : function(ResName, ConstructionActionRepository, table) : ConstructionDefinition
	getShapeDefinition : function(ResName, ConstructionActionRepository, table) : ConstructionDefinition
	getArrangeLineDefinition : function(ResName, ConstructionActionRepository, table) : ConstructionDefinition
	getArrangeCircleDefinition : function(ResName, ConstructionActionRepository, table) : ConstructionDefinition
	getGenerateDefinition : function(ResName, ConstructionActionRepository, table) : ConstructionDefinition
	getParallelDefinition : function(ResName, ConstructionActionRepository, table) : ConstructionDefinition
	getReverseDefinition : function(ResName, ConstructionActionRepository, table) : ConstructionDefinition
	getAddNodeDefinition : function(ResName, ConstructionActionRepository, table) : ConstructionDefinition
	getRemoveNodeDefinition : function(ResName, ConstructionActionRepository, table) : ConstructionDefinition
	getSlopeDefinition : function(ResName, ConstructionActionRepository, table) : ConstructionDefinition
end

local function makeUi() : UiExports
-- Network Tools: Parallel lives in ntools_parallel_tool.script.tl. It gets the helpers and the
-- shared state it needs from here once, at load (a require back into this file would be circular).

local record ParallelOptions
	offset : number        -- nil = automatic
	autoOffset : number
	side : integer         -- +1 = left, -1 = right
	height : number
	crossings : boolean    -- join existing roads / tracks the copy runs over
	connectEnds : boolean  -- join the copy's ends to the network where they land
	count : integer        -- copies side by side
end
local record ParallelModule
	init : function(any)
	opts : ParallelOptions
	copyProposal : function(chain : {{string : any}}, offset : number, flip : boolean) : SimpleProposal
	withTwinPreview : function(sp : SimpleProposal, offset : number, flip : boolean) : SimpleProposal
	mergeSections : function(list : {SimpleProposal}) : SimpleProposal, string
	ParallelActionRecipe : function(ConstructionCustomActionParams<any>) : TreeNodeId
end
local parallel = require "network_tools_1::/gui/construction/tools/parallel/ntools_parallel_tool.script.tl" as ParallelModule
parallel.init({
	p3 = p3, clamp = clamp, dot2 = dot2, norm2 = norm2,
	getEdge = getEdge, getNodePos = getNodePos, isEdge = function(e : Engine.Entity) : boolean return getEdge(e) ~= nil end,
	sanitizePieces = sanitizePieces, vec3 = vec3,
	laneWidth = laneWidth, templateById = templateById, templateByName = templateByName, applyNetwork = applyNetwork,
	fmtLen = fmtLen, tooltip = tooltip,
	shortcutHandler = shortcutHandler, safeUseInputAction = safeUseInputAction, precise = precise,
	networkId = function() : integer return g_networkId end,
	anarchy = function() : boolean return g_anarchy end,
	levelCrossingType = levelCrossingType,
	ui = g_ui,
	toolbarEvents = TOOLBAR_EVENTS,
})
local g_par = parallel.opts
g_twin.copy = parallel.copyProposal
g_twin.preview = parallel.withTwinPreview
g_twin.merge = parallel.mergeSections

-- Network Tools: Reverse lives in reverse/ntools_reverse_tool.script.tl (same hand-over as Parallel).
local record ReverseModule
	init : function(any)
	ReverseActionRecipe : function(ConstructionCustomActionParams<any>) : TreeNodeId
end
local reverse = require "network_tools_1::/gui/construction/tools/reverse/ntools_reverse_tool.script.tl" as ReverseModule
reverse.init({
	getEdge = getEdge, isEdge = function(e : Engine.Entity) : boolean return getEdge(e) ~= nil end, tooltip = tooltip,
	anarchy = function() : boolean return g_anarchy end,
	ui = g_ui,
	toolbarEvents = TOOLBAR_EVENTS,
})

-- The newer Rail tab tools (upgrade/ ...), all in ONE local: this file's main body is at Lua's
-- 200-local limit
local railTools : {string : {string : any}} = {
	upgrade = require "network_tools_1::/gui/construction/tools/upgrade/ntools_upgrade_tool.script.tl" as {string : any},
	crossover = require "network_tools_1::/gui/construction/tools/crossover/ntools_crossover_tool.script.tl" as {string : any},
	loop = require "network_tools_1::/gui/construction/tools/loop/ntools_loop_tool.script.tl" as {string : any},
	junction = require "network_tools_1::/gui/construction/tools/junction/ntools_junction_tool.script.tl" as {string : any},
	siding = require "network_tools_1::/gui/construction/tools/siding/ntools_siding_tool.script.tl" as {string : any},
}
for __, m in pairs(railTools) do
	(m.init as function(any))({
		getEdge = getEdge, isEdge = function(e : Engine.Entity) : boolean return getEdge(e) ~= nil end, tooltip = tooltip,
		pickEdge = isEdge,   -- (stations too: their track nearest the mouse, as Connect picks)
		anarchy = function() : boolean return g_anarchy end,
		ui = g_ui,
		toolbarEvents = TOOLBAR_EVENTS,
	})
end

-- Network Tools: Add node / Remove node live in add_node/ and remove_node/ (same hand-over).
local record AddNodeModule
	init : function(any)
	AddNodeActionRecipe : function(ConstructionCustomActionParams<any>) : TreeNodeId
end
local add_node = require "network_tools_1::/gui/construction/tools/add_node/ntools_add_node_tool.script.tl" as AddNodeModule
add_node.init({
	getEdge = getEdge, isEdge = function(e : Engine.Entity) : boolean return getEdge(e) ~= nil end, tooltip = tooltip,
	anarchy = function() : boolean return g_anarchy end,
})

-- Network Tools: Set slope lives in slope/ (same hand-over; the panel edits its options).
local record SlopeOptions
	mode : integer      -- 1 linear, 2 ease, 3 arch
	arch : number       -- metres
	easeIn : number     -- 0 .. 0.5 of the stretch
	easeOut : number
end
local record SlopeModule
	init : function(any)
	opts : SlopeOptions
	SlopeActionRecipe : function(ConstructionCustomActionParams<any>) : TreeNodeId
end
local slope = require "network_tools_1::/gui/construction/tools/slope/ntools_slope_tool.script.tl" as SlopeModule
slope.init({
	getEdge = getEdge, isEdge = function(e : Engine.Entity) : boolean return getEdge(e) ~= nil end, getNodePos = getNodePos, tooltip = tooltip,
	anarchy = function() : boolean return g_anarchy end,
	ui = g_ui,
	toolbarEvents = TOOLBAR_EVENTS,
})
local g_slope = slope.opts

-- The reshape engine (shared by Smooth / Straighten and the Arrange tools) and those tools; then
-- Generate. Same hand-over: the helpers they need are passed in once.
local record ReshapeEngine
	init : function(any)
end
local reshape_engine = require "network_tools_1::/gui/construction/tools/shared/ntools_reshape.script.tl" as ReshapeEngine
reshape_engine.init({
	getEdge = getEdge, isEdge = function(e : Engine.Entity) : boolean return getEdge(e) ~= nil end, getNodePos = getNodePos, tooltip = tooltip,
	anarchy = function() : boolean return g_anarchy end,
	ui = g_ui,
	toolbarEvents = TOOLBAR_EVENTS,
})

local record ShapeOptions
	mode : integer        -- 1 straighten, 2 smooth, 3 ease, 4 curve (its options: the panel)
	strength : number     -- smooth: 0 .. 1
	transition : number   -- ease: 0 .. 1
end
local record ShapeModule
	opts : ShapeOptions
	ShapeActionRecipe : function(ConstructionCustomActionParams<any>) : TreeNodeId
end
local shape_tool = require "network_tools_1::/gui/construction/tools/shape/ntools_shape_tool.script.tl" as ShapeModule
local g_shape = shape_tool.opts

local record ArrangeLineModule
	ArrangeLineActionRecipe : function(ConstructionCustomActionParams<any>) : TreeNodeId
end
local arrange_line = require "network_tools_1::/gui/construction/tools/arrange_line/ntools_arrange_line_tool.script.tl" as ArrangeLineModule

local record ArrangeCircleModule
	ArrangeCircleActionRecipe : function(ConstructionCustomActionParams<any>) : TreeNodeId
end
local arrange_circle = require "network_tools_1::/gui/construction/tools/arrange_circle/ntools_arrange_circle_tool.script.tl" as ArrangeCircleModule

local record GenerateOptions
	shape : integer       -- 1 circle, 2 oval, 3 grid, 4 helix
	radius : number
	radiusY : number
	cols : integer
	rows : integer
	spacing : number
	rotation : number
	turns : number        -- helix
	grade : number        -- helix: % (negative = descends)
	clockwise : boolean   -- helix
end
local record GenerateModule
	init : function(any)
	opts : GenerateOptions
	GenerateActionRecipe : function(ConstructionCustomActionParams<any>) : TreeNodeId
end
local generate = require "network_tools_1::/gui/construction/tools/generate/ntools_generate_tool.script.tl" as GenerateModule
generate.init({
	tooltip = tooltip,
	anarchy = function() : boolean return g_anarchy end,
	ui = g_ui,
	toolbarEvents = TOOLBAR_EVENTS,
	-- the panel's Network pick, else the first available road (then track)
	networkTemplate = function() : integer
		if g_networkId then return g_networkId end
		local list = listNetworks()
		for _, n in ipairs(list) do
			if not n.isTrack then return n.id end
		end
		return list[1] and list[1].id or nil
	end,
})
local g_gen = generate.opts

-- Auto-signal (a Transport Fever tool): signals along a stretch of track
local record SignalOptions
	spacing : number
	spacingType : integer  -- 1 equal blocks, 2 fixed interval, 3 by line speed, 4 by count
	blockCount : integer
	twoWay : boolean
	existingMode : integer -- 1 keep, 2 replace, 3 ignore
	oneWay : boolean
	reverse : boolean
	beforeSwitches : boolean
	beforeCrossings : boolean
	switchDistance : number
	crossingDistance : number
	besideTracks : boolean
	besideSameWay : boolean
	removeMode : boolean
	stationMode : boolean
	pattern : integer      -- 1 opposite, 2 same, 3 alternate, 4 pairs
	model : string
end
local record SignalModel
	name : string
	label : string
	oneWay : boolean
end
local record SignalsModule
	init : function(any)
	opts : SignalOptions
	listSignals : function() : {SignalModel}
	SignalsActionRecipe : function(ConstructionCustomActionParams<any>) : TreeNodeId
end
local signals = require "network_tools_1::/gui/construction/tools/signals/ntools_signals_tool.script.tl" as SignalsModule
signals.init({
	getEdge = getEdge, isEdge = function(e : Engine.Entity) : boolean return getEdge(e) ~= nil end, tooltip = tooltip,
	anarchy = function() : boolean return g_anarchy end,
	ui = g_ui,
	toolbarEvents = TOOLBAR_EVENTS,
	shortcutHandler = shortcutHandler, safeUseInputAction = safeUseInputAction,
})
local g_sig = signals.opts

local record RemoveNodeModule
	init : function(any)
	RemoveNodeActionRecipe : function(ConstructionCustomActionParams<any>) : TreeNodeId
end
local remove_node = require "network_tools_1::/gui/construction/tools/remove_node/ntools_remove_node_tool.script.tl" as RemoveNodeModule
remove_node.init({
	getEdge = getEdge, isEdge = function(e : Engine.Entity) : boolean return getEdge(e) ~= nil end, tooltip = tooltip, pickNodeOnEdge = pickNodeOnEdge,
	anarchy = function() : boolean return g_anarchy end,
})

----------------------------------------------------------------------------------------------------
-- Network Tools panel: its own file (panel/ntools_panel.script.tl). It gets the tools' recipes, the
-- shared option tables and accessors for this file's own settings (plain variables here) once.
local record PanelModule
	init : function(any)
	togglePanel : function(boolean)
	isPanelOpen : function() : boolean
end
local panel = require "network_tools_1::/gui/construction/tools/panel/ntools_panel.script.tl" as PanelModule
panel.init({
	get = function(key : string) : any
		if key == "mode" then return g_mode
		elseif key == "follow" then return g_followTerrain
		elseif key == "snap" then return g_snap
		elseif key == "anarchy" then return g_anarchy
		elseif key == "bridges" then return g_bridges
		elseif key == "network" then return g_networkId
		elseif key == "twin" then return g_twin.side
		elseif key == "replace" then return g_replace
		elseif key == "live" then return g_livePreview
		elseif key == "dubinsRadius" then return (dubins.opts as {string : number}).radius
		-- bridge / tunnel / level crossing type: an id, -1 = none, nil = automatic
		elseif key == "bridgeType" then return g_bridgeType
		elseif key == "tunnelType" then return g_tunnelType
		elseif key == "rcType" then return g_rcType
		end
		return nil
	end,
	set = function(key : string, value : any)
		if key == "mode" then g_mode = value as integer
		elseif key == "follow" then g_followTerrain = value as boolean
		elseif key == "snap" then g_snap = value as boolean
		elseif key == "anarchy" then g_anarchy = value as boolean
		elseif key == "bridges" then g_bridges = value as boolean
		elseif key == "network" then g_networkId = value as integer
		elseif key == "twin" then g_twin.side = (value as integer) or 0
		elseif key == "replace" then g_replace = value as boolean
		elseif key == "live" then g_livePreview = value as boolean
		elseif key == "dubinsRadius" then (dubins.opts as {string : number}).radius = clamp(value as number, MIN_RADIUS, MAX_RADIUS)
		elseif key == "bridgeType" then g_bridgeType = value as integer
		elseif key == "tunnelType" then g_tunnelType = value as integer
		elseif key == "rcType" then g_rcType = value as integer
		end
	end,
	ui = g_ui,
	modeConnection = MODE_CONNECTION,
	listNetworks = listNetworks,
	listSignals = signals.listSignals,
	clamp = clamp,
	recipes = {
		connect = ConnectActionRecipe,
		parallel = parallel.ParallelActionRecipe,
		reverse = reverse.ReverseActionRecipe,
		addNode = add_node.AddNodeActionRecipe,
		removeNode = remove_node.RemoveNodeActionRecipe,
		slope = slope.SlopeActionRecipe,
		shape = shape_tool.ShapeActionRecipe,
		arrangeLine = arrange_line.ArrangeLineActionRecipe,
		arrangeCircle = arrange_circle.ArrangeCircleActionRecipe,
		generate = generate.GenerateActionRecipe,
		signals = signals.SignalsActionRecipe,
		-- (the cast in brackets: after "function(...) : T" a comma would read as a second return type)
		upgrade = (railTools.upgrade.UpgradeActionRecipe as function(ConstructionCustomActionParams<any>) : TreeNodeId),
		crossover = (railTools.crossover.CrossoverActionRecipe as function(ConstructionCustomActionParams<any>) : TreeNodeId),
		loop = (railTools.loop.LoopActionRecipe as function(ConstructionCustomActionParams<any>) : TreeNodeId),
		junction = (railTools.junction.JunctionActionRecipe as function(ConstructionCustomActionParams<any>) : TreeNodeId),
		siding = (railTools.siding.SidingActionRecipe as function(ConstructionCustomActionParams<any>) : TreeNodeId),
	},
	junction = railTools.junction.opts,
	siding = railTools.siding.opts,
	upgrade = railTools.upgrade.opts,
	crossover = railTools.crossover.opts,
	loop = railTools.loop.opts,
	par = g_par,
	slope = g_slope,
	shape = g_shape,
	gen = g_gen,
	sig = g_sig,
})
local togglePanel = panel.togglePanel
local isPanelOpen = panel.isPanelOpen

-- The build-menu definitions live inside a function: a Lua chunk may only have 200 local
-- variables, and this file's main body had reached that limit ("too many local variables").
local record ToolDefs
	getUpgradeDefinition : function(ResName, ConstructionActionRepository, table) : ConstructionDefinition
	getCrossoverDefinition : function(ResName, ConstructionActionRepository, table) : ConstructionDefinition
	getJunctionDefinition : function(ResName, ConstructionActionRepository, table) : ConstructionDefinition
	getSidingDefinition : function(ResName, ConstructionActionRepository, table) : ConstructionDefinition
	getSignalsDefinition : function(ResName, ConstructionActionRepository, table) : ConstructionDefinition
	getShapeDefinition : function(ResName, ConstructionActionRepository, table) : ConstructionDefinition
	getArrangeLineDefinition : function(ResName, ConstructionActionRepository, table) : ConstructionDefinition
	getArrangeCircleDefinition : function(ResName, ConstructionActionRepository, table) : ConstructionDefinition
	getGenerateDefinition : function(ResName, ConstructionActionRepository, table) : ConstructionDefinition
	getParallelDefinition : function(ResName, ConstructionActionRepository, table) : ConstructionDefinition
	getReverseDefinition : function(ResName, ConstructionActionRepository, table) : ConstructionDefinition
	getAddNodeDefinition : function(ResName, ConstructionActionRepository, table) : ConstructionDefinition
	getRemoveNodeDefinition : function(ResName, ConstructionActionRepository, table) : ConstructionDefinition
	getSlopeDefinition : function(ResName, ConstructionActionRepository, table) : ConstructionDefinition
end
local function makeToolDefinitions() : ToolDefs
----------------------------------------------------------------------------------------------------
-- Build-menu entries for the other tools (Network Tools tab of the Roads / Tracks menus). Each tool's
-- folder has a construction_tool .res.lua pointing at one of the getXxxDefinition functions below.
-- They live here because this is where every tool module is loaded and handed its helpers.
-- In the build menu there is no panel, so each entry's settings are toolbar params (the game draws
-- them as its native one-line rows); they write the same option tables the panel and the in-world
-- handles use. Param values: checkboxes report 2 = on; sliders / choices report the stop's index
-- (their `numbers` are the indices 0 .. n-1).

local function tbSeed(paramsApi : ConstructionMenuParamsAPI)
	if paramsApi then g_paramsApi = paramsApi end
end

local function tbButton(key : string, label : string, tip : string, event : string, enabled : function() : (boolean)) : ConstructionMenuParam
	return {
		key = key, name = label, tooltip = tip, values = { label }, defaultIndex = 1, hideLabel = true,
		group = "ntools_final", yearFrom = 0, yearTo = 0,
		uiType = api.type["enum"].ScriptParamType.Button,
		location = api.type["enum"].ScriptParamLocation.Toolbar,
		onChangeFn = function(_v : number, paramsApi : ConstructionMenuParamsAPI, _o? : number)
			tbSeed(paramsApi)
			api.gui.fireReactEvent(event, {})
		end,
		checkEnabledFn = function(_values : {string : number}) : ConstructionMenuParam.CheckEnabledResult
			return enabled() and "Enabled" or "Disabled"
		end,
	}
end

local function tbIndices(n : integer) : {number}
	local out : {number} = {}
	for i = 1, n do out[i] = i - 1 end
	return out
end

-- slider or button row over `labels`; onIndex gets the 0-based stop; visible() may hide it
local function tbChoice(key : string, name : string, tip : string, uiType : ScriptParamType, labels : {string},
		defaultIdx : integer, onIndex : function(integer), visible? : function() : (boolean)) : ConstructionMenuParam
	return {
		key = key, name = name, tooltip = tip, values = labels, numbers = tbIndices(#labels),
		defaultIndex = defaultIdx + 1, yearFrom = 0, yearTo = 0,
		uiType = uiType,
		displayMode = uiType == api.type["enum"].ScriptParamType.Button and api.type["enum"].ScriptParamDisplayMode.Horizontal or nil,
		location = api.type["enum"].ScriptParamLocation.Toolbar,
		onChangeFn = function(v : number, paramsApi : ConstructionMenuParamsAPI, _o? : number)
			tbSeed(paramsApi)
			if v then onIndex(math.floor(v + 0.5)) end
			refreshToolbar()
		end,
		checkEnabledFn = function(_values : {string : number}) : ConstructionMenuParam.CheckEnabledResult
			if visible and not visible() then return "Hidden" end
			return "Enabled"
		end,
	}
end

local function tbCheck(key : string, name : string, tip : string, default : boolean, set : function(boolean)) : ConstructionMenuParam
	return {
		key = key, name = name, tooltip = tip, values = { _("Off"), _("On") },
		defaultIndex = default and 2 or 1, yearFrom = 0, yearTo = 0,
		uiType = api.type["enum"].ScriptParamType.CheckBox,
		location = api.type["enum"].ScriptParamLocation.Toolbar,
		onChangeFn = function(v : number, paramsApi : ConstructionMenuParamsAPI, _o? : number)
			tbSeed(paramsApi)
			set(v == 2)
		end,
	}
end

local function tbAnarchy() : ConstructionMenuParam
	return tbCheck(ANARCHY_PARAM, _("Anarchy"), _("Build without collision checks"), g_anarchy,
		function(v : boolean) g_anarchy = v end)
end

local function tbResetBuild(buildTip : string) : {ConstructionMenuParam}
	return {
		tbButton("ntools_reset", _("Reset"), _("Start over"), "ntoolsResetShape", function() : boolean return true end),
		tbButton("ntools_build", _("Build"), buildTip, "ntoolsBuild", function() : boolean return g_ui.canBuild end),
	}
end

-- the Network Tools tabs when loaded, else the game's Road / Rail Tools tabs
local function ntCategories(order : integer) : ModelMetadata.MenuCategory
	-- Build menu tab off (Settings): in no tab at all
	if shared.opts.buildMenu == false then return { categories = {} } as ModelMetadata.MenuCategory end
	local hasOwn = false
	pcall(function()
		for _, id in ipairs(api.res.genericRep.getAllOfType("menu_category")) do
			local res = api.res.genericRep.get(id)
			local data = res and res.data as ConstructionMenuCategory
			if data and data.category == "ntools_road" then hasOwn = true end
		end
	end)
	return {
		categories = {
			{ category = hasOwn and "ntools_road" or "roads_tools", order = hasOwn and order or 900 + order },
			{ category = hasOwn and "ntools_rail" or "rail_tools", order = hasOwn and order or 900 + order },
		},
	} as ModelMetadata.MenuCategory
end

local record ToolSpec
	icon : string      -- "<folder>/<file>" under tools/, without .tga (its _preview sits beside it)
	name : string
	description : string
	order : integer
	recipe : function(ConstructionCustomActionParams<any>) : TreeNodeId
	params : {ConstructionMenuParam}
end

local function toolDefinition(resName : ResName, spec : ToolSpec) : ConstructionDefinition
	return {
		resName = resName,
		icon = { icon = "network_tools_1::/gui/construction/tools/" .. spec.icon .. ".tga" },
		previewIcon = { icon = "network_tools_1::/gui/construction/tools/" .. spec.icon .. "_preview.tga" },
		name = spec.name,
		description = spec.description,
		action = "ACTION_CUSTOM",
		availability = { yearFrom = 0, yearTo = 0 },
		params = spec.params,
		hudIcons = construction_react_util.getStreetToolsHudIcons("ROAD"),
		customAction = {
			recipe = spec.recipe as Recipe<ConstructionCustomActionParams<any>>,
			customParam = nil,
		},
		menuCategory = ntCategories(spec.order),
	}
end

local function concat(a : {ConstructionMenuParam}, b : {ConstructionMenuParam}) : {ConstructionMenuParam}
	local out : {ConstructionMenuParam} = {}
	for _, p in ipairs(a) do out[#out + 1] = p end
	for _, p in ipairs(b) do out[#out + 1] = p end
	return out
end

local function getParallelDefinition(resName : ResName, _repo : ConstructionActionRepository, _params : table) : ConstructionDefinition
	local SLIDER = api.type["enum"].ScriptParamType.Slider
	local BUTTON = api.type["enum"].ScriptParamType.Button
	local offsetLabels, heightLabels : {string}, {string} = {}, {}
	for i = 1, 200 do offsetLabels[i] = string.format("%.1f m", i / 2) end
	for i = 0, 200 do heightLabels[i + 1] = string.format("%+.1f m", (i - 100) / 2) end
	return toolDefinition(resName, {
		icon = "parallel/ntools_parallel",
		name = _("Parallel (Network Tools)"),
		description = _("Build a copy of a stretch of road or track beside it, at a chosen offset and height. Joins roads it crosses and the ones its ends land on."),
		order = 200,
		recipe = parallel.ParallelActionRecipe,
		params = concat({
			tbChoice("ntools_par_offset", _("Offset"), _("Distance from the original (or drag the handle)"), SLIDER, offsetLabels,
				math.floor(clamp(g_par.offset or g_par.autoOffset, 0.5, 100) * 2 + 0.5) - 1,
				function(i : integer) g_par.offset = (i + 1) / 2 end),
			tbChoice("ntools_par_height", _("Height"), _("Raise or lower the copy"), SLIDER, heightLabels,
				math.floor(clamp(g_par.height, -50, 50) * 2 + 0.5) + 100,
				function(i : integer) g_par.height = (i - 100) / 2 end),
			tbChoice("ntools_par_side", _("Side"), _("Which side of the direction you selected in - or both"), BUTTON,
				{ _("Left"), _("Both"), _("Right") }, g_par.side > 0 and 0 or (g_par.side == 0 and 1 or 2),
				function(i : integer) g_par.side = i == 0 and 1 or (i == 1 and 0 or -1) end),
			tbCheck("ntools_par_auto", _("Automatic offset"), _("Put the copy right beside the original"), g_par.offset == nil,
				function(v : boolean) g_par.offset = (not v) and (g_par.offset or g_par.autoOffset) or nil end),
			tbCheck("ntools_par_ends", _("Connect ends"), _("Join the copy's ends to the road or track they land on"), g_par.connectEnds ~= false,
				function(v : boolean) g_par.connectEnds = v end),
			tbChoice("ntools_par_count", _("Copies"), _("How many copies side by side"), SLIDER,
				{ "1", "2", "3", "4", "5", "6", "7", "8" }, math.floor(clamp(g_par.count or 1, 1, 8)) - 1,
				function(i : integer) g_par.count = i + 1 end),
			tbCheck("ntools_par_cross", _("Make crossings"), _("Join roads and tracks the copy runs over"), g_par.crossings ~= false,
				function(v : boolean) g_par.crossings = v end),
			tbAnarchy(),
		}, tbResetBuild(_("Build the copy"))),
	})
end

local function getReverseDefinition(resName : ResName, _repo : ConstructionActionRepository, _params : table) : ConstructionDefinition
	return toolDefinition(resName, {
		icon = "reverse/ntools_reverse",
		name = _("Reverse (Network Tools)"),
		description = _("Flip the direction of road or track segments: one-way roads run the other way."),
		order = 300,
		recipe = reverse.ReverseActionRecipe,
		params = concat({ tbAnarchy() }, tbResetBuild(_("Reverse the selected segments"))),
	})
end

local function getAddNodeDefinition(resName : ResName, _repo : ConstructionActionRepository, _params : table) : ConstructionDefinition
	return toolDefinition(resName, {
		icon = "add_node/ntools_add_node",
		name = _("Add node (Network Tools)"),
		description = _("Click a road or track to split it there with a plain node. Its shape stays the same."),
		order = 400,
		recipe = add_node.AddNodeActionRecipe,
		params = { tbAnarchy() },
	})
end

local function getRemoveNodeDefinition(resName : ResName, _repo : ConstructionActionRepository, _params : table) : ConstructionDefinition
	return toolDefinition(resName, {
		icon = "remove_node/ntools_remove_node",
		name = _("Remove node (Network Tools)"),
		description = _("Click next to a plain node to merge its two segments into one."),
		order = 500,
		recipe = remove_node.RemoveNodeActionRecipe,
		params = { tbAnarchy() },
	})
end

local function getSlopeDefinition(resName : ResName, _repo : ConstructionActionRepository, _params : table) : ConstructionDefinition
	local SLIDER = api.type["enum"].ScriptParamType.Slider
	local BUTTON = api.type["enum"].ScriptParamType.Button
	local archLabels, pctLabels : {string}, {string} = {}, {}
	for i = 0, 120 do archLabels[i + 1] = string.format("%+.1f m", (i - 60) / 2) end
	for i = 0, 100 do pctLabels[i + 1] = tostring(i) .. " %" end
	return toolDefinition(resName, {
		icon = "slope/ntools_slope",
		name = _("Set slope (Network Tools)"),
		description = _("Give a stretch of road or track an even gradient, an eased one (level at the ends), or an arch."),
		order = 600,
		recipe = slope.SlopeActionRecipe,
		params = concat({
			tbChoice("ntools_slope_mode", _("Profile"), _("Linear, Ease (level at the ends) or Arch"), BUTTON,
				{ _("Linear"), _("Ease"), _("Arch") }, (g_slope.mode or 1) - 1,
				function(i : integer) g_slope.mode = i + 1 end),
			tbChoice("ntools_slope_in", _("Start flatness"), _("How long the road stays level at the start (or drag the first handle)"), SLIDER, pctLabels,
				math.floor(clamp(g_slope.easeIn, 0, 0.5) * 200 + 0.5),
				function(i : integer) g_slope.easeIn = i / 200 end,
				function() : boolean return g_slope.mode == 2 end),
			tbChoice("ntools_slope_out", _("End flatness"), _("How long the road is level again at the end (or drag the second handle)"), SLIDER, pctLabels,
				math.floor(clamp(g_slope.easeOut, 0, 0.5) * 200 + 0.5),
				function(i : integer) g_slope.easeOut = i / 200 end,
				function() : boolean return g_slope.mode == 2 end),
			tbChoice("ntools_slope_arch", _("Arch"), _("How far the middle rises above (or dips below) a straight line (or drag the handle)"), SLIDER, archLabels,
				math.floor(clamp(g_slope.arch, -30, 30) * 2 + 0.5) + 60,
				function(i : integer) g_slope.arch = (i - 60) / 2 end,
				function() : boolean return g_slope.mode == 3 end),
			tbAnarchy(),
		}, tbResetBuild(_("Apply the slope"))),
	})
end

local function getShapeDefinition(resName : ResName, _repo : ConstructionActionRepository, _params : table) : ConstructionDefinition
	local pct : {string} = {}
	for i = 0, 100 do pct[i + 1] = tostring(i) .. " %" end
	return toolDefinition(resName, {
		icon = "shape/ntools_shape",
		name = _("Smooth / Straighten (Network Tools)"),
		description = _("Straighten a stretch of road or track, smooth out its kinks so trains keep their speed, or ease a bend into a railway-style curve with transition spirals."),
		order = 700,
		recipe = shape_tool.ShapeActionRecipe,
		params = concat({
			tbChoice("ntools_shape_mode", _("Mode"), _("Straighten, Smooth, Ease (transition curves), or Curve (edit by hand)"), api.type["enum"].ScriptParamType.Button,
				{ _("Straighten"), _("Smooth"), _("Ease"), _("Curve") }, (g_shape.mode or 1) - 1, function(i : integer) g_shape.mode = i + 1 end),
			tbChoice("ntools_shape_strength", _("Strength"), _("How far each node moves towards its neighbours"), api.type["enum"].ScriptParamType.Slider,
				pct, math.floor(clamp(g_shape.strength, 0, 1) * 100 + 0.5), function(i : integer) g_shape.strength = i / 100 end,
				function() : boolean return g_shape.mode == 2 end),
			tbChoice("ntools_shape_transition", _("Transition"), _("How much of the turn is made in the transition spirals (0 % = a plain arc)"), api.type["enum"].ScriptParamType.Slider,
				pct, math.floor(clamp(g_shape.transition or 0.5, 0, 1) * 100 + 0.5), function(i : integer) g_shape.transition = i / 100 end,
				function() : boolean return g_shape.mode == 3 end),
			tbAnarchy(),
		}, tbResetBuild(_("Apply"))),
	})
end

local function getArrangeLineDefinition(resName : ResName, _repo : ConstructionActionRepository, _params : table) : ConstructionDefinition
	return toolDefinition(resName, {
		icon = "arrange_line/ntools_arrange_line",
		name = _("Arrange on line (Network Tools)"),
		description = _("Spread the nodes of a stretch evenly on the straight line between its ends."),
		order = 800,
		recipe = arrange_line.ArrangeLineActionRecipe,
		params = concat({ tbAnarchy() }, tbResetBuild(_("Apply"))),
	})
end

local function getArrangeCircleDefinition(resName : ResName, _repo : ConstructionActionRepository, _params : table) : ConstructionDefinition
	return toolDefinition(resName, {
		icon = "arrange_circle/ntools_arrange_circle",
		name = _("Arrange on circle (Network Tools)"),
		description = _("Spread the nodes of a stretch evenly round a circle; drag the centre and rim handles to adjust it."),
		order = 900,
		recipe = arrange_circle.ArrangeCircleActionRecipe,
		params = concat({ tbAnarchy() }, tbResetBuild(_("Apply"))),
	})
end

local function getGenerateDefinition(resName : ResName, _repo : ConstructionActionRepository, _params : table) : ConstructionDefinition
	local SLIDER = api.type["enum"].ScriptParamType.Slider
	local function steps(lo : number, hi : number, step : number, unit : string) : {string}
		local out : {string} = {}
		for i = 0, math.floor((hi - lo) / step + 0.5) do out[i + 1] = string.format("%g", lo + i * step) .. unit end
		return out
	end
	local function idxOf(v : number, lo : number, step : number) : integer return math.floor((v - lo) / step + 0.5) end
	local notGrid = function() : boolean return g_gen.shape ~= 3 end
	local isGrid = function() : boolean return g_gen.shape == 3 end
	local isHelix = function() : boolean return g_gen.shape == 4 end
	-- helix grade: -8 .. +8 % in 0.5 % steps
	local grades : {string} = {}
	for i = 0, 32 do grades[i + 1] = string.format("%+.1f %%", -8 + i * 0.5) end
	return toolDefinition(resName, {
		icon = "generate/ntools_generate",
		name = _("Generate (Network Tools)"),
		description = _("Build a ring road, an oval, a street grid or a helix: click the ground, then drag its handles. Uses the road type picked in the Network Tools panel."),
		order = 1000,
		recipe = generate.GenerateActionRecipe,
		params = concat({
			-- the road / track type it builds (the panel's Network list - the build menu has no panel):
			-- the game's own picker over this year's types (the value: the picked type's id)
			{
				key = "ntools_gen_network",
				tooltip = _("Road / track type: what the shape is built as"),
				-- (no label, as Connect's pickers: a labelled picker drew one big tile)
				hideLabel = true,
				defaultIndex = 1, yearFrom = 0, yearTo = 0,
				location = api.type["enum"].ScriptParamLocation.Toolbar,
				getFilterObjectsFn = function() : {MenuCategoryUtil.FilterObject}, integer
					local objects : {MenuCategoryUtil.FilterObject} = {}
					local current = 1
					pcall(function()
						for __, o in ipairs(menu_category_util.getAvailableObjectsSorted(api.res.streetTemplateRep as ResTypeRep<integer, table>, api.engine.util.getYear())) do
							objects[#objects + 1] = o
							if o.id == g_networkId then current = #objects end
						end
					end)
					return objects, current
				end,
				resetOnDefinitionChange = false, resetOnCategoryChange = false, resetOnMenuClose = false,
				onChangeFn = function(v : number, paramsApi : ConstructionMenuParamsAPI, _o? : number)
					tbSeed(paramsApi)
					if v and v >= 0 then g_networkId = math.floor(v) end
				end,
			} as ConstructionMenuParam,
			tbChoice("ntools_gen_shape", _("Shape"), _("Circle, oval, grid or helix (a spiral that gains height)"), api.type["enum"].ScriptParamType.Button,
				{ _("Circle"), _("Oval"), _("Grid"), _("Helix") }, (g_gen.shape or 1) - 1, function(i : integer) g_gen.shape = i + 1 end),
			tbChoice("ntools_gen_turns", _("Turns"), _("How many times the helix goes round"), SLIDER, steps(0.25, 10, 0.25, ""),
				idxOf(g_gen.turns, 0.25, 0.25), function(i : integer) g_gen.turns = 0.25 + i * 0.25 end, isHelix),
			tbChoice("ntools_gen_grade", _("Grade"), _("Climb along the helix (negative: it goes down - a spiral tunnel)"), SLIDER, grades,
				idxOf(g_gen.grade, -8, 0.5), function(i : integer) g_gen.grade = -8 + i * 0.5 end, isHelix),
			tbChoice("ntools_gen_hand", _("Turning"), _("Which way the helix turns, seen from above"), api.type["enum"].ScriptParamType.Button,
				{ _("Left"), _("Right") }, g_gen.clockwise and 1 or 0, function(i : integer) g_gen.clockwise = i == 1 end, isHelix),
			tbChoice("ntools_gen_radius", _("Radius"), _("Circle radius / oval X radius"), SLIDER, steps(15, 1000, 5, " m"),
				idxOf(g_gen.radius, 15, 5), function(i : integer) g_gen.radius = 15 + i * 5 end, notGrid),
			tbChoice("ntools_gen_radius_y", _("Radius Y"), _("Oval Y radius"), SLIDER, steps(10, 1000, 5, " m"),
				idxOf(g_gen.radiusY, 10, 5), function(i : integer) g_gen.radiusY = 10 + i * 5 end,
				function() : boolean return g_gen.shape == 2 end),
			tbChoice("ntools_gen_cols", _("Columns"), _("Blocks across"), SLIDER, steps(1, 10, 1, ""),
				idxOf(g_gen.cols, 1, 1), function(i : integer) g_gen.cols = 1 + i end, isGrid),
			tbChoice("ntools_gen_rows", _("Rows"), _("Blocks down"), SLIDER, steps(1, 10, 1, ""),
				idxOf(g_gen.rows, 1, 1), function(i : integer) g_gen.rows = 1 + i end, isGrid),
			tbChoice("ntools_gen_spacing", _("Block"), _("Block size"), SLIDER, steps(20, 300, 5, " m"),
				idxOf(g_gen.spacing, 20, 5), function(i : integer) g_gen.spacing = 20 + i * 5 end, isGrid),
			tbChoice("ntools_gen_rotation", _("Rotation"), _("Turn it (or drag the rotation handle)"), SLIDER, steps(0, 355, 5, "°"),
				idxOf(g_gen.rotation, 0, 5), function(i : integer) g_gen.rotation = i * 5 end),
			tbAnarchy(),
		}, tbResetBuild(_("Build it"))),
	})
end

	local function getSignalsDefinition(resName : ResName, _repo : ConstructionActionRepository, _params : table) : ConstructionDefinition
		local labels : {string} = {}
		for i = 0, 38 do labels[i + 1] = tostring(100 + i * 50) .. " m" end
		local blockLabels : {string} = {}
		for i = 1, 20 do blockLabels[i] = tostring(i) end
		return toolDefinition(resName, {
			icon = "signals/ntools_signals",
			name = _("Auto-signal (Network Tools)"),
			description = _("Place block signals in equal blocks along a stretch of track, and at each switch."),
			order = 1100,
			recipe = signals.SignalsActionRecipe,
			params = concat({
				tbChoice("ntools_sig_spacing_type", _("Block spacing"), _("Equal blocks / a fixed interval / by line speed (Spacing = a block at 100 km/h) / a set number of blocks"),
					api.type["enum"].ScriptParamType.Button, { _("Equal"), _("Fixed"), _("Line speed"), _("Count") }, (g_sig.spacingType or 1) - 1,
					function(i : integer) g_sig.spacingType = i + 1 end),
				tbChoice("ntools_sig_spacing", _("Spacing"), _("Distance between block signals (Line speed: a block's length at 100 km/h)"), api.type["enum"].ScriptParamType.Slider,
					labels, math.floor(clamp((g_sig.spacing - 100) / 50, 0, 38) + 0.5), function(i : integer) g_sig.spacing = 100 + i * 50 end),
				tbChoice("ntools_sig_blocks", _("Blocks"), _("Count: equal blocks between each pair of signals that stand anyway"), api.type["enum"].ScriptParamType.Slider,
					blockLabels, (g_sig.blockCount or 3) - 1, function(i : integer) g_sig.blockCount = i + 1 end),
				tbCheck("ntools_sig_twoway", _("Two-way track"), _("Signal for both ways of travel (never one-way signals)"), g_sig.twoWay == true,
					function(v : boolean) g_sig.twoWay = v end),
				tbChoice("ntools_sig_existing", _("Signals already there"), _("Keep and plan around them / replace the ones facing the way signalled / ignore them"),
					api.type["enum"].ScriptParamType.Button, { _("Keep"), _("Replace"), _("Ignore") }, (g_sig.existingMode or 1) - 1,
					function(i : integer) g_sig.existingMode = i + 1 end),
				tbCheck("ntools_sig_oneway", _("One-way signals"), _("Trains may pass only in the direction of travel"), g_sig.oneWay == true,
					function(v : boolean) g_sig.oneWay = v end),
				tbCheck("ntools_sig_switches", _("At switches"), _("Also a signal at each switch: before it where the track splits, past it where tracks join"), g_sig.beforeSwitches ~= false,
					function(v : boolean) g_sig.beforeSwitches = v end),
				tbCheck("ntools_sig_remove", _("Remove signals"), _("Remove the signals on the stretch instead of placing them"), g_sig.removeMode == true,
					function(v : boolean) g_sig.removeMode = v end),
				tbCheck("ntools_sig_station", _("Station mode"), _("Exit signals at the platform ends, equal blocks between stations (Spacing = target block length)"), g_sig.stationMode == true,
					function(v : boolean) g_sig.stationMode = v end),
				tbCheck("ntools_sig_beside", _("Tracks alongside too"), _("Multi-track lines: also the tracks beside the stretch"), g_sig.besideTracks ~= false,
					function(v : boolean) g_sig.besideTracks = v end),
				tbChoice("ntools_sig_pattern", _("Directions"), _("Directions across the tracks (click a signal marker to turn one track)"), api.type["enum"].ScriptParamType.Button,
					{ _("Opposite"), _("Same"), _("Alternate"), _("Pairs") }, (g_sig.pattern or 1) - 1,
					function(i : integer) g_sig.pattern = i + 1; g_sig.besideSameWay = false end),
				tbCheck("ntools_sig_reverse", _("Against the selection"), _("Trains travel from the last segment you picked towards the first"), g_sig.reverse == true,
					function(v : boolean) g_sig.reverse = v end),
				tbAnarchy(),
			}, tbResetBuild(_("Place the signals"))),
		})
	end

	-- The rail tools (the panel's Rail tab). Their options as the panel's rows; on console the build
	-- menu is the only way in. (Branch's types are separate entries here: Junction, and Siding whose
	-- End: Rejoin makes it a passing loop - the panel's Siding / Rejoin with drag handles)
	local BUTTON = api.type["enum"].ScriptParamType.Button
	local SLIDER = api.type["enum"].ScriptParamType.Slider
	local function numbers(lo : integer, hi : integer, step : integer, unit : string) : {string}
		local out : {string} = {}
		for v = lo, hi, step do out[#out + 1] = tostring(v) .. unit end
		return out
	end
	local SPEEDS = { 0, 40, 60, 80, 100, 120 }
	local SPEED_LABELS = { _("Free"), "40", "60", "80", "100", "120" }
	local function speedIndex(v : number) : integer
		for i, s in ipairs(SPEEDS) do if s == math.floor(v or 0) then return i - 1 end end
		return 0
	end

	local function getUpgradeDefinition(resName : ResName, _repo : ConstructionActionRepository, _params : table) : ConstructionDefinition
		local up = railTools.upgrade.opts as {string : any}
		-- the track types this year (Keep: each segment's own)
		local types : {NetworkOption} = {}
		pcall(function()
			for __, n in ipairs(listNetworks()) do if n.isTrack then types[#types + 1] = n end end
			table.sort(types, function(x : NetworkOption, y : NetworkOption) : boolean return x.name < y.name end)
		end)
		local labels : {string} = { _("Keep each segment's type") }
		local current = 0
		for i, n in ipairs(types) do
			labels[i + 1] = n.name
			if n.id == up.trackType then current = i end
		end
		return toolDefinition(resName, {
			icon = "upgrade/ntools_upgrade",
			name = _("Track upgrade (Network Tools)"),
			description = _("Change a stretch of track to another type, or add / remove its catenary - signals stay. Click a track segment, then one further along."),
			order = 1200,
			recipe = (railTools.upgrade.UpgradeActionRecipe as function(ConstructionCustomActionParams<any>) : TreeNodeId),
			params = concat({
				tbChoice("ntools_up_type", _("Type"), _("The track type the stretch becomes"), api.type["enum"].ScriptParamType.ComboBox,
					labels, current, function(i : integer) up.trackType = types[i] and types[i].id or 0 end),
				tbChoice("ntools_up_catenary", _("Catenary"), _("Keep it as it is / electrify / remove it"), BUTTON,
					{ _("Keep"), _("Electrify"), _("Remove") }, ((up.catenary as integer) or 1) - 1, function(i : integer) up.catenary = i + 1 end),
				tbAnarchy(),
			}, tbResetBuild(_("Upgrade the track"))),
		})
	end

	local function getCrossoverDefinition(resName : ResName, _repo : ConstructionActionRepository, _params : table) : ConstructionDefinition
		local cx = railTools.crossover.opts as {string : any}
		return toolDefinition(resName, {
			icon = "crossover/ntools_crossover",
			name = _("Crossover (Network Tools)"),
			description = _("Join tracks side by side with pairs of switches. Click a track where the crossovers start, then each track beside it."),
			order = 1300,
			recipe = (railTools.crossover.CrossoverActionRecipe as function(ConstructionCustomActionParams<any>) : TreeNodeId),
			params = concat({
				tbChoice("ntools_cx_kind", _("Kind"), _("Single: one pair of switches; Scissors: two crossing in the middle"), BUTTON,
					{ _("Single"), _("Scissors") }, ((cx.kind as integer) or 1) - 1, function(i : integer) cx.kind = i + 1 end),
				tbChoice("ntools_cx_dir", _("Direction"), _("Along the first track's direction from the click, or against it"), BUTTON,
					{ _("Ahead"), _("Behind") }, ((cx.dir as integer) or 1) - 1, function(i : integer) cx.dir = i + 1 end),
				tbChoice("ntools_cx_length", _("Length"), _("How far along the tracks the crossover runs"), SLIDER,
					numbers(20, 200, 5, " m"), math.floor((((cx.length as number) or 60) - 20) / 5 + 0.5), function(i : integer) cx.length = 20 + i * 5 end),
				tbChoice("ntools_cx_arrange", _("Arrange"), _("More than two tracks: staggered (a train can cross them all), or side by side"), BUTTON,
					{ _("Staggered"), _("Side by side") }, ((cx.arrange as integer) or 1) - 1, function(i : integer) cx.arrange = i + 1 end),
				tbAnarchy(),
			}, tbResetBuild(_("Build the crossover"))),
		})
	end

	local function getJunctionDefinition(resName : ResName, _repo : ConstructionActionRepository, _params : table) : ConstructionDefinition
		local jn = railTools.junction.opts as {string : any}
		return toolDefinition(resName, {
			icon = "junction/ntools_junction",
			name = _("Junction (Network Tools)"),
			description = _("A switch and a curving branch: click a track where the branch leaves it, then move the handle - onto another track to join it there. Click the tracks beside it to branch them too."),
			order = 1400,
			recipe = (railTools.junction.JunctionActionRecipe as function(ConstructionCustomActionParams<any>) : TreeNodeId),
			params = concat({
				tbChoice("ntools_jn_side", _("Start side"), _("Which side of the track a click puts the handle"), BUTTON,
					{ _("Right"), _("Left") }, ((jn.side as integer) or 1) - 1, function(i : integer) jn.side = i + 1 end),
				tbChoice("ntools_jn_speed", _("Turnout speed"), _("Free: the handle shapes the curve; a speed: the turnout for it, then straight on"), BUTTON,
					SPEED_LABELS, speedIndex(jn.speed as number), function(i : integer) jn.speed = SPEEDS[i + 1] or 0 end),
				tbChoice("ntools_jn_radius", _("Warn below"), _("The tooltip warns under this radius; also the tightest curve of a branch dropped on a track"), SLIDER,
					numbers(100, 1000, 50, " m"), math.floor((((jn.minRadius as number) or 300) - 100) / 50 + 0.5), function(i : integer) jn.minRadius = 100 + i * 50 end),
				tbCheck("ntools_jn_slip", _("Double-slip switches"), _("Where parallel branches cross the other tracks: double-slip switches"), jn.doubleSlip == true,
					function(v : boolean) jn.doubleSlip = v end),
				tbCheck("ntools_jn_fan", _("Feed every track"), _("Dropped on a station's track end: a branch to every open track at that end"), jn.fanStation ~= false,
					function(v : boolean) jn.fanStation = v end),
				tbAnarchy(),
			}, tbResetBuild(_("Build the junction"))),
		})
	end

	local function getSidingDefinition(resName : ResName, _repo : ConstructionActionRepository, _params : table) : ConstructionDefinition
		local sd = railTools.siding.opts as {string : any}
		local free = function() : boolean return ((sd.speed as number) or 0) == 0 end
		local feed = function() : boolean return sd.feedAll ~= false end
		return toolDefinition(resName, {
			icon = "siding/ntools_siding",
			name = _("Siding / passing loop (Network Tools)"),
			description = _("Track beside the line: click a track where it leaves, then move the handle along for its length, across for the other side. End: Dead end makes a siding, Rejoin a passing loop."),
			order = 1500,
			recipe = (railTools.siding.SidingActionRecipe as function(ConstructionCustomActionParams<any>) : TreeNodeId),
			params = concat({
				tbChoice("ntools_sd_end", _("End"), _("Dead end: a siding; Rejoin: a passing loop back onto the line"), BUTTON,
					{ _("Dead end"), _("Rejoin") }, sd.rejoin == true and 1 or 0, function(i : integer) sd.rejoin = i == 1 end),
				tbChoice("ntools_sd_side", _("Start side"), _("Right / left of the track, or both sides"), BUTTON,
					{ _("Right"), _("Left"), _("Both") }, sd.both == true and 2 or (((sd.side as integer) or 1) - 1),
					function(i : integer) sd.both = i == 2; if i < 2 then sd.side = i + 1 end end),
				tbChoice("ntools_sd_count", _("Sidings"), _("Per side: each leaves the one before, like a yard ladder"), SLIDER,
					numbers(1, 6, 1, ""), ((sd.count as integer) or 1) - 1, function(i : integer) sd.count = i + 1 end),
				tbChoice("ntools_sd_spacing", _("Spacing"), _("Distance between the track centres"), SLIDER,
					numbers(4, 15, 1, " m"), math.floor(((sd.spacing as number) or 5) - 4 + 0.5), function(i : integer) sd.spacing = 4 + i end),
				tbChoice("ntools_sd_alongside", _("Alongside"), _("Tracks running alongside: off, the outer ones, a bundle, or across"), BUTTON,
					{ _("Off"), _("Outer"), _("Bundle"), _("Across") }, (sd.alongside as integer) or 0, function(i : integer) sd.alongside = i end),
				tbChoice("ntools_sd_speed", _("Turnout speed"), _("Free: the Switch radius sets the curves"), BUTTON,
					SPEED_LABELS, speedIndex(sd.speed as number), function(i : integer) sd.speed = SPEEDS[i + 1] or 0 end),
				tbChoice("ntools_sd_radius", _("Switch radius"), _("How wide the switch curves are (Turnout speed: Free)"), SLIDER,
					numbers(100, 600, 50, " m"), math.floor((((sd.radius as number) or 300) - 100) / 50 + 0.5), function(i : integer) sd.radius = 100 + i * 50 end, free),
				tbCheck("ntools_sd_feed", _("Feed every track"), _("Dead end dropped on a station's track end: a siding to every open track there"), sd.feedAll ~= false,
					function(v : boolean) sd.feedAll = v end),
				tbChoice("ntools_sd_feed_style", _("Feed style"), _("Nested, a yard ladder, or a diagonal throat"), BUTTON,
					{ _("Nested"), _("Ladder"), _("Diagonal") }, ((sd.feedStyle as integer) or 1) - 1, function(i : integer) sd.feedStyle = i + 1 end, feed),
				tbAnarchy(),
			}, tbResetBuild(_("Build it"))),
		})
	end

	return {
		getUpgradeDefinition = getUpgradeDefinition,
		getCrossoverDefinition = getCrossoverDefinition,
		getJunctionDefinition = getJunctionDefinition,
		getSidingDefinition = getSidingDefinition,
		getSignalsDefinition = getSignalsDefinition,
		getShapeDefinition = getShapeDefinition,
		getArrangeLineDefinition = getArrangeLineDefinition,
		getArrangeCircleDefinition = getArrangeCircleDefinition,
		getGenerateDefinition = getGenerateDefinition,
		getParallelDefinition = getParallelDefinition,
		getReverseDefinition = getReverseDefinition,
		getAddNodeDefinition = getAddNodeDefinition,
		getRemoveNodeDefinition = getRemoveNodeDefinition,
		getSlopeDefinition = getSlopeDefinition,
	}
end
local toolDefs = makeToolDefinitions()

	return {
		togglePanel = togglePanel,
		isPanelOpen = isPanelOpen,
		getUpgradeDefinition = toolDefs.getUpgradeDefinition,
		getCrossoverDefinition = toolDefs.getCrossoverDefinition,
		getJunctionDefinition = toolDefs.getJunctionDefinition,
		getSidingDefinition = toolDefs.getSidingDefinition,
		getSignalsDefinition = toolDefs.getSignalsDefinition,
		getShapeDefinition = toolDefs.getShapeDefinition,
		getArrangeLineDefinition = toolDefs.getArrangeLineDefinition,
		getArrangeCircleDefinition = toolDefs.getArrangeCircleDefinition,
		getGenerateDefinition = toolDefs.getGenerateDefinition,
		getParallelDefinition = toolDefs.getParallelDefinition,
		getReverseDefinition = toolDefs.getReverseDefinition,
		getAddNodeDefinition = toolDefs.getAddNodeDefinition,
		getRemoveNodeDefinition = toolDefs.getRemoveNodeDefinition,
		getSlopeDefinition = toolDefs.getSlopeDefinition,
	}
end
local ui = makeUi()

local Ret = {
	getUpgradeDefinition = ui.getUpgradeDefinition,
	getCrossoverDefinition = ui.getCrossoverDefinition,
	getJunctionDefinition = ui.getJunctionDefinition,
	getSidingDefinition = ui.getSidingDefinition,
	getSignalsDefinition = ui.getSignalsDefinition,
	getShapeDefinition = ui.getShapeDefinition,
	getArrangeLineDefinition = ui.getArrangeLineDefinition,
	getArrangeCircleDefinition = ui.getArrangeCircleDefinition,
	getGenerateDefinition = ui.getGenerateDefinition,
	getParallelDefinition = ui.getParallelDefinition,
	getReverseDefinition = ui.getReverseDefinition,
	getAddNodeDefinition = ui.getAddNodeDefinition,
	getRemoveNodeDefinition = ui.getRemoveNodeDefinition,
	getSlopeDefinition = ui.getSlopeDefinition,
	-- used by the toolbar button (gui/ntools_toolbar.script.tl)
	togglePanel = ui.togglePanel,
	isPanelOpen = ui.isPanelOpen,
	getDefinition = function(constructionDefinition : ResName, _repository : ConstructionActionRepository, _params : table) : ConstructionDefinition
		-- Use the "Network Tools" categories when they are loaded; otherwise (e.g. new files not yet in the
		-- game's file index until a restart) fall back to the standard Road / Rail Tools lists.
		local hasOwnCategories = false
		pcall(function()
			for _, id in ipairs(api.res.genericRep.getAllOfType("menu_category")) do
				local res = api.res.genericRep.get(id)
				local data = res and res.data as ConstructionMenuCategory
				if data and data.category == "ntools_road" then
					hasOwnCategories = true
				end
			end
		end)
		return {
			resName = constructionDefinition,
			icon = { icon = resolve("ntools_connect.tga") },
			previewIcon = { icon = resolve("ntools_connect_preview.tga") },
			name = _("Connect (Network Tools)"),
			description = _("Join two road or track nodes, like Network Multitool's connection modes. Connection: an arc from each road joined by a straight, with draggable circles. Loop: one circle tangent to both roads, drag its centre to resize or switch corner/loop. Curve: a smooth curve. Straight: a direct line."),
			action = "ACTION_CUSTOM",
			availability = {
				yearFrom = 0,
				yearTo = 0,
			},
			params = toolbarParams(),
			hudIcons = construction_react_util.getStreetToolsHudIcons("ROAD"),
			customAction = {
				recipe = ConnectActionRecipe as Recipe<ConstructionCustomActionParams<any>>,
				customParam = nil,
			},
			-- (Build menu tab off in Settings: in no tab at all)
			menuCategory = shared.opts.buildMenu == false and { categories = {} } or {
				categories = {
					{ category = hasOwnCategories and "ntools_road" or "roads_tools", order = hasOwnCategories and 100 or 900 },
					{ category = hasOwnCategories and "ntools_rail" or "rail_tools", order = hasOwnCategories and 100 or 900 },
				},
			},
		}
	end,
}

return Ret
