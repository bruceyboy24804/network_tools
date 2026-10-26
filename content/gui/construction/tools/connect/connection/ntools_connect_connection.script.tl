-- Network Tools: Connect - Connection mode: an arc leaving each road, joined by straights, with any
-- number of free circles between them (CS1 CreateConnection). Drag a circle centre: along the road =
-- move the arc, away = radius, across the road = turn the other way.
--
-- Set up by the Connect tool with its shared helpers (ctx): it owns the height profile
-- (buildFromPrims), which depends on the tool's live settings.

local record P3
	x : number
	y : number
	z : number
	lift : number
end

local record Prim
	sweep : number
end

local record ConnCircle
	offset : number
	radius : number
	side : number
	lift : number
	liftEnd : number
	structure : integer
end

local record MidCircle
	x : number
	y : number
	radius : number
	orient : number
	lift : number
	liftEnd : number
	structure : integer
end

local record ConnState
	first : ConnCircle
	last : ConnCircle
	middle : {MidCircle}
end

local record Circ
	x : number
	y : number
	r : number
	w : number
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
end

local record GenResult
	pieces : {any}
	error : string
	handles : {P3}
	circles : {Circle2}
	straights : {Line2}
	info : string
end

local record Ctx
	MIN_RADIUS : number
	MAX_RADIUS : number
	DEFAULT_RADIUS : number
	MAX_GUIDE_T : number
	p3 : function(x : number, y : number, z : number) : P3
	clamp : function(v : number, lo : number, hi : number) : number
	cross2 : function(ax : number, ay : number, bx : number, by : number) : number
	dot2 : function(ax : number, ay : number, bx : number, by : number) : number
	norm2 : function(x : number, y : number) : number, number, number
	routePoints : function(A : P3, B : P3, wps : {P3}) : {P3}
	linePrim : function(px : number, py : number, qx : number, qy : number) : Prim
	arcPrim : function(cx : number, cy : number, r : number, sx : number, sy : number, ex : number, ey : number, orient : number) : Prim
	buildFromPrims : function(prims : {Prim}, A : P3, B : P3, followTerrain : boolean) : {any}
	fmtLen : function(m : number) : string
	fmtDeg : function(rad : number) : string
end

local record Connection
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

return function(ctx : Ctx) : Connection
	local p3, clamp, cross2, dot2, norm2 = ctx.p3, ctx.clamp, ctx.cross2, ctx.dot2, ctx.norm2
	local linePrim, fmtLen, fmtDeg = ctx.linePrim, ctx.fmtLen, ctx.fmtDeg
	local MIN_RADIUS, MAX_RADIUS, DEFAULT_RADIUS = ctx.MIN_RADIUS, ctx.MAX_RADIUS, ctx.DEFAULT_RADIUS

	local SNAP_TANGENT_RANGE = 10   -- snap the arcs together when within this many metres of radius

	-- Circle centre and tangent point for one end of a Connection.
	local function connCircleGeom(P : P3, gx : number, gy : number, c : ConnCircle) : number, number, number, number
		local tx, ty = P.x + gx * c.offset, P.y + gy * c.offset
		-- left normal of the road direction
		local nx, ny = -gy, gx
		return tx + nx * c.radius * c.side, ty + ny * c.radius * c.side, tx, ty
	end

	-- radius of the circle a waypoint becomes in Connection
	local WAYPOINT_RADIUS = DEFAULT_RADIUS / 2

	local function defaultConnState(A : P3, B : P3, ax : number, ay : number, bx : number, by : number, wps? : {P3}) : ConnState
		local pts = ctx.routePoints(A, B, wps)
		local n = #pts
		-- turn each arc towards the next point (CS1 EdgeCircle.GetSides)
		local side1 = cross2(ax, ay, pts[2].x - A.x, pts[2].y - A.y) >= 0 and 1 or -1
		local side2 = cross2(bx, by, pts[n - 1].x - B.x, pts[n - 1].y - B.y) >= 0 and 1 or -1
		-- every waypoint: a circle on the inside of the turn there, its rim touching the waypoint
		local middle : {MidCircle} = {}
		for i = 2, n - 1 do
			local p, w, q = pts[i - 1], pts[i], pts[i + 1]
			local orient = cross2(w.x - p.x, w.y - p.y, q.x - w.x, q.y - w.y) >= 0 and 1 or -1
			local dx, dy = norm2(q.x - p.x, q.y - p.y)
			middle[#middle + 1] = { x = w.x - dy * WAYPOINT_RADIUS * orient, y = w.y + dx * WAYPOINT_RADIUS * orient,
				radius = WAYPOINT_RADIUS, orient = orient, lift = w.lift }
		end
		return {
			first = { offset = 0, radius = DEFAULT_RADIUS, side = side1 },
			last = { offset = 0, radius = DEFAULT_RADIUS, side = side2 },
			middle = middle,
		}
	end

	-- All circles of a Connection in travel order, with their travel orientation w
	-- (+1 = counter-clockwise), plus the tangent points on the two roads.
	local function connCircles(A : P3, B : P3, ax : number, ay : number, bx : number, by : number, st : ConnState) : {Circ}, number, number, number, number
		local c1x, c1y, t1x, t1y = connCircleGeom(A, ax, ay, st.first)
		local c2x, c2y, t2x, t2y = connCircleGeom(B, bx, by, st.last)
		local circs : {Circ} = { { x = c1x, y = c1y, r = st.first.radius, w = st.first.side } }
		for _, m in ipairs(st.middle or {}) do
			circs[#circs + 1] = { x = m.x, y = m.y, r = m.radius, w = m.orient }
		end
		-- travelling INTO B reverses the orientation seen from B
		circs[#circs + 1] = { x = c2x, y = c2y, r = st.last.radius, w = -st.last.side }
		return circs, t1x, t1y, t2x, t2y
	end

	-- Tangent line leaving circle a and entering circle b in their travel orientations.
	-- With w the unit normal, X_a = Ca + wa*ra*w and X_b = Cb + wb*rb*w need
	-- dot(Cb - Ca, w) = wa*ra - wb*rb. Returns nil if the circles overlap that way.
	local function tangentBetween(a : Circ, b : Circ) : number, number, number, number
		local dx, dy = b.x - a.x, b.y - a.y
		local dist = math.sqrt(dx * dx + dy * dy)
		local rho = a.w * a.r - b.w * b.r
		if dist < 1e-3 or math.abs(rho) > dist then
			return nil
		end
		local psi = math.atan2(dy, dx) - math.acos(rho / dist)
		local wx, wy = math.cos(psi), math.sin(psi)
		return a.x + a.w * a.r * wx, a.y + a.w * a.r * wy, b.x + b.w * b.r * wx, b.y + b.w * b.r * wy
	end

	-- Squared tangent length between two circles (negative = they overlap that way).
	local function gapBetween(a : Circ, b : Circ) : number
		local rho = a.w * a.r - b.w * b.r
		return (b.x - a.x) ^ 2 + (b.y - a.y) ^ 2 - rho * rho
	end

	-- CS1 CreateConnection: arc from A, then any number of circles joined by tangent straights, arc into B.
	local function genConnection(A : P3, B : P3, ax : number, ay : number, bx : number, by : number, st : ConnState, followTerrain : boolean) : GenResult
		local z = (A.z + B.z) / 2
		local circs, t1x, t1y, t2x, t2y = connCircles(A, B, ax, ay, bx, by, st)
		local n = #circs

		local result : GenResult = { handles = {}, circles = {}, straights = {} }
		for _, c in ipairs(circs) do
			result.handles[#result.handles + 1] = p3(c.x, c.y, z)
			result.circles[#result.circles + 1] = { x = c.x, y = c.y, r = c.r }
		end

		-- entry/exit points on every circle
		local ex : {number} = {}
		local ey : {number} = {}
		local nx : {number} = { t1x }
		local ny : {number} = { t1y }
		for k = 1, n - 1 do
			local x1, y1, x2, y2 = tangentBetween(circs[k], circs[k + 1])
			if not x1 then
				result.error = _("Circles") .. " " .. tostring(k) .. " & " .. tostring(k + 1)
					.. " " .. _("overlap - move one away or make it smaller")
				return result
			end
			ex[k], ey[k] = x1, y1
			nx[k + 1], ny[k + 1] = x2, y2
			result.straights[k] = { x0 = x1, y0 = y1, x1 = x2, y1 = y2 }
		end
		ex[n], ey[n] = t2x, t2y

		local prims : {Prim} = { linePrim(A.x, A.y, t1x, t1y) }
		local arcInfo : {string} = {}
		local straightInfo : {string} = {}
		for k = 1, n do
			local c = circs[k]
			local arc = ctx.arcPrim(c.x, c.y, c.r, nx[k], ny[k], ex[k], ey[k], c.w)
			prims[#prims + 1] = arc
			arcInfo[#arcInfo + 1] = fmtLen(c.r) .. " " .. fmtDeg(arc.sweep)
			if k < n then
				prims[#prims + 1] = linePrim(ex[k], ey[k], nx[k + 1], ny[k + 1])
				straightInfo[#straightInfo + 1] = fmtLen(math.sqrt((nx[k + 1] - ex[k]) ^ 2 + (ny[k + 1] - ey[k]) ^ 2))
			end
		end
		prims[#prims + 1] = linePrim(t2x, t2y, B.x, B.y)

		result.pieces = ctx.buildFromPrims(prims, A, B, followTerrain)
		-- CS1 shows these as labels on the circles and straights
		result.info = _("Arcs") .. ": " .. table.concat(arcInfo, ", ")
			.. "   " .. _("Straights") .. ": " .. table.concat(straightInfo, ", ")
		return result
	end

	------------------------------------------------------------------------------------------------
	-- State editing (circle index: 1 = first end, 2..n-1 = middle, n = last end)

	local function connCount(st : ConnState) : integer
		return 2 + #(st.middle or {})
	end

	local function copyConn(st : ConnState) : ConnState
		local middle : {MidCircle} = {}
		for i, m in ipairs(st.middle or {}) do
			middle[i] = { x = m.x, y = m.y, radius = m.radius, orient = m.orient, lift = m.lift, liftEnd = m.liftEnd, structure = m.structure }
		end
		return {
			first = { offset = st.first.offset, radius = st.first.radius, side = st.first.side, lift = st.first.lift,
				liftEnd = st.first.liftEnd, structure = st.first.structure },
			last = { offset = st.last.offset, radius = st.last.radius, side = st.last.side, lift = st.last.lift,
				liftEnd = st.last.liftEnd, structure = st.last.structure },
			middle = middle,
		}
	end

	local function radiusOf(st : ConnState, idx : integer) : number
		if idx == 1 then return st.first.radius end
		if idx == connCount(st) then return st.last.radius end
		return st.middle[idx - 1].radius
	end

	local function withRadius(st : ConnState, idx : integer, r : number) : ConnState
		local nst = copyConn(st)
		r = clamp(r, MIN_RADIUS, MAX_RADIUS)
		if idx == 1 then
			nst.first.radius = r
		elseif idx == connCount(st) then
			nst.last.radius = r
		else
			nst.middle[idx - 1].radius = r
		end
		return nst
	end

	-- Flip which way a circle turns (CS1: double-click a circle centre).
	local function flipCircle(st : ConnState, idx : integer) : ConnState
		local nst = copyConn(st)
		if idx == 1 then
			nst.first.side = -nst.first.side
		elseif idx == connCount(st) then
			nst.last.side = -nst.last.side
		else
			nst.middle[idx - 1].orient = -nst.middle[idx - 1].orient
		end
		return nst
	end

	-- Insert a free circle into straight number k (between circle k and k+1), centred at (x, y)
	-- and turning towards the side it sits on (CS1: double-click a straight).
	local function insertCircle(st : ConnState, k : integer, straight : Line2, x : number, y : number) : ConnState
		local nst = copyConn(st)
		local side = cross2(straight.x1 - straight.x0, straight.y1 - straight.y0, x - straight.x0, y - straight.y0)
		table.insert(nst.middle, k, { x = x, y = y, radius = DEFAULT_RADIUS / 2, orient = side >= 0 and 1 or -1 })
		return nst
	end

	-- Like insertCircle, but the circle sits beyond (x, y) so the road passes through that point
	-- (a waypoint clicked in Connection).
	local function insertCircleThrough(st : ConnState, k : integer, straight : Line2, x : number, y : number) : ConnState
		local dx, dy = norm2(straight.x1 - straight.x0, straight.y1 - straight.y0)
		local orient = cross2(dx, dy, x - straight.x0, y - straight.y0) >= 0 and 1 or -1
		return insertCircle(st, k, straight, x - dy * WAYPOINT_RADIUS * orient, y + dx * WAYPOINT_RADIUS * orient)
	end

	local function removeCircle(st : ConnState, idx : integer) : ConnState
		if idx <= 1 or idx >= connCount(st) then
			return st
		end
		local nst = copyConn(st)
		table.remove(nst.middle, idx - 1)
		return nst
	end

	local function moveMiddle(st : ConnState, idx : integer, x : number, y : number) : ConnState
		local nst = copyConn(st)
		local m = nst.middle[idx - 1]
		if m then
			m.x, m.y = x, y
		end
		return nst
	end

	-- Snap a circle's radius so it meets a neighbouring circle directly (the straight between them
	-- disappears, CS1 circle snapping) when that is within SNAP_TANGENT_RANGE metres; otherwise round
	-- the radius to `roundStep`.
	local function snapRadius(A : P3, B : P3, ax : number, ay : number, bx : number, by : number, st : ConnState, idx : integer, roundStep : number) : ConnState
		local n = connCount(st)
		local neighbours : {integer} = {}
		if idx > 1 then neighbours[#neighbours + 1] = idx - 1 end
		if idx < n then neighbours[#neighbours + 1] = idx + 1 end

		local function gapsFor(s : ConnState) : {number}
			local circs = connCircles(A, B, ax, ay, bx, by, s)
			local g : {number} = {}
			for i, nb in ipairs(neighbours) do
				local lo, hi = math.min(idx, nb), math.max(idx, nb)
				g[i] = gapBetween(circs[lo], circs[hi])
			end
			return g
		end

		local r0 = radiusOf(st, idx)
		local g0 = gapsFor(st)
		local step = 0.5
		local k = 1
		while k * step <= SNAP_TANGENT_RANGE do
			for _, dir in ipairs({ 1, -1 }) do
				local r1 = r0 + dir * k * step
				if r1 >= MIN_RADIUS and r1 <= MAX_RADIUS then
					local g1 = gapsFor(withRadius(st, idx, r1))
					for i = 1, #neighbours do
						if (g0[i] >= 0) ~= (g1[i] >= 0) then
							-- bisect between r1 - dir*step and r1 on this neighbour's gap
							local lo, hi = r1 - dir * step, r1
							for _ = 1, 30 do
								local mid = (lo + hi) / 2
								local gm = gapsFor(withRadius(st, idx, mid))[i]
								if (gm >= 0) == (g0[i] >= 0) then lo = mid else hi = mid end
							end
							-- land on the non-overlapping side
							local rv = gapsFor(withRadius(st, idx, lo))[i] >= 0 and lo or hi
							return withRadius(st, idx, rv)
						end
					end
				end
			end
			k = k + 1
		end
		if roundStep and roundStep > 0 then
			return withRadius(st, idx, math.floor(r0 / roundStep + 0.5) * roundStep)
		end
		return st
	end

	-- Drag an end circle's centre to (mx, my): the circle slides along its road only
	-- (CS1 CreateConnectionMoveCircle on an EdgeCircle). Radius is changed from the rim,
	-- the turning side by double-clicking the centre.
	local function dragConnCircle(P : P3, gx : number, gy : number, c : ConnCircle, mx : number, my : number) : ConnCircle
		local vx, vy = mx - P.x, my - P.y
		return {
			offset = clamp(dot2(vx, vy, gx, gy), 0, ctx.MAX_GUIDE_T),
			radius = c.radius,
			side = c.side,
			lift = c.lift,
			liftEnd = c.liftEnd,
			structure = c.structure,
		}
	end

	-- A copy of the state with circle idx (1 = first end, n = last end, else a middle circle) changed by
	-- `set` (it gets the circle's own record: a ConnCircle or a MidCircle; the shared fields are the same)
	local function withCircle(st : ConnState, idx : integer, set : function(c : ConnCircle, m : MidCircle)) : ConnState
		local nst = copyConn(st)
		if idx == 1 then
			set(nst.first, nil)
		elseif idx == connCount(st) then
			set(nst.last, nil)
		elseif nst.middle[idx - 1] then
			set(nil, nst.middle[idx - 1])
		end
		return nst
	end

	return {
		defaultConnState = defaultConnState,
		connCircles = connCircles,
		genConnection = genConnection,
		connCount = connCount,
		copyConn = copyConn,
		radiusOf = radiusOf,
		withRadius = withRadius,
		flipCircle = flipCircle,
		insertCircle = insertCircle,
		insertCircleThrough = insertCircleThrough,
		removeCircle = removeCircle,
		moveMiddle = moveMiddle,
		snapRadius = snapRadius,
		dragConnCircle = dragConnCircle,
		withCircle = withCircle,
	}
end
