-- Network Tools: a track type's curve speeds, for the turnout speed options (Siding, Rejoin;
-- Junction has its own copy). The type's speedCoeffs give speed = a * (radius + b) ^ c m/s (as the
-- preview labels, shared/ntools_labels); minCurveRadiusBuild is the tightest curve a player may build.
--
--   local lim = speed.limitsOf(edge)        -- nil: unknown type
--   speed.speedAt(lim, radius)              -- km/h (nil: unknown)
--   speed.radiusFor(lim, kmh)               -- metres, at least the type's tightest
--   speed.verdictWithCleanup(proposal)      -- the game's verdict with the builders' Context: "" = ok

local record TrackLimits
	a : number
	b : number
	c : number
	minR : number
end

local g_limits : {string : TrackLimits} = {}

local function limitsOf(e : Engine.Component.BaseEdge) : TrackLimits
	local name = e and e.roadTemplate
	if not name or name == "" then return nil end
	if g_limits[name] ~= nil then return g_limits[name] end
	local lim : TrackLimits = nil
	pcall(function()
		local id = api.res.streetTemplateRep.find(name)
		if not id or id < 0 then return end
		local t = api.res.streetTemplateRep.get(id)
		local co = t.speedCoeffs as any
		local a, b, c : number, number, number
		-- (a vector: by index, or x / y / z)
		pcall(function() local v = co as {number}; a, b, c = v[1], v[2], v[3] end)
		if type(a) ~= "number" then pcall(function() local v = co as {string : number}; a, b, c = v.x, v.y, v.z end) end
		if type(a) == "number" and type(b) == "number" and type(c) == "number" and a > 0 and c ~= 0 then
			lim = { a = a, b = b, c = c, minR = t.minCurveRadiusBuild or 0 }
		end
	end)
	g_limits[name] = lim
	return lim
end

local function speedAt(lim : TrackLimits, r : number) : number
	if not lim or not r or r == math.huge or r <= 0 then return nil end
	return lim.a * (r + lim.b) ^ lim.c * 3.6
end

local function radiusFor(lim : TrackLimits, kmh : number) : number
	if not lim or not kmh or kmh <= 0 then return nil end
	local r = (kmh / 3.6 / lim.a) ^ (1 / lim.c) - lim.b
	return math.max(r, lim.minR or 0, 20)
end

-- The preview judges a proposal without a Context; the game's builders build with one that tidies
-- the street graph round new switches (cleanupStreetGraph). A refusal asked again that way may pass:
-- its messages ("" = none), or nil if it couldn't be asked
local function verdictWithCleanup(proposal : SimpleProposal) : string
	local out : string = nil
	pcall(function()
		local ctx = api.type.Context.new()
		ctx.player = api.engine.util.getPlayer()
		ctx.cleanupStreetGraph = true
		local pd = (api.engine.util.proposal.makeProposalData as function(SimpleProposal, Context) : ProposalData)(proposal, ctx)
		if pd then
			local msg = ""
			for __, m in ipairs(pd.errorState.messages or {}) do msg = msg .. m .. " " end
			out = msg
		end
	end)
	return out
end

-- the build's Context: the player, and the street graph tidied as the game's builders do
local function buildContext() : Context
	local context = api.type.Context.new()
	context.player = api.engine.util.getPlayer()
	pcall(function() context.cleanupStreetGraph = true end)
	return context
end

return {
	limitsOf = limitsOf,
	speedAt = speedAt,
	radiusFor = radiusFor,
	verdictWithCleanup = verdictWithCleanup,
	buildContext = buildContext,
}
