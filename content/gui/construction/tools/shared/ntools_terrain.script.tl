-- Network Tools: terrain, water and bridges, shared by every tool that builds road / track.
--
-- heights(): the height profile along a planned path (a list of plan pieces), refined with extra
--   nodes where the profile bends. Like the game's street builder:
--   * over water the road is kept CLEARANCE above the water surface, ramping up from the shores
--     (the terrain under a lake is its bed - following it puts the road in the water)
--   * follow terrain: like the game's builder, the road hugs the ground (nodes every few dozen
--     metres), cutting / filling only where the ground is steeper than the maximum grade
--   * no follow terrain: the even slope between the ends, lifted only over water
-- classify(): bridge / tunnel / normal for a finished piece, from its height above the ground,
--   plus: a piece on, over or right next to water is a bridge (a normal road's embankment would
--   reach into the water and collide with the water mesh - the game starts its bridges before the
--   waterline too).
-- upgradeSegment(): for tools that keep their own heights (Set slope, Parallel, the reshape
--   tools): a segment that now runs high above / deep below the ground becomes a bridge / tunnel.
--
-- Water level: the TERRAIN component's waterLevel reads as nil in TF3, so the surface is
-- estimated from the shoreline (dry ground next to water is at / just above the surface).

local menu_category_util = ug_require "::/gui/main/menu_category_util.tl" as MenuCategoryUtil

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
-- a piece of the path in plan: ends, tangents (Hermite) and length
local record Part
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

local record Terrain
	clearance : number
	ground : function(x : number, y : number) : number
	onWater : function(x : number, y : number) : boolean
	heights : function(parts : {Part}, zA : number, zB : number, follow : boolean, maxGrade : number, lift? : number) : {Part}, {number}
	nodeZ : function(x : number, y : number) : number
	classify : function(pc : Piece, noShore? : boolean) : string
	pickTypes : function(isTrack : boolean) : integer, integer
	upgradeSegment : function(seg : Proposal.SegmentAndEntity, isTrack : boolean, bridgeId? : integer, tunnelId? : integer, noShore? : boolean) : string
	forceStructure : function(seg : Proposal.SegmentAndEntity, isTrack : boolean, bridgeId? : integer, tunnelId? : integer) : string
end

local CLEARANCE = 4            -- metres from the water surface to the deck
-- average height above / depth below the ground that makes a piece a bridge / tunnel: the
-- panel's Bridge height / Tunnel depth (shared options)
local record SharedOptions
	opts : {string : any}
end
local shared = require "network_tools_1::/gui/construction/tools/shared/ntools_options.script.tl" as SharedOptions
local function bridgeClearance() : number return (shared.opts.bridgeHeight as number) or 4.5 end
local function tunnelDepth() : number return (shared.opts.tunnelDepth as number) or 8 end
local SHORE_MARGIN = 12        -- metres: a piece this close to water is a bridge
local SAMPLE_STEP = 8          -- metres between profile samples
local SPLIT_TOLERANCE = 2.0    -- metres the profile may bend inside one piece before it is split
local MIN_PART = 30            -- shortest piece the refinement makes
local FOLLOW_SAMPLE_STEP = 4   -- the same, with follow terrain
local FOLLOW_TOLERANCE = 0.5
local FOLLOW_MIN_PART = 10
local FOLLOW_MAX_PART = 60     -- with follow terrain no piece is longer than this

local function ground(x : number, y : number) : number
	local ok, h = pcall(function() : number return api.engine.terrain.getHeightAt(api.type.Vec2f.new(x, y)) end)
	return ok and h or nil
end

local function onWater(x : number, y : number) : boolean
	local ok, w = pcall(function() : boolean return api.engine.terrain.isOnWater(api.type.Vec2f.new(x, y)) end)
	return ok and w == true
end

-- Water surface ------------------------------------------------------------------------------------

local g_level : number = nil       -- the map's (if it can be read)
local g_levelTried = false
local g_lastSurface : number = nil -- the last estimate (reused where a path has no shoreline)

local function mapLevel() : number
	if not g_levelTried then
		g_levelTried = true
		pcall(function()
			local ents = api.engine.getEntitiesWithComponent(api.type.ComponentType.TERRAIN)
			local t = ents and ents[1] and api.engine.getComponent(ents[1], api.type.ComponentType.TERRAIN) as Engine.Component.Terrain
			if t and t.waterLevel then g_level = t.waterLevel end
		end)
	end
	return g_level
end

-- the surface near a point that is on water: walk out in 8 directions to the first dry ground
local function surfaceNear(x : number, y : number) : number
	if mapLevel() then return mapLevel() end
	local best : number = nil
	for k = 0, 7 do
		local a = k * math.pi / 4
		local dx, dy = math.cos(a), math.sin(a)
		for d = 10, 800, 10 do
			local px, py = x + dx * d, y + dy * d
			if not onWater(px, py) then
				local h = ground(px, py)
				if h and (not best or h < best) then best = h end
				break
			end
		end
	end
	if best then g_lastSurface = best end
	return best or g_lastSurface
end

-- Plan geometry ------------------------------------------------------------------------------------

local function part2(p : Part, t : number) : number, number
	local t2, t3 = t * t, t * t * t
	local h00, h10, h01, h11 = 2 * t3 - 3 * t2 + 1, t3 - 2 * t2 + t, -2 * t3 + 3 * t2, t3 - t2
	return h00 * p.x0 + h10 * p.tx0 + h01 * p.x1 + h11 * p.tx1, h00 * p.y0 + h10 * p.ty0 + h01 * p.y1 + h11 * p.ty1
end

local function partD(p : Part, t : number) : number, number
	local t2 = t * t
	local d00, d10, d01, d11 = 6 * t2 - 6 * t, 3 * t2 - 4 * t + 1, -6 * t2 + 6 * t, 3 * t2 - 2 * t
	return d00 * p.x0 + d10 * p.tx0 + d01 * p.x1 + d11 * p.tx1, d00 * p.y0 + d10 * p.ty0 + d01 * p.y1 + d11 * p.ty1
end

-- the two halves of a part
local function halve(p : Part) : Part, Part
	local out : {Part} = {}
	for i = 0, 1 do
		local ta, tb = i / 2, (i + 1) / 2
		local xa, ya = part2(p, ta)
		local xb, yb = part2(p, tb)
		local dxa, dya = partD(p, ta)
		local dxb, dyb = partD(p, tb)
		out[i + 1] = { x0 = xa, y0 = ya, tx0 = dxa / 2, ty0 = dya / 2, x1 = xb, y1 = yb, tx1 = dxb / 2, ty1 = dyb / 2, len = p.len / 2 }
	end
	return out[1], out[2]
end

-- Height profile -----------------------------------------------------------------------------------

local record Sample
	s : number
	h : number        -- the height that holds the road up here (ground, or water surface + clearance)
	wet : boolean
end

-- lift: with follow terrain, the road runs this far above (+) / below (-) the ground (height offset)
local function heights(parts : {Part}, zA : number, zB : number, follow : boolean, maxGrade : number, lift? : number) : {Part}, {number}
	local G = maxGrade or 0.06
	lift = lift or 0
	-- samples along the path
	local samples : {Sample} = {}
	local S = 0.0
	local wetGround, shore : {number}, {number} = {}, {}
	local prevWet : boolean = nil
	local prevH : number = nil
	for _, p in ipairs(parts) do
		local n = math.max(1, math.ceil(p.len / (follow and FOLLOW_SAMPLE_STEP or SAMPLE_STEP)))
		for k = (#samples == 0) and 0 or 1, n do
			local x, y = part2(p, k / n)
			local s = S + p.len * k / n
			local h = ground(x, y)
			local wet = onWater(x, y)
			if h then
				samples[#samples + 1] = { s = s, h = h, wet = wet }
				if wet then wetGround[#wetGround + 1] = h end
				-- land / water change: the dry side's ground is at (just above) the surface
				if prevWet ~= nil and wet ~= prevWet then
					shore[#shore + 1] = wet and prevH or h
				end
				prevWet, prevH = wet, h
			end
		end
		S = S + p.len
	end
	if S <= 0 then return parts, nil end

	-- the water surface: the map's, else the lowest shoreline, else the highest wet ground + 1
	local surface = mapLevel()
	if not surface and #wetGround > 0 then
		for _, h in ipairs(shore) do surface = surface and math.min(surface, h) or h end
		if not surface then
			local hi = -math.huge
			for _, h in ipairs(wetGround) do hi = math.max(hi, h) end
			surface = g_lastSurface or (hi + 1)
		end
		g_lastSurface = surface
	end
	local floors : {Sample} = {}
	for _, smp in ipairs(samples) do
		if smp.wet and surface then
			floors[#floors + 1] = { s = smp.s, h = math.max(smp.h, surface + CLEARANCE), wet = true }
		elseif follow then
			floors[#floors + 1] = { s = smp.s, h = smp.h + lift, wet = false }
		end
	end

	-- follow terrain (like the game's builder): hug the ground (the water surface + clearance over
	-- water), cutting hills and filling dips only where the ground is steeper than the max grade
	local fz : {number} = nil
	if follow then
		local n = #floors
		fz = {}
		for i, f in ipairs(floors) do fz[i] = f.h end
		local function clampTo(i : integer, j : integer)
			local d = G * math.abs(floors[i].s - floors[j].s)
			fz[i] = math.min(math.max(fz[i], fz[j] - d), fz[j] + d)
		end
		-- fixed ends, then forward / backward passes until every step is within the grade
		for _ = 1, 4 do
			for i = 1, n do
				local cone = math.min(math.max(fz[i], zA - G * floors[i].s), zA + G * floors[i].s)
				fz[i] = math.min(math.max(cone, zB - G * (S - floors[i].s)), zB + G * (S - floors[i].s))
				if i > 1 then clampTo(i, i - 1) end
			end
			for i = n - 1, 1, -1 do clampTo(i, i + 1) end
		end
	end

	local function r(s : number) : number
		if fz then
			if #floors == 0 then return zA + (zB - zA) * (s / S) end
			if s <= floors[1].s then return fz[1] end
			for i = 2, #floors do
				if s <= floors[i].s then
					local a, b = floors[i - 1], floors[i]
					local t = (b.s > a.s) and (s - a.s) / (b.s - a.s) or 0
					return fz[i - 1] + (fz[i] - fz[i - 1]) * t
				end
			end
			return fz[#fz]
		end
		local z = zA + (zB - zA) * (s / S)
		for _, f in ipairs(floors) do
			local h = f.h - G * math.abs(s - f.s)
			if h > z then z = h end
		end
		return z
	end
	if #floors == 0 and not follow then
		-- nothing to change: the even slope as it was
		local zs : {number} = { zA }
		local acc = 0.0
		for _, p in ipairs(parts) do
			acc = acc + p.len
			zs[#zs + 1] = zA + (zB - zA) * (acc / S)
		end
		zs[#zs] = zB
		return parts, zs
	end

	-- split pieces where the profile bends inside them (finely when following the ground, so the
	-- road doesn't cut through or float over bumps between nodes)
	local tol = follow and FOLLOW_TOLERANCE or SPLIT_TOLERANCE
	local minPart = follow and FOLLOW_MIN_PART or MIN_PART
	local out : {Part} = {}
	local function emit(p : Part, s0 : number, depth : integer)
		local s1 = s0 + p.len
		local bent = false
		for q = 1, 3 do
			local lin = r(s0) + (r(s1) - r(s0)) * q / 4
			if math.abs(r(s0 + p.len * q / 4) - lin) > tol then bent = true end
		end
		local tooLong = follow and p.len > FOLLOW_MAX_PART
		if depth < 8 and p.len >= 2 * minPart and (bent or tooLong) then
			local a, b = halve(p)
			emit(a, s0, depth + 1)
			emit(b, s0 + a.len, depth + 1)
		else
			out[#out + 1] = p
		end
	end
	local s = 0.0
	for _, p in ipairs(parts) do
		emit(p, s, 0)
		s = s + p.len
	end
	local zs : {number} = { zA }
	local acc = 0.0
	for i, p in ipairs(out) do
		acc = acc + p.len
		zs[i + 1] = (i == #out) and zB or r(acc)
	end
	return out, zs
end

-- height for a lone node (e.g. a generated layout's corner): on the ground, above water if wet
local function nodeZ(x : number, y : number) : number
	local h = ground(x, y) or 0
	if onWater(x, y) then
		local sfc = surfaceNear(x, y)
		if sfc then h = math.max(h, sfc + CLEARANCE) end
	end
	return h
end

-- Bridges / tunnels --------------------------------------------------------------------------------

local function hermite3(pc : Piece, t : number) : number, number, number
	local t2, t3 = t * t, t * t * t
	local h00, h10, h01, h11 = 2 * t3 - 3 * t2 + 1, t3 - 2 * t2 + t, -2 * t3 + 3 * t2, t3 - t2
	return h00 * pc.p0.x + h10 * pc.t0.x + h01 * pc.p1.x + h11 * pc.t1.x,
		h00 * pc.p0.y + h10 * pc.t0.y + h01 * pc.p1.y + h11 * pc.t1.y,
		h00 * pc.p0.z + h10 * pc.t0.z + h01 * pc.p1.z + h11 * pc.t1.z
end

-- noShore: skip the "next to water" rule (for existing roads re-shaped by a tool: only real
-- height above / depth below the ground decides)
local function classify(pc : Piece, noShore? : boolean) : string
	local sumClear, minClear = 0.0, math.huge
	local sumDepth, minDepth = 0.0, math.huge
	local samples = 5
	for i = 1, samples do
		local x, y, z = hermite3(pc, i / (samples + 1))
		local h = ground(x, y)
		if not h then return "normal" end
		sumClear, minClear = sumClear + (z - h), math.min(minClear, z - h)
		sumDepth, minDepth = sumDepth + (h - z), math.min(minDepth, h - z)
	end
	local bc, td = bridgeClearance(), tunnelDepth()
	if sumClear / samples >= bc and minClear >= math.min(2, bc / 2) then return "bridge" end
	if sumDepth / samples >= td and minDepth >= math.min(4, td / 2) then return "tunnel" end
	-- at the shore (not when running below ground)
	if minDepth < 1 and not noShore then
		for i = 0, 6 do
			local x, y = hermite3(pc, i / 6)
			for _, o in ipairs({ { 0, 0 }, { SHORE_MARGIN, 0 }, { -SHORE_MARGIN, 0 }, { 0, SHORE_MARGIN }, { 0, -SHORE_MARGIN } }) do
				if onWater(x + o[1], y + o[2]) then return "bridge" end
			end
		end
	end
	return "normal"
end

-- the game's default bridge / tunnel type for this carrier and year (auto-selectable first)
local function pickTypes(isTrack : boolean) : integer, integer
	local carrier = isTrack and api.type["enum"].Carrier.RAIL or api.type["enum"].Carrier.ROAD
	local year = api.engine.util.getYear()
	local function pick(rep : ResTypeRep<integer, BridgeType>) : integer
		local ok, objects = pcall(function() : {MenuCategoryUtil.FilterObject}
			return menu_category_util.getAvailableObjectsSorted(rep as ResTypeRep<integer, table>, year)
		end)
		if not ok or not objects then return nil end
		local fallback : integer = nil
		for _, o in ipairs(objects) do
			local matches = false
			for _, c in ipairs(o.carriers or {}) do
				if c == carrier then matches = true end
			end
			if matches then
				if o.isAutoSelectable ~= false then return o.id end
				fallback = fallback or o.id
			end
		end
		return fallback
	end
	return pick(api.res.bridgeTypeRep), pick(api.res.tunnelTypeRep)
end

-- The panel's Structure (shared): a new segment forced on the ground / onto a bridge / into a
-- tunnel whatever its height. Returns the kind it forced, or nil (Automatic: the heights decide)
local function forceStructure(seg : Proposal.SegmentAndEntity, isTrack : boolean, bridgeId? : integer, tunnelId? : integer) : string
	local f = (shared.opts.structure as integer) or 1
	if f <= 1 then return nil end
	local kind : string = nil
	pcall(function()
		local c = seg.comp
		if f == 2 then
			c.type, c.typeIndex = api.type["enum"].BaseEdgeType.NORMAL, -1
			kind = "normal"
		elseif f == 3 then
			local b = bridgeId
			if not b then b = pickTypes(isTrack) end
			if b then c.type, c.typeIndex = api.type["enum"].BaseEdgeType.BRIDGE, b; kind = "bridge" end
		elseif f == 4 then
			local t = tunnelId
			if not t then local _b : integer; _b, t = pickTypes(isTrack) end
			if t then c.type, c.typeIndex = api.type["enum"].BaseEdgeType.TUNNEL, t; kind = "tunnel" end
		end
	end)
	return kind
end

-- A finished segment that now runs high above / deep below the ground (or over water) becomes a
-- bridge / tunnel; one that is normal stays as the tool made it. Returns the verdict. (The panel's
-- Structure, when not Automatic, decides instead.)
local function upgradeSegment(seg : Proposal.SegmentAndEntity, isTrack : boolean, bridgeId? : integer, tunnelId? : integer, noShore? : boolean) : string
	local forced = forceStructure(seg, isTrack, bridgeId, tunnelId)
	if forced then return forced end
	local kind = "normal"
	pcall(function()
		local c = seg.comp
		local pc : Piece = {
			p0 = { x = c.position0.x, y = c.position0.y, z = c.position0.z }, t0 = { x = c.tangent0.x, y = c.tangent0.y, z = c.tangent0.z },
			p1 = { x = c.position1.x, y = c.position1.y, z = c.position1.z }, t1 = { x = c.tangent1.x, y = c.tangent1.y, z = c.tangent1.z },
		}
		kind = classify(pc, noShore)
		local BRIDGE, TUNNEL = api.type["enum"].BaseEdgeType.BRIDGE, api.type["enum"].BaseEdgeType.TUNNEL
		if kind == "bridge" and c.type ~= BRIDGE then
			local b = bridgeId
			if not b then b = pickTypes(isTrack) end
			if b then c.type, c.typeIndex = BRIDGE, b end
		elseif kind == "tunnel" and c.type ~= TUNNEL then
			local t = tunnelId
			if not t then local _b : integer; _b, t = pickTypes(isTrack) end
			if t then c.type, c.typeIndex = TUNNEL, t end
		end
	end)
	return kind
end

local M : Terrain = {
	clearance = CLEARANCE,
	ground = ground,
	onWater = onWater,
	heights = heights,
	nodeZ = nodeZ,
	classify = classify,
	pickTypes = pickTypes,
	upgradeSegment = upgradeSegment,
	forceStructure = forceStructure,
}
return M
