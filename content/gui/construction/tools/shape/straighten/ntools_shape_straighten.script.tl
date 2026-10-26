-- Network Tools: Shape - Straighten mode: the nodes move onto the straight line between the two
-- ends, keeping their relative spacing; the segments become straight.
--
-- Set up by the Shape tool with its shared helpers (ctx). place() gives the new node positions and
-- the direction through each; the tool builds the segments from them.

local record P3
	x : number
	y : number
	z : number
end

local record Ctx
	p3 : function(x : number, y : number, z : number) : P3
end

local record Straighten
	place : function(chain : {any}, P : {P3}, s : {number}) : {P3}, {P3}
end

return function(ctx : Ctx) : Straighten
	local function place(_chain : {any}, P : {P3}, s : {number}) : {P3}, {P3}
		local n = #P
		local S = s[n]
		local Q : {P3} = {}
		for k = 1, n do Q[k] = P[k] end
		for k = 2, n - 1 do
			local u = s[k] / S
			Q[k] = ctx.p3(P[1].x + (P[n].x - P[1].x) * u, P[1].y + (P[n].y - P[1].y) * u, P[k].z)
		end
		-- direction through each node: along the line
		local dirs : {P3} = {}
		local d = ctx.p3(P[n].x - P[1].x, P[n].y - P[1].y, 0)
		for k = 1, n do dirs[k] = d end
		return Q, dirs
	end

	return { place = place }
end
