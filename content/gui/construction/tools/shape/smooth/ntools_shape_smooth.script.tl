-- Network Tools: Shape - Smooth mode: each node in between moves part of the way (Strength) towards
-- the midpoint of its neighbours, and the curves become a smooth spline through the nodes - the kinks
-- that cost trains speed go.
--
-- Set up by the Shape tool with its shared helpers (ctx). place() gives the new node positions and
-- the direction through each; the tool builds the segments from them.

local record P3
	x : number
	y : number
	z : number
end

local record Options
	strength : number
end

local record Ctx
	opts : Options
	p3 : function(x : number, y : number, z : number) : P3
	endDirections : function(chain : {any}) : P3, P3
end

local record Smooth
	place : function(chain : {any}, P : {P3}, s : {number}) : {P3}, {P3}
end

return function(ctx : Ctx) : Smooth
	local function place(chain : {any}, P : {P3}, _s : {number}) : {P3}, {P3}
		local n = #P
		local Q : {P3} = {}
		for k = 1, n do Q[k] = P[k] end
		local f = math.max(0, math.min(1, ctx.opts.strength))
		for k = 2, n - 1 do
			local mx, my = (P[k - 1].x + P[k + 1].x) / 2, (P[k - 1].y + P[k + 1].y) / 2
			Q[k] = ctx.p3(P[k].x + (mx - P[k].x) * f, P[k].y + (my - P[k].y) * f, P[k].z)
		end
		-- direction through each node: Catmull-Rom through the new positions, keeping the stretch's
		-- own directions at its two ends
		local dirs : {P3} = {}
		local d0, d1 = ctx.endDirections(chain)
		dirs[1], dirs[n] = d0, d1
		for k = 2, n - 1 do dirs[k] = ctx.p3(Q[k + 1].x - Q[k - 1].x, Q[k + 1].y - Q[k - 1].y, 0) end
		return Q, dirs
	end

	return { place = place }
end
