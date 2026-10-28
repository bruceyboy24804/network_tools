-- Network Tools: Siding (Rail tab). Click a track where the siding leaves it: a turnout and a dead-end
-- track beside the line are shown, ending at a handle - drag it along to set the siding's length, and
-- to either side to choose the side (the length shows as you drag). Spacing and turnout length are
-- set in the panel.
--
-- An S-curve turnout, then a stub beside the line, both following its curves (the line is walked
-- from the switch, see walkLine - the Alongside modes too) (shared/ntools_trackbuild), with the
-- clicked track's type. The segment it leaves must carry no
-- signals.

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
	split : function(pc : Piece, ts : {number}) : {Piece}
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
	protectSwitch : function(seg : Engine.Entity, switchAtStart : boolean, dist : number, model : string)
	touch : function(node : Engine.Entity)
	want : function(edge : Engine.Entity, t : number) : string
	cutAll : function() : boolean
	cut : function(key : string) : Cut
	proposal : function() : SimpleProposal
	why : string
	deferSignals : boolean   -- signals placed after the build (trackbuild.placeSignals)
end

-- the tracks alongside (shared/ntools_alongside)
local record Lane
	edge : Engine.Entity
	off : number
end
local record Spot
	edge : Engine.Entity
	t : number
	pos : P3
	dir : P3
	grade : number
	node : Engine.Entity
	nodePos : P3
end
local record Alongside
	alongside : function(edge : Engine.Entity, p : P3, d : P3) : {Lane}
	trackAt : function(q : P3, d : P3) : Spot
	crossU : function(pc : Piece, base : P3, nx : number, ny : number, w : number) : number
end
local along_util = require "network_tools_1::/gui/construction/tools/shared/ntools_alongside.script.tl" as Alongside
local record TrackBuild
	new : function() : Builder
	unit : function(v : P3) : P3
	diagnose : function(key : string) : string   -- the refused piece of the previewed proposal
	deferredSignals : function() : {any}         -- signals kept back (Builder.deferSignals)
	placeSignals : function({any})                -- ... placed onto the built track
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

dbg("[network_tools] siding tool script loaded (v1)")
local g_lastPlanLog = ""

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

-- options (the panel; saved with the game): distance between the track centres and the turnout's
-- length (m); side 1 right / 2 left for where a click puts the handle to start with
local record Options
	spacing : number
	turnout : number    -- (older: a fixed turnout length; now from `radius`)
	radius : number     -- the turnouts' curve radius (m)
	side : integer
	count : integer     -- sidings per side (each off the one before, a small yard ladder)
	both : boolean      -- the same on the other side of the line too
	alongside : integer -- tracks alongside: 0 off (just the clicked one), 1 a siding off the
	                    -- outermost track on each side, 2 one per track side by side (crossing the
	                    -- tracks between), 3 one beside the outermost, reached from the clicked track
	rejoin : boolean    -- (the panel: Rejoin with handles) a passing loop: it rejoins the line at
	                    -- the end handle; a second handle moves the start switch along the line
	speed : number      -- turnout speed km/h: the turnouts' radius for it (the track type's own
	                    -- formula, shared/ntools_speed) instead of `radius`; 0 = use `radius`
	signals : boolean   -- a signal short of each switch on the new track: a siding's exit, a passing
	                    -- loop's two ends - for trains heading out onto the line
	signalModel : string
	sigDist : number    -- how far short of the switch (m)
	feedAll : boolean   -- Dead end dropped on a station's track end: a siding to every open track at
	                    -- that end (the handle's side; Both: both sides). nil = on
	feedStyle : integer -- ... how: 1 nested (each siding off the line), 2 ladder (each off the one
	                    -- inside it), 3 diagonal (a straight throat track, a switch per track)
	feedCross : boolean -- ... a double-track line, both sides: two crossovers between the mains first
	                    -- (every platform from / to either main). nil = on
end
local opts : Options = { spacing = 5, turnout = 40, side = 1, count = 1, both = false, alongside = 0, radius = 300, rejoin = false, speed = 0,
	signals = false, signalModel = nil, sigDist = 10, feedAll = true, feedStyle = 1, feedCross = true }
-- the signal model when Signals is on (nil: none)
local function sigModel() : string return opts.signals and opts.signalModel or nil end

local record TrackLimits
	a : number
	b : number
	c : number
	minR : number
end
local record Speed
	limitsOf : function(e : Engine.Component.BaseEdge) : TrackLimits
	speedAt : function(lim : TrackLimits, r : number) : number
	radiusFor : function(lim : TrackLimits, kmh : number) : number
	verdictWithCleanup : function(proposal : SimpleProposal) : string
	buildContext : function() : Context
end
local speedUtil = require "network_tools_1::/gui/construction/tools/shared/ntools_speed.script.tl" as Speed

-- the turnouts' radius for this plan: the turnout speed's (for the clicked track's type), else the
-- panel's Switch radius (set by plan)
local g_turnR = 300.0

-- A turnout (an S-curve) moving `lat` metres across bends at about length^2 / (6 lat): its length
-- for the chosen radius (a fixed 40 m turnout bent at ~50 m - "Too Much Curvature")
local function turnLen(lat : number) : number
	return math.max(20, math.sqrt(6 * math.abs(lat) * math.max(50, g_turnR or opts.radius or 300)))
end

-- sets g_turnR for a plan off this segment; the turnouts' speed (km/h, nil: unknown type)
local function setTurnRadius(e : Engine.Component.BaseEdge) : number
	local lim = speedUtil.limitsOf(e)
	local r = (opts.speed or 0) > 0 and speedUtil.radiusFor(lim, opts.speed) or nil
	g_turnR = r or opts.radius or 300
	return speedUtil.speedAt(lim, g_turnR)
end

local record Pick
	edge : Engine.Entity
	t : number
	ex : number    -- the handle (the siding's end)
	ey : number
end

-- The siding from the pick to its handle: the switch point and direction (towards the handle), the
-- turnout's end, the stub's end, its usable length. nil and why if it can't.
local record Arc
	p : P3
	d : P3
	q : P3
	e : P3
	length : number
	grade : number   -- the track's gradient at the switch, along d (the siding carries it on)
	side : integer   -- the handle's side (+1 left of d)
	along : number   -- the handle's distance along the track from the switch
	joins : boolean  -- Dead end: the siding ends on a platform track's end (the handle dropped there)
	feeds : integer  -- ... Feed every track: how many station tracks it feeds
	crossovers : boolean -- ... with crossovers between a double-track line's mains first
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
	local vx, vy = pk.ex - p.x, pk.ey - p.y
	local along = vx * d.x + vy * d.y
	if along < 0 then d = { x = -d.x, y = -d.y, z = 0 }; along = -along; grade = -grade end
	-- (the side the handle is on: left of d is (-d.y, d.x))
	local side = (-d.y * vx + d.x * vy) >= 0 and 1 or -1
	local nx, ny = -d.y * side, d.x * side
	local s = math.max(3.5, opts.spacing or 5)
	local T = turnLen(s)
	if along < T + 10 then return nil, _("Drag the handle further along the track") end
	-- (the siding keeps the track's gradient: a level branch off a sloping track is refused)
	local q : P3 = { x = p.x + d.x * T + nx * s, y = p.y + d.y * T + ny * s, z = p.z + grade * T }
	local far : P3 = { x = p.x + d.x * along + nx * s, y = p.y + d.y * along + ny * s, z = p.z + grade * along }
	return { p = p, d = d, q = q, e = far, length = along - T, grade = grade, side = side, along = along }, nil
end

-- The line followed from the switch: a frame every WALK_STEP metres along the track (its point,
-- unit direction, gradient), so a siding off a curved line curves with it
local WALK_STEP = 10
local WALK_MAX = 3000
local MIN_SIDING_R = 60 -- metres: tightest curve a siding may have (inside a bend: the line's radius less its offset)
local record Frame
	pos : P3
	dir : P3
	grade : number
	along : number
end
-- walks from P along d until it is level with (x, y): the frames, and how far along that is; nil
-- and why if the track ends (or bends too sharply to follow) before
local function walkLine(P : P3, d : P3, grade : number, x : number, y : number) : {Frame}, number, string
	local frames : {Frame} = { { pos = P, dir = d, grade = grade, along = 0 } }
	local cur = frames[1]
	while cur.along < WALK_MAX do
		-- (level with the handle: it is no longer ahead of this frame)
		local ahead = (x - cur.pos.x) * cur.dir.x + (y - cur.pos.y) * cur.dir.y
		if ahead <= WALK_STEP then
			local a = cur.along + math.max(0, ahead)
			if ahead > 0.5 then
				local spot = along_util.trackAt({ x = cur.pos.x + cur.dir.x * ahead, y = cur.pos.y + cur.dir.y * ahead, z = cur.pos.z }, cur.dir)
				if not spot then return nil, nil, _("The track ends (or bends away) before the handle - drag it back") end
				frames[#frames + 1] = { pos = spot.pos, dir = spot.dir, grade = spot.grade, along = a }
			end
			return frames, a, nil
		end
		local spot = along_util.trackAt({ x = cur.pos.x + cur.dir.x * WALK_STEP, y = cur.pos.y + cur.dir.y * WALK_STEP, z = cur.pos.z }, cur.dir)
		if not spot then return nil, nil, _("The track ends (or bends away) before the handle - drag it back") end
		cur = { pos = spot.pos, dir = spot.dir, grade = spot.grade, along = cur.along + WALK_STEP }
		frames[#frames + 1] = cur
	end
	return nil, nil, _("Drag the handle nearer - the siding would be too long")
end

-- the line's frame `a` metres along (between two walked frames)
local function frameAt(frames : {Frame}, a : number) : Frame
	local i = 1
	while i < #frames and frames[i + 1].along < a do i = i + 1 end
	local f0, f1 = frames[i], frames[math.min(i + 1, #frames)]
	local span = f1.along - f0.along
	local k = span > 1e-6 and math.max(0, math.min(1, (a - f0.along) / span)) or 0
	local function mix(u : number, v : number) : number return u + (v - u) * k end
	return {
		pos = { x = mix(f0.pos.x, f1.pos.x), y = mix(f0.pos.y, f1.pos.y), z = mix(f0.pos.z, f1.pos.z) },
		dir = trackbuild.unit({ x = mix(f0.dir.x, f1.dir.x), y = mix(f0.dir.y, f1.dir.y), z = 0 }),
		grade = mix(f0.grade, f1.grade),
		along = a,
	}
end

-- `lat` metres beside the line at `a` along, on side sg (+1 left of the direction)
local function besideAt(frames : {Frame}, a : number, lat : number, sg : integer) : P3, Frame
	local f = frameAt(frames, a)
	return { x = f.pos.x - f.dir.y * sg * lat, y = f.pos.y + f.dir.x * sg * lat, z = f.pos.z }, f
end

-- a piece's tangent length: its own arc's length from its ends and their directions (beside a
-- bend a piece is shorter (inside) or longer (outside) than the line - the line's length kinks it:
-- "Too Much Curvature")
-- (exact for a circular arc: a Hermite curve with tangents 4 r tan(th / 4) = chord / cos^2(th / 4)
-- long follows the arc - the arc's length, which was used before, is a little short: the piece
-- bends tighter in its middle than the radius planned)
local function tanLen(p0 : P3, d0 : P3, p1 : P3, d1 : P3) : number
	local chord = math.sqrt((p1.x - p0.x) ^ 2 + (p1.y - p0.y) ^ 2)
	local c = math.max(-1, math.min(1, d0.x * d1.x + d0.y * d1.y))
	local th = math.acos(c)
	if th < 1e-3 then return chord end
	local q = math.cos(th / 4)
	return chord / (q * q)
end

-- why a siding `lat` across on side sg can't run from a0 to a1 along the line: inside a bend its
-- curve is the line's radius less lat - too tight below MIN_SIDING_R. nil if it can
local function curveWhy(frames : {Frame}, a0 : number, a1 : number, lat : number, sg : integer) : string
	for i = 1, #frames - 1 do
		local f0, f1 = frames[i], frames[i + 1]
		if f1.along > a0 and f0.along < a1 then
			local step = f1.along - f0.along
			local turn = f0.dir.x * f1.dir.y - f0.dir.y * f1.dir.x   -- (+: the line bends left)
			local c = math.max(-1, math.min(1, f0.dir.x * f1.dir.x + f0.dir.y * f1.dir.y))
			local th = math.acos(c)
			if step > 1 and th > 1e-4 and turn * sg > 0 then
				local R = step / th
				if R - lat < MIN_SIDING_R then
					return string.format(_("The line bends too tightly here for a siding on the inside (about %d m: under %d m) - build it on the outside, or with less spacing"),
						math.floor(R - lat + 0.5), MIN_SIDING_R)
				end
			end
		end
	end
	return nil
end

-- why a turnout from a0 to a1 (`lat` across at its end) can't be built: its S-curve bends at about
-- the Switch radius on top of the line's own bend - where they add up (half the S bends the line's
-- way) under MIN_SIDING_R. nil if it can
local function turnoutWhy(frames : {Frame}, a0 : number, a1 : number, lat : number) : string
	local rs = math.max(50, g_turnR or opts.radius or 300)
	for i = 1, #frames - 1 do
		local f0, f1 = frames[i], frames[i + 1]
		if f1.along > a0 and f0.along < a1 then
			local step = f1.along - f0.along
			local c = math.max(-1, math.min(1, f0.dir.x * f1.dir.x + f0.dir.y * f1.dir.y))
			local th = math.acos(c)
			if step > 1 and th > 1e-4 then
				local R = math.max(1, step / th - lat)
				local comb = 1 / (1 / R + 1 / rs)
				if comb < MIN_SIDING_R then
					return string.format(_("The switch curve on top of the line's bend is too tight here (about %d m) - click on a straighter part, or use a wider Switch radius"),
						math.floor(comb + 0.5))
				end
			end
		end
	end
	return nil
end

-- Where a run beside the line (from aStart to aEnd along it, lat across on side sg) needs its nodes:
-- only where one curved piece can't follow it any more (the run sampled every 4 m; each piece grown
-- while the Hermite piece between its ends - their directions, the exact arc tangent - stays within
-- 0.1 m of every sample, under 80 m and 45 degrees of turn). A straight or an even curve: few long
-- pieces; where the line's curvature changes: more. The along values after aStart, aEnd last
local function runStops(frames : {Frame}, aStart : number, aEnd : number, lat : number, sg : integer) : {number}
	local L = aEnd - aStart
	if L <= 4 then return { aEnd } end
	local n = math.max(2, math.ceil(L / 4))
	local P : {P3} = {}
	local Dr : {P3} = {}
	local al : {number} = {}
	for i = 0, n do
		local a = aStart + L * i / n
		local p, f = besideAt(frames, a, lat, sg)
		P[#P + 1], Dr[#Dr + 1], al[#al + 1] = p, f.dir, a
	end
	-- does one piece from sample i to j follow every sample between?
	local function fits(i : integer, j : integer) : boolean
		if al[j] - al[i] > 80 then return false end
		if Dr[i].x * Dr[j].x + Dr[i].y * Dr[j].y < math.cos(math.rad(45)) then return false end
		local t = tanLen(P[i], Dr[i], P[j], Dr[j])
		local pc : Piece = { p0 = P[i], t0 = { x = Dr[i].x * t, y = Dr[i].y * t, z = 0 }, p1 = P[j], t1 = { x = Dr[j].x * t, y = Dr[j].y * t, z = 0 } }
		for k = i + 1, j - 1 do
			local q = geom.point(pc, (al[k] - al[i]) / (al[j] - al[i]))
			if (q.x - P[k].x) ^ 2 + (q.y - P[k].y) ^ 2 > 0.01 then return false end
		end
		return true
	end
	local out : {number} = {}
	local i = 1
	while i < #P do
		local j = i + 1
		while j < #P and fits(i, j + 1) do j = j + 1 end
		out[#out + 1] = al[j]
		i = j
	end
	return out
end

-- the line walked further back, to `a` (negative: behind the switch) - as far as the track goes
local function walkBack(frames : {Frame}, a : number) : {Frame}
	local f0 = frames[1]
	local back : {Frame} = {}
	local cur : Frame = { pos = f0.pos, dir = { x = -f0.dir.x, y = -f0.dir.y, z = 0 }, grade = -f0.grade, along = f0.along }
	while cur.along > a do
		local spot = along_util.trackAt({ x = cur.pos.x + cur.dir.x * WALK_STEP, y = cur.pos.y + cur.dir.y * WALK_STEP, z = cur.pos.z }, cur.dir)
		if not spot then break end
		cur = { pos = spot.pos, dir = spot.dir, grade = spot.grade, along = cur.along - WALK_STEP }
		back[#back + 1] = cur
	end
	local out : {Frame} = {}
	for i = #back, 1, -1 do
		local f = back[i]
		out[#out + 1] = { pos = f.pos, dir = { x = -f.dir.x, y = -f.dir.y, z = 0 }, grade = -f.grade, along = f.along }
	end
	for __, f in ipairs(frames) do out[#out + 1] = f end
	return out
end

-- how far across the line (on side sg) a point is, and how far along (aGuess: near where it is)
local function latOf(frames : {Frame}, x : P3, aGuess : number, sg : integer) : number, number
	local a = aGuess
	for __ = 1, 3 do
		local f = frameAt(frames, a)
		a = a + (x.x - f.pos.x) * f.dir.x + (x.y - f.pos.y) * f.dir.y
	end
	local f = frameAt(frames, a)
	return ((x.x - f.pos.x) * -f.dir.y + (x.y - f.pos.y) * f.dir.x) * sg, a
end

-- where a turnout (from a0 along, T long) is wl across the line: its parameter and how far along,
-- or nil (as along_util.crossU, but across the curved line)
local function crossUCurved(pc : Piece, frames : {Frame}, a0 : number, T : number, sg : integer, wl : number) : number, number
	local N = 40
	local prevU, prevL = 0.0, (latOf(frames, pc.p0, a0, sg))
	for i = 1, N do
		local u = i / N
		local l = latOf(frames, geom.point(pc, u), a0 + u * T, sg)
		if (prevL - wl) * (l - wl) <= 0 then
			local lo, hi = prevU, u
			for __ = 1, 20 do
				local mid = (lo + hi) / 2
				local lm = latOf(frames, geom.point(pc, mid), a0 + mid * T, sg)
				if (prevL - wl) * (lm - wl) <= 0 then hi = mid else lo, prevL = mid, lm end
			end
			local _l, a = latOf(frames, geom.point(pc, hi), a0 + hi * T, sg)
			return hi, a
		end
		prevU, prevL = u, l
	end
	return nil, nil
end

-- One siding of the Alongside modes: from a switch on a track (an existing node, or a deferred
-- cut on it), a turnout S-curve out to `w` metres across from the clicked track's line, crossing
-- the tracks in between (a node shared with each), then a stub beside the line to the handle. All
-- along the line as walked, so it follows its curves.
local record Run
	key : string            -- the switch: a deferred cut ...
	node : Engine.Entity    -- ... or an existing node
	pos : P3
	grade : number
	dir : P3                -- the switch track's direction there
	a0 : number             -- where the switch is, along the line from the clicked point
	w : number              -- how far across the siding runs
	sg : integer            -- its side (+1 left of the line)
	T : number              -- its turnout's length (from how far across it moves, and the radius)
	pc : Piece              -- the turnout
	crossU : {number}       -- the turnout's parameters where it crosses tracks
	crossKey : {string}
end

-- mode: as opts.alongside (1 Outer, 2 Bundle, 3 Across), or 4: off the outermost track on the
-- handle's side only (Off on a multi-track line)
local function planAlongside(pk : Pick, arc : Arc, frames : {Frame}, mode : integer) : SimpleProposal, string
	local d, P = arc.d, arc.p
	local s = math.max(3.5, opts.spacing or 5)
	local lanes = along_util.alongside(pk.edge, P, d)
	local b = trackbuild.new()
	local ref = g_host.getEdge(pk.edge)
	local runs : {Run} = {}
	-- a siding from the track `off` across (+ left of the line) whose switch is a0 along, out to w
	-- across (both from the clicked track's line, on side sg)
	local count = math.max(1, math.min(6, math.floor(opts.count or 1)))
	local Tl = turnLen(s)   -- (a ladder siding's turnout: one spacing across)
	local function addRun(off : number, a0 : number, sg : integer, w : number) : string
		if a0 < frames[1].along - 0.5 then frames = walkBack(frames, a0 - WALK_STEP) end
		if a0 < frames[1].along - 0.5 then return _("The track behind ends (or bends away) where a switch must go - click further along") end
		local T = turnLen(w - off * sg)
		local r : Run = { a0 = a0, w = w, sg = sg, T = T, crossU = {}, crossKey = {} }
		if off == 0 and a0 == 0 then
			r.key, r.pos, r.grade, r.dir = b.want(pk.edge, pk.t), P, arc.grade, d
		else
			local q, f = besideAt(frames, a0, off, 1)
			local spot = along_util.trackAt(q, f.dir)
			if not spot then return _("A track alongside ends (or bends away) where a switch must go - click elsewhere") end
			if spot.node then r.node, r.pos = spot.node, spot.nodePos else r.key, r.pos = b.want(spot.edge, spot.t), spot.pos end
			r.grade, r.dir = spot.grade, spot.dir
		end
		-- the turnout, and where it crosses the tracks between its own and its end
		local whyC = curveWhy(frames, a0, arc.along, w + (count - 1) * s, sg) or turnoutWhy(frames, a0, a0 + T, w)
		if whyC then return whyC end
		local Q, fQ = besideAt(frames, a0 + T, w, sg)
		local tT = tanLen(r.pos, r.dir, Q, fQ.dir)
		r.pc = { p0 = r.pos, t0 = { x = r.dir.x * tT, y = r.dir.y * tT, z = r.grade * tT },
			p1 = Q, t1 = { x = fQ.dir.x * tT, y = fQ.dir.y * tT, z = fQ.grade * tT } }
		local wS = off * sg
		for __, ln in ipairs(lanes) do
			local wl = ln.off * sg
			if wl > wS + 0.5 and wl < w - 0.5 then
				local u, ax = crossUCurved(r.pc, frames, a0, T, sg, wl)
				if not u then return _("Can't find where a siding crosses a track") end
				local x = geom.point(r.pc, u)
				local spot = along_util.trackAt(x, frameAt(frames, ax).dir)
				if not spot then return _("A siding crosses a track beyond its segment - click elsewhere") end
				r.crossU[#r.crossU + 1] = u
				r.crossKey[#r.crossKey + 1] = b.want(spot.edge, spot.t)
			end
		end
		runs[#runs + 1] = r
		return nil
	end
	local sg = arc.side
	local why : string = nil
	if mode == 5 then mode = 1 end
	if mode == 4 then
		-- the outermost track on the handle's side: a siding off it, outwards
		local out = lanes[1]
		for __, ln in ipairs(lanes) do if ln.off * sg > out.off * sg then out = ln end end
		why = addRun(out.off, 0, sg, out.off * sg + s)
	elseif mode == 1 then
		-- each side's outermost track: a siding off it, outwards
		-- (a single track: just the handle's side - one switch can't feed both)
		local lo, hi = lanes[1], lanes[#lanes]
		if #lanes == 1 then
			why = addRun(0, 0, sg, s)
		else
			why = addRun(hi.off, 0, 1, hi.off + s)
			if not why then why = addRun(lo.off, 0, -1, -lo.off + s) end
		end
	elseif mode == 3 then
		-- one siding beside the outermost track on the handle's side, from the clicked track
		local wmax = 0.0
		for __, ln in ipairs(lanes) do wmax = math.max(wmax, ln.off * sg) end
		why = addRun(0, 0, sg, wmax + s)
	else
		-- one per track, side by side: the track nearest the siding side first (innermost siding),
		-- each next one's switch a turnout's length further back, so its turnout ends before the
		-- one inside it starts
		local order : {Lane} = {}
		for __, ln in ipairs(lanes) do order[#order + 1] = ln end
		table.sort(order, function(a : Lane, c : Lane) : boolean return a.off * sg > c.off * sg end)
		local wmax = order[1].off * sg
		-- (each next turnout ends where the one before starts: its switch its own length further back;
		-- each track's ladder of `count` sidings has its own band of places across)
		local a0 = 0.0
		for r, ln in ipairs(order) do
			local w = wmax + s * ((r - 1) * count + 1)
			if r > 1 then a0 = a0 - turnLen(w - ln.off * sg) end
			why = why or addRun(ln.off, a0, sg, w)
		end
	end
	if why then return nil, why end
	if not b.cutAll() then return nil, b.why end
	for __, r in ipairs(runs) do
		local n0 = r.node or b.cut(r.key).node
		if r.node then b.touch(r.node) end
		-- the turnout in pieces between its crossings
		local us : {number} = {}
		local keys : {string} = {}
		for k, u in ipairs(r.crossU) do us[k], keys[k] = u, r.crossKey[k] end
		local idx : {integer} = {}
		for k in ipairs(us) do idx[k] = k end
		table.sort(idx, function(a : integer, c : integer) : boolean return us[a] < us[c] end)
		local sorted : {number} = {}
		for k, ix in ipairs(idx) do sorted[k] = us[ix] end
		local parts = #sorted > 0 and geom.split(r.pc, sorted) or { r.pc }
		local prevNode, prevPos = n0, r.pos
		for k, part in ipairs(parts) do
			local node : Engine.Entity
			local pos : P3
			if k <= #sorted then
				local c = b.cut(keys[idx[k]])
				node, pos = c.node, c.pos
			else
				pos = r.pc.p1
				node = b.node(pos)
			end
			local sp = b.segment(prevNode, prevPos, part.t0, node, pos, part.t1, ref)
			-- (the siding's exit: its turnout's first piece, short of the switch)
			if k == 1 then b.protectSwitch(sp, true, opts.sigDist, sigModel()) end
			prevNode, prevPos = node, pos
		end
		-- the stub, and the ladder: each next siding off the one before (at its turnout's end), one
		-- spacing further out, its stub ending level with the handle too - all beside the line
		local qNode, qPos = prevNode, r.pc.p1
		local aQ = r.a0 + r.T
		local lat = r.w
		local fQ = frameAt(frames, aQ)
		for k = 1, count do
			if k > 1 then
				local q2, f2 = besideAt(frames, aQ + Tl, lat + s, r.sg)
				local q2n = b.node(q2)
				local tL = tanLen(qPos, fQ.dir, q2, f2.dir)
				local sL = b.segment(qNode, qPos, { x = fQ.dir.x * tL, y = fQ.dir.y * tL, z = fQ.grade * tL },
					q2n, q2, { x = f2.dir.x * tL, y = f2.dir.y * tL, z = f2.grade * tL }, ref)
				b.protectSwitch(sL, true, opts.sigDist, sigModel())
				qNode, qPos, aQ, lat, fQ = q2n, q2, aQ + Tl, lat + s, f2
			end
			local L = arc.along - aQ
			if L < 5 then
				return nil, string.format(_("Drag the handle further along the track - these sidings need about %d m"), math.floor(aQ - math.min(0, r.a0) + 10))
			end
			local pn, pp, pf = qNode, qPos, fQ
			for __, aS in ipairs(runStops(frames, aQ, aQ + L, lat, r.sg)) do
				local e, fe = besideAt(frames, aS, lat, r.sg)
				local en = b.node(e)
				local len = tanLen(pp, pf.dir, e, fe.dir)
				b.segment(pn, pp, { x = pf.dir.x * len, y = pf.dir.y * len, z = pf.grade * len },
					en, e, { x = fe.dir.x * len, y = fe.dir.y * len, z = fe.grade * len }, ref)
				pn, pp, pf = en, e, fe
			end
		end
	end
	return b.proposal(), b.why
end

-- Rejoin (a passing loop between the two handles): from a switch at the start handle, a turnout out
-- beside the line, a run beside it following its curves, and a turnout back in to a switch level
-- with the end handle. Tracks > 1: each next loop off the one before, its turnouts nested inside
-- (it leaves where the one before has turned out, and rejoins where that one starts back).
-- mode: 0 the clicked track (Both sides: also the other side, its switches T + 5 further in),
-- 1 off each outer track (Outer / Mirror), 4 off the outermost track on the handle's side
-- the line walked further on, to `a` - as far as the track goes
local function walkAhead(frames : {Frame}, a : number) : {Frame}
	local cur = frames[#frames]
	while cur.along < a do
		local spot = along_util.trackAt({ x = cur.pos.x + cur.dir.x * WALK_STEP, y = cur.pos.y + cur.dir.y * WALK_STEP, z = cur.pos.z }, cur.dir)
		if not spot then break end
		cur = { pos = spot.pos, dir = spot.dir, grade = spot.grade, along = cur.along + WALK_STEP }
		frames[#frames + 1] = cur
	end
	return frames
end

-- Rejoin, Bundle / Across: passing loops whose turnouts cross the tracks between their own track and
-- the loop (flat crossings, a node shared with each). Across: one loop beside the outermost track
-- on the handle's side, from the clicked track. Bundle: one loop per track on that side, side by
-- side beyond the outermost - the inner tracks' switches further back at the start and further on
-- at the end, so no turnout overlaps another. Sidings: that many loops per track (Across: beside the
-- outermost), stacked the same way.
-- Start side Both (both sides, mirrored - each side's loops measured outwards on that side):
--   Bundle: every track gets a loop on each side
--   Across: each side's loop leaves the track furthest from it, crossing the others
--   Outer (mode 1): each side's outermost track's loop, plus one from the opposite outermost track
--     crossing over (on a double track the same as Bundle)
-- The second side's switches sit further in (past the first side's turnouts at both ends): two
-- crossing turnouts over the same stretch between the tracks would cross each other too.
local function planRejoinCross(pk : Pick, arc : Arc, frames : {Frame}, mode : integer) : SimpleProposal, string
	local s = math.max(3.5, opts.spacing or 5)
	local A = arc.along
	local lanes = along_util.alongside(pk.edge, arc.p, arc.d)
	local b = trackbuild.new()
	-- (signals after the build: these crossings only pass with the game's cleanup, which refuses
	-- them with signals in the same proposal)
	b.deferSignals = true
	local ref = g_host.getEdge(pk.edge)
	-- the loops: the track each leaves (off, + left of the line), its side, how far out it runs,
	-- where its switches are along the line
	local record XLoop
		off : number
		sg : integer
		w : number
		a0 : number   -- entry switch
		a1 : number   -- exit switch
		T : number
	end
	local loops : {XLoop} = {}
	local both = opts.both == true
	local sideList : {integer} = both and { arc.side, -arc.side } or { arc.side }
	local inset = 0.0   -- the second side's switches: this much further in at both ends
	for si, sg in ipairs(sideList) do
		local wmax = -math.huge
		local far : Lane = nil       -- the track furthest from this side
		for __, ln in ipairs(lanes) do
			wmax = math.max(wmax, ln.off * sg)
			if not far or ln.off * sg < far.off * sg then far = ln end
		end
		-- the tracks this side's loops leave, outermost (on this side) first, and their stacking
		local srcs : {Lane} = {}
		if mode == 3 then
			-- (one side only: from the clicked track, as before; both: from the far track)
			srcs[1] = both and far or { edge = pk.edge, off = 0 }
		elseif mode == 1 then
			local out : Lane = nil
			for __, ln in ipairs(lanes) do if not out or ln.off * sg > out.off * sg then out = ln end end
			srcs[1] = out
			if far and far ~= out then srcs[2] = far end
		else
			for __, ln in ipairs(lanes) do
				if both or ln.off * sg >= -0.5 then srcs[#srcs + 1] = ln end
			end
			table.sort(srcs, function(x : Lane, y : Lane) : boolean return x.off * sg > y.off * sg end)
		end
		-- Sidings: that many loops per track, side by side (each further out leaves a turnout length
		-- further back, and is out at its place before the one inside it starts: none cross)
		local count = math.max(1, math.min(6, math.floor(opts.count or 1)))
		if count > 1 then
			local rep : {Lane} = {}
			for __, ln in ipairs(srcs) do
				for __ = 1, count do rep[#rep + 1] = ln end
			end
			srcs = rep
		end
		local back = 0.0
		local sideMaxBack = 0.0
		local first = #loops + 1
		for r, ln in ipairs(srcs) do
			local w = wmax + s * r
			local T = turnLen(w - ln.off * sg)
			if r > 1 then back = back + T end
			loops[#loops + 1] = { off = ln.off, sg = sg, w = w, a0 = -back, a1 = A + back, T = T }
			sideMaxBack = math.max(sideMaxBack, back + T)
		end
		-- The second side's switches further in. What must not meet is the two sides' turnouts that
		-- cross the gap between the tracks: the first side's are all done by the handle (each crossing
		-- loop leaves a turnout length further back than the one inside it). But this side's outermost
		-- switch sits on the track the first side's innermost loop leaves at the handle: past that
		-- turnout (a switch inside another's diverging part is refused - 15 m on was). (A single
		-- track: both sides' loops leave it - past the first side's turnouts altogether.)
		if si == 2 then
			inset = #lanes > 1 and (back + loops[1].T + 5) or (inset + 10)
			for k = first, #loops do
				loops[k].a0 = loops[k].a0 + inset
				loops[k].a1 = loops[k].a1 - inset
			end
		elseif si == 1 then
			inset = sideMaxBack
		end
	end
	-- (debug: what was found alongside and planned - once per change)
	do
		local parts : {string} = {}
		for __, ln in ipairs(lanes) do parts[#parts + 1] = string.format("%d@%.1f", ln.edge, ln.off) end
		local lps : {string} = {}
		for __, lp in ipairs(loops) do lps[#lps + 1] = string.format("[from %.1f side %d out %.1f sw %.0f..%.0f]", lp.off, lp.sg, lp.w, lp.a0, lp.a1) end
		local text = string.format("mode %d both %s side %d: tracks %s; loops %s", mode, tostring(both), arc.side,
			table.concat(parts, " "), table.concat(lps, " "))
		if text ~= g_lastPlanLog then g_lastPlanLog = text; dbg("[network_tools] siding rejoin: " .. text) end
	end
	if #loops == 0 then return nil, _("No track on the handle's side to loop") end
	-- the line walked as far back / on as the outer switches need
	local aMin, aMax = 0.0, A
	for __, lp in ipairs(loops) do aMin, aMax = math.min(aMin, lp.a0), math.max(aMax, lp.a1) end
	if aMin < frames[1].along - 0.5 then frames = walkBack(frames, aMin - WALK_STEP) end
	if aMax > frames[#frames].along + 0.5 then frames = walkAhead(frames, aMax + WALK_STEP) end
	if aMin < frames[1].along - 0.5 or aMax > frames[#frames].along + 0.5 then
		return nil, _("The tracks end (or bend away) where the outer loops' switches must go - move the handles in")
	end
	arc.length = A
	local record Sw
		key : string
		node : Engine.Entity
		pos : P3
		dir : P3
		grade : number
	end
	local function switchAt(off : number, a : number) : Sw, string
		if off == 0 and math.abs(a) < 1e-6 then
			return { key = b.want(pk.edge, pk.t), pos = arc.p, dir = arc.d, grade = arc.grade }, nil
		end
		local q, f = besideAt(frames, a, off, 1)
		local spot = along_util.trackAt(q, f.dir)
		if not spot then return nil, _("A track ends (or bends away) where a switch must go - move the handles") end
		local sw : Sw = { pos = spot.node and spot.nodePos or spot.pos, dir = spot.dir, grade = spot.grade }
		if spot.node then sw.node = spot.node else sw.key = b.want(spot.edge, spot.t) end
		return sw, nil
	end
	-- a turnout from p0 to p1 (a0 along, T long) and where it crosses the tracks between lateral
	-- latA and latB: its piece, and the crossings' parameters and cut keys
	local record Turn
		pc : Piece
		us : {number}
		keys : {string}
	end
	local function turnout(p0 : P3, d0 : P3, g0 : number, p1 : P3, d1 : P3, g1 : number, a0 : number, T : number, latA : number, latB : number, sg : integer) : Turn, string
		local L = tanLen(p0, d0, p1, d1)
		local tn : Turn = { pc = { p0 = p0, t0 = { x = d0.x * L, y = d0.y * L, z = g0 * L }, p1 = p1, t1 = { x = d1.x * L, y = d1.y * L, z = g1 * L } }, us = {}, keys = {} }
		local lo, hi = math.min(latA, latB), math.max(latA, latB)
		for __, ln in ipairs(lanes) do
			local wl = ln.off * sg
			if wl > lo + 0.5 and wl < hi - 0.5 then
				local u, ax = crossUCurved(tn.pc, frames, a0, T, sg, wl)
				if not u then return nil, _("Can't find where a loop crosses a track") end
				local spot = along_util.trackAt(geom.point(tn.pc, u), frameAt(frames, ax).dir)
				if not spot then return nil, _("A loop crosses a track beyond its segment - move the handles") end
				tn.us[#tn.us + 1] = u
				tn.keys[#tn.keys + 1] = b.want(spot.edge, spot.t)
			end
		end
		return tn, nil
	end
	local record Built
		s0 : Sw
		s1 : Sw
		tin : Turn
		tout : Turn
		qIn : P3
		qOut : P3
		fIn : Frame
		fOut : Frame
		w : number
		aIn : number   -- where the run beside the line starts / ends, along it
		aOut : number
		sg : integer
	end
	local built : {Built} = {}
	for __, lp in ipairs(loops) do
		local sg = lp.sg
		local wS = lp.off * sg
		local aIn, aOut = lp.a0 + lp.T, lp.a1 - lp.T
		if aOut - aIn < 5 then
			return nil, string.format(_("These loops need the handles further apart (about %d m more)"), math.ceil(aIn - aOut + 5))
		end
		local whyC = curveWhy(frames, lp.a0, lp.a1, lp.w, sg) or turnoutWhy(frames, lp.a0, aIn, lp.w) or turnoutWhy(frames, aOut, lp.a1, lp.w)
		if whyC then return nil, whyC end
		local s0, w0 = switchAt(lp.off, lp.a0)
		if not s0 then return nil, w0 end
		local s1, w1 = switchAt(lp.off, lp.a1)
		if not s1 then return nil, w1 end
		local qIn, fIn = besideAt(frames, aIn, lp.w, sg)
		local qOut, fOut = besideAt(frames, aOut, lp.w, sg)
		local tin, wi = turnout(s0.pos, s0.dir, s0.grade, qIn, fIn.dir, fIn.grade, lp.a0, lp.T, wS, lp.w, sg)
		if not tin then return nil, wi end
		local tout, wo = turnout(qOut, fOut.dir, fOut.grade, s1.pos, s1.dir, s1.grade, aOut, lp.T, lp.w, wS, sg)
		if not tout then return nil, wo end
		built[#built + 1] = { s0 = s0, s1 = s1, tin = tin, tout = tout, qIn = qIn, qOut = qOut, fIn = fIn, fOut = fOut, w = lp.w,
			aIn = aIn, aOut = aOut, sg = sg }
	end
	if not b.cutAll() then return nil, b.why end
	local function nodeOf(sw : Sw) : Engine.Entity
		if sw.node then b.touch(sw.node) return sw.node end
		return b.cut(sw.key).node
	end
	-- a turnout from node n0 to node n1, in pieces between its crossings; its first and last pieces
	local function buildTurn(tn : Turn, n0 : Engine.Entity, n1 : Engine.Entity) : Engine.Entity, Engine.Entity
		local idx : {integer} = {}
		for k in ipairs(tn.us) do idx[k] = k end
		table.sort(idx, function(x : integer, y : integer) : boolean return tn.us[x] < tn.us[y] end)
		local sorted : {number} = {}
		for k, ix in ipairs(idx) do sorted[k] = tn.us[ix] end
		local parts = #sorted > 0 and geom.split(tn.pc, sorted) or { tn.pc }
		local pn, pp = n0, tn.pc.p0
		local first, last : Engine.Entity, Engine.Entity
		for k, part in ipairs(parts) do
			local nn, np : Engine.Entity, P3
			if k <= #sorted then
				local c = b.cut(tn.keys[idx[k]])
				nn, np = c.node, c.pos
			else
				nn, np = n1, tn.pc.p1
			end
			last = b.segment(pn, pp, part.t0, nn, np, part.t1, ref)
			first = first or last
			pn, pp = nn, np
		end
		return first, last
	end
	for __, bl in ipairs(built) do
		local qn, qen = b.node(bl.qIn), b.node(bl.qOut)
		buildTurn(bl.tin, nodeOf(bl.s0), qn)
		-- the run beside the line
		-- (nodes only where the line bends - runStops; the last one the exit turnout's start)
		local stops = runStops(frames, bl.aIn, bl.aOut, bl.w, bl.sg)
		local pn, pp, pf = qn, bl.qIn, bl.fIn
		local runFirst, runLast : Engine.Entity, Engine.Entity
		for k, aS in ipairs(stops) do
			local e, f, en : P3, Frame, Engine.Entity
			if k == #stops then
				e, f, en = bl.qOut, bl.fOut, qen
			else
				e, f = besideAt(frames, aS, bl.w, bl.sg)
				en = b.node(e)
			end
			local len = tanLen(pp, pf.dir, e, f.dir)
			runLast = b.segment(pn, pp, { x = pf.dir.x * len, y = pf.dir.y * len, z = pf.grade * len },
				en, e, { x = f.dir.x * len, y = f.dir.y * len, z = f.grade * len }, ref)
			runFirst = runFirst or runLast
			pn, pp, pf = en, e, f
		end
		buildTurn(bl.tout, qen, nodeOf(bl.s1))
		-- the loop's exit signals at the ends of its run, short of the turnouts: a train waiting in
		-- the loop stands clear of them and of the tracks they cross. (On the turnouts' first pieces
		-- - between the switch and the first crossing, often a few metres - they sat in the gap
		-- between the tracks, or were left out.)
		b.protectSwitch(runFirst, true, opts.sigDist, sigModel())
		b.protectSwitch(runLast, false, opts.sigDist, sigModel())
	end
	return b.proposal(), b.why
end

local function planRejoin(pk : Pick, arc : Arc, frames : {Frame}, mode : integer) : SimpleProposal, string
	local s = math.max(3.5, opts.spacing or 5)
	local T = turnLen(s)
	local count = math.max(1, math.min(6, math.floor(opts.count or 1)))
	local A = arc.along
	local lanes = along_util.alongside(pk.edge, arc.p, arc.d)
	local sg = arc.side
	-- the loops to build: the track they leave (off across, + left), their side, how far in their
	-- switches are from the handles
	local record LoopRun
		off : number
		sg : integer
		shift : number
	end
	local list : {LoopRun} = {}
	-- Outer + Start side Both on a multi-track line: each side's outer track's loop plus one crossing
	-- over from the opposite outer track (planRejoinCross); 5 (Off on a multi-track line): plain Outer
	if mode == 1 and opts.both and #lanes > 1 then return planRejoinCross(pk, arc, frames, mode) end
	if mode == 5 then mode = 1 end
	if mode == 0 then
		list[1] = { off = 0, sg = sg, shift = 0 }
		if opts.both then list[2] = { off = 0, sg = -sg, shift = T + 5 } end
	elseif mode == 4 then
		local out = lanes[1]
		for __, ln in ipairs(lanes) do if ln.off * sg > out.off * sg then out = ln end end
		list[1] = { off = out.off, sg = sg, shift = 0 }
	elseif mode == 1 then
		if #lanes == 1 then
			list[1] = { off = 0, sg = sg, shift = 0 }
		else
			list[1] = { off = lanes[#lanes].off, sg = 1, shift = 0 }
			list[2] = { off = lanes[1].off, sg = -1, shift = 0 }
		end
	else
		-- Bundle / Across: loops crossing the tracks between
		return planRejoinCross(pk, arc, frames, mode)
	end
	local maxShift = 0.0
	for __, r in ipairs(list) do maxShift = math.max(maxShift, r.shift) end
	local need = 2 * (count * T + maxShift) + 10
	-- (shown: switch to switch - the part beside the line alone goes negative while the handles are
	-- too close for all the turnouts)
	arc.length = A
	if A < need then
		return nil, string.format(_("These loops need the handles at least %d m apart - drag them further"), math.floor(need))
	end
	local b = trackbuild.new()
	local ref = g_host.getEdge(pk.edge)
	-- a switch on the track `off` across, `a` along the line: the clicked spot, an existing node, or
	-- a cut to come
	local record Sw
		key : string
		node : Engine.Entity
		pos : P3
		dir : P3
		grade : number
	end
	local function switchAt(off : number, a : number) : Sw, string
		if off == 0 and a == 0 then
			return { key = b.want(pk.edge, pk.t), pos = arc.p, dir = arc.d, grade = arc.grade }, nil
		end
		local q, f = besideAt(frames, a, off, 1)
		local spot = along_util.trackAt(q, f.dir)
		if not spot then return nil, _("The track ends (or bends away) where a switch must go - move the handles") end
		local sw : Sw = { pos = spot.node and spot.nodePos or spot.pos, dir = spot.dir, grade = spot.grade }
		if spot.node then sw.node = spot.node else sw.key = b.want(spot.edge, spot.t) end
		return sw, nil
	end
	local sws : {{Sw}} = {}
	for i, r in ipairs(list) do
		local outer = r.off * r.sg + count * s
		local whyC = curveWhy(frames, r.shift, A - r.shift, outer, r.sg)
			or turnoutWhy(frames, r.shift, r.shift + count * T, outer)
			or turnoutWhy(frames, A - r.shift - count * T, A - r.shift, outer)
		if whyC then return nil, whyC end
		local s0, w0 = switchAt(r.off, r.shift)
		if not s0 then return nil, w0 end
		local s1, w1 = switchAt(r.off, A - r.shift)
		if not s1 then return nil, w1 end
		sws[i] = { s0, s1 }
	end
	if not b.cutAll() then return nil, b.why end
	local function nodeOf(sw : Sw) : Engine.Entity
		if sw.node then b.touch(sw.node) return sw.node end
		return b.cut(sw.key).node
	end
	-- one piece between two points with their directions and grades (its own arc length)
	local function piece(n0 : Engine.Entity, p0 : P3, d0 : P3, g0 : number, n1 : Engine.Entity, p1 : P3, d1 : P3, g1 : number) : Engine.Entity
		local L = tanLen(p0, d0, p1, d1)
		return b.segment(n0, p0, { x = d0.x * L, y = d0.y * L, z = g0 * L }, n1, p1, { x = d1.x * L, y = d1.y * L, z = g1 * L }, ref)
	end
	for i, r in ipairs(list) do
		local s0, s1 = sws[i][1], sws[i][2]
		-- the loop before (the line itself for the first): where this one leaves and rejoins it
		local inN, inP, inD, inG = nodeOf(s0), s0.pos, s0.dir, s0.grade
		local outN, outP, outD, outG = nodeOf(s1), s1.pos, s1.dir, s1.grade
		local base = r.off * r.sg
		for j = 1, count do
			local lat = base + j * s
			local aIn = r.shift + j * T            -- where the entry turnout has turned out
			local aOut = A - r.shift - j * T       -- where the exit turnout starts back
			if aOut - aIn < 5 then
				return nil, string.format(_("These loops need the handles at least %d m apart - drag them further"), math.floor(need))
			end
			local q, fq = besideAt(frames, aIn, lat, r.sg)
			local qe, fe = besideAt(frames, aOut, lat, r.sg)
			local qn, qen = b.node(q), b.node(qe)
			-- (exit signals at both ends of the loop track: short of the switch behind (trains backing
			-- out) and of the one ahead)
			local sIn = piece(inN, inP, inD, inG, qn, q, fq.dir, fq.grade)
			b.protectSwitch(sIn, true, opts.sigDist, sigModel())
			-- the run beside the line
			-- (nodes only where the line bends - runStops; the last one the exit turnout's start)
			local stops = runStops(frames, aIn, aOut, lat, r.sg)
			local pn, pp, pf = qn, q, fq
			for k, aS in ipairs(stops) do
				local e, f, en : P3, Frame, Engine.Entity
				if k == #stops then
					e, f, en = qe, fe, qen
				else
					e, f = besideAt(frames, aS, lat, r.sg)
					en = b.node(e)
				end
				piece(pn, pp, pf.dir, pf.grade, en, e, f.dir, f.grade)
				pn, pp, pf = en, e, f
			end
			local sOut = piece(qen, qe, fe.dir, fe.grade, outN, outP, outD, outG)
			b.protectSwitch(sOut, false, opts.sigDist, sigModel())
			inN, inP, inD, inG = qn, q, fq.dir, fq.grade
			outN, outP, outD, outG = qen, qe, fe.dir, fe.grade
		end
	end
	return b.proposal(), b.why
end

-- the last plan's turnout speed (km/h, the tooltip; nil: unknown)
local g_turnSpeed : number = nil

-- Dead end onto a platform: a loose track end (one track there - a station's open end, or a dead end)
-- within 15 m of the handle, on its side of the line, running on the line's way. Its offset from
-- the line, how far along it is from the switch, where it is and the way / grade a track arrives at
-- it. nil: none there
local record PlatEnd
	node : Engine.Entity
	pos : P3
	dir : P3
	grade : number
	lat : number
	along : number
end
local PLAT_SNAP = 15
local g_platLog = ""
local function platformEnd(pk : Pick, arc : Arc) : PlatEnd
	local best : PlatEnd = nil
	local seen : {string} = {}
	pcall(function()
		local bestD = PLAT_SNAP
		local nx, ny = -arc.d.y * arc.side, arc.d.x * arc.side
		for __, n in ipairs(api.engine.util.octree.findEntitiesInCircle(api.type.Vec2f.new(pk.ex, pk.ey), PLAT_SNAP + 1, api.type.ComponentType.BASE_NODE)) do
			local nd = api.engine.getComponent(n, api.type.ComponentType.BASE_NODE) as Engine.Component.BaseNode
			local segs = api.engine.system.streetSystem.getNodeSegments(n)
			-- (debug: each node looked at, and why it doesn't do)
			do
				local np = nd and nd.position
				local why = not nd and "no node" or (not segs and "no segments") or (#segs ~= 1 and (tostring(#segs) .. " segments")) or "loose"
				if np and segs and #segs == 1 then
					local se = g_host.getEdge(segs[1])
					local lat = (np.x - arc.p.x) * nx + (np.y - arc.p.y) * ny
					why = string.format("loose, lat %.1f, %s", lat, se and (se.roadType == api.type["enum"].RoadType.TRACK and "track" or "road") or "?")
				end
				seen[#seen + 1] = tostring(n) .. ": " .. why
			end
			-- (a loose end, or where a station's track ends - not a plain node along another line's track:
			-- on a double-track line the other main's nodes would catch the handle first)
			local endish = segs ~= nil and #segs == 1
			for __, sId in ipairs(segs or {}) do
				local c = api.engine.system.streetConnectorSystem.getConstructionEntityForEdge(sId)
				if c and c >= 0 then endish = true end
			end
			-- (one of its tracks leaving it the line's way - the siding arrives along that one)
			for __, sId in ipairs((nd and endish) and segs or {}) do
				local se = g_host.getEdge(sId)
				if se and se.roadType == api.type["enum"].RoadType.TRACK then
					local np : P3 = { x = nd.position.x, y = nd.position.y, z = nd.position.z }
					local dh = math.sqrt((np.x - pk.ex) ^ 2 + (np.y - pk.ey) ^ 2)
					local spc = geom.edgePiece(se)
					local tg = se.node0 == n and spc.t0 or { x = -spc.t1.x, y = -spc.t1.y, z = -spc.t1.z }
					local h = math.sqrt(tg.x * tg.x + tg.y * tg.y)
					local lat = (np.x - arc.p.x) * nx + (np.y - arc.p.y) * ny
					local along = (np.x - arc.p.x) * arc.d.x + (np.y - arc.p.y) * arc.d.y
					local way = h > 1e-6 and (tg.x * arc.d.x + tg.y * arc.d.y) / h or -1
					if dh < bestD and way > 0.95 and lat >= 3.5 and lat <= 40 then
						bestD = dh
						best = { node = n, pos = np, dir = { x = tg.x / h, y = tg.y / h, z = 0 }, grade = tg.z / h, lat = lat, along = along }
					else
						seen[#seen] = seen[#seen] .. string.format(", way %.2f", way)
					end
				end
			end
		end
	end)
	local text = table.concat(seen, " | ") .. (best and (" -> " .. tostring(best.node)) or " -> none")
	if text ~= g_platLog then g_platLog = text; dbg("[network_tools] siding platform end: " .. text) end
	return best
end

-- The station's open track ends at the same end as `node` (a platform track's end): each not yet
-- joined by a track outside, with its offset from the line (+ the handle's side) and how far along
-- it is. nil: not a station's
local function stationFeedEnds(node : Engine.Entity, arc : Arc) : {PlatEnd}
	local out : {PlatEnd} = nil
	pcall(function()
		local sc = api.engine.system.streetConnectorSystem
		local conE : Engine.Entity = nil
		for __, s in ipairs(api.engine.system.streetSystem.getNodeSegments(node) or {}) do
			local c = sc.getConstructionEntityForEdge(s)
			if c and c >= 0 then conE = c; break end
		end
		if not conE then return end
		local con = api.engine.getComponent(conE, api.type.ComponentType.CONSTRUCTION) as {string : any}
		if not con then return end
		local frozenNode : {Engine.Entity : boolean} = {}
		local frozenEdge : {Engine.Entity : boolean} = {}
		for __, n in ipairs((con.frozenNodes or {}) as {Engine.Entity}) do frozenNode[n] = true end
		for __, s in ipairs((con.frozenEdges or {}) as {Engine.Entity}) do frozenEdge[s] = true end
		local nx, ny = -arc.d.y * arc.side, arc.d.x * arc.side
		out = {}
		for s in pairs(frozenEdge) do
			local se = g_host.getEdge(s)
			if se and se.roadType == api.type["enum"].RoadType.TRACK then
				local spc = geom.edgePiece(se)
				for __, n in ipairs({ se.node0, se.node1 }) do
					if not frozenNode[n] then
						local tg = n == se.node0 and spc.t0 or { x = -spc.t1.x, y = -spc.t1.y, z = -spc.t1.z }
						local h = math.sqrt(tg.x * tg.x + tg.y * tg.y)
						-- (the same end: entered the line's way; open: no track outside joins it)
						local joined = false
						for __, s2 in ipairs(api.engine.system.streetSystem.getNodeSegments(n) or {}) do
							if not frozenEdge[s2] then joined = true end
						end
						if h > 1e-6 and (tg.x * arc.d.x + tg.y * arc.d.y) / h > 0.9 and not joined then
							local np = n == se.node0 and spc.p0 or spc.p1
							out[#out + 1] = { node = n, pos = np, dir = { x = tg.x / h, y = tg.y / h, z = 0 }, grade = tg.z / h,
								lat = (np.x - arc.p.x) * nx + (np.y - arc.p.y) * ny,
								along = (np.x - arc.p.x) * arc.d.x + (np.y - arc.p.y) * arc.d.y }
						end
					end
				end
			end
		end
	end)
	return out
end

-- Feed every track, the other styles: each side its own throat off one switch on the line (the
-- handle's side at the click; the other side's once the first turnout has left the line).
--   Ladder:   the innermost track's siding leaves the line, the next one's leaves that siding, and so
--             on outwards - each turnout crosses one track spacing (a yard ladder)
--   Diagonal: a straight track at the turnout angle leaves the line; a switch on it for each track,
--             curving back into it - the outermost the diagonal's own end (a station throat)
-- The sides fed: each side's station tracks inner to outer, and the main track they're fed from - the
-- outermost of the line's tracks on that side (a double-track line: the left main feeds the left
-- platforms, the right main the right ones; a single track: the clicked one for both)
local record FeedSide
	sg : integer
	list : {PlatEnd}
	at : number          -- its first switch, along the line from the click
	laneW : number       -- its main track's offset from the clicked one, out to its side (0: the clicked)
	laneEdge : Engine.Entity
	flip : number        -- a station track's offset out to this side: en.lat * flip
end
local function feedSides(pk : Pick, arc : Arc, ends : {PlatEnd}) : {FeedSide}
	local lanes = along_util.alongside(pk.edge, arc.p, arc.d)
	local hasClicked = false
	for __, ln in ipairs(lanes) do if ln.edge == pk.edge then hasClicked = true end end
	if not hasClicked then lanes[#lanes + 1] = { edge = pk.edge, off = 0 } end
	local sides : {FeedSide} = {}
	for __, sg in ipairs(opts.both and { arc.side, -arc.side } or { arc.side }) do
		local lane : Lane = nil
		for __, ln in ipairs(lanes) do if not lane or ln.off * sg > lane.off * sg then lane = ln end end
		local laneW = math.max(0, lane.off * sg)
		local flip = arc.side * sg
		local list : {PlatEnd} = {}
		for __, en in ipairs(ends) do
			if en.lat * flip - laneW >= 3.5 then list[#list + 1] = en end
		end
		table.sort(list, function(a : PlatEnd, c : PlatEnd) : boolean return a.lat * flip < c.lat * flip end)
		if #list > 0 then sides[#sides + 1] = { sg = sg, list = list, at = 0, laneW = laneW, laneEdge = lane.edge, flip = flip } end
	end
	return sides
end

-- a switch on a main track: a cut asked for (key) or an existing node; node and pos once resolved
local record MainSw
	key : string
	node : Engine.Entity
	pos : P3
end

-- Double-track line, both sides fed: two crossovers between the mains before the throats, one each
-- way, one after another from the click (no diamond) - every platform reached from either main,
-- every platform out onto either (a line run one way on each track: in on one, out on the other).
-- The throats start after them. nil: not a double-track line / both sides / the option
local record FeedXo
	len : number
	want : function(b : Builder, pk : Pick, frames : {Frame}) : string
	build : function(b : Builder, frames : {Frame}, ref : Engine.Component.BaseEdge)
end
local function feedCrossovers(pk : Pick, arc : Arc) : FeedXo
	if not opts.both or opts.feedCross == false then return nil end
	local lanes = along_util.alongside(pk.edge, arc.p, arc.d)
	local L, Rt : Lane, Lane = nil, nil
	for __, ln in ipairs(lanes) do
		if not L or ln.off > L.off then L = ln end
		if not Rt or ln.off < Rt.off then Rt = ln end
	end
	if not L or not Rt or L.off - Rt.off < 3 then return nil end
	local T = turnLen(L.off - Rt.off)
	-- each crossover: from a main (its offset, + left) at an along, to the other at another
	local legs : {{number}} = { { L.off, 0, Rt.off, T }, { Rt.off, T + 10, L.off, 2 * T + 10 } }
	local sws : {integer : MainSw} = {}
	local xo : FeedXo = { len = 2 * T + 20 }
	-- (a main's point `a` along: beside the clicked track's line by its offset)
	local function lanePoint(frames : {Frame}, a : number, off : number) : P3, Frame
		return besideAt(frames, a, math.abs(off), off >= 0 and 1 or -1)
	end
	xo.want = function(b : Builder, pk2 : Pick, frames : {Frame}) : string
		for i, lg in ipairs(legs) do
			for j = 0, 1 do
				local off, a = lg[1 + 2 * j], lg[2 + 2 * j]
				local idx = (i - 1) * 2 + j + 1
				if a < 0.5 and math.abs(off) < 0.5 then
					sws[idx] = { key = b.want(pk2.edge, pk2.t) }
				else
					local q, f = lanePoint(frames, a, off)
					local spot = along_util.trackAt(q, f.dir)
					if not spot then return _("A main track ends (or bends away) where a crossover must go - click further from its end") end
					if spot.node then
						b.touch(spot.node)
						sws[idx] = { node = spot.node, pos = spot.nodePos }
					else
						sws[idx] = { key = b.want(spot.edge, spot.t) }
					end
				end
			end
		end
		return nil
	end
	xo.build = function(b : Builder, frames : {Frame}, ref : Engine.Component.BaseEdge)
		for __, m in pairs(sws) do
			if m.key then local c = b.cut(m.key); m.node, m.pos = c.node, c.pos end
		end
		for i, lg in ipairs(legs) do
			local s0, s1 = sws[(i - 1) * 2 + 1], sws[(i - 1) * 2 + 2]
			local f0, f1 = frameAt(frames, lg[2]), frameAt(frames, lg[4])
			local tT = tanLen(s0.pos, f0.dir, s1.pos, f1.dir)
			b.segment(s0.node, s0.pos, { x = f0.dir.x * tT, y = f0.dir.y * tT, z = f0.grade * tT },
				s1.node, s1.pos, { x = f1.dir.x * tT, y = f1.dir.y * tT, z = f1.grade * tT }, ref)
		end
	end
	return xo
end

-- the switch on a side's main track `a` along from the click: the clicked spot, an existing node
-- there, or a cut on whichever segment is there; resolved after b.cutAll()
local function wantMain(b : Builder, pk : Pick, frames : {Frame}, a : number, sd : FeedSide) : MainSw, string
	if a < 0.5 and sd.laneEdge == pk.edge then return { key = b.want(pk.edge, pk.t) }, nil end
	local q, f = besideAt(frames, a, sd.laneW, sd.sg)
	local spot = along_util.trackAt(q, f.dir)
	if not spot then return nil, _("The line ends (or bends away) where a switch must go - click further from its end") end
	if spot.node then
		b.touch(spot.node)
		return { node = spot.node, pos = spot.nodePos }, nil
	end
	return { key = b.want(spot.edge, spot.t) }, nil
end

-- a run beside the line from (n0, p0, f0) at aFrom to aTo, `w` across on side sg; extra nodes at the
-- alongs in `at` (switches for the next siding) - returned by along index; it ends on `en` (joining
-- it) or at a new node
local function buildRun(b : Builder, ref : Engine.Component.BaseEdge, frames : {Frame}, n0 : Engine.Entity, p0 : P3, f0 : Frame,
		aFrom : number, aTo : number, w : number, sg : integer, extra : {number}, en : PlatEnd) : {integer : Engine.Entity}, {integer : P3}
	local stops = runStops(frames, aFrom, aTo, w, sg)
	-- (the extra stops in, in order; one within a metre of another is that one)
	local marks : {{number}} = {}
	for __, a in ipairs(stops) do marks[#marks + 1] = { a, 0 } end
	for i, a in ipairs(extra or {}) do
		local merged = false
		for __, m in ipairs(marks) do
			if math.abs(m[1] - a) < 1 and m[2] == 0 and m[1] < aTo - 0.5 then m[2] = i; merged = true; break end
		end
		if not merged then marks[#marks + 1] = { a, i } end
	end
	table.sort(marks, function(x : {number}, y : {number}) : boolean return x[1] < y[1] end)
	local nodesAt : {integer : Engine.Entity} = {}
	local posAt : {integer : P3} = {}
	local pn, pp, pf = n0, p0, f0
	for k, m in ipairs(marks) do
		local e, fe = besideAt(frames, m[1], w, sg)
		local node : Engine.Entity
		local endDir, endGrade = fe.dir, fe.grade
		if k == #marks and en then
			e, node, endDir, endGrade = en.pos, en.node, en.dir, en.grade
			b.touch(en.node)
		else
			node = b.node(e)
		end
		local len = tanLen(pp, pf.dir, e, endDir)
		b.segment(pn, pp, { x = pf.dir.x * len, y = pf.dir.y * len, z = pf.grade * len },
			node, e, { x = endDir.x * len, y = endDir.y * len, z = endGrade * len }, ref)
		if m[2] > 0 then nodesAt[math.floor(m[2])], posAt[math.floor(m[2])] = node, e end
		pn, pp, pf = node, e, fe
	end
	return nodesAt, posAt
end

local function planFeedLadder(pk : Pick, arc : Arc, frames : {Frame}, ends : {PlatEnd}, xo : FeedXo) : SimpleProposal, string
	local sides = feedSides(pk, arc, ends)
	if #sides == 0 then return nil, _("Every track at this end of the station is joined already") end
	-- (the other side's switch on the same track: once the first side's first turnout has left it;
	-- a double-track line's other main: level with it)
	if sides[2] and sides[2].laneEdge == sides[1].laneEdge then
		sides[2].at = turnLen(sides[1].list[1].lat * sides[1].flip - sides[1].laneW) + 5
	end
	-- (the crossovers between the mains first)
	for __, sd in ipairs(sides) do sd.at = sd.at + (xo and xo.len or 0) end
	local b = trackbuild.new()
	local ref = g_host.getEdge(pk.edge)
	-- each siding: where it leaves (along), its turnout's length (offsets: from the clicked track)
	local deps : {{number}} = {}
	local Tl : {{number}} = {}
	local maxAlong, spread = 0.0, 0.0
	for si, sd in ipairs(sides) do
		deps[si], Tl[si] = {}, {}
		local prevW = sd.laneW
		local a = sd.at
		for k, en in ipairs(sd.list) do
			local w = en.lat * sd.flip
			if w - prevW < 3.5 then return nil, _("Two of the station's tracks are too close together for a ladder") end
			deps[si][k], Tl[si][k] = a, turnLen(w - prevW)
			-- (room: the turnout, then on to the track's end; the next siding leaves before this one ends)
			if a + Tl[si][k] + 5 > en.along then
				return nil, string.format(_("The ladder doesn't fit before the station - click the line further back (about %d m more)"),
					math.ceil(a + Tl[si][k] + 5 - en.along))
			end
			maxAlong = math.max(maxAlong, en.along)
			prevW = w
			a = a + Tl[si][k] + 5
			spread = math.max(spread, a)
			if sd.list[k + 1] and a > en.along - 3 then
				return nil, _("A track ends before the next one's siding can leave it - click the line further back")
			end
		end
	end
	if maxAlong > frames[#frames].along then frames = walkAhead(frames, maxAlong + WALK_STEP) end
	if maxAlong > frames[#frames].along + 1 then return nil, _("The track ends (or bends away) before the station's tracks") end
	local mains : {MainSw} = {}
	for si, sd in ipairs(sides) do
		local m, whyM = wantMain(b, pk, frames, sd.at, sd)
		if not m then return nil, whyM end
		mains[si] = m
	end
	if xo then
		local whyX = xo.want(b, pk, frames)
		if whyX then return nil, whyX end
	end
	if not b.cutAll() then return nil, b.why end
	for __, m in ipairs(mains) do
		if m.key then local c = b.cut(m.key); m.node, m.pos = c.node, c.pos end
	end
	if xo then xo.build(b, frames, ref) end
	for si, sd in ipairs(sides) do
		local baseN, baseP = mains[si].node, mains[si].pos
		local prevW = sd.laneW
		for k, en in ipairs(sd.list) do
			local w = en.lat * sd.flip
			local a0, a1 = deps[si][k], deps[si][k] + Tl[si][k]
			local whyC = curveWhy(frames, a0, en.along, w, sd.sg) or turnoutWhy(frames, a0, a1, w - prevW)
			if whyC then return nil, whyC end
			local f0 = frameAt(frames, a0)
			local q, fq = besideAt(frames, a1, w, sd.sg)
			local qn = b.node(q)
			local tT = tanLen(baseP, f0.dir, q, fq.dir)
			local sT = b.segment(baseN, baseP, { x = f0.dir.x * tT, y = f0.dir.y * tT, z = f0.grade * tT },
				qn, q, { x = fq.dir.x * tT, y = fq.dir.y * tT, z = fq.grade * tT }, ref)
			b.protectSwitch(sT, true, opts.sigDist, sigModel())
			-- on beside the line to its track; a node where the next siding leaves it
			local nextDep = sd.list[k + 1] and { deps[si][k + 1] } or {}
			local nodesAt, posAt = buildRun(b, ref, frames, qn, q, fq, a1, en.along, w, sd.sg, nextDep, en)
			baseN, baseP = nodesAt[1], posAt[1]
			prevW = w
		end
	end
	arc.length = spread
	arc.joins = true
	local n = 0
	for __, sd in ipairs(sides) do n = n + #sd.list end
	arc.feeds = n
	return b.proposal(), b.why
end

local function planFeedDiagonal(pk : Pick, arc : Arc, frames : {Frame}, ends : {PlatEnd}, xo : FeedXo) : SimpleProposal, string
	local sides = feedSides(pk, arc, ends)
	if #sides == 0 then return nil, _("Every track at this end of the station is joined already") end
	local R = math.max(50, g_turnR or 300)
	-- (offsets in a side's own frame: from its main track, out to its side)
	local function relW(sd : FeedSide, en : PlatEnd) : number return en.lat * sd.flip - sd.laneW end
	-- each side's turnout angle: an S-turnout of half the innermost track's offset at the Switch radius
	-- (the full offset: each next switch sat where the curve before was still ~2.5 m off the diagonal -
	-- a switch inside another's diverging part is refused; at half, about twice the room)
	local thetas : {number} = {}
	for si, sd in ipairs(sides) do
		local w1 = relW(sd, sd.list[1])
		thetas[si] = math.max(math.rad(4), math.min(math.rad(25), math.acos(math.max(-1, 1 - w1 / (4 * R)))))
	end
	-- (the other side off the same track: once the first side's turnout has left it; a double-track
	-- line's other main: level with it)
	if sides[2] and sides[2].laneEdge == sides[1].laneEdge then sides[2].at = R * math.sin(thetas[1]) + 5 end
	-- (the crossovers between the mains first)
	for __, sd in ipairs(sides) do sd.at = sd.at + (xo and xo.len or 0) end
	-- the geometry in each side's own frame (x along the line from its switch, y out to its side)
	local record DiagT
		t : number     -- along the diagonal from the first arc's end, to this track's switch
		bx : number    -- where its curve back ends (along)
	end
	local geo : {{DiagT}} = {}
	local maxAlong, spread = 0.0, 0.0
	for si, sd in ipairs(sides) do
		local th = thetas[si]
		local gain = R * (1 - math.cos(th))
		local sx = R * math.sin(th)
		geo[si] = {}
		local prevT = -math.huge
		for k, en in ipairs(sd.list) do
			local w = relW(sd, en)
			local t = math.max(0, (w - 2 * gain) / math.sin(th))
			-- (the next switch where the curve before is ~3 m off the diagonal: s^2 / 2R)
			if t - prevT < math.sqrt(6 * R) then return nil, _("Two of the station's tracks are too close together for a diagonal at this Switch radius - try Ladder, or a smaller radius") end
			local bx = sx + t * math.cos(th) + sx
			geo[si][k] = { t = t, bx = bx }
			if sd.at + bx + 2 > en.along then
				return nil, string.format(_("The diagonal doesn't fit before the station - click the line further back (about %d m more)"),
					math.ceil(sd.at + bx + 2 - en.along))
			end
			maxAlong = math.max(maxAlong, en.along)
			spread = math.max(spread, sd.at + bx)
			prevT = t
		end
	end
	if maxAlong > frames[#frames].along then frames = walkAhead(frames, maxAlong + WALK_STEP) end
	if maxAlong > frames[#frames].along + 1 then return nil, _("The track ends (or bends away) before the station's tracks") end
	local b = trackbuild.new()
	local ref = g_host.getEdge(pk.edge)
	local mains : {MainSw} = {}
	for si, sd in ipairs(sides) do
		local m, whyM = wantMain(b, pk, frames, sd.at, sd)
		if not m then return nil, whyM end
		mains[si] = m
	end
	if xo then
		local whyX = xo.want(b, pk, frames)
		if whyX then return nil, whyX end
	end
	if not b.cutAll() then return nil, b.why end
	for __, m in ipairs(mains) do
		if m.key then local c = b.cut(m.key); m.node, m.pos = c.node, c.pos end
	end
	if xo then xo.build(b, frames, ref) end
	for si, sd in ipairs(sides) do
		local th = thetas[si]
		local f0 = frameAt(frames, sd.at)
		local d = f0.dir
		local nrm : P3 = { x = -d.y * sd.sg, y = d.x * sd.sg, z = 0 }
		local u : P3 = { x = d.x * math.cos(th) + nrm.x * math.sin(th), y = d.y * math.cos(th) + nrm.y * math.sin(th), z = 0 }
		local P0 = mains[si].pos
		-- (a point of this side's frame in the world; its height the line's there)
		local function world(x : number, y : number) : P3
			local f = frameAt(frames, sd.at + x)
			return { x = P0.x + d.x * x + nrm.x * y, y = P0.y + d.y * x + nrm.y * y, z = f.pos.z }
		end
		local function gradeAt(x : number) : number return frameAt(frames, sd.at + x).grade end
		local gain = R * (1 - math.cos(th))
		local sx = R * math.sin(th)
		local kArc = 4 * R * math.tan(th / 4)
		-- the turnout off the line: to the diagonal's start (the innermost track's switch)
		local Ax, Ay = sx, gain
		local A = world(Ax, Ay)
		local An = b.node(A)
		local sT = b.segment(mains[si].node, P0, { x = d.x * kArc, y = d.y * kArc, z = gradeAt(0) * kArc },
			An, A, { x = u.x * kArc, y = u.y * kArc, z = gradeAt(Ax) * kArc }, ref)
		b.protectSwitch(sT, true, opts.sigDist, sigModel())
		-- the diagonal, switch to switch; from each a curve back into its track
		local prevN, prevP, prevX, prevT = An, A, Ax, 0.0
		for k, en in ipairs(sd.list) do
			local g = geo[si][k]
			local Sx, Sy = Ax + g.t * math.cos(th), Ay + g.t * math.sin(th)
			local Sn, S : Engine.Entity, P3 = prevN, prevP
			if g.t - prevT > 0.5 then
				S = world(Sx, Sy)
				Sn = b.node(S)
				local len = g.t - prevT
				b.segment(prevN, prevP, { x = u.x * len, y = u.y * len, z = gradeAt(prevX) * len },
					Sn, S, { x = u.x * len, y = u.y * len, z = gradeAt(Sx) * len }, ref)
			end
			-- the curve back to the line's way, at this track's offset
			local Bx = Sx + sx
			local B = world(Bx, relW(sd, en))
			local Bn = b.node(B)
			local sC = b.segment(Sn, S, { x = u.x * kArc, y = u.y * kArc, z = gradeAt(Sx) * kArc },
				Bn, B, { x = d.x * kArc, y = d.y * kArc, z = gradeAt(Bx) * kArc }, ref)
			-- (the exit signal: on the curve, short of the switch it leaves)
			b.protectSwitch(sC, true, opts.sigDist, sigModel())
			-- straight on into the track's end
			local len = math.sqrt((en.pos.x - B.x) ^ 2 + (en.pos.y - B.y) ^ 2)
			b.touch(en.node)
			b.segment(Bn, B, { x = d.x * len, y = d.y * len, z = gradeAt(Bx) * len },
				en.node, en.pos, { x = en.dir.x * len, y = en.dir.y * len, z = en.grade * len }, ref)
			prevN, prevP, prevX, prevT = Sn, S, Sx, g.t
		end
	end
	arc.length = spread
	arc.joins = true
	local n = 0
	for __, sd in ipairs(sides) do n = n + #sd.list end
	arc.feeds = n
	return b.proposal(), b.why
end

-- Nested: every siding leaves its side's main track, each side's outermost station track first, the
-- sides taking turns. The switches one after another from the click towards the station - on one
-- track, each once the turnout before is fully out beside it (two mains: each its own sequence) -
-- so the sidings nest and none crosses another. Each runs at its station track's offset to that
-- track's own end and joins it.
local function planFeedNested(pk : Pick, arc : Arc, frames : {Frame}, ends : {PlatEnd}, xo : FeedXo) : SimpleProposal, string
	local sides = feedSides(pk, arc, ends)
	if #sides == 0 then return nil, _("Every track at this end of the station is joined already") end
	-- the order: each side's outermost first, the sides taking turns ({side, its track})
	local order : {{integer}} = {}
	local maxN = 0
	for __, sd in ipairs(sides) do maxN = math.max(maxN, #sd.list) end
	for i = 1, maxN do
		for si, sd in ipairs(sides) do
			local k = #sd.list - i + 1
			if k >= 1 then order[#order + 1] = { si, k } end
		end
	end
	-- where each switch goes along its main track, and each turnout's length
	local at : {number} = {}
	local Ts : {number} = {}
	local cursor : {Engine.Entity : number} = {}
	local maxAlong, spread = 0.0, 0.0
	for o, ok in ipairs(order) do
		local sd = sides[ok[1]]
		local en = sd.list[ok[2]]
		-- (after the crossovers between the mains, if any)
		local a = cursor[sd.laneEdge] or (xo and xo.len or 0.0)
		at[o], Ts[o] = a, turnLen(en.lat * sd.flip - sd.laneW)
		if a + Ts[o] + 5 > en.along then
			return nil, string.format(_("%d sidings don't fit before the station - click the line further back (about %d m more)"),
				#order, math.ceil(a + Ts[o] + 5 - en.along))
		end
		maxAlong = math.max(maxAlong, en.along)
		cursor[sd.laneEdge] = a + Ts[o] + 5
		spread = math.max(spread, a + Ts[o] + 5)
	end
	if maxAlong > frames[#frames].along then frames = walkAhead(frames, maxAlong + WALK_STEP) end
	if maxAlong > frames[#frames].along + 1 then return nil, _("The track ends (or bends away) before the station's tracks") end
	local b = trackbuild.new()
	local ref = g_host.getEdge(pk.edge)
	local mains : {MainSw} = {}
	for o, ok in ipairs(order) do
		local m, whyM = wantMain(b, pk, frames, at[o], sides[ok[1]])
		if not m then return nil, whyM end
		mains[o] = m
	end
	if xo then
		local whyX = xo.want(b, pk, frames)
		if whyX then return nil, whyX end
	end
	if not b.cutAll() then return nil, b.why end
	for __, m in ipairs(mains) do
		if m.key then local c = b.cut(m.key); m.node, m.pos = c.node, c.pos end
	end
	if xo then xo.build(b, frames, ref) end
	for o, ok in ipairs(order) do
		local sd = sides[ok[1]]
		local en = sd.list[ok[2]]
		local w = en.lat * sd.flip
		local a0, a1 = at[o], at[o] + Ts[o]
		local whyC = curveWhy(frames, a0, en.along, w, sd.sg) or turnoutWhy(frames, a0, a1, w - sd.laneW)
		if whyC then return nil, whyC end
		local f0 = frameAt(frames, a0)
		local q, fq = besideAt(frames, a1, w, sd.sg)
		local qn = b.node(q)
		local tT = tanLen(mains[o].pos, f0.dir, q, fq.dir)
		local sT = b.segment(mains[o].node, mains[o].pos, { x = f0.dir.x * tT, y = f0.dir.y * tT, z = f0.grade * tT },
			qn, q, { x = fq.dir.x * tT, y = fq.dir.y * tT, z = fq.grade * tT }, ref)
		b.protectSwitch(sT, true, opts.sigDist, sigModel())
		-- beside the line to the track's end, onto it
		buildRun(b, ref, frames, qn, q, fq, a1, en.along, w, sd.sg, {}, en)
	end
	arc.length = spread
	arc.joins = true
	arc.feeds = #order
	return b.proposal(), b.why
end

-- Feed every track in the panel's style: 1 nested (each off the line), 2 ladder, 3 diagonal
local function planFeed(pk : Pick, arc : Arc, frames : {Frame}, ends : {PlatEnd}) : SimpleProposal, string
	local style = math.floor(opts.feedStyle or 1)
	-- (a double-track line, both sides: crossovers between the mains first)
	local xo = feedCrossovers(pk, arc)
	arc.crossovers = xo ~= nil
	-- (the line walked as far as the crossovers reach, before the throats' own checks)
	if xo and xo.len > frames[#frames].along then frames = walkAhead(frames, xo.len + WALK_STEP) end
	if style == 2 then return planFeedLadder(pk, arc, frames, ends, xo) end
	if style == 3 then return planFeedDiagonal(pk, arc, frames, ends, xo) end
	return planFeedNested(pk, arc, frames, ends, xo)
end

local function plan(pk : Pick) : SimpleProposal, string, Arc
	-- (first: every turnout length below comes from this radius)
	g_turnSpeed = setTurnRadius(g_host.getEdge(pk.edge))
	local arc, why = arcOf(pk)
	if not arc then return nil, why, nil end
	-- the line from the switch to the handle, walked: the sidings follow its curves
	local frames, alongH, whyW = walkLine(arc.p, arc.d, arc.grade, pk.ex, pk.ey)
	if not frames then return nil, whyW, arc end
	arc.along = alongH
	-- (the handle drawn at the curved siding's end, not the straight one's)
	arc.e = besideAt(frames, alongH, math.max(3.5, opts.spacing or 5), arc.side)
	-- Dead end on a station's track end, Feed every track: a siding to each of its open tracks there -
	-- before Tracks alongside below (a double-track line feeds each side from its own main)
	if not opts.rejoin and opts.feedAll ~= false then
		local platF = platformEnd(pk, arc)
		local ends = platF and stationFeedEnds(platF.node, arc) or nil
		if ends and #ends > 0 then
			arc.e = platF.pos
			local p, w = planFeed(pk, arc, frames, ends)
			return p, w, arc
		end
	end
	-- Tracks alongside Off on a double (multi-) track line: a siding off the clicked track would run
	-- across the track beside it (Both sides: always) - Collision. Instead: Both sides, one off each
	-- outer track outwards (Outer); else off the outermost track on the handle's side
	-- (5: as Outer, chosen for Off on a multi-track line - not the crossing layout Outer + Both builds)
	local mode = opts.alongside or 0
	if mode == 0 and #along_util.alongside(pk.edge, arc.p, arc.d) > 1 then
		mode = opts.both and 5 or 4
	end
	if opts.rejoin then
		local p, w = planRejoin(pk, arc, frames, mode)
		return p, w, arc
	end
	if mode > 0 then
		local p, w = planAlongside(pk, arc, frames, mode)
		return p, w, arc
	end
	local count = math.max(1, math.min(6, math.floor(opts.count or 1)))
	-- the handle on a loose track end beside the line (a station's platform track): the siding runs
	-- at that track's distance and joins it there
	-- (several sidings: the outermost joins it, the others between - its distance shared out)
	local plat = platformEnd(pk, arc)
	if plat and plat.lat / count < 3.5 then
		return nil, string.format(_("That track is too close for %d sidings side by side - fewer sidings, or a track further out"), count), arc
	end
	if plat then
		arc.along = plat.along
		-- (the handle drawn on the platform track's end)
		arc.e = plat.pos
		-- (the line walked on as far as the platform's end, if the handle was dropped short of it)
		if plat.along > frames[#frames].along then frames = walkAhead(frames, plat.along + WALK_STEP) end
		if plat.along > frames[#frames].along + 1 then return nil, _("The track ends (or bends away) before that platform track"), arc end
	end
	local s = plat and (plat.lat / count) or math.max(3.5, opts.spacing or 5)
	local T = turnLen(s)
	local need = count * T + 10 + (opts.both and (T + 5) or 0)
	arc.length = arc.along - count * T
	arc.joins = plat ~= nil
	if arc.along < need then
		return nil, string.format(_("These sidings need the handle at least %d m along - drag it further"), math.floor(need)), arc
	end
	local b = trackbuild.new()
	-- the switches on the line: one per side; the other side's once the first turnout is clear of
	-- the line (8 m on, the first still overlapped it: "Construction Not Possible")
	-- (the second switch: on whichever segment of the track is there - the clicked one, or one
	-- further along; an existing node there is used as it is)
	local keys : {string} = { b.want(pk.edge, pk.t) }
	local bases : {Cut} = {}
	local sides : {integer} = { arc.side }
	local off2 = T + 5
	if opts.both then
		local f2 = frameAt(frames, off2)
		local spot = along_util.trackAt(f2.pos, f2.dir)
		if not spot then
			return nil, _("Both sides: the track ends (or bends away) where the second switch must go - click further from its end"), arc
		end
		if spot.node then
			bases[2] = { node = spot.node, pos = spot.nodePos }
			b.touch(spot.node)
		else
			keys[2] = b.want(spot.edge, spot.t)
		end
		sides[2] = -arc.side
	end
	if not b.cutAll() then return nil, b.why, arc end
	for i, k in pairs(keys) do bases[i] = b.cut(k) end
	local ref = g_host.getEdge(pk.edge)
	for i, sg in ipairs(sides) do
		local base = bases[i]
		-- (distances along the line from the clicked switch; the stubs all end level with the handle)
		local off = i == 1 and 0 or off2
		local prevNode, prevPos = base.node, base.pos
		local f0 = frameAt(frames, off)
		local prevDir, prevGrade = f0.dir, f0.grade
		for j = 1, count do
			-- the turnout: an S-curve off the line (or the siding before), along the track at both
			-- ends, keeping its gradient (a switch's tracks leave at the same slope); then the stub
			-- beside the line, following its curves, to the handle
			local a0 = off + (j - 1) * T
			local a1 = a0 + T
			local whyC = curveWhy(frames, a0, arc.along, j * s, sg) or turnoutWhy(frames, a0, a1, j * s)
			if whyC then return nil, whyC, arc end
			local q, fq = besideAt(frames, a1, j * s, sg)
			local qn = b.node(q)
			local tT = tanLen(prevPos, prevDir, q, fq.dir)
			local sT = b.segment(prevNode, prevPos, { x = prevDir.x * tT, y = prevDir.y * tT, z = prevGrade * tT },
				qn, q, { x = fq.dir.x * tT, y = fq.dir.y * tT, z = fq.grade * tT }, ref)
			-- (the siding's exit: short of its switch, for trains heading out)
			b.protectSwitch(sT, true, opts.sigDist, sigModel())
			-- the stub: pieces only where the line bends (runStops), each end beside the line
			local pn, pp, pf = qn, q, fq
			local stops = runStops(frames, a1, arc.along, j * s, sg)
			for k, a in ipairs(stops) do
				local e, fe = besideAt(frames, a, j * s, sg)
				local en : Engine.Entity
				local endDir, endGrade = fe.dir, fe.grade
				-- (the handle's side, its outermost siding: onto the track there)
				local joinsHere = plat ~= nil and i == 1 and j == count and k == #stops
				if joinsHere then
					-- (onto the platform track's end, arriving along it)
					e, en, endDir, endGrade = plat.pos, plat.node, plat.dir, plat.grade
					b.touch(plat.node)
				else
					en = b.node(e)
				end
				local len = tanLen(pp, pf.dir, e, endDir)
				b.segment(pn, pp, { x = pf.dir.x * len, y = pf.dir.y * len, z = pf.grade * len },
					en, e, { x = endDir.x * len, y = endDir.y * len, z = endGrade * len }, ref)
				pn, pp, pf = en, e, fe
			end
			prevNode, prevPos, prevDir, prevGrade = qn, q, fq.dir, fq.grade
		end
	end
	return b.proposal(), b.why, arc
end

local SidingActionRecipe = react.RegisterRecipe("NtoolsSidingAction", function(params : ConstructionCustomActionParams<any>) : TreeNodeId
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
		return tostring(opts.spacing) .. "/" .. tostring(opts.radius) .. "/" .. tostring(opts.side)
			.. "/" .. tostring(opts.count) .. "/" .. tostring(opts.both) .. "/" .. tostring(opts.alongside)
			.. "/" .. tostring(opts.rejoin) .. "/" .. tostring(opts.speed)
			.. "/" .. tostring(opts.signals) .. "/" .. tostring(opts.signalModel) .. "/" .. tostring(opts.sigDist)
			.. "/" .. tostring(opts.feedAll) .. "/" .. tostring(opts.feedStyle) .. "/" .. tostring(opts.feedCross)
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
		if ok then proposal, why, arc = p, w, a else why = _("Can't be planned here"); dbg("[network_tools] siding: " .. tostring(p)) end
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
		-- (the game's builders' Context: the street graph tidied round the new switches)
		local context = speedUtil.buildContext()
		local cmd = api.cmd.makeWorldBuildProposalCmd(proposal, context, anarchy, true)
		-- (Bundle / Across: their signals go on once the track stands)
		local laterSignals = trackbuild.deferredSignals()
		pickState:set(nil)
		busyState:set(true)
		local send = shared.send as function(Command<WorldBuildProposalCommandData>, function(WorldBuildProposalCommandData, boolean), boolean)
		send(cmd, function(__ : WorldBuildProposalCommandData, success : boolean)
			if not success then dbg("[network_tools] Siding: build failed") end
			if success and laterSignals then trackbuild.placeSignals(laterSignals) end
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
	-- (on the stub's end once it can be planned; else where it was dragged)
	if arc then handleList[1] = { x = arc.e.x, y = arc.e.y, z = nil }
	elseif pick then handleList[1] = { x = pick.ex, y = pick.ey, z = nil } end
	-- Rejoin: a second handle on the start switch (dragged along the track)
	if opts.rejoin and pick then
		local e = g_host.getEdge(pick.edge)
		if e then
			local p = geom.point(geom.edgePiece(e), pick.t)
			handleList[2] = { x = p.x, y = p.y, z = nil }
		end
	end
	local dragging = draggingState:old() or 0
	local hover = hoverState:old() or 0
	local dragCtl : DragCtl = {
		handles = handleList,
		dragging = dragging,
		setDragging = function(i : integer) draggingState:set(i) end,
		hover = hover,
		setHover = function(i : integer) hoverState:set(i) end,
		onDrag = function(i : integer, x : number, y : number)
			if not pick then return end
			if i == 2 then
				-- the start switch: onto the track under the cursor (along the same line)
				local e = g_host.getEdge(pick.edge)
				if not e then return end
				local d = trackbuild.unit(geom.tangent(geom.edgePiece(e), pick.t))
				local spot = along_util.trackAt({ x = x, y = y, z = 0 }, { x = d.x, y = d.y, z = 0 })
				if not spot or spot.node then return end
				costState:set(0)
				errorState:set("")
				pickState:set({ edge = spot.edge, t = spot.t, ex = pick.ex, ey = pick.ey })
				return
			end
			costState:set(0)
			errorState:set("")
			-- Dead end: over a track node beside the line (a platform track's end), the handle snaps
			-- onto it (as Junction's onto a track) - the outermost siding then joins that track there
			if not opts.rejoin then
				local tmp : Pick = { edge = pick.edge, t = pick.t, ex = x, ey = y }
				local okA, a = pcall(arcOf, tmp)
				local pl = okA and a and platformEnd(tmp, a) or nil
				if pl then x, y = pl.pos.x, pl.pos.y end
			end
			pickState:set({ edge = pick.edge, t = pick.t, ex = x, ey = y })
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
				local pc = geom.edgePiece(e)
				local t = geom.closestT(pc, x, y)
				-- the handle starts 120 m along (a loop: 300 m), on the chosen side
				local p = geom.point(pc, t)
				local d = trackbuild.unit(geom.tangent(pc, t))
				local s = opts.side == 2 and 1 or -1
				local w = math.max(3.5, opts.spacing or 5)
				local ahead = opts.rejoin and 300 or 120
				costState:set(0)
				errorState:set("")
				pickState:set({ edge = entity, t = t, ex = p.x + d.x * ahead - d.y * w * s, ey = p.y + d.y * ahead + d.x * w * s })
				return true
			end,
			onProcessMouseEvent = function(evt : Gui.Mouse.Event) : boolean
				return handles.mouse(evt, dragCtl)
			end,
			filter = g_host.isEdge,
		}) as Builtin.SelectorParam)
		if proposal then
			local id = string.format("ntools_siding,%s,%d,%.3f,%.1f,%.1f", _o, pick.edge, pick.t, pick.ex, pick.ey)
			children[#children + 1] = preview.viewer{
				proposal = proposal,
				anarchy = anarchy,
				onData = function(proposalData : ProposalData)
					if aliveRef:hasExpired() then return end
					costState:set(proposalData.costs)
					local msg = ""
					for __, m in ipairs(proposalData.errorState.messages) do msg = msg .. m .. " " end
					-- (refused here: asked again with the build's Context, it may pass)
					if msg ~= "" and speedUtil.verdictWithCleanup(proposal) == "" then msg = "" end
					-- (still refused: which new piece - the game asked part by part)
					if msg ~= "" then
						local dg = trackbuild.diagnose(id)
						if dg then msg = msg .. "\n" .. dg end
					end
					errorState:set(msg)
				end,
				id = id,
			}
		end
		if #handleList > 0 then
			local c = handles.canvas()
			for i, h in ipairs(handleList) do
				c.handle(h, dragging == i and 2 or (hover == i and 1 or 0))
			end
			local n = c.node()
			if n then children[#children + 1] = n end
		end

		local info = ""
		if arc then
			-- (a train of n cars fits roughly in the usable length; shown in metres)
			info = string.format(arc.feeds and _("Switches over %d m of the line") or (opts.rejoin and _("Loop length: %d m") or _("Siding length: %d m")), math.floor(arc.length + 0.5))
			-- (the turnouts' speed, the track type's own formula; and their radius)
			if g_turnSpeed then
				info = info .. "   " .. string.format(_("Turnouts: %d km/h (R %d m)"), math.floor(g_turnSpeed + 0.5), math.floor(g_turnR + 0.5))
			end
			if arc.feeds then
				info = info .. "\n" .. string.format(_("Feeding %d station tracks (Start side Both: both sides of the line)"), arc.feeds)
				if arc.crossovers then info = info .. "\n" .. _("Crossovers between the mains first: every platform from and to either main track") end
			elseif arc.joins then info = info .. "\n" .. _("Joins the platform track there") end
		end
		if not pick then
			children[#children + 1] = g_host.tooltip(opts.rejoin and _("Click a track where the passing loop should start") or _("Click a track where the siding should leave it"), false, false)
		elseif why then
			children[#children + 1] = g_host.tooltip(why .. (info ~= "" and ("\n" .. info) or ""), false, true)
		elseif blocked then
			children[#children + 1] = g_host.tooltip(errorState:old() .. "\n" .. info, false, true, costState:old())
		else
			children[#children + 1] = g_host.tooltip((opts.rejoin and _("Drag the end handle (length and side) or the start handle (along the track), Build to build it")
				or _("Drag the handle to set the length and side, Build to build it")) .. "\n" .. info, true, false, costState:old())
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

	params.setActionFn(actionFn, "NtoolsSidingAction")
	return padMod.anchor(pad)
end)

return {
	init = init,
	opts = opts,
	SidingActionRecipe = SidingActionRecipe,
}
