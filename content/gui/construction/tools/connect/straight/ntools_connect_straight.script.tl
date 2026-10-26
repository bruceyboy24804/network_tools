-- Network Tools: Connect - Straight mode: a direct line from A to B (through any waypoints).
--
-- Set up by the Connect tool with its shared helpers (ctx): it owns the height profile (toPieces /
-- buildFromPrims), which depends on the tool's live settings.

local record P3
	x : number
	y : number
	z : number
end

local record Prim
	line : boolean
end

local record GenResult
	pieces : {any}
	info : string
end

local record Ctx
	routePoints : function(A : P3, B : P3, wps : {P3}) : {P3}
	linePrim : function(px : number, py : number, qx : number, qy : number) : Prim
	primLength : function(p : Prim) : number
	buildFromPrims : function(prims : {Prim}, A : P3, B : P3, followTerrain : boolean) : {any}
	fmtLen : function(m : number) : string
end

local record Straight
	genStraight : function(A : P3, B : P3, followTerrain : boolean, wps? : {P3}) : GenResult
end

return function(ctx : Ctx) : Straight
	local function genStraight(A : P3, B : P3, followTerrain : boolean, wps? : {P3}) : GenResult
		local pts = ctx.routePoints(A, B, wps)
		local prims : {Prim} = {}
		local len = 0.0
		for i = 1, #pts - 1 do
			prims[#prims + 1] = ctx.linePrim(pts[i].x, pts[i].y, pts[i + 1].x, pts[i + 1].y)
			len = len + ctx.primLength(prims[#prims])
		end
		return {
			pieces = ctx.buildFromPrims(prims, A, B, followTerrain),
			info = _("Length") .. " " .. ctx.fmtLen(len),
		}
	end

	return { genStraight = genStraight }
end
