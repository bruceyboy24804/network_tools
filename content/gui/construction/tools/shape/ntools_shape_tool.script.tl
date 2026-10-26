-- Network Tools: Smooth / Straighten (modelled on the curve transforms of Network Tools for Cities:
-- Skylines 2). Select a stretch, then:
--   Straighten - the nodes move onto the straight line between the two ends, keeping their
--                relative spacing; the segments become straight
--   Smooth     - each node in between moves part of the way (Strength) towards the midpoint of its
--                neighbours, and the curves become a smooth spline through the nodes - the kinks
--                that cost trains speed go
--   Curve      - edit by hand, like Connect's Curve mode: every node in between gets a centre handle
--                (move it) and a front / back handle (they stay in line: turn the road there; each
--                one's length: how far the curve swings on its side); the two ends keep their
--                direction (the road goes on there), their handle sets only how far the curve swings
--   Ease       - the bend becomes a railway-style eased curve: straight, transition spiral (the
--                curvature grows evenly), circular arc, spiral back to straight. It fills the corner the
--                two end directions make, as wide as the ends allow; Transition = how much of the turn
--                is spiral (0 % = a plain arc, 100 % = all spiral). The nodes slide onto it keeping
--                their spacing - more nodes follow it closer (Add node first on a short stretch)
-- Heights stay as they are; the climb of each segment is spread evenly along it.
-- The selection, preview, handles and proposal come from the shared reshape engine.
-- Each mode lives in its own folder: shape/<mode>/ntools_shape_<mode>.script.tl.

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
	edgePiece : function(e : Engine.Component.BaseEdge) : Piece
	length : function(pc : Piece) : number
end
local geom = require "network_tools_1::/gui/construction/tools/shared/ntools_geom.script.tl" as Geom

local record ChainLink
	edge : Engine.Entity
	fwd : boolean
end
local record Curve
	t0 : P3
	t1 : P3
end
local record Handle
	x : number
	y : number
	z : number
end
local record Canvas
	line : function(x0 : number, y0 : number, z0 : number, x1 : number, y1 : number, z1 : number, color : Vec4f, width : number)
	circle : function(cx : number, cy : number, z : number, r : number, color : Vec4f, width : number)
end
local record Shape
	moves : {Engine.Entity : P3}
	curves : {Engine.Entity : Curve}
	why : string
	info : string
	handles : {Handle}
	onDrag : function(i : integer, x : number, y : number)
	onPress : function(i : integer)
	draw : function(c : Canvas)
end
local record Spec
	recipeName : string
	hint : string
	buildHint : string
	minLinks : integer
	compute : function(chain : {ChainLink}, nodes : {Engine.Entity}) : Shape
	key : function() : string
end
local record Reshape
	create : function(spec : Spec) : function(ConstructionCustomActionParams<any>) : TreeNodeId
	linkCurve : function(link : ChainLink, t0 : P3, t1 : P3) : Curve
	gradedTangent : function(dx : number, dy : number, len : number, z0 : number, z1 : number, hChord : number) : P3
end
local reshape = require "network_tools_1::/gui/construction/tools/shared/ntools_reshape.script.tl" as Reshape

do ((require "network_tools_1::/gui/construction/tools/shared/ntools_debug.script.tl" as {string : any}).log as function(string))("[network_tools] smooth / straighten tool script loaded (v7: modes split into shape/<mode>/)") end

local MODE_STRAIGHTEN, MODE_SMOOTH, MODE_EASE, MODE_CURVE = 1, 2, 3, 4

local record Options
	mode : integer
	strength : number     -- Smooth: 0 .. 1, how far nodes move towards their neighbours' midpoint
	transition : number   -- Ease: 0 .. 1, the share of the turn made in the spirals
	curveMirror : boolean -- Curve: a node's two handles always as long as each other
	curveFree : boolean   -- Curve: a node's two handles turn on their own (a corner) instead of in line
	curveReset : integer  -- Curve: the panel's Reset edits counts this up
	-- Curve: the selected node (the last one whose handle was dragged) for the panel, and its height
	-- change: we set both when the selection changes, the panel's slider writes curveHeight
	curveSelLabel : string
	curveHeight : number
end
local opts : Options = { mode = MODE_STRAIGHTEN, strength = 0.5, transition = 0.5, curveMirror = false, curveFree = false, curveReset = 0 }

local function getEdge(entity : Engine.Entity) : Engine.Component.BaseEdge
	if not entity or entity < 0 or not api.engine.entityExists(entity) then return nil end
	return api.engine.getComponent(entity, api.type.ComponentType.BASE_EDGE) as Engine.Component.BaseEdge
end

local function nodePos(n : Engine.Entity) : P3
	local node = api.engine.getComponent(n, api.type.ComponentType.BASE_NODE) as Engine.Component.BaseNode
	return geom.p3(node.position.x, node.position.y, node.position.z)
end

local function hdist(a : P3, b : P3) : number
	return math.sqrt((b.x - a.x) ^ 2 + (b.y - a.y) ^ 2)
end

-- the stretch's start / end direction in plan (the curve leaving the first node, entering the last)
local function endDirections(chain : {ChainLink}) : P3, P3
	local first, last = getEdge(chain[1].edge), getEdge(chain[#chain].edge)
	local pf, pl = geom.edgePiece(first), geom.edgePiece(last)
	local d0 = chain[1].fwd and pf.t0 or geom.p3(-pf.t1.x, -pf.t1.y, -pf.t1.z)
	local d1 = chain[#chain].fwd and pl.t1 or geom.p3(-pl.t0.x, -pl.t0.y, -pl.t0.z)
	return d0, d1
end

-- The modes, each set up with the helpers above
local record Placer
	place : function(chain : {ChainLink}, P : {P3}, s : {number}) : {P3}, {P3}
end
local record EaseMode
	computeEase : function(chain : {ChainLink}, nodes : {Engine.Entity}, P : {P3}, s : {number}) : Shape
end
local record CurveState
	version : integer
end
local record CurveMode
	state : CurveState
	computeCurve : function(chain : {ChainLink}, nodes : {Engine.Entity}, P : {P3}) : Shape
end
local modeCtx : {string : any} = {
	opts = opts, p3 = geom.p3, edgePiece = geom.edgePiece, getEdge = getEdge, hdist = hdist,
	endDirections = endDirections, linkCurve = reshape.linkCurve, gradedTangent = reshape.gradedTangent,
}
local straightenMode = (require "network_tools_1::/gui/construction/tools/shape/straighten/ntools_shape_straighten.script.tl" as function({string : any}) : Placer)(modeCtx)
local smoothMode = (require "network_tools_1::/gui/construction/tools/shape/smooth/ntools_shape_smooth.script.tl" as function({string : any}) : Placer)(modeCtx)
local easeMode = (require "network_tools_1::/gui/construction/tools/shape/ease/ntools_shape_ease.script.tl" as function({string : any}) : EaseMode)(modeCtx)
local curveMode = (require "network_tools_1::/gui/construction/tools/shape/curve/ntools_shape_curve.script.tl" as function({string : any}) : CurveMode)(modeCtx)

local function compute(chain : {ChainLink}, nodes : {Engine.Entity}) : Shape
	local n = #nodes
	if nodes[1] == nodes[n] then
		return { why = _("The stretch is a loop - pick one that has two ends") }
	end
	local P : {P3} = {}
	for k, nd in ipairs(nodes) do P[k] = nodePos(nd) end
	-- distance along the road to each node
	local s : {number} = { 0 }
	for i, l in ipairs(chain) do s[i + 1] = s[i] + geom.length(geom.edgePiece(getEdge(l.edge))) end
	local S = s[n]
	if S < 1 then return { why = _("The stretch is too short") } end
	if opts.mode == MODE_EASE then return easeMode.computeEase(chain, nodes, P, s) end
	if opts.mode == MODE_CURVE then return curveMode.computeCurve(chain, nodes, P) end

	-- Straighten / Smooth: new plan positions (heights kept) and the direction through each node
	local Q, dirs = (opts.mode == MODE_STRAIGHTEN and straightenMode or smoothMode).place(chain, P, s)

	local moves : {Engine.Entity : P3} = {}
	local maxMove = 0.0
	for k = 2, n - 1 do
		moves[nodes[k]] = Q[k]
		maxMove = math.max(maxMove, hdist(P[k], Q[k]))
	end
	local curves : {Engine.Entity : Curve} = {}
	for i, l in ipairs(chain) do
		local a, b = Q[i], Q[i + 1]
		local h = hdist(a, b)
		local t0 = reshape.gradedTangent(dirs[i].x, dirs[i].y, h, a.z, b.z, h)
		local t1 = reshape.gradedTangent(dirs[i + 1].x, dirs[i + 1].y, h, a.z, b.z, h)
		curves[l.edge] = reshape.linkCurve(l, t0, t1)
	end
	return {
		moves = moves,
		curves = curves,
		info = string.format("%s: %.1f m", _("Largest node move"), maxMove),
	}
end

local ShapeActionRecipe = reshape.create({
	recipeName = "NtoolsShapeAction",
	hint = _("Click a road or track segment to start the stretch"),
	buildHint = _("Click more segments to extend, the first / last to remove. Press Build to apply"),
	minLinks = 1,
	compute = compute,
	-- (Curve: every handle drag changes the version - a re-render and a new preview)
	key = function() : string return tostring(opts.mode) .. "/" .. tostring(opts.strength) .. "/" .. tostring(opts.transition)
		.. "/" .. tostring(curveMode.state.version) .. "/" .. tostring(opts.curveReset) .. "/" .. tostring(opts.curveHeight) end,
})

return {
	opts = opts,
	ShapeActionRecipe = ShapeActionRecipe,
}
