-- Network Tools: Arrange on line (modelled on Network Multitool's ArrangeLine for Cities: Skylines 1).
-- Select a stretch: the nodes between its two ends are spread at equal distances along the straight
-- line between them, and the segments become straight. Heights stay as they are.
-- (Smooth / Straighten's Straighten keeps the nodes' relative spacing instead.)

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
local record Shape
	moves : {Engine.Entity : P3}
	curves : {Engine.Entity : Curve}
	why : string
	info : string
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
	gradedTangent : function(dx : number, dy : number, len : number, z0 : number, z1 : number, hChord : number) : P3
end
local reshape = require "network_tools_1::/gui/construction/tools/shared/ntools_reshape.script.tl" as Reshape

do ((require "network_tools_1::/gui/construction/tools/shared/ntools_debug.script.tl" as {string : any}).log as function(string))("[network_tools] arrange on line tool script loaded (v1)") end

local function nodePos(n : Engine.Entity) : P3
	local node = api.engine.getComponent(n, api.type.ComponentType.BASE_NODE) as Engine.Component.BaseNode
	return geom.p3(node.position.x, node.position.y, node.position.z)
end

local function compute(chain : {ChainLink}, nodes : {Engine.Entity}) : Shape
	local n = #nodes
	if nodes[1] == nodes[n] then
		return { why = _("The stretch is a loop - pick one that has two ends") }
	end
	local A, B = nodePos(nodes[1]), nodePos(nodes[n])
	local dx, dy = B.x - A.x, B.y - A.y
	local L = math.sqrt(dx * dx + dy * dy)
	if L < 1 then return { why = _("The two ends are too close together") } end

	local Q : {P3} = {}
	local moves : {Engine.Entity : P3} = {}
	for k = 1, n do
		local p = nodePos(nodes[k])
		if k == 1 or k == n then
			Q[k] = p
		else
			local u = (k - 1) / (n - 1)
			Q[k] = geom.p3(A.x + dx * u, A.y + dy * u, p.z)
			moves[nodes[k]] = Q[k]
		end
	end
	local curves : {Engine.Entity : Curve} = {}
	for i, l in ipairs(chain) do
		local a, b = Q[i], Q[i + 1]
		local h = math.sqrt((b.x - a.x) ^ 2 + (b.y - a.y) ^ 2)
		local t = reshape.gradedTangent(dx, dy, h, a.z, b.z, h)
		curves[l.edge] = reshape.linkCurve(l, t, t)
	end
	-- a tag halfway along the line: the spacing between the nodes; on hover the line's length
	local tags : {any} = { {
		x = (A.x + B.x) / 2, y = (A.y + B.y) / 2, z = (A.z + B.z) / 2,
		rows = { { text = string.format("%s %.1f m", _("Spacing"), L / (n - 1)) } },
		detail = { { text = string.format("%s %.1f m", _("Length"), L) } },
	} }
	return {
		moves = moves,
		curves = curves,
		info = string.format("%s: %.1f m", _("Spacing"), L / (n - 1)),
		tags = tags,
	}
end

local ArrangeLineActionRecipe = reshape.create({
	recipeName = "NtoolsArrangeLineAction",
	hint = _("Click a road or track segment to start the stretch"),
	buildHint = _("Click more segments to extend, the first / last to remove. Press Build to line the nodes up"),
	minLinks = 2,
	compute = compute,
})

return {
	ArrangeLineActionRecipe = ArrangeLineActionRecipe,
}
