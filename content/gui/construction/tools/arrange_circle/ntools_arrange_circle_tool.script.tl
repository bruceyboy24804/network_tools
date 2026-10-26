-- Network Tools: Arrange on circle (modelled on Network Multitool's ArrangeCircle for Cities:
-- Skylines 1 and the circle generator of Network Tools for Cities: Skylines 2).
-- Select a stretch (or a closed loop): its nodes are spread evenly round a circle - the arc between
-- the stretch's ends, or the full ring for a loop - in their existing order, and every segment
-- becomes an exact circular arc. The circle starts as the best fit to the nodes; drag the centre
-- handle to move it and the rim handle to change the radius. Heights stay as they are.

local record P3
	x : number
	y : number
	z : number
end
local record Geom
	p3 : function(x : number, y : number, z : number) : P3
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
	handle : function(h : Handle, state : integer)
	node : function() : TreeNodeId
end
local record Shape
	moves : {Engine.Entity : P3}
	curves : {Engine.Entity : Curve}
	why : string
	info : string
	handles : {Handle}
	onDrag : function(i : integer, x : number, y : number)
	draw : function(c : Canvas)
	tags : {any}
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
end
local reshape = require "network_tools_1::/gui/construction/tools/shared/ntools_reshape.script.tl" as Reshape

local record Handles
	colors : {string : Vec4f}
end
local handles = require "network_tools_1::/gui/construction/tools/shared/ntools_handles.script.tl" as Handles

-- the tags' icons (shared/ntools_labels)
local icons = (require "network_tools_1::/gui/construction/tools/shared/ntools_labels.script.tl" as {string : any}).icons as {string : string}

do ((require "network_tools_1::/gui/construction/tools/shared/ntools_debug.script.tl" as {string : any}).log as function(string))("[network_tools] arrange on circle tool script loaded (v1)") end

local MIN_RADIUS, MAX_RADIUS = 5, 2000

-- the circle the handles have set; reset to the best fit whenever the stretch changes
local record Circle
	sig : string          -- the stretch it belongs to
	cx : number
	cy : number
	r : number
end
local g_circle : Circle = { sig = "" }

local function nodePos(n : Engine.Entity) : P3
	local node = api.engine.getComponent(n, api.type.ComponentType.BASE_NODE) as Engine.Component.BaseNode
	return geom.p3(node.position.x, node.position.y, node.position.z)
end

local function wrap(a : number) : number
	while a > math.pi do a = a - 2 * math.pi end
	while a < -math.pi do a = a + 2 * math.pi end
	return a
end

local function compute(chain : {ChainLink}, nodes : {Engine.Entity}) : Shape
	local closed = nodes[1] == nodes[#nodes]
	-- the distinct nodes in order (a loop's last node is its first again)
	local count = closed and #nodes - 1 or #nodes
	if count < 3 then return { why = _("Select at least two segments (three nodes)") } end
	local P : {P3} = {}
	for k = 1, count do P[k] = nodePos(nodes[k]) end

	-- best-fit circle for a new stretch: centroid and mean distance
	local sig = ""
	for _, l in ipairs(chain) do sig = sig .. tostring(l.edge) .. "," end
	if g_circle.sig ~= sig then
		local cx, cy = 0.0, 0.0
		for k = 1, count do cx, cy = cx + P[k].x, cy + P[k].y end
		cx, cy = cx / count, cy / count
		local r = 0.0
		for k = 1, count do r = r + math.sqrt((P[k].x - cx) ^ 2 + (P[k].y - cy) ^ 2) end
		g_circle = { sig = sig, cx = cx, cy = cy, r = math.max(MIN_RADIUS, r / count) }
	end
	local cx, cy, r = g_circle.cx, g_circle.cy, g_circle.r

	-- the nodes' angles round the centre, and the sweep they cover in their own order
	local ang : {number} = {}
	for k = 1, count do ang[k] = math.atan2(P[k].y - cy, P[k].x - cx) end
	local sweep = 0.0
	for k = 2, count do sweep = sweep + wrap(ang[k] - ang[k - 1]) end
	if closed then
		sweep = (sweep + wrap(ang[1] - ang[count])) >= 0 and 2 * math.pi or -2 * math.pi
	end
	if math.abs(sweep) < 0.05 then return { why = _("The nodes don't go round the circle - move the centre") } end
	local steps = closed and count or count - 1
	local step = sweep / steps              -- angle between neighbouring nodes
	local dir = step >= 0 and 1 or -1

	local Q : {P3} = {}
	local moves : {Engine.Entity : P3} = {}
	for k = 1, count do
		local a = ang[1] + step * (k - 1)
		Q[k] = geom.p3(cx + r * math.cos(a), cy + r * math.sin(a), P[k].z)
		moves[nodes[k]] = Q[k]
	end
	if closed then Q[count + 1] = Q[1] end

	-- each segment an exact arc: Hermite tangent length 4 * tan(theta / 4) * r, perpendicular to
	-- the radius; the climb spread evenly along it
	local tl = 4 * math.tan(math.abs(step) / 4) * r
	local arcLen = math.abs(step) * r
	local curves : {Engine.Entity : Curve} = {}
	for i, l in ipairs(chain) do
		local a0 = ang[1] + step * (i - 1)
		local a1 = a0 + step
		local z0, z1 = Q[i].z, Q[i + 1].z
		local g = arcLen > 0.01 and (z1 - z0) / arcLen or 0
		local t0 = geom.p3(-math.sin(a0) * dir * tl, math.cos(a0) * dir * tl, g * tl)
		local t1 = geom.p3(-math.sin(a1) * dir * tl, math.cos(a1) * dir * tl, g * tl)
		curves[l.edge] = reshape.linkCurve(l, t0, t1)
	end

	-- a tag at the centre: the radius and the arc; on hover the spacing along the arc
	local zMid = 0.0
	for k = 1, count do zMid = zMid + P[k].z end
	zMid = zMid / count
	pcall(function() zMid = api.engine.terrain.getHeightAt(api.type.Vec2f.new(cx, cy)) end)
	local tags : {any} = { {
		x = cx, y = cy, z = zMid,
		rows = {
			{ icon = icons.radius, text = string.format("R %.1f m", r) },
			{ icon = icons.angle, text = string.format("%.0f°", math.abs(sweep) * 180 / math.pi) },
		},
		detail = { { text = string.format("%s %.1f m", _("Spacing"), arcLen) } },
	} }

	-- handles: 1 = centre, 2 = on the rim at the middle of the arc
	local am = ang[1] + sweep / 2
	local hs : {Handle} = {
		{ x = cx, y = cy, z = nil },
		{ x = cx + r * math.cos(am), y = cy + r * math.sin(am), z = nil },
	}
	return {
		moves = moves,
		curves = curves,
		handles = hs,
		onDrag = function(i : integer, x : number, y : number)
			if i == 1 then
				g_circle.cx, g_circle.cy = x, y
			else
				local nr = math.sqrt((x - g_circle.cx) ^ 2 + (y - g_circle.cy) ^ 2)
				g_circle.r = math.max(MIN_RADIUS, math.min(MAX_RADIUS, math.floor(nr * 2 + 0.5) / 2))
			end
		end,
		draw = function(c : Canvas)
			c.circle(cx, cy, nil, r, handles.colors.guide, 0.6)
			c.line(cx, cy, nil, hs[2].x, hs[2].y, nil, handles.colors.guide, 0.6)
		end,
		info = string.format("%s: %.1f m   %s: %.0f°", _("Radius"), r, _("Arc"), math.abs(sweep) * 180 / math.pi),
		tags = tags,
	}
end

local ArrangeCircleActionRecipe = reshape.create({
	recipeName = "NtoolsArrangeCircleAction",
	hint = _("Click a road or track segment to start the stretch (or select a closed loop)"),
	buildHint = _("Drag the centre / rim handles to adjust the circle. Press Build to apply"),
	minLinks = 2,
	compute = compute,
	key = function() : string
		return string.format("%.2f/%.2f/%.2f", g_circle.cx or 0, g_circle.cy or 0, g_circle.r or 0)
	end,
})

return {
	ArrangeCircleActionRecipe = ArrangeCircleActionRecipe,
}
