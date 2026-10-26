-- Network Tools: Shape - Ease mode: the bend becomes a railway-style eased curve: straight,
-- transition spiral (the curvature grows evenly), circular arc, spiral back to straight. It fills the
-- corner the two end directions make, as wide as the ends allow; Transition = how much of the turn is
-- spiral (0 % = a plain arc, 100 % = all spiral). The nodes slide onto it keeping their spacing - more
-- nodes follow it closer (Add node first on a short stretch).
--
-- Set up by the Shape tool with its shared helpers (ctx).

local record P3
	x : number
	y : number
	z : number
end

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
end

local record Options
	transition : number
end

local record Ctx
	opts : Options
	p3 : function(x : number, y : number, z : number) : P3
	hdist : function(a : P3, b : P3) : number
	endDirections : function(chain : {ChainLink}) : P3, P3
	linkCurve : function(link : ChainLink, t0 : P3, t1 : P3) : Curve
	gradedTangent : function(dx : number, dy : number, len : number, z0 : number, z1 : number, hChord : number) : P3
end

local record Ease
	computeEase : function(chain : {ChainLink}, nodes : {Engine.Entity}, P : {P3}, s : {number}) : Shape
end

-- Ease: the eased curve from P1 (leaving along d0) to Pn (arriving along d1), as a polyline in plan
-- with the distance along it at every point. Built for radius 1 turning left, then scaled so it
-- touches both end lines as far out as the nearer end allows, and placed in the corner (mirrored for a
-- right turn); straights fill up to the ends. Returns the points, distances, the arc's radius and the
-- spiral length - or nil and why not.
local EASE_STEPS = 400
local record Polyline
	x : {number}
	y : {number}
	s : {number}
end
local function easedCurve(P1 : P3, d0 : P3, Pn : P3, d1 : P3, f : number) : Polyline, number, number, string
	local l0, l1 = math.sqrt(d0.x ^ 2 + d0.y ^ 2), math.sqrt(d1.x ^ 2 + d1.y ^ 2)
	if l0 < 1e-6 or l1 < 1e-6 then return nil, 0, 0, _("Can't read the road direction at one of the ends") end
	local ux, uy, vx, vy = d0.x / l0, d0.y / l0, d1.x / l1, d1.y / l1
	local cr, dt = ux * vy - uy * vx, ux * vx + uy * vy
	local delta = math.atan2(cr, dt)          -- signed turn, + = left
	local D = math.abs(delta)
	if D < math.rad(2) then return nil, 0, 0, _("The stretch hardly turns - use Straighten") end
	if D > math.rad(170) then return nil, 0, 0, _("The stretch turns back on itself - pick a bend under 170°") end
	-- the corner V: P1 + u d0 = Pn - w d1
	local ex, ey = Pn.x - P1.x, Pn.y - P1.y
	local u = (ex * vy - ey * vx) / cr
	local w = (ux * ey - uy * ex) / cr
	if u <= 1 or w <= 1 then
		return nil, 0, 0, _("The two end directions don't meet in front of the stretch - it isn't one bend")
	end
	-- the unit curve (R = 1): spiral angle f D / 2 each, spiral length 2 x that, the arc the rest
	local Ls = f * D
	local La = D - f * D
	local total = 2 * Ls + La
	local k = function(s : number) : number
		if Ls > 1e-9 and s < Ls then return s / Ls end
		if Ls > 1e-9 and s > Ls + La then return math.max(0, (total - s) / Ls) end
		return 1
	end
	local xs, ys = { 0.0 }, { 0.0 }
	local x, y, th = 0.0, 0.0, 0.0
	local h = total / EASE_STEPS
	for i = 1, EASE_STEPS do
		-- midpoint rule: heading at the middle of the step
		local s0 = (i - 1) * h
		local thMid = th + (k(s0) + k(s0 + h / 2)) / 2 * (h / 2)
		x, y = x + math.cos(thMid) * h, y + math.sin(thMid) * h
		th = th + (k(s0) + 4 * k(s0 + h / 2) + k(s0 + h)) / 6 * h
		xs[#xs + 1], ys[#ys + 1] = x, y
	end
	-- where the end line crosses the start line: the unit curve's tangent length (same at both ends)
	local T1 = x - y / math.sin(D) * math.cos(D)
	if T1 <= 1e-6 then return nil, 0, 0, _("Can't fit an eased curve here") end
	local R = math.min(u, w) / T1
	-- place it: start at V - T1 R d0, mirror for a right turn, turn to d0
	local sx, sy = P1.x + ux * (u - T1 * R), P1.y + uy * (u - T1 * R)
	local mir = delta < 0 and -1 or 1
	local out : Polyline = { x = { P1.x }, y = { P1.y }, s = { 0 } }
	local function push(px : number, py : number)
		local n = #out.x
		local d = math.sqrt((px - out.x[n]) ^ 2 + (py - out.y[n]) ^ 2)
		if d < 1e-4 then return end
		out.x[n + 1], out.y[n + 1], out.s[n + 1] = px, py, out.s[n] + d
	end
	for i = 1, #xs do
		local lx, ly = xs[i] * R, ys[i] * R * mir
		push(sx + ux * lx - uy * ly, sy + uy * lx + ux * ly)
	end
	-- (the integration can overshoot the end node by millimetres: drop what lies past it)
	while #out.x > 2 and (Pn.x - out.x[#out.x]) * vx + (Pn.y - out.y[#out.y]) * vy < 0 do
		out.x[#out.x], out.y[#out.y], out.s[#out.s] = nil, nil, nil
	end
	push(Pn.x, Pn.y)
	return out, R, Ls * R, nil
end

-- point and direction at distance s along a polyline
local function polyAt(pl : Polyline, s : number) : number, number, number, number
	local n = #pl.s
	local i = 2
	while i < n and pl.s[i] < s do i = i + 1 end
	local s0, s1 = pl.s[i - 1], pl.s[i]
	local t = s1 > s0 and math.max(0, math.min(1, (s - s0) / (s1 - s0))) or 0
	local dx, dy = pl.x[i] - pl.x[i - 1], pl.y[i] - pl.y[i - 1]
	return pl.x[i - 1] + dx * t, pl.y[i - 1] + dy * t, dx, dy
end

return function(ctx : Ctx) : Ease
	local function computeEase(chain : {ChainLink}, nodes : {Engine.Entity}, P : {P3}, s : {number}) : Shape
		local n = #nodes
		if n < 3 then
			return { why = _("Pick at least two segments (or add nodes first) - the ease moves the nodes in between") }
		end
		local d0, d1 = ctx.endDirections(chain)
		local pl, R, Ls, why = easedCurve(P[1], d0, P[n], d1, math.max(0, math.min(1, ctx.opts.transition)))
		if not pl then return { why = why } end
		local L = pl.s[#pl.s]
		-- the nodes keep their share of the length
		local S = s[n]
		local Q : {P3} = { P[1] }
		local along : {number} = { 0 }
		local dirs : {P3} = { d0 }
		for k = 2, n - 1 do
			local at = s[k] / S * L
			local x, y, dx, dy = polyAt(pl, at)
			Q[k], along[k], dirs[k] = ctx.p3(x, y, P[k].z), at, ctx.p3(dx, dy, 0)
		end
		Q[n], along[n], dirs[n] = P[n], L, d1
		local moves : {Engine.Entity : P3} = {}
		local maxMove = 0.0
		for k = 2, n - 1 do
			moves[nodes[k]] = Q[k]
			maxMove = math.max(maxMove, ctx.hdist(P[k], Q[k]))
		end
		local curves : {Engine.Entity : Curve} = {}
		for i, l in ipairs(chain) do
			local a, b = Q[i], Q[i + 1]
			local h = ctx.hdist(a, b)
			-- tangent length = the curve's length between the nodes (the Hermite then follows the arc)
			local len = math.max(h, along[i + 1] - along[i])
			local t0 = ctx.gradedTangent(dirs[i].x, dirs[i].y, len, a.z, b.z, h)
			local t1 = ctx.gradedTangent(dirs[i + 1].x, dirs[i + 1].y, len, a.z, b.z, h)
			curves[l.edge] = ctx.linkCurve(l, t0, t1)
		end
		local info = string.format("%s: %.0f m   %s: %.0f m   %s: %.1f m", _("Radius"), R, _("Transition"), Ls,
			_("Largest node move"), maxMove)
		-- a node per ~ 30 m of curve follows it closely; fewer and the curve between them is a guess
		if L / (n - 1) > 60 then
			info = info .. "\n" .. _("Few nodes for this curve - add some (Add node) for a closer fit")
		end
		return { moves = moves, curves = curves, info = info }
	end

	return { computeEase = computeEase }
end
