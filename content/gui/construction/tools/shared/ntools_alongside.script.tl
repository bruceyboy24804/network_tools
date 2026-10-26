-- Network Tools: the tracks running alongside a track (a double / multi-track line), for the Siding
-- and Passing loop tools' "Alongside" options, and where a new curve crosses them.
--
--   alongside(edge, p, d)          -> { {edge, off}, ... } sorted by off (+ left of d), the clicked
--                                     track included (off 0); neighbours each <= 15 m from the next
--   trackAt(q, d)                  -> the track under q running along d: edge, t, its unit direction
--                                     along d, gradient along d, and an existing node within 3 m
--   crossU(piece, base, n, w)      -> the parameter where a curve is w metres across (along n) from
--                                     the line through base, or nil

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
	closestT : function(pc : Piece, x : number, y : number) : number, number
	point : function(pc : Piece, t : number) : P3
	tangent : function(pc : Piece, t : number) : P3
end
local geom = require "network_tools_1::/gui/construction/tools/shared/ntools_geom.script.tl" as Geom

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
	node : Engine.Entity   -- an existing node of the track within 3 m (use it instead of a split)
	nodePos : P3
end

local MAX_GAP = 15

local function getEdge(e : Engine.Entity) : Engine.Component.BaseEdge
	if not e or e < 0 or not api.engine.entityExists(e) then return nil end
	return api.engine.getComponent(e, api.type.ComponentType.BASE_EDGE) as Engine.Component.BaseEdge
end

local function trackEdgesNear(x : number, y : number, r : number) : {Engine.Entity}
	local out : {Engine.Entity} = {}
	local ok, found = pcall(function() : {Engine.Entity}
		return api.engine.util.octree.findEntitiesInCircle(api.type.Vec2f.new(x, y), r, api.type.ComponentType.BASE_EDGE)
	end)
	for __, e in ipairs(ok and found or {}) do
		local be = getEdge(e)
		if be and be.roadType == api.type["enum"].RoadType.TRACK then out[#out + 1] = e end
	end
	return out
end

local function flatUnit(v : P3) : P3
	local l = math.sqrt(v.x * v.x + v.y * v.y)
	if l < 1e-9 then return { x = 1, y = 0, z = 0 } end
	return { x = v.x / l, y = v.y / l, z = 0 }
end

-- The tracks alongside `edge` near p (d: its direction there)
local function alongside(edge : Engine.Entity, p : P3, d : P3) : {Lane}
	local nx, ny = -d.y, d.x
	local found : {Lane} = {}
	for __, e in ipairs(trackEdgesNear(p.x, p.y, 70)) do
		if e ~= edge then
			local pc = geom.edgePiece(getEdge(e))
			local t, dd = geom.closestT(pc, p.x, p.y)
			local q = geom.point(pc, t)
			local u = flatUnit(geom.tangent(pc, t))
			-- (parallel, beside p - not ahead of it: the foot of the perpendicular, inside the segment)
			local along = (q.x - p.x) * d.x + (q.y - p.y) * d.y
			if math.abs(u.x * d.x + u.y * d.y) > 0.9 and math.abs(along) < 3 and dd < 60 then
				local off = (q.x - p.x) * nx + (q.y - p.y) * ny
				if math.abs(off) >= 2.5 then
					local dup = false
					for __, f in ipairs(found) do if math.abs(f.off - off) < 1.5 then dup = true end end
					if not dup then found[#found + 1] = { edge = e, off = off } end
				end
			end
		end
	end
	table.sort(found, function(a : Lane, b : Lane) : boolean return a.off < b.off end)
	-- each side: outwards from the clicked track while the next is within MAX_GAP
	local out : {Lane} = { { edge = edge, off = 0 } }
	local last = 0.0
	for __, f in ipairs(found) do
		if f.off > 0 and f.off - last <= MAX_GAP then out[#out + 1] = f; last = f.off end
	end
	last = 0.0
	for i = #found, 1, -1 do
		local f = found[i]
		if f.off < 0 and last - f.off <= MAX_GAP then out[#out + 1] = f; last = f.off end
	end
	table.sort(out, function(a : Lane, b : Lane) : boolean return a.off < b.off end)
	return out
end

-- The track at q running along d (within 2.5 m), or nil
local function trackAt(q : P3, d : P3) : Spot
	local best : Spot = nil
	local bestD = 2.5
	for __, e in ipairs(trackEdgesNear(q.x, q.y, 25)) do
		local be = getEdge(e)
		local pc = geom.edgePiece(be)
		local t, dd = geom.closestT(pc, q.x, q.y)
		local t3 = geom.tangent(pc, t)
		local u = flatUnit(t3)
		if dd < bestD and math.abs(u.x * d.x + u.y * d.y) > 0.9 then
			local h = math.sqrt(t3.x * t3.x + t3.y * t3.y)
			local g = h > 1e-6 and t3.z / h or 0
			if u.x * d.x + u.y * d.y < 0 then u = { x = -u.x, y = -u.y, z = 0 }; g = -g end
			local pos = geom.point(pc, t)
			local s : Spot = { edge = e, t = t, pos = pos, dir = u, grade = g }
			-- (an existing node that close: joined directly - a split there would be too short)
			for k, n in ipairs({ be.node0, be.node1 }) do
				local np = k == 1 and pc.p0 or pc.p1
				if math.sqrt((np.x - pos.x) ^ 2 + (np.y - pos.y) ^ 2) < 3 then s.node, s.nodePos = n, np end
			end
			best, bestD = s, dd
		end
	end
	return best
end

-- Where the curve is w across (along n) from the line through base: its parameter, or nil
local function crossU(pc : Piece, base : P3, nx : number, ny : number, w : number) : number
	local function f(u : number) : number
		local q = geom.point(pc, u)
		return (q.x - base.x) * nx + (q.y - base.y) * ny - w
	end
	local N = 40
	local prev = f(0)
	for i = 1, N do
		local u = i / N
		local cur = f(u)
		if (prev <= 0 and cur >= 0) or (prev >= 0 and cur <= 0) then
			local lo, hi = (i - 1) / N, u
			for __ = 1, 30 do
				local mid = (lo + hi) / 2
				local fm = f(mid)
				if (f(lo) <= 0) == (fm <= 0) then lo = mid else hi = mid end
			end
			return (lo + hi) / 2
		end
		prev = cur
	end
	return nil
end

local record M
	alongside : function(edge : Engine.Entity, p : P3, d : P3) : {Lane}
	trackAt : function(q : P3, d : P3) : Spot
	crossU : function(pc : Piece, base : P3, nx : number, ny : number, w : number) : number
end
local m : M = { alongside = alongside, trackAt = trackAt, crossU = crossU }
return m
