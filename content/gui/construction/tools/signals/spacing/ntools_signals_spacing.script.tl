-- Network Tools: Auto-signal - Spacing mode (the default): block signals along the stretch, all
-- facing the chosen way of travel. Planned in two passes:
--   1. Signals that must stand at a particular place:
--        * at switches (At switches; splits and joins each on or off, each with its own distance):
--          where the track SPLITS in the direction of travel, the signal stands that far before the
--          switch (the path signal picks the branch there); where tracks JOIN, it stands that far
--          past the switch, so a train frees the junction for the other branch as soon as it is
--          clear of it
--        * before each level crossing (Before crossings)
--      Each is left out where a signal already on the track (facing the same way) does the job.
--   2. Block signals: every gap between the stretch's ends, the signals of pass 1 and the signals
--      already on it is cut into blocks by the spacing type (ntools_signals_place blockCutter):
--      equal blocks near the Spacing (the default - never a short leftover), a fixed interval,
--      equal-time blocks by line speed, or a set number of blocks, within the min / max block
--      limits. So a block signal never crowds out a switch signal.
-- Placing itself (walking off segments that can't take a signal, end margins, skipped reasons) is
-- shared with Station mode: ntools_signals_place.
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
	kind : string
	reason : string
	moved : number
	at : number
	user : boolean
end

local record Plan
	spots : {Spot}
	skipped : integer
	skippedSpots : {Spot}
	removedSpots : {Spot}
	length : number
	why : string
	track : any               -- the stretch as read (ntools_signals_place Track), for the preview
end

-- the player's edits on this track (see ntools_signals_place): the tool hands them over as a
-- function of the stretch as read (they are kept as world positions)
local record Add
	at : number
	alongChain : boolean
	kind : string
	model : string
	locked : boolean
end
local record Edits
	adds : {Add}
	removes : {number}
end

local record Existing
	at : number
	alongChain : boolean
end

local record Track
	chain : {ChainLink}
	nodes : {Engine.Entity}
	s : {number}
	S : number
	pieces : {Piece}
	edges : {Engine.Component.BaseEdge}
	existing : {Existing}
	travelAlong : boolean
end

local record Place
	minGap : function() : number
	endClearance : function() : number
	track : function(chain : {ChainLink}, reverse : boolean) : Track, string
	place : function(T : Track, w : number, pref : integer, kind : string, alongChain? : boolean, lo? : number, hi? : number) : Spot
	placeAdd : function(T : Track, a : Add) : Spot
	nearExisting : function(T : Track, w : number, alongChain : boolean) : boolean
	travelOffset : function(T : Track, at : number, d : number) : number
	applyRemoves : function(plan : Plan, edits : Edits)
	blockCutter : function(T : Track) : function(a : number, b : number) : {number}
end

local record Options
	beforeSwitches : boolean  -- signals at switches at all
	atSplits : boolean        -- ... where the track splits (nil = yes)
	atJoins : boolean         -- ... where tracks join (nil = yes)
	switchDistance : number   -- metres before a split
	joinDistance : number     -- metres past a join (nil = switchDistance)
	beforeCrossings : boolean
	crossingDistance : number
end

local record Ctx
	opts : Options
	END_CLEARANCE : number
	MIN_GAP : number
	BEFORE_SWITCH : number
	CROSSING_MARGIN : number
	place : Place
	getEdge : function(Engine.Entity) : Engine.Component.BaseEdge
	edgePiece : function(e : Engine.Component.BaseEdge) : Piece
end

local record Spacing
	makePlan : function(chain : {ChainLink}, reverse : boolean, edits? : function(T : Track) : Edits) : Plan
end

-- a signal that must stand at a particular place (pass 1)
local record Wanted
	at : number
	pref : integer        -- which way it may walk (see ntools_signals_place)
	kind : string
end

return function(ctx : Ctx) : Spacing
	local opts = ctx.opts
	local P = ctx.place

	-- A level crossing: the node is a railroad crossing, or road and rail meet at it
	local function isLevelCrossing(node : Engine.Entity) : boolean
		local result = false
		pcall(function()
			if api.engine.getComponent(node, api.type.ComponentType.RAILROAD_CROSSING) then result = true; return end
			local track, street = false, false
			for _, seg in ipairs(api.engine.system.streetSystem.getNodeSegments(node)) do
				local e = ctx.getEdge(seg)
				if e then
					if e.roadType == api.type["enum"].RoadType.TRACK then track = true else street = true end
				end
			end
			result = track and street
		end)
		return result
	end

	-- the plan direction a segment leaves `node` in (nil if unreadable)
	-- (the piece runs node0 -> node1: t0 leaves node0, t1 arrives at node1)
	local function leaving(seg : Engine.Entity, node : Engine.Entity) : number, number
		local e = ctx.getEdge(seg)
		if not e or (node ~= e.node0 and node ~= e.node1) then return nil end
		local ok, pc = pcall(ctx.edgePiece, e)
		if not ok or not pc then return nil end
		local t = node == e.node0 and pc.t0 or { x = -pc.t1.x, y = -pc.t1.y, z = -pc.t1.z }
		local l = math.sqrt(t.x * t.x + t.y * t.y)
		if l < 1e-6 then return nil end
		return t.x / l, t.y / l
	end

	-- At interior node k: does the track split (more than one way on) and / or do tracks join it (more
	-- than one way in), seen in the direction of travel? Other track segments at the node that leave
	-- on the same side as the way on are branches the train could take; the others join from behind.
	local function switchKind(T : Track, k : integer, segs : {Engine.Entity}) : boolean, boolean
		local node = T.nodes[k]
		local before, after = T.chain[k - 1].edge, T.chain[k].edge
		local onEdge = T.travelAlong and after or before
		local ox, oy = leaving(onEdge, node)
		if not ox then return true, false end   -- (unreadable: as before, a signal before it)
		local splits, joins = false, false
		for _, sg in ipairs(segs) do
			if sg ~= before and sg ~= after then
				local e = ctx.getEdge(sg)
				if e and e.roadType == api.type["enum"].RoadType.TRACK then
					local dx, dy = leaving(sg, node)
					if dx then
						if dx * ox + dy * oy > 0 then splits = true else joins = true end
					end
				end
			end
		end
		return splits, joins
	end

	-- reverse: trains travel against the chain's direction; editsFor: the player's added / removed
	-- signals on this stretch (handed the stretch as read)
	local function makePlan(chain : {ChainLink}, reverse : boolean, editsFor? : function(T : Track) : Edits) : Plan
		local T, why = P.track(chain, reverse)
		if not T then return { spots = {}, skipped = 0, skippedSpots = {}, removedSpots = {}, length = 0, why = why } end
		local plan : Plan = { spots = {}, skipped = 0, skippedSpots = {}, removedSpots = {}, length = T.S, track = T }
		local edits = editsFor and editsFor(T) or nil
		local END_CLEARANCE, MIN_GAP = P.endClearance(), P.minGap()
		local S = T.S
		local along = T.travelAlong
		-- "before" in the direction of travel, as a walking direction along the stretch
		local back = along and -1 or 1

		-- where signals stand (block boundaries): the ones already there facing our way, then ours
		local fixed : {number} = {}
		for _, ex in ipairs(T.existing) do
			if ex.alongChain == along then fixed[#fixed + 1] = ex.at end
		end
		local function crowded(at : number) : boolean
			for _, f in ipairs(fixed) do
				if math.abs(f - at) < MIN_GAP then return true end
			end
			return false
		end
		local function keep(sp : Spot) : boolean
			if sp.reason then
				plan.skippedSpots[#plan.skippedSpots + 1] = sp
				plan.skipped = plan.skipped + 1
				return false
			end
			if crowded(sp.at) then return false end
			plan.spots[#plan.spots + 1] = sp
			fixed[#fixed + 1] = sp.at
			return true
		end

		-- 0. the player's own signals: where they put them (anywhere on the stretch), facing the way
		-- they set, ahead of the rest; one facing the way of travel bounds a block
		for __, a in ipairs(edits and edits.adds or {}) do
			local sp = P.placeAdd(T, a)
			if sp.reason then
				plan.skippedSpots[#plan.skippedSpots + 1] = sp
				plan.skipped = plan.skipped + 1
			else
				plan.spots[#plan.spots + 1] = sp
				if a.alongChain == along then fixed[#fixed + 1] = sp.at end
			end
		end

		-- 1. signals that must stand at a particular place
		local wanted : {Wanted} = {}
		local lo, hi = END_CLEARANCE * 0.5, S - END_CLEARANCE * 0.5
		local function want(at : number, pref : integer, kind : string)
			if at > lo and at < hi then wanted[#wanted + 1] = { at = at, pref = pref, kind = kind } end
		end
		if opts.beforeSwitches then
			-- splits and joins each on their own, with their own distance
			local dSplit = opts.switchDistance or ctx.BEFORE_SWITCH
			local dJoin = opts.joinDistance or dSplit
			local atSplits, atJoins = opts.atSplits ~= false, opts.atJoins ~= false
			for k = 2, #T.nodes - 1 do
				local ok, segs = pcall(function() : {Engine.Entity}
					return api.engine.system.streetSystem.getNodeSegments(T.nodes[k])
				end)
				if ok and segs and #segs > 2 then
					local splits, joins = switchKind(T, k, segs)
					if splits and atSplits then want(P.travelOffset(T, T.s[k], dSplit), back, "split") end
					if joins and atJoins then want(P.travelOffset(T, T.s[k], -dJoin), -back, "join") end
				end
			end
		end
		if opts.beforeCrossings then
			-- before each level crossing in the direction of travel, crossingDistance short of it. The
			-- segment touching the crossing is re-added with the signal and the crossing re-created
			-- (net_util.rebuildCrossings); one that can't be walks the signal back to the first segment
			-- that can carry it
			-- (a signal can't be attached to a segment as it stands: the engine only takes edge objects
			-- on segments the proposal adds - it asserts "eo.edgeEntity.GetId() < 0", a hard crash)
			local d = opts.crossingDistance or ctx.CROSSING_MARGIN
			for k = 1, #T.nodes do
				-- (a crossing has a node on each side of the road: only the one trains reach first counts)
				local prevNode = reverse and T.nodes[k + 1] or T.nodes[k - 1]
				local first = not (prevNode and isLevelCrossing(prevNode))
				if first and isLevelCrossing(T.nodes[k]) then
					want(P.travelOffset(T, T.s[k], d), back, "crossing")
				end
			end
		end
		-- in the order trains reach them; one already standing there does the job
		table.sort(wanted, function(a : Wanted, b : Wanted) : boolean
			if along then return a.at < b.at end
			return a.at > b.at
		end)
		for _, w in ipairs(wanted) do
			if not P.nearExisting(T, w.at, along) then
				keep(P.place(T, w.at, w.pref, w.kind, nil, lo, hi))
			end
		end

		-- 2. block signals in every gap between the stretch's ends and the signals standing, by the
		-- spacing type (see blockCutter)
		local bounds : {number} = { 0, S }
		for _, f in ipairs(fixed) do bounds[#bounds + 1] = f end
		table.sort(bounds)
		local blocks = P.blockCutter(T)
		for g = 1, #bounds - 1 do
			for __, w in ipairs(blocks(bounds[g], bounds[g + 1])) do
				if w >= END_CLEARANCE and w <= S - END_CLEARANCE then
					keep(P.place(T, w, 0, "block", nil, END_CLEARANCE, S - END_CLEARANCE))
				end
			end
		end
		-- 3. the planned signals the player removed (they leave a gap: the blocks aren't re-spaced, or
		-- the removed signal would only turn up somewhere else)
		P.applyRemoves(plan, edits)
		return plan
	end

	return { makePlan = makePlan }
end
