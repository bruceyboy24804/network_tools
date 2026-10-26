-- Network Tools: verdicts and demolitions (after the Overpass Builder mod).
--   of(sp)            - the game's verdict on a proposal right now, without the preview (or nil)
--   houses(pd)        - the ordinary town houses a verdict says are in the way
--   demolish(sp, hs)  - put those houses into the proposal: they are demolished by the same build,
--                       so a refused build demolishes nothing
--   blockReason(pd, sp) - why a verdict blocks building, or nil. Collisions with what the proposal
--                       removes anyway (old road it replaces, houses it demolishes) don't block;
--                       every other error does - a slope / curvature message is never hidden
--                       behind an expected collision.
-- Plus a little state the Connect tool keeps between renders (see the fields below).
-- (Its own file: the Connect script's main body is at Lua's 200-local limit.)

local record Demolition
	key : string
	houses : {Engine.Entity}
end

local record Verdict
	of : function(sp : SimpleProposal) : ProposalData
	houses : function(pd : ProposalData) : {Engine.Entity}
	demolish : function(sp : SimpleProposal, houses : {Engine.Entity})
	blockReason : function(pd : ProposalData, sp : SimpleProposal) : string
	-- the houses last found in the way, per shape (the verdict is only asked again when it changes)
	demolition : Demolition
	-- build latch: a proposal in flight isn't sent again (a quick double click); released by the
	-- game's answer, or after BUILD_TIMEOUT_S if none comes
	BUILD_TIMEOUT_S : number
	buildSince : number
	-- the preview's last raw error text (logged when it changes)
	lastPreviewMsg : string
	-- chained sections (A -> B, then on from B ...): the proposals of the sections committed so far,
	-- built together with the current one
	chain : {SimpleProposal}
	-- each kept section's setup (ends, mode, shape), alongside chain - to go back and edit it
	chainSnaps : {{string : any}}
	-- sections after the current one (when the player went back): { proposal = ..., snap = ... }
	after : {{string : any}}
	-- (set each render) the chained sections plus the current one as one proposal, or nil (no
	-- chain); chainWhy: why they can't be combined
	chainMerged : SimpleProposal
	chainWhy : string
	-- live preview off: the shape last priced (the cost is asked of the game only when it changes)
	offCostKey : string
end

-- untyped views of the engine objects (the shipped declarations miss these fields)
local function anyOf(x : any) : {string : any} return x as {string : any} end

local function of(sp : SimpleProposal) : ProposalData
	local ok, pd = pcall(function() : ProposalData
		local validate = api.engine.util.proposal.makeProposalData as function(SimpleProposal) : ProposalData
		return validate(sp)
	end)
	return ok and pd or nil
end

-- The town-house construction an entity belongs to, or -1. Stations, depots, industries and
-- constructions owning tracks / roads are never "houses".
local function townHouseOf(entity : Engine.Entity) : Engine.Entity
	local ok, res = pcall(function() : Engine.Entity
		if entity == nil or entity < 0 or not api.engine.entityExists(entity) then return -1 end
		local owner = entity
		local building = anyOf(api.engine.getComponent(entity, api.type.ComponentType.TOWN_BUILDING))
		if building ~= nil then
			owner = building.construction as Engine.Entity
		elseif api.engine.getComponent(entity, api.type.ComponentType.SUBCONSTRUCTION) ~= nil then
			owner = api.engine.system.streetConnectorSystem.getConstructionEntityForSubconstruction(entity)
		end
		if owner == nil or owner < 0 or not api.engine.entityExists(owner) then return -1 end
		local con = anyOf(api.engine.getComponent(owner, api.type.ComponentType.CONSTRUCTION))
		if con == nil then return -1 end
		local function n(f : string) : integer return #((con[f] or {}) as {any}) end
		if n("townBuildings") == 0 or n("stations") > 0 or n("depots") > 0 or n("industries") > 0
				or n("frozenEdges") > 0 or n("frozenNodes") > 0 then return -1 end
		return owner
	end)
	return ok and res or -1
end

local function houses(pd : ProposalData) : {Engine.Entity}
	local out : {Engine.Entity} = {}
	local seen : {Engine.Entity : boolean} = {}
	if pd == nil then return out end
	local ci = anyOf(anyOf(pd).collisionInfo)
	if ci == nil then return out end
	local function add(e : Engine.Entity)
		local owner = townHouseOf(e)
		if owner >= 0 and not seen[owner] then seen[owner] = true; out[#out + 1] = owner end
	end
	for _, item in ipairs((ci.collisionEntities or {}) as {{string : any}}) do add(item.entity as Engine.Entity) end
	for _, id in ipairs((ci.buildingEntities or {}) as {Engine.Entity}) do add(id) end
	for _, id in ipairs((ci.removableModules or {}) as {Engine.Entity}) do add(id) end
	return out
end

local function demolish(sp : SimpleProposal, hs : {Engine.Entity})
	pcall(function()
		local list : {Engine.Entity} = {}
		for _, h in ipairs(hs or {}) do
			if townHouseOf(h) == h then list[#list + 1] = h end   -- still a house
		end
		anyOf(sp).constructionsToRemove = list
	end)
end

local function blockReason(pd : ProposalData, sp : SimpleProposal) : string
	if pd == nil then return nil end
	local ok, reason = pcall(function() : string
		local es = anyOf(anyOf(pd).errorState)
		if es == nil then return nil end
		local msgs = (es.messages or {}) as {string}
		if es.critical == true and #msgs == 0 then return _("Can't be built here") end
		if #msgs == 0 then return nil end
		local gone : {Engine.Entity : boolean} = {}
		local spa = anyOf(sp)
		local street = anyOf(spa.streetProposal)
		for _, e in ipairs((street.edgesToRemove or {}) as {Engine.Entity}) do gone[e] = true end
		for _, e in ipairs((street.nodesToRemove or {}) as {Engine.Entity}) do gone[e] = true end
		local demolished : {Engine.Entity : boolean} = {}
		for _, e in ipairs((spa.constructionsToRemove or {}) as {Engine.Entity}) do demolished[e] = true end
		local function expected(e : Engine.Entity) : boolean
			if e == nil then return false end
			if gone[e] then return true end
			local owner = townHouseOf(e)
			return owner >= 0 and demolished[owner] == true
		end
		local ci = anyOf(anyOf(pd).collisionInfo)
		local allExpected = true
		local any = false
		if ci then
			for _, item in ipairs((ci.collisionEntities or {}) as {{string : any}}) do
				any = true
				if not expected(item.entity as Engine.Entity) then allExpected = false end
			end
			for _, id in ipairs((ci.buildingEntities or {}) as {Engine.Entity}) do
				any = true
				if not expected(id) then allExpected = false end
			end
			for _, id in ipairs((ci.removableModules or {}) as {Engine.Entity}) do
				any = true
				if not expected(id) then allExpected = false end
			end
		end
		local blocking : {string} = {}
		for __, m in ipairs(msgs) do
			local isCollision = m == _("Collision") or m == _("Collision detected") or m == _("Collision detected.")
			if not (isCollision and any and allExpected) then blocking[#blocking + 1] = m end
		end
		return #blocking > 0 and table.concat(blocking, " ") or nil
	end)
	if not ok then return nil end
	return reason
end

local M : Verdict = {
	of = of,
	houses = houses,
	demolish = demolish,
	blockReason = blockReason,
	demolition = { key = "", houses = {} },
	BUILD_TIMEOUT_S = 10.0,
	buildSince = nil,
	lastPreviewMsg = "",
	chain = {},
	chainSnaps = {},
	after = {},
	offCostKey = "",
}
return M
