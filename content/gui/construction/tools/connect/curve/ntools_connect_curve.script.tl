-- Network Tools: Connect - Curve mode: a smooth curve following both road directions (CS1 CreateCurve),
-- through any waypoints.
--
-- Set up by the Connect tool with its shared helpers (ctx): it owns the height profile (toPieces),
-- which depends on the tool's live settings.

local record P3
	x : number
	y : number
	z : number
	hx : number
	hy : number
	hb : number
end

local record Piece2
	len : number
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
	guides : {Line2}
	info : string
end

local record Ctx
	MIN_PRIM_LENGTH : number
	p3 : function(x : number, y : number, z : number) : P3
	norm2 : function(x : number, y : number) : number, number, number
	dot2 : function(ax : number, ay : number, bx : number, by : number) : number
	routePoints : function(A : P3, B : P3, wps : {P3}) : {P3}
	emitHermite : function(out : {Piece2}, ax : number, ay : number, t0x : number, t0y : number, bx : number, by : number, t1x : number, t1y : number)
	toPieces : function(parts : {Piece2}, A : P3, B : P3, followTerrain? : boolean) : {any}
	fmtLen : function(m : number) : string
end

local record Curve
	CURVE_K_MIN : number
	CURVE_K_MAX : number
	CURVE_K_SNAP : number
	curveEndLengths : function(A : P3, B : P3, wps : {P3}) : number, number
	genCurve : function(A : P3, B : P3, ax : number, ay : number, bx : number, by : number, followTerrain : boolean, k0? : number, k1? : number, wps? : {P3}) : GenResult
end

return function(ctx : Ctx) : Curve
	local p3, norm2, dot2 = ctx.p3, ctx.norm2, ctx.dot2

	-- CS1 CreateCurve: refuse shapes that turn back on themselves.
	-- Curve handles: the curve's two Bezier control points, one on each end's guide line at a third
	-- of that end's tangent length (k0 / k1 x the distance between the ends; 1 = the default shape).
	-- Dragging one along its line makes that end run straighter (out) or bend sooner (in).
	local CURVE_K_MIN, CURVE_K_MAX, CURVE_K_SNAP = 0.05, 3.0, 0.05

	-- the lengths of the first and last leg (A to the first waypoint, the last waypoint to B): the
	-- curve handles' scale at each end
	local function curveEndLengths(A : P3, B : P3, wps : {P3}) : number, number
		local pts = ctx.routePoints(A, B, wps)
		local n = #pts
		return math.sqrt((pts[2].x - A.x) ^ 2 + (pts[2].y - A.y) ^ 2),
			math.sqrt((B.x - pts[n - 1].x) ^ 2 + (B.y - pts[n - 1].y) ^ 2)
	end

	local function genCurve(A : P3, B : P3, ax : number, ay : number, bx : number, by : number, followTerrain : boolean, k0? : number, k1? : number, wps? : {P3}) : GenResult
		local pts = ctx.routePoints(A, B, wps)
		local n = #pts
		local len0, len1 = curveEndLengths(A, B, wps)
		for i = 1, n - 1 do
			if (pts[i + 1].x - pts[i].x) ^ 2 + (pts[i + 1].y - pts[i].y) ^ 2 < ctx.MIN_PRIM_LENGTH ^ 2 then
				return { error = n == 2 and _("The nodes are too close together") or _("Two points are too close together") }
			end
		end
		local ux0, uy0 = norm2(pts[2].x - A.x, pts[2].y - A.y)
		local ux1, uy1 = norm2(B.x - pts[n - 1].x, B.y - pts[n - 1].y)
		if dot2(ax, ay, ux0, uy0) < -0.7 or dot2(bx, by, -ux1, -uy1) < -0.7 then
			return { error = _("Wrong shape for a curve - try Connection or Loop") }
		end
		k0, k1 = k0 or 1, k1 or 1
		-- unit direction at every point: the ends' own; at a waypoint its handles', else Catmull-Rom
		-- (previous to next). tOut / tIn: a waypoint's tangent going on / coming in, from its front / back
		-- handle (nil = each side's chord)
		local dirs : {{number}} = { { ax, ay } }
		local tOut : {integer : number} = {}
		local tIn : {integer : number} = {}
		for i = 2, n - 1 do
			local w = pts[i]
			local hl = w.hx and math.sqrt(w.hx * w.hx + w.hy * w.hy) or 0
			if hl > 0.5 then
				dirs[i] = { w.hx / hl, w.hy / hl }
				tOut[i] = 3 * hl
				tIn[i] = 3 * (w.hb or hl)
			else
				local dx, dy = norm2(pts[i + 1].x - pts[i - 1].x, pts[i + 1].y - pts[i - 1].y)
				dirs[i] = { dx, dy }
			end
		end
		dirs[n] = { -bx, -by }
		local parts : {Piece2} = {}
		-- a waypoint's automatic tangents (for its handles): coming in, the chord before it; going on, the
		-- chord after it
		local autoIn : {integer : number} = {}
		local autoOut : {integer : number} = {}
		for i = 1, n - 1 do
			local p, q = pts[i], pts[i + 1]
			local L = math.sqrt((q.x - p.x) ^ 2 + (q.y - p.y) ^ 2)
			local s0 = i == 1 and len0 * k0 or (tOut[i] or L)
			local s1 = i == n - 1 and len1 * k1 or (tIn[i + 1] or L)
			if i > 1 then autoOut[i] = L end
			if i < n - 1 then autoIn[i + 1] = L end
			ctx.emitHermite(parts, p.x, p.y, dirs[i][1] * s0, dirs[i][2] * s0, q.x, q.y, dirs[i + 1][1] * s1, dirs[i + 1][2] * s1)
		end
		local total = 0.0
		for _, p in ipairs(parts) do total = total + p.len end
		local h1 = p3(A.x + ax * len0 * k0 / 3, A.y + ay * len0 * k0 / 3, A.z)
		local h2 = p3(B.x + bx * len1 * k1 / 3, B.y + by * len1 * k1 / 3, B.z)
		local handles : {P3} = { h1, h2 }
		local guides : {Line2} = { { x0 = A.x, y0 = A.y, x1 = h1.x, y1 = h1.y }, { x0 = B.x, y0 = B.y, x1 = h2.x, y1 = h2.y } }
		-- two handles per waypoint, front and back (handles 3, 4: waypoint 1's front / back; 5, 6:
		-- waypoint 2's ...): where they are set, else where the automatic tangent puts them
		for i = 2, n - 1 do
			local w = pts[i]
			local df = (tOut[i] or autoOut[i] or 30) / 3
			local db = (tIn[i] or autoIn[i] or 30) / 3
			local hf = p3(w.x + dirs[i][1] * df, w.y + dirs[i][2] * df, w.z)
			local hb = p3(w.x - dirs[i][1] * db, w.y - dirs[i][2] * db, w.z)
			handles[#handles + 1] = hf
			handles[#handles + 1] = hb
			guides[#guides + 1] = { x0 = hb.x, y0 = hb.y, x1 = hf.x, y1 = hf.y }
		end
		return {
			pieces = ctx.toPieces(parts, A, B, followTerrain),
			info = _("Length") .. " " .. ctx.fmtLen(total),
			handles = handles,
			guides = guides,
		}
	end

	return {
		CURVE_K_MIN = CURVE_K_MIN,
		CURVE_K_MAX = CURVE_K_MAX,
		CURVE_K_SNAP = CURVE_K_SNAP,
		curveEndLengths = curveEndLengths,
		genCurve = genCurve,
	}
end
