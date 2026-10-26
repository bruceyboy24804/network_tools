-- Network Tools: Auto-signal - placing signals on a stretch (shared by the Spacing and Station modes).
--
--   * The stretch is read once (track()): its segments, the distance along it to each node, which
--     segments can take a signal (and why not), and the signals already on it.
--   * A segment can take a signal unless it belongs to a station, ends at a junction with hand-edited
--     lanes / lights, or carries a stop or waypoint. Signals already on it don't block it: the tool
--     re-adds the segment with them placed again (shared/ntools_edge_signals).
--   * place() puts a signal at a distance along the stretch, at least END_MARGIN metres from the
--     segment's ends. If that segment can't take one, the signal walks to the nearest segment that
--     can (within WALK_MAX, only in the allowed direction, never out of the part of the stretch the
--     planner allows - see place()'s lo / hi); otherwise it is returned as skipped, with the reason
--     (drawn in the preview).
--
-- Set up by the Auto-signal tool with its shared helpers (ctx).

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

local record ChainLink
	edge : Engine.Entity
	fwd : boolean
end

local record Spot
	link : integer
	param : number
	pos : P3
	dir : P3
	along : boolean
	kind : string             -- "block", "split", "join", "crossing", "exit", "entry", "user"
	reason : string           -- skipped spots: why it couldn't be placed
	moved : number            -- metres it walked from where it was wanted (0 = not moved)
	at : number               -- distance along the stretch where it stands
	user : boolean            -- the player's: placed, moved, turned round or locked by them
	locked : boolean          -- a planned signal the player locked where it stands
	model : string            -- the signal type picked for this one signal (nil = by kind)
end

local record SignalCopy
	entity : Engine.Entity
	param : number
	model : string
	left : boolean
	oneWay : boolean
end

-- a signal already on the stretch
local record Existing
	at : number               -- distance along the stretch
	alongChain : boolean      -- trains pass it travelling along the stretch's direction
end

local record Track
	chain : {ChainLink}
	nodes : {Engine.Entity}
	s : {number}              -- distance along the stretch to node i (s[1] = 0)
	S : number
	pieces : {Piece}
	edges : {Engine.Component.BaseEdge}
	blocked : {integer : string}   -- link i: why it can't take a signal (nil = it can)
	existing : {Existing}     -- the signals already there that planning works around (see
	                          -- existingMode; empty when they are replaced or ignored)
	existingAll : {Existing}  -- every signal already there
	travelAlong : boolean     -- trains travel along the stretch's direction (not reversed)
end

local record Options
	minGap : number           -- metres: never two signals closer (nil = ctx.MIN_GAP)
	endClearance : number     -- metres kept free at the stretch's ends (nil = ctx.END_CLEARANCE)
	existingMode : integer    -- signals already there: 1 keep and plan around, 2 replace, 3 ignore
	spacing : number
	spacingType : integer     -- 1 equal blocks, 2 fixed interval, 3 by line speed, 4 by count
	blockCount : integer
	minBlock : number         -- metres, 0 = no limit
	maxBlock : number         -- metres, 0 = no limit
end

local record Ctx
	opts : Options
	MIN_GAP : number
	END_CLEARANCE : number
	getEdge : function(Engine.Entity) : Engine.Component.BaseEdge
	isFrozenEdge : function(edge : Engine.Entity) : boolean
	refusedEdge : function(edge : Engine.Entity) : boolean   -- the game refused a signal on it
	isProtectedNode : function(node : Engine.Entity) : boolean
	readSignals : function(e : Engine.Entity, oe : Engine.Component.BaseEdge) : {SignalCopy}, string
	chainNodes : function(chain : {ChainLink}) : {Engine.Entity}
	edgePiece : function(e : Engine.Component.BaseEdge) : Piece
	point : function(pc : Piece, t : number) : P3
	tangent : function(pc : Piece, t : number) : P3
	length : function(pc : Piece) : number
end

-- the player's edits on one planned track, as distances along its stretch (the tool turns its
-- world-position edits into these for each plan): their signals, and planned signals removed
local record Add
	at : number
	alongChain : boolean      -- trains pass it travelling along the stretch's direction
	kind : string             -- "user", or a locked / moved / turned planned signal's kind
	model : string            -- nil = by kind
	locked : boolean
end
local record Edits
	adds : {Add}
	removes : {number}
end

local record Plan
	spots : {Spot}
	skipped : integer
	skippedSpots : {Spot}
	removedSpots : {Spot}
end

local record Place
	END_MARGIN : number
	REMOVE_TOL : number
	minGap : function() : number
	endClearance : function() : number
	project : function(T : Track, x : number, y : number) : number, number
	pointAt : function(T : Track, at : number) : P3
	applyRemoves : function(plan : Plan, edits : Edits)
	track : function(chain : {ChainLink}, reverse : boolean) : Track, string
	place : function(T : Track, w : number, pref : integer, kind : string, alongChain? : boolean, lo? : number, hi? : number) : Spot
	placeAdd : function(T : Track, a : Add) : Spot
	nearExisting : function(T : Track, w : number, alongChain : boolean) : boolean
	travelOffset : function(T : Track, at : number, d : number) : number
	blockCutter : function(T : Track) : function(a : number, b : number) : {number}
end

local END_MARGIN = 3       -- metres a signal keeps from its segment's ends (clear of the node)
local WALK_MAX = 60        -- metres a signal may walk to find a segment that can take it
local REMOVE_TOL = 4       -- metres: a removal matches the planned signal standing this close

return function(ctx : Ctx) : Place
	local opts = ctx.opts or {}
	-- the panel's clearances (read at every plan: they can change any time)
	local function minGap() : number return math.max(5, opts.minGap or ctx.MIN_GAP) end
	local function endClearance() : number return math.max(0, opts.endClearance or ctx.END_CLEARANCE) end

	-- why link i can't take a signal, or nil
	local function blockReason(l : ChainLink, e : Engine.Component.BaseEdge) : string
		if not e then return _("segment is gone") end
		if ctx.isFrozenEdge(l.edge) then return _("station track") end
		if ctx.refusedEdge and ctx.refusedEdge(l.edge) then return _("the game won't take a signal here") end
		if ctx.isProtectedNode(e.node0) or ctx.isProtectedNode(e.node1) then
			return _("junction with hand-edited lanes / lights")
		end
		if #(e.objects or {}) > 0 then
			local ok, sigs, why = pcall(ctx.readSignals, l.edge, e)
			if not ok or not sigs then
				if why == "has waypoints" then return _("segment has a waypoint") end
				return _("segment has a stop or other object")
			end
		end
		return nil
	end

	local function track(chain : {ChainLink}, reverse : boolean) : Track, string
		local first = ctx.getEdge(chain[1].edge)
		if not first or first.roadType ~= api.type["enum"].RoadType.TRACK then
			return nil, _("Signals go on track - select a stretch of track")
		end
		local T : Track = { chain = chain, nodes = ctx.chainNodes(chain), s = { 0 }, pieces = {}, edges = {},
			blocked = {}, existing = {}, existingAll = {}, travelAlong = not reverse }
		for i, l in ipairs(chain) do
			local e = ctx.getEdge(l.edge)
			T.edges[i] = e
			T.pieces[i] = ctx.edgePiece(e)
			local len = ctx.length(T.pieces[i])
			T.s[i + 1] = T.s[i] + len
			T.blocked[i] = blockReason(l, e)
			if not T.blocked[i] and len < 2 * END_MARGIN + 0.5 then T.blocked[i] = _("segment too short") end
			-- the signals already on it, as distances along the stretch
			if e and #(e.objects or {}) > 0 then
				local ok, sigs = pcall(ctx.readSignals, l.edge, e)
				for _, sc in ipairs(ok and sigs or {}) do
					local u = l.fwd and sc.param or (1 - sc.param)
					-- (left: faces travel against the segment's direction)
					T.existingAll[#T.existingAll + 1] = { at = T.s[i] + u * len, alongChain = (not sc.left) == l.fwd }
				end
			end
		end
		-- planning works around them only in Keep mode (Replace: the tool removes the ones facing the
		-- way being signalled; Ignore: they stay but don't count)
		if (opts.existingMode or 1) == 1 then T.existing = T.existingAll end
		T.S = T.s[#T.s]
		return T, nil
	end

	-- d metres before `at` in the direction of travel (negative d: after it)
	local function travelOffset(T : Track, at : number, d : number) : number
		return T.travelAlong and (at - d) or (at + d)
	end

	-- an existing signal facing the same way within MIN_GAP of w (it already does the job)
	local function nearExisting(T : Track, w : number, alongChain : boolean) : boolean
		for _, ex in ipairs(T.existing) do
			if ex.alongChain == alongChain and math.abs(ex.at - w) < minGap() then return true end
		end
		return false
	end

	local function linkAt(T : Track, w : number) : integer
		local i = 1
		while i < #T.chain and T.s[i + 1] < w do i = i + 1 end
		return i
	end

	local function spotOn(T : Track, i : integer, w : number, kind : string, alongChain : boolean) : Spot
		local l = T.chain[i]
		local len = T.s[i + 1] - T.s[i]
		local u = len > 0.01 and math.max(0, math.min(1, (w - T.s[i]) / len)) or 0.5
		local param = l.fwd and u or (1 - u)
		local pos = ctx.point(T.pieces[i], param)
		local tan = ctx.tangent(T.pieces[i], param)
		local sign = (l.fwd and 1 or -1) * (alongChain and 1 or -1)
		return {
			link = i, param = param, pos = pos,
			dir = { x = tan.x * sign, y = tan.y * sign, z = 0 },
			along = sign > 0, kind = kind, moved = 0, at = w,
		}
	end

	-- A signal wanted at distance w along the stretch. pref: which way it may walk if its segment
	-- can't take it: -1 back along the stretch (smaller distances), +1 on along it, 0 either way.
	-- alongChain: trains pass it travelling along the stretch (default: the direction of travel).
	-- lo / hi: the part of the stretch it must stay in, wherever it walks (default: the whole stretch).
	-- Returns the spot; a skipped one has `reason` set (and stands where it was wanted).
	local function place(T : Track, w : number, pref : integer, kind : string, alongChain? : boolean, lo? : number, hi? : number) : Spot
		if alongChain == nil then alongChain = T.travelAlong end
		lo, hi = lo or 0, hi or T.S
		local i0 = linkAt(T, w)
		local best : integer = nil
		local bestW, bestD = 0.0, math.huge
		for i = 1, #T.chain do
			-- the part of segment i it may stand on: clear of the segment's ends, inside lo .. hi
			local a = math.max(T.s[i] + END_MARGIN, lo)
			local b = math.min(T.s[i + 1] - END_MARGIN, hi)
			if not T.blocked[i] and a <= b then
				local x = math.max(a, math.min(b, w))
				local d = x - w
				-- (its own segment: the end margin may nudge it a little either way)
				local allowed = i == i0 or pref == 0 or (pref < 0 and d <= 0) or (pref > 0 and d >= 0)
				if allowed and math.abs(d) <= WALK_MAX and math.abs(d) < bestD then
					best, bestW, bestD = i, x, math.abs(d)
				end
			end
		end
		if not best then
			local sp = spotOn(T, i0, w, kind, alongChain)
			sp.reason = T.blocked[i0] or _("no segment nearby within the stretch can take it")
			return sp
		end
		local sp = spotOn(T, best, bestW, kind, alongChain)
		sp.moved = bestD
		return sp
	end

	-- one of the player's signals, where they put it (anywhere on the stretch), the way they turned it
	local function placeAdd(T : Track, a : Add) : Spot
		local sp = place(T, a.at, 0, a.kind or "user", a.alongChain, 0, T.S)
		sp.user = true
		sp.locked = a.locked
		sp.model = a.model
		return sp
	end

	-- The distance along the stretch closest to (x, y) and how far (x, y) is from the track there
	local function project(T : Track, x : number, y : number) : number, number
		local bestAt, bestD = 0.0, math.huge
		for i = 1, #T.chain do
			local len = T.s[i + 1] - T.s[i]
			local n = math.max(4, math.min(64, math.ceil(len / 5)))
			for k = 0, n do
				local u = k / n
				local l = T.chain[i]
				local p = ctx.point(T.pieces[i], l.fwd and u or (1 - u))
				local d = (p.x - x) ^ 2 + (p.y - y) ^ 2
				if d < bestD then bestAt, bestD = T.s[i] + u * len, d end
			end
		end
		return bestAt, math.sqrt(bestD)
	end

	-- the point on the track at distance `at` along the stretch
	local function pointAt(T : Track, at : number) : P3
		local i = linkAt(T, at)
		local len = T.s[i + 1] - T.s[i]
		local u = len > 0.01 and math.max(0, math.min(1, (at - T.s[i]) / len)) or 0.5
		return ctx.point(T.pieces[i], T.chain[i].fwd and u or (1 - u))
	end

	-- Planned signals the player removed (within REMOVE_TOL of a removal) move to removedSpots, where
	-- the preview shows them faintly (a click brings them back). The player's own signals are never
	-- removed this way: removing one drops it from the edits instead.
	local function applyRemoves(plan : Plan, edits : Edits)
		plan.removedSpots = plan.removedSpots or {}
		if not edits or #(edits.removes or {}) == 0 then return end
		local function removed(sp : Spot) : boolean
			if sp.user then return false end
			for _, r in ipairs(edits.removes) do
				if math.abs(r - sp.at) <= REMOVE_TOL then return true end
			end
			return false
		end
		local kept : {Spot} = {}
		for _, sp in ipairs(plan.spots) do
			if removed(sp) then plan.removedSpots[#plan.removedSpots + 1] = sp else kept[#kept + 1] = sp end
		end
		plan.spots = kept
		local keptSkipped : {Spot} = {}
		for _, sp in ipairs(plan.skippedSpots or {}) do
			if removed(sp) then plan.removedSpots[#plan.removedSpots + 1] = sp else keptSkipped[#keptSkipped + 1] = sp end
		end
		plan.skippedSpots = keptSkipped
		plan.skipped = #keptSkipped
	end

	-- the line speed on a segment, km/h: its fastest lane, the lower of the track's limit and the
	-- curve's (nil if unknown)
	local function lineSpeed(edge : Engine.Entity) : number
		local ok, v = pcall(function() : number
			local tn = api.engine.getComponent(edge, api.type.ComponentType.TRANSPORT_NETWORK) as Engine.Component.TransportNetwork
			if not tn then return nil end
			local best = 0.0
			for __, e in ipairs(tn.edges or {}) do
				local s = math.min(e.speedLimit or 0, (e.curveSpeedLimit and e.curveSpeedLimit > 0) and e.curveSpeedLimit or math.huge)
				if s > best then best = s end
			end
			return best > 0 and best * 3.6 or nil
		end)
		return ok and v or nil
	end

	-- Where the block signals go in one gap (a, b) between signals that stand anyway, by the spacing
	-- type (shared by Spacing and Station mode):
	--   1 equal blocks    the gap cut into equal blocks, as near the Spacing as a whole number of
	--                     blocks gets (never a short leftover)
	--   2 fixed interval  a signal every Spacing metres from the gap's start in the direction of
	--                     travel; the last block takes what is left
	--   3 by line speed   blocks that take trains equally long: Spacing is a block's length at
	--                     REF_SPEED, longer where the line is faster, shorter where it is slower (curves
	--                     included) - equal "time blocks", as near that as a whole number of them gets
	--   4 by count        Block count equal blocks
	-- Then the limits: blocks never shorter than Min block (or the minimum gap), and, where a Max
	-- block is set, cut finer until none is longer.
	local REF_SPEED = 100   -- km/h
	local function blockCutter(T : Track) : function(a : number, b : number) : {number}
		local kind = opts.spacingType or 1
		local target = math.max(50, opts.spacing or 500)
		local along = T.travelAlong
		local shortest = math.max(minGap(), opts.minBlock or 0)
		local longest = (opts.maxBlock or 0) > 0 and math.max(opts.maxBlock, shortest) or nil

		-- by line speed: blocks per metre on each segment, and its running total along the stretch
		local rate : {number} = {}
		if kind == 3 then
			for k, l in ipairs(T.chain) do
				local v = lineSpeed(l.edge) or REF_SPEED
				rate[k] = 1 / (target * math.max(0.3, math.min(4, v / REF_SPEED)))
			end
		end
		local function tau(x : number) : number
			local acc = 0.0
			for k = 1, #T.chain do
				local s0, s1 = T.s[k], T.s[k + 1]
				if x <= s0 then break end
				acc = acc + (math.min(x, s1) - s0) * rate[k]
			end
			return acc
		end
		local function untau(t : number) : number
			local acc = 0.0
			for k = 1, #T.chain do
				local s0, s1 = T.s[k], T.s[k + 1]
				local d = (s1 - s0) * rate[k]
				if acc + d >= t and rate[k] > 0 then return s0 + (t - acc) / rate[k] end
				acc = acc + d
			end
			return T.S
		end

		return function(a : number, b : number) : {number}
			local L = b - a
			local out : {number} = {}
			local maxBlocks = math.floor(L / shortest)
			local minBlocks = longest and math.ceil(L / longest) or 1
			if kind == 2 then
				local step = longest and math.min(target, longest) or target
				step = math.max(step, shortest)
				local k = 1
				while k * step <= L - shortest do
					out[#out + 1] = along and (a + k * step) or (b - k * step)
					k = k + 1
				end
			elseif kind == 3 then
				local ta, tb = tau(a), tau(b)
				local n = math.min(math.max(math.floor(tb - ta + 0.5), minBlocks), maxBlocks)
				for k = 1, n - 1 do out[#out + 1] = untau(ta + k * (tb - ta) / n) end
			else
				local n = kind == 4 and math.max(1, opts.blockCount or 3) or math.floor(L / target + 0.5)
				n = math.min(math.max(n, minBlocks), maxBlocks)
				for k = 1, n - 1 do out[#out + 1] = a + k * L / n end
			end
			return out
		end
	end

	return {
		END_MARGIN = END_MARGIN,
		REMOVE_TOL = REMOVE_TOL,
		minGap = minGap,
		endClearance = endClearance,
		project = project,
		pointAt = pointAt,
		applyRemoves = applyRemoves,
		track = track,
		place = place,
		placeAdd = placeAdd,
		nearExisting = nearExisting,
		travelOffset = travelOffset,
		blockCutter = blockCutter,
	}
end
