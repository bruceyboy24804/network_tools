-- Network Tools: Dubins paths - the shortest way from one point and heading to another using only
-- straights and arcs of at least a given radius (Connect's "Min. radius" mode).
--
-- First choice is the game's own api.engine.util.findDubinsPath. What it returns isn't documented
-- beyond {EdgeGeometry, boolean} pairs, so its result is only used when it checks out: every piece a
-- line or an arc, joined end to end from the start to the target. Otherwise (or if the call fails) the
-- path comes from the six classic Dubins words below - each candidate is traced and kept only if it
-- really ends at the target with the right heading, so a wrong formula can't produce a wrong road.
--
-- Primitives come out in Connect's Prim form: lines (px, py -> qx, qy) and arcs (centre, r, start
-- angle a0, sweep > 0 = counter-clockwise).

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

local record Result
	prims : {Prim}
	word : string        -- e.g. "LSR" (L = left arc, S = straight, R = right arc); "engine" for the game's path
	length : number
	engine : boolean
	error : string
end

local record Options
	radius : number
end

local record Dubins
	MODE : integer
	opts : Options
	path : function(x0 : number, y0 : number, h0x : number, h0y : number, x1 : number, y1 : number, h1x : number, h1y : number, r : number) : Result
end

local TAU = 2 * math.pi
local POS_TOL = 0.5        -- metres: pieces must join (and reach the target) this closely
local DIR_TOL = 0.02       -- radians: and arrive with this heading

local function mod2pi(a : number) : number
	return a - TAU * math.floor(a / TAU)
end

local function angleDiff(a : number, b : number) : number
	local d = mod2pi(a - b)
	return math.min(d, TAU - d)
end

local function primLength(p : Prim) : number
	if p.line then return math.sqrt((p.qx - p.px) ^ 2 + (p.qy - p.py) ^ 2) end
	return p.r * math.abs(p.sweep)
end

-- start / end point and end heading of a primitive
local function primStart(p : Prim) : number, number
	if p.line then return p.px, p.py end
	return p.cx + p.r * math.cos(p.a0), p.cy + p.r * math.sin(p.a0)
end
local function primEnd(p : Prim) : number, number, number
	if p.line then return p.qx, p.qy, math.atan2(p.qy - p.py, p.qx - p.px) end
	local a = p.a0 + p.sweep
	local h = a + (p.sweep >= 0 and math.pi / 2 or -math.pi / 2)
	return p.cx + p.r * math.cos(a), p.cy + p.r * math.sin(a), h
end
local function primStartHeading(p : Prim) : number
	if p.line then return math.atan2(p.qy - p.py, p.qx - p.px) end
	return p.a0 + (p.sweep >= 0 and math.pi / 2 or -math.pi / 2)
end

-- the pieces join up and run from (x0, y0, th0) to (x1, y1, th1)
local function checks(prims : {Prim}, x0 : number, y0 : number, th0 : number, x1 : number, y1 : number, th1 : number) : boolean
	if #prims == 0 then return false end
	local px, py, ph = x0, y0, th0
	for _, p in ipairs(prims) do
		local sx, sy = primStart(p)
		if (sx - px) ^ 2 + (sy - py) ^ 2 > POS_TOL ^ 2 then return false end
		-- headings only matter for pieces long enough to have one
		if primLength(p) > POS_TOL and angleDiff(primStartHeading(p), ph) > DIR_TOL * 5 then return false end
		px, py, ph = primEnd(p)
	end
	return (px - x1) ^ 2 + (py - y1) ^ 2 <= POS_TOL ^ 2 and angleDiff(ph, th1) <= DIR_TOL * 5
end

----------------------------------------------------------------------------------------------------
-- The game's path

local g_loggedEngine = false

local function fromEngine(x0 : number, y0 : number, th0 : number, x1 : number, y1 : number, th1 : number, r : number) : {Prim}
	local ok, res = pcall(function() : {{EdgeGeometry, boolean}}
		return api.engine.util.findDubinsPath(
			api.type.Vec3f.new(x0, y0, 0), api.type.Vec3f.new(math.cos(th0), math.sin(th0), 0),
			api.type.Vec3f.new(x1, y1, 0), api.type.Vec3f.new(math.cos(th1), math.sin(th1), 0), r)
	end)
	if not ok or not res then
		if not g_loggedEngine then
			g_loggedEngine = true
			do ((require "network_tools_1::/gui/construction/tools/shared/ntools_debug.script.tl" as {string : any}).log as function(string))("[network_tools] dubins: findDubinsPath failed: " .. tostring(res)) end
		end
		return nil
	end
	local prims : {Prim} = {}
	local okConv = pcall(function()
		for _, pair in ipairs(res) do
			local g = pair[1]
			if g.type == api.type.EdgeGeometry.Type.STRAIGHT then
				local a, b = g.straight.pos[1], g.straight.pos[2]
				prims[#prims + 1] = { line = true, px = a.x, py = a.y, qx = b.x, qy = b.y }
			elseif g.type == api.type.EdgeGeometry.Type.ARC then
				local c = g.arc
				prims[#prims + 1] = { line = false, cx = c.center.x, cy = c.center.y, r = c.radius, a0 = c.startAngle, sweep = c.angle }
			else
				error("unexpected geometry type " .. tostring(g.type))
			end
		end
	end)
	if not okConv then return nil end
	-- drop zero-length pieces, then accept only a path that checks out (the boolean's meaning isn't
	-- documented: if the pieces only fit reversed, try that)
	local kept : {Prim} = {}
	for _, p in ipairs(prims) do
		if primLength(p) > 0.01 then kept[#kept + 1] = p end
	end
	if checks(kept, x0, y0, th0, x1, y1, th1) then return kept end
	local rev : {Prim} = {}
	for i = #kept, 1, -1 do
		local p = kept[i]
		if p.line then
			rev[#rev + 1] = { line = true, px = p.qx, py = p.qy, qx = p.px, qy = p.py }
		else
			rev[#rev + 1] = { line = false, cx = p.cx, cy = p.cy, r = p.r, a0 = p.a0 + p.sweep, sweep = -p.sweep }
		end
	end
	if checks(rev, x0, y0, th0, x1, y1, th1) then return rev end
	if not g_loggedEngine then
		g_loggedEngine = true
		do ((require "network_tools_1::/gui/construction/tools/shared/ntools_debug.script.tl" as {string : any}).log as function(string))(string.format("[network_tools] dubins: findDubinsPath result (%d pieces) didn't check out - using our own", #kept)) end
	end
	return nil
end

----------------------------------------------------------------------------------------------------
-- Our own: the six Dubins words (LaValle, Planning Algorithms 15.3.1), in units of the radius

-- t, p, q: the three part lengths (radians for arcs, radii for the straight), or nil
local function word(w : string, a : number, b : number, d : number) : number, number, number
	local sa, sb, ca, cb = math.sin(a), math.sin(b), math.cos(a), math.cos(b)
	local cab = math.cos(a - b)
	if w == "LSL" then
		local tmp = 2 + d * d - 2 * cab + 2 * d * (sa - sb)
		if tmp < 0 then return nil end
		local th = math.atan2(cb - ca, d + sa - sb)
		return mod2pi(-a + th), math.sqrt(tmp), mod2pi(b - th)
	elseif w == "RSR" then
		local tmp = 2 + d * d - 2 * cab + 2 * d * (sb - sa)
		if tmp < 0 then return nil end
		local th = math.atan2(ca - cb, d - sa + sb)
		return mod2pi(a - th), math.sqrt(tmp), mod2pi(-b + th)
	elseif w == "LSR" then
		local tmp = -2 + d * d + 2 * cab + 2 * d * (sa + sb)
		if tmp < 0 then return nil end
		local p = math.sqrt(tmp)
		local th = math.atan2(-ca - cb, d + sa + sb) - math.atan2(-2, p)
		return mod2pi(-a + th), p, mod2pi(-b + th)
	elseif w == "RSL" then
		local tmp = d * d - 2 + 2 * cab - 2 * d * (sa + sb)
		if tmp < 0 then return nil end
		local p = math.sqrt(tmp)
		local th = math.atan2(ca + cb, d - sa - sb) - math.atan2(2, p)
		return mod2pi(a - th), p, mod2pi(b - th)
	elseif w == "RLR" then
		local tmp = (6 - d * d + 2 * cab + 2 * d * (sa - sb)) / 8
		if math.abs(tmp) > 1 then return nil end
		local p = mod2pi(TAU - math.acos(tmp))
		local t = mod2pi(a - math.atan2(ca - cb, d - sa + sb) + p / 2)
		return t, p, mod2pi(a - b - t + p)
	elseif w == "LRL" then
		local tmp = (6 - d * d + 2 * cab + 2 * d * (sb - sa)) / 8
		if math.abs(tmp) > 1 then return nil end
		local p = mod2pi(TAU - math.acos(tmp))
		local t = mod2pi(-a - math.atan2(ca - cb, d + sa - sb) + p / 2)
		return t, p, mod2pi(b - a - t + p)
	end
	return nil
end

-- trace a word from (x, y, th) into primitives
local function trace(w : string, x : number, y : number, th : number, lens : {number}, r : number) : {Prim}
	local prims : {Prim} = {}
	for i = 1, 3 do
		local kind = w:sub(i, i)
		local l = lens[i]
		if kind == "S" then
			local nx, ny = x + math.cos(th) * l * r, y + math.sin(th) * l * r
			if l * r > 0.01 then prims[#prims + 1] = { line = true, px = x, py = y, qx = nx, qy = ny } end
			x, y = nx, ny
		else
			local s = kind == "L" and 1 or -1
			-- centre to the left (L) / right (R) of the heading
			local cx, cy = x - math.sin(th) * r * s, y + math.cos(th) * r * s
			local a0 = math.atan2(y - cy, x - cx)
			local sweep = l * s
			if l * r > 0.01 then prims[#prims + 1] = { line = false, cx = cx, cy = cy, r = r, a0 = a0, sweep = sweep } end
			x, y = cx + r * math.cos(a0 + sweep), cy + r * math.sin(a0 + sweep)
			th = th + sweep
		end
	end
	return prims
end

local WORDS = { "LSL", "RSR", "LSR", "RSL", "RLR", "LRL" }

local function own(x0 : number, y0 : number, th0 : number, x1 : number, y1 : number, th1 : number, r : number) : {Prim}, string, number
	local dx, dy = x1 - x0, y1 - y0
	local d = math.sqrt(dx * dx + dy * dy) / r
	local theta = mod2pi(math.atan2(dy, dx))
	local a, b = mod2pi(th0 - theta), mod2pi(th1 - theta)
	local best : {Prim} = nil
	local bestW, bestL = "", math.huge
	for _, w in ipairs(WORDS) do
		local t, p, q = word(w, a, b, d)
		if t then
			local L = (t + p + q) * r
			if L < bestL then
				local prims = trace(w, x0, y0, th0, { t, p, q }, r)
				if checks(prims, x0, y0, th0, x1, y1, th1) then
					best, bestW, bestL = prims, w, L
				end
			end
		end
	end
	return best, bestW, bestL
end

----------------------------------------------------------------------------------------------------

-- (h0x, h0y): heading leaving the start; (h1x, h1y): heading arriving at the end
local function path(x0 : number, y0 : number, h0x : number, h0y : number, x1 : number, y1 : number, h1x : number, h1y : number, r : number) : Result
	if (x1 - x0) ^ 2 + (y1 - y0) ^ 2 < 1 then
		return { error = _("The nodes are too close together") }
	end
	local th0, th1 = math.atan2(h0y, h0x), math.atan2(h1y, h1x)
	local prims = fromEngine(x0, y0, th0, x1, y1, th1, r)
	if prims then
		local L = 0.0
		for _, p in ipairs(prims) do L = L + primLength(p) end
		return { prims = prims, word = "engine", length = L, engine = true }
	end
	local w : string
	local L : number
	prims, w, L = own(x0, y0, th0, x1, y1, th1, r)
	if not prims then
		return { error = _("No path with this radius - try a smaller one") }
	end
	return { prims = prims, word = w, length = L, engine = false }
end

local M : Dubins = {
	MODE = 5,
	opts = { radius = 100 },
	path = path,
}
return M
