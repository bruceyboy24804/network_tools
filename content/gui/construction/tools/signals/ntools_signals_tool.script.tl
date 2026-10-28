-- Network Tools: Auto-signal (a Transport Fever tool). Select a stretch of track: block signals are
-- placed along it in equal blocks of about N metres, plus one at each switch (before it where the
-- track splits, past it where tracks join), all facing the chosen way of travel. Then Build.
-- Signals already on the track are kept and planned around; spots that can't take a signal are
-- moved to a nearby segment that can, or shown as red crosses with the reason (signals/<mode>/,
-- signals/ntools_signals_place).
--
-- How the game places a signal (read from its mission checks, mission_task_build_construction_util):
-- the segment is removed and re-added with the same shape; the re-added segment's comp.objects lists
-- the new signal ({ id, EdgeObjectType.SIGNAL }) and the proposal's edgeObjectsToAdd has a matching
-- SimpleStreetProposal.EdgeObject (edgeEntity = the new segment, param 0..1 along it, left = which
-- way it faces, oneWay, model). A segment's own signals are removed and placed again on the re-added
-- segment (shared/ntools_edge_signals); segments with stops / waypoints can't be re-added that way
-- and get no signal. Loaded by the connect tool (init() hand-over).

local builtin = ug_require "::/gui/main/builtin.lua" as Builtin
-- game controller support (shared/ntools_pad)
local record PadModule
	use : function() : any
	isLive : function(pad : any) : boolean
	trackLayer : function(pad : any)
	actions : function(pad : any, confirmText : string, back : function(), backText : string)
	selector : function(pad : any, p : {string : any}) : {string : any}
	anchor : function(pad : any) : TreeNodeId
	crosshair : function(pad : any) : boolean, string
end
local padMod = require "network_tools_1::/gui/construction/tools/shared/ntools_pad.script.tl" as PadModule
local engine_react_util = ug_require "::/gui/main/engine_react_util.tl" as EngineReactUtil
local react = ug_require "::/gui/main/react.lua" as React
local leave = require "network_tools_1::/gui/construction/tools/shared/ntools_leave.script.tl" as function(any)

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
local record Geom
	vec3 : function(p : P3) : Vec3f
	edgePiece : function(e : Engine.Component.BaseEdge) : Piece
	point : function(pc : Piece, t : number) : P3
	tangent : function(pc : Piece, t : number) : P3
	length : function(pc : Piece) : number
end
local geom = require "network_tools_1::/gui/construction/tools/shared/ntools_geom.script.tl" as Geom

local record NetUtil
	isProtectedNode : function(node : Engine.Entity) : boolean
	configNodesFor : function(removedEdges : {Engine.Entity}, extraNodes? : {Engine.Entity}, skipNodes? : {Engine.Entity}) : {Engine.Entity}
	rebuildCrossings : function(proposal : SimpleProposal, removedEdges : {Engine.Entity}, skipNodes? : {Engine.Entity}) : integer
end
local net_util = require "network_tools_1::/gui/construction/tools/shared/ntools_net_util.script.tl" as NetUtil

-- the build preview: the game's ProposalViewer, or our own green one in Anarchy (no red)
local record PreviewParams
	proposal : SimpleProposal
	id : string
	onData : function(ProposalData)
	anarchy : boolean
	noTags : boolean
end
local record Preview
	viewer : function(p : PreviewParams) : TreeNodeId
	leftover : function() : TreeNodeId
	clear : function()
end
local preview = require "network_tools_1::/gui/construction/tools/shared/ntools_preview.script.tl" as Preview

local record ChainLink
	edge : Engine.Entity
	fwd : boolean
end
local record PathOptions
	mode : integer            -- ntools_chain's MODE_* (1 fewest segments ... 16 alternative route)
	avoidStations : boolean
	electricOnly : boolean
end
local record Chain
	nodes : function(chain : {ChainLink}) : {Engine.Entity}
	click : function(chain : {ChainLink}, entity : Engine.Entity, avoid? : {Engine.Entity : boolean}, opts? : PathOptions) : {ChainLink}
	lastNote : function() : string
end
local chain_util = require "network_tools_1::/gui/construction/tools/shared/ntools_chain.script.tl" as Chain

local record Handle
	x : number
	y : number
	z : number
end
local record Canvas
	line : function(x0 : number, y0 : number, z0 : number, x1 : number, y1 : number, z1 : number, color : Vec4f, width : number)
	circle : function(cx : number, cy : number, z : number, r : number, color : Vec4f, width : number)
	handle : function(h : Handle, state : integer)
	edges : function(list : {Builtin.Type.EdgeRenderable.Edge})
	node : function() : TreeNodeId
end
-- dragging markers (the shared handle kit's controller)
local record DragCtl
	handles : {Handle}
	dragging : integer
	setDragging : function(i : integer)
	hover : integer
	setHover : function(i : integer)
	onDrag : function(i : integer, x : number, y : number)
	onRelease : function(i : integer)
end
local record Handles
	canvas : function() : Canvas
	cursor : function() : number, number
	hit : function(handles : {Handle}, x : number, y : number) : integer
	mouse : function(evt : Gui.Mouse.Event, ctl : DragCtl) : boolean
	colors : {string : Vec4f}
end
local handles = require "network_tools_1::/gui/construction/tools/shared/ntools_handles.script.tl" as Handles

-- options shared by all tools (the underground view)
local record SharedOptions
	opts : {string : any}
	key : function() : string
	layerNode : function() : TreeNodeId
end
local shared = require "network_tools_1::/gui/construction/tools/shared/ntools_options.script.tl" as SharedOptions

-- diagnostic traces: only with ntools_debug's DEBUG on
local dbg = (require "network_tools_1::/gui/construction/tools/shared/ntools_debug.script.tl" as {string : any}).log as function(string)

dbg("[network_tools] auto-signal tool script loaded (v5: drag / remove / add signals, hover info, block lengths)")

local END_CLEARANCE = 25      -- metres kept free at the stretch's two ends
local MIN_GAP = 30            -- metres: signals closer than this are merged
local BEFORE_SWITCH = 25      -- metres before a switch (in the direction of travel)
local CROSSING_MARGIN = 5     -- metres short of the segment that touches a level crossing

-- what the planned stretch comes to (the panel shows it)
local record Stats
	signals : integer         -- signals to place
	blocks : integer
	shortest : number
	longest : number
	average : number
	added : integer           -- placed / moved / turned by the player
	locked : integer
	removed : integer         -- planned ones the player removed
	skipped : integer         -- couldn't be placed
	existing : integer        -- already on the stretch
	replaced : integer        -- of those, removed (Replace)
	tracks : integer
end

-- options shared with the panel and the toolbar
local record Options
	spacing : number          -- metres between block signals (see spacingType)
	spacingType : integer     -- 1 equal blocks, 2 fixed interval, 3 by line speed, 4 by count
	blockCount : integer      -- by count: blocks between each pair of fixed signals
	oneWay : boolean
	reverse : boolean         -- trains travel against the selection's direction
	beforeSwitches : boolean
	beforeCrossings : boolean -- also a signal shortly before each level crossing
	switchDistance : number   -- metres before a switch (panel slider)
	crossingDistance : number -- metres short of the segments that touch a level crossing (slider)
	model : string            -- signal construction (ResName); nil = first available
	besideTracks : boolean    -- also signal the track running beside the stretch (double track)
	besideSameWay : boolean   -- trains on it run the same way (default: the opposite way)
	removeMode : boolean      -- remove the signals on the stretch (and alongside) instead
	stationMode : boolean     -- only exit signals where the stretch leaves a station
	pattern : integer         -- directions across the tracks: 1 opposite, 2 same, 3 alternate, 4 pairs, 5 auto
	runningSide : integer     -- (auto) trains keep 1 left, 2 right
	-- two-way track: every track signalled for both ways (its own plan each way; never one-way)
	twoWay : boolean
	-- signals already on the track: 1 keep and plan around them, 2 replace the ones facing the way
	-- being signalled, 3 ignore them (they stay, but don't count)
	existingMode : integer
	-- clearances and limits (metres; 0 = no limit)
	minGap : number           -- never two signals closer
	endClearance : number     -- kept free at the stretch's ends
	minBlock : number
	maxBlock : number
	-- switches: splits and joins each on or off, each with its own distance
	atSplits : boolean
	atJoins : boolean
	joinDistance : number     -- metres past a join (switchDistance: before a split)
	-- a signal type per kind (block, split, join, crossing, exit, entry, user); nil = the main one
	kindModels : {string : string}
	-- station mode
	exitDistance : number
	stationEntry : boolean
	entryDistance : number
	-- picking the stretch: a click further away adds the path to it (see ntools_chain)
	pathMode : integer         -- ntools_chain's MODE_*: 1 fewest segments, 2 shortest, 3 straightest,
	                           -- 4 same track type, 5 fastest, 6 flattest, 7 fewest junctions, 8 no bridges /
	                           -- tunnels, 9 A*, 10 beeline, 11 follow the line, 12 / 13 keep left / right,
	                           -- 14 highest minimum speed, 15 gentlest steepest climb, 16 alternative route
	pathAvoidStations : boolean
	pathElectric : boolean     -- only electrified track (every mode)
	-- names of the new signals: 1 like the game's (town), 2 namePrefix, 3 none; nameKind adds what
	-- each is for (Exit, Switch ...)
	nameStyle : integer
	namePrefix : string
	nameKind : boolean
	-- written every render for the panel's readout (see Stats)
	stats : Stats
end

local opts : Options = { spacing = 500, spacingType = 1, blockCount = 3, oneWay = false, reverse = false, beforeSwitches = true, beforeCrossings = false, switchDistance = BEFORE_SWITCH, crossingDistance = CROSSING_MARGIN, model = nil,
	besideTracks = true, besideSameWay = false, removeMode = false, stationMode = false, pattern = 1, runningSide = 1,
	twoWay = false, existingMode = 1, minGap = MIN_GAP, endClearance = END_CLEARANCE, minBlock = 0, maxBlock = 0,
	atSplits = true, atJoins = true, joinDistance = BEFORE_SWITCH, kindModels = {},
	exitDistance = 8, stationEntry = false, entryDistance = 8,
	pathMode = 3, pathAvoidStations = false, pathElectric = false,
	nameStyle = 1, namePrefix = "", nameKind = false }

-- every option that changes the plan, as one string (a change re-plans)
local function optsKey() : string
	local km : {string} = {}
	for k, v in pairs(opts.kindModels or {}) do km[#km + 1] = k .. "=" .. v end
	table.sort(km)
	return table.concat({
		tostring(opts.spacing), tostring(opts.spacingType), tostring(opts.blockCount), tostring(opts.oneWay),
		tostring(opts.reverse), tostring(opts.beforeSwitches), tostring(opts.atSplits), tostring(opts.atJoins),
		tostring(opts.switchDistance), tostring(opts.joinDistance), tostring(opts.beforeCrossings),
		tostring(opts.crossingDistance), tostring(opts.model), tostring(opts.besideTracks), tostring(opts.besideSameWay),
		tostring(opts.removeMode), tostring(opts.stationMode), tostring(opts.pattern), tostring(opts.runningSide), tostring(opts.twoWay),
		tostring(opts.existingMode), tostring(opts.minGap), tostring(opts.endClearance), tostring(opts.minBlock),
		tostring(opts.maxBlock), tostring(opts.exitDistance), tostring(opts.stationEntry), tostring(opts.entryDistance),
		table.concat(km, ","),
	}, "/")
end
local PATTERN_OPPOSITE, PATTERN_SAME, PATTERN_ALTERNATE, PATTERN_PAIRS = 1, 2, 3, 4

local record UiState
	canBuild : boolean
end
local record Host
	getEdge : function(Engine.Entity) : Engine.Component.BaseEdge
	isEdge : function(Engine.Entity) : boolean
	tooltip : function(message : string, good : boolean, bad : boolean, cost? : integer, keys? : string) : TreeNodeId
	anarchy : function() : boolean
	ui : UiState
	toolbarEvents : {string}
	shortcutHandler : function(handler : function(), enabled : function() : (boolean), prompt? : string, repeatPresses? : boolean) : React.IaHandler
	safeUseInputAction : function(string, React.IaHandler) : boolean
end
local g_host : Host = nil
local function init(host : any) g_host = host as Host end

----------------------------------------------------------------------------------------------------
-- Signal models

local record SignalModel
	name : string             -- ResName
	label : string
	oneWay : boolean          -- a one-way path signal
end

-- Path signals available this year. In TF3 a signal is an edge-object construction (e.g.
-- signal/signal_path_a.con, snapping to track) whose "One-Way" is a build option, not a separate
-- model; the models carry no "signal" metadata. So: constructions with an edgeObject that snaps to
-- track and "signal" in the file name. Any of them can be one-way (EdgeObject.oneWay).
local function listSignals() : {SignalModel}
	local out : {SignalModel} = {}
	pcall(function()
		local year = api.engine.util.getYear()
		for id, resName in pairs(api.res.constructionRep.getAll()) do
			pcall(function()
				if not resName:find("signal") or resName:find("missing") then return end
				local desc = api.res.constructionRep.get(id)
				local eo = desc and desc.edgeObject
				if not eo or not eo.snapToTrack then return end
				local av = desc.availability
				if av and ((av.yearFrom or 0) > 0 and year < av.yearFrom or (av.yearTo or 0) > 0 and year >= av.yearTo) then return end
				-- the proposal's EdgeObject.model takes the construction (as the Automatic Signal
				-- Spacing mod does, copying an existing signal's edgeObjectConstruction)
				local label = desc.description and desc.description.name or resName
				out[#out + 1] = { name = resName, label = label, oneWay = false }
			end)
		end
	end)
	if #out == 0 then dbg("[network_tools] signals: no signal constructions found") end
	table.sort(out, function(a : SignalModel, b : SignalModel) : boolean
		if a.oneWay ~= b.oneWay then return not a.oneWay end
		return a.label < b.label
	end)
	return out
end

-- the signal to use: the picked one, else the first available (one-way is a flag on the edge object)
local function chooseModel() : string
	local list = listSignals()
	-- the picked one only if it is still a valid model name (an older pick may be a .con)
	for _, s in ipairs(list) do
		if s.name == opts.model then return s.name end
	end
	return list[1] and list[1].name or nil
end

-- a signal type's name as the game shows it
local function modelLabel(name : string) : string
	for __, s in ipairs(listSignals()) do
		if s.name == name then return s.label end
	end
	return name
end

-- A signal that is already there (clicked in the world): its kind and type for the tooltip, or nil
-- when `e` is no signal. The signal list entity is also the signal's edge object.
local function describeSignal(e : Engine.Entity, index : integer) : string
	local ok, txt = pcall(function() : string
		local sl = api.engine.getComponent(e, api.type.ComponentType.SIGNAL_LIST) as Engine.Component.SignalList
		if not sl or not sl.signals or #sl.signals == 0 then return nil end
		local sd = sl.signals[(index or 0) + 1] or sl.signals[1]
		local T = api.type.Signal.Type
		local kind = sd.type == T.ONE_WAY_SIGNAL and _("One-way signal")
			or sd.type == T.WAYPOINT and _("Waypoint")
			or _("Signal")
		local out = _("Clicked") .. ": " .. kind
		local eo = api.engine.getComponent(e, api.type.ComponentType.EDGE_OBJECT) as Engine.Component.EdgeObject
		if eo and eo.edgeObjectConstruction then
			out = out .. "\n" .. _("Type") .. ": " .. modelLabel(eo.edgeObjectConstruction as string)
		end
		-- the segment it stands on (the engine knows it directly) and how far along
		local okE, edge = pcall(function() : Engine.Entity return api.engine.system.streetSystem.getEdgeForEdgeObject(e) end)
		local be = okE and edge and edge >= 0 and g_host.getEdge(edge) or nil
		if be then
			local L = geom.length(geom.edgePiece(be))
			local at = eo and eo.param and (eo.param * L) or nil
			out = out .. "\n" .. (at
				and string.format(_("On segment %d, %.0f m of %.0f m"), edge, at, L)
				or string.format(_("On segment %d (%.0f m)"), edge, L))
		end
		if #sl.signals > 1 then
			out = out .. "\n" .. string.format(_("Signal %d of %d here"), (index or 0) + 1, #sl.signals)
		end
		return out .. "\n" .. _("Entity") .. ": " .. tostring(e)
	end)
	if not ok then dbg("[network_tools] signals: reading the clicked signal failed: " .. tostring(txt)) end
	return ok and txt or nil
end

local function isSignal(e : Engine.Entity) : boolean
	local ok, sl = pcall(function() : any return api.engine.getComponent(e, api.type.ComponentType.SIGNAL_LIST) end)
	return ok and sl ~= nil
end

-- naming styles (opts.nameStyle)
local NAME_GAME = 1      -- "<closest town> Signal #n", as the game's own signal tool
local NAME_CUSTOM = 2    -- "<namePrefix> #n"
local NAME_OFF = 3       -- left unnamed
-- what a signal is for, as a word in its name (opts.nameKind); plain block / own signals: none
local NAME_KIND_WORDS : {string : string} = {
	split = "Switch", join = "Join", crossing = "Crossing", exit = "Exit", entry = "Entry",
}

-- the highest number given to each name this session (in case the engine can't list every signal)
local g_nameCounts : {string : integer} = {}

-- a planned spot as the naming needs it: where it is and what it is for
local record NameSpot
	x : number
	y : number
	kind : string
end

-- Signals built through a proposal get no name (the window shows "Name"). After a build, the new
-- unnamed signals among the result (or on its segments) are named in the chosen style, numbered on
-- from the highest number that name already has. spots: the planned signals (for what each is for)
local function nameNewSignals(result : {{Engine.Entity, Engine.Revision}}, spots : {NameSpot})
	if opts.nameStyle == NAME_OFF then return end
	local ok, err = pcall(function()
		local CT = api.type.ComponentType
		-- (per entity: one without a name, or gone - the old signals the build removed - throws
		-- "Invalid entity", which mustn't stop the rest)
		local function nameOf(e : Engine.Entity) : string
			if not e or e < 0 or not api.engine.entityExists(e) then return nil end
			local okN, n = pcall(function() : string
				local nm = api.engine.getComponent(e, CT.NAME) as Engine.Component.Name
				return nm and nm.name or nil
			end)
			return okN and n or nil
		end
		local seen : {Engine.Entity : boolean} = {}
		local new : {Engine.Entity} = {}
		local function consider(e : Engine.Entity)
			if seen[e] or not isSignal(e) then return end
			seen[e] = true
			local n = nameOf(e)
			if not n or n == "" then new[#new + 1] = e end
		end
		for __, r in ipairs(result or {}) do
			local e = r[1]
			consider(e)
			local okE, edge = pcall(function() : Engine.Component.BaseEdge
				if not api.engine.entityExists(e) then return nil end
				return api.engine.getComponent(e, CT.BASE_EDGE) as Engine.Component.BaseEdge
			end)
			if not okE then edge = nil end
			for ___, obj in ipairs(edge and edge.objects or {}) do
				if obj[2] == api.type["enum"].EdgeObjectType.SIGNAL then consider(obj[1]) end
			end
		end
		dbg(string.format("[network_tools] signals: naming - %d result entities, %d new unnamed signals", #(result or {}), #new))
		if #new == 0 then return end
		local word = _("Signal")
		-- the highest number each name already has ("<name> #<n>"): the engine won't loop over
		-- SIGNAL_LIST ("Cannot loop over this component type"), so over every named entity if it allows
		-- that, else the signals on the segments this build touched; and what we numbered before
		local used : {string : integer} = {}
		for base, n in pairs(g_nameCounts) do used[base] = n end
		local function count(e : Engine.Entity)
			local base, num = (nameOf(e) or ""):match("^(.-) #(%d+)$")
			if base then used[base] = math.max(used[base] or 0, math.floor(tonumber(num))) end
		end
		local okAll = pcall(function() api.engine.forEachEntityWithComponent(count, CT.NAME) end)
		dbg("[network_tools] signals: naming - numbers from " .. (okAll and "every named entity" or "the touched segments"))
		if not okAll then
			for __, r in ipairs(result or {}) do
				pcall(function()
					if not api.engine.entityExists(r[1]) then return end
					local edge = api.engine.getComponent(r[1], CT.BASE_EDGE) as Engine.Component.BaseEdge
					for ___, obj in ipairs(edge and edge.objects or {}) do count(obj[1]) end
				end)
			end
		end
		local prefix = (opts.namePrefix or ""):match("^%s*(.-)%s*$")
		if prefix == "" then prefix = word end
		for i, e in ipairs(new) do
			local eo = api.engine.getComponent(e, CT.EDGE_OBJECT) as Engine.Component.EdgeObject
			local pos = eo and eo.transf and eo.transf:getTransl() or nil
			-- what it is for: the planned spot it stands on (within a few metres)
			local kindWord = ""
			if opts.nameKind and pos then
				local best, bestD : string, number = nil, 6.0
				for ___, sp in ipairs(spots or {}) do
					local d = math.sqrt((sp.x - pos.x) ^ 2 + (sp.y - pos.y) ^ 2)
					if d < bestD then best, bestD = sp.kind, d end
				end
				kindWord = best and NAME_KIND_WORDS[best] and _(NAME_KIND_WORDS[best]) or ""
			end
			local base : string
			if opts.nameStyle == NAME_CUSTOM then
				-- "<custom> [Exit]"
				base = prefix .. (kindWord ~= "" and (" " .. kindWord) or "")
			else
				-- like the game's: "<closest town> [Exit] Signal"
				local town : string = nil
				if pos then
					-- (it lives in util.town, as the game's own scripts call it - the .d.tl puts it in util)
					local okT, t = pcall(function() : Engine.Entity
						local util = api.engine.util as {string : any}
						local tu = util.town as {string : function(Vec3f) : Engine.Entity}
						local f = tu and tu.getClosestTown or util.getClosestTown as function(Vec3f) : Engine.Entity
						return f(pos)
					end)
					if not okT and i == 1 then dbg("[network_tools] signals: closest town: " .. tostring(t)) end
					town = okT and t and nameOf(t) or nil
				end
				base = ((town and town ~= "") and (town .. " ") or "") .. (kindWord ~= "" and (kindWord .. " ") or "") .. word
			end
			local n = (used[base] or 0) + 1
			used[base] = n
			g_nameCounts[base] = math.max(g_nameCounts[base] or 0, n)
			-- forceSameEntity: a signal without a name of its own would otherwise pass the name on to
			-- its "stem" (another entity) and keep showing "Name"
			local name = base .. " #" .. tostring(n)
			local first = i == 1
			api.cmd.sendCommand(api.cmd.makeEntitySetNameCmd(e, name, true), function(_d : EntitySetNameCommandData, success : boolean)
				if first then
					dbg(string.format("[network_tools] signals: named %d as '%s': %s (shown now: %s)", e, name,
						tostring(success), tostring(nameOf(e))))
				end
			end)
		end
	end)
	if not ok then dbg("[network_tools] signals: naming the new signals failed: " .. tostring(err)) end
end

----------------------------------------------------------------------------------------------------
-- Planning

local record Spot
	link : integer            -- index into the chain
	param : number            -- 0..1 along the segment, in the segment's own direction
	pos : P3
	dir : P3                  -- direction of travel at the spot (plan)
	along : boolean           -- trains pass it in the segment's own direction
	track : Engine.Entity     -- which track it is on (its stretch's first segment): click to flip
	kind : string             -- "block", "split" / "join" (at a switch), "crossing", "exit" (station),
	                          -- "user" (placed by the player)
	reason : string           -- a skipped spot: why no signal could go there
	moved : number            -- metres it walked off a segment that couldn't take it
	at : number               -- distance along its stretch
	user : boolean            -- the player's (placed, moved, turned round or locked by them)
	locked : boolean          -- a planned signal the player locked where it stands
	model : string            -- the signal type picked for this one signal (nil = by kind)
end

-- a stretch as the planners read it (signals/ntools_signals_place): what the preview needs of it
local record Existing
	at : number
	alongChain : boolean
end
local record Track
	S : number
	existing : {Existing}
	existingAll : {Existing}
	blocked : {integer : string}
	travelAlong : boolean
end

local record Plan
	spots : {Spot}
	skipped : integer         -- spots that couldn't be placed (skippedSpots: where, and why)
	skippedSpots : {Spot}
	removedSpots : {Spot}     -- planned signals the player removed (shown faintly)
	length : number
	why : string
	track : Track
end

-- The player's edits, kept as world positions on the track centre lines with the way trains pass
-- the signal there, so they survive extending the stretch and changing options. Each plan reads the
-- ones on its own track (editsFor). A planned signal the player moves, turns round, locks or gives
-- its own type becomes one of theirs: removed where it was planned, added where it stands now.
local record WorldEdit
	x : number
	y : number
	z : number
	dx : number               -- the way trains pass it (plan, unit vector)
	dy : number
	kind : string             -- adds: "user", or the kind of the planned signal it was
	model : string            -- adds: its own signal type (nil = by kind)
	locked : boolean          -- adds: a planned signal locked where it stood
end
local record WorldEdits
	adds : {WorldEdit}
	removes : {WorldEdit}
end
-- the edits as one plan takes them (distances along its stretch; see ntools_signals_place)
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

-- tags in the world (the block lengths, the signals' kinds), like the street builder's
-- (shared/ntools_labels)
local record LabelRow
	icon : string
	text : string
end
local record Label
	x : number
	y : number
	z : number
	text : string
	rows : {LabelRow}
	detail : {LabelRow}
	level : integer
end
local screen_labels = require "network_tools_1::/gui/construction/tools/shared/ntools_labels.script.tl" as {string : any}
local setLabels = screen_labels.set as function(tags : {Engine.Entity : any}, points : {Label})
local labelsNode = screen_labels.node as function() : TreeNodeId
local signalIcons = screen_labels.icons as {string : string}

-- the signals on a segment, to place again when it is re-added (shared/ntools_edge_signals)
local record SignalCopy
	entity : Engine.Entity
	param : number
	model : string
	left : boolean
	oneWay : boolean
end
local readSignals = (require "network_tools_1::/gui/construction/tools/shared/ntools_edge_signals.script.tl" as {string : any}).readSignals
	as function(e : Engine.Entity, oe : Engine.Component.BaseEdge) : {SignalCopy}, string

-- A segment that belongs to a construction (a station's platform tracks): it can't be replaced, so
-- no signal can go on it.
local g_loggedConstructionErr = false
-- the construction (station, depot...) that owns a segment, or nil
local function constructionOfEdge(edge : Engine.Entity) : Engine.Entity
	local ok, c = pcall(function() : Engine.Entity
		return api.engine.system.streetConnectorSystem.getConstructionEntityForEdge(edge)
	end)
	if not ok and not g_loggedConstructionErr then
		g_loggedConstructionErr = true
		dbg("[network_tools] signals: getConstructionEntityForEdge failed: " .. tostring(c))
	end
	if ok and c and c >= 0 then return c end
	return nil
end

local function isFrozenEdge(edge : Engine.Entity) : boolean
	return constructionOfEdge(edge) ~= nil
end

-- Segments on which the game refused a signal (found by checking a refused plan segment by
-- segment, see probeRefusal): planned as unable to take one, so their signals move to a segment
-- nearby. For the session - the reason (a station's area, ...) doesn't go away by itself.
local g_refused : {Engine.Entity : boolean} = {}
local function refusedEdge(edge : Engine.Entity) : boolean
	return g_refused[edge] == true
end

-- The modes, one module each in signals/<mode>/ (Spacing: block signals every N metres; Station:
-- exit signals and equal blocks; Remove), set up with the helpers here. g_host is set later (init),
-- so the modules reach it through getEdge.
local record ModeSpacing
	makePlan : function(chain : {ChainLink}, reverse : boolean, editsFor? : function(T : Track) : Edits) : Plan
end
local record ModeStation
	makeStationPlan : function(chain : {ChainLink}, reverse? : boolean, editsFor? : (function(T : Track) : Edits), ownWayOnly? : boolean) : Plan
end
local record ModeRemove
	makeRemoveProposal : function(chains : {{ChainLink}}) : SimpleProposal, integer
end
local modeCtx : {string : any} = {
	opts = opts, END_CLEARANCE = END_CLEARANCE, MIN_GAP = MIN_GAP, BEFORE_SWITCH = BEFORE_SWITCH,
	CROSSING_MARGIN = CROSSING_MARGIN,
	getEdge = function(e : Engine.Entity) : Engine.Component.BaseEdge return g_host.getEdge(e) end,
	constructionOfEdge = constructionOfEdge, isFrozenEdge = isFrozenEdge, refusedEdge = refusedEdge,
	isProtectedNode = net_util.isProtectedNode, configNodesFor = net_util.configNodesFor,
	rebuildCrossings = net_util.rebuildCrossings, chainNodes = chain_util.nodes,
	edgePiece = geom.edgePiece, point = geom.point, tangent = geom.tangent, length = geom.length,
	readSignals = readSignals,
}
-- placing a signal on a stretch (shared by Spacing and Station); the preview uses its track helpers
local record PlaceApi
	REMOVE_TOL : number
	project : function(T : Track, x : number, y : number) : number, number
	pointAt : function(T : Track, at : number) : P3
end
local placeApi = (require "network_tools_1::/gui/construction/tools/signals/ntools_signals_place.script.tl" as function({string : any}) : PlaceApi)(modeCtx)
modeCtx.place = placeApi

-- the way along the stretch at distance `at` (plan, unit; in the stretch's own direction)
local function stretchDir(T : Track, at : number) : number, number
	local a = placeApi.pointAt(T, math.max(0, at - 1))
	local b = placeApi.pointAt(T, math.min(T.S, at + 1))
	local dx, dy = b.x - a.x, b.y - a.y
	local l = math.sqrt(dx * dx + dy * dy)
	if l < 1e-6 then return 1, 0 end
	return dx / l, dy / l
end

local EDIT_TOL = 2.0   -- metres: an edit belongs to the track whose centre line it lies this close to

-- One plan's share of the player's edits: the adds on its track (two-way track: only the ones
-- facing the way this plan signals - the other way's plan takes the rest), as distances along it.
-- Removals are applied after planning (removeEdited), by position and facing.
local function editsFor(we : WorldEdits, twoWay : boolean) : function(T : Track) : Edits
	return function(T : Track) : Edits
		local out : Edits = { adds = {}, removes = {} }
		for __, e in ipairs(we.adds or {}) do
			local at, d = placeApi.project(T, e.x, e.y)
			if d <= EDIT_TOL then
				local sx, sy = stretchDir(T, at)
				local alongChain = sx * e.dx + sy * e.dy > 0
				if not twoWay or alongChain == T.travelAlong then
					out.adds[#out.adds + 1] = { at = at, alongChain = alongChain, kind = e.kind, model = e.model, locked = e.locked }
				end
			end
		end
		return out
	end
end

-- an edit within `tol` of (x, y) facing the way (dx, dy), as an index into `list`; 0 = none
local function findEdit(list : {WorldEdit}, x : number, y : number, dx : number, dy : number, tol : number) : integer
	local best, bestD = 0, tol * tol
	for i, e in ipairs(list or {}) do
		local d = (e.x - x) ^ 2 + (e.y - y) ^ 2
		if d <= bestD and e.dx * dx + e.dy * dy > 0 then best, bestD = i, d end
	end
	return best
end

-- unit plan direction of a spot's travel
local function spotDir(sp : Spot) : number, number
	local l = math.sqrt(sp.dir.x * sp.dir.x + sp.dir.y * sp.dir.y)
	if l < 1e-6 then return 1, 0 end
	return sp.dir.x / l, sp.dir.y / l
end

-- the planned signals the player removed: out of the plan into removedSpots (shown faintly)
local function removeEdited(plan : Plan, we : WorldEdits)
	plan.removedSpots = plan.removedSpots or {}
	if #(we.removes or {}) == 0 then return end
	local function removed(sp : Spot) : boolean
		if sp.user then return false end
		local dx, dy = spotDir(sp)
		return findEdit(we.removes, sp.pos.x, sp.pos.y, dx, dy, placeApi.REMOVE_TOL) > 0
	end
	local kept : {Spot} = {}
	for __, sp in ipairs(plan.spots) do
		if removed(sp) then plan.removedSpots[#plan.removedSpots + 1] = sp else kept[#kept + 1] = sp end
	end
	plan.spots = kept
	local keptSkipped : {Spot} = {}
	for __, sp in ipairs(plan.skippedSpots or {}) do
		if removed(sp) then plan.removedSpots[#plan.removedSpots + 1] = sp else keptSkipped[#keptSkipped + 1] = sp end
	end
	plan.skippedSpots = keptSkipped
	plan.skipped = #keptSkipped
end
local spacingPlanner = (require "network_tools_1::/gui/construction/tools/signals/spacing/ntools_signals_spacing.script.tl" as function({string : any}) : ModeSpacing)(modeCtx)
local stationPlanner = (require "network_tools_1::/gui/construction/tools/signals/station/ntools_signals_station.script.tl" as function({string : any}) : ModeStation)(modeCtx)
local removePlanner = (require "network_tools_1::/gui/construction/tools/signals/remove/ntools_signals_remove.script.tl" as function({string : any}) : ModeRemove)(modeCtx)

----------------------------------------------------------------------------------------------------
-- Tracks alongside (double / multi track)

local BESIDE_MIN, BESIDE_MAX = 2.5, 15     -- metres between track centre lines
local PARALLEL_DOT = 0.9                    -- |cos| of the angle between them

-- the track segment running beside the chain at piece pc, param t (nil if none): the closest one
-- within BESIDE_MAX whose direction there is parallel, not in `exclude`
local function besideEdge(pc : Piece, t : number, exclude : {Engine.Entity : boolean}) : Engine.Entity
	local p = geom.point(pc, t)
	local d = geom.tangent(pc, t)
	local dl = math.sqrt(d.x * d.x + d.y * d.y)
	if dl < 1e-6 then return nil end
	local dx, dy = d.x / dl, d.y / dl
	-- nodes near the point (searching segments directly misses track, see the Parallel tool), then
	-- their segments; the radius covers long segments whose ends are far away
	local radius = math.max(60, geom.length(pc))
	local ok, near = pcall(function() : {Engine.Entity}
		return api.engine.util.octree.findEntitiesInCircle(api.type.Vec2f.new(p.x, p.y), radius, api.type.ComponentType.BASE_NODE)
	end)
	local best, bestDist : Engine.Entity, number = nil, math.huge
	local seen : {Engine.Entity : boolean} = {}
	for _, node in ipairs(ok and near or {}) do
		local okS, segs = pcall(function() : {Engine.Entity} return api.engine.system.streetSystem.getNodeSegments(node) end)
		for _, s in ipairs(okS and segs or {}) do
			if not seen[s] and not exclude[s] then
				seen[s] = true
				local e = g_host.getEdge(s)
				if e and e.roadType == api.type["enum"].RoadType.TRACK then
					local q = geom.edgePiece(e)
					-- closest of samples along the candidate, ~4 m apart (a fixed count steps right
					-- over the +-6 m window on long segments, and the track beside is missed)
					local ns = math.floor(math.max(16, math.min(400, geom.length(q) / 4)))
					for i = 0, ns do
						local u = i / ns
						local c = geom.point(q, u)
						local ox, oy = c.x - p.x, c.y - p.y
						local along = ox * dx + oy * dy
						local lateral = math.abs(ox * dy - oy * dx)
						if math.abs(along) < 6 and math.abs(c.z - p.z) < 4 and lateral >= BESIDE_MIN and lateral <= BESIDE_MAX and lateral < bestDist then
							local ct = geom.tangent(q, u)
							local cl = math.sqrt(ct.x * ct.x + ct.y * ct.y)
							if cl > 1e-6 and math.abs((ct.x * dx + ct.y * dy) / cl) >= PARALLEL_DOT then
								best, bestDist = s, lateral
							end
						end
					end
				end
			end
		end
	end
	return best
end

-- The stretch of track beside `chain`, running the same way, or nil: tracks found beside it from
-- each end inwards, joined by the stretch picker's path search kept off the chain's own segments
-- (no hopping over at a crossover); the pair covering most of the chain, and at least half of it.
-- exclude: segments of tracks already found (several tracks: each search skips those)
local function besideChain(chain : {ChainLink}, exclude? : {Engine.Entity : boolean}) : {ChainLink}
	local own : {Engine.Entity : boolean} = {}
	for e, v in pairs(exclude or {}) do own[e] = v end
	for _, l in ipairs(chain) do own[l.edge] = true end
	-- candidates from each end inwards (distinct segments; the stretch's ends may run past where the
	-- other track starts / stops). What is beside the first segments may be a junction leg or a
	-- siding rather than the other main track, so pairs are tried until two are joined along one
	-- track without using the stretch itself (no hopping over at a crossover)
	local CANDIDATES = 6
	local record Cand
		i : integer
		e : Engine.Entity
	end
	local function collect(from : integer, to : integer, step : integer, t0 : number, t1 : number) : {Cand}
		local out : {Cand} = {}
		local seenE : {Engine.Entity : boolean} = {}
		for i = from, to, step do
			local e = besideEdge(geom.edgePiece(g_host.getEdge(chain[i].edge)), chain[i].fwd and t0 or t1, own)
			if e and not seenE[e] then
				seenE[e] = true
				out[#out + 1] = { i = i, e = e }
				if #out >= CANDIDATES then break end
			end
		end
		return out
	end
	local starts = collect(1, #chain, 1, 0.25, 0.75)
	if #starts == 0 then return nil end
	local ends = collect(#chain, starts[1].i, -1, 0.75, 0.25)
	-- of the pairs that join, the one covering most of the stretch (the first to join can be a
	-- short siding beside part of it)
	local a : Engine.Entity = nil
	local ia = 0
	local other : {ChainLink} = nil
	local bestSpan = -1
	for __, s in ipairs(starts) do
		for __, en in ipairs(ends) do
			if en.i >= s.i and en.i - s.i > bestSpan then
				local o = chain_util.click({}, s.e)
				if en.e ~= s.e then o = chain_util.click(o, en.e, own) end
				local ok = #o > 0 and (en.e == s.e or #o >= 2)
				for __, l in ipairs(o) do if own[l.edge] then ok = false end end
				if ok then a, ia, other, bestSpan = s.e, s.i, o, en.i - s.i end
			end
		end
	end
	if not other then return nil end
	-- a track beside only a short part of the stretch is a junction leg or siding running past, not
	-- a track of the line: it must run beside at least half of it
	if (bestSpan + 1) * 2 < #chain then return nil end
	local firstPc = geom.edgePiece(g_host.getEdge(chain[ia].edge))
	-- orient it like the chain: its first segment is the one beside the chain's start
	if other[1].edge ~= a then
		local flipped : {ChainLink} = {}
		for i = #other, 1, -1 do flipped[#flipped + 1] = { edge = other[i].edge, fwd = not other[i].fwd } end
		other = flipped
	end
	-- a single segment: set its direction from the chain's
	if #other == 1 then
		local q = geom.edgePiece(g_host.getEdge(a))
		local t0 = geom.tangent(firstPc, 0.5)
		local t1 = geom.tangent(q, 0.5)
		local same = (t0.x * t1.x + t0.y * t1.y) > 0
		other[1].fwd = (chain[ia].fwd == same)
	end
	return other
end

-- Every track running beside the stretch, outwards on both sides (3+ track lines): each found
-- track is searched from in turn, skipping the tracks already found. All run the same way as the
-- stretch (orientation), so the caller decides each one's direction of travel.
local MAX_TRACKS_BESIDE = 5
local function besideChains(chain : {ChainLink}) : {{ChainLink}}
	local found : {{ChainLink}} = {}
	local excl : {Engine.Entity : boolean} = {}
	for _, l in ipairs(chain) do excl[l.edge] = true end
	local queue : {{ChainLink}} = { chain }
	local qi = 1
	while qi <= #queue and #found < MAX_TRACKS_BESIDE do
		local ok, b = pcall(besideChain, queue[qi], excl)
		if ok and b then
			for _, l in ipairs(b) do excl[l.edge] = true end
			found[#found + 1] = b
			queue[#queue + 1] = b
		else
			if not ok then dbg("[network_tools] signals: beside search failed: " .. tostring(b)) end
			qi = qi + 1
		end
	end
	return found
end


-- Signed sideways distance of a track from the stretch (left of its direction = positive), at the
-- stretch's first segment: orders the tracks across the line for the direction patterns.
local function lateral(chain : {ChainLink}, other : {ChainLink}) : number
	local pc = geom.edgePiece(g_host.getEdge(chain[1].edge))
	local p = geom.point(pc, 0.5)
	local t = geom.tangent(pc, 0.5)
	if not chain[1].fwd then t = { x = -t.x, y = -t.y, z = 0 } end
	local qc = geom.edgePiece(g_host.getEdge(other[1].edge))
	-- the point of the other track's first segment closest to p
	local best, bestD : P3, number = nil, math.huge
	for i = 0, 16 do
		local q = geom.point(qc, i / 16)
		local d = (q.x - p.x) ^ 2 + (q.y - p.y) ^ 2
		if d < bestD then best, bestD = q, d end
	end
	return t.x * (best.y - p.y) - t.y * (best.x - p.x)
end

-- Whether each track runs against the stretch's direction of travel, by the pattern: tracks are
-- ordered across the line (index), `sel` is the stretch's own place in that order.
local function patternFlip(pattern : integer, index : integer, sel : integer) : boolean
	local k = index - sel
	if pattern == PATTERN_SAME then return false end
	if pattern == PATTERN_ALTERNATE then return k % 2 ~= 0 end
	if pattern == PATTERN_PAIRS then
		-- pairs counted from the left-most track
		return (math.floor((index - 1) / 2) - math.floor((sel - 1) / 2)) % 2 ~= 0
	end
	return k ~= 0      -- opposite: every other track runs against the stretch
end

-- Pattern Auto: each track's direction worked out from what is in the world, most telling first:
--   1. its existing signals (which way they face, by majority)
--   2. the trains running on it (which way their paths cross it)
--   3. the running side (opts.runningSide): looking the way trains go, they keep left (or right) -
--      the tracks left of the line's middle run one way, those right of it the other (platform
--      tracks through a station alongside the line follow the same rule)
--   4. otherwise (one track, or the middle one) as selected
local PATTERN_AUTO = 5
local RUN_LEFT, RUN_RIGHT = 1, 2

local record AutoLane
	chain : {ChainLink}
	side : number             -- sideways from the stretch, left of its direction positive (lateral)
end

-- trains whose paths use the track: how often they cross it along / against its direction
local function trainVotes(lane : {ChainLink}) : integer, integer
	local along, against = 0, 0
	pcall(function()
		local edges : {Engine.Entity} = {}
		local fwdOf : {Engine.Entity : boolean} = {}
		for __, l in ipairs(lane) do edges[#edges + 1] = l.edge; fwdOf[l.edge] = l.fwd end
		local vehicles = api.engine.system.transportVehicleSystem.getVehicles(edges, false)
		for i = 1, math.min(#vehicles, 200) do
			local mp = api.engine.getComponent(vehicles[i], api.type.ComponentType.MOVE_PATH) as Engine.Component.MovePath
			for __, step in ipairs(mp and mp.path and mp.path.edges or {}) do
				local f = fwdOf[step[1].entity]
				-- (true: the path runs the segment node0 -> node1)
				if f ~= nil then
					if step[2] == f then along = along + 1 else against = against + 1 end
				end
			end
		end
	end)
	return along, against
end

-- For each track (ordered across the line): whether its trains run against its own direction, and
-- why (for the tooltip)
local function autoDirections(lanes : {AutoLane}, runningSide : integer, fallbackRev : boolean) : {boolean}, {string}
	local revs : {boolean} = {}
	local why : {string} = {}
	local centre = 0.0
	for __, ln in ipairs(lanes) do centre = centre + ln.side end
	centre = centre / math.max(#lanes, 1)
	for i, ln in ipairs(lanes) do
		local along, against = 0, 0
		for __, l in ipairs(ln.chain) do
			local ok, sigs = pcall(readSignals, l.edge, g_host.getEdge(l.edge))
			for ___, sc in ipairs(ok and sigs or {}) do
				-- (left: the signal is for travel against the segment's own direction)
				if l.fwd ~= sc.left then along = along + 1 else against = against + 1 end
			end
		end
		if along ~= against then
			revs[i], why[i] = against > along, _("its signals")
		else
			local tAlong, tAgainst = trainVotes(ln.chain)
			if tAlong ~= tAgainst then
				revs[i], why[i] = tAgainst > tAlong, _("the trains on it")
			elseif #lanes >= 2 and math.abs(ln.side - centre) > 0.5 then
				-- keep left: the tracks left of the middle run the stretch's way
				local leftOfMiddle = ln.side > centre
				revs[i] = leftOfMiddle == (runningSide == RUN_RIGHT)
				why[i] = runningSide == RUN_RIGHT and _("keep right") or _("keep left")
			else
				revs[i], why[i] = fallbackRev, _("as selected")
			end
		end
	end
	return revs, why
end

-- one track to signal: its stretch and the plan for it
local record Job
	chain : {ChainLink}
	plan : Plan
end

-- returns the proposal (nil: nothing to build), why not, and how many signals already there it
-- removes (Replace)
local function makeSignalProposal(jobs : {Job}) : SimpleProposal, string, integer
	local model = chooseModel()
	if not model then return nil, _("No signal type is available yet"), 0 end
	-- a signal's type: its own, else its kind's, else the main one (each only if still available)
	local valid : {string : boolean} = {}
	for __, s in ipairs(listSignals()) do valid[s.name] = true end
	local function modelFor(sp : Spot) : string
		if sp.model and valid[sp.model] then return sp.model end
		local km = (opts.kindModels or {})[sp.kind]
		if km and valid[km] then return km end
		return model
	end
	local oneWay = opts.oneWay and not opts.twoWay
	-- the segments that get signals (each once, even if two stretches share it)
	local bySeg : {Engine.Entity : {Spot}} = {}
	local order : {Engine.Entity} = {}
	local function addSeg(edge : Engine.Entity)
		if not bySeg[edge] then bySeg[edge] = {}; order[#order + 1] = edge end
	end
	-- Replace: every signal already on the tracks being signalled goes, both ways (per segment, by
	-- their `left` flag: left = facing against the segment's direction). Was: only the ones facing
	-- the way being signalled - so after Same, Opposite + Replace kept the old signals on the track
	-- that changed direction ("Replace doesn't work", "Opposite looks like Same" - user report
	-- 2026-10-11; the debug log showed the tool's own signals read and dropped correctly)
	local dropLeft : {Engine.Entity : {boolean : boolean}} = {}
	for __, job in ipairs(jobs) do
		for __, sp in ipairs(job.plan.spots) do
			local edge = job.chain[sp.link].edge
			addSeg(edge)
			table.insert(bySeg[edge], sp)
		end
		if opts.existingMode == 2 and job.plan.track then
			local T = job.plan.track
			for i, l in ipairs(job.chain) do
				-- (only segments that can be re-added: not station track, stops, edited junctions)
				if not (T.blocked or {})[i] then
					dropLeft[l.edge] = { [true] = true, [false] = true }
				else
					dbg("[network_tools] signals replace: seg " .. tostring(l.edge) .. " blocked: " .. tostring(T.blocked[i]))
				end
			end
		end
	end
	-- segments with a signal to replace but none planned: re-added without it
	local replaced = 0
	for edge, drops in pairs(dropLeft) do
		local okS, sigs = pcall(readSignals, edge, g_host.getEdge(edge))
		for __, sc in ipairs(okS and sigs or {}) do
			if drops[sc.left] then addSeg(edge) end
		end
		-- (debug: what Replace saw on each segment - its signals' facing, the facing it drops)
		local seen : {string} = {}
		for __, sc in ipairs(okS and sigs or {}) do seen[#seen + 1] = string.format("%.2f%s", sc.param, sc.left and "L" or "R") end
		dbg(string.format("[network_tools] signals replace: seg %s drops L=%s R=%s read=%s signals=[%s]", tostring(edge),
			tostring(drops[true] == true), tostring(drops[false] == true), tostring(okS and sigs ~= nil), table.concat(seen, " ")))
	end
	if #order == 0 then return nil, nil, 0 end
	local edgesToAdd : {Proposal.SegmentAndEntity} = {}
	local edgesToRemove : {Engine.Entity} = {}
	local objects : {SimpleStreetProposal.EdgeObject} = {}
	local objectsRemoved : {Engine.Entity} = {}
	-- new signals are referenced from their segment by placeholder ids far below every other new
	-- entity (pattern from the Automatic Signal Spacing mod; -(segments + n) crashed the engine)
	local nextPlaceholder = -400000000
	local function addSignal(k : integer, refs : {{Engine.Entity, EdgeObjectType}}, param : number, left : boolean, oneWay : boolean, m : string)
		local o = api.type.SimpleStreetProposal.EdgeObject.new()
		o.edgeEntity = -k
		o.param = param
		o.oneWay = oneWay
		o.left = left
		o.model = m
		o.playerEntity = api.engine.util.getPlayer()
		objects[#objects + 1] = o
		refs[#refs + 1] = { nextPlaceholder, api.type["enum"].EdgeObjectType.SIGNAL }
		nextPlaceholder = nextPlaceholder - 1
	end
	for k, edge in ipairs(order) do
		local l : ChainLink = { edge = edge, fwd = true }
		local e = g_host.getEdge(edge)
		local seg = api.type.SegmentAndEntity.new()
		seg.entity = -k
		-- the whole segment as it is (keeps every field)
		seg.comp = e
		seg.type = 1
		pcall(function()
			local po = api.engine.getComponent(l.edge, api.type.ComponentType.PLAYER_OWNED)
			if po then seg.playerOwned = po end
		end)
		local refs : {{Engine.Entity, EdgeObjectType}} = {}
		-- the signals already on it are removed and placed again on the re-added segment, same place,
		-- facing, one-way and model (as Parallel does on crossed track); the planner only picks
		-- segments whose objects are all readable signals (else: their objects kept as they were)
		local okS, sigs = pcall(readSignals, edge, e)
		if okS and sigs then
			for _, sc in ipairs(sigs) do
				-- (Replace: the ones facing a way being signalled aren't placed again)
				if not (dropLeft[edge] and dropLeft[edge][sc.left]) then
					addSignal(k, refs, sc.param, sc.left, sc.oneWay, sc.model or model)
				else
					replaced = replaced + 1
				end
				objectsRemoved[#objectsRemoved + 1] = sc.entity
			end
		else
			for _, obj in ipairs(e.objects or {}) do refs[#refs + 1] = { obj[1], obj[2] } end
		end
		-- Two signals at (nearly) the same place on a segment crash the engine ("Assertion
		-- AreSplitParametersValid"): two-way track plans the same block ends for both ways, and a
		-- player's signal can land on a planned one. Each new one keeps SAME_SPOT metres from every
		-- other on the segment - nudged along it if it can be, left out if it can't.
		local SAME_SPOT = 4
		local segLen = math.max(1, geom.length(geom.edgePiece(e)))
		local margin = 3 / segLen
		local taken : {number} = {}
		if okS and sigs then
			for __, sc in ipairs(sigs) do
				if not (dropLeft[edge] and dropLeft[edge][sc.left]) then taken[#taken + 1] = sc.param end
			end
		end
		local function free(p : number) : boolean
			if p < margin or p > 1 - margin then return false end
			for __, t in ipairs(taken) do
				if math.abs(t - p) * segLen < SAME_SPOT then return false end
			end
			return true
		end
		for _, sp in ipairs(bySeg[edge]) do
			local p = sp.param
			if not free(p) then
				p = nil
				for step = 1, 6 do
					for __, sgn in ipairs({ 1, -1 }) do
						local q = sp.param + sgn * step * SAME_SPOT / segLen
						if not p and free(q) then p = q end
					end
				end
			end
			if p then
				taken[#taken + 1] = p
				-- facing: left = against the segment's own direction (travel along it = false)
				addSignal(k, refs, p, not sp.along, oneWay, modelFor(sp))
			end
		end
		seg.comp.objects = refs
		edgesToAdd[#edgesToAdd + 1] = seg
		edgesToRemove[#edgesToRemove + 1] = l.edge
	end
	local proposal = api.type.SimpleProposal.new()
	proposal.streetProposal.edgesToAdd = edgesToAdd
	proposal.streetProposal.edgesToRemove = edgesToRemove
	proposal.streetProposal.edgeObjectsToAdd = objects
	if #objectsRemoved > 0 then proposal.streetProposal.edgeObjectsToRemove = objectsRemoved end
	-- the end nodes' lane connections name the re-added segments: let the engine rebuild them
	local cfg = net_util.configNodesFor(edgesToRemove)
	if #cfg > 0 then proposal.streetProposal.nodeConfigsToRemove = cfg end
	-- a re-added segment at a level crossing: the engine re-creates the crossing (same type)
	net_util.rebuildCrossings(proposal, edgesToRemove)
	return proposal, nil, replaced
end

----------------------------------------------------------------------------------------------------
-- Why the game refuses a plan: the segments re-added without any new signal, then each segment's
-- new signals on their own. The segments whose signals are refused go in g_refused (the plan then
-- moves their signals to a segment nearby); returns how many were new.

local g_lastProbe = ""

-- the last plan the recipe made and what it was made from (see "Planning is the heavy part" below)
local g_planCache : {string : any} = { key = "" }
local function probeRefusal(sp : SimpleProposal, probeId : string) : integer
	if probeId == g_lastProbe then return 0 end
	g_lastProbe = probeId
	local validate = api.engine.util.proposal.makeProposalData as function(SimpleProposal) : ProposalData
	local src = sp.streetProposal
	local segs = src.edgesToAdd
	local objs = src.edgeObjectsToAdd or {}
	-- only segment `only`'s new signals (0: none), placeholders renumbered from the first
	local function variant(only : integer) : SimpleProposal
		local p = api.type.SimpleProposal.new()
		local edges : {Proposal.SegmentAndEntity} = {}
		local kept : {SimpleStreetProposal.EdgeObject} = {}
		local next = -400000000
		for __, s in ipairs(segs) do
			local c = api.type.SegmentAndEntity.new()
			c.entity = s.entity
			c.comp = s.comp
			c.type = s.type
			pcall(function() c.playerOwned = s.playerOwned end)
			local refs : {{Engine.Entity, EdgeObjectType}} = {}
			for __, r in ipairs(s.comp.objects or {}) do
				if r[1] >= 0 then
					refs[#refs + 1] = { r[1], r[2] }
				elseif s.entity == -only then
					refs[#refs + 1] = { next, r[2] }
					next = next - 1
				end
			end
			c.comp.objects = refs
			edges[#edges + 1] = c
		end
		for __, o in ipairs(objs) do
			if o.edgeEntity == -only then kept[#kept + 1] = o end
		end
		p.streetProposal.edgesToAdd = edges
		p.streetProposal.edgesToRemove = src.edgesToRemove
		p.streetProposal.edgeObjectsToAdd = kept
		pcall(function() p.streetProposal.edgeObjectsToRemove = src.edgeObjectsToRemove end)
		pcall(function() p.streetProposal.nodeConfigsToRemove = src.nodeConfigsToRemove end)
		pcall(function() p.streetProposal.node2rcType = src.node2rcType end)
		return p
	end
	local function refused(p : SimpleProposal) : string
		local ok, pd = pcall(validate, p)
		if not ok then return "check failed: " .. tostring(pd) end
		if pd.errorState.critical then
			local m = ""
			for __, s in ipairs(pd.errorState.messages) do m = m .. s .. " " end
			return m ~= "" and m or "refused"
		end
		return nil
	end
	local P = "[network_tools] signals: "
	local base = refused(variant(0))
	if base then
		dbg(P .. "refused even with no new signals (the segments / crossings themselves): " .. base)
		return 0
	end
	local bad, added = 0, 0
	for __, s in ipairs(segs) do
		local k = -s.entity
		local mine : {string} = {}
		for __, o in ipairs(objs) do
			if o.edgeEntity == s.entity then
				mine[#mine + 1] = string.format("%.3f%s", o.param, o.left and "L" or "R")
			end
		end
		if #mine > 0 then
			local why = refused(variant(k))
			if why then
				bad = bad + 1
				local orig = src.edgesToRemove[k]
				if orig and not g_refused[orig] then
					g_refused[orig] = true
					added = added + 1
				end
				local e = s.comp
				local okL, len = pcall(function() : number return geom.length(geom.edgePiece(e)) end)
				local nOld = 0
				for __, r in ipairs(e.objects or {}) do if r[1] >= 0 then nOld = nOld + 1 end end
				dbg(string.format("%ssegment %d refused (%s): length %.0f m, at (%.0f,%.0f), new signals at %s, other objects kept %d",
					P, k, why, okL and len or -1, e.position0.x, e.position0.y, table.concat(mine, " "), nOld))
			end
		end
	end
	if bad == 0 then dbg(P .. "every segment's signals pass on their own - it's how they combine") end
	return added
end

----------------------------------------------------------------------------------------------------
-- Tool

local SignalsActionRecipe = react.RegisterRecipe("NtoolsSignalsAction", function(params : ConstructionCustomActionParams<any>) : TreeNodeId
	react.onUnmount(preview.clear)   -- its speed / incline tags leave with the tool
	local chainState : ReactStateT<{ChainLink}> = react.useState({})
	-- the segments the player clicked to make the stretch, in order: replayed with the new settings
	-- when the path type / its filters change, so the stretch re-routes straight away
	local anchorsRef : ReactRefT<{Engine.Entity}> = react.useRef({})
	local pathKeyRef : ReactRefT<string> = react.useRef(nil)
	-- tracks the player turned round by clicking their signal markers (key: the track's first segment)
	local flipsState : ReactStateT<{Engine.Entity : boolean}> = react.useState({})
	local costState : ReactStateT<integer> = react.useState(0)
	local errorState : ReactStateT<string> = react.useState("")
	-- bumped when the game refused signals on segments it hadn't before (g_refused): plan again
	local refusedVerState : ReactStateT<integer> = react.useState(0)
	local aliveRef : ReactRefT<boolean> = react.useRef(true)
	-- true from Build until the command's callback (a half-built segment under the cursor is an
	-- engine assertion, not a Lua error)
	local busyState : ReactStateT<boolean> = react.useState(false)
	-- the player's edits, as world positions (kept when the stretch is extended or options change;
	-- cleared by Reset and Build)
	local editsState : ReactStateT<WorldEdits> = react.useState({ adds = {}, removes = {} })
	-- markers as handles: the one being dragged / under the cursor (0 = none), where a dragged one
	-- would land (distance along its track), and whether the press has become a drag
	local draggingState : ReactStateT<integer> = react.useState(0)
	local hoverState : ReactStateT<integer> = react.useState(0)
	local dragAtState : ReactStateT<number> = react.useState(-1)
	local dragAtRef : ReactRefT<number> = react.useRef(-1)      -- (the latest, for the release)
	local dragMovedRef : ReactRefT<boolean> = react.useRef(false)
	-- the block under the cursor ("<track>:<index>", "" = none): the tooltip describes it
	local blockHoverState : ReactStateT<string> = react.useState("")
	-- a signal already there that the player clicked: what it is (shown until the next click)
	local signalInfoState : ReactStateT<string> = react.useState("")
	-- why the last click couldn't add a path to the stretch ("" = it could)
	local pathNoteState : ReactStateT<string> = react.useState("")
	local keyUi = engine_react_util.useStepState(function() : string
		return optsKey() .. shared.key()
	end)
	-- the path settings (type, filters): a change re-routes the stretch (see anchorsRef)
	local pathUi = engine_react_util.useStepState(function() : string
		return tostring(opts.pathMode) .. "/" .. tostring(opts.pathElectric) .. "/" .. tostring(opts.pathAvoidStations)
	end)
	local anarchyUi = engine_react_util.useStepState(function() : boolean return g_host.anarchy() end)

	local handlersRef : ReactRefT<{string : function()}> = react.useRef({})
	for _, name in ipairs(g_host.toolbarEvents) do
		react.onEvent(name, function()
			local h = handlersRef:get()[name]
			if h then h() end
		end)
	end

	-- the game's "Flip" modifier (Ctrl by default; its track tool's "(Hold) Flip Segment"). Polling
	-- it doesn't work, so it is followed through its input action's events (pattern from MoveIt)
	local ctrlRef : ReactRefT<boolean> = react.useRef(false) as ReactRefT<boolean>
	pcall(function()
		react.useInputAction("IA_SECONDARY_MODE", react.iaHandlerExtended(function(invokeData : Gui.InputAction.InvokeData)
			local Status = api.gui.inputAction.InvokeData.Status
			if invokeData.status == Status.Triggered then
				ctrlRef:set(true)
			elseif invokeData.status == Status.EndReleased or invokeData.status == Status.EndAborted then
				ctrlRef:set(false)
			end
		end, nil, nil))
	end)
	-- keys on the signal under the cursor (right-click is the engine's: it cancels the tool), and
	-- Ctrl+clicks that reach the recipe as PressedOutside; the handlers are set further down
	local keyFnsRef : ReactRefT<{string : function()}> = react.useRef({})
	local outsideRef : ReactRefT<function(Gui.Mouse.Event) : boolean> = react.useRef(nil)
	local function keyEnabled() : boolean
		local f = keyFnsRef:get().enabled as function() : boolean
		return f ~= nil and f()
	end
	g_host.safeUseInputAction("constructOpt7", g_host.shortcutHandler(function()
		local f = keyFnsRef:get().lock
		if f then f() end
	end, keyEnabled, _("Lock / unlock signal")))
	g_host.safeUseInputAction("constructOpt8", g_host.shortcutHandler(function()
		local f = keyFnsRef:get().nextType
		if f then f() end
	end, keyEnabled, _("Next signal type")))
	react.onMouseEvent(function(evt : Gui.Mouse.Event) : boolean
		local f = outsideRef:get()
		return f ~= nil and f(evt)
	end)
	-- focused for the bottom-right key list (run from the panel nothing else focuses the tool)
	local selfRef = react.useSelfRef() as ReactNodeRef
	local focusedRef : ReactRefT<boolean> = react.useRef(false)

	react.setForceFocusable(true)
	react.setRestrictMouseFocus(true)
	local pad = padMod.use()

	-- (on a pad isActive flickers off on the confirm press: the tool stays while its layer is up)
	if not params.isActive and not padMod.isLive(pad) then
		focusedRef:set(false)
		return
	end
	if not focusedRef:get() then
		-- (the node may not exist on the first render: then the next render tries again)
		local ok = pcall(function() ((selfRef as any) as ReactRefWrap):get():focus() end)
		focusedRef:set(ok)
	end

	local busy = busyState:old() == true
	local chain : {ChainLink} = {}
	if not busy then
		for _, l in ipairs(chainState:old() or {}) do
			if api.engine.entityExists(l.edge) and g_host.getEdge(l.edge) then chain[#chain + 1] = l end
		end
	end
	-- how a click further along finds its path (the panel's path type and filters)
	local function pathOpts() : PathOptions
		return { mode = opts.pathMode or 3, avoidStations = opts.pathAvoidStations == true, electricOnly = opts.pathElectric == true }
	end
	-- path settings changed: the same clicks again, routed the new way
	local pathKey = pathUi:old() or ""
	if pathKeyRef:get() ~= pathKey then
		local first = pathKeyRef:get() == nil
		pathKeyRef:set(pathKey)
		local anchors = anchorsRef:get() or {}
		if not first and not busy and #anchors >= 2 then
			local nc : {ChainLink} = {}
			local po = pathOpts()
			for __, a in ipairs(anchors) do
				local there = false
				for ___, l in ipairs(nc) do if l.edge == a then there = true end end
				-- (an anchor the new route already runs through isn't clicked again: that would remove it)
				if not there and api.engine.entityExists(a) then nc = chain_util.click(nc, a, nil, po) end
			end
			chain = nc
			chainState:set(nc)
			pathNoteState:set(chain_util.lastNote())
		end
	end
	local key = keyUi:old() or ""
	local anarchy = anarchyUi:old() == true

	local plan : Plan = nil
	local beside : {ChainLink} = nil          -- every track alongside, all their links (highlight)
	local nBesideTracks = 0
	local besidePlan : Plan = nil             -- their planned signals together (markers / counts)
	local proposal : SimpleProposal = nil
	local why : string = nil
	local nRemove = 0
	-- every track planned (the stretch and the ones alongside): what the preview needs of each
	local record View
		key : Engine.Entity       -- the track's first segment (its flip key)
		second : boolean          -- two-way track: the plan for the other way
		T : Track
		plan : Plan
	end
	local views : {View} = {}
	local allEdits : WorldEdits = editsState:old() or { adds = {}, removes = {} }
	local nReplaced = 0
	local autoNote : string = nil   -- Auto directions: each track's and why (tooltip)
	-- Planning is the heavy part (every track, the tracks alongside, the proposal). The tool renders
	-- again on every hover / block-hover change, which re-planned the whole stretch each time (FPS
	-- drop while moving over signals), so the result is kept and reused until something it depends
	-- on changes: the stretch, the options (key), turned tracks, the player's edits, refused segments.
	local planKey : string = nil
	if not busy and #chain > 0 then
		local parts : {string} = { key, tostring(refusedVerState:old() or 0) }
		for __, l in ipairs(chain) do parts[#parts + 1] = tostring(l.edge) .. (l.fwd and "+" or "-") end
		local fk : {string} = {}
		for k, v in pairs(flipsState:old() or {}) do if v then fk[#fk + 1] = tostring(k) end end
		table.sort(fk)
		parts[#parts + 1] = "f" .. table.concat(fk, ",")
		for __, a in ipairs(allEdits.adds or {}) do
			parts[#parts + 1] = string.format("+%.1f,%.1f,%.2f,%.2f,%s,%s,%s", a.x, a.y, a.dx, a.dy, tostring(a.kind), tostring(a.model), tostring(a.locked))
		end
		for __, r in ipairs(allEdits.removes or {}) do parts[#parts + 1] = string.format("-%.1f,%.1f", r.x, r.y) end
		planKey = table.concat(parts, "|")
	end
	local hit = planKey ~= nil and g_planCache.key == planKey
	if hit then
		local c = g_planCache
		plan, beside, nBesideTracks, besidePlan = c.plan as Plan, c.beside as {ChainLink}, c.nBesideTracks as integer, c.besidePlan as Plan
		proposal, why, nRemove, nReplaced = c.proposal as SimpleProposal, c.why as string, c.nRemove as integer, c.nReplaced as integer
		views = c.views as {View}
		autoNote = c.autoNote as string
	elseif not busy and #chain > 0 then
		if opts.stationMode and not opts.removeMode then
			plan = stationPlanner.makeStationPlan(chain, opts.reverse)
		else
			plan = spacingPlanner.makePlan(chain, opts.reverse)
		end
		why = plan.why
		local tracks : {{ChainLink}} = {}
		if not why and opts.besideTracks then
			tracks = besideChains(chain)
			nBesideTracks = #tracks
			if #tracks > 0 then
				beside = {}
				for _, t in ipairs(tracks) do
					for _, l in ipairs(t) do beside[#beside + 1] = l end
				end
			end
		end
		if not why and opts.removeMode then
			-- remove the signals on the stretch and the tracks alongside
			local all : {{ChainLink}} = { chain }
			for _, t in ipairs(tracks) do all[#all + 1] = t end
			proposal, nRemove = removePlanner.makeRemoveProposal(all)
			plan = { spots = {}, skipped = 0, skippedSpots = {}, removedSpots = {}, length = plan.length }
		elseif not why then
			-- every track (the stretch too) ordered across the line, right to left
			local record Lane
				chain : {ChainLink}
				side : number
			end
			local lanes : {Lane} = { { chain = chain, side = 0 } }
			for _, t in ipairs(tracks) do
				local okL, sd = pcall(lateral, chain, t)
				lanes[#lanes + 1] = { chain = t, side = okL and sd or 0 }
			end
			table.sort(lanes, function(a : Lane, b : Lane) : boolean return a.side < b.side end)
			local sel = 1
			for i, ln in ipairs(lanes) do if ln.chain == chain then sel = i end end
			local pattern = opts.pattern or PATTERN_OPPOSITE
			if opts.besideSameWay then pattern = PATTERN_SAME end
			local flips = flipsState:old() or {}
			local jobs : {Job} = {}
			besidePlan = { spots = {}, skipped = 0, skippedSpots = {}, removedSpots = {}, length = 0 }
			local twoWay = opts.twoWay == true
			local ef = editsFor(allEdits, twoWay)
			-- Auto: every track's direction from the world (and why, for the tooltip)
			local autoRevs : {boolean} = nil
			if pattern == PATTERN_AUTO then
				local whys : {string}
				local al : {AutoLane} = {}
				for __, ln in ipairs(lanes) do al[#al + 1] = { chain = ln.chain, side = ln.side } end
				autoRevs, whys = autoDirections(al, opts.runningSide or RUN_LEFT, opts.reverse == true)
				local parts : {string} = {}
				for i, w in ipairs(whys) do
					-- (each track's way compared with the stretch's own direction of travel)
					local same = autoRevs[i] == (opts.reverse == true)
					parts[#parts + 1] = string.format("%s %d: %s (%s)", _("Track"), i, same and _("this way") or _("other way"), w)
				end
				autoNote = _("Directions (tracks right to left)") .. "\n   " .. table.concat(parts, "\n   ")
			end
			for i, ln in ipairs(lanes) do
				local key = ln.chain[1].edge
				-- the pattern's direction, turned round where the player Shift+clicked the track's signals
				local rev : boolean
				if autoRevs then rev = autoRevs[i] else rev = opts.reverse ~= patternFlip(pattern, i, sel) end
				if flips[key] then rev = not rev end
				-- (debug: each track's place across the line and the direction the pattern gave it)
				dbg(string.format("[network_tools] signals lanes: %d/%d sel=%d side=%.1f pattern=%s besideSameWay=%s flip=%s rev=%s first=%s fwd=%s segs=%d",
					i, #lanes, sel, ln.side, tostring(pattern), tostring(opts.besideSameWay), tostring(flips[key] == true), tostring(rev),
					tostring(ln.chain[1].edge), tostring(ln.chain[1].fwd), #ln.chain))
				-- two-way track: each way planned on its own
				local ways : {boolean} = twoWay and { rev, not rev } or { rev }
				for wi, r in ipairs(ways) do
					local tp : Plan
					if opts.stationMode then
						tp = stationPlanner.makeStationPlan(ln.chain, r, ef, twoWay)
					else
						tp = spacingPlanner.makePlan(ln.chain, r, ef)
					end
					removeEdited(tp, allEdits)
					if ln.chain == chain and wi == 1 then plan = tp end
					for __, sp in ipairs(tp.spots) do sp.track = key end
					for __, sp in ipairs(tp.skippedSpots or {}) do sp.track = key end
					for __, sp in ipairs(tp.removedSpots or {}) do sp.track = key end
					if tp.track then views[#views + 1] = { key = key, second = wi == 2, T = tp.track, plan = tp } end
					if not tp.why then
						jobs[#jobs + 1] = { chain = ln.chain, plan = tp }
						if ln.chain ~= chain then
							for __, sp in ipairs(tp.spots) do besidePlan.spots[#besidePlan.spots + 1] = sp end
							for __, sp in ipairs(tp.skippedSpots or {}) do besidePlan.skippedSpots[#besidePlan.skippedSpots + 1] = sp end
							besidePlan.skipped = besidePlan.skipped + tp.skipped
						end
					end
				end
			end
			proposal, why, nReplaced = makeSignalProposal(jobs)
		end
		g_planCache = { key = planKey, plan = plan, beside = beside, nBesideTracks = nBesideTracks, besidePlan = besidePlan,
			proposal = proposal, why = why, nRemove = nRemove, nReplaced = nReplaced, views = views, autoNote = autoNote }
	end
	local blocked = errorState:old() ~= "" and not anarchy
	g_host.ui.canBuild = proposal ~= nil and not blocked

	-- Markers: every signal in the preview is a handle. Drag = move it, click = remove / bring back
	-- (a red cross: hide it), Shift+click = turn its whole track round, hover = what it is (tooltip).
	local record Mark
		sp : Spot
		view : View
		state : string            -- "placed", "skipped" or "removed"
	end
	local marks : {Mark} = {}
	for _, v in ipairs(views) do
		for _, sp in ipairs(v.plan.spots) do marks[#marks + 1] = { sp = sp, view = v, state = "placed" } end
		if not opts.removeMode then
			for _, sp in ipairs(v.plan.skippedSpots or {}) do marks[#marks + 1] = { sp = sp, view = v, state = "skipped" } end
			for _, sp in ipairs(v.plan.removedSpots or {}) do marks[#marks + 1] = { sp = sp, view = v, state = "removed" } end
		end
	end
	local markHandles : {Handle} = {}
	for i, m in ipairs(marks) do markHandles[i] = { x = m.sp.pos.x, y = m.sp.pos.y, z = m.sp.pos.z } end

	-- Blocks: the stretches of track between two signals in a row (planned, the player's, or already
	-- there facing the same way), per track
	local record Block
		id : string
		view : View
		a : number
		b : number
		fromKind : string
		toKind : string
	end
	local blocks : {Block} = {}
	if not opts.removeMode then
		for _, v in ipairs(views) do
			local stops : {{any}} = {}
			for _, sp in ipairs(v.plan.spots) do stops[#stops + 1] = { sp.at, sp.kind } end
			for _, ex in ipairs(v.T.existing or {}) do
				if ex.alongChain == v.T.travelAlong then stops[#stops + 1] = { ex.at, "existing" } end
			end
			table.sort(stops, function(p : {any}, q : {any}) : boolean return (p[1] as number) < (q[1] as number) end)
			for k = 1, #stops - 1 do
				local a, b = stops[k][1] as number, stops[k + 1][1] as number
				if b - a > 1 then
					-- (named in the order trains pass them)
					local fa, fb = stops[k][2] as string, stops[k + 1][2] as string
					if not v.T.travelAlong then fa, fb = fb, fa end
					blocks[#blocks + 1] = { id = tostring(v.key) .. ":" .. tostring(k), view = v, a = a, b = b, fromKind = fa, toKind = fb }
				end
			end
		end
	end

	-- the readout for the panel (opts.stats)
	do
		local st : Stats = { signals = 0, blocks = #blocks, shortest = 0, longest = 0, average = 0, added = 0, locked = 0,
			removed = 0, skipped = 0, existing = 0, replaced = nReplaced or 0, tracks = 0 }
		for __, m in ipairs(marks) do
			if m.state == "placed" then
				st.signals = st.signals + 1
				if m.sp.user then st.added = st.added + 1 end
				if m.sp.locked then st.locked = st.locked + 1 end
			elseif m.state == "skipped" then st.skipped = st.skipped + 1
			else st.removed = st.removed + 1 end
		end
		local seen : {Engine.Entity : boolean} = {}
		for __, v in ipairs(views) do
			if not seen[v.key] then
				seen[v.key] = true
				st.tracks = st.tracks + 1
				st.existing = st.existing + #(v.T.existingAll or {})
			end
		end
		local sum = 0.0
		for i, bl in ipairs(blocks) do
			local L = bl.b - bl.a
			sum = sum + L
			if i == 1 or L < st.shortest then st.shortest = L end
			if L > st.longest then st.longest = L end
		end
		if #blocks > 0 then st.average = sum / #blocks end
		if #chain == 0 or opts.removeMode then st = nil end
		opts.stats = st
	end

	-- the planned track under (x, y): its view and the distance along it, or nil
	local TRACK_HIT = 6
	local function trackAt(x : number, y : number) : View, number
		local best : View = nil
		local bestAt, bestD = 0.0, TRACK_HIT
		for _, v in ipairs(views) do
			local at, d = placeApi.project(v.T, x, y)
			if d < bestD then best, bestAt, bestD = v, at, d end
		end
		return best, bestAt
	end
	local function blockAt(x : number, y : number) : string
		local v, at = trackAt(x, y)
		if not v then return "" end
		for _, bl in ipairs(blocks) do
			if bl.view == v and at >= bl.a and at <= bl.b then return bl.id end
		end
		return ""
	end

	-- Shift (the game's precision modifier) held
	local function shiftHeld() : boolean
		local ok, active = pcall(function() : boolean
			return api.gui.inputAction.modifierOnlyActionIsActive("IA_PRECISION_MODE")
		end)
		return ok and active == true
	end
	-- Ctrl (followed by ctrlRef, above)
	local function ctrlHeld() : boolean
		return ctrlRef:get() == true
	end

	-- the player's edits, changed (a copy per change: React state)
	local function edit(change : function(e : WorldEdits))
		local old = editsState:old() or { adds = {}, removes = {} }
		local e : WorldEdits = { adds = {}, removes = {} }
		for i, a in ipairs(old.adds or {}) do e.adds[i] = a end
		for i, r in ipairs(old.removes or {}) do e.removes[i] = r end
		change(e)
		editsState:set(e)
		costState:set(0)
		errorState:set("")
	end
	local function drop(list : {WorldEdit}, i : integer) : {WorldEdit}
		local out : {WorldEdit} = {}
		for k, v in ipairs(list) do if k ~= i then out[#out + 1] = v end end
		return out
	end
	-- a world edit for a marker's spot (its position and facing)
	local function editOf(sp : Spot) : WorldEdit
		local dx, dy = spotDir(sp)
		return { x = sp.pos.x, y = sp.pos.y, z = sp.pos.z, dx = dx, dy = dy, kind = sp.kind, model = sp.model, locked = sp.locked }
	end
	-- the player's add a marker stands for (0 = none)
	local function addIndex(e : WorldEdits, sp : Spot) : integer
		local dx, dy = spotDir(sp)
		return findEdit(e.adds, sp.pos.x, sp.pos.y, dx, dy, placeApi.REMOVE_TOL + 2)
	end
	-- a planned signal becomes the player's where it stands (removed as planned, added as theirs),
	-- changed by `how`; one of theirs is just changed
	local function takeOver(m : Mark, how : function(a : WorldEdit))
		edit(function(e : WorldEdits)
			if m.sp.user then
				local i = addIndex(e, m.sp)
				if i > 0 then
					local o = e.adds[i]
					local a : WorldEdit = { x = o.x, y = o.y, z = o.z, dx = o.dx, dy = o.dy, kind = o.kind, model = o.model, locked = o.locked }
					how(a)
					e.adds[i] = a
				end
			else
				e.removes[#e.removes + 1] = editOf(m.sp)
				local a = editOf(m.sp)
				how(a)
				e.adds[#e.adds + 1] = a
			end
		end)
	end
	-- a click on a marker: remove a planned signal, drop one of the player's, bring a removed one back,
	-- hide a red cross
	local function toggleMark(m : Mark)
		edit(function(e : WorldEdits)
			local dx, dy = spotDir(m.sp)
			if m.state == "removed" then
				local i = findEdit(e.removes, m.sp.pos.x, m.sp.pos.y, dx, dy, placeApi.REMOVE_TOL)
				if i > 0 then e.removes = drop(e.removes, i) end
			elseif m.sp.user then
				local i = addIndex(e, m.sp)
				if i > 0 then e.adds = drop(e.adds, i) end
			else
				e.removes[#e.removes + 1] = editOf(m.sp)
			end
		end)
	end
	-- a marker dropped at distance `to` along its track: the player's signal stands there now, facing
	-- the same way along the track
	local function moveMark(m : Mark, to : number)
		local p = placeApi.pointAt(m.view.T, to)
		local sx, sy = stretchDir(m.view.T, to)
		local dx, dy = spotDir(m.sp)
		local ox, oy = stretchDir(m.view.T, m.sp.at)
		if ox * dx + oy * dy < 0 then sx, sy = -sx, -sy end
		if m.state == "removed" then
			-- (a removed one dragged elsewhere: brought back there as the player's)
			edit(function(e : WorldEdits)
				e.adds[#e.adds + 1] = { x = p.x, y = p.y, z = p.z, dx = sx, dy = sy, kind = m.sp.kind, model = m.sp.model }
			end)
			return
		end
		takeOver(m, function(a : WorldEdit)
			a.x, a.y, a.z, a.dx, a.dy = p.x, p.y, p.z, sx, sy
			a.locked = nil
		end)
	end
	-- Shift+click on a track: a signal of the player's own there, facing that plan's way of travel
	local function addSignal(v : View, at : number)
		local p = placeApi.pointAt(v.T, at)
		local sx, sy = stretchDir(v.T, at)
		if not v.T.travelAlong then sx, sy = -sx, -sy end
		edit(function(e : WorldEdits)
			e.adds[#e.adds + 1] = { x = p.x, y = p.y, z = p.z, dx = sx, dy = sy, kind = "user" }
		end)
	end
	-- Ctrl+click: just this signal turned round
	local function flipOne(m : Mark)
		if m.state ~= "placed" then return end
		takeOver(m, function(a : WorldEdit) a.dx, a.dy = -a.dx, -a.dy end)
	end
	-- right-click: lock a planned signal where it stands (re-planning won't move or remove it), or
	-- unlock a locked one (the plan places it again)
	local function toggleLock(m : Mark)
		if m.state ~= "placed" then return end
		if not m.sp.user then
			takeOver(m, function(a : WorldEdit) a.locked = true end)
		elseif m.sp.locked then
			edit(function(e : WorldEdits)
				local i = addIndex(e, m.sp)
				if i > 0 then e.adds = drop(e.adds, i) end
				local dx, dy = spotDir(m.sp)
				local r = findEdit(e.removes, m.sp.pos.x, m.sp.pos.y, dx, dy, placeApi.REMOVE_TOL + 2)
				if r > 0 then e.removes = drop(e.removes, r) end
			end)
		end
	end
	-- Ctrl+right-click: this signal's own type, the next of the available ones (after the last: by
	-- its kind again)
	local function cycleModel(m : Mark)
		if m.state ~= "placed" then return end
		local list = listSignals()
		local cur = 0
		for i, s in ipairs(list) do if s.name == m.sp.model then cur = i end end
		local nxt = list[cur + 1] and list[cur + 1].name or nil
		takeOver(m, function(a : WorldEdit) a.model = nxt end)
	end

	-- the keys' work (registered above): on the signal under the cursor
	local function hoveredMark() : Mark
		local m = marks[hoverState:old() or 0]
		if m and m.state == "placed" and not opts.removeMode then return m end
		return nil
	end
	keyFnsRef:set({
		enabled = function() : boolean return hoveredMark() ~= nil end as function(),
		lock = function() local m = hoveredMark(); if m then toggleLock(m) end end,
		nextType = function() local m = hoveredMark(); if m then cycleModel(m) end end,
	})
	-- Ctrl+click on a marker: just that signal turned round (a Ctrl+click can reach the recipe as
	-- PressedOutside instead of through the Selector)
	local function ctrlClick(evt : Gui.Mouse.Event) : boolean
		local Type = api.gui.mouse.Event.Type
		if (evt.type ~= Type.Pressed and evt.type ~= Type.PressedOutside) or evt.button ~= 0 then return false end
		if opts.removeMode or not ctrlHeld() then return false end
		local x, y = handles.cursor()
		local i = x and handles.hit(markHandles, x, y) or 0
		if i > 0 and marks[i] then
			flipOne(marks[i])
			return true
		end
		return false
	end
	-- (Pressed comes through the Selector's onProcessMouseEvent below; only PressedOutside here,
	-- or a click would turn the signal twice)
	outsideRef:set(function(evt : Gui.Mouse.Event) : boolean
		if evt.type ~= api.gui.mouse.Event.Type.PressedOutside then return false end
		return ctrlClick(evt)
	end)

	local function flipTrack(key : Engine.Entity)
		local nf : {Engine.Entity : boolean} = {}
		for k, v in pairs(flipsState:old() or {}) do nf[k] = v end
		nf[key] = not nf[key] or nil
		flipsState:set(nf)
		costState:set(0)
		errorState:set("")
	end

	local function clear()
		if aliveRef:hasExpired() then return end
		chainState:set({})
		anchorsRef:set({})
		flipsState:set({})
		editsState:set({ adds = {}, removes = {} })
		draggingState:set(0)
		hoverState:set(0)
		blockHoverState:set("")
		signalInfoState:set("")
		pathNoteState:set("")
		costState:set(0)
		errorState:set("")
	end

	local dragging = draggingState:old() or 0
	local dragCtl : DragCtl = {
		handles = markHandles,
		dragging = dragging,
		setDragging = function(i : integer)
			if i ~= 0 then dragMovedRef:set(false); dragAtRef:set(-1); dragAtState:set(-1) end
			draggingState:set(i)
		end,
		hover = hoverState:old() or 0,
		setHover = function(i : integer) hoverState:set(i) end,
		onDrag = function(i : integer, x : number, y : number)
			local m = marks[i]
			if not m then return end
			local at = placeApi.project(m.view.T, x, y)
			if math.abs(at - m.sp.at) > 2 then dragMovedRef:set(true) end
			dragAtRef:set(at)
			dragAtState:set(at)
		end,
		onRelease = function(i : integer)
			local m = marks[i]
			if not m then return end
			local to = dragAtRef:get() or -1
			if dragMovedRef:get() and to >= 0 then
				moveMark(m, to)
			elseif shiftHeld() then
				flipTrack(m.view.key)
			else
				toggleMark(m)
			end
			dragMovedRef:set(false)
			dragAtRef:set(-1)
			dragAtState:set(-1)
		end,
	}

	local function build()
		if not proposal or blocked or busy then return end
		local context = api.type.Context.new()
		context.player = api.engine.util.getPlayer()
		local cmd = api.cmd.makeWorldBuildProposalCmd(proposal, context, anarchy, true)
		-- where signals go in / come out, for the short icons after the build (the marks are gone by then)
		local done : {{number}} = {}
		local gone : {{number}} = {}
		local nameSpots : {NameSpot} = {}   -- (and what each new one is for, for its name)
		for __, m in ipairs(marks) do
			local p = { m.sp.pos.x, m.sp.pos.y, m.sp.pos.z }
			if m.state == "placed" then
				if opts.removeMode then
					gone[#gone + 1] = p
				else
					done[#done + 1] = p
					nameSpots[#nameSpots + 1] = { x = m.sp.pos.x, y = m.sp.pos.y, kind = m.sp.kind }
				end
			elseif m.state == "removed" then
				gone[#gone + 1] = p
			end
		end
		chainState:set({})
		anchorsRef:set({})
		busyState:set(true)
		-- (the shared send every tool's build goes through)
		((require "network_tools_1::/gui/construction/tools/shared/ntools_options.script.tl" as {string : any}).send as function(Command<WorldBuildProposalCommandData>, function(WorldBuildProposalCommandData, boolean, {{Engine.Entity, Engine.Revision}})))(cmd, function(data : WorldBuildProposalCommandData, success : boolean, resultEntities : {{Engine.Entity, Engine.Revision}})
			if not success then dbg("[network_tools] Auto-signal: build failed") end
			-- (the result comes as the callback's third argument; the data's copy as a fallback)
			local result = resultEntities
			if (not result or #result == 0) and data then pcall(function() result = data.resultEntities end) end
			-- named like the game's own signals (also when the tool was closed meanwhile)
			if success and not opts.removeMode then nameNewSignals(result, nameSpots) end
			-- (Settings: "Show build icons" off - none)
			if success and shared.opts.hudIcons ~= false then
				-- a green tick over each new signal, a red cross where one was taken out (capped so a
				-- long line doesn't flood the screen). The icon
				-- needs a living entity (-1 trips an engine assertion): any of the build's, our
				-- position overrides where it shows.
				local anchor : Engine.Entity = result and result[1] and result[1][1] or nil
				-- (our own coloured icons with transparency: the game's grayscale ones showed a black square)
				local function pop(list : {{number}}, icon : string)
					if not anchor then return end
					for i = 1, math.min(#list, 150) do
						local p = list[i]
						local ok, err = pcall(function()
							api.gui.spawnEphemeralHudImage(icon, anchor, nil,
								api.type.Vec3f.new(p[1], p[2], p[3] + 4), 1.5)
						end)
						if not ok then
							dbg("[network_tools] Auto-signal: build icons: " .. tostring(err))
							return
						end
					end
				end
				-- (HUD images are textures: the mod prefix without the slash ("network_tools_1::gui/...",
				-- "network_tools_1::/gui/..." isn't found) and the @2x file named in full)
				pop(done, "network_tools_1::gui/icons/ntools_hud_added@2x.tga")
				pop(gone, "network_tools_1::gui/icons/ntools_hud_removed@2x.tga")
			end
			if aliveRef:hasExpired() then return end
			busyState:set(false)
			clear()
		end)
	end

	handlersRef:set({
		ntoolsResetShape = clear,
		ntoolsBuild = build,
	})
	padMod.actions(pad, _("Pick segment / grab signal"), function() leave(params) end, _("Leave the tool"))

	local actionFn = function() : TreeNodeId
		padMod.trackLayer(pad)
		local crosshair, circle = padMod.crosshair(pad)
		if busy then
			return builtin.ActionDescriptor{
				parent = selfRef,
				tool = "construction-menu-perks",
				onBack = function() leave(params) end,
				crosshair = crosshair,
				terrainCirclePolicy = circle,
				children = { g_host.tooltip(_("Building..."), true, false) },
			}
		end
		local children : {TreeNodeId} = {
			builtin.Selector(padMod.selector(pad, {
				onSelect = function(entity : Engine.Entity, __ : {integer}, details : Gui.SelectionDetails) : boolean
					-- a signal already there: say what it is (the selection names the signal list, or
					-- the clicked entity is one)
					local okD, sel = pcall(function() : Gui.SelectionDetails.Signal
						local d = details and details.data as Gui.SelectionDetails.Signal
						return (d and d.signalList) and d or nil
					end)
					local sigText = (okD and sel) and describeSignal(sel.signalList, sel.signalIndex)
						or (isSignal(entity) and describeSignal(entity, 0)) or nil
					if sigText then
						signalInfoState:set(sigText)
						return true
					end
					if not g_host.getEdge(entity) then return false end
					signalInfoState:set("")
					-- a click on a marker, or a Shift+click (adds a signal), doesn't change the stretch
					local x, y = handles.cursor()
					if x and handles.hit(markHandles, x, y) > 0 then return true end
					if shiftHeld() and #views > 0 then return true end
					costState:set(0)
					errorState:set("")
					-- (the edits stay: they are world positions, and apply wherever the stretch reaches)
					local newChain = chain_util.click(chain, entity, nil, pathOpts())
					chainState:set(newChain)
					pathNoteState:set(chain_util.lastNote())
					-- remember the click (a new stretch starts the list again; a segment taken off an
					-- end drops out of it)
					local anchors = anchorsRef:get() or {}
					local na : {Engine.Entity} = {}
					if #chain == 0 or chain_util.lastNote() ~= "" then
						na = { entity }
					elseif #newChain > #chain then
						for __, a in ipairs(anchors) do na[#na + 1] = a end
						na[#na + 1] = entity
					else
						local inNew : {Engine.Entity : boolean} = {}
						for __, l in ipairs(newChain) do inNew[l.edge] = true end
						for __, a in ipairs(anchors) do if inNew[a] then na[#na + 1] = a end end
					end
					anchorsRef:set(na)
					return true
				end,
				onProcessMouseEvent = function(evt : Gui.Mouse.Event) : boolean
					local Type = api.gui.mouse.Event.Type
					local x, y = handles.cursor()
					if ctrlClick(evt) then return true end
					-- markers first: drag to move, click to remove / bring back, Shift+click to turn the
					-- track round
					if not opts.removeMode and handles.mouse(evt, dragCtl) then return true end
					if evt.type == Type.Pressed and evt.button == 0 and shiftHeld() and x and not opts.removeMode then
						-- Shift+click on a planned track: a signal of the player's own there
						local v, at = trackAt(x, y)
						if v then
							addSignal(v, at)
							return true
						end
					elseif evt.type == Type.Moved and dragging == 0 then
						-- the block under the cursor (its length and ends go in the tooltip)
						local id = x and blockAt(x, y) or ""
						if id ~= (blockHoverState:old() or "") then blockHoverState:set(id) end
					end
					return false
				end,
				-- (signals too: a click on one says what it is)
				filter = function(e : Engine.Entity) : boolean return g_host.isEdge(e) or isSignal(e) end,
			}) as Builtin.SelectorParam),
		}
		if proposal then
			local id = "ntools_signals," .. key .. ",r" .. tostring(refusedVerState:old() or 0)
			for k, _v in pairs(flipsState:old() or {}) do id = id .. ",f" .. tostring(k) end
			for _, l in ipairs(chain) do id = id .. "," .. tostring(l.edge) end
			for _, l in ipairs(beside or {}) do id = id .. ",b" .. tostring(l.edge) end
			-- (the player's edits change the proposal too)
			for __, a in ipairs(allEdits.adds or {}) do
				id = id .. string.format("+%.1f,%.1f,%.2f,%.2f,%s,%s,%s", a.x, a.y, a.dx, a.dy, tostring(a.kind), tostring(a.model), tostring(a.locked))
			end
			for __, r in ipairs(allEdits.removes or {}) do id = id .. string.format("-%.1f,%.1f", r.x, r.y) end
			children[#children + 1] = preview.viewer{
				proposal = proposal,
				anarchy = anarchy,
				noTags = true,   -- (segments are only re-added to carry the signals: the block lengths are the tags)
				onData = function(proposalData : ProposalData)
					if aliveRef:hasExpired() then return end
					costState:set(proposalData.costs)
					local msg = ""
					for __, m in ipairs(proposalData.errorState.messages) do msg = msg .. m .. " " end
					errorState:set(msg)
					-- refused: find the segments the game won't take a signal on, and plan again without them
					if proposalData.errorState.critical then
						local okP, nNew = pcall(probeRefusal, proposal, id)
						if not okP then
							dbg("[network_tools] signals: checking the refused plan failed: " .. tostring(nNew))
						elseif nNew > 0 then
							refusedVerState:set((refusedVerState:old() or 0) + 1)
						end
					end
				end,
				id = id,
			}
		end

		-- markers: a ring at each signal and a tick pointing the way trains will pass it (lighter: moved
		-- to a segment that can take it; green: placed by the player); a faint ring where the player
		-- removed one; a red ring with a cross where one was wanted but couldn't go. The marker under
		-- the cursor is drawn bolder, a dragged one where it would land.
		local allSpots : {Spot} = {}
		local skippedSpots : {Spot} = {}
		local nRemoved, nUser = 0, 0
		for _, m in ipairs(marks) do
			if m.state == "placed" then
				allSpots[#allSpots + 1] = m.sp
				if m.sp.user then nUser = nUser + 1 end
			elseif m.state == "skipped" then
				skippedSpots[#skippedSpots + 1] = m.sp
			else
				nRemoved = nRemoved + 1
			end
		end
		local hover = hoverState:old() or 0
		local dragAt = dragAtState:old() or -1
		local labels : {Label} = {}
		for _, bl in ipairs(blocks) do
			-- (two-way track: the other way's blocks would sit on top of these)
			if not bl.view.second then
				local p = placeApi.pointAt(bl.view.T, (bl.a + bl.b) / 2)
				labels[#labels + 1] = { x = p.x, y = p.y, z = p.z, text = string.format("%.0f m", bl.b - bl.a) }
			end
		end
		-- what each signal is for, on the ones that aren't plain block signals; red where one was
		-- wanted but can't go (the reason on hover)
		local KIND_TAGS : {string : LabelRow} = {
			split = { icon = signalIcons.switch, text = _("Switch") },
			join = { icon = signalIcons.join, text = _("Join") },
			crossing = { icon = signalIcons.crossing, text = _("Crossing") },
			exit = { icon = signalIcons.exit, text = _("Exit") },
			entry = { icon = signalIcons.entry, text = _("Entry") },
			user = { icon = signalIcons.user, text = _("Yours") },
		}
		for __, m in ipairs(marks) do
			local kt = KIND_TAGS[m.sp.kind]
			-- locked / own type: said on the tag (the type's name on hover)
			if m.state == "placed" and (m.sp.locked or m.sp.model) then
				local base = kt or { icon = signalIcons.signal, text = _("Block") }
				kt = { icon = base.icon, text = base.text .. (m.sp.locked and (" - " .. _("locked")) or "") .. (m.sp.model and " *" or "") }
			end
			if m.state == "skipped" then
				labels[#labels + 1] = {
					x = m.sp.pos.x, y = m.sp.pos.y, z = m.sp.pos.z, level = 2,
					rows = { { icon = signalIcons.warning, text = kt and kt.text or _("Signal") } },
					detail = { { text = m.sp.reason or _("can't be placed") } },
				}
			elseif m.state == "placed" and kt and shared.opts.markerDetail ~= false then
				labels[#labels + 1] = { x = m.sp.pos.x, y = m.sp.pos.y, z = m.sp.pos.z, rows = { kt } }
			end
		end
		if #marks > 0 or #labels > 0 or #chain > 0 then
			local c = handles.canvas()
			-- the selected stretch, drawn along each segment's own curve (first, so the signal markers
			-- sit on top): the stretch bright, the tracks alongside fainter; a dot where it starts
			-- (green) and where it ends (orange). One cubic-spline strip per segment (as the preview's
			-- strips): neighbours share their end point and tangent, so it reads as one smooth line.
			local function drawLink(edge : Engine.Entity, color : Vec4f, width : number)
				local e = g_host.getEdge(edge)
				if not e then return end
				local p0, p1, t0, t1 = e.position0, e.position1, e.tangent0, e.tangent1
				local okS, strip = pcall(function() : Builtin.Type.EdgeRenderable.Edge
					local sp = api.type.EdgeGeometry.CubicSpline.new()
					sp.pos = { api.type.Vec2f.new(p0.x, p0.y), api.type.Vec2f.new(p1.x, p1.y) }
					sp.tangent = { api.type.Vec2f.new(t0.x, t0.y), api.type.Vec2f.new(t1.x, t1.y) }
					local geom = api.type.EdgeGeometry.new()
					geom.type = api.type.EdgeGeometry.Type.CUBIC_SPLINE
					geom.cubicSpline = sp
					geom.height = api.type.Vec2f.new(p0.z, p1.z)
					geom.tangent = api.type.Vec2f.new(t0.z, t1.z)
					geom.width = width
					geom.length = math.sqrt((p1.x - p0.x) ^ 2 + (p1.y - p0.y) ^ 2)
					local re = builtin.type.EdgeRenderable.Edge.new(geom)
					re.colors = { color, color, color }
					re.stepSize = 1
					re.width = width
					re.offsetZ = 0.6
					return re
				end)
				if okS and strip then
					c.edges({ strip })
					return
				end
				-- (the engine refused the spline: short straight pieces instead)
				local function at(t : number) : number, number, number
					local t2, t3 = t * t, t * t * t
					local h00, h10, h01, h11 = 2 * t3 - 3 * t2 + 1, t3 - 2 * t2 + t, -2 * t3 + 3 * t2, t3 - t2
					return h00 * p0.x + h10 * t0.x + h01 * p1.x + h11 * t1.x,
						h00 * p0.y + h10 * t0.y + h01 * p1.y + h11 * t1.y,
						h00 * p0.z + h10 * t0.z + h01 * p1.z + h11 * t1.z
				end
				local len = math.sqrt((p1.x - p0.x) ^ 2 + (p1.y - p0.y) ^ 2)
				local n = math.max(2, math.min(24, math.ceil(len / 8)))
				local px, py, pz = at(0)
				for k = 1, n do
					local x, y, z = at(k / n)
					c.line(px, py, pz + 0.3, x, y, z + 0.3, color, width)
					px, py, pz = x, y, z
				end
			end
			-- (the Settings tab's colour preset, via the handle kit, and line thickness)
			local STRETCH = handles.colors.stretch or handles.colors.handle
			local ls = (shared.opts.lineScale as number) or 1
			-- (widths in metres: a line along the track, not a band over it; the tracks alongside
			-- thinner in the same colour)
			for __, l in ipairs(beside or {}) do drawLink(l.edge, STRETCH, 0.6 * ls) end
			for __, l in ipairs(chain) do drawLink(l.edge, STRETCH, 1.5 * ls) end
			if #chain > 0 then
				local nodesOf = chain_util.nodes(chain)
				local function ring(node : Engine.Entity, color : Vec4f)
					local ok, bn = pcall(function() : Engine.Component.BaseNode
						return api.engine.getComponent(node, api.type.ComponentType.BASE_NODE) as Engine.Component.BaseNode
					end)
					-- a solid dot a little wider than the line: a ring whose thickness is its whole
					-- radius fills in (2.2 m across at the normal thickness)
					if ok and bn and bn.position then
						c.circle(bn.position.x, bn.position.y, bn.position.z + 0.3, 0.55 * ls, color, 1.1 * ls)
					end
				end
				ring(nodesOf[1], handles.colors.start or handles.colors.good)
				ring(nodesOf[#nodesOf], handles.colors.finish or handles.colors.drag)
			end
			for i, m in ipairs(marks) do
				local sp = m.sp
				local x, y, z = sp.pos.x, sp.pos.y, sp.pos.z
				-- a dragged marker: where it would land
				if i == dragging and dragMovedRef:get() and dragAt >= 0 then
					local p = placeApi.pointAt(m.view.T, dragAt)
					x, y, z = p.x, p.y, p.z
				end
				local w = (i == hover or i == dragging) and 2.0 or 1.2
				if m.state == "removed" then
					c.circle(x, y, z, 3, handles.colors.guide, w * 0.7)
					c.line(x - 2, y, z, x + 2, y, z, handles.colors.guide, 0.8)
				elseif m.state == "skipped" then
					c.circle(x, y, z, 3, handles.colors.bad, w)
					c.line(x - 2, y - 2, z, x + 2, y + 2, z, handles.colors.bad, 1.0)
					c.line(x - 2, y + 2, z, x + 2, y - 2, z, handles.colors.bad, 1.0)
				else
					local col = handles.colors.handle
					if i == dragging and dragMovedRef:get() then col = handles.colors.drag
					elseif sp.user then col = handles.colors.good
					elseif (sp.moved or 0) > 0.5 or i == hover then col = handles.colors.hover end
					c.circle(x, y, z, 3, col, w)
					local l = math.sqrt(sp.dir.x * sp.dir.x + sp.dir.y * sp.dir.y)
					if l > 1e-6 then
						local dx, dy = sp.dir.x / l, sp.dir.y / l
						-- from the ring's outer edge (radius 3 + half its width), not across its middle
						-- (Settings: marker detail off - rings only)
						if shared.opts.markerDetail ~= false then
							c.line(x + dx * 3.6, y + dy * 3.6, z, x + dx * 9, y + dy * 9, z, col, w)
						end
					end
				end
			end
			local n = c.node()
			if n then children[#children + 1] = n end
		end
		-- block lengths, halfway between their signals
		setLabels({}, labels)
		local tagsNode = labelsNode()
		if tagsNode then children[#children + 1] = tagsNode end

		-- what's under the cursor: a marker, else a block (first in the tooltip)
		local KIND_NAMES : {string : string} = {
			block = _("Block signal"),
			split = _("Signal before a switch (the track splits)"),
			join = _("Signal past a switch (tracks join)"),
			crossing = _("Signal before a level crossing"),
			exit = _("Station exit signal"),
			entry = _("Station entry signal"),
			user = _("Your signal"),
			existing = _("signal already there"),
		}
		local function kindName(k : string) : string return KIND_NAMES[k] or _("Signal") end
		local focus : string = nil
		local hm = marks[hover]
		if hm and dragging == 0 then
			local sp = hm.sp
			if hm.state == "removed" then
				focus = kindName(sp.kind) .. " - " .. _("removed") .. "\n" .. _("Click to bring it back")
			elseif hm.state == "skipped" then
				focus = kindName(sp.kind) .. " - " .. _("can't be placed") .. ": " .. (sp.reason or _("unknown"))
					.. "\n" .. _("Drag it to a segment that can take a signal, or click to hide it")
			else
				focus = kindName(sp.kind)
				if (sp.moved or 0) > 0.5 then
					focus = focus .. "\n" .. string.format(_("Moved %.0f m to a segment that can take a signal"), sp.moved)
				end
				if sp.locked then focus = focus .. " - " .. _("locked") end
				if sp.model then focus = focus .. "\n" .. _("Type") .. ": " .. modelLabel(sp.model) end
				focus = focus .. "\n" .. (sp.user and _("Drag to move, click to delete") or _("Drag to move, click to remove"))
					.. "\n" .. _("Lock and signal type: the keys in the list at the bottom right")
			end
		else
			local bid = blockHoverState:old() or ""
			-- (not `_` as the loop variable: that would hide the translate function _() inside)
			for __, bl in ipairs(blocks) do
				if bl.id == bid then
					focus = string.format("%s: %.0f m", _("Block"), bl.b - bl.a)
						.. "\n" .. _("From") .. ": " .. kindName(bl.fromKind)
						.. "\n" .. _("To") .. ": " .. kindName(bl.toKind)
						.. "\n" .. _("Shift+click to add a signal here")
				end
			end
		end

		local info = _("Segments") .. ": " .. tostring(#chain)
		if plan then
			local skipped = #skippedSpots
			if opts.removeMode then
				info = info .. "   " .. string.format("%s: %.0f m   %s: %d", _("Length"), plan.length, _("Signals to remove"), nRemove)
			else
				info = info .. "   " .. string.format("%s: %.0f m   %s: %d", _("Length"), plan.length, _("Signals"), #allSpots)
			end
			if beside then
				info = info .. "\n" .. _("Tracks alongside") .. ": " .. tostring(nBesideTracks)
			elseif opts.besideTracks then
				info = info .. "\n" .. _("No track alongside")
			end
			if autoNote and not opts.removeMode then info = info .. "\n" .. autoNote end
			if skipped > 0 and not opts.removeMode then
				-- each reason once, with how many (the red crosses on the track)
				local count : {string : integer} = {}
				local reasons : {string} = {}
				for __, sp in ipairs(skippedSpots) do
					local r = sp.reason or _("unknown")
					if not count[r] then count[r] = 0; reasons[#reasons + 1] = r end
					count[r] = count[r] + 1
				end
				info = info .. "\n" .. _("Not placed (red crosses)") .. ": " .. tostring(skipped)
				for _, r in ipairs(reasons) do
					info = info .. "\n   " .. r .. ": " .. tostring(count[r])
				end
			end
			local moved = 0
			for _, sp in ipairs(allSpots) do if (sp.moved or 0) > 0.5 then moved = moved + 1 end end
			if moved > 0 and not opts.removeMode then
				info = info .. "\n" .. _("Moved to a nearby segment that can take a signal (lighter markers)") .. ": " .. tostring(moved)
			end
			if (nUser > 0 or nRemoved > 0) and not opts.removeMode then
				info = info .. "\n" .. string.format("%s: %d   %s: %d", _("Added by you (green)"), nUser, _("Removed by you (faint)"), nRemoved)
			end
		end
		-- a clicked signal first
		local sigInfo = signalInfoState:old() or ""
		if sigInfo ~= "" then focus = focus and (sigInfo .. "\n\n" .. focus) or sigInfo end
		local pathNote = pathNoteState:old() or ""
		if pathNote ~= "" then focus = focus and (_(pathNote) .. "\n\n" .. focus) or _(pathNote) end
		if focus then info = focus .. "\n\n" .. info end
		if #chain == 0 then
			children[#children + 1] = g_host.tooltip((sigInfo ~= "" and (sigInfo .. "\n\n") or "")
				.. _("Click a track segment to start the stretch"), false, false)
		elseif why then
			children[#children + 1] = g_host.tooltip(why .. "\n" .. info, false, true)
		elseif not proposal and opts.removeMode then
			children[#children + 1] = g_host.tooltip(_("No signals on this stretch") .. "\n" .. info, false, false)
		elseif not proposal then
			children[#children + 1] = g_host.tooltip(_("No room for a signal on this stretch - make it longer or the spacing shorter") .. "\n" .. info, false, false)
		elseif blocked then
			children[#children + 1] = g_host.tooltip(errorState:old() .. "\n" .. info, false, true, costState:old())
		elseif opts.removeMode then
			children[#children + 1] = g_host.tooltip(_("Click more segments to extend, the first / last to remove. Press Build to remove the signals") .. "\n" .. info, true, false, costState:old())
		else
			children[#children + 1] = g_host.tooltip(_("Click more segments to extend, the first / last to remove. Press Build to place the signals") .. "\n" .. info,
				true, false, costState:old(),
				_("Drag a signal: move it") .. "\n"
				.. _("Click a signal: remove it") .. "\n"
				.. _("Shift+click the track: add a signal") .. "\n"
				.. _("Shift+click a signal: turn its track round") .. "\n"
				.. _("Ctrl+click a signal: turn just that one") .. "\n"
				.. _("Point at a signal and press the keys at the bottom right to lock it or change its type"))
		end

		local highlighted : {Engine.Entity} = {}
		for _, l in ipairs(chain) do highlighted[#highlighted + 1] = l.edge end
		for _, l in ipairs(beside or {}) do highlighted[#highlighted + 1] = l.edge end
		-- Anarchy preview strips no overlay drew this frame
		local lo = preview.leftover()
		if lo then children[#children + 1] = lo end
		-- underground view (panel option, all tools): the engine then draws tunnel tracks and the
		-- Selector can pick them
		local under = shared.layerNode()
		if under then children[#children + 1] = under end
		return builtin.ActionDescriptor{
			parent = selfRef,
			tool = "construction-menu-perks",
			onBack = function() leave(params) end,
			highlightedEntities = highlighted,
			crosshair = crosshair,
			terrainCirclePolicy = circle,
			children = children,
		}
	end

	params.setActionFn(actionFn, "NtoolsSignalsAction")
	return padMod.anchor(pad)
end)

return {
	init = init,
	opts = opts,
	listSignals = listSignals,
	SignalsActionRecipe = SignalsActionRecipe,
}
