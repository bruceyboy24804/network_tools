-- Network Tools: Connect's extra modes (6 - 11). Pure geometry: each returns the route in one of
-- Connect's forms, and Connect gives it heights, bridges and tunnels as for its own modes:
--   prims  - lines and arcs (Connect's Prim: centre, r, start angle a0, sweep > 0 counter-clockwise)
--   parts  - 2D Hermite pieces (Connect's Piece2), heights still to come
--   pieces - finished 3D pieces (Helix: it climbs evenly round its turns itself)
--
--   Easement   - Min. radius's path, its curvature eased in and out (clothoid-like transitions)
--   Helix      - Min. radius's path with full turns added at the start, to climb (or drop) to the
--                other end at no more than the set grade
--   Grade path - a route over the ground that never climbs steeper than the set grade (a search on a
--                grid of the terrain), smoothed
--   Spline     - a smooth curve through the waypoints (centripetal Catmull-Rom)
--   Arc        - one circular arc: through a waypoint, or leaving end 1 along its road
--   Offset     - an S-shift: two reverse arcs from end 1's direction to a parallel line through end 2

local record P3
	x : number
	y : number
	z : number
end

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

local record Piece
	p0 : P3
	t0 : P3
	p1 : P3
	t1 : P3
end

local record Circle2
	x : number
	y : number
	r : number
end

local record DubinsResult
	prims : {Prim}
	error : string
	length : number
end

local record Ctx
	A : P3
	B : P3
	ax : number
	ay : number
	bx : number          -- the way the new road leaves B (it arrives against it)
	by : number
	wps : {P3}
	radius : number      -- Min. radius's radius
	typeGrade : number   -- the road / track type's steepest grade (fraction)
	path : function(number, number, number, number, number, number, number, number, number) : DubinsResult
	ground : function(number, number) : number
end

local record Result
	prims : {Prim}
	parts : {Piece2}
	pieces : {Piece}
	circles : {Circle2}
	info : string
	error : string
	follow : boolean     -- build with follow terrain whatever the toggle (Grade path)
end

local record Options
	easeLength : number  -- metres of each transition
	helixRadius : number
	helixGrade : number  -- percent
	gradeMax : number    -- percent (Grade path)
end

local opts : Options = { easeLength = 60, helixRadius = 120, helixGrade = 2.5, gradeMax = 3 }

local MODE_EASE, MODE_HELIX, MODE_GRADE, MODE_SPLINE, MODE_ARC, MODE_OFFSET = 6, 7, 8, 9, 10, 11
local TAU = 2 * math.pi
local SAMPLE = 2.0       -- metres between samples of a path
local PIECE = 24.0       -- metres: pieces made from samples
local HELIX_CLEAR = 7.5  -- metres a helix's turns should be apart (a train under a bridge)
local ARC_MAX_R = 4000   -- metres: an arc wider than this is built as a straight
local ARC_SHOW_R = 1500  -- metres: its guide circle is drawn only up to this (a bigger one fills the screen)

local function len2(x : number, y : number) : number return math.sqrt(x * x + y * y) end
local function fmt(m : number) : string return tostring(math.floor(m + 0.5)) .. " m" end

local function primLength(p : Prim) : number
	if p.line then return len2(p.qx - p.px, p.qy - p.py) end
	return p.r * math.abs(p.sweep)
end

-- the path sampled every SAMPLE metres: points, headings (radians) and curvatures (signed: + left)
local record Sample
	x : number
	y : number
	h : number
	k : number
	s : number
end
local function samplePrims(prims : {Prim}) : {Sample}
	local out : {Sample} = {}
	local s0 = 0.0
	for i, p in ipairs(prims) do
		local L = primLength(p)
		local n = math.max(1, math.ceil(L / SAMPLE))
		for j = (i == 1 and 0 or 1), n do
			local u = j / n
			local smp : Sample
			if p.line then
				local h = math.atan2(p.qy - p.py, p.qx - p.px)
				smp = { x = p.px + (p.qx - p.px) * u, y = p.py + (p.qy - p.py) * u, h = h, k = 0 }
			else
				local a = p.a0 + p.sweep * u
				local dir = p.sweep >= 0 and 1 or -1
				smp = { x = p.cx + p.r * math.cos(a), y = p.cy + p.r * math.sin(a), h = a + dir * math.pi / 2, k = dir / p.r }
			end
			smp.s = s0 + L * u
			out[#out + 1] = smp
		end
		s0 = s0 + L
	end
	return out
end

-- Hermite parts through samples, one every PIECE metres (tangents along the headings, as long as
-- the piece's own arc)
local function partsFromSamples(smp : {Sample}) : {Piece2}
	local parts : {Piece2} = {}
	if #smp < 2 then return parts end
	local total = smp[#smp].s - smp[1].s
	local n = math.max(1, math.ceil(total / PIECE))
	local idx : {integer} = { 1 }
	local j = 1
	for k = 1, n - 1 do
		local target = smp[1].s + total * k / n
		while j < #smp and smp[j].s < target do j = j + 1 end
		if j > idx[#idx] and j < #smp then idx[#idx + 1] = j end
	end
	idx[#idx + 1] = #smp
	for k = 1, #idx - 1 do
		local a, b = smp[idx[k]], smp[idx[k + 1]]
		local chord = len2(b.x - a.x, b.y - a.y)
		local dh = math.abs(math.atan2(math.sin(b.h - a.h), math.cos(b.h - a.h)))
		-- (the exact circular-arc Hermite tangent: chord / cos^2(turn / 4))
		local L = dh < 1e-3 and chord or chord / (math.cos(dh / 4) ^ 2)
		parts[#parts + 1] = {
			x0 = a.x, y0 = a.y, tx0 = math.cos(a.h) * L, ty0 = math.sin(a.h) * L,
			x1 = b.x, y1 = b.y, tx1 = math.cos(b.h) * L, ty1 = math.sin(b.h) * L,
			len = math.max(L, b.s - a.s),
		}
	end
	return parts
end

-- an arc from p (leaving it along unit t) to q: its prim, or a line when (nearly) straight
local function arcFrom(px : number, py : number, tx : number, ty : number, qx : number, qy : number) : Prim
	local nx, ny = -ty, tx                      -- left of the travel
	local vx, vy = qx - px, qy - py
	local side = vx * nx + vy * ny
	local vv = vx * vx + vy * vy
	if math.abs(side) < 1e-6 or vv / (2 * math.abs(side)) > 1e5 then
		return { line = true, px = px, py = py, qx = qx, qy = qy }
	end
	local r = vv / (2 * side)                   -- signed: + centre on the left (counter-clockwise)
	local cx, cy = px + nx * r, py + ny * r
	local a0 = math.atan2(py - cy, px - cx)
	local a1 = math.atan2(qy - cy, qx - cx)
	local sweep : number
	if r > 0 then sweep = (a1 - a0) % TAU else sweep = -((a0 - a1) % TAU) end
	return { line = false, cx = cx, cy = cy, r = math.abs(r), a0 = a0, sweep = sweep }
end

-- Biarc: two circular arcs from p0 (unit direction t0) to p1 (arriving along t1), meeting smoothly
-- (the equal-tangent biarc) - true arcs, so every piece built has one radius the game reads as planned
local function biarc(p0x : number, p0y : number, t0x : number, t0y : number, p1x : number, p1y : number, t1x : number, t1y : number) : {Prim}
	local vx, vy = p1x - p0x, p1y - p0y
	local vv = vx * vx + vy * vy
	if vv < 1e-6 then return {} end
	local tx, ty = t0x + t1x, t0y + t1y
	local vt = vx * tx + vy * ty
	local c = 2 * (1 - (t0x * t1x + t0y * t1y))
	local dlen : number
	if math.abs(c) < 1e-6 then
		local v0 = vx * t0x + vy * t0y
		if math.abs(v0) < 1e-9 then return { { line = true, px = p0x, py = p0y, qx = p1x, qy = p1y } } end
		dlen = vv / (4 * v0)
	else
		dlen = (-vt + math.sqrt(vt * vt + c * vv)) / c
	end
	-- the joint: halfway between the two tangent points
	local jx = (p0x + t0x * dlen + p1x - t1x * dlen) / 2
	local jy = (p0y + t0y * dlen + p1y - t1y * dlen) / 2
	local a = arcFrom(p0x, p0y, t0x, t0y, jx, jy)
	-- (the second arc, run backwards from p1 against t1, then turned round)
	local bk = arcFrom(p1x, p1y, -t1x, -t1y, jx, jy)
	local b2 : Prim
	if bk.line then b2 = { line = true, px = jx, py = jy, qx = p1x, qy = p1y }
	else b2 = { line = false, cx = bk.cx, cy = bk.cy, r = bk.r, a0 = bk.a0 + bk.sweep, sweep = -bk.sweep } end
	return { a, b2 }
end

-- Douglas-Peucker: the points of a polyline that keep it within tol metres (its ends always), and
-- no two kept more than maxLen apart (indices into pts)
local function simplify(pts : {{number}}, tol : number, maxLen : number) : {integer}
	local keep : {integer : boolean} = { [1] = true, [#pts] = true }
	local function rec(i : integer, j : integer)
		if j <= i + 1 then return end
		local ax, ay, bx, by = pts[i][1], pts[i][2], pts[j][1], pts[j][2]
		local dx, dy = bx - ax, by - ay
		local L = math.sqrt(dx * dx + dy * dy)
		local worst, wi = -1.0, -1
		for k = i + 1, j - 1 do
			local d : number
			if L < 1e-9 then d = math.sqrt((pts[k][1] - ax) ^ 2 + (pts[k][2] - ay) ^ 2)
			else d = math.abs((pts[k][1] - ax) * dy - (pts[k][2] - ay) * dx) / L end
			if d > worst then worst, wi = d, k end
		end
		if worst > tol or L > maxLen then
			if worst <= tol then wi = math.floor((i + j) / 2) end
			keep[wi] = true
			rec(i, wi)
			rec(wi, j)
		end
	end
	rec(1, #pts)
	local out : {integer} = {}
	for k = 1, #pts do if keep[k] then out[#out + 1] = k end end
	return out
end

local function dubinsPath(c : Ctx, r : number) : DubinsResult
	return c.path(c.A.x, c.A.y, c.ax, c.ay, c.B.x, c.B.y, -c.bx, -c.by, r)
end

-- Easement ----------------------------------------------------------------------------------------

-- (one pass: Min. radius's path to (tx, ty), its curvature eased - its samples and where it ends)
local genEaseTo : function(c : Ctx, tx : number, ty : number) : Result, {Sample}, number, number
local function genEase(c : Ctx) : Result
	-- the eased path ends a little off end 2 (easing moves the curves inwards): aim at a point off
	-- end 2 by as much the other way, again, until it lands within 0.2 m - the curves stay clothoids
	-- (the drift spread along the route bent them)
	local tx, ty = c.B.x, c.B.y
	local res : Result
	for __ = 1, 5 do
		local r2, __s, ex, ey = genEaseTo(c, tx, ty)
		res = r2
		if not res or res.error or not ex then break end
		if len2(ex, ey) < 0.2 then break end
		tx, ty = tx + ex, ty + ey
	end
	return res
end
genEaseTo = function(c : Ctx, tx : number, ty : number) : Result, {Sample}, number, number
	local r = c.radius or 100
	local res = c.path(c.A.x, c.A.y, c.ax, c.ay, tx, ty, -c.bx, -c.by, r)
	if res.error then return { error = res.error }, nil, nil, nil end
	local smp = samplePrims(res.prims)
	if #smp < 3 then return { error = _("Too short") }, nil, nil, nil end
	local L = smp[#smp].s
	-- the curvature smoothed over the transition length: where it steps (straight to arc) it now
	-- changes evenly - a clothoid's linear curvature
	local W = math.min(opts.easeLength or 60, L / 3)
	local half = math.max(1, math.floor(W / SAMPLE / 2 + 0.5))
	local pre : {number} = { 0 }
	for i, s in ipairs(smp) do pre[i + 1] = pre[i] + s.k end
	local k2 : {number} = {}
	for i = 1, #smp do
		local lo, hi = math.max(1, i - half), math.min(#smp, i + half)
		k2[i] = (pre[hi + 1] - pre[lo]) / (2 * half + 1)
	end
	-- heading and position again from end 1 (its own direction); then the drift at end 2 (in the
	-- heading, then the position) spread evenly along the way, so it still meets end 2 square
	local hs : {number} = { smp[1].h }
	for i = 2, #smp do hs[i] = hs[i - 1] + 0.5 * (k2[i - 1] + k2[i]) * (smp[i].s - smp[i - 1].s) end
	local dh = smp[#smp].h - hs[#smp]
	dh = math.atan2(math.sin(dh), math.cos(dh))
	for i = 1, #smp do hs[i] = hs[i] + dh * smp[i].s / L end
	local xs : {number} = { smp[1].x }
	local ys : {number} = { smp[1].y }
	for i = 2, #smp do
		local ds = smp[i].s - smp[i - 1].s
		local hm = 0.5 * (hs[i - 1] + hs[i])
		xs[i], ys[i] = xs[i - 1] + math.cos(hm) * ds, ys[i - 1] + math.sin(hm) * ds
	end
	-- how far the eased path ends from end 2 itself (genEase aims again by this); what's left after
	-- the last aim is spread along the way so the road still meets end 2 exactly
	local ex, ey = c.B.x - xs[#smp], c.B.y - ys[#smp]
	local out : {Sample} = {}
	for i = 1, #smp do
		local u = smp[i].s / L
		out[i] = { x = xs[i] + ex * u, y = ys[i] + ey * u, h = hs[i], k = k2[i], s = smp[i].s }
	end
	local drift = len2(ex, ey)
	local info = _("Easement") .. " " .. fmt(W) .. "   " .. _("Length") .. " " .. fmt(L) .. "   " .. _("Min. radius") .. " " .. fmt(r)
	if drift > 0.02 * L then
		info = info .. "\n" .. _("Long easements for this path - a bigger radius or a shorter easement keeps it closer")
	end
	return { parts = partsFromSamples(out), circles = {}, info = info }, out, ex, ey
end

-- Helix -------------------------------------------------------------------------------------------

local function genHelix(c : Ctx) : Result
	local r = math.max(30, opts.helixRadius or 120)
	local grade = math.max(0.1, opts.helixGrade or 2.5) / 100
	local res = dubinsPath(c, r)
	if res.error then return { error = res.error } end
	local prims : {Prim} = {}
	for i, p in ipairs(res.prims) do prims[i] = p end
	local L0 = 0.0
	for __, p in ipairs(prims) do L0 = L0 + primLength(p) end
	local dz = c.B.z - c.A.z
	local need = math.abs(dz) / grade
	local turns = math.max(0, math.ceil((need - L0) / (TAU * r)))
	if turns > 0 then
		local first = prims[1]
		if first and not first.line and math.abs(first.r - r) < 0.5 then
			-- (the path starts on a circle: go round it `turns` more times - a copy, the path's own
			-- prims may be kept elsewhere)
			prims[1] = { line = false, cx = first.cx, cy = first.cy, r = first.r, a0 = first.a0,
				sweep = first.sweep + (first.sweep >= 0 and 1 or -1) * TAU * turns }
		else
			-- full turns on a circle touching end 1 on its left, back to where they began
			local cx, cy = c.A.x - c.ay * r, c.A.y + c.ax * r
			table.insert(prims, 1, { line = false, cx = cx, cy = cy, r = r, a0 = math.atan2(c.A.y - cy, c.A.x - cx), sweep = TAU * turns })
		end
	end
	local smp = samplePrims(prims)
	local parts = partsFromSamples(smp)
	if #parts == 0 then return { error = _("Too short") } end
	local total = 0.0
	for __, pt in ipairs(parts) do total = total + pt.len end
	local slope = dz / total
	local pieces : {Piece} = {}
	local s = 0.0
	for __, pt in ipairs(parts) do
		local z0, z1 = c.A.z + slope * s, c.A.z + slope * (s + pt.len)
		pieces[#pieces + 1] = {
			p0 = { x = pt.x0, y = pt.y0, z = z0 }, t0 = { x = pt.tx0, y = pt.ty0, z = slope * pt.len },
			p1 = { x = pt.x1, y = pt.y1, z = z1 }, t1 = { x = pt.tx1, y = pt.ty1, z = slope * pt.len },
		}
		s = s + pt.len
	end
	pieces[1].p0 = c.A
	pieces[#pieces].p1 = c.B
	local rise = math.abs(slope) * TAU * r
	local info = string.format("%s: %d   %s %s   %s %.1f%%   %s %.1f m", _("Turns"), turns, _("Radius"), fmt(r),
		_("Grade"), math.abs(slope) * 100, _("per turn"), rise)
	if turns == 0 then
		info = info .. "\n" .. _("No turns needed: the ends are close enough in height for the grade")
	elseif rise < HELIX_CLEAR then
		info = info .. "\n" .. string.format(_("The turns are only %.1f m apart - a bigger radius or a steeper grade gives room under each"), rise)
	end
	if math.abs(slope) > (c.typeGrade or 1) then
		info = info .. "\n" .. string.format(_("Grade %.1f%% is steeper than this type allows"), math.abs(slope) * 100)
	end
	local circles : {Circle2} = {}
	if turns > 0 then
		local f = prims[1]
		circles[1] = { x = f.cx, y = f.cy, r = f.r }
	end
	return { pieces = pieces, circles = circles, info = info }
end

-- Grade path --------------------------------------------------------------------------------------

local g_gradeCache : {string : any} = {}

-- a binary heap of {cost, cell}
local function heapPush(h : {{number}}, item : {number})
	h[#h + 1] = item
	local i = #h
	while i > 1 do
		local p = math.floor(i / 2)
		if h[p][1] <= h[i][1] then break end
		h[p], h[i] = h[i], h[p]
		i = p
	end
end
local function heapPop(h : {{number}}) : {number}
	local top = h[1]
	local last = table.remove(h)
	if #h > 0 then
		h[1] = last
		local i = 1
		while true do
			local l, r = 2 * i, 2 * i + 1
			local m = i
			if l <= #h and h[l][1] < h[m][1] then m = l end
			if r <= #h and h[r][1] < h[m][1] then m = r end
			if m == i then break end
			h[m], h[i] = h[i], h[m]
			i = m
		end
	end
	return top
end

local function genGradeGrid(c : Ctx) : Result
	local maxG = math.min(math.max(0.5, opts.gradeMax or 3) / 100, c.typeGrade or 1)
	local A, B = c.A, c.B
	local dist = len2(B.x - A.x, B.y - A.y)
	if dist < 20 then return { error = _("Too short") } end
	-- (leave each end along its road first, then search between those points)
	local lead = 20.0
	local sx, sy = A.x + c.ax * lead, A.y + c.ay * lead
	local gx, gy = B.x + c.bx * lead, B.y + c.by * lead
	local margin = math.max(250, dist * 0.6)
	local x0, y0 = math.min(sx, gx) - margin, math.min(sy, gy) - margin
	local x1, y1 = math.max(sx, gx) + margin, math.max(sy, gy) + margin
	local cell = math.max(16, math.max(x1 - x0, y1 - y0) / 140)
	local nx, ny = math.ceil((x1 - x0) / cell) + 1, math.ceil((y1 - y0) / cell) + 1
	local key = string.format("%.0f,%.0f,%.0f,%.0f,%.0f,%.0f,%.4f", sx, sy, gx, gy, A.z, B.z, maxG)
	if g_gradeCache.key == key then return g_gradeCache.result as Result end
	local hcache : {integer : number} = {}
	local function cellH(i : integer, j : integer) : number
		local id = j * nx + i
		local h = hcache[id]
		if h == nil then
			h = c.ground(x0 + i * cell, y0 + j * cell) or 0
			hcache[id] = h
		end
		return h
	end
	local function cellOf(x : number, y : number) : integer, integer
		return math.floor((x - x0) / cell + 0.5), math.floor((y - y0) / cell + 0.5)
	end
	local si, sj = cellOf(sx, sy)
	local ti, tj = cellOf(gx, gy)
	-- 16 directions (knight moves too): straighter lines than 8
	local moves : {{integer}} = {}
	for di = -2, 2 do
		for dj = -2, 2 do
			if (di ~= 0 or dj ~= 0) and not (math.abs(di) == 2 and math.abs(dj) == 2) and not (math.abs(di) == 2 and dj == 0) and not (di == 0 and math.abs(dj) == 2) then
				moves[#moves + 1] = { di, dj }
			end
		end
	end
	local gScore : {integer : number} = {}
	local from : {integer : integer} = {}
	local closed : {integer : boolean} = {}
	local start = sj * nx + si
	local goal = tj * nx + ti
	gScore[start] = 0
	local heap : {{number}} = {}
	heapPush(heap, { len2(ti - si, tj - sj) * cell, start })
	local found = false
	local iter = 0
	while #heap > 0 and iter < 200000 do
		iter = iter + 1
		local top = heapPop(heap)
		local id = math.floor(top[2])
		if id == goal then found = true break end
		if not closed[id] then
			closed[id] = true
			local i, j = id % nx, math.floor(id / nx)
			local h0 = cellH(i, j)
			for __, m in ipairs(moves) do
				local i2, j2 = i + m[1], j + m[2]
				if i2 >= 0 and j2 >= 0 and i2 < nx and j2 < ny then
					local id2 = j2 * nx + i2
					if not closed[id2] then
						local d = len2(m[1], m[2]) * cell
						local g = math.abs(cellH(i2, j2) - h0) / d
						if g <= maxG then
							local cost = gScore[id] + d * (1 + 0.5 * g / maxG)
							if gScore[id2] == nil or cost < gScore[id2] then
								gScore[id2] = cost
								from[id2] = id
								heapPush(heap, { cost + len2(ti - i2, tj - j2) * cell, id2 })
							end
						end
					end
				end
			end
		end
	end
	local result : Result
	if not found then
		result = { error = string.format(_("No route between the ends stays within %.1f%% - raise the grade, or pick nearer ends"), maxG * 100) }
	else
		-- the cells back to front, then smoothed (corner cutting) into a gentle line
		local pts : {{number}} = {}
		local id = goal
		while id do
			pts[#pts + 1] = { x0 + (id % nx) * cell, y0 + math.floor(id / nx) * cell }
			id = from[id]
		end
		local line : {{number}} = { { A.x, A.y }, { sx, sy } }
		for k = #pts, 1, -1 do line[#line + 1] = pts[k] end
		line[#line + 1] = { gx, gy }
		line[#line + 1] = { B.x, B.y }
		for __ = 1, 4 do
			local sm : {{number}} = { line[1], line[2] }
			for k = 2, #line - 2 do
				local p, q = line[k], line[k + 1]
				sm[#sm + 1] = { 0.75 * p[1] + 0.25 * q[1], 0.75 * p[2] + 0.25 * q[2] }
				sm[#sm + 1] = { 0.25 * p[1] + 0.75 * q[1], 0.25 * p[2] + 0.75 * q[2] }
			end
			sm[#sm + 1] = line[#line - 1]
			sm[#sm + 1] = line[#line]
			line = sm
		end
		-- samples with headings from their neighbours; the ends along the roads
		local smp : {Sample} = {}
		local s = 0.0
		for k, p in ipairs(line) do
			if k > 1 then s = s + len2(p[1] - line[k - 1][1], p[2] - line[k - 1][2]) end
			local h : number
			if k == 1 then h = math.atan2(c.ay, c.ax)
			elseif k == #line then h = math.atan2(-c.by, -c.bx)
			else h = math.atan2(line[k + 1][2] - line[k - 1][2], line[k + 1][1] - line[k - 1][1]) end
			smp[#smp + 1] = { x = p[1], y = p[2], h = h, k = 0, s = s }
		end
		-- only the points that matter (Douglas-Peucker: within 1 m, at most 150 m apart), joined by biarcs
		local xy : {{number}} = {}
		for k, sm in ipairs(smp) do xy[k] = { sm.x, sm.y } end
		local prims : {Prim} = {}
		local kept = simplify(xy, 1.0, 150)
		for k = 1, #kept - 1 do
			local a, bb = smp[kept[k]], smp[kept[k + 1]]
			for __, pr in ipairs(biarc(a.x, a.y, math.cos(a.h), math.sin(a.h), bb.x, bb.y, math.cos(bb.h), math.sin(bb.h))) do
				prims[#prims + 1] = pr
			end
		end
		result = { prims = prims, circles = {}, follow = true,
			info = string.format("%s %.1f%%   %s %s", _("Max. grade"), maxG * 100, _("Length"), fmt(s)) }
	end
	g_gradeCache.key, g_gradeCache.result = key, result
	return result
end

-- Grade path, hybrid A*: a search over position AND heading, moving in steps that are straights or
-- arcs of the minimum radius (so what it finds is buildable as it stands - no zig-zag to smooth),
-- each step within the grade over the ground. Near the goal it tries the exact Dubins finish (the
-- route's last curves straight onto end 2's direction), kept when that too stays within the grade.
-- No route: the grid search above (smoothed) is tried instead.
local g_hybridCache : {string : any} = {}
local function genGrade(c : Ctx) : Result
	local maxG = math.min(math.max(0.5, opts.gradeMax or 3) / 100, c.typeGrade or 1)
	local A, B = c.A, c.B
	local dist = len2(B.x - A.x, B.y - A.y)
	if dist < 20 then return { error = _("Too short") } end
	local R = math.max(c.radius or 100, 60)
	local lead = 20.0
	local sx, sy = A.x + c.ax * lead, A.y + c.ay * lead
	local gx, gy = B.x + c.bx * lead, B.y + c.by * lead
	local gh = math.atan2(-c.by, -c.bx)   -- arriving at end 2 against its road's way out
	local key = string.format("%.0f,%.0f,%.0f,%.0f,%.0f,%.0f,%.4f,%.0f", sx, sy, gx, gy, A.z, B.z, maxG, R)
	if g_hybridCache.key == key then return g_hybridCache.result as Result end
	local S = math.max(16, math.min(40, R * 0.35))   -- step length
	local margin = math.max(300, dist * 0.6)
	local x0, y0 = math.min(sx, gx) - margin, math.min(sy, gy) - margin
	local x1, y1 = math.max(sx, gx) + margin, math.max(sy, gy) + margin
	local cell = S * 0.75
	local NH = 24                                  -- heading bins
	local hcache : {string : number} = {}
	local function ground(x : number, y : number) : number
		local k = string.format("%.0f,%.0f", x / 4, y / 4)
		local h = hcache[k]
		if h == nil then h = c.ground(x, y) or 0; hcache[k] = h end
		return h
	end
	local function keyOf(x : number, y : number, h : number) : string
		local hb = math.floor((h % TAU) / TAU * NH + 0.5) % NH
		return string.format("%d,%d,%d", math.floor((x - x0) / cell), math.floor((y - y0) / cell), hb)
	end
	-- a step from (x, y, h) with curvature k: where it ends, its heading, its prim
	local function step(x : number, y : number, h : number, k : number) : number, number, number, Prim
		if k == 0 then
			local qx, qy = x + math.cos(h) * S, y + math.sin(h) * S
			return qx, qy, h, { line = true, px = x, py = y, qx = qx, qy = qy }
		end
		local r = 1 / math.abs(k)
		local sgn = k > 0 and 1 or -1
		local cx, cy = x - math.sin(h) * r * sgn, y + math.cos(h) * r * sgn
		local a0 = math.atan2(y - cy, x - cx)
		local sw = S / r * sgn
		local a1 = a0 + sw
		return cx + r * math.cos(a1), cy + r * math.sin(a1), h + sw, { line = false, cx = cx, cy = cy, r = r, a0 = a0, sweep = sw }
	end
	-- within the grade along a stretch of prims (sampled every few metres over the ground)
	local function gradeOk(prims : {Prim}) : boolean
		local smp = samplePrims(prims)
		local stepM = 8.0
		local lastS, lastZ = 0.0, ground(smp[1].x, smp[1].y)
		for i = 2, #smp do
			if smp[i].s - lastS >= stepM or i == #smp then
				local z = ground(smp[i].x, smp[i].y)
				local ds = smp[i].s - lastS
				if ds > 0.5 and math.abs(z - lastZ) / ds > maxG * 1.15 then return false end
				lastS, lastZ = smp[i].s, z
			end
		end
		return true
	end
	-- the search
	local record Node
		x : number
		y : number
		h : number
		g : number
		parent : integer
		prim : Prim
	end
	local nodesL : {Node} = { { x = sx, y = sy, h = math.atan2(c.ay, c.ax), g = 0, parent = 0 } }
	local best : {string : number} = {}
	local closed : {string : boolean} = {}
	local heap : {{number}} = {}
	heapPush(heap, { len2(gx - sx, gy - sy), 1 })
	local finish : {Prim} = nil
	local endNode = 0
	local iter = 0
	while #heap > 0 and iter < 40000 do
		iter = iter + 1
		local top = heapPop(heap)
		local id = math.floor(top[2])
		local nd = nodesL[id]
		local kk = keyOf(nd.x, nd.y, nd.h)
		if not closed[kk] then
			closed[kk] = true
			-- near enough: the exact finish onto end 2
			local dg = len2(gx - nd.x, gy - nd.y)
			if dg < 8 * R or iter % 50 == 0 then
				local ok, res = pcall(c.path, nd.x, nd.y, math.cos(nd.h), math.sin(nd.h), gx, gy, math.cos(gh), math.sin(gh), R)
				if ok and res and not res.error and res.prims and #res.prims > 0 and res.length < dg * 1.6 + 2 * R and gradeOk(res.prims) then
					finish, endNode = res.prims, id
					break
				end
			end
			for __, k in ipairs({ 0, 1 / R, -1 / R }) do
				local qx, qy, qh, pr = step(nd.x, nd.y, nd.h, k)
				if qx >= x0 and qy >= y0 and qx <= x1 and qy <= y1 then
					local z0, zm, z1 = ground(nd.x, nd.y), 0.0, ground(qx, qy)
					local mx, my = (nd.x + qx) / 2, (nd.y + qy) / 2
					zm = ground(mx, my)
					local g = math.max(math.abs(z1 - z0) / S, math.abs(zm - z0) / (S / 2), math.abs(z1 - zm) / (S / 2))
					if g <= maxG then
						local cost = nd.g + S * (1 + 0.5 * g / maxG) + (k ~= 0 and S * 0.08 or 0)
						local qk = keyOf(qx, qy, qh)
						if not closed[qk] and (best[qk] == nil or cost < best[qk]) then
							best[qk] = cost
							nodesL[#nodesL + 1] = { x = qx, y = qy, h = qh, g = cost, parent = id, prim = pr }
							heapPush(heap, { cost + len2(gx - qx, gy - qy), #nodesL })
						end
					end
				end
			end
		end
	end
	local result : Result
	if not finish then
		result = genGradeGrid(c)
		if not result.error then result.info = (result.info or "") .. "\n" .. _("(no route with curves this wide - the grid route, smoothed)") end
	else
		-- the steps back to the start, then the finish; the leads along the two roads at the ends
		local chain : {Prim} = {}
		local id = endNode
		while id > 0 and nodesL[id].prim do
			table.insert(chain, 1, nodesL[id].prim)
			id = nodesL[id].parent
		end
		local prims : {Prim} = { { line = true, px = A.x, py = A.y, qx = sx, qy = sy } }
		for __, p in ipairs(chain) do prims[#prims + 1] = p end
		for __, p in ipairs(finish) do prims[#prims + 1] = p end
		prims[#prims + 1] = { line = true, px = gx, py = gy, qx = B.x, qy = B.y }
		local L = 0.0
		for __, p in ipairs(prims) do L = L + primLength(p) end
		result = { prims = prims, circles = {}, follow = true,
			info = string.format("%s %.1f%%   %s %s   %s %s", _("Max. grade"), maxG * 100, _("Length"), fmt(L), _("Curves"), fmt(R)) }
	end
	g_hybridCache.key, g_hybridCache.result = key, result
	return result
end

-- Spline ------------------------------------------------------------------------------------------

local function genSpline(c : Ctx) : Result
	local pts : {P3} = { c.A }
	for __, w in ipairs(c.wps or {}) do pts[#pts + 1] = w end
	pts[#pts + 1] = c.B
	local n = #pts
	-- unit directions at each point: the roads' at the ends, else (centripetal) from the neighbours
	local dirs : {{number}} = {}
	for i = 1, n do
		local dx, dy : number, number
		if i == 1 then dx, dy = c.ax, c.ay
		elseif i == n then dx, dy = -c.bx, -c.by
		else
			local p, q, r = pts[i - 1], pts[i], pts[i + 1]
			local d1, d2 = math.sqrt(len2(q.x - p.x, q.y - p.y)), math.sqrt(len2(r.x - q.x, r.y - q.y))
			dx = (q.x - p.x) / math.max(d1, 1e-3) / math.max(d1, 1e-3) * d2 + (r.x - q.x) / math.max(d2, 1e-3) / math.max(d2, 1e-3) * d1
			dy = (q.y - p.y) / math.max(d1, 1e-3) / math.max(d1, 1e-3) * d2 + (r.y - q.y) / math.max(d2, 1e-3) / math.max(d2, 1e-3) * d1
		end
		local l = math.max(len2(dx, dy), 1e-9)
		dirs[i] = { dx / l, dy / l }
	end
	-- between each two points a biarc (two true arcs): every piece has one radius - the tightest shown
	local prims : {Prim} = {}
	local tight = math.huge
	for i = 1, n - 1 do
		local p, q = pts[i], pts[i + 1]
		for __, pr in ipairs(biarc(p.x, p.y, dirs[i][1], dirs[i][2], q.x, q.y, dirs[i + 1][1], dirs[i + 1][2])) do
			prims[#prims + 1] = pr
			if not pr.line then tight = math.min(tight, pr.r) end
		end
	end
	local info = string.format("%s: %d", _("Points"), n - 2)
	if tight < math.huge then info = info .. "   " .. _("Tightest") .. " " .. fmt(tight) end
	return { prims = prims, circles = {}, info = info }
end

-- Arc ---------------------------------------------------------------------------------------------

local function arcPrim(cx : number, cy : number, r : number, px : number, py : number, qx : number, qy : number, ccw : boolean) : Prim
	local a0 = math.atan2(py - cy, px - cx)
	local a1 = math.atan2(qy - cy, qx - cx)
	local sweep : number
	if ccw then sweep = (a1 - a0) % TAU else sweep = -((a0 - a1) % TAU) end
	return { line = false, cx = cx, cy = cy, r = r, a0 = a0, sweep = sweep }
end

local function genArc(c : Ctx) : Result
	local A, B = c.A, c.B
	local w = c.wps and c.wps[1]
	if w then
		-- the circle through end 1, the waypoint and end 2
		local ax, ay, bx, by, cx, cy = A.x, A.y, w.x, w.y, B.x, B.y
		local d = 2 * (ax * (by - cy) + bx * (cy - ay) + cx * (ay - by))
		if math.abs(d) < 1e-6 then
			return { prims = { { line = true, px = A.x, py = A.y, qx = B.x, qy = B.y } }, circles = {}, info = _("The three points are in line: a straight") }
		end
		local a2, b2, c2 = ax * ax + ay * ay, bx * bx + by * by, cx * cx + cy * cy
		local ox = (a2 * (by - cy) + b2 * (cy - ay) + c2 * (ay - by)) / d
		local oy = (a2 * (cx - bx) + b2 * (ax - cx) + c2 * (bx - ax)) / d
		local r = len2(ax - ox, ay - oy)
		if r > ARC_MAX_R then
			return { prims = { { line = true, px = A.x, py = A.y, qx = B.x, qy = B.y } }, circles = {}, info = _("The three points are almost in line: a straight") }
		end
		-- (counter-clockwise when the waypoint is left of the way from end 1 to end 2)
		local ccw = ((bx - ax) * (cy - ay) - (by - ay) * (cx - ax)) < 0
		local p = arcPrim(ox, oy, r, A.x, A.y, B.x, B.y, ccw)
		local info = _("Radius") .. " " .. fmt(r)
		if math.abs(p.sweep) > 1.5 * math.pi then
			info = info .. "\n" .. _("The arc goes most of the way round its circle - move the point between the ends for a gentler one")
		end
		-- (end 1's road direction against the arc's: a kink at a node)
		local th = p.a0 + (p.sweep >= 0 and 1 or -1) * math.pi / 2
		local dev = math.deg(math.abs(math.atan2(math.sin(th - math.atan2(c.ay, c.ax)), math.cos(th - math.atan2(c.ay, c.ax)))))
		if dev > 3 then info = info .. "\n" .. string.format(_("The arc leaves end 1 %d° off its road's direction"), math.floor(dev + 0.5)) end
		local circ : {Circle2} = {}
		if r <= ARC_SHOW_R then circ[1] = { x = ox, y = oy, r = r } end
		return { prims = { p }, circles = circ, info = info }
	end
	-- no waypoint: the arc that leaves end 1 along its road and ends at end 2
	local dx, dy = B.x - A.x, B.y - A.y
	local nx, ny = -c.ay, c.ax
	local side = dx * nx + dy * ny
	if math.abs(side) < 0.05 then
		return { prims = { { line = true, px = A.x, py = A.y, qx = B.x, qy = B.y } }, circles = {}, info = _("End 2 is straight ahead: a straight") }
	end
	local r = (dx * dx + dy * dy) / (2 * math.abs(side))
	-- (end 2 nearly straight ahead: the radius runs to kilometres - a straight is what it is)
	if r > ARC_MAX_R then
		return { prims = { { line = true, px = A.x, py = A.y, qx = B.x, qy = B.y } }, circles = {}, info = _("End 2 is almost straight ahead: a straight") }
	end
	local sg = side > 0 and 1 or -1
	local ox, oy = A.x + nx * r * sg, A.y + ny * r * sg
	local p = arcPrim(ox, oy, r, A.x, A.y, B.x, B.y, sg > 0)
	-- (end 2 beside or behind end 1: the only such arc goes the long way round - a giant loop)
	if math.abs(p.sweep) > math.pi then
		return { error = _("End 2 is beside or behind end 1: an arc leaving along its road would loop the long way round - click a point for the arc to pass through, or use Loop") }
	end
	local circ : {Circle2} = {}
	if r <= ARC_SHOW_R then circ[1] = { x = ox, y = oy, r = r } end
	return { prims = { p }, circles = circ,
		info = _("Radius") .. " " .. fmt(r) .. "\n" .. _("Click a point for an arc through it") }
end

-- Offset ------------------------------------------------------------------------------------------

local function genOffset(c : Ctx) : Result
	local A, B = c.A, c.B
	local dx, dy = B.x - A.x, B.y - A.y
	local along = dx * c.ax + dy * c.ay
	local nx, ny = -c.ay, c.ax
	local h = dx * nx + dy * ny
	if along < 5 then return { error = _("End 2 must lie ahead of end 1 (the shift runs along end 1's road)") } end
	if math.abs(h) < 0.1 then
		return { prims = { { line = true, px = A.x, py = A.y, qx = B.x, qy = B.y } }, circles = {}, info = _("No sideways shift: a straight") }
	end
	local th = 2 * math.atan2(math.abs(h), along)
	local R = along / (2 * math.sin(th))
	local sg = h > 0 and 1 or -1
	local mx, my = A.x + c.ax * along / 2 + nx * h / 2, A.y + c.ay * along / 2 + ny * h / 2
	local c1x, c1y = A.x + nx * R * sg, A.y + ny * R * sg
	local c2x, c2y = B.x - nx * R * sg, B.y - ny * R * sg
	local p1 = arcPrim(c1x, c1y, R, A.x, A.y, mx, my, sg > 0)
	local p2 = arcPrim(c2x, c2y, R, mx, my, B.x, B.y, sg < 0)
	local info = string.format("%s %s   %s %s   %s %s", _("Shift"), fmt(math.abs(h)), _("over"), fmt(along), _("Radius"), fmt(R))
	-- (end 2 a node whose road isn't parallel: a kink there)
	local par = math.abs(c.bx * c.ax + c.by * c.ay)
	if par < 0.995 then info = info .. "\n" .. _("End 2's road isn't parallel to end 1's: the shift meets it at an angle") end
	return { prims = { p1, p2 }, circles = { { x = c1x, y = c1y, r = R }, { x = c2x, y = c2y, r = R } }, info = info }
end

---------------------------------------------------------------------------------------------------

local function generate(mode : integer, c : Ctx) : Result
	if mode == MODE_EASE then return genEase(c)
	elseif mode == MODE_HELIX then return genHelix(c)
	elseif mode == MODE_GRADE then return genGrade(c)
	elseif mode == MODE_SPLINE then return genSpline(c)
	elseif mode == MODE_ARC then return genArc(c)
	elseif mode == MODE_OFFSET then return genOffset(c)
	end
	return { error = "unknown mode" }
end

-- Vertical curves: a height profile (vs: distances, zs: heights at them) averaged over `len` metres
-- around each point - the average of straight grades is a parabola where they meet, the rail
-- builder's vertical curve. The window shrinks towards the ends, so the end heights stay.
local function smoothProfile(vs : {number}, zs : {number}, len : number) : {number}
	local n = #vs
	if n < 3 or len <= 0 then return zs end
	-- the integral of the (piecewise straight) profile up to each point
	local I : {number} = { 0 }
	for k = 2, n do I[k] = I[k - 1] + (zs[k - 1] + zs[k]) / 2 * (vs[k] - vs[k - 1]) end
	local function integral(s : number) : number
		if s <= vs[1] then return 0 end
		if s >= vs[n] then return I[n] end
		local lo, hi = 1, n
		while hi - lo > 1 do
			local mid = math.floor((lo + hi) / 2)
			if vs[mid] <= s then lo = mid else hi = mid end
		end
		local ds = vs[hi] - vs[lo]
		local u = ds > 1e-9 and (s - vs[lo]) / ds or 0
		local zAt = zs[lo] + (zs[hi] - zs[lo]) * u
		return I[lo] + (zs[lo] + zAt) / 2 * (s - vs[lo])
	end
	local out : {number} = {}
	local total = vs[n]
	for k = 1, n do
		local s = vs[k]
		local h = math.min(len / 2, s - vs[1], total - s)
		if h < 0.5 then out[k] = zs[k]
		else out[k] = (integral(s + h) - integral(s - h)) / (2 * h) end
	end
	return out
end

-- The planned route's height profile, for the panel's Profile card (its chart, grade bands and
-- steepest-grade bar). Connect hands its pieces over each time it plans (setProfile); the panel
-- reads `profile` and polls `profileVersion` (bumped only when the route changes).
-- a piece of the route, for the table: its length, tightest radius (plan), grade, height above (+) /
-- below (-) the ground at its middle, and what Connect builds it as
local record PieceRow
	len : number
	radius : number
	grade : number
	height : number
	kind : string       -- "normal", "bridge", "tunnel"
end
local record Profile
	s : {number}        -- distance along the route (m)
	z : {number}        -- the route's height
	ground : {number}   -- the ground's height there
	grade : {number}    -- the grade from each point to the next (fraction, signed)
	steep : number      -- the steepest grade (fraction)
	limit : number      -- the type's steepest grade (fraction)
	length : number
	rows : {PieceRow}   -- one per piece to build (the panel's Route pieces table)
end
-- the tightest radius along a cubic Hermite piece (plan view)
local function pieceMinRadius(pc : Piece) : number
	local best = math.huge
	for i = 0, 16 do
		local u = i / 16
		local a0, a1, a2, a3 = 6 * u * u - 6 * u, 3 * u * u - 4 * u + 1, -6 * u * u + 6 * u, 3 * u * u - 2 * u
		local b0, b1, b2, b3 = 12 * u - 6, 6 * u - 4, -12 * u + 6, 6 * u - 2
		local dx = a0 * pc.p0.x + a1 * pc.t0.x + a2 * pc.p1.x + a3 * pc.t1.x
		local dy = a0 * pc.p0.y + a1 * pc.t0.y + a2 * pc.p1.y + a3 * pc.t1.y
		local ddx = b0 * pc.p0.x + b1 * pc.t0.x + b2 * pc.p1.x + b3 * pc.t1.x
		local ddy = b0 * pc.p0.y + b1 * pc.t0.y + b2 * pc.p1.y + b3 * pc.t1.y
		local cr = math.abs(dx * ddy - dy * ddx)
		local v = math.sqrt(dx * dx + dy * dy)
		if cr > 1e-9 then best = math.min(best, v * v * v / cr) end
	end
	return best
end
local g_profileKey : string = nil
local M_profile : {string : any} = { profile = nil, version = 0 }
local function setProfile(pieces : {Piece}, ground : function(number, number) : number, limit : number, classify? : function(Piece) : string)
	if not pieces or #pieces == 0 then
		if g_profileKey ~= nil then g_profileKey = nil; M_profile.profile = nil; M_profile.version = (M_profile.version as integer) + 1 end
		return
	end
	-- (the same route again: nothing to do - this runs every render)
	local a, b = pieces[1], pieces[#pieces]
	local key = string.format("%d,%.1f,%.1f,%.1f,%.1f,%.1f,%.1f,%.4f", #pieces, a.p0.x, a.p0.y, a.p0.z, b.p1.x, b.p1.y, b.p1.z, limit or 0)
	if key == g_profileKey then return end
	g_profileKey = key
	-- points along every piece (a cubic Hermite in 3D), then thinned to at most ~150
	local xs, ys, zs : {number}, {number}, {number} = {}, {}, {}
	for k, pc in ipairs(pieces) do
		for i = (k == 1 and 0 or 1), 8 do
			local u = i / 8
			local u2, u3 = u * u, u * u * u
			local h0, h1, h2, h3 = 2 * u3 - 3 * u2 + 1, u3 - 2 * u2 + u, -2 * u3 + 3 * u2, u3 - u2
			xs[#xs + 1] = h0 * pc.p0.x + h1 * pc.t0.x + h2 * pc.p1.x + h3 * pc.t1.x
			ys[#ys + 1] = h0 * pc.p0.y + h1 * pc.t0.y + h2 * pc.p1.y + h3 * pc.t1.y
			zs[#zs + 1] = h0 * pc.p0.z + h1 * pc.t0.z + h2 * pc.p1.z + h3 * pc.t1.z
		end
	end
	local stepN = math.max(1, math.ceil(#xs / 150))
	local p : Profile = { s = {}, z = {}, ground = {}, grade = {}, steep = 0, limit = limit or 0.04, length = 0 }
	local s = 0.0
	local lastI = 1
	for i = 1, #xs do
		if i > 1 then s = s + len2(xs[i] - xs[i - 1], ys[i] - ys[i - 1]) end
		if i == 1 or i == #xs or (i - lastI) >= stepN then
			p.s[#p.s + 1] = s
			p.z[#p.z + 1] = zs[i]
			p.ground[#p.ground + 1] = ground(xs[i], ys[i]) or zs[i]
			lastI = i
		end
	end
	for i = 1, #p.s - 1 do
		local ds = p.s[i + 1] - p.s[i]
		local g = ds > 0.5 and (p.z[i + 1] - p.z[i]) / ds or 0
		p.grade[i] = g
		p.steep = math.max(p.steep, math.abs(g))
	end
	p.length = s
	-- the pieces, for the table
	p.rows = {}
	for __, pc in ipairs(pieces) do
		local L = 0.0
		local px, py = pc.p0.x, pc.p0.y
		for i = 1, 8 do
			local u = i / 8
			local u2, u3 = u * u, u * u * u
			local h0, h1, h2, h3 = 2 * u3 - 3 * u2 + 1, u3 - 2 * u2 + u, -2 * u3 + 3 * u2, u3 - u2
			local x = h0 * pc.p0.x + h1 * pc.t0.x + h2 * pc.p1.x + h3 * pc.t1.x
			local y = h0 * pc.p0.y + h1 * pc.t0.y + h2 * pc.p1.y + h3 * pc.t1.y
			L = L + len2(x - px, y - py)
			px, py = x, y
		end
		local mx = 0.5 * (pc.p0.x + pc.p1.x) + 0.125 * (pc.t0.x - pc.t1.x)
		local my = 0.5 * (pc.p0.y + pc.p1.y) + 0.125 * (pc.t0.y - pc.t1.y)
		local mz = 0.5 * (pc.p0.z + pc.p1.z) + 0.125 * (pc.t0.z - pc.t1.z)
		local okK, kind = true, "normal"
		if classify then okK, kind = pcall(classify, pc) end
		p.rows[#p.rows + 1] = {
			len = L,
			radius = pieceMinRadius(pc),
			grade = L > 0.5 and (pc.p1.z - pc.p0.z) / L or 0,
			height = mz - (ground(mx, my) or mz),
			kind = okK and kind or "normal",
		}
	end
	M_profile.profile = p
	M_profile.version = (M_profile.version as integer) + 1
end

-- Snapping a chain back together: an end of the section being edited dropped near an end of another
-- section of the chain (kept, or after) lands exactly on it - Build then merges the two into one
-- node - and leaves it the way that section's road arrives there, so the joint is smooth. The way
-- comes from that section's planned segments (its proposal): an end dragged apart has lost the
-- direction its pick carried. Returns a pick ({kind, node, edge, pos, dir}) or nil.
local CHAIN_SNAP_M = 12
local CHAIN_BRANCH_M = 8   -- metres from another section's centre line: a branch off its middle
local CHAIN_NODE_M = 10    -- ... this close (along it) to one of its nodes: onto that node

-- a planned segment's point and horizontal direction at t; c: {p0, p1, t0, t1 as x, y, z} (plain
-- numbers - see segsOf)
local function segAt(c : {number}, t : number) : number, number, number, number, number
	local t2, t3 = t * t, t * t * t
	local h00, h10, h01, h11 = 2 * t3 - 3 * t2 + 1, t3 - 2 * t2 + t, -2 * t3 + 3 * t2, t3 - t2
	local d00, d10, d01, d11 = 6 * t2 - 6 * t, 3 * t2 - 4 * t + 1, -6 * t2 + 6 * t, 3 * t2 - 2 * t
	return h00 * c[1] + h10 * c[7] + h01 * c[4] + h11 * c[10],
		h00 * c[2] + h10 * c[8] + h01 * c[5] + h11 * c[11],
		h00 * c[3] + h10 * c[9] + h01 * c[6] + h11 * c[12],
		d00 * c[1] + d10 * c[7] + d01 * c[4] + d11 * c[10],
		d00 * c[2] + d10 * c[8] + d01 * c[5] + d11 * c[11]
end

-- The other sections' planned segments as plain numbers: {p0, p1, t0, t1 (x, y, z each), track (1/0),
-- box x0, y0, x1, y1}. Read from the game's proposals once while they stay the same (a drag asks on
-- every mouse move; reading the game's vectors per sample dropped the frame rate)
local g_segs : {{number}} = {}
local g_segsKey = ""
local function segsOf(verdict : {string : any}) : {{number}}
	local props : {any} = {}
	for __, p in ipairs((verdict.chain or {}) as {any}) do props[#props + 1] = p end
	for __, af in ipairs((verdict.after or {}) as {{string : any}}) do props[#props + 1] = af.proposal end
	local keys : {string} = {}
	for i, p in ipairs(props) do keys[i] = tostring(p) end
	local key = table.concat(keys, ",")
	if key == g_segsKey then return g_segs end
	local segs : {{number}} = {}
	for __, prop in ipairs(props) do
		pcall(function()
			for __, s in ipairs((prop as {string : any}).streetProposal.edgesToAdd as {{string : any}}) do
				local c = s.comp as {string : any}
				local p0, p1 = c.position0 as P3, c.position1 as P3
				local t0, t1 = c.tangent0 as P3, c.tangent1 as P3
				local g = { p0.x, p0.y, p0.z, p1.x, p1.y, p1.z, t0.x, t0.y, t0.z, t1.x, t1.y, t1.z,
					(s.type as integer) == 1 and 1 or 0 }
				-- the curve lies inside its Bezier control points' box
				local xs = { g[1], g[1] + g[7] / 3, g[4] - g[10] / 3, g[4] }
				local ys = { g[2], g[2] + g[8] / 3, g[5] - g[11] / 3, g[5] }
				g[14], g[15] = math.min(xs[1], xs[2], xs[3], xs[4]), math.min(ys[1], ys[2], ys[3], ys[4])
				g[16], g[17] = math.max(xs[1], xs[2], xs[3], xs[4]), math.max(ys[1], ys[2], ys[3], ys[4])
				segs[#segs + 1] = g
			end
		end)
	end
	g_segs, g_segsKey = segs, key
	return segs
end

-- The nearest point (x, y) along the other sections' planned roads, within maxD: {x, y, z, dx, dy,
-- track} (dx, dy: the road's unit direction there), or nil
local function onSections(x : number, y : number, verdict : {string : any}, maxD : number) : {string : any}
	local best : {string : any} = nil
	local bestD = maxD
	for __, c in ipairs(segsOf(verdict)) do
		-- (only a segment whose box is within reach)
		if x >= c[14] - maxD and x <= c[16] + maxD and y >= c[15] - maxD and y <= c[17] + maxD then
			do
				-- coarse samples, then a few halvings around the nearest
				local N = 24
				local bt, bd = 0.0, math.huge
				for i = 0, N do
					local px, py = segAt(c, i / N)
					local d = len2(px - x, py - y)
					if d < bd then bt, bd = i / N, d end
				end
				local h = 1 / N
				for __ = 1, 8 do
					h = h / 2
					for __, t in ipairs({ bt - h, bt + h }) do
						if t >= 0 and t <= 1 then
							local px, py = segAt(c, t)
							local d = len2(px - x, py - y)
							if d < bd then bt, bd = t, d end
						end
					end
				end
				if bd < bestD then
					-- close to the segment's end (a node of that section): that node - the game never
					-- leaves a stub between a junction and a node (its road tool moves the node instead)
					local L = 0.0
					local qx, qy = segAt(c, 0)
					for i = 1, 16 do
						local rx, ry = segAt(c, i / 16)
						L = L + len2(rx - qx, ry - qy)
						qx, qy = rx, ry
					end
					if bt * L < CHAIN_NODE_M then bt = 0 elseif (1 - bt) * L < CHAIN_NODE_M then bt = 1 end
					local px, py, pz, dx, dy = segAt(c, bt)
					local l = len2(dx, dy)
					if l > 1e-6 then
						bestD = bd
						best = { x = px, y = py, z = pz, dx = dx / l, dy = dy / l, track = c[13] == 1 }
					end
				end
			end
		end
	end
	return best
end

local function chainSnap(x : number, y : number, verdict : {string : any}, posOf : function(any) : (P3), toward : P3) : {string : any}
	local best : {string : any} = nil
	local bestD = CHAIN_SNAP_M
	local bestProp : any = nil
	local function consider(pick : {string : any}, prop : any)
		if not pick then return end
		local P = posOf(pick)
		if not P then return end
		local d = len2(P.x - x, P.y - y)
		if d < bestD then best, bestD, bestProp = pick, d, prop end
	end
	local chain = (verdict.chain or {}) as {any}
	for i, sn in ipairs((verdict.chainSnaps or {}) as {{string : any}}) do
		consider(sn.a as {string : any}, chain[i])
		consider(sn.b as {string : any}, chain[i])
	end
	for __, af in ipairs((verdict.after or {}) as {{string : any}}) do
		local sn = af.snap as {string : any}
		if sn then
			consider(sn.a as {string : any}, af.proposal)
			consider(sn.b as {string : any}, af.proposal)
		end
	end
	if not best then
		-- no end close by: a point along another section's road - a branch off its middle (Build splits
		-- that section's segment there: one junction node). At the road's height there; a track leaves
		-- along the track (a switch), the way towards this section's other end
		local on = onSections(x, y, verdict, CHAIN_BRANCH_M)
		if not on then return nil end
		-- (axis: the line it leaves along - Connect takes the side towards the section's other end. A
		-- track along the track (a switch); a road at right angles (a T: the game refuses a junction
		-- whose roads meet at a shallow angle, overlapping past the node))
		local dx, dy = on.dx as number, on.dy as number
		local pick : {string : any} = { kind = "free", pos = { x = on.x, y = on.y, z = on.z }, branch = true,
			axis = on.track and { dx, dy } or { -dy, dx } }
		return pick
	end
	-- a node: that node, as it is (its own roads give the way)
	if best.kind == "node" then return { kind = "node", node = best.node, edge = best.edge } end
	local P = posOf(best)
	-- the way that section's road leaves P (into that section), from its segment ending there
	local outX, outY : number, number = nil, nil
	pcall(function()
		local edges = (bestProp as {string : any}).streetProposal.edgesToAdd as {{string : any}}
		for __, s in ipairs(edges) do
			local c = s.comp as {string : any}
			local p0, p1 = c.position0 as P3, c.position1 as P3
			local t0, t1 = c.tangent0 as P3, c.tangent1 as P3
			if len2(p0.x - P.x, p0.y - P.y) < 1.5 then
				local l = len2(t0.x, t0.y)
				if l > 1e-6 then outX, outY = t0.x / l, t0.y / l end
			elseif len2(p1.x - P.x, p1.y - P.y) < 1.5 then
				local l = len2(t1.x, t1.y)
				if l > 1e-6 then outX, outY = -t1.x / l, -t1.y / l end
			end
			if outX then break end
		end
	end)
	local pick : {string : any} = { kind = "free", pos = { x = P.x, y = P.y, z = P.z } }
	-- (this section leaves the joint opposite to the way the other one does - both ends' dir is the
	-- way the new road leaves its point)
	if outX then pick.dir = { -outX, -outY } end
	return pick
end

-- Where chainSnap can land, for the overlay: the ends of the other sections that are loose (not
-- shared with another section, nor with this section's own ends) - rings - and, while one of this
-- section's ends (dragK: 1 / 2, else 0) is dragged onto one, that one - hot. {x, y, r} each.
local function chainSnapRings(verdict : {string : any}, posOf : function(any) : (P3), a : any, b : any,
		dragK : integer) : {{string : number}}, {{string : number}}
	local ends : {{number}} = {}   -- {x, y, section}
	local function addEnd(pick : any, si : integer)
		local P = pick and posOf(pick)
		if P then ends[#ends + 1] = { P.x, P.y, si } end
	end
	local n = 0
	for __, sn in ipairs((verdict.chainSnaps or {}) as {{string : any}}) do
		n = n + 1
		addEnd(sn.a, n)
		addEnd(sn.b, n)
	end
	for __, af in ipairs((verdict.after or {}) as {{string : any}}) do
		n = n + 1
		local sn = (af.snap or {}) as {string : any}
		addEnd(sn.a, n)
		addEnd(sn.b, n)
	end
	local A, B = a and posOf(a), b and posOf(b)
	local function near(P : P3, x : number, y : number) : boolean
		return P ~= nil and (P.x - x) ^ 2 + (P.y - y) ^ 2 < 1
	end
	local rings, hot : {{string : number}}, {{string : number}} = {}, {}
	local done : {{number}} = {}
	for i, e in ipairs(ends) do
		local skip = false
		for j, o in ipairs(ends) do
			if j ~= i and o[3] ~= e[3] and (o[1] - e[1]) ^ 2 + (o[2] - e[2]) ^ 2 < 1 then skip = true; break end
		end
		for __, d in ipairs(done) do
			if (d[1] - e[1]) ^ 2 + (d[2] - e[2]) ^ 2 < 1 then skip = true; break end
		end
		if not skip then
			done[#done + 1] = e
			local onA, onB = near(A, e[1], e[2]), near(B, e[1], e[2])
			if (onA and dragK == 1) or (onB and dragK == 2) then
				hot[#hot + 1] = { x = e[1], y = e[2], r = CHAIN_SNAP_M }
			elseif not onA and not onB then
				rings[#rings + 1] = { x = e[1], y = e[2], r = CHAIN_SNAP_M }
			end
		end
	end
	-- the dragged end on another section's middle (a branch): marked there
	local D = (dragK == 1 and A) or (dragK == 2 and B) or nil
	if D and #hot == 0 then
		local on = onSections(D.x, D.y, verdict, 0.5)
		if on then hot[#hot + 1] = { x = on.x as number, y = on.y as number, r = CHAIN_BRANCH_M } end
	end
	return rings, hot
end

-- the modes that run through clicked waypoints
local function usesWaypoints(mode : integer) : boolean
	return mode == MODE_SPLINE or mode == MODE_ARC
end

return {
	FIRST = MODE_EASE,
	LAST = MODE_OFFSET,
	EASE = MODE_EASE, HELIX = MODE_HELIX, GRADE = MODE_GRADE, SPLINE = MODE_SPLINE, ARC = MODE_ARC, OFFSET = MODE_OFFSET,
	opts = opts,
	generate = generate,
	usesWaypoints = usesWaypoints,
	smoothProfile = smoothProfile,
	-- the height profile (setProfile from Connect; the panel reads state.profile, polls state.version)
	setProfile = setProfile,
	state = M_profile,
	-- a chain's sections snapped back together (Connect's end clicks and drags)
	chainSnap = chainSnap,
	chainSnapRings = chainSnapRings,
}
