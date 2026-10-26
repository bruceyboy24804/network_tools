-- Network Tools: Auto-signal - Station mode. The stretch is split into runs of ordinary track (the
-- station's own platform segments can't carry our signals). On each run:
--   * where it leaves a station: an exit signal Exit distance outside the platform end, facing
--     away from the station (trains leaving the platform pass it) - both ways, or (two-way track,
--     where each way is planned on its own) only the way being planned
--   * with Entry signals on: where it runs into a station in the way of travel, an entry signal
--     Entry distance short of the platform end
--   * between its two ends (stations, or the stretch's ends): block signals by the spacing type
--     (ntools_signals_place blockCutter), facing the way of travel (`reverse`, as the other modes)
-- A signal already on the track facing the same way within MIN_GAP does the job of a planned one.
-- Placing itself (walking off segments that can't take a signal, end margins, skipped reasons) is
-- shared with Spacing mode: ntools_signals_place.
--
-- Set up by the Auto-signal tool with its shared helpers (ctx).

local record P3
	x : number
	y : number
	z : number
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

local record Track
	chain : {ChainLink}
	nodes : {Engine.Entity}
	s : {number}
	S : number
	travelAlong : boolean
end

local record Place
	minGap : function() : number
	endClearance : function() : number
	track : function(chain : {ChainLink}, reverse : boolean) : Track, string
	place : function(T : Track, w : number, pref : integer, kind : string, alongChain? : boolean, lo? : number, hi? : number) : Spot
	placeAdd : function(T : Track, a : Add) : Spot
	nearExisting : function(T : Track, w : number, alongChain : boolean) : boolean
	applyRemoves : function(plan : Plan, edits : Edits)
	blockCutter : function(T : Track) : function(a : number, b : number) : {number}
end

local record Options
	exitDistance : number     -- metres outside the platform end (nil = STATION_GAP)
	stationEntry : boolean    -- also entry signals
	entryDistance : number    -- metres short of the platform end (nil = STATION_GAP)
end

local record Ctx
	opts : Options
	place : Place
	constructionOfEdge : function(edge : Engine.Entity) : Engine.Entity
	isFrozenEdge : function(edge : Engine.Entity) : boolean
end

local record Station
	makeStationPlan : function(chain : {ChainLink}, reverse? : boolean, editsFor? : (function(T : Track) : Edits), ownWayOnly? : boolean) : Plan
end

local STATION_GAP = 8

return function(ctx : Ctx) : Station
	local opts = ctx.opts
	local P = ctx.place

	local function isStation(c : Engine.Entity) : boolean
		local result = false
		pcall(function()
			local con = api.engine.getComponent(c, api.type.ComponentType.CONSTRUCTION) as Engine.Component.Construction
			result = con ~= nil and #(con.stations or {}) > 0
		end)
		return result
	end

	-- A node where the line meets a station's tracks: one of the segments at it belongs to a station
	-- (the station owns its platform segments; the node they share with the line need not be its own)
	local function isStationNode(node : Engine.Entity) : boolean
		local ok, segs = pcall(function() : {Engine.Entity} return api.engine.system.streetSystem.getNodeSegments(node) end)
		for _, s in ipairs(ok and segs or {}) do
			local c = ctx.constructionOfEdge(s)
			if c and isStation(c) then return true end
		end
		-- or the node itself is one of the station's
		local result = false
		pcall(function()
			local c = api.engine.system.streetConnectorSystem.getConstructionEntityForNode(node)
			if c and c >= 0 then result = isStation(c) end
		end)
		return result
	end

	-- ownWayOnly: exit signals only for the way being planned (two-way track: the other way has its
	-- own plan)
	local function makeStationPlan(chain : {ChainLink}, reverse? : boolean, editsFor? : (function(T : Track) : Edits), ownWayOnly? : boolean) : Plan
		local T, why = P.track(chain, reverse == true)
		if not T then return { spots = {}, skipped = 0, skippedSpots = {}, removedSpots = {}, length = 0, why = why } end
		local plan : Plan = { spots = {}, skipped = 0, skippedSpots = {}, removedSpots = {}, length = T.S, track = T }
		local edits = editsFor and editsFor(T) or nil
		local END_CLEARANCE, MIN_GAP = P.endClearance(), P.minGap()
		local EXIT_GAP = math.max(1, opts.exitDistance or STATION_GAP)
		local ENTRY_GAP = math.max(1, opts.entryDistance or STATION_GAP)
		local along = T.travelAlong
		local s, nodes = T.s, T.nodes
		local placed : {number} = {}
		-- the player's own signals first: the planned ones keep clear of them
		for __, a in ipairs(edits and edits.adds or {}) do
			local sp = P.placeAdd(T, a)
			if sp.reason then
				plan.skippedSpots[#plan.skippedSpots + 1] = sp
				plan.skipped = plan.skipped + 1
			else
				placed[#placed + 1] = sp.at
				plan.spots[#plan.spots + 1] = sp
			end
		end
		-- a signal d metres along the stretch; alongChain: trains pass it travelling along the stretch;
		-- pref: which way it may walk (see ntools_signals_place); lo .. hi: the part of the stretch it
		-- must stay in (its own run of track)
		local function addAt(d : number, alongChain : boolean, pref : integer, kind : string, lo : number, hi : number)
			if P.nearExisting(T, d, alongChain) then return end
			local sp = P.place(T, d, pref, kind, alongChain, lo, hi)
			if sp.reason then
				plan.skippedSpots[#plan.skippedSpots + 1] = sp
				plan.skipped = plan.skipped + 1
				return
			end
			for _, a in ipairs(placed) do
				if math.abs(a - sp.at) < MIN_GAP then return end
			end
			placed[#placed + 1] = sp.at
			plan.spots[#plan.spots + 1] = sp
		end
		local frozen : {boolean} = {}
		for i, l in ipairs(chain) do frozen[i] = ctx.isFrozenEdge(l.edge) end
		local stations = 0
		local i = 1
		while i <= #chain do
			if frozen[i] then
				i = i + 1
			else
				-- a run of ordinary track: links i .. j
				local j = i
				while j < #chain and not frozen[j + 1] do j = j + 1 end
				local s0, s1 = s[i], s[j + 1]
				local stationBefore = (i > 1 and frozen[i - 1]) or isStationNode(nodes[i])
				local stationAfter = (j < #chain and frozen[j + 1]) or isStationNode(nodes[j + 1])
				-- exit signals: if they have to move, only further from the platform
				if stationBefore then
					stations = stations + 1
					if not ownWayOnly or along then addAt(s0 + EXIT_GAP, true, 1, "exit", s0, s1) end
				end
				if stationAfter then
					stations = stations + 1
					if not ownWayOnly or not along then addAt(s1 - EXIT_GAP, false, -1, "exit", s0, s1) end
				end
				-- entry signals: short of the platform the trains run into (the way of travel); if they
				-- have to move, only further from the platform
				if opts.stationEntry then
					if stationAfter and along then addAt(s1 - ENTRY_GAP, true, -1, "entry", s0, s1) end
					if stationBefore and not along then addAt(s0 + ENTRY_GAP, false, 1, "entry", s0, s1) end
				end
				-- block signals between the run's ends, by the spacing type
				local gapBefore = stationBefore and math.max(EXIT_GAP, opts.stationEntry and ENTRY_GAP or 0) or END_CLEARANCE
				local gapAfter = stationAfter and math.max(EXIT_GAP, opts.stationEntry and ENTRY_GAP or 0) or END_CLEARANCE
				local a = s0 + gapBefore
				local b = s1 - gapAfter
				if b - a > MIN_GAP * 2 then
					for __, w in ipairs(P.blockCutter(T)(a, b)) do
						addAt(w, not reverse, 0, "block", a, b)
					end
				end
				i = j + 1
			end
		end
		if stations == 0 then
			plan.spots = {}
			plan.skippedSpots = {}
			plan.skipped = 0
			plan.why = _("The stretch doesn't reach a station - select track that runs into one")
		end
		P.applyRemoves(plan, edits)
		return plan
	end

	return { makeStationPlan = makeStationPlan }
end
