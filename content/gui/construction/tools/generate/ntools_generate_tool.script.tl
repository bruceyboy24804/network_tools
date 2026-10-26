-- Network Tools: Generate (modelled on the generators of Network Tools for Cities: Skylines 2).
-- Build a ring road / round track, an oval, or a street grid from scratch: click the ground to place
-- it, then drag its handles - centre (move), size (radius / grid size), a second size for the oval,
-- and rotation. Road type = the panel's Network pick (else the first available road). Nodes sit on
-- the terrain; every segment's climb is spread evenly along it. Only new segments: nothing existing
-- is removed, so the game's own checks (collisions, cost) decide what can be built.

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

local record P3
	x : number
	y : number
	z : number
end

local record Handle
	x : number
	y : number
	z : number
end
local record Canvas
	line : function(x0 : number, y0 : number, z0 : number, x1 : number, y1 : number, z1 : number, color : Vec4f, width : number)
	circle : function(cx : number, cy : number, z : number, r : number, color : Vec4f, width : number)
	handle : function(h : Handle, state : integer)
	node : function() : TreeNodeId
end
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
	hit : function(handles : {Handle}, x : number, y : number) : integer
	mouse : function(evt : Gui.Mouse.Event, ctl : DragCtl) : boolean
	cursor : function() : number, number
	colors : {string : Vec4f}
end
local handles = require "network_tools_1::/gui/construction/tools/shared/ntools_handles.script.tl" as Handles

-- the build preview: the game's ProposalViewer, or our own green one in Anarchy (no red)
local record PreviewParams
	proposal : SimpleProposal
	id : string
	onData : function(ProposalData)
	anarchy : boolean
end
local record Preview
	viewer : function(p : PreviewParams) : TreeNodeId
	leftover : function() : TreeNodeId
	tags : function() : TreeNodeId
	clear : function()
end
local preview = require "network_tools_1::/gui/construction/tools/shared/ntools_preview.script.tl" as Preview
-- the tinted footprint under the shape
local record Zone
	show : function(key : string, nodes : {any}, margin : number, r : number, g : number, b : number, a : number)
	clear : function(key : string)
end
local zone = require "network_tools_1::/gui/construction/tools/shared/ntools_zone.script.tl" as Zone
local ZONE_KEY = "ntools_generate_footprint"

-- water and bridges (shared with the other tools)
local record TPart
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
	heights : function(parts : {TPart}, zA : number, zB : number, follow : boolean, maxGrade : number) : {TPart}, {number}
	nodeZ : function(x : number, y : number) : number
	pickTypes : function(isTrack : boolean) : integer, integer
	upgradeSegment : function(seg : Proposal.SegmentAndEntity, isTrack : boolean, bridgeId? : integer, tunnelId? : integer) : string
end
local terrain = require "network_tools_1::/gui/construction/tools/shared/ntools_terrain.script.tl" as Terrain

-- options shared by all tools: height offset, new-road properties
local record SharedOptions
	opts : {string : any}
	applyRoad : function(seg : Proposal.SegmentAndEntity)
	key : function() : string
end
local shared = require "network_tools_1::/gui/construction/tools/shared/ntools_options.script.tl" as SharedOptions

do ((require "network_tools_1::/gui/construction/tools/shared/ntools_debug.script.tl" as {string : any}).log as function(string))("[network_tools] generate tool script loaded (v2: water / bridges)") end

local SHAPE_CIRCLE, SHAPE_OVAL, SHAPE_GRID, SHAPE_HELIX = 1, 2, 3, 4
local TARGET_SEG = 40        -- metres per segment on circles / ovals
local HELIX_CLEARANCE = 7    -- metres between turns: closer than this, a turn hits the one below

-- options shared with the panel and the toolbar
local record Options
	shape : integer
	radius : number          -- circle radius / oval X radius / helix radius
	radiusY : number         -- oval Y radius
	cols : integer           -- grid blocks across
	rows : integer           -- grid blocks down
	spacing : number         -- grid block size
	rotation : number        -- degrees (helix: where it starts)
	turns : number           -- helix: number of turns
	grade : number           -- helix: climb in % (negative = it descends: a spiral tunnel)
	clockwise : boolean      -- helix: turning right (seen from above) instead of left
end
local opts : Options = { shape = SHAPE_CIRCLE, radius = 60, radiusY = 35, cols = 3, rows = 2, spacing = 60, rotation = 0,
	turns = 2, grade = 2.5, clockwise = false }

local record UiState
	canBuild : boolean
end
local record Host
	tooltip : function(message : string, good : boolean, bad : boolean, cost? : integer) : TreeNodeId
	anarchy : function() : boolean
	ui : UiState
	toolbarEvents : {string}
	-- the street template to build with: id (nil = none available)
	networkTemplate : function() : integer
end
local g_host : Host = nil
local function init(host : any) g_host = host as Host end

local function vec3(x : number, y : number, z : number) : Vec3f
	return api.type.Vec3f.new(x, y, z)
end

local function ground(x : number, y : number) : number
	local ok, h = pcall(function() : number
		return api.engine.terrain.getHeightAt(api.type.Vec2f.new(x, y))
	end)
	return ok and h or 0
end

local record Seg
	a : integer              -- node indices
	b : integer
	ta : P3                  -- plan tangents (z added later)
	tb : P3
end
local record Layout
	nodes : {P3}
	segs : {Seg}
	fixedZ : boolean         -- the heights are the shape's own (helix), not the terrain's
	info : string
end

-- rotate (x, y) by the options' rotation, then move to the centre
local function place(cx : number, cy : number, x : number, y : number) : number, number
	local a = math.rad(opts.rotation)
	return cx + x * math.cos(a) - y * math.sin(a), cy + x * math.sin(a) + y * math.cos(a)
end
local function turn(x : number, y : number) : number, number
	local a = math.rad(opts.rotation)
	return x * math.cos(a) - y * math.sin(a), x * math.sin(a) + y * math.cos(a)
end

local function layout(cx : number, cy : number) : Layout
	local nodes : {P3} = {}
	local segs : {Seg} = {}
	if opts.shape == SHAPE_GRID then
		local nx, ny, sp = opts.cols, opts.rows, opts.spacing
		local function idx(i : integer, j : integer) : integer return j * (nx + 1) + i + 1 end
		for j = 0, ny do
			for i = 0, nx do
				local x, y = place(cx, cy, (i - nx / 2) * sp, (j - ny / 2) * sp)
				nodes[idx(i, j)] = { x = x, y = y, z = 0 }
			end
		end
		local ux, uy = turn(sp, 0)
		local vx, vy = turn(0, sp)
		for j = 0, ny do
			for i = 0, nx do
				if i < nx then segs[#segs + 1] = { a = idx(i, j), b = idx(i + 1, j), ta = { x = ux, y = uy, z = 0 }, tb = { x = ux, y = uy, z = 0 } } end
				if j < ny then segs[#segs + 1] = { a = idx(i, j), b = idx(i, j + 1), ta = { x = vx, y = vy, z = 0 }, tb = { x = vx, y = vy, z = 0 } } end
			end
		end
	elseif opts.shape ~= SHAPE_HELIX then
		local rx = opts.radius
		local ry = opts.shape == SHAPE_OVAL and opts.radiusY or opts.radius
		-- ellipse perimeter (Ramanujan) -> segment count
		local per = math.pi * (3 * (rx + ry) - math.sqrt((3 * rx + ry) * (rx + 3 * ry)))
		local n = math.floor(math.max(6, math.min(64, math.ceil(per / TARGET_SEG))))
		local dt = 2 * math.pi / n
		-- a circle's arcs are exact with tangent 4 tan(dt / 4) r; the ellipse uses its derivative x the
		-- same factor (close for gentle ovals)
		local k = 4 * math.tan(dt / 4)
		for i = 0, n - 1 do
			local t = i * dt
			local x, y = place(cx, cy, rx * math.cos(t), ry * math.sin(t))
			nodes[i + 1] = { x = x, y = y, z = 0 }
		end
		for i = 0, n - 1 do
			local t0, t1 = i * dt, (i + 1) * dt
			local ax, ay = turn(-rx * math.sin(t0) * k, ry * math.cos(t0) * k)
			local bx, by = turn(-rx * math.sin(t1) * k, ry * math.cos(t1) * k)
			segs[#segs + 1] = { a = i + 1, b = (i + 1) % n + 1, ta = { x = ax, y = ay, z = 0 }, tb = { x = bx, y = by, z = 0 } }
		end
	end
	local lift = (shared.opts.heightOffset as number) or 0
	if opts.shape == SHAPE_HELIX then
		-- a spiral round the centre, starting at the rotation angle on the terrain (plus the height
		-- offset) and climbing (or falling) evenly by the grade along its length
		local r = opts.radius
		local perTurn = math.floor(math.max(8, math.min(64, math.ceil(2 * math.pi * r / TARGET_SEG))))
		local n = math.max(1, math.floor(opts.turns * perTurn + 0.5))
		local dir = opts.clockwise and -1 or 1
		local dt = 2 * math.pi / perTurn * dir
		local k = 4 * math.tan(math.abs(dt) / 4) * r       -- exact arc tangent length
		local a0 = math.rad(opts.rotation)
		local x0, y0 = cx + r * math.cos(a0), cy + r * math.sin(a0)
		local ok, zg = pcall(terrain.nodeZ, x0, y0)
		local z0 = ((ok and zg) or ground(x0, y0)) + lift
		local dz = opts.grade / 100 * r * math.abs(dt)      -- climb per segment (arc length x grade)
		for i = 0, n do
			local t = a0 + i * dt
			nodes[i + 1] = { x = cx + r * math.cos(t), y = cy + r * math.sin(t), z = z0 + i * dz }
		end
		for i = 0, n - 1 do
			local t0, t1 = a0 + i * dt, a0 + (i + 1) * dt
			segs[#segs + 1] = { a = i + 1, b = i + 2,
				ta = { x = -math.sin(t0) * k * dir, y = math.cos(t0) * k * dir, z = 0 },
				tb = { x = -math.sin(t1) * k * dir, y = math.cos(t1) * k * dir, z = 0 } }
		end
		local perTurnRise = math.abs(opts.grade) / 100 * 2 * math.pi * r
		local info = string.format("%s: %+.1f m   %s: %.1f m", _("Total climb"), n * dz, _("Between turns"), perTurnRise)
		if opts.turns > 1 and perTurnRise < HELIX_CLEARANCE then
			info = info .. "\n" .. _("Turns too close above each other - raise the radius or the grade")
		end
		return { nodes = nodes, segs = segs, fixedZ = true, info = info }
	end
	-- on the terrain (plus the panel's height offset); over water, above the surface
	for _, p in ipairs(nodes) do
		local ok, z = pcall(terrain.nodeZ, p.x, p.y)
		p.z = ((ok and z) or ground(p.x, p.y)) + lift
	end
	return { nodes = nodes, segs = segs }
end

local function makeGenerateProposal(lay : Layout) : SimpleProposal, string
	local id = g_host.networkTemplate()
	if not id then return nil, _("Pick a road or track type (Road / track type option, or the panel's Network list)") end
	local ok, t = pcall(function() : StreetTemplate return api.res.streetTemplateRep.get(id) end)
	if not ok or not t then return nil, _("Pick a road or track type (Road / track type option, or the panel's Network list)") end
	local names = api.res.streetTemplateRep.getAll()
	local isTrack = t.roadType == api.type["enum"].RoadType.TRACK
	-- each layout segment as one or more pieces: over water it is lifted above the surface and
	-- gets extra nodes (shared terrain profile, an even slope otherwise)
	local record GPiece
		a : integer          -- node index (layout nodes first, then the extra ones)
		b : integer
		part : TPart
		za : number
		zb : number
	end
	local allNodes : {P3} = {}
	for i, p in ipairs(lay.nodes) do allNodes[i] = p end
	local pieces : {GPiece} = {}
	local maxGrade = isTrack and 0.03 or 0.06
	for _, s in ipairs(lay.segs) do
		local a, b = lay.nodes[s.a], lay.nodes[s.b]
		local chord = math.sqrt((b.x - a.x) ^ 2 + (b.y - a.y) ^ 2)
		local tl = (math.sqrt(s.ta.x ^ 2 + s.ta.y ^ 2) + math.sqrt(s.tb.x ^ 2 + s.tb.y ^ 2)) / 2
		local part : TPart = { x0 = a.x, y0 = a.y, tx0 = s.ta.x, ty0 = s.ta.y, x1 = b.x, y1 = b.y, tx1 = s.tb.x, ty1 = s.tb.y,
			len = (chord + tl) / 2 }
		local parts : {TPart} = { part }
		local zs : {number} = { a.z, b.z }
		-- (a helix keeps its own even climb: the terrain decides only bridge / tunnel below)
		if not lay.fixedZ then
			local ok, rp, rz = pcall(terrain.heights, parts, a.z, b.z, false, maxGrade)
			if ok and rp and rz then parts, zs = rp, rz end
		end
		local prev = s.a
		for j, p in ipairs(parts) do
			local cur = s.b
			if j < #parts then
				allNodes[#allNodes + 1] = { x = p.x1, y = p.y1, z = zs[j + 1] }
				cur = #allNodes
			end
			pieces[#pieces + 1] = { a = prev, b = cur, part = p, za = zs[j], zb = zs[j + 1] }
			prev = cur
		end
	end
	local E = #pieces
	local nodes : {Proposal.NodeAndEntity} = {}
	for i, p in ipairs(allNodes) do
		local node = api.type.NodeAndEntity.new()
		node.entity = -(E + i)
		node.comp.position = vec3(p.x, p.y, p.z)
		nodes[#nodes + 1] = node
	end
	local bridgeId, tunnelId : integer, integer = nil, nil
	pcall(function() bridgeId, tunnelId = terrain.pickTypes(isTrack) end)
	local edges : {Proposal.SegmentAndEntity} = {}
	for i, pc in ipairs(pieces) do
		local p = pc.part
		local h = math.sqrt((p.x1 - p.x0) ^ 2 + (p.y1 - p.y0) ^ 2)
		local grade = h > 0.01 and (pc.zb - pc.za) / h or 0
		local la = math.sqrt(p.tx0 ^ 2 + p.ty0 ^ 2)
		local lb = math.sqrt(p.tx1 ^ 2 + p.ty1 ^ 2)
		local seg = api.type.SegmentAndEntity.new()
		seg.entity = -i
		seg.comp.node0, seg.comp.node1 = -(E + pc.a), -(E + pc.b)
		seg.comp.position0, seg.comp.position1 = vec3(p.x0, p.y0, pc.za), vec3(p.x1, p.y1, pc.zb)
		seg.comp.tangent0 = vec3(p.tx0, p.ty0, grade * la)
		seg.comp.tangent1 = vec3(p.tx1, p.ty1, grade * lb)
		seg.comp.type = api.type["enum"].BaseEdgeType.NORMAL
		seg.comp.typeIndex = -1
		seg.comp.laneConfigs = t.laneConfigs
		seg.comp.roadTemplate = names[id]
		seg.comp.roadStyle = t.streetStyle
		seg.comp.roadType = t.roadType
		seg.type = isTrack and 1 or 0
		-- over water / high above the ground: a bridge (deep below it: a tunnel)
		terrain.upgradeSegment(seg, isTrack, bridgeId, tunnelId)
		if isTrack then
			pcall(function()
				if t.trackDistance and t.trackDistance > 0 then seg.comp.distance = t.trackDistance end
			end)
		end
		-- the panel's new-road properties (catenary, bus lane, tram, lock, owner, decorations)
		shared.applyRoad(seg)
		edges[#edges + 1] = seg
	end
	local proposal = api.type.SimpleProposal.new()
	proposal.streetProposal.nodesToAdd = nodes
	proposal.streetProposal.edgesToAdd = edges
	return proposal, nil
end

local GenerateActionRecipe = react.RegisterRecipe("NtoolsGenerateAction", function(params : ConstructionCustomActionParams<any>) : TreeNodeId
	-- its speed / incline tags and its footprint leave with the tool
	react.onUnmount(function() preview.clear(); zone.clear(ZONE_KEY) end)
	local centreState : ReactStateT<{number}> = react.useState(nil)
	local costState : ReactStateT<integer> = react.useState(0)
	local errorState : ReactStateT<string> = react.useState("")
	local aliveRef : ReactRefT<boolean> = react.useRef(true)
	local busyState : ReactStateT<boolean> = react.useState(false)
	local draggingState : ReactStateT<integer> = react.useState(0)
	local hoverState : ReactStateT<integer> = react.useState(0)
	local keyUi = engine_react_util.useStepState(function() : string
		return string.format("%d/%.1f/%.1f/%d/%d/%.1f/%.1f/%s/%.2f/%.1f/%s", opts.shape, opts.radius, opts.radiusY,
			opts.cols, opts.rows, opts.spacing, opts.rotation, tostring(g_host.networkTemplate()),
			opts.turns, opts.grade, tostring(opts.clockwise)) .. "/" .. shared.key()   -- + the panel's new-road options
	end)
	local anarchyUi = engine_react_util.useStepState(function() : boolean return g_host.anarchy() end)

	local handlersRef : ReactRefT<{string : function()}> = react.useRef({})
	for _, name in ipairs(g_host.toolbarEvents) do
		react.onEvent(name, function()
			local h = handlersRef:get()[name]
			if h then h() end
		end)
	end

	react.setForceFocusable(true)
	react.setRestrictMouseFocus(true)
	local pad = padMod.use()

	-- (on a pad isActive flickers off on the confirm press: the tool stays while its layer is up)
	if not params.isActive and not padMod.isLive(pad) then
		zone.clear(ZONE_KEY)
		return
	end

	local busy = busyState:old() == true
	local centre = centreState:old()
	local key = keyUi:old() or ""
	local anarchy = anarchyUi:old() == true

	local lay : Layout = nil
	local proposal : SimpleProposal = nil
	local why : string = nil
	if centre and not busy then
		lay = layout(centre[1], centre[2])
		proposal, why = makeGenerateProposal(lay)
	end
	-- the ground it takes, tinted (pushed out by about a road's width)
	-- (Settings: "Show footprint" off - none)
	if lay and shared.opts.footprints ~= false then zone.show(ZONE_KEY, lay.nodes, 12, 0.3, 0.6, 1.0, 0.25) else zone.clear(ZONE_KEY) end
	local blocked = errorState:old() ~= "" and not anarchy
	g_host.ui.canBuild = proposal ~= nil and not blocked

	local function clear()
		if aliveRef:hasExpired() then return end
		centreState:set(nil)
		costState:set(0)
		errorState:set("")
	end

	local function build()
		if not proposal or blocked or busy then return end
		local context = api.type.Context.new()
		context.player = api.engine.util.getPlayer()
		local cmd = api.cmd.makeWorldBuildProposalCmd(proposal, context, anarchy, true)
		busyState:set(true)
		-- (the shared send every tool's build goes through)
		-- (new roads: Player owned applies)
		((require "network_tools_1::/gui/construction/tools/shared/ntools_options.script.tl" as {string : any}).send as function(Command<WorldBuildProposalCommandData>, function(WorldBuildProposalCommandData, boolean), boolean))(cmd, function(__ : WorldBuildProposalCommandData, success : boolean)
			if not success then ((require "network_tools_1::/gui/construction/tools/shared/ntools_debug.script.tl" as {string : any}).log as function(string))("[network_tools] Generate: build failed") end
			if aliveRef:hasExpired() then return end
			busyState:set(false)
			if success then clear() end
		end, true)
	end

	handlersRef:set({
		ntoolsResetShape = clear,
		ntoolsBuild = build,
	})

	-- handles: 1 centre, 2 size (radius / X radius / grid corner), 3 rotation, 4 oval Y radius
	local hs : {Handle} = {}
	local kinds : {string} = {}
	if centre then
		local cx, cy = centre[1], centre[2]
		hs[1], kinds[1] = { x = cx, y = cy }, "centre"
		if opts.shape == SHAPE_GRID then
			local x, y = place(cx, cy, opts.cols * opts.spacing / 2, opts.rows * opts.spacing / 2)
			hs[2], kinds[2] = { x = x, y = y }, "size"
		else
			local x, y = place(cx, cy, opts.radius, 0)
			hs[2], kinds[2] = { x = x, y = y }, "size"
		end
		local rx, ry = place(cx, cy, 0, -(opts.shape == SHAPE_GRID and opts.rows * opts.spacing / 2
			or (opts.shape == SHAPE_OVAL and opts.radiusY or opts.radius)) - 15)
		hs[3], kinds[3] = { x = rx, y = ry }, "rotate"
		if opts.shape == SHAPE_OVAL then
			local x, y = place(cx, cy, 0, opts.radiusY)
			hs[4], kinds[4] = { x = x, y = y }, "sizeY"
		end
	end
	local dragging = draggingState:old() or 0
	local hover = hoverState:old() or 0
	local dragCtl : DragCtl = {
		handles = hs,
		dragging = dragging,
		setDragging = function(i : integer) draggingState:set(i) end,
		hover = hover,
		setHover = function(i : integer) hoverState:set(i) end,
		onDrag = function(i : integer, x : number, y : number)
			if not centre then return end
			local cx, cy = centre[1], centre[2]
			-- the mouse in the shape's own (unrotated) frame
			local a = math.rad(opts.rotation)
			local dx, dy = x - cx, y - cy
			local lx, ly = dx * math.cos(a) + dy * math.sin(a), -dx * math.sin(a) + dy * math.cos(a)
			local kind = kinds[i]
			if kind == "centre" then
				centreState:set({ x, y })
			elseif kind == "size" then
				if opts.shape == SHAPE_GRID then
					local s = math.max(math.abs(lx) * 2 / opts.cols, math.abs(ly) * 2 / opts.rows)
					opts.spacing = math.max(20, math.min(300, math.floor(s / 5 + 0.5) * 5))
				else
					opts.radius = math.max(15, math.min(1000, math.floor(math.abs(lx) / 5 + 0.5) * 5))
				end
			elseif kind == "sizeY" then
				opts.radiusY = math.max(10, math.min(1000, math.floor(math.abs(ly) / 5 + 0.5) * 5))
			elseif kind == "rotate" then
				-- the rotate handle sits below the shape (-y); point it at the mouse
				local deg = math.deg(math.atan2(dy, dx)) + 90
				opts.rotation = (math.floor(deg / 5 + 0.5) * 5) % 360
			end
		end,
	}

	padMod.actions(pad, _("Place / grab handle"), function() params.abort() end, _("Leave the tool"))

	local actionFn = function() : TreeNodeId
		padMod.trackLayer(pad)
		local crosshair, circle = padMod.crosshair(pad)
		if busy then
			return builtin.ActionDescriptor{
				tool = "construction-menu-perks",
				onBack = function() params.abort() end,
				crosshair = crosshair,
				terrainCirclePolicy = circle,
				children = { g_host.tooltip(_("Building..."), true, false) },
			}
		end
		local children : {TreeNodeId} = {
			builtin.Selector(padMod.selector(pad, {
				onSelect = function(_entity : Engine.Entity, __ : {integer}, __ : Gui.SelectionDetails) : boolean
					return true    -- placing is done on the ground (below), not by picking objects
				end,
				onProcessMouseEvent = function(evt : Gui.Mouse.Event) : boolean
					if handles.mouse(evt, dragCtl) then return true end
					-- a click on the ground (not on a handle) places / moves the shape
					if evt.type == api.gui.mouse.Event.Type.Pressed and evt.button == 0 then
						local x, y = handles.cursor()
						if x then
							centreState:set({ x, y })
							costState:set(0)
							errorState:set("")
							return true
						end
					end
					return false
				end,
			}) as Builtin.SelectorParam),
		}
		if proposal then
			children[#children + 1] = preview.viewer{
				proposal = proposal,
				anarchy = anarchy,
				onData = function(proposalData : ProposalData)
					if aliveRef:hasExpired() then return end
					costState:set(proposalData.costs)
					local msg = ""
					for __, m in ipairs(proposalData.errorState.messages) do msg = msg .. m .. " " end
					errorState:set(msg)
				end,
				id = "ntools_generate," .. key .. "," .. string.format("%.1f,%.1f", centre[1], centre[2]),
			}
		end

		local info = ""
		if lay then
			info = _("Segments") .. ": " .. tostring(#lay.segs) .. "   " .. _("Nodes") .. ": " .. tostring(#lay.nodes)
			if lay.info then info = info .. "\n" .. lay.info end
		end
		if not centre then
			children[#children + 1] = g_host.tooltip(_("Click the ground to place it"), false, false)
		elseif why then
			children[#children + 1] = g_host.tooltip(why, false, true)
		elseif blocked then
			children[#children + 1] = g_host.tooltip(errorState:old() .. "\n" .. info, false, true, costState:old())
		else
			children[#children + 1] = g_host.tooltip(_("Drag the handles to move, resize or turn it. Click elsewhere to move it. Press Build to build") .. "\n" .. info, true, false, costState:old())
		end

		if #hs > 0 then
			local c = handles.canvas()
			c.line(hs[1].x, hs[1].y, nil, hs[2].x, hs[2].y, nil, handles.colors.guide, 0.6)
			c.line(hs[1].x, hs[1].y, nil, hs[3].x, hs[3].y, nil, handles.colors.guide, 0.6)
			if hs[4] then c.line(hs[1].x, hs[1].y, nil, hs[4].x, hs[4].y, nil, handles.colors.guide, 0.6) end
			for i, h in ipairs(hs) do c.handle(h, dragging == i and 2 or (hover == i and 1 or 0)) end
			local n = c.node()
			if n then children[#children + 1] = n end
		end
		-- Anarchy preview strips no overlay drew this frame
		local lo = preview.leftover()
		if lo then children[#children + 1] = lo end
		-- speed / gradient tags on the new segments
		local tags = preview.tags()
		if tags then children[#children + 1] = tags end

		-- underground view (panel option, all tools)
		local under = ((require "network_tools_1::/gui/construction/tools/shared/ntools_options.script.tl" as {string : any}).layerNode as function() : TreeNodeId)()
		if under then children[#children + 1] = under end
		return builtin.ActionDescriptor{
			tool = "construction-menu-perks",
			onBack = function() params.abort() end,
			crosshair = crosshair,
			terrainCirclePolicy = circle,
			children = children,
		}
	end

	params.setActionFn(actionFn, "NtoolsGenerateAction")
	return padMod.anchor(pad)
end)

return {
	init = init,
	opts = opts,
	GenerateActionRecipe = GenerateActionRecipe,
}
