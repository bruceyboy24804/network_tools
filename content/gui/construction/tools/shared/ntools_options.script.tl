-- Network Tools: options shared by every tool (set in the panel), modelled on the game's road /
-- track builders:
--   * underground: the engine's underground view (shows and picks only underground roads)
--   * bridgeHeight / tunnelDepth: how high above / deep below the ground a piece must run to
--     become a bridge / tunnel (the builders' Bridge Height / Tunnel Height)
--   * new-road properties, applied to the segments a tool builds new (not to existing segments it
--     only re-adds): catenary, bus lane, tram track, locked development, player owned, decorations
--   * Connect: height offset, fixed incline, snapping ground points to roads, override lanes

local builtin = ug_require "::/gui/main/builtin.lua" as Builtin
-- diagnostic traces (print only with ntools_debug's DEBUG on); also handed out as M.debug
local dbg = (require "network_tools_1::/gui/construction/tools/shared/ntools_debug.script.tl" as {string : any}).log as function(string)

local record Options
	underground : boolean
	bridgeHeight : number
	tunnelDepth : number
	structure : integer        -- every tool's new segments: 1 automatic (from the heights above),
	                           -- 2 ground, 3 bridge, 4 tunnel (shared/ntools_terrain forceStructure)
	-- Connect
	heightOffset : number      -- metres above (+) / below (-) the ground for points on bare ground
	incline : number           -- percent; nil = off (the ends' own heights)
	snapToRoads : boolean      -- a click on bare ground next to a road picks the road
	overrideLanes : boolean    -- Replace may rebuild junctions with hand-edited lanes / lights
	pointLabel : string        -- the selected circle / waypoint (set by Connect; nil = none)
	pointHeight : number       -- its height offset: the panel's slider writes it, Connect stores it
	-- a selected Connect circle (pointCircle) also has, edited the same way:
	pointCircle : boolean
	pointHeightEnd : number    -- height at the end of its arc (nil = pointHeight all along)
	pointRadius : number
	pointStructure : integer   -- 1 automatic, 2 ground, 3 bridge, 4 tunnel
	pointMovable : boolean     -- a middle circle (its centre can be moved)
	pointMove : {number}       -- a move {dx, dy} the panel asks for (Connect applies and clears it)
	pointSent : string         -- (Connect's) what it last showed the panel
	-- new roads and tracks
	catenary : integer         -- 1 as the network, 2 electrified, 3 not electrified
	busLane : boolean
	tram : integer             -- 1 as the network, 2 tram track, 3 electric tram track
	lockDevelopment : boolean
	playerOwned : boolean
	decorations : boolean      -- the network's default edge decorations
	-- general settings (the panel's Settings tab)
	hudIcons : boolean         -- the short tick / cross over signals after a build
	footprints : boolean       -- the tinted area under a shape being placed (Generate)
	saveSettings : boolean     -- remember the tools' settings with the savegame (ntools_persist)
	-- the preview labels (shared/ntools_labels): shown at all, which rows, hover detail, size, range
	labels : boolean
	labelSpeed : boolean
	labelGrade : boolean
	labelRadius : boolean
	labelHeight : boolean      -- bridge / tunnel height
	labelTotal : boolean       -- the build's total length
	labelDetail : boolean      -- the extra lines on the label under the cursor
	labelSize : integer        -- 1 auto (compact far off), 2 always compact, 3 always full
	labelRange : number        -- metres from the camera
	-- look (shared/ntools_handles and the tools' overlays)
	colorPreset : integer      -- 1 default, 2 colour-blind safe, 3 high contrast
	lineScale : number         -- thickness of a selected stretch's highlight (1 = normal)
	handleScale : number       -- size of the handles, drawn and grabbable (1 = normal)
	markerDetail : boolean     -- signal markers with their direction tick and kind tags
	-- panel
	panelLastTool : boolean    -- open on the tool used last (else on the tiles, no tool running)
	compactPanel : boolean     -- smaller tool tiles
	anarchyDefault : boolean   -- the tools start with Anarchy on
	buildMenu : boolean        -- the tools also in the Roads / Tracks menus' Network Tools tab (the
	                           -- way in on console, where the panel's window fails)
end

local opts : Options = {
	underground = false,
	bridgeHeight = 4.5,
	tunnelDepth = 8,
	structure = 1,
	heightOffset = 0,
	incline = nil,
	snapToRoads = true,
	overrideLanes = false,
	catenary = 1,
	busLane = false,
	tram = 1,
	lockDevelopment = false,
	playerOwned = false,
	decorations = false,
	hudIcons = true,
	footprints = true,
	saveSettings = true,
	labels = true,
	labelSpeed = true,
	labelGrade = true,
	labelRadius = true,
	labelHeight = true,
	labelTotal = true,
	labelDetail = true,
	labelSize = 1,
	labelRange = 4000,
	colorPreset = 1,
	lineScale = 1,
	handleScale = 1,
	markerDetail = true,
	panelLastTool = true,
	compactPanel = false,
	anarchyDefault = false,
	buildMenu = true,
}

-- a string that changes whenever an option does (the panel polls it to re-render)
local function key() : string
	return table.concat({
		tostring(opts.underground), tostring(opts.bridgeHeight), tostring(opts.tunnelDepth), tostring(opts.structure),
		tostring(opts.heightOffset), tostring(opts.incline), tostring(opts.snapToRoads), tostring(opts.overrideLanes),
		tostring(opts.pointLabel), tostring(opts.pointHeight),
		tostring(opts.pointCircle), tostring(opts.pointHeightEnd), tostring(opts.pointRadius), tostring(opts.pointStructure),
		tostring(opts.pointMovable), tostring(opts.pointMove),
		tostring(opts.catenary), tostring(opts.busLane), tostring(opts.tram), tostring(opts.lockDevelopment),
		tostring(opts.playerOwned), tostring(opts.decorations),
		tostring(opts.hudIcons), tostring(opts.footprints), tostring(opts.saveSettings),
		tostring(opts.labels), tostring(opts.labelSpeed), tostring(opts.labelGrade), tostring(opts.labelRadius),
		tostring(opts.labelHeight), tostring(opts.labelTotal), tostring(opts.labelDetail),
		tostring(opts.labelSize), tostring(opts.labelRange),
		tostring(opts.colorPreset), tostring(opts.lineScale), tostring(opts.handleScale), tostring(opts.markerDetail),
		tostring(opts.panelLastTool), tostring(opts.compactPanel), tostring(opts.anarchyDefault),
		tostring(opts.buildMenu),
	}, "/")
end

-- The underground view as a child of a tool's ActionDescriptor (as the game's construction menu
-- does it), or nil when off
local function layerNode() : TreeNodeId
	if not opts.underground then return nil end
	local ok, node = pcall(function() : TreeNodeId
		local cfg = api.type.LayerConfig.new()
		cfg.undergroundMode = true
		-- wrapped as { config = ... } like construction.tl (the .d.tl's Recipe<LayerConfig> is wrong)
		return builtin.LayerConfig({ config = cfg } as LayerConfig)
	end)
	return ok and node or nil
end

local function templateOf(name : string) : StreetTemplate
	if not name or name == "" then return nil end
	local ok, t = pcall(function() : StreetTemplate
		local id = api.res.streetTemplateRep.find(name)
		if id == nil or id < 0 then return nil end
		return api.res.streetTemplateRep.get(id)
	end)
	return ok and t or nil
end

local function useTemplate(seg : Proposal.SegmentAndEntity, name : string) : StreetTemplate
	local t = templateOf(name)
	if not t or #(t.laneConfigs or {}) == 0 then return nil end
	seg.comp.roadTemplate = name
	seg.comp.laneConfigs = t.laneConfigs
	seg.comp.roadStyle = t.streetStyle
	return t
end

local function isSidewalk(lc : LaneConfig) : boolean
	local modes = lc.transportModes or {}
	if modes[api.type["enum"].TransportMode.PERSON] then return true end
	for _, on in pairs(modes) do
		if on then return false end
	end
	return true
end

local function vehicleLanes(t : StreetTemplate) : integer
	local n = 0
	for _, lc in ipairs(t.laneConfigs or {}) do
		if not isSidewalk(lc) then n = n + 1 end
	end
	return n
end

local function categoriesOf(t : StreetTemplate) : {string : boolean}, {string : boolean}
	local cats, filters : {string : boolean}, {string : boolean} = {}, {}
	for _, c in ipairs(t.menuCategory and t.menuCategory.categories or {}) do
		if c.category then cats[c.category] = true end
		for _, f in ipairs(c.filterCategories or {}) do filters[f] = true end
	end
	return cats, filters
end

-- The network's variant that has all the `want` build-menu filters ("tram", "bus"): the same kind,
-- town / country, size category and number of vehicle lanes; among those the one whose name is
-- closest (best: the network's own name plus "With Tram Tracks" ...). The network itself when it
-- has them already; nil when there is none.
local function variantOf(name : string, tpl : StreetTemplate, want : {string}) : string
	local cats, filters = categoriesOf(tpl)
	local function hasAll(f : {string : boolean}) : boolean
		for _, w in ipairs(want) do if not f[w] then return false end end
		return true
	end
	if hasAll(filters) then return name end
	local lanes = vehicleLanes(tpl)
	local base = (tpl.description and tpl.description.name or ""):lower()
	local best, bestScore : string, number = nil, -math.huge
	for id, other in pairs(api.res.streetTemplateRep.getAll()) do
		local t = api.res.streetTemplateRep.get(id)
		if t.roadType == tpl.roadType and (t.country == true) == (tpl.country == true) then
			local oc, of = categoriesOf(t)
			local sameCat = false
			for c in pairs(cats) do if oc[c] then sameCat = true end end
			if sameCat and hasAll(of) and vehicleLanes(t) == lanes then
				local oname = (t.description and t.description.name or ""):lower()
				-- prefer names that start with the network's name, then the shortest extra
				local score = (base ~= "" and oname:sub(1, #base) == base) and 1000 or 0
				score = score - math.abs(#oname - #base)
				if score > bestScore then best, bestScore = other as string, score end
			end
		end
	end
	return best
end

local g_ownerFailLogged = false

-- New-road properties for a segment a tool builds new (its network already set)
local function applyRoad(seg : Proposal.SegmentAndEntity)
	local TM = api.type["enum"].TransportMode
	local isTrack = seg.comp.roadType == api.type["enum"].RoadType.TRACK
	local tpl = templateOf(seg.comp.roadTemplate)
	-- catenary: the network's electrified / plain twin
	if isTrack and tpl and opts.catenary ~= 1 then
		pcall(function()
			local twin = opts.catenary == 2 and tpl.catenaryAdd or tpl.catenaryRemove
			if twin and twin ~= "" then tpl = useTemplate(seg, twin) or tpl end
		end)
	end
	-- tram track / bus lane: TF3 has them as road types of their own ("... With Tram Tracks"), so
	-- switch to the network's variant. (Editing the lanes' transport modes by hand made lanes the
	-- engine asserts on - a hard crash on Build.)
	if not isTrack and tpl and (opts.busLane or opts.tram ~= 1) then
		local ok, err = pcall(function()
			local want : {string} = {}
			if opts.tram ~= 1 then want[#want + 1] = "tram" end
			if opts.busLane then want[#want + 1] = "bus" end
			local name = variantOf(seg.comp.roadTemplate, tpl, want)
			if not name then error("no variant of " .. tostring(seg.comp.roadTemplate) .. " with " .. table.concat(want, " + ")) end
			if name ~= seg.comp.roadTemplate then tpl = useTemplate(seg, name) or tpl end
			-- electric trams: the variant's electrified twin
			if opts.tram == 3 and tpl.catenaryAdd and tpl.catenaryAdd ~= "" then
				tpl = useTemplate(seg, tpl.catenaryAdd) or tpl
			end
		end)
		if not ok then
			dbg("[network_tools] tram / bus lane: built as the network (" .. tostring(err) .. ")")
		end
	end
	-- towns may not upgrade / extend it (or the network's own default)
	pcall(function()
		seg.comp.roadDevelopmentLocked = opts.lockDevelopment or (tpl ~= nil and tpl.initiallyLocked == true)
	end)
	-- the network's default edge decorations (only every one of them resolved: a partial or
	-- mismatched list is not risked)
	if opts.decorations and tpl and #(tpl.defaultEdgeDecorations or {}) > 0 then
		pcall(function()
			local decos : {{integer, boolean}} = {}
			for _, d in ipairs(tpl.defaultEdgeDecorations) do
				local id = api.res.edgeDecorationRep.find(d[1])
				if not id or id < 0 then return end
				decos[#decos + 1] = { id, d[2] }
			end
			seg.comp.edgeDecorations = decos
		end)
	end
	-- player owned: given to the player after the build (send(..., newRoads = true), below), with the
	-- official command
end

-- The segments of a successful build given to the player (cmd.makeEntitySetPlayerCmd, as the game's
-- own scripts do it). The build's result lists the new entities; the ones it removed are gone by now.
local function giveToPlayer(result : {{Engine.Entity, Engine.Revision}})
	local ok, err = pcall(function()
		local player = api.engine.util.getPlayer()
		local n = 0
		for __, r in ipairs(result or {}) do
			local e = r[1]
			local isEdge = false
			pcall(function()
				isEdge = api.engine.entityExists(e) and api.engine.getComponent(e, api.type.ComponentType.BASE_EDGE) ~= nil
			end)
			if isEdge then
				api.cmd.sendCommand(api.cmd.makeEntitySetPlayerCmd(e, player))
				n = n + 1
			end
		end
		dbg("[network_tools] player owned: " .. tostring(n) .. " segments")
	end)
	if not ok and not g_ownerFailLogged then
		g_ownerFailLogged = true
		dbg("[network_tools] player owned: " .. tostring(err))
	end
end

-- api.cmd.sendCommand for a tool's build, the one place every tool's build goes through
-- (the callback also gets the build's result entities: the new segments, signals ...). newRoads: the
-- build is new road / track with the new-road properties (applyRoad) - Player owned applies to it
-- (not set by tools that only re-add existing segments: Signals, Set slope ...)
local function send(cmd : Command<WorldBuildProposalCommandData>, callback? : function(WorldBuildProposalCommandData, boolean, {{Engine.Entity, Engine.Revision}}), newRoads? : boolean)
	local own = newRoads == true and opts.playerOwned == true
	api.cmd.sendCommand(cmd, function(data : WorldBuildProposalCommandData, success : boolean, resultEntities : {{Engine.Entity, Engine.Revision}})
		if success and own then giveToPlayer(resultEntities) end
		if callback then callback(data, success, resultEntities) end
	end)
end

-- The key the player has bound to a key command (api.util.getKeyName - "M" for constructOpt1 unless
-- rebound), for hints in tooltips and the panel; `fallback` if the game can't say
local function keyName(cmd : string, fallback : string) : string
	local ok, k = pcall(function() : string return api.util.getKeyName(cmd) end)
	if ok and k and k ~= "" then return k end
	return fallback
end

local record M
	opts : Options
	keyName : function(cmd : string, fallback : string) : string
	key : function() : string
	layerNode : function() : TreeNodeId
	applyRoad : function(seg : Proposal.SegmentAndEntity)
	send : function(cmd : Command<WorldBuildProposalCommandData>, callback? : function(WorldBuildProposalCommandData, boolean, {{Engine.Entity, Engine.Revision}}), newRoads? : boolean)
	debug : function(msg : string)
end
local m : M = {
	opts = opts,
	keyName = keyName,
	key = key,
	layerNode = layerNode,
	applyRoad = applyRoad,
	send = send,
	debug = dbg,
}
return m
