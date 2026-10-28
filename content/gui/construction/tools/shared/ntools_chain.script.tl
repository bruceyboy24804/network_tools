-- Network Tools: selecting a stretch of road / track (a chain of segments in order), shared by the
-- tools that work on a path (Set slope; Parallel has its own copy of the same rules).
--
-- Click a segment to start; click a segment joining either end to extend; click a segment further
-- away to add the whole path to it; click the first / last segment to remove it.
--
-- The path to a segment further away, by the mode (PathOptions.mode, the MODE_* below):
--   * Dijkstra with the mode's step cost: fewest segments, shortest, straightest, same track type,
--     fastest, flattest, fewest junctions, avoiding bridges / tunnels
--   * A* (shortest, guided by the straight-line distance to the target) and Beeline (greedy
--     best-first on that distance alone)
--   * walkers, no search: Follow the line (straightest branch at every switch), Keep left / right
--   * bottleneck / minimax: the highest minimum speed, the gentlest steepest gradient
--   * Alternative route: the shortest path, then a second search with its track made dear
-- Every mode but Fewest segments refuses to double back through a switch (no train can). The
-- searches walk (node, segment arrived on) states, so a step can depend on the turn it makes.

local record ChainLink
	edge : Engine.Entity
	fwd : boolean      -- true: the chain runs node0 -> node1 along this edge
end

local record PathOptions
	mode : integer            -- MODE_*; nil = MODE_FEWEST
	avoidStations : boolean   -- not through station tracks
	electricOnly : boolean    -- only electrified track (tracks; roads are never filtered)
end

local record Chain
	linkEnds : function(link : ChainLink) : Engine.Entity, Engine.Entity
	nodes : function(chain : {ChainLink}) : {Engine.Entity}
	click : function(chain : {ChainLink}, entity : Engine.Entity, avoid? : {Engine.Entity : boolean}, opts? : PathOptions) : {ChainLink}
	lastNote : function() : string
end

-- path modes (PathOptions.mode; the Signals panel lists them in this order)
local MODE_FEWEST, MODE_SHORTEST, MODE_STRAIGHTEST, MODE_SAME_TYPE = 1, 2, 3, 4
local MODE_FASTEST, MODE_FLATTEST, MODE_FEWEST_JUNCTIONS, MODE_NO_STRUCTURES = 5, 6, 7, 8
-- (other algorithms, not just other weights)
local MODE_ASTAR, MODE_BEELINE = 9, 10                            -- A* / greedy best-first
local MODE_FOLLOW, MODE_KEEP_LEFT, MODE_KEEP_RIGHT = 11, 12, 13   -- walkers: no search
local MODE_BOTTLENECK_SPEED, MODE_MINIMAX_GRADE = 14, 15          -- bottleneck / minimax paths
local MODE_ALTERNATIVE = 16                                       -- second route, off the shortest's track

local SEARCH_LIMIT = 20000      -- states taken off the queue before giving up
local REVERSAL_COS = -0.17      -- a turn sharper than ~100 degrees is doubling back

-- why the last click didn't add a path (for the tool's tooltip; "" = nothing to say)
local g_note = ""

local function getEdge(entity : Engine.Entity) : Engine.Component.BaseEdge
	if not entity or entity < 0 or not api.engine.entityExists(entity) then
		return nil
	end
	return api.engine.getComponent(entity, api.type.ComponentType.BASE_EDGE) as Engine.Component.BaseEdge
end

-- The link's start and end node in chain direction.
local function linkEnds(link : ChainLink) : Engine.Entity, Engine.Entity
	local e = getEdge(link.edge)
	if not e then return nil, nil end
	if link.fwd then return e.node0, e.node1 end
	return e.node1, e.node0
end

-- The chain's nodes in order (one more than there are links).
local function nodes(chain : {ChainLink}) : {Engine.Entity}
	local out : {Engine.Entity} = {}
	for i, link in ipairs(chain) do
		local a, b = linkEnds(link)
		if i == 1 then out[1] = a end
		out[#out + 1] = b
	end
	return out
end

-- a segment that belongs to a station (or another construction)
local function isStationEdge(edge : Engine.Entity) : boolean
	local ok, c = pcall(function() : Engine.Entity
		return api.engine.system.streetConnectorSystem.getConstructionEntityForEdge(edge)
	end)
	return ok and c ~= nil and c >= 0
end

local function segmentsAt(node : Engine.Entity) : {Engine.Entity}
	local ok, segs = pcall(function() : {Engine.Entity} return api.engine.system.streetSystem.getNodeSegments(node) end)
	return ok and segs or {}
end

-- What the search needs to know about a segment (read once per search)
local record Info
	e : Engine.Component.BaseEdge
	length : number
	dz : number               -- height change end to end
	structure : boolean       -- bridge or tunnel
	speed : number            -- m/s (its fastest lane, curve limit included); nil = unknown
	electric : boolean
	template : string
end

local function readInfo(s : Engine.Entity) : Info
	local e = getEdge(s)
	if not e then return nil end
	local p0, p1 = e.position0, e.position1
	local length = (e.distance and e.distance > 0) and e.distance
		or math.sqrt((p1.x - p0.x) ^ 2 + (p1.y - p0.y) ^ 2 + (p1.z - p0.z) ^ 2)
	local info : Info = { e = e, length = math.max(length, 0.1), dz = p1.z - p0.z, template = tostring(e.roadTemplate),
		structure = e.type ~= api.type["enum"].BaseEdgeType.NORMAL, electric = false }
	pcall(function()
		local tn = api.engine.getComponent(s, api.type.ComponentType.TRANSPORT_NETWORK) as Engine.Component.TransportNetwork
		local ELECTRIC = api.type["enum"].TransportMode.ELECTRIC_TRAIN
		local best = 0.0
		for __, te in ipairs(tn and tn.edges or {}) do
			local v = math.min(te.speedLimit or 0, (te.curveSpeedLimit and te.curveSpeedLimit > 0) and te.curveSpeedLimit or math.huge)
			if v > best then best = v end
			if te.transportModes and te.transportModes[ELECTRIC] then info.electric = true end
		end
		info.speed = best > 0 and best or nil
	end)
	return info
end

-- Direction of travel along segment `i` at node `n`: arriving there (`arriving`), or leaving from there
local function dirAt(i : Info, n : Engine.Entity, arriving : boolean) : number, number
	local t : Vec3f
	local sign = 1
	if i.e.node1 == n then
		t = i.e.tangent1
		if not arriving then sign = -1 end
	else
		t = i.e.tangent0
		if arriving then sign = -1 end
	end
	local l = math.sqrt(t.x * t.x + t.y * t.y)
	if l < 1e-6 then return 0, 0 end
	return sign * t.x / l, sign * t.y / l
end

-- cos of the turn from arriving on `a` to leaving on `b` at node `n` (1 = straight on, -1 = straight back)
local function turnCos(a : Info, b : Info, n : Engine.Entity) : number
	local ax, ay = dirAt(a, n, true)
	local bx, by = dirAt(b, n, false)
	if (ax == 0 and ay == 0) or (bx == 0 and by == 0) then return 1 end
	return ax * bx + ay * by
end

-- min-heap of { cost, key } (the search's open list)
local record HeapItem
	cost : number
	key : string
end
local function heapPush(h : {HeapItem}, item : HeapItem)
	h[#h + 1] = item
	local i = #h
	while i > 1 do
		local p = math.floor(i / 2)
		if h[p].cost <= h[i].cost then break end
		h[p], h[i] = h[i], h[p]
		i = p
	end
end
local function heapPop(h : {HeapItem}) : HeapItem
	local top = h[1]
	local last = table.remove(h)
	if #h > 0 then
		h[1] = last
		local i = 1
		while true do
			local l, r, m = 2 * i, 2 * i + 1, i
			if l <= #h and h[l].cost < h[m].cost then m = l end
			if r <= #h and h[r].cost < h[m].cost then m = r end
			if m == i then break end
			h[m], h[i] = h[i], h[m]
			i = m
		end
	end
	return top
end

local record State
	node : Engine.Entity
	via : Engine.Entity       -- the segment arrived on
	prev : string             -- the state before (key), nil at the start
	cost : number             -- what the search minimises (see cost() in search)
	len : number              -- metres so far
	m : number                -- the bottleneck modes' running min speed / max gradient
	seed : integer            -- which search start it descends from (priority searches)
end

-- a segment's position at node `n` (its end there)
local function endAt(i : Info, n : Engine.Entity) : Vec3f
	return i.e.node0 == n and i.e.position0 or i.e.position1
end

-- signed turn at node `n` from arriving on `a` to leaving on `b`: > 0 left, < 0 right (sin of it)
local function turnSin(a : Info, b : Info, n : Engine.Entity) : number
	local ax, ay = dirAt(a, n, true)
	local bx, by = dirAt(b, n, false)
	return ax * by - ay * bx
end

-- a place the search starts from: a chain end (its node, arrived at on its end segment)
local record Seed
	node : Engine.Entity
	edge : Engine.Entity
	atEnd : boolean           -- the chain's last end (else its first)
end

-- The path (by the mode) from the nearest of the chain ends in `seeds` to segment `target`: the
-- links in order, ending with the target, and the seed it started from; or nil. One search for all
-- the seeds, so it stops at the first end to reach the target. `penalty`: segments made dearer
-- (the alternative route's second pass).
local function search(seeds : {Seed}, target : Engine.Entity, roadType : any,
		exclude : {Engine.Entity : boolean}, opts : PathOptions, penalty? : {Engine.Entity : boolean}) : {ChainLink}, Seed
	local mode = opts and opts.mode or MODE_FEWEST
	local avoidStations = opts ~= nil and opts.avoidStations == true
	local isTrack = roadType == api.type["enum"].RoadType.TRACK
	local electricOnly = isTrack and opts ~= nil and opts.electricOnly == true
	local noReversal = mode ~= MODE_FEWEST
	local infos : {Engine.Entity : Info} = {}
	local function info(s : Engine.Entity) : Info
		local i = infos[s]
		if i == nil then
			i = readInfo(s) or ({} as Info)
			infos[s] = i
		end
		return i.e and i or nil
	end
	local start = info(seeds[1].edge)
	local ti = info(target)
	if not start or not ti then return nil end
	local startTemplate = start.template
	-- where the target is (its middle), for A* / Beeline
	local tx = (ti.e.position0.x + ti.e.position1.x) / 2
	local ty = (ti.e.position0.y + ti.e.position1.y) / 2
	local function toTarget(p : Vec3f) : number return math.sqrt((p.x - tx) ^ 2 + (p.y - ty) ^ 2) end

	-- the segments one may go on to from `st` (arrived at its node on its segment), with the turn
	local record Next
		s : Engine.Entity
		b : Info
		c : number                -- turn cos
		degree : integer          -- segments at the node
	end
	local function nexts(node : Engine.Entity, via : Engine.Entity) : {Next}
		local out : {Next} = {}
		local a = info(via)
		local segs = segmentsAt(node)
		for __, s in ipairs(segs) do
			if s ~= via and not exclude[s] and not (avoidStations and isStationEdge(s)) then
				local b = info(s)
				if b and b.e.roadType == roadType and not (electricOnly and not b.electric) then
					local c = turnCos(a, b, node)
					if not (noReversal and c < REVERSAL_COS) then out[#out + 1] = { s = s, b = b, c = c, degree = #segs } end
				end
			end
		end
		return out
	end
	local function linksBack(states : {string : State}, key : string, last : Engine.Entity, lastNode : Engine.Entity) : {ChainLink}
		local links : {ChainLink} = { { edge = last, fwd = info(last).e.node0 == lastNode } }
		local k = key
		while states[k].prev do
			local cur = states[k]
			table.insert(links, 1, { edge = cur.via, fwd = info(cur.via).e.node1 == cur.node })
			k = cur.prev
		end
		return links
	end

	-- Walkers (Follow the line / Keep left / Keep right): no search - at each node the one branch the
	-- rule picks, until the target (or a dead end / a loop)
	if mode == MODE_FOLLOW or mode == MODE_KEEP_LEFT or mode == MODE_KEEP_RIGHT then
		local function walk(seed : Seed) : {ChainLink}
		local states : {string : State} = {}
		local node, via = seed.node, seed.edge
		local key = tostring(node) .. ":" .. tostring(via)
		states[key] = { node = node, via = via, cost = 0 }
		for __ = 1, SEARCH_LIMIT do
			local opts2 = nexts(node, via)
			if #opts2 == 0 then return nil end
			local pick : Next = nil
			for ___, n in ipairs(opts2) do
				if n.s == target then pick = n break end
			end
			if not pick then
				local best = -math.huge
				for ___, n in ipairs(opts2) do
					local score : number
					if mode == MODE_FOLLOW then score = n.c
					elseif mode == MODE_KEEP_LEFT then score = turnSin(info(via), n.b, node)
					else score = -turnSin(info(via), n.b, node) end
					if score > best then best, pick = score, n end
				end
			end
			if pick.s == target then return linksBack(states, key, target, node) end
			local other = pick.b.e.node0 == node and pick.b.e.node1 or pick.b.e.node0
			local nkey = tostring(other) .. ":" .. tostring(pick.s)
			if states[nkey] then return nil end   -- round in a loop
			states[nkey] = { node = other, via = pick.s, prev = key, cost = 0 }
			node, via, key = other, pick.s, nkey
		end
		return nil
		end
		-- the walk from each chain end; the one with fewer segments
		local best : {ChainLink} = nil
		local bestSeed : Seed = nil
		for __, seed in ipairs(seeds) do
			local p = walk(seed)
			if p and (not best or #p < #best) then best, bestSeed = p, seed end
		end
		return best, bestSeed
	end

	-- Alternative route: the shortest path first, then the shortest one with that path's track made
	-- dear (so it goes another way where there is one)
	if mode == MODE_ALTERNATIVE and not penalty then
		local first = search(seeds, target, roadType, exclude, { mode = MODE_SHORTEST,
			avoidStations = avoidStations, electricOnly = opts.electricOnly })
		if not first then return nil end
		local used : {Engine.Entity : boolean} = {}
		for __, l in ipairs(first) do if l.edge ~= target then used[l.edge] = true end end
		return search(seeds, target, roadType, exclude, opts, used)
	end

	-- Priority searches. cost() gives a state's value from the one before it; the open list is
	-- ordered by it (Dijkstra), plus the straight-line distance on to the target (A*), or by that
	-- distance alone (Beeline: greedy best-first, not shortest). The bottleneck modes keep their
	-- running min speed / max gradient in m and rank by it first, length second.
	local V_TOP = 200.0
	local function cost(st : State, n : Next, node : Engine.Entity) : number, number, number
		local b = n.b
		local len = st.len + b.length
		if mode == MODE_FEWEST then return st.cost + 1, len, 0 end
		if mode == MODE_SHORTEST or mode == MODE_ASTAR or mode == MODE_BEELINE then return len, len, 0 end
		if mode == MODE_STRAIGHTEST then
			-- the turn in degrees dominates; length only breaks ties
			local deg = math.deg(math.acos(math.max(-1, math.min(1, n.c))))
			return st.cost + b.length * 0.02 + deg * 10, len, 0
		end
		if mode == MODE_SAME_TYPE then
			return st.cost + b.length + (b.template ~= startTemplate and (b.length * 20 + 500) or 0), len, 0
		end
		if mode == MODE_FASTEST then return st.cost + b.length / math.max(b.speed or 10, 1), len, 0 end
		if mode == MODE_FLATTEST then return st.cost + b.length + math.abs(b.dz) * 50, len, 0 end
		if mode == MODE_FEWEST_JUNCTIONS then return st.cost + b.length * 0.01 + (n.degree > 2 and 1000 or 0), len, 0 end
		if mode == MODE_NO_STRUCTURES then return st.cost + b.length + (b.structure and (b.length * 50 + 1000) or 0), len, 0 end
		if mode == MODE_BOTTLENECK_SPEED then
			local m = math.min(st.m, b.speed or 10)
			return (V_TOP - math.min(m, V_TOP)) * 1e5 + len, len, m
		end
		if mode == MODE_MINIMAX_GRADE then
			local m = math.max(st.m, math.abs(b.dz) / b.length * 100)
			return m * 1e5 + len, len, m
		end
		if mode == MODE_ALTERNATIVE then
			return st.cost + b.length * ((penalty and penalty[n.s]) and 8 or 1), len, 0
		end
		return len, len, 0
	end
	local function priority(c : number, p : Vec3f) : number
		if mode == MODE_ASTAR then return c + toTarget(p) end
		if mode == MODE_BEELINE then return toTarget(p) end
		return c
	end

	local states : {string : State} = {}
	local done : {string : boolean} = {}
	local heap : {HeapItem} = {}
	for i, seed in ipairs(seeds) do
		local startKey = tostring(seed.node) .. ":" .. tostring(seed.edge)
		states[startKey] = { node = seed.node, via = seed.edge, cost = 0, len = 0, seed = i,
			m = mode == MODE_BOTTLENECK_SPEED and math.huge or 0 }
		heapPush(heap, { cost = 0, key = startKey })
	end
	local popped = 0
	while #heap > 0 and popped < SEARCH_LIMIT do
		local item = heapPop(heap)
		if not done[item.key] then
			done[item.key] = true
			popped = popped + 1
			local st = states[item.key]
			for __, n in ipairs(nexts(st.node, st.via)) do
				if n.s == target then return linksBack(states, item.key, target, st.node), seeds[st.seed] end
				local other = n.b.e.node0 == st.node and n.b.e.node1 or n.b.e.node0
				local key = tostring(other) .. ":" .. tostring(n.s)
				local c, len, m = cost(st, n, st.node)
				local old = states[key]
				if not done[key] and (old == nil or c < old.cost) then
					states[key] = { node = other, via = n.s, prev = item.key, cost = c, len = len, m = m, seed = st.seed }
					heapPush(heap, { cost = priority(c, endAt(n.b, other)), key = key })
				end
			end
		end
	end
	return nil
end

-- The chain after clicking `entity` (a new table; the old one is left alone). avoid: segments the
-- path to it may not use (e.g. another track's, when following the track beside it). opts: how a
-- path to a segment further away is found (nil: the fewest segments)
local function click(chain : {ChainLink}, entity : Engine.Entity, avoid? : {Engine.Entity : boolean}, opts? : PathOptions) : {ChainLink}
	g_note = ""
	local e = getEdge(entity)
	if not e then return chain end
	if #chain == 0 then
		return { { edge = entity, fwd = true } }
	end
	-- clicking the first / last segment removes it; the middle of the chain is left alone
	for i, link in ipairs(chain) do
		if link.edge == entity then
			if i == 1 or i == #chain then
				local nc : {ChainLink} = {}
				for j, l in ipairs(chain) do
					if j ~= i then nc[#nc + 1] = l end
				end
				return nc
			end
			return chain
		end
	end
	local startNode = linkEnds(chain[1])
	local _startOfLast, endNode = linkEnds(chain[#chain])
	local nc : {ChainLink} = {}
	for _, l in ipairs(chain) do nc[#nc + 1] = l end
	if e.node0 == endNode or e.node1 == endNode then
		nc[#nc + 1] = { edge = entity, fwd = e.node0 == endNode }
	elseif e.node0 == startNode or e.node1 == startNode then
		table.insert(nc, 1, { edge = entity, fwd = e.node1 == startNode })
	else
		-- further away: add the whole path to it (from whichever chain end reaches it)
		local inChain : {Engine.Entity : boolean} = {}
		for _, l in ipairs(chain) do inChain[l.edge] = true end
		for s, v in pairs(avoid or {}) do if v then inChain[s] = true end end
		local roadType = getEdge(chain[1].edge).roadType
		-- one search from both of the chain's ends (the start, arriving there on its first segment): it
		-- takes whichever end is nearer (trying the end first sent a click just behind the chain the
		-- long way round a loop)
		local seeds : {Seed} = {
			{ node = endNode, edge = chain[#chain].edge, atEnd = true },
			{ node = startNode, edge = chain[1].edge, atEnd = false },
		}
		local path, from = search(seeds, entity, roadType, inChain, opts)
		if path and from.atEnd then
			for _, l in ipairs(path) do nc[#nc + 1] = l end
		elseif path then
			-- walked away from the start: reverse it to put it in front of the chain
			for _, l in ipairs(path) do
				table.insert(nc, 1, { edge = l.edge, fwd = not l.fwd })
			end
		else
			g_note = (opts and opts.mode and opts.mode ~= MODE_FEWEST)
				and "No path to that segment with these settings (no doubling back through a switch) - a new stretch starts there"
				or "No path to that segment - a new stretch starts there"
			nc = { { edge = entity, fwd = true } }
		end
	end
	return nc
end

local M : Chain = {
	linkEnds = linkEnds,
	nodes = nodes,
	click = click,
	lastNote = function() : string return g_note end,
}
return M
