-- Network Tools: Connect - Loop mode: one circle tangent to both road lines, centred on their
-- bisector (CS1 CreateLoop). Drag the centre to change the radius; drag it past the lines' crossing
-- point to switch between a corner and a loop.
--
-- Set up by the Connect tool with its shared helpers (ctx): it owns the height profile
-- (buildFromPrims), which depends on the tool's live settings.

local record P3
	x : number
	y : number
	z : number
end

local record Prim
	sweep : number
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

local record LoopState
	radius : number
	loop : boolean
end

local record GenResult
	pieces : {any}
	error : string
	handles : {P3}
	circles : {Circle2}
	guides : {Line2}
	info : string
end

local record Ctx
	MIN_RADIUS : number
	MAX_RADIUS : number
	MAX_GUIDE_T : number
	SNAP_RADIUS_STEP : number
	p3 : function(x : number, y : number, z : number) : P3
	clamp : function(v : number, lo : number, hi : number) : number
	cross2 : function(ax : number, ay : number, bx : number, by : number) : number
	dot2 : function(ax : number, ay : number, bx : number, by : number) : number
	norm2 : function(x : number, y : number) : number, number, number
	linePrim : function(px : number, py : number, qx : number, qy : number) : Prim
	arcPrim : function(cx : number, cy : number, r : number, sx : number, sy : number, ex : number, ey : number, orient : number) : Prim
	buildFromPrims : function(prims : {Prim}, A : P3, B : P3, followTerrain : boolean) : {any}
	fmtLen : function(m : number) : string
	fmtDeg : function(rad : number) : string
end

local record Loop
	genLoop : function(A : P3, B : P3, ax : number, ay : number, bx : number, by : number, st : LoopState, followTerrain : boolean) : GenResult
	dragLoop : function(A : P3, B : P3, ax : number, ay : number, bx : number, by : number, mx : number, my : number, snap : boolean) : LoopState
end

local record LoopGeom
	ix : number
	iy : number
	cdx : number
	cdy : number
	sinHalf : number
	tanHalf : number
	t1 : number
	t2 : number
end

return function(ctx : Ctx) : Loop
	local p3, clamp, cross2, dot2, norm2 = ctx.p3, ctx.clamp, ctx.cross2, ctx.dot2, ctx.norm2
	local linePrim, fmtLen, fmtDeg = ctx.linePrim, ctx.fmtLen, ctx.fmtDeg
	local MIN_RADIUS, MAX_RADIUS = ctx.MIN_RADIUS, ctx.MAX_RADIUS

	-- Crossing point of the two road lines and the bisector direction (CS1 MiddleCircle).
	local function loopGeom(A : P3, B : P3, ax : number, ay : number, bx : number, by : number) : LoopGeom
		local denom = cross2(ax, ay, bx, by)
		if math.abs(denom) < 1e-3 then
			return nil
		end
		local wx, wy = B.x - A.x, B.y - A.y
		local t1 = cross2(wx, wy, bx, by) / denom
		local t2 = cross2(wx, wy, ax, ay) / denom
		if math.abs(t1) > ctx.MAX_GUIDE_T or math.abs(t2) > ctx.MAX_GUIDE_T then
			return nil
		end
		local cdx, cdy, clen = norm2(ax + bx, ay + by)
		if clen < 1e-3 then
			return nil
		end
		local half = math.acos(clamp(dot2(ax, ay, bx, by), -1, 1)) / 2
		local sinHalf = math.sin(half)
		if sinHalf < 0.02 then
			return nil
		end
		return {
			ix = ((A.x + ax * t1) + (B.x + bx * t2)) / 2,
			iy = ((A.y + ay * t1) + (B.y + by * t2)) / 2,
			cdx = cdx, cdy = cdy,
			sinHalf = sinHalf, tanHalf = math.tan(half),
			t1 = t1, t2 = t2,
		}
	end

	-- CS1 CreateLoop.
	local function genLoop(A : P3, B : P3, ax : number, ay : number, bx : number, by : number, st : LoopState, followTerrain : boolean) : GenResult
		local g = loopGeom(A, B, ax, ay, bx, by)
		if not g then
			return { error = _("The road lines don't cross - try Connection instead") }
		end
		local z = (A.z + B.z) / 2
		local possibleCorner = g.t1 >= 0 and g.t2 >= 0
		local corner = possibleCorner and not st.loop

		local minR, maxR : number, number
		if corner then
			minR, maxR = MIN_RADIUS, g.tanHalf * math.min(g.t1, g.t2)
			if maxR < MIN_RADIUS then
				corner = false  -- no room for a corner: fall back to a loop
			end
		end
		if not corner then
			minR = math.max(g.tanHalf * math.max(-math.min(g.t1, 0), -math.min(g.t2, 0)), MIN_RADIUS)
			maxR = math.max(minR + 200, MAX_RADIUS)
		end
		local r = clamp(st.radius, minR, maxR)

		local d = r / g.sinHalf
		local sign = corner and -1 or 1
		local cx, cy = g.ix + g.cdx * d * sign, g.iy + g.cdy * d * sign

		-- tangent points: feet of the perpendiculars from the centre onto each road line
		local o1 = dot2(cx - A.x, cy - A.y, ax, ay)
		local o2 = dot2(cx - B.x, cy - B.y, bx, by)
		local t1x, t1y = A.x + ax * o1, A.y + ay * o1
		local t2x, t2y = B.x + bx * o2, B.y + by * o2
		local orient = cross2(ax, ay, cx - t1x, cy - t1y) >= 0 and 1 or -1

		local result : GenResult = {
			handles = { p3(cx, cy, z) },
			circles = { { x = cx, y = cy, r = r } },
			guides = {
				{ x0 = A.x, y0 = A.y, x1 = g.ix, y1 = g.iy },
				{ x0 = B.x, y0 = B.y, x1 = g.ix, y1 = g.iy },
			},
		}
		if o1 < -0.5 or o2 < -0.5 then
			result.error = _("Radius too small")
			return result
		end
		local arc = ctx.arcPrim(cx, cy, r, t1x, t1y, t2x, t2y, orient)
		local prims : {Prim} = {
			linePrim(A.x, A.y, t1x, t1y),
			arc,
			linePrim(t2x, t2y, B.x, B.y),
		}
		result.pieces = ctx.buildFromPrims(prims, A, B, followTerrain)
		result.info = (corner and _("Corner") or _("Loop")) .. ": R " .. fmtLen(r) .. ", " .. fmtDeg(arc.sweep)
			.. "   " .. _("Straights") .. ": " .. fmtLen(math.max(o1, 0)) .. " / " .. fmtLen(math.max(o2, 0))
		-- the lines cross behind a node: the loop has to turn back over that road (usually the wrong end picked)
		if g.t1 < 0 or g.t2 < 0 then
			local which = (g.t1 < 0 and g.t2 < 0) and _("both ends") or (g.t1 < 0 and _("end 1") or _("end 2"))
			result.info = result.info .. "\n" .. _("The road lines cross behind") .. " " .. which
				.. " - " .. _("the loop turns back over the road. Check the blue arrows, pick the other end of that road, or use Link")
		end
		return result
	end

	-- Drag the loop centre along the bisector: distance = radius, side of the crossing = corner/loop.
	local function dragLoop(A : P3, B : P3, ax : number, ay : number, bx : number, by : number, mx : number, my : number, snap : boolean) : LoopState
		local g = loopGeom(A, B, ax, ay, bx, by)
		if not g then
			return nil
		end
		local t = dot2(mx - g.ix, my - g.iy, g.cdx, g.cdy)
		local possibleCorner = g.t1 >= 0 and g.t2 >= 0
		local r = math.abs(t) * g.sinHalf
		if snap then
			r = math.floor(r / ctx.SNAP_RADIUS_STEP + 0.5) * ctx.SNAP_RADIUS_STEP
		end
		return {
			radius = clamp(r, MIN_RADIUS, MAX_RADIUS),
			loop = not (possibleCorner and t < 0),
		}
	end

	return { genLoop = genLoop, dragLoop = dragLoop }
end
