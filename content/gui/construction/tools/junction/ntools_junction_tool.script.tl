-- Network Tools: Junction builder (Rail tab). Click a track where the branch leaves it: a switch is
-- put there and a branch curves away to a handle - drag the handle to shape it (any side, ahead or
-- behind; the radius shows as you drag). Build leaves the branch's far end free, to carry on from
-- with the game's own track tool or Connect.
--
-- The branch is a circular arc leaving the track along its direction (shared/ntools_trackbuild),
-- with the clicked track's type. The segment it leaves must carry no signals. Also:
--   * Turnout speed: the curve at the radius the track type allows that speed on (its own
--     speedCoeffs), then a straight on to the handle; the tooltip shows the curve's speed always
--   * the handle dropped on a track (a node, or a point on a segment): the branch joins it there -
--     a route of straights and arcs (the Dubins path finder, Connect's Min. radius) arriving along
--     that track, its heights a smooth curve between the two tracks' grades
--   * the verdict asked again with the build's Context (cleanupStreetGraph, as the game's builders)
--   * Double slip: after a build, each crossing the parallel branches made becomes a double-slip
--     switch (the game's createDoubleSlipSwitchProposal, as the node window does)

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
	edgePiece : function(e : Engine.Component.BaseEdge) : Piece
	closestT : function(pc : Piece, x : number, y : number) : number, number
	point : function(pc : Piece, t : number) : P3
	tangent : function(pc : Piece, t : number) : P3
	length : function(pc : Piece) : number
end
local geom = require "network_tools_1::/gui/construction/tools/shared/ntools_geom.script.tl" as Geom

local record Cut
	node : Engine.Entity
	pos : P3
	dir : P3
end
local record Builder
	splitAt : function(edge : Engine.Entity, ts : {number}) : {Cut}
	node : function(pos : P3) : Engine.Entity
	segment : function(n0 : Engine.Entity, p0 : P3, t0 : P3, n1 : Engine.Entity, p1 : P3, t1 : P3, ref : Engine.Component.BaseEdge, keep? : boolean) : Engine.Entity
	proposal : function() : SimpleProposal
	why : string
	onNewSegment : function(seg : Proposal.SegmentAndEntity)
	touch : function(node : Engine.Entity)
	protectSwitch : function(seg : Engine.Entity, switchAtStart : boolean, dist : number, model : string)
end
local record TrackBuild
	new : function() : Builder
	unit : function(v : P3) : P3
	diagnose : function(key : string) : string   -- the refused piece of the previewed proposal
end
local trackbuild = require "network_tools_1::/gui/construction/tools/shared/ntools_trackbuild.script.tl" as TrackBuild

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

local dbg = (require "network_tools_1::/gui/construction/tools/shared/ntools_debug.script.tl" as {string : any}).log as function(string)
local shared = require "network_tools_1::/gui/construction/tools/shared/ntools_options.script.tl" as {string : any}
local record Terrain
	ground : function(x : number, y : number) : number
	upgradeSegment : function(seg : Proposal.SegmentAndEntity, isTrack : boolean, bridgeId? : integer, tunnelId? : integer, noShore? : boolean) : string
end
local terrain = require "network_tools_1::/gui/construction/tools/shared/ntools_terrain.script.tl" as Terrain
-- the Height & placement options (shared with Connect): the branch's free end
local function sharedOpts() : {string : any}
	return (shared.opts as {string : any}) or {}
end

dbg("[network_tools] junction tool script loaded (v1)")

local record UiState
	canBuild : boolean
end
local record Host
	getEdge : function(Engine.Entity) : Engine.Component.BaseEdge
	isEdge : function(Engine.Entity) : boolean
	tooltip : function(message : string, good : boolean, bad : boolean, cost? : integer) : TreeNodeId
	anarchy : function() : boolean
	ui : UiState
	toolbarEvents : {string}
end
local g_host : Host = nil
local function init(host : any) g_host = host as Host end

-- options (the panel; saved with the game): the radius under which the tooltip warns (m), and
-- whether a click puts the handle to the right (1) or left (2) to start with
local record Options
	minRadius : number
	side : integer
	mode : integer   -- (the panel's Branch type: 1 this tool, 2 Siding, 3 Passing loop)
	siding : integer -- (the panel: the Siding type's last End, 2 dead end / 3 rejoin)
	speed : number   -- turnout speed, km/h: the branch curves at the radius for it (the track type's
	                 -- own speed formula), then runs straight to the handle; 0 = free (the handle shapes it)
	doubleSlip : boolean -- after a build, crossings the branches made become double-slip switches
	signals : boolean    -- a signal on each branch short of its switch (and of the target's), for
	                     -- trains heading into it
	signalModel : string
	sigDist : number     -- how far short of the switch (m)
	fanStation : boolean -- the handle dropped on a station's track end: a branch to each of its tracks
	                     -- at that end (nil = on)
end
local opts : Options = { minRadius = 300, side = 1, mode = 1, siding = 2, speed = 0, doubleSlip = false,
	signals = false, signalModel = nil, sigDist = 10, fanStation = true }
-- the signal model when Signals is on (nil: none)
local function sigModel() : string return opts.signals and opts.signalModel or nil end

-- Where the branch ends when its handle is dropped on a track: an existing node, or a point on a
-- segment (split there). The branch arrives along the track there (a switch), its route found by
-- the Dubins path finder (Connect's Min. radius)
local record Target
	node : Engine.Entity
	edge : Engine.Entity
	t : number
	pos : P3
end

local record Pick
	edge : Engine.Entity
	t : number
	ex : number    -- the handle (the branch's far end)
	ey : number
	extras : {Engine.Entity}   -- tracks beside it that branch too, parallel (a double-track junction)
	target : Target
end

local function dist2d(a : P3, b : P3) : number return math.sqrt((a.x - b.x) ^ 2 + (a.y - b.y) ^ 2) end

-- The track type's limits: speed = a * (radius + b) ^ c m/s (its speedCoeffs), the tightest curve
-- the player may build
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
-- km/h on a curve of radius r (nil: unknown)
local function speedAt(lim : TrackLimits, r : number) : number
	if not lim or not r or r == math.huge then return nil end
	return lim.a * (r + lim.b) ^ lim.c * 3.6
end
-- the radius for a turnout speed (km/h) - at least the type's tightest
local function radiusFor(lim : TrackLimits, kmh : number) : number
	if not lim then return nil end
	local r = (kmh / 3.6 / lim.a) ^ (1 / lim.c) - lim.b
	return math.max(r, lim.minR or 0, 20)
end

-- The branch from the pick to its handle: the switch point, its direction along the track (towards
-- the handle), the far end and its direction, the arc's radius and length. nil and why if it can't.
local record Arc
	p : P3
	d : P3
	e : P3
	de : P3
	radius : number
	length : number  -- of the curve (the tail after it not included)
	grade : number   -- the track's gradient at the switch, along d (the branch carries it on)
	tail : number    -- a straight after the curve (a turnout speed's fixed radius), 0 if none
	ce : P3          -- where the curve ends (the tail starts); = e without a tail
	speed : number   -- km/h the curve allows (the type's formula), nil if unknown
	lim : TrackLimits
	steep : number   -- branch to a target: the steepest grade on the way (fraction)
	toTarget : boolean
	fan : integer    -- Feed every track: how many branches
	fanGap : number  -- ... their switches' spacing (m)
end
local function arcOf(pk : Pick) : Arc, string
	local e = g_host.getEdge(pk.edge)
	if not e then return nil, _("A segment is gone") end
	local pc = geom.edgePiece(e)
	local p = geom.point(pc, pk.t)
	local t3 = geom.tangent(pc, pk.t)
	local h = math.sqrt(t3.x * t3.x + t3.y * t3.y)
	local grade = h > 1e-6 and t3.z / h or 0
	local d = trackbuild.unit({ x = t3.x, y = t3.y, z = 0 })
	local far : P3 = { x = pk.ex, y = pk.ey, z = p.z }
	local chord = dist2d(p, far)
	if chord < 10 then return nil, _("Drag the handle further away") end
	local c = trackbuild.unit({ x = far.x - p.x, y = far.y - p.y, z = 0 })
	local cd = c.x * d.x + c.y * d.y
	if cd < 0 then d = { x = -d.x, y = -d.y, z = 0 }; cd = -cd; grade = -grade end
	local phi = math.acos(math.min(1, cd))
	if phi > math.rad(80) then return nil, _("The branch turns too sharply - drag the handle further along the track") end
	local lim = limitsOf(e)
	local de : P3
	local length, radius : number, number
	local tail = 0.0
	local ce : P3 = nil
	local fixedR = (opts.speed or 0) > 0 and radiusFor(lim, opts.speed) or nil
	if fixedR and phi > 1e-3 then
		-- a turnout speed: a curve of its radius from the switch, then straight on to the handle
		-- (the line from the handle touching the circle)
		local sg = (-d.y * (far.x - p.x) + d.x * (far.y - p.y)) >= 0 and 1 or -1
		local R = fixedR
		local C : P3 = { x = p.x - d.y * sg * R, y = p.y + d.x * sg * R, z = p.z }
		local D = dist2d(C, far)
		if D <= R + 1 then
			return nil, string.format(_("At %d km/h the branch curves at %d m: drag the handle further out"), math.floor(opts.speed), math.floor(R + 0.5))
		end
		local ang0 = math.atan2(p.y - C.y, p.x - C.x)
		local phiH = math.atan2(far.y - C.y, far.x - C.x)
		local alpha = math.acos(R / D)
		local best : number = nil
		for __, ang in ipairs({ phiH + alpha, phiH - alpha }) do
			-- (travel round the circle: its direction there must point at the handle)
			local tx, ty = -math.sin(ang) * sg, math.cos(ang) * sg
			local qx, qy = C.x + R * math.cos(ang), C.y + R * math.sin(ang)
			if tx * (far.x - qx) + ty * (far.y - qy) > 0 then
				local th = ((ang - ang0) * sg) % (2 * math.pi)
				if not best or th < best then best = th end
			end
		end
		if not best or best > math.rad(80) then
			return nil, _("The branch turns too sharply for this speed - drag the handle further along the track")
		end
		local angE = ang0 + sg * best
		ce = { x = C.x + R * math.cos(angE), y = C.y + R * math.sin(angE), z = p.z }
		de = { x = -math.sin(angE) * sg, y = math.cos(angE) * sg, z = 0 }
		radius, length = R, R * best
		tail = dist2d(ce, far)
	else
		-- (a circular arc: the far end's direction is the start's mirrored about the chord)
		de = { x = 2 * cd * c.x - d.x, y = 2 * cd * c.y - d.y, z = 0 }
		length = phi < 1e-4 and chord or chord * phi / math.sin(phi)
		radius = phi < 1e-4 and math.huge or chord / (2 * math.sin(phi))
	end
	-- (the branch keeps the track's gradient: every track at a switch must leave it at the same
	-- slope - a level branch off a sloping track is refused, "Construction Not Possible")
	if ce then ce.z = p.z + grade * length end
	far.z = p.z + grade * (length + tail)
	-- the free end's height, as Connect's Height & placement: a fixed incline from the switch, or
	-- the height offset above the ground; neither - the track's grade carried on (above). The
	-- branch still leaves the switch at the track's grade and eases to it (see endTangentZ)
	local so = sharedOpts()
	local incline = so.incline as number
	local offset = (so.heightOffset as number) or 0
	if incline ~= nil then
		far.z = p.z + incline / 100 * (length + tail)
	elseif offset ~= 0 then
		local gz = terrain.ground(far.x, far.y)
		if gz then far.z = gz + offset end
	end
	return { p = p, d = d, e = far, de = de, radius = radius, length = length, grade = grade,
		tail = tail, ce = ce or far, speed = speedAt(lim, radius), lim = lim }, nil
end

-- a piece leaving at `grade` and climbing dz over `len`: its end tangent's z (an even change of
-- slope along it - with no change of height it is the grade again)
local function endTangentZ(grade : number, len : number, dz : number) : number
	return 2 * dz - grade * len
end

-- a track taking part: its segment and piece, its offset towards the curve's centre (from the
-- clicked track's line), the branch's radius, its gradient along d
local record Lane
	edge : Engine.Entity
	e : Engine.Component.BaseEdge
	pc : Piece
	oc : number
	r : number
	grade : number
	t : number          -- where its switch is
	z0 : number
end
-- a node along a branch: its angle around the curve, and the cut on the track it crosses there
local record Stop
	ang : number
	key : string
end

-- where the last plan's branches cross the tracks beside them (flat crossings): after a build they
-- can become double-slip switches (opts.doubleSlip)
local g_crossings : {P3} = {}

-- the Dubins path finder (Connect's Min. radius): shortest straights-and-arcs route between two
-- points and headings, no curve tighter than r
local record DPrim
	line : boolean
	px : number
	py : number
	qx : number
	qy : number
	cx : number
	cy : number
	r : number
	a0 : number
	sweep : number
end
local record DResult
	prims : {DPrim}
	error : string
	length : number
end
local dubins = require "network_tools_1::/gui/construction/tools/connect/min_radius/ntools_dubins.script.tl" as {string : any}
local dubinsPath = dubins.path as function(number, number, number, number, number, number, number, number, number) : DResult

-- a unit direction in plan and the gradient along it, from a 3D tangent
local function dirGrade(t : P3, sign : number) : P3, number
	local h = math.sqrt(t.x * t.x + t.y * t.y)
	if h < 1e-6 then return nil, 0 end
	return { x = t.x / h * sign, y = t.y / h * sign, z = 0 }, t.z / h * sign
end

-- a Dubins route as points every few metres (arcs every 15 degrees at most): {x, y, dx, dy, s}
local function routePoints(P : P3, d0 : P3, res : DResult) : {{number}}
	local pts : {{number}} = {}
	local s = 0.0
	local function add(x : number, y : number, dx : number, dy : number) pts[#pts + 1] = { x, y, dx, dy, s } end
	add(P.x, P.y, d0.x, d0.y)
	for __, pr in ipairs(res.prims) do
		if pr.line then
			local L = math.sqrt((pr.qx - pr.px) ^ 2 + (pr.qy - pr.py) ^ 2)
			if L > 0.5 then
				local n = math.max(1, math.ceil(L / 80))
				local ux, uy = (pr.qx - pr.px) / L, (pr.qy - pr.py) / L
				for k = 1, n do
					s = s + L / n
					add(pr.px + (pr.qx - pr.px) * k / n, pr.py + (pr.qy - pr.py) * k / n, ux, uy)
				end
			end
		else
			local n = math.max(1, math.ceil(math.abs(pr.sweep) / math.rad(15)))
			local dir = pr.sweep >= 0 and 1 or -1
			for k = 1, n do
				local a = pr.a0 + pr.sweep * k / n
				s = s + pr.r * math.abs(pr.sweep) / n
				add(pr.cx + pr.r * math.cos(a), pr.cy + pr.r * math.sin(a), -math.sin(a) * dir, math.cos(a) * dir)
			end
		end
	end
	return pts
end

-- A route's track, piece by piece from node n0 (p0) to node n1 (p1), its heights a cubic from the
-- start's grade g0 to the end's g1; signals short of both switches. The steepest grade on it.
local function layRoute(b : Builder, e : Engine.Component.BaseEdge, pts : {{number}}, g0 : number, g1 : number,
		n0 : Engine.Entity, p0 : P3, n1 : Engine.Entity, p1 : P3) : number
	local L = pts[#pts][5]
	local z0, z1 = p0.z, p1.z
	local m0, m1 = g0 * L, g1 * L
	local function zAt(u : number) : number, number
		local u2, u3 = u * u, u * u * u
		local z = (2 * u3 - 3 * u2 + 1) * z0 + (u3 - 2 * u2 + u) * m0 + (-2 * u3 + 3 * u2) * z1 + (u3 - u2) * m1
		local dz = ((6 * u2 - 6 * u) * z0 + (3 * u2 - 4 * u + 1) * m0 + (-6 * u2 + 6 * u) * z1 + (3 * u2 - 2 * u) * m1) / L
		return z, dz
	end
	local maxSlope = 0.0
	local prevN, prevP : Engine.Entity, P3 = n0, p0
	local _zp, prevSlope = zAt(0)
	for k = 2, #pts do
		local q = pts[k]
		local z, slope = zAt(q[5] / L)
		maxSlope = math.max(maxSlope, math.abs(slope))
		local node : Engine.Entity
		local pos : P3
		if k == #pts then node, pos = n1, p1 else
			pos = { x = q[1], y = q[2], z = z }
			node = b.node(pos)
		end
		local len = q[5] - pts[k - 1][5]
		local a = pts[k - 1]
		local sgT = b.segment(prevN, prevP, { x = a[3] * len, y = a[4] * len, z = prevSlope * len },
			node, pos, { x = q[3] * len, y = q[4] * len, z = slope * len }, e)
		-- (signals short of both switches: the first piece leaves one, the last joins the other)
		if k == 2 then b.protectSwitch(sgT, true, opts.sigDist, sigModel()) end
		if k == #pts and #pts > 2 then b.protectSwitch(sgT, false, opts.sigDist, sigModel()) end
		prevN, prevP, prevSlope = node, pos, slope
	end
	return maxSlope
end

-- A station's open track ends at the same end as `node` (one of them): each end node, where it is,
-- the way into the station there and its grade, and whether a track outside already joins it. nil:
-- the node isn't a station track's end
local record FanEnd
	node : Engine.Entity
	pos : P3
	dir : P3
	grade : number
	joined : boolean
end
local function stationEnds(node : Engine.Entity) : {FanEnd}
	local out : {FanEnd} = nil
	pcall(function()
		local sc = api.engine.system.streetConnectorSystem
		local nd = api.engine.getComponent(node, api.type.ComponentType.BASE_NODE) as Engine.Component.BaseNode
		if not nd then return end
		-- the station: the construction owning a track at the node
		local conE : Engine.Entity = nil
		for __, s in ipairs(api.engine.util.octree.findEntitiesInCircle(api.type.Vec2f.new(nd.position.x, nd.position.y), 3, api.type.ComponentType.BASE_EDGE)) do
			local se = g_host.getEdge(s)
			if se and (se.node0 == node or se.node1 == node) then
				local c = sc.getConstructionEntityForEdge(s)
				if c and c >= 0 then conE = c; break end
			end
		end
		if not conE then return end
		local con = api.engine.getComponent(conE, api.type.ComponentType.CONSTRUCTION) as {string : any}
		if not con then return end
		local frozenNode : {Engine.Entity : boolean} = {}
		local frozenEdge : {Engine.Entity : boolean} = {}
		for __, n in ipairs((con.frozenNodes or {}) as {Engine.Entity}) do frozenNode[n] = true end
		for __, s in ipairs((con.frozenEdges or {}) as {Engine.Entity}) do frozenEdge[s] = true end
		local ends : {FanEnd} = {}
		local refDir : P3 = nil
		for s in pairs(frozenEdge) do
			local se = g_host.getEdge(s)
			if se and se.roadType == api.type["enum"].RoadType.TRACK then
				local spc = geom.edgePiece(se)
				for __, n in ipairs({ se.node0, se.node1 }) do
					if not frozenNode[n] then
						local dd, gg : P3, number
						if n == se.node0 then dd, gg = dirGrade(spc.t0, 1) else dd, gg = dirGrade(spc.t1, -1) end
						local np = n == se.node0 and spc.p0 or spc.p1
						-- (joined: a track outside the station ends there too)
						local joined = false
						for __, s2 in ipairs(api.engine.util.octree.findEntitiesInCircle(api.type.Vec2f.new(np.x, np.y), 3, api.type.ComponentType.BASE_EDGE)) do
							local o = g_host.getEdge(s2)
							if o and not frozenEdge[s2] and (o.node0 == n or o.node1 == n) then joined = true end
						end
						if dd then
							ends[#ends + 1] = { node = n, pos = np, dir = dd, grade = gg, joined = joined }
							if n == node then refDir = dd end
						end
					end
				end
			end
		end
		if not refDir then return end
		-- (the same end of the station: entered the same way)
		out = {}
		for __, en in ipairs(ends) do
			if en.dir.x * refDir.x + en.dir.y * refDir.y > 0.9 then out[#out + 1] = en end
		end
	end)
	return out
end

-- Fan (Feed every track): from the clicked track a branch to each open track end of the station at
-- that end, switches one after another from the click towards the station. Each side's outermost
-- track leaves first, so a branch is out beside the ones inside it before they start: none cross,
-- and none runs into a station track. The switches' spacing grows until that holds (and each
-- turnout has left the line before the next switch).
local FAN_CLEAR = 4.5     -- metres between a branch and the track / branch inside it
local function planFan(pk : Pick, ends : {FanEnd}) : SimpleProposal, string, Arc
	local e = g_host.getEdge(pk.edge)
	if not e then return nil, _("A segment is gone"), nil end
	local pc = geom.edgePiece(e)
	local P = geom.point(pc, pk.t)
	local lim = limitsOf(e)
	local R = (opts.speed or 0) > 0 and radiusFor(lim, opts.speed) or math.max(opts.minRadius or 300, lim and lim.minR or 0)
	-- the way towards the station along the line, and across it (+ left)
	local cx, cy = 0.0, 0.0
	for __, en in ipairs(ends) do cx, cy = cx + en.pos.x / #ends, cy + en.pos.y / #ends end
	local t3 = geom.tangent(pc, pk.t)
	local sgnD = (t3.x * (cx - P.x) + t3.y * (cy - P.y)) >= 0 and 1 or -1
	local d, _g = dirGrade(t3, sgnD)
	if not d then return nil, _("Can't read the track's direction"), nil end
	local nx, ny = -d.y, d.x
	-- the tracks to feed (not one a track outside already joins), each side outermost first
	local record FanT
		en : FanEnd
		lat : number
		along : number
	end
	local left, right : {FanT}, {FanT} = {}, {}
	for __, en in ipairs(ends) do
		local lat = (en.pos.x - P.x) * nx + (en.pos.y - P.y) * ny
		local along = (en.pos.x - P.x) * d.x + (en.pos.y - P.y) * d.y
		if not en.joined then
			if along < 20 then return nil, _("Click the line further from the station: its tracks must be ahead of the switches"), nil end
			if lat >= 0 then left[#left + 1] = { en = en, lat = lat, along = along } else right[#right + 1] = { en = en, lat = lat, along = along } end
		end
	end
	table.sort(left, function(a : FanT, c : FanT) : boolean return a.lat > c.lat end)
	table.sort(right, function(a : FanT, c : FanT) : boolean return a.lat < c.lat end)
	-- (outermost first, the sides taking turns)
	local order : {FanT} = {}
	for i = 1, math.max(#left, #right) do
		if left[i] then order[#order + 1] = left[i] end
		if right[i] then order[#order + 1] = right[i] end
	end
	if #order == 0 then return nil, _("Every track at this end of the station is joined already"), nil end
	local segLen = geom.length(pc)
	-- along the line from the click: where each switch can go (on the clicked segment)
	local tAlong = function(s : number) : number
		local q : P3 = { x = P.x + d.x * s, y = P.y + d.y * s, z = 0 }
		local t, dd = geom.closestT(pc, q.x, q.y)
		if dd > 1.5 then return nil end
		return t
	end
	-- a route's lateral offset (from the line) at `along`, by its points (nil: not there)
	local function latAt(pts : {{number}}, along : number) : number
		local prevA, prevL : number, number = nil, nil
		for __, q in ipairs(pts) do
			local a = (q[1] - P.x) * d.x + (q[2] - P.y) * d.y
			local l = (q[1] - P.x) * nx + (q[2] - P.y) * ny
			if prevA and ((prevA <= along and a >= along) or (prevA >= along and a <= along)) and math.abs(a - prevA) > 1e-6 then
				return prevL + (l - prevL) * (along - prevA) / (a - prevA)
			end
			prevA, prevL = a, l
		end
		return nil
	end
	local record FanR
		ft : FanT
		t : number
		at : number
		pts : {{number}}
		d0 : P3
		g0 : number
	end
	local function attempt(gap : number) : {FanR}, string
		local routes : {FanR} = {}
		for k, ft in ipairs(order) do
			local at = (k - 1) * gap
			local t = tAlong(at)
			if not t then return nil, "segment" end
			if t * segLen < 4 or (1 - t) * segLen < 4 then return nil, "segment" end
			local p = geom.point(pc, t)
			local d0, g0 = dirGrade(geom.tangent(pc, t), sgnD)
			if not d0 then return nil, "route" end
			local ok, res = pcall(dubinsPath, p.x, p.y, d0.x, d0.y, ft.en.pos.x, ft.en.pos.y, ft.en.dir.x, ft.en.dir.y, R)
			if not ok or not res or res.error or not res.prims then return nil, "route" end
			local pts = routePoints(p, d0, res)
			-- (a sensible route: no loop round)
			local straight = dist2d(p, ft.en.pos)
			if pts[#pts][5] > straight * 1.6 + 20 then return nil, "route" end
			routes[k] = { ft = ft, t = t, at = at, pts = pts, d0 = d0, g0 = g0 }
		end
		-- every pair on one side: the outer (earlier) one beside the inner one wherever both run, and
		-- beside the inner station track from its end on; each turnout clear of the line by the next switch
		for i, ri in ipairs(routes) do
			local nextR = routes[i + 1]
			if nextR then
				local l = latAt(ri.pts, nextR.at)
				if l and math.abs(l) < 3.5 then return nil, "clear" end
			end
			for j = i + 1, #routes do
				local rj = routes[j]
				if (ri.ft.lat >= 0) == (rj.ft.lat >= 0) then
					local side = ri.ft.lat >= 0 and 1 or -1
					for __, q in ipairs(rj.pts) do
						local a = (q[1] - P.x) * d.x + (q[2] - P.y) * d.y
						local lj = ((q[1] - P.x) * nx + (q[2] - P.y) * ny) * side
						local li = latAt(ri.pts, a)
						if li and lj > 0.5 and li * side < lj + FAN_CLEAR then return nil, "cross" end
					end
					local li = latAt(ri.pts, rj.ft.along)
					if li and li * side < math.abs(rj.ft.lat) + FAN_CLEAR then return nil, "cross" end
				end
			end
		end
		return routes, nil
	end
	local routes : {FanR} = nil
	local whyF = "route"
	local gap = 25.0
	while gap <= 200 and not routes do
		routes, whyF = attempt(gap)
		if not routes then
			if whyF == "segment" then break end
			gap = gap + 10
		end
	end
	if not routes then
		if whyF == "segment" then
			return nil, string.format(_("%d switches don't fit on the clicked segment - click further back on a longer straight"), #order), nil
		end
		return nil, string.format(_("No fan to these %d tracks with curves of %d m or wider - click further from the station, or a lower turnout speed"), #order, math.floor(R + 0.5)), nil
	end
	local b = trackbuild.new()
	b.onNewSegment = function(seg : Proposal.SegmentAndEntity) terrain.upgradeSegment(seg, true) end
	g_crossings = {}
	local ts : {number} = {}
	for k, r in ipairs(routes) do ts[k] = r.t end
	local cuts = b.splitAt(pk.edge, ts)
	if not cuts then return nil, b.why, nil end
	local steep = 0.0
	for k, r in ipairs(routes) do
		b.touch(r.ft.en.node)
		steep = math.max(steep, layRoute(b, e, r.pts, r.g0, r.ft.en.grade, cuts[k].node, cuts[k].pos, r.ft.en.node, r.ft.en.pos))
	end
	local last = routes[#routes]
	local arc : Arc = { p = P, d = d, e = last.ft.en.pos, de = last.ft.en.dir, radius = R, length = last.pts[#last.pts][5],
		grade = routes[1].g0, tail = 0, ce = last.ft.en.pos, speed = speedAt(lim, R), lim = lim }
	arc.steep = steep
	arc.toTarget = true
	arc.fan = #routes
	arc.fanGap = gap
	return b.proposal(), b.why, arc
end

-- Branch to a target: a switch at the click, the route (Dubins) to the target, arriving along the
-- track there (a switch at a node or a split, or carrying on from a dead end). Heights: a smooth
-- curve leaving at the clicked track's grade and arriving at the target track's.
local function planTarget(pk : Pick) : SimpleProposal, string, Arc
	-- a station's track end, Feed every track: a branch to each of its tracks at that end
	if pk.target.node and opts.fanStation ~= false and not (pk.extras and #pk.extras > 0) then
		local ends = stationEnds(pk.target.node)
		if ends and #ends >= 2 then return planFan(pk, ends) end
	end
	local T = pk.target
	local e = g_host.getEdge(pk.edge)
	if not e then return nil, _("A segment is gone"), nil end
	if pk.extras and #pk.extras > 0 then return nil, _("Branching onto a track works with one track: drop the tracks beside it (click them again)"), nil end
	local pc = geom.edgePiece(e)
	local P = geom.point(pc, pk.t)
	local t3 = geom.tangent(pc, pk.t)
	local lim = limitsOf(e)
	local R = (opts.speed or 0) > 0 and radiusFor(lim, opts.speed) or math.max(opts.minRadius or 300, lim and lim.minR or 0)
	-- the target: its point, and the ways a branch can arrive there (onto each track leaving it)
	local Q : P3
	local arrivals : {{P3, number}} = {}
	if T.node then
		local nd = api.engine.getComponent(T.node, api.type.ComponentType.BASE_NODE) as Engine.Component.BaseNode
		if not nd then return nil, _("The target is gone"), nil end
		Q = { x = nd.position.x, y = nd.position.y, z = nd.position.z }
		for __, s in ipairs(api.engine.util.octree.findEntitiesInCircle(api.type.Vec2f.new(Q.x, Q.y), 3, api.type.ComponentType.BASE_EDGE)) do
			local se = g_host.getEdge(s)
			if se and se.roadType == api.type["enum"].RoadType.TRACK and (se.node0 == T.node or se.node1 == T.node) then
				local spc = geom.edgePiece(se)
				local dd, gg : P3, number
				if se.node0 == T.node then dd, gg = dirGrade(spc.t0, 1) else dd, gg = dirGrade(spc.t1, -1) end
				if dd then arrivals[#arrivals + 1] = { dd, gg } end
			end
		end
	else
		local te = g_host.getEdge(T.edge)
		if not te then return nil, _("The target is gone"), nil end
		local tpc = geom.edgePiece(te)
		Q = geom.point(tpc, T.t)
		local tt = geom.tangent(tpc, T.t)
		for __, sgn in ipairs({ 1, -1 }) do
			local dd, gg = dirGrade(tt, sgn)
			if dd then arrivals[#arrivals + 1] = { dd, gg } end
		end
	end
	if #arrivals == 0 then return nil, _("Can't read the track's direction at the target"), nil end
	-- the shortest route over both ways of leaving the switch and every way of arriving
	local best : DResult = nil
	local bestD, bestA : P3, P3
	local bestG0, bestG1 : number, number
	for __, sgn in ipairs({ 1, -1 }) do
		local d0, g0 = dirGrade(t3, sgn)
		if d0 then
			for __, ar in ipairs(arrivals) do
				local ok, res = pcall(dubinsPath, P.x, P.y, d0.x, d0.y, Q.x, Q.y, ar[1].x, ar[1].y, R)
				if ok and res and not res.error and res.prims and (not best or res.length < best.length) then
					best, bestD, bestA, bestG0, bestG1 = res, d0, ar[1], g0, ar[2]
				end
			end
		end
	end
	if not best then
		return nil, string.format(_("No route onto that track with curves of %d m or wider - drop the handle further away"), math.floor(R + 0.5)), nil
	end
	-- the route as points every few metres (arcs every 15 degrees at most), with directions
	local pts : {{number}} = {}   -- x, y, dx, dy, s
	local s = 0.0
	local function add(x : number, y : number, dx : number, dy : number) pts[#pts + 1] = { x, y, dx, dy, s } end
	add(P.x, P.y, bestD.x, bestD.y)
	for __, pr in ipairs(best.prims) do
		if pr.line then
			local L = math.sqrt((pr.qx - pr.px) ^ 2 + (pr.qy - pr.py) ^ 2)
			if L > 0.5 then
				local n = math.max(1, math.ceil(L / 80))
				local ux, uy = (pr.qx - pr.px) / L, (pr.qy - pr.py) / L
				for k = 1, n do
					s = s + L / n
					add(pr.px + (pr.qx - pr.px) * k / n, pr.py + (pr.qy - pr.py) * k / n, ux, uy)
				end
			end
		else
			local n = math.max(1, math.ceil(math.abs(pr.sweep) / math.rad(15)))
			local dir = pr.sweep >= 0 and 1 or -1
			for k = 1, n do
				local a = pr.a0 + pr.sweep * k / n
				s = s + pr.r * math.abs(pr.sweep) / n
				add(pr.cx + pr.r * math.cos(a), pr.cy + pr.r * math.sin(a), -math.sin(a) * dir, math.cos(a) * dir)
			end
		end
	end
	local L = s
	if L < 10 or #pts < 2 then return nil, _("Drag the handle further away"), nil end
	-- heights: a cubic from the switch (its grade) to the target (its grade)
	local z0, z1 = P.z, Q.z
	local m0, m1 = bestG0 * L, bestG1 * L
	local function zAt(u : number) : number, number
		local u2, u3 = u * u, u * u * u
		local z = (2 * u3 - 3 * u2 + 1) * z0 + (u3 - 2 * u2 + u) * m0 + (-2 * u3 + 3 * u2) * z1 + (u3 - u2) * m1
		local dz = ((6 * u2 - 6 * u) * z0 + (3 * u2 - 4 * u + 1) * m0 + (-6 * u2 + 6 * u) * z1 + (3 * u2 - 2 * u) * m1) / L
		return z, dz
	end
	-- the switches: at the click, and at the target (one split if both are on the clicked segment)
	local b = trackbuild.new()
	b.onNewSegment = function(seg : Proposal.SegmentAndEntity) terrain.upgradeSegment(seg, true) end
	g_crossings = {}
	local n0, n1 : Engine.Entity, Engine.Entity
	local p0, p1 : P3, P3
	if T.edge and T.edge == pk.edge then
		local cuts = b.splitAt(pk.edge, { pk.t, T.t })
		if not cuts then return nil, b.why, nil end
		n0, p0, n1, p1 = cuts[1].node, cuts[1].pos, cuts[2].node, cuts[2].pos
	else
		local c0 = b.splitAt(pk.edge, { pk.t })
		if not c0 then return nil, b.why, nil end
		n0, p0 = c0[1].node, c0[1].pos
		if T.edge then
			local c1 = b.splitAt(T.edge, { T.t })
			if not c1 then return nil, b.why, nil end
			n1, p1 = c1[1].node, c1[1].pos
		else
			n1, p1 = T.node, Q
			b.touch(T.node)
		end
	end
	local maxSlope = 0.0
	local prevN, prevP : Engine.Entity, P3 = n0, p0
	local _zp, prevSlope = zAt(0)
	for k = 2, #pts do
		local q = pts[k]
		local u = q[5] / L
		local z, slope = zAt(u)
		maxSlope = math.max(maxSlope, math.abs(slope))
		local node : Engine.Entity
		local pos : P3
		if k == #pts then node, pos = n1, p1 else
			pos = { x = q[1], y = q[2], z = z }
			node = b.node(pos)
		end
		local len = q[5] - pts[k - 1][5]
		local a = pts[k - 1]
		local sgT = b.segment(prevN, prevP, { x = a[3] * len, y = a[4] * len, z = prevSlope * len },
			node, pos, { x = q[3] * len, y = q[4] * len, z = slope * len }, e)
		-- (signals short of both switches: the first piece leaves one, the last joins the other)
		if k == 2 then b.protectSwitch(sgT, true, opts.sigDist, sigModel()) end
		if k == #pts and #pts > 2 then b.protectSwitch(sgT, false, opts.sigDist, sigModel()) end
		prevN, prevP, prevSlope = node, pos, slope
	end
	local arc : Arc = { p = P, d = bestD, e = Q, de = bestA, radius = R, length = L, grade = bestG0, tail = 0, ce = Q,
		speed = speedAt(lim, R), lim = lim }
	arc.steep = maxSlope
	arc.toTarget = true
	return b.proposal(), b.why, arc
end

-- The branch(es): from the clicked track to the handle, and from each track picked beside it a
-- branch parallel to the first (the same curve, centred on the same point, offset by the tracks'
-- spacing). A branch that leaves on the outside of the turn crosses the tracks inside it: a flat
-- crossing (a node shared by both) where it does.
local function plan(pk : Pick) : SimpleProposal, string, Arc
	if pk.target then return planTarget(pk) end
	local arc, why = arcOf(pk)
	if not arc then return nil, why, nil end
	local e = g_host.getEdge(pk.edge)
	local d, P = arc.d, arc.p
	local extras = pk.extras or {}
	local b = trackbuild.new()
	-- a branch running high above / deep below the ground becomes a bridge / tunnel (the panel's
	-- Bridge height / Tunnel depth)
	b.onNewSegment = function(seg : Proposal.SegmentAndEntity) terrain.upgradeSegment(seg, true) end
	-- how far the free end is lifted (+) / lowered (-) from the track's grade carried on
	local tail = arc.tail or 0
	local lift = arc.e.z - (P.z + arc.grade * (arc.length + tail))
	g_crossings = {}
	if #extras == 0 or arc.radius == math.huge then
		if #extras > 0 then return nil, _("Curve the branch a little: tracks beside it follow its curve"), arc end
		local cut = b.splitAt(pk.edge, { pk.t })
		if not cut then return nil, b.why, arc end
		-- (the exact circular-arc Hermite tangent, 4 R tan(turn / 4) - the arc's length is a little short)
		local k = arc.radius == math.huge and arc.length or 4 * arc.radius * math.tan(arc.length / arc.radius / 4)
		local gz = arc.grade * k
		if tail > 1 then
			-- a turnout speed: the curve at the track's grade, then the straight (it takes any lift)
			local midNode = b.node(arc.ce)
			local s1 = b.segment(cut[1].node, cut[1].pos, { x = arc.d.x * k, y = arc.d.y * k, z = gz },
				midNode, arc.ce, { x = arc.de.x * k, y = arc.de.y * k, z = gz }, e)
			b.protectSwitch(s1, true, opts.sigDist, sigModel())
			b.segment(midNode, arc.ce, { x = arc.de.x * tail, y = arc.de.y * tail, z = arc.grade * tail },
				b.node(arc.e), arc.e, { x = arc.de.x * tail, y = arc.de.y * tail, z = endTangentZ(arc.grade, tail, arc.e.z - arc.ce.z) }, e)
			return b.proposal(), b.why, arc
		end
		local endNode = b.node(arc.e)
		local s1 = b.segment(cut[1].node, cut[1].pos, { x = arc.d.x * k, y = arc.d.y * k, z = gz },
			endNode, arc.e, { x = arc.de.x * k, y = arc.de.y * k, z = endTangentZ(arc.grade, k, arc.e.z - cut[1].pos.z) }, e)
		b.protectSwitch(s1, true, opts.sigDist, sigModel())
		return b.proposal(), b.why, arc
	end
	-- the curve: its centre on the handle's side, how far it turns
	local vx, vy = pk.ex - P.x, pk.ey - P.y
	local sg = (-d.y * vx + d.x * vy) >= 0 and 1 or -1
	local R = arc.radius
	local nx, ny = -d.y * sg, d.x * sg            -- towards the centre
	local C : P3 = { x = P.x + nx * R, y = P.y + ny * R, z = P.z }
	local theta = arc.length / R
	-- (on the circle of radius r around C, `ang` round from the switches' line: point, direction)
	local function at(r : number, ang : number) : P3
		local ca, sa = math.cos(ang * sg), math.sin(ang * sg)
		local ux, uy = -nx, -ny
		return { x = C.x + (ux * ca - uy * sa) * r, y = C.y + (ux * sa + uy * ca) * r, z = 0 }
	end
	local function dirAt(ang : number) : P3
		local ca, sa = math.cos(ang * sg), math.sin(ang * sg)
		return { x = d.x * ca - d.y * sa, y = d.x * sa + d.y * ca, z = 0 }
	end
	local lanes : {Lane} = { { edge = pk.edge, e = e, pc = geom.edgePiece(e), oc = 0, r = R, grade = arc.grade, t = pk.t, z0 = P.z } }
	for __, ex in ipairs(extras) do
		local oe = g_host.getEdge(ex)
		if not oe then return nil, _("A segment is gone"), arc end
		local pc = geom.edgePiece(oe)
		local tq = geom.closestT(pc, P.x, P.y)
		local q = geom.point(pc, tq)
		local oc = (q.x - P.x) * nx + (q.y - P.y) * ny
		if math.abs(oc) < 3 or math.abs(oc) > 40 then return nil, _("Tracks beside it should run 3 to 40 m apart"), arc end
		if R - oc < 30 then return nil, _("The curve is too tight for the tracks inside it - drag the handle further"), arc end
		local t3 = geom.tangent(pc, tq)
		local h = math.sqrt(t3.x * t3.x + t3.y * t3.y)
		local g = h > 1e-6 and t3.z / h or 0
		if t3.x * d.x + t3.y * d.y < 0 then g = -g end
		lanes[#lanes + 1] = { edge = ex, e = oe, pc = pc, oc = oc, r = R - oc, grade = g, t = tq, z0 = q.z }
	end
	-- every split each track needs: its switch, and where each branch from further out crosses it
	local wantsT : {Engine.Entity : {number}} = {}
	local wantsK : {Engine.Entity : {string}} = {}
	local function want(ln : Lane, t : number, key : string)
		wantsT[ln.edge] = wantsT[ln.edge] or {}
		wantsK[ln.edge] = wantsK[ln.edge] or {}
		local ts, ks = wantsT[ln.edge], wantsK[ln.edge]
		ts[#ts + 1], ks[#ks + 1] = t, key
	end
	local stops : {integer : {Stop}} = {}
	for i, ln in ipairs(lanes) do
		want(ln, ln.t, "sw" .. tostring(i))
		stops[i] = { { ang = 0, key = "sw" .. tostring(i) } }
	end
	for i, ln in ipairs(lanes) do
		for j, other in ipairs(lanes) do
			if j ~= i and other.oc > ln.oc then
				-- (the circle of radius r reaches the other track's line where R - r cos(ang) = its offset)
				local c = (R - other.oc) / ln.r
				if c <= 1 then
					local ang = math.acos(c)
					if ang < theta - 1e-3 then
						local x = at(ln.r, ang)
						local tx, dd = geom.closestT(other.pc, x.x, x.y)
						if dd > 2 then
							return nil, _("A branch crosses a track beyond the clicked segment - click nearer the segments' ends, or a shorter branch"), arc
						end
						local key = string.format("x%d_%d", i, j)
						want(other, tx, key)
						stops[i][#stops[i] + 1] = { ang = ang, key = key }
					end
				end
			end
		end
	end
	local cutOf : {string : Cut} = {}
	for __, ln in ipairs(lanes) do
		local ts = wantsT[ln.edge]
		if ts then
			local cuts = b.splitAt(ln.edge, ts)
			if not cuts then return nil, b.why, arc end
			for k, c in ipairs(cuts) do
				cutOf[wantsK[ln.edge][k]] = c
				-- (a crossing: remembered, a double-slip switch there after the build if wanted)
				if wantsK[ln.edge][k]:sub(1, 1) == "x" then g_crossings[#g_crossings + 1] = c.pos end
			end
		end
	end
	-- each branch: piece by piece between its switch, its crossings and its free end
	for i, ln in ipairs(lanes) do
		local st = stops[i]
		table.sort(st, function(a : Stop, c : Stop) : boolean return a.ang < c.ang end)
		local prevNode, prevPos, prevAng = cutOf[st[1].key].node, cutOf[st[1].key].pos, 0.0
		for k = 2, #st + 1 do
			local ang = k <= #st and st[k].ang or theta
			local node : Engine.Entity
			local pos : P3
			if k <= #st then
				node, pos = cutOf[st[k].key].node, cutOf[st[k].key].pos
			else
				pos = at(ln.r, theta)
				-- (every branch's free end lifted as much as the clicked track's; only this last
				-- piece changes height - the crossings stay at the tracks' own; with a tail, the tail)
				pos.z = ln.z0 + ln.grade * ln.r * theta + (tail > 1 and 0 or lift)
				node = b.node(pos)
			end
			-- (the exact circular-arc Hermite tangent for this piece of the curve)
			local len = 4 * ln.r * math.tan((ang - prevAng) / 4)
			local d0, d1 = dirAt(prevAng), dirAt(ang)
			local gz = ln.grade * len
			local gz1 = (k > #st and tail <= 1) and endTangentZ(ln.grade, len, pos.z - prevPos.z) or gz
			local sg1 = b.segment(prevNode, prevPos, { x = d0.x * len, y = d0.y * len, z = gz },
				node, pos, { x = d1.x * len, y = d1.y * len, z = gz1 }, e)
			-- (each branch's first piece leaves its switch)
			if k == 2 then b.protectSwitch(sg1, true, opts.sigDist, sigModel()) end
			prevNode, prevPos, prevAng = node, pos, ang
		end
		-- a turnout speed: each branch carries on straight, as far as the clicked track's
		if tail > 1 then
			local dT = dirAt(theta)
			local q : P3 = { x = prevPos.x + dT.x * tail, y = prevPos.y + dT.y * tail, z = prevPos.z + ln.grade * tail + lift }
			b.segment(prevNode, prevPos, { x = dT.x * tail, y = dT.y * tail, z = ln.grade * tail },
				b.node(q), q, { x = dT.x * tail, y = dT.y * tail, z = endTangentZ(ln.grade, tail, q.z - prevPos.z) }, e)
		end
	end
	return b.proposal(), b.why, arc
end

-- A track under the dropped handle (x, y), for a branch onto it: a track node within 8 m (not the
-- clicked segment's own ends), else a point on a track segment within 4 m (a node if that close to
-- one of its ends). nil: none - the branch ends free
local SNAP_NODE, SNAP_EDGE, END_NEAR = 8, 4, 6
local function findTarget(pk : Pick, x : number, y : number) : Target
	local own = g_host.getEdge(pk.edge)
	local function isOwnEnd(n : Engine.Entity) : boolean return own ~= nil and (n == own.node0 or n == own.node1) end
	local function trackNode(n : Engine.Entity) : boolean
		local nd = api.engine.getComponent(n, api.type.ComponentType.BASE_NODE) as Engine.Component.BaseNode
		if not nd then return false end
		for __, s in ipairs(api.engine.util.octree.findEntitiesInCircle(api.type.Vec2f.new(nd.position.x, nd.position.y), 3, api.type.ComponentType.BASE_EDGE)) do
			local se = g_host.getEdge(s)
			if se and se.roadType == api.type["enum"].RoadType.TRACK and (se.node0 == n or se.node1 == n) then return true end
		end
		return false
	end
	local best : Target = nil
	pcall(function()
		local bestD = SNAP_NODE
		for __, n in ipairs(api.engine.util.octree.findEntitiesInCircle(api.type.Vec2f.new(x, y), SNAP_NODE, api.type.ComponentType.BASE_NODE)) do
			local nd = api.engine.getComponent(n, api.type.ComponentType.BASE_NODE) as Engine.Component.BaseNode
			if nd and not isOwnEnd(n) then
				local dd = math.sqrt((nd.position.x - x) ^ 2 + (nd.position.y - y) ^ 2)
				if dd < bestD and trackNode(n) then
					bestD = dd
					best = { node = n, pos = { x = nd.position.x, y = nd.position.y, z = nd.position.z } }
				end
			end
		end
		if best then return end
		bestD = SNAP_EDGE
		for __, s in ipairs(api.engine.util.octree.findEntitiesInCircle(api.type.Vec2f.new(x, y), 40, api.type.ComponentType.BASE_EDGE)) do
			local se = g_host.getEdge(s)
			if se and se.roadType == api.type["enum"].RoadType.TRACK then
				local spc = geom.edgePiece(se)
				local t, dd = geom.closestT(spc, x, y)
				if dd < bestD and t > 0 and t < 1 then
					local len = math.sqrt((spc.p1.x - spc.p0.x) ^ 2 + (spc.p1.y - spc.p0.y) ^ 2)
					bestD = dd
					-- (that close to an end: the node there - a split would leave too short a piece)
					if t * len < END_NEAR and not isOwnEnd(se.node0) then
						best = { node = se.node0, pos = spc.p0 }
					elseif (1 - t) * len < END_NEAR and not isOwnEnd(se.node1) then
						best = { node = se.node1, pos = spc.p1 }
					elseif t * len >= END_NEAR and (1 - t) * len >= END_NEAR then
						best = { edge = s, t = t, pos = geom.point(spc, t) }
					end
				end
			end
		end
	end)
	-- (not the switch's own spot)
	if best and best.edge == pk.edge and math.abs((best.t or 0) - pk.t) < 0.02 then return nil end
	return best
end

local JunctionActionRecipe = react.RegisterRecipe("NtoolsJunctionAction", function(params : ConstructionCustomActionParams<any>) : TreeNodeId
	react.onUnmount(preview.clear)
	local pickState : ReactStateT<Pick> = react.useState(nil)
	local costState : ReactStateT<integer> = react.useState(0)
	local errorState : ReactStateT<string> = react.useState("")
	local draggingState : ReactStateT<integer> = react.useState(0)
	local hoverState : ReactStateT<integer> = react.useState(0)
	local aliveRef : ReactRefT<boolean> = react.useRef(true)
	local busyState : ReactStateT<boolean> = react.useState(false)
	local anarchyUi = engine_react_util.useStepState(function() : boolean return g_host.anarchy() end)
	local optsUi = engine_react_util.useStepState(function() : string
		local so = sharedOpts()
		return tostring(opts.minRadius) .. "/" .. tostring(opts.side) .. "/" .. tostring(so.incline) .. "/" .. tostring(so.heightOffset)
			.. "/" .. tostring(so.bridgeHeight) .. "/" .. tostring(so.tunnelDepth) .. "/" .. tostring(so.structure)
			.. "/" .. tostring(opts.speed) .. "/" .. tostring(opts.doubleSlip)
			.. "/" .. tostring(opts.signals) .. "/" .. tostring(opts.signalModel) .. "/" .. tostring(opts.sigDist)
			.. "/" .. tostring(opts.fanStation)
	end)

	local handlersRef : ReactRefT<{string : function()}> = react.useRef({})
	for __, name in ipairs(g_host.toolbarEvents) do
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
		return
	end

	local busy = busyState:old() == true
	local pick = pickState:old()
	if busy or (pick and not (api.engine.entityExists(pick.edge) and g_host.getEdge(pick.edge))) then pick = nil end
	local anarchy = anarchyUi:old() == true
	local _o = optsUi:old()

	local proposal : SimpleProposal = nil
	local why : string = nil
	local arc : Arc = nil
	if pick then
		local ok, p, w, a = pcall(plan, pick)
		if ok then proposal, why, arc = p, w, a else why = _("Can't be planned here"); dbg("[network_tools] junction: " .. tostring(p)) end
	end
	local blocked = errorState:old() ~= "" and not anarchy
	g_host.ui.canBuild = proposal ~= nil and not blocked

	local function clear()
		if aliveRef:hasExpired() then return end
		pickState:set(nil)
		costState:set(0)
		errorState:set("")
	end

	local function build()
		if not proposal or blocked or busy then return end
		local context = api.type.Context.new()
		context.player = api.engine.util.getPlayer()
		-- (as the game's own builders: it may tidy the street graph round the new switches - the
		-- verdict below was checked the same way)
		pcall(function() context.cleanupStreetGraph = true end)
		local cmd = api.cmd.makeWorldBuildProposalCmd(proposal, context, anarchy, true)
		-- the crossings this build makes, for double-slip switches once it stands
		local crossings : {P3} = opts.doubleSlip and g_crossings or {}
		pickState:set(nil)
		busyState:set(true)
		local send = shared.send as function(Command<WorldBuildProposalCommandData>, function(WorldBuildProposalCommandData, boolean), boolean)
		send(cmd, function(__ : WorldBuildProposalCommandData, success : boolean)
			if not success then dbg("[network_tools] Junction: build failed") end
			if success and #crossings > 0 then
				-- each crossing's node (found where it was planned) made a double-slip switch, with the
				-- game's own proposal (as its node window's Double slip switch: Yes)
				for __, pos in ipairs(crossings) do
					pcall(function()
						for __, n in ipairs(api.engine.util.octree.findEntitiesInCircle(api.type.Vec2f.new(pos.x, pos.y), 1.5, api.type.ComponentType.BASE_NODE)) do
							local p = api.engine.util.proposal.createDoubleSlipSwitchProposal(n, true)
							if p then
								api.cmd.sendCommand(api.cmd.makeWorldBuildProposalCmd(p, nil, false, true), function(__ : WorldBuildProposalCommandData, ok : boolean)
									if not ok then dbg("[network_tools] Junction: double-slip switch refused at node " .. tostring(n)) end
								end)
							end
						end
					end)
				end
			end
			if aliveRef:hasExpired() then return end
			busyState:set(false)
			clear()
		end, true)
	end

	handlersRef:set({
		ntoolsResetShape = clear,
		ntoolsBuild = build,
	})

	local handleList : {Handle} = {}
	-- (on its target when dropped on a track)
	if pick and pick.target then handleList[1] = { x = pick.target.pos.x, y = pick.target.pos.y, z = nil }
	elseif pick then handleList[1] = { x = pick.ex, y = pick.ey, z = nil } end
	local dragging = draggingState:old() or 0
	local hover = hoverState:old() or 0
	local dragCtl : DragCtl = {
		handles = handleList,
		dragging = dragging,
		setDragging = function(i : integer) draggingState:set(i) end,
		hover = hover,
		setHover = function(i : integer) hoverState:set(i) end,
		onDrag = function(__ : integer, x : number, y : number)
			if not pick then return end
			costState:set(0)
			errorState:set("")
			-- (over a track: the branch goes onto it)
			pickState:set({ edge = pick.edge, t = pick.t, ex = x, ey = y, extras = pick.extras, target = findTarget(pick, x, y) })
		end,
	}

	padMod.actions(pad, _("Pick track / grab handle"), function() leave(params) end, _("Leave the tool"))

	local actionFn = function() : TreeNodeId
		padMod.trackLayer(pad)
		local crosshair, circle = padMod.crosshair(pad)
		local children : {TreeNodeId} = {}
		if busy then
			children[#children + 1] = g_host.tooltip(_("Building..."), true, false)
			return builtin.ActionDescriptor{
				tool = "construction-menu-perks",
				onBack = function() leave(params) end,
				crosshair = crosshair,
				terrainCirclePolicy = circle,
				children = children,
			}
		end
		children[#children + 1] = builtin.Selector(padMod.selector(pad, {
			onSelect = function(entity : Engine.Entity, __ : {integer}, __ : Gui.SelectionDetails) : boolean
				local x, y = handles.cursor()
				if dragging ~= 0 or (x and handles.hit(handleList, x, y) > 0) then return true end
				local e = g_host.getEdge(entity)
				if not e or e.roadType ~= api.type["enum"].RoadType.TRACK then return false end
				if not x then return true end
				costState:set(0)
				errorState:set("")
				-- a track beside the picked one: it branches too, parallel (again: dropped)
				if pick and entity ~= pick.edge then
					local list : {Engine.Entity} = {}
					local had = false
					for __, ex in ipairs(pick.extras or {}) do
						if ex == entity then had = true else list[#list + 1] = ex end
					end
					if not had then list[#list + 1] = entity end
					pickState:set({ edge = pick.edge, t = pick.t, ex = pick.ex, ey = pick.ey, extras = list, target = pick.target })
					return true
				end
				local pc = geom.edgePiece(e)
				local t = geom.closestT(pc, x, y)
				-- the handle starts 120 m along and 8 m to the side (a gentle branch, ~900 m radius)
				local p = geom.point(pc, t)
				local d = trackbuild.unit(geom.tangent(pc, t))
				local s = opts.side == 2 and 1 or -1
				costState:set(0)
				errorState:set("")
				pickState:set({ edge = entity, t = t, ex = p.x + d.x * 120 - d.y * 8 * s, ey = p.y + d.y * 120 + d.x * 8 * s, extras = {} })
				return true
			end,
			onProcessMouseEvent = function(evt : Gui.Mouse.Event) : boolean
				return handles.mouse(evt, dragCtl)
			end,
			filter = g_host.isEdge,
		}) as Builtin.SelectorParam)
		if proposal then
			local id = string.format("ntools_junction,%s,%d,%.3f,%.1f,%.1f", _o, pick.edge, pick.t, pick.ex, pick.ey)
			for __, ex in ipairs(pick.extras or {}) do id = id .. "," .. tostring(ex) end
			if pick.target then id = id .. ",T" .. tostring(pick.target.node or pick.target.edge) .. "," .. string.format("%.3f", pick.target.t or 0) end
			children[#children + 1] = preview.viewer{
				proposal = proposal,
				anarchy = anarchy,
				onData = function(proposalData : ProposalData)
					if aliveRef:hasExpired() then return end
					costState:set(proposalData.costs)
					local msg = ""
					for __, m in ipairs(proposalData.errorState.messages) do msg = msg .. m .. " " end
					-- the preview judges without a Context; the build uses the game builders' one (it
					-- tidies the street graph round new switches): asked again that way, it may pass
					if msg ~= "" then
						pcall(function()
							local ctx = api.type.Context.new()
							ctx.player = api.engine.util.getPlayer()
							ctx.cleanupStreetGraph = true
							local pd = (api.engine.util.proposal.makeProposalData as function(SimpleProposal, Context) : ProposalData)(proposal, ctx)
							if pd and #(pd.errorState.messages or {}) == 0 then
								dbg("[network_tools] junction: refused in the preview, passes with the build's context")
								msg = ""
							end
						end)
					end
					-- (still refused: which new piece - the game asked part by part; first, before the
					-- debug below builds proposals of its own)
					if msg ~= "" then
						local dg = trackbuild.diagnose(id)
						if dg then msg = msg .. "\n" .. dg end
					end
					errorState:set(msg)
					if arc and msg ~= "" then
						-- (debug: the split alone - is it the split or the branch the game refuses?)
						local okS, sMsg = pcall(function() : string
							local b2 = trackbuild.new()
							local cut2 = b2.splitAt(pick.edge, { pick.t })
							if not cut2 then return "not split: " .. tostring(b2.why) end
							local pd = (api.engine.util.proposal.makeProposalData as function(SimpleProposal) : ProposalData)(b2.proposal())
							local m2 = ""
							for __, s2 in ipairs(pd.errorState.messages or {}) do m2 = m2 .. s2 .. " " end
							return m2 == "" and "ok" or m2
						end)
						dbg("[network_tools] junction split alone: " .. (okS and sMsg or ("check failed: " .. tostring(sMsg))))
						-- (debug: every new segment's fields, as the build spy logs the game's own)
						pcall(function()
							local function v3(v : Vec3f) : string return string.format("(%.1f %.1f %.2f)", v.x, v.y, v.z) end
							for __, s in ipairs(proposal.streetProposal.edgesToAdd as {Proposal.SegmentAndEntity}) do
								local c = s.comp
								dbg(string.format("[network_tools] junction seg %d: %d -> %d  p %s -> %s  t %s / %s  type %s typeIndex %s distance %s template %s style %s lanes %d",
									s.entity, c.node0, c.node1, v3(c.position0), v3(c.position1), v3(c.tangent0), v3(c.tangent1),
									tostring(s.type), tostring(c.typeIndex), tostring((c as {string : any}).distance), tostring(c.roadTemplate),
									tostring(c.roadStyle), #(c.laneConfigs or {})))
							end
						end)
					end
					if arc then
						dbg(string.format("[network_tools] junction preview: %s | segment %d at t %.3f, radius %.0f m, length %.1f m, turn %.1f deg",
							msg ~= "" and ((proposalData.errorState.critical and "CRITICAL " or "") .. msg) or "ok", pick.edge, pick.t,
							arc.radius == math.huge and 0 or arc.radius, arc.length,
							math.deg(math.acos(math.max(-1, math.min(1, arc.d.x * arc.de.x + arc.d.y * arc.de.y))))))
					end
				end,
				id = id,
			}
		end
		if #handleList > 0 then
			local c = handles.canvas()
			if arc then c.line(arc.p.x, arc.p.y, nil, arc.e.x, arc.e.y, nil, handles.colors.guide, 0.5) end
			c.handle(handleList[1], dragging == 1 and 2 or (hover == 1 and 1 or 0))
			local n = c.node()
			if n then children[#children + 1] = n end
		end

		local info = ""
		if arc then
			local r = arc.radius == math.huge and _("straight") or string.format("%d m", math.floor(arc.radius + 0.5))
			local L = arc.length + math.max(0, arc.tail or 0)
			info = string.format(_("Radius: %s   Length: %d m"), r, math.floor(L + 0.5))
			-- (the curve's speed limit, from the track type's own formula)
			if arc.speed then info = info .. "   " .. string.format(_("Speed: %d km/h"), math.floor(arc.speed + 0.5)) end
			if arc.fan then
				info = info .. "\n" .. string.format(_("Feeding %d station tracks: switches every %d m"), arc.fan, math.floor((arc.fanGap or 0) + 0.5))
				if (arc.steep or 0) > 0.001 then info = info .. "   " .. string.format(_("Steepest: %.1f%%"), arc.steep * 100) end
			elseif arc.toTarget then
				info = info .. "\n" .. _("Onto the track there (a switch)")
				if (arc.steep or 0) > 0.001 then info = info .. "   " .. string.format(_("Steepest: %.1f%%"), arc.steep * 100) end
			end
			if (opts.speed or 0) == 0 and arc.radius < (opts.minRadius or 300) then info = info .. "\n" .. _("Tight curve: trains will slow down here") end
		end
		if not pick then
			children[#children + 1] = g_host.tooltip(_("Click a track where the branch should leave it"), false, false)
		elseif why then
			children[#children + 1] = g_host.tooltip(why .. (info ~= "" and ("\n" .. info) or ""), false, true)
		elseif blocked then
			children[#children + 1] = g_host.tooltip(errorState:old() .. "\n" .. info, false, true, costState:old())
		else
			children[#children + 1] = g_host.tooltip(_("Drag the handle to shape the branch (drop it on a track to join it), click tracks beside it to branch them too, Build to build it") .. "\n" .. info, true, false, costState:old())
		end
		local lo = preview.leftover()
		if lo then children[#children + 1] = lo end
		local tags = preview.tags()
		if tags then children[#children + 1] = tags end
		local under = (shared.layerNode as function() : TreeNodeId)()
		if under then children[#children + 1] = under end
		return builtin.ActionDescriptor{
			tool = "construction-menu-perks",
			onBack = function() leave(params) end,
			crosshair = crosshair,
			terrainCirclePolicy = circle,
			children = children,
		}
	end

	params.setActionFn(actionFn, "NtoolsJunctionAction")
	return padMod.anchor(pad)
end)

return {
	init = init,
	opts = opts,
	JunctionActionRecipe = JunctionActionRecipe,
}
