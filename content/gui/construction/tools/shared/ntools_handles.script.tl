-- Network Tools: in-world handles (like the Handles of Network Tools for Cities: Skylines 2), shared
-- by the tools so every panel setting can also be dragged in the world.
--
-- Drawing follows the Connect tool / MoveIt mod: lines and circles are split into short straight
-- pieces on one builtin.EdgeRenderable (only ONE may be mounted per recipe - the engine asserts
-- otherwise). Input: the tool's builtin.Selector passes every mouse event to mouse(), which
-- hit-tests handles in world metres against the terrain position under the cursor.
--
-- Use in a recipe:
--   local draggingState = react.useState(0); local hoverState = react.useState(0)
--   local ctl = { handles = {...}, dragging = draggingState:old(), setDragging = ..., ... }
--   Selector{ onProcessMouseEvent = function(evt) return handles.mouse(evt, ctl) end, ... }
--   children[#children + 1] = canvas.node()

local builtin = ug_require "::/gui/main/builtin.lua" as Builtin

-- the Anarchy build preview's green strips: drawn in this canvas's EdgeRenderable (a tool may only
-- mount one), see shared/ntools_preview
local record Preview
	takeEdges : function() : {Builtin.Type.EdgeRenderable.Edge}
end
local preview = require "network_tools_1::/gui/construction/tools/shared/ntools_preview.script.tl" as Preview

local record Handle
	x : number
	y : number
	z : number        -- nil = on the ground
end

local record Canvas
	-- z nil = follow the ground
	line : function(x0 : number, y0 : number, z0 : number, x1 : number, y1 : number, z1 : number, color : Vec4f, width : number)
	circle : function(cx : number, cy : number, z : number, r : number, color : Vec4f, width : number)
	handle : function(h : Handle, state : integer)     -- state: 0 idle, 1 hover, 2 dragging
	edges : function(list : {Builtin.Type.EdgeRenderable.Edge})   -- ready-made edges (e.g. ground text)
	node : function() : TreeNodeId
end

local record DragCtl
	handles : {Handle}
	dragging : integer                                -- index being dragged, 0 = none
	setDragging : function(i : integer)
	hover : integer                                   -- index under the cursor, 0 = none
	setHover : function(i : integer)
	onDrag : function(i : integer, x : number, y : number)
	onRelease : function(i : integer)                 -- optional
	onPress : function(i : integer)                   -- optional: a handle was pressed (a click selects)
end

local record Handles
	HANDLE_RADIUS : number
	canvas : function() : Canvas
	hit : function(handles : {Handle}, x : number, y : number) : integer
	mouse : function(evt : Gui.Mouse.Event, ctl : DragCtl) : boolean
	cursor : function() : number, number
	colors : {string : Vec4f}
end

local HANDLE_RADIUS = 3.5      -- metres, drawn (times the Settings tab's handle size)
local HIT_RADIUS = 8           -- metres, grabbable (the same)
local STEP = 8                 -- metres per drawn piece

-- the Settings tab (shared/ntools_options): colorPreset, handleScale
local sharedOpts = (require "network_tools_1::/gui/construction/tools/shared/ntools_options.script.tl" as {string : {string : any}}).opts
local function handleScale() : number
	local s = sharedOpts and sharedOpts.handleScale as number
	return (s and s > 0) and s or 1
end

local function rgba(r : number, g : number, b : number, a : number) : Vec4f return api.type.Vec4f.new(r, g, b, a) end
-- colour sets: 1 default, 2 colour-blind safe (Okabe-Ito: good / bad as blue / orange, not green /
-- red), 3 high contrast. stretch / start / finish: a tool's selected stretch and its two ends
local PRESETS : {{string : {number}}} = {
	{ handle = { 1.0, 0.8, 0.25, 0.95 }, hover = { 1.0, 1.0, 0.6, 1.0 }, drag = { 1.0, 0.5, 0.0, 1.0 },
	  guide = { 1.0, 1.0, 1.0, 0.45 }, good = { 0.3, 1.0, 0.5, 0.9 }, bad = { 1.0, 0.3, 0.3, 0.9 },
	  stretch = { 0.25, 0.75, 1.0, 0.85 }, start = { 0.3, 1.0, 0.45, 0.95 }, finish = { 1.0, 0.6, 0.15, 0.95 } },
	{ handle = { 0.94, 0.89, 0.26, 0.95 }, hover = { 1.0, 1.0, 0.7, 1.0 }, drag = { 0.9, 0.6, 0.0, 1.0 },
	  guide = { 1.0, 1.0, 1.0, 0.45 }, good = { 0.0, 0.45, 0.70, 0.95 }, bad = { 0.9, 0.6, 0.0, 0.95 },
	  stretch = { 0.35, 0.70, 0.90, 0.85 }, start = { 0.0, 0.62, 0.45, 0.95 }, finish = { 0.8, 0.47, 0.65, 0.95 } },
	{ handle = { 1.0, 1.0, 0.0, 1.0 }, hover = { 1.0, 1.0, 1.0, 1.0 }, drag = { 1.0, 0.0, 1.0, 1.0 },
	  guide = { 1.0, 1.0, 1.0, 0.8 }, good = { 0.0, 1.0, 1.0, 1.0 }, bad = { 1.0, 0.0, 1.0, 1.0 },
	  stretch = { 0.0, 1.0, 1.0, 0.95 }, start = { 1.0, 1.0, 1.0, 1.0 }, finish = { 1.0, 0.0, 1.0, 1.0 } },
}

-- the colours tools draw with (one table, its entries swapped when the preset changes)
local colors : {string : Vec4f} = {}
local g_preset = 0
local function applyPreset()
	local i = (sharedOpts and (sharedOpts.colorPreset as integer)) or 1
	if not PRESETS[i] then i = 1 end
	if i == g_preset then return end
	g_preset = i
	for k, c in pairs(PRESETS[i]) do colors[k] = rgba(c[1], c[2], c[3], c[4]) end
end
applyPreset()

local function groundZ(x : number, y : number, fallback : number) : number
	local ok, h = pcall(function() : number
		return api.engine.terrain.getHeightAt(api.type.Vec2f.new(x, y))
	end)
	return (ok and h) or fallback or 0
end

local function segmentEdge(x0 : number, y0 : number, z0 : number, x1 : number, y1 : number, z1 : number, color : Vec4f, width : number) : Builtin.Type.EdgeRenderable.Edge
	local len = math.sqrt((x1 - x0) ^ 2 + (y1 - y0) ^ 2)
	if len < 0.05 then return nil end
	local straight = api.type.EdgeGeometry.Straight.new()
	straight.pos = { api.type.Vec2f.new(x0, y0), api.type.Vec2f.new(x1, y1) }
	local geom = api.type.EdgeGeometry.new()
	geom.straight = straight
	geom.height = api.type.Vec2f.new(z0, z1)
	geom.width = 1.0
	geom.length = len
	local edge = builtin.type.EdgeRenderable.Edge.new(geom)
	edge.colors = { color, color, color }
	edge.stepSize = 1
	edge.width = width
	edge.offsetZ = 1.0
	return edge
end

-- One true arc piece (EdgeGeometry ARC), or nil if the engine rejects arc geometry
-- (stepSize: metres between the points the engine draws the arc through; 1 when not given)
local function arcEdge(cx : number, cy : number, r : number, a0 : number, da : number, z0 : number, z1 : number, color : Vec4f, width : number, stepSize? : number) : Builtin.Type.EdgeRenderable.Edge
	local ok, edge = pcall(function() : Builtin.Type.EdgeRenderable.Edge
		local arc = api.type.EdgeGeometry.Arc.new()
		arc.center = api.type.Vec2f.new(cx, cy)
		arc.radius = r
		arc.startAngle = a0
		arc.angle = da
		local geom = api.type.EdgeGeometry.new()
		geom.type = api.type.EdgeGeometry.Type.ARC
		geom.arc = arc
		geom.height = api.type.Vec2f.new(z0, z1)
		geom.width = 1.0
		geom.length = math.abs(da) * r
		local e = builtin.type.EdgeRenderable.Edge.new(geom)
		e.colors = { color, color, color }
		e.stepSize = stepSize or 1
		e.width = width
		e.offsetZ = 1.0
		return e
	end)
	return ok and edge or nil
end
local g_arcsOk = true

local function canvas() : Canvas
	local edges : {Builtin.Type.EdgeRenderable.Edge} = {}
	local function add(e : Builtin.Type.EdgeRenderable.Edge)
		if e then edges[#edges + 1] = e end
	end
	applyPreset()   -- (the Settings tab's colours, if they changed)
	local c : Canvas = {}
	c.line = function(x0 : number, y0 : number, z0 : number, x1 : number, y1 : number, z1 : number, color : Vec4f, width : number)
		local len = math.sqrt((x1 - x0) ^ 2 + (y1 - y0) ^ 2)
		if len < 0.3 then return end
		local n = math.max(1, math.ceil(len / STEP))
		local function at(i : integer) : number, number, number
			local t = i / n
			local x, y = x0 + (x1 - x0) * t, y0 + (y1 - y0) * t
			local z : number
			if z0 and z1 then z = z0 + (z1 - z0) * t else z = groundZ(x, y, z0 or z1) end
			return x, y, z
		end
		local px, py, pz = at(0)
		for i = 1, n do
			local x, y, z = at(i)
			add(segmentEdge(px, py, pz, x, y, z, color, width))
			px, py, pz = x, y, z
		end
	end
	c.circle = function(cx : number, cy : number, z : number, r : number, color : Vec4f, width : number)
		if r < 0.3 then return end
		-- real arcs (EdgeGeometry ARC): smooth at any size; a few arcs so each follows the ground
		if g_arcsOk then
			local n = math.floor(math.max(4, math.min(24, math.ceil(2 * math.pi * r / 25))))
			-- the engine draws an arc through points stepSize metres apart: 1 m makes a small circle
			-- a polygon (a 0.55 m dot came out an octagon), so small circles get finer steps
			local step = math.min(1, math.max(0.05, r * 0.1))
			local pieces : {Builtin.Type.EdgeRenderable.Edge} = {}
			for i = 0, n - 1 do
				local a0, a1 = 2 * math.pi * i / n, 2 * math.pi * (i + 1) / n
				local z0 = z or groundZ(cx + r * math.cos(a0), cy + r * math.sin(a0), 0)
				local z1 = z or groundZ(cx + r * math.cos(a1), cy + r * math.sin(a1), 0)
				local e = arcEdge(cx, cy, r, a0, a1 - a0, z0, z1, color, width, step)
				if not e then g_arcsOk = false; break end
				pieces[#pieces + 1] = e
			end
			if g_arcsOk then
				for _, e in ipairs(pieces) do add(e) end
				return
			end
		end
		local n = math.floor(math.max(12, math.min(96, math.ceil(2 * math.pi * r / 4))))
		local function at(i : integer) : number, number, number
			local a = 2 * math.pi * i / n
			local x, y = cx + r * math.cos(a), cy + r * math.sin(a)
			return x, y, z or groundZ(x, y, 0)
		end
		local px, py, pz = at(0)
		for i = 1, n do
			local x, y, zz = at(i)
			add(segmentEdge(px, py, pz, x, y, zz, color, width))
			px, py, pz = x, y, zz
		end
	end
	c.handle = function(h : Handle, state : integer)
		local color = state == 2 and colors.drag or (state == 1 and colors.hover or colors.handle)
		local w = state == 0 and 1.2 or 1.8
		local r = HANDLE_RADIUS * handleScale()
		c.circle(h.x, h.y, h.z, r, color, w)
		c.circle(h.x, h.y, h.z, r * 0.35, color, w)
	end
	c.edges = function(list : {Builtin.Type.EdgeRenderable.Edge})
		for _, e in ipairs(list or {}) do add(e) end
	end
	c.node = function() : TreeNodeId
		-- the Anarchy preview's strips first, so handles draw on top
		local strips = preview.takeEdges()
		if #strips > 0 then
			for _, e in ipairs(edges) do strips[#strips + 1] = e end
			edges = strips
		end
		if #edges == 0 then return nil end
		local ok, node = pcall(function() : TreeNodeId
			return builtin.EdgeRenderable{ edges = edges, ignoreDepth = true }
		end)
		return ok and node or nil
	end
	return c
end

-- Index of the handle within reach of (x, y), nearest first; 0 = none.
local function hit(handles : {Handle}, x : number, y : number) : integer
	local hr = HIT_RADIUS * handleScale()
	local best, bestD = 0, hr * hr
	for i, h in ipairs(handles or {}) do
		local d = (h.x - x) ^ 2 + (h.y - y) ^ 2
		if d <= bestD then best, bestD = i, d end
	end
	return best
end

-- Ground position under the cursor, or nil.
local function cursor() : number, number
	if not api.gui.mouse.hasTerrainPosition() then return nil, nil end
	local m = api.gui.mouse.getTerrainPosition()
	return m.x, m.y
end

-- Feed every Selector mouse event here. Returns true when a handle took the event (the Selector
-- then doesn't select). A stale drag is cleared on the next press, because a re-mounted Selector
-- can swallow the Released event (pattern from the MoveIt mod).
local function mouse(evt : Gui.Mouse.Event, ctl : DragCtl) : boolean
	local Type = api.gui.mouse.Event.Type
	if evt.type == Type.Pressed and ctl.dragging ~= 0 then
		ctl.setDragging(0)
	end
	local x, y = cursor()
	if evt.type == Type.Pressed and evt.button == 0 then
		if not x then return false end
		local i = hit(ctl.handles, x, y)
		if i > 0 then
			ctl.setDragging(i)
			if ctl.onPress then ctl.onPress(i) end
			return true
		end
	elseif evt.type == Type.Moved then
		if ctl.dragging ~= 0 then
			if x then ctl.onDrag(ctl.dragging, x, y) end
			return true
		end
		local i = x and hit(ctl.handles, x, y) or 0
		if i ~= ctl.hover then ctl.setHover(i) end
	elseif evt.type == Type.Released and ctl.dragging ~= 0 then
		local i = ctl.dragging
		ctl.setDragging(0)
		if ctl.onRelease then ctl.onRelease(i) end
		return true
	end
	return false
end

local M : Handles = {
	HANDLE_RADIUS = HANDLE_RADIUS,
	canvas = canvas,
	hit = hit,
	mouse = mouse,
	cursor = cursor,
	colors = colors,
}
return M
