-- Network Tools: curve maths shared by the tools. TF3 segments are cubic Hermite curves: two end
-- positions and two end tangents (tangent length ~ segment length).

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
	scaled : function(v : P3, s : number) : P3
	len3 : function(v : P3) : number
	vec3 : function(p : P3) : Vec3f
	edgePiece : function(e : Engine.Component.BaseEdge) : Piece
	point : function(pc : Piece, t : number) : P3
	tangent : function(pc : Piece, t : number) : P3
	split : function(pc : Piece, ts : {number}) : {Piece}
	length : function(pc : Piece) : number
	closestT : function(pc : Piece, x : number, y : number) : number, number
end

local function p3(x : number, y : number, z : number) : P3
	return { x = x, y = y, z = z }
end

local function scaled(v : P3, s : number) : P3
	return p3(v.x * s, v.y * s, v.z * s)
end

local function len3(v : P3) : number
	return math.sqrt(v.x * v.x + v.y * v.y + v.z * v.z)
end

local function vec3(p : P3) : Vec3f
	return api.type.Vec3f.new(p.x, p.y, p.z)
end

local function edgePiece(e : Engine.Component.BaseEdge) : Piece
	return {
		p0 = p3(e.position0.x, e.position0.y, e.position0.z), t0 = p3(e.tangent0.x, e.tangent0.y, e.tangent0.z),
		p1 = p3(e.position1.x, e.position1.y, e.position1.z), t1 = p3(e.tangent1.x, e.tangent1.y, e.tangent1.z),
	}
end

local function point(pc : Piece, t : number) : P3
	local t2, t3 = t * t, t * t * t
	local h00, h10, h01, h11 = 2 * t3 - 3 * t2 + 1, t3 - 2 * t2 + t, -2 * t3 + 3 * t2, t3 - t2
	return p3(h00 * pc.p0.x + h10 * pc.t0.x + h01 * pc.p1.x + h11 * pc.t1.x,
		h00 * pc.p0.y + h10 * pc.t0.y + h01 * pc.p1.y + h11 * pc.t1.y,
		h00 * pc.p0.z + h10 * pc.t0.z + h01 * pc.p1.z + h11 * pc.t1.z)
end

local function tangent(pc : Piece, t : number) : P3
	local t2 = t * t
	local d00, d10, d01, d11 = 6 * t2 - 6 * t, 3 * t2 - 4 * t + 1, -6 * t2 + 6 * t, 3 * t2 - 2 * t
	return p3(d00 * pc.p0.x + d10 * pc.t0.x + d01 * pc.p1.x + d11 * pc.t1.x,
		d00 * pc.p0.y + d10 * pc.t0.y + d01 * pc.p1.y + d11 * pc.t1.y,
		d00 * pc.p0.z + d10 * pc.t0.z + d01 * pc.p1.z + d11 * pc.t1.z)
end

-- Split at sorted parameters in (0, 1); exact: the parts trace the same curve.
local function split(pc : Piece, ts : {number}) : {Piece}
	local out : {Piece} = {}
	local cur = pc
	local done = 0.0
	for _, t in ipairs(ts) do
		local lt = (t - done) / (1 - done)
		local P = point(cur, lt)
		local D = tangent(cur, lt)
		out[#out + 1] = { p0 = cur.p0, t0 = scaled(cur.t0, lt), p1 = P, t1 = scaled(D, lt) }
		cur = { p0 = P, t0 = scaled(D, 1 - lt), p1 = cur.p1, t1 = scaled(cur.t1, 1 - lt) }
		done = t
	end
	out[#out + 1] = cur
	return out
end

-- Arc length, by sampling.
local function length(pc : Piece) : number
	local n = 32
	local total = 0.0
	local prev = pc.p0
	for k = 1, n do
		local q = point(pc, k / n)
		total = total + math.sqrt((q.x - prev.x) ^ 2 + (q.y - prev.y) ^ 2 + (q.z - prev.z) ^ 2)
		prev = q
	end
	return total
end

-- Parameter of the point on the curve closest (in plan) to x, y, and that distance.
local function closestT(pc : Piece, x : number, y : number) : number, number
	local function d2(t : number) : number
		local q = point(pc, t)
		return (q.x - x) ^ 2 + (q.y - y) ^ 2
	end
	local n = 64
	local best, bestD = 0.0, math.huge
	for k = 0, n do
		local d = d2(k / n)
		if d < bestD then best, bestD = k / n, d end
	end
	-- refine by bisection around the best sample
	local lo, hi = math.max(0, best - 1 / n), math.min(1, best + 1 / n)
	for _ = 1, 30 do
		local a, b = lo + (hi - lo) / 3, hi - (hi - lo) / 3
		if d2(a) < d2(b) then hi = b else lo = a end
	end
	local t = (lo + hi) / 2
	return t, math.sqrt(d2(t))
end

local M : Geom = {
	p3 = p3, scaled = scaled, len3 = len3, vec3 = vec3, edgePiece = edgePiece,
	point = point, tangent = tangent, split = split, length = length, closestT = closestT,
}
return M
