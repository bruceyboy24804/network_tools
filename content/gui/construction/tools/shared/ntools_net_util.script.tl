-- Network Tools: helpers shared by the tools that remove and re-add existing segments
-- (Parallel's crossings, Reverse, Add / Remove node, Set slope, Smooth, Signals, Connect...).
--
-- Every existing node a proposal touches keeps data that names its segments by entity id:
--   * its BASE_NODE_CONFIG lane connections - dropped with nodeConfigsToRemove (configNodesFor),
--     the engine then builds fresh, automatic ones
--   * at a level crossing, the crossing itself - re-created with node2rcType (rebuildCrossings),
--     the engine then builds it anew with the same type (confirmed in game, 2026-10-03)
-- Left as it was, either one names a removed segment and the engine hard-crashes ("lc.segment0
-- not found" in StreetShapeFactory) - even while only previewing. What can't be rebuilt that way is
-- left alone (isProtectedNode): lanes / light phases the player edited by hand, and a crossing
-- whose type can't be read.

local record NetUtil
	isProtectedNode : function(node : Engine.Entity, allowUserConfig? : boolean) : boolean
	whyNotReplaceable : function(edge : Engine.Entity, allowUserConfig? : boolean) : string
	configNodesFor : function(removedEdges : {Engine.Entity}, extraNodes? : {Engine.Entity}, skipNodes? : {Engine.Entity}) : {Engine.Entity}
	isCrossingNode : function(node : Engine.Entity) : boolean
	isPlainCrossing : function(node : Engine.Entity) : boolean
	crossingTypeAt : function(node : Engine.Entity) : integer
	rebuildCrossings : function(proposal : SimpleProposal, removedEdges : {Engine.Entity}, skipNodes? : {Engine.Entity}) : integer
	carryConfigs : function(proposal : SimpleProposal, nodes : {Engine.Entity}, remap : {Engine.Entity : {Engine.Entity : Engine.Entity | boolean}}) : integer
end

local function getEdge(entity : Engine.Entity) : Engine.Component.BaseEdge
	if not entity or entity < 0 or not api.engine.entityExists(entity) then
		return nil
	end
	return api.engine.getComponent(entity, api.type.ComponentType.BASE_EDGE) as Engine.Component.BaseEdge
end

-- A level crossing: the game's crossing component on the node, or road and rail meeting at it
local function isCrossingNode(node : Engine.Entity) : boolean
	if not node or node < 0 then return false end
	local result = false
	pcall(function()
		if api.engine.getComponent(node, api.type.ComponentType.RAILROAD_CROSSING) then result = true; return end
		local hasTrack, hasStreet = false, false
		for _, s in ipairs(api.engine.system.streetSystem.getNodeSegments(node)) do
			local e = getEdge(s)
			if e then
				if e.roadType == api.type["enum"].RoadType.TRACK then hasTrack = true else hasStreet = true end
			end
		end
		result = hasTrack and hasStreet
	end)
	return result
end

-- The game's first available crossing type (what it builds when road meets rail), or nil.
-- Cached per in-game year (sorting the types every call, several times a frame, cost frames).
local g_defaultRc : integer = nil
local g_defaultRcYear : integer = nil
local function defaultCrossingType() : integer
	local year : integer = nil
	pcall(function() year = api.engine.util.getYear() end)
	if g_defaultRcYear ~= nil and g_defaultRcYear == year then return g_defaultRc end
	local found : integer = nil
	pcall(function()
		local mcu = ug_require "::/gui/main/menu_category_util.tl" as MenuCategoryUtil
		local objects = mcu.getAvailableObjectsSorted(api.res.railroadCrossingTypeRep as ResTypeRep<integer, table>, year)
		if objects and objects[1] then found = objects[1].id end
	end)
	g_defaultRc, g_defaultRcYear = found, year
	return found
end

-- crossing type per node, cached for a few seconds (a crossing keeps its type; the lookup searches
-- the area for crossing entities, and the tools ask for every node of every segment each frame)
local g_rcType : {Engine.Entity : integer} = {}
local g_rcTypeAt : {Engine.Entity : number} = {}
local RC_CACHE_SECONDS = 5

-- The crossing type at a level-crossing node (index in railroadCrossingTypeRep): the crossing's
-- own, else the game's default one; nil only when neither can be found
local function crossingTypeAt(node : Engine.Entity) : integer
	-- (without os.clock in the game's Lua the cache simply never expires - a crossing keeps its type)
	local okC, now = pcall(function() : number return os.clock() end)
	if not okC or not now then now = 0 end
	if g_rcTypeAt[node] and now - g_rcTypeAt[node] < RC_CACHE_SECONDS then return g_rcType[node] end
	local found : integer = nil
	pcall(function()
		local rc = api.engine.getComponent(node, api.type.ComponentType.RAILROAD_CROSSING) as Engine.Component.RailroadCrossing
		if rc then found = rc.typeIndex; return end
		-- the crossing may be its own entity listing the node
		local n = api.engine.getComponent(node, api.type.ComponentType.BASE_NODE) as Engine.Component.BaseNode
		if not n then return end
		local p = api.type.Vec2f.new(n.position.x, n.position.y)
		for _, e in ipairs(api.engine.util.octree.findEntitiesInCircle(p, 40, api.type.ComponentType.RAILROAD_CROSSING)) do
			local c = api.engine.getComponent(e, api.type.ComponentType.RAILROAD_CROSSING) as Engine.Component.RailroadCrossing
			for _, cn in ipairs(c and c.nodes or {}) do
				if cn == node then found = c.typeIndex; return end
			end
		end
	end)
	if found == nil or found < 0 then found = defaultCrossingType() end
	g_rcType[node], g_rcTypeAt[node] = found, now
	return found
end

local function hasUserConfig(node : Engine.Entity) : boolean
	local result = false
	pcall(function()
		local cfg = api.engine.getComponent(node, api.type.ComponentType.BASE_NODE_CONFIG) as Engine.Component.BaseNodeConfig
		if cfg then
			result = cfg.userModifiedLaneConnections == true or cfg.userModifiedTrafficLightStates == true
		end
	end)
	return result
end

-- a level crossing with no hand-edited lanes / lights: rebuildCrossings can re-create it
local function isPlainCrossing(node : Engine.Entity) : boolean
	return isCrossingNode(node) and not hasUserConfig(node)
end

-- log each node's verdict once (diagnostics)
local g_logged : {Engine.Entity : boolean} = {}

-- A node whose segments must not be removed: the player edited its lanes / light phases (those
-- would be lost), or it is a crossing whose type can't be read (it couldn't be re-created).
-- allowUserConfig (Connect's Override lanes): hand-edited lanes / lights don't protect it - its
-- config is dropped and rebuilt automatically.
local function isProtectedNode(node : Engine.Entity, allowUserConfig? : boolean) : boolean
	if not node or node < 0 then return false end
	local ok, protected = pcall(function() : boolean
		if not allowUserConfig and hasUserConfig(node) then return true end
		return isCrossingNode(node) and crossingTypeAt(node) == nil
	end)
	if not g_logged[node] then
		g_logged[node] = true
		local why = ""
		pcall(function()
			local cfg = api.engine.getComponent(node, api.type.ComponentType.BASE_NODE_CONFIG) as Engine.Component.BaseNodeConfig
			why = string.format(" userLanes=%s userLights=%s rcType=%s",
				tostring(cfg and cfg.userModifiedLaneConnections), tostring(cfg and cfg.userModifiedTrafficLightStates),
				tostring(isCrossingNode(node) and crossingTypeAt(node) or "-"))
		end)
		do ((require "network_tools_1::/gui/construction/tools/shared/ntools_debug.script.tl" as {string : any}).log as function(string))("[network_tools] node " .. tostring(node) .. " protected=" .. tostring(not ok or protected)
			.. " crossing=" .. tostring(isCrossingNode(node)) .. why .. (ok and "" or (" error: " .. tostring(protected)))) end
	end
	-- if we can't tell, don't touch it
	return not ok or protected == true
end

-- Why an existing segment can't be removed and re-added safely, or nil if it can.
local function whyNotReplaceable(edge : Engine.Entity, allowUserConfig? : boolean) : string
	local e = getEdge(edge)
	if not e then return _("Not a road or track segment") end
	if #(e.objects or {}) > 0 then return _("Has signals or other objects on it") end
	if isProtectedNode(e.node0, allowUserConfig) or isProtectedNode(e.node1, allowUserConfig) then
		return _("Ends at a junction with hand-edited lanes / traffic lights")
	end
	return nil
end

-- The existing nodes whose lane connections must be dropped: the ends of the removed segments,
-- plus `extraNodes` (existing nodes that gain a segment). (Nodes whose lanes / light phases the
-- player edited are refused by isProtectedNode instead, so no hand-made configuration is lost.)
-- `skipNodes`: nodes the proposal removes itself - "node configurations that will be removed
-- (node itself cannot be removed at the same time)", says the API.
local function configNodesFor(removedEdges : {Engine.Entity}, extraNodes? : {Engine.Entity}, skipNodes? : {Engine.Entity}) : {Engine.Entity}
	local out : {Engine.Entity} = {}
	local seen : {Engine.Entity : boolean} = {}
	for _, n in ipairs(skipNodes or {}) do seen[n] = true end
	local function add(node : Engine.Entity)
		if node and node >= 0 and not seen[node] then
			seen[node] = true
			-- (not a station's / depot's node, nor a station's open track end - a segment there
			-- belongs to the construction: dropping its lanes makes the game refuse the build,
			-- "Construction Not Possible", or crashes it)
			local okO, owned = pcall(function() : boolean
				local sc = api.engine.system.streetConnectorSystem
				if (sc.getConstructionEntityForNode(node) or -1) >= 0 then return true end
				for _, s in ipairs(api.engine.system.streetSystem.getNodeSegments(node) or {}) do
					if (sc.getConstructionEntityForEdge(s) or -1) >= 0 then return true end
				end
				return false
			end)
			if okO and owned then return end
			local ok, cfg = pcall(function() : any
				return api.engine.getComponent(node, api.type.ComponentType.BASE_NODE_CONFIG)
			end)
			if ok and cfg ~= nil then out[#out + 1] = node end
		end
	end
	for _, edge in ipairs(removedEdges) do
		local e = getEdge(edge)
		if e then
			add(e.node0)
			add(e.node1)
		end
	end
	for _, n in ipairs(extraNodes or {}) do add(n) end
	return out
end

-- Re-create (node2rcType, same type) every level crossing at the ends of the removed segments, so
-- the old crossing doesn't go on naming a removed segment. Merges with entries the proposal has
-- already (new crossings a tool makes). Returns how many crossings it added.
local function rebuildCrossings(proposal : SimpleProposal, removedEdges : {Engine.Entity}, skipNodes? : {Engine.Entity}) : integer
	local skip : {Engine.Entity : boolean} = {}
	for _, n in ipairs(skipNodes or {}) do skip[n] = true end
	local rc : {Engine.Entity : integer} = {}
	pcall(function()
		for k, v in pairs(proposal.streetProposal.node2rcType or {}) do rc[k as Engine.Entity] = v as integer end
	end)
	local n = 0
	for _, edge in ipairs(removedEdges or {}) do
		local e = getEdge(edge)
		for _, node in ipairs(e and { e.node0, e.node1 } or {}) do
			if not skip[node] and rc[node] == nil and isCrossingNode(node) then
				local t = crossingTypeAt(node)
				if t then rc[node] = t; n = n + 1 end
			end
		end
	end
	if n > 0 then
		pcall(function() proposal.streetProposal.node2rcType = rc end)
		do ((require "network_tools_1::/gui/construction/tools/shared/ntools_debug.script.tl" as {string : any}).log as function(string))(string.format("[network_tools] re-creating %d level crossing node(s)", n)) end
	end
	return n
end

-- Give back the lane connections of nodes in nodeConfigsToRemove (nodeConfigsToAdd, the node's own
-- config with its segment ids renamed), as the Overpass Builder mod does: only removed, a node had
-- no BASE_NODE_CONFIG until the engine caught up, and the game crashed a while after Build
-- (mod.io report 2026-10-19, "Assertion it != components.end()", BaseNodeConfig / BaseEdge).
-- `remap`: node -> { old segment -> new segment, or false where the node loses it }. Only nodes in
-- `remap` are carried; a connection / crosswalk naming any other removed segment is dropped.
local function carryConfigs(proposal : SimpleProposal, nodes : {Engine.Entity},
		remap : {Engine.Entity : {Engine.Entity : Engine.Entity | boolean}}) : integer
	local removed : {Engine.Entity : boolean} = {}
	pcall(function()
		for __, s in ipairs(proposal.streetProposal.edgesToRemove or {}) do removed[s as Engine.Entity] = true end
	end)
	local function map(m : {Engine.Entity : Engine.Entity | boolean}, s : Engine.Entity) : Engine.Entity
		local to = m[s]
		if to == false then return nil end
		if to ~= nil then return to as Engine.Entity end
		if removed[s] then return nil end
		return s
	end
	local adds : {Proposal.BaseNodeLaneConnectionAndEntity} = {}
	for __, node in ipairs(nodes) do
		local m = remap[node]
		if m then
			local ok, err = pcall(function()
				local cfg = api.engine.getComponent(node, api.type.ComponentType.BASE_NODE_CONFIG) as Engine.Component.BaseNodeConfig
				if not cfg then return end
				local conns = {}
				for i = 1, #cfg.laneConnections do
					local lc = cfg.laneConnections[i]
					local s0, s1 = map(m, lc.segment0), map(m, lc.segment1)
					if s0 and s1 then
						lc.segment0, lc.segment1 = s0, s1
						conns[#conns + 1] = lc
					end
				end
				local walks = {}
				for i = 1, #cfg.crosswalks do
					local cw = map(m, cfg.crosswalks[i])
					if cw then walks[#walks + 1] = cw end
				end
				local ae = api.type.BaseNodeLaneConnectionAndEntity.new()
				ae.entity = node
				ae.comp = cfg
				ae.comp.laneConnections = conns
				ae.comp.crosswalks = walks
				adds[#adds + 1] = ae
				do ((require "network_tools_1::/gui/construction/tools/shared/ntools_debug.script.tl" as {string : any}).log as function(string))(string.format("[network_tools] carryConfigs: node %d, %d lane connection(s) of %d, %d crosswalk(s)", node, #conns, #cfg.laneConnections, #walks)) end
			end)
			if not ok then
				do ((require "network_tools_1::/gui/construction/tools/shared/ntools_debug.script.tl" as {string : any}).log as function(string))("[network_tools] carryConfigs: node " .. tostring(node) .. " error: " .. tostring(err)) end
			end
		end
	end
	if #adds > 0 then
		pcall(function()
			local all : {Proposal.BaseNodeLaneConnectionAndEntity} = {}
			for __, x in ipairs(proposal.streetProposal.nodeConfigsToAdd or {}) do all[#all + 1] = x end
			for __, x in ipairs(adds) do all[#all + 1] = x end
			proposal.streetProposal.nodeConfigsToAdd = all
		end)
		do ((require "network_tools_1::/gui/construction/tools/shared/ntools_debug.script.tl" as {string : any}).log as function(string))(string.format("[network_tools] carrying %d node config(s) onto the new segments", #adds)) end
	end
	return #adds
end

local M : NetUtil = {
	isProtectedNode = isProtectedNode,
	whyNotReplaceable = whyNotReplaceable,
	configNodesFor = configNodesFor,
	isCrossingNode = isCrossingNode,
	isPlainCrossing = isPlainCrossing,
	crossingTypeAt = crossingTypeAt,
	rebuildCrossings = rebuildCrossings,
	carryConfigs = carryConfigs,
}
return M
