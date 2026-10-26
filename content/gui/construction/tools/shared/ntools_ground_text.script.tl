-- Network Tools: speed / incline tags on segments, like the game's street builder shows. The game
-- draws its tags natively and its HUD icons can't be attached to segments (verified: the HUD icon
-- manager never asks for BASE_EDGE), so these are drawn in the world with overlay lines: a small
-- stroke font, laid flat at the segment's middle, turned to read upright from the camera and sized
-- with the camera distance.
--
-- tagsFor(segments) returns overlay edges for a list of proposal segments; the caller hands them to
-- the handle kit's pending overlay (one EdgeRenderable per tool).

local builtin = ug_require "::/gui/main/builtin.lua" as Builtin

local record Tag
	x : number
	y : number
	z : number
	speed : number        -- km/h, or nil
	grade : number        -- %, along the segment, or nil
end

-- free text (digits, "m", "%", ".", "-", spaces), boxed like the tags
local record Label
	x : number
	y : number
	z : number
	text : string
end

local record GroundText
	tagsFor : function(segs : {Proposal.SegmentAndEntity}) : {Builtin.Type.EdgeRenderable.Edge}
	tagEdges : function(tags : {Tag}) : {Builtin.Type.EdgeRenderable.Edge}
	labelEdges : function(labels : {Label}) : {Builtin.Type.EdgeRenderable.Edge}
end

local TEXT = api.type.Vec4f.new(1.0, 1.0, 1.0, 0.97)
local FRAME = api.type.Vec4f.new(0.30, 0.52, 0.78, 0.9)
local FILL = api.type.Vec4f.new(0.07, 0.09, 0.12, 0.78)   -- the box behind the text
local LIFT = 2.5                -- metres above the road

-- Stroke font: polylines in a 0.6 x 1.0 box (x right, y up), round shapes built from arcs.
-- Arrows: "^" up, "v" down; "S" = speed.

-- points round an ellipse (centre cx, cy; radii rx, ry) from angle a0 to a1 (degrees, either way),
-- appended to `pts` (a flat x, y, x, y ... list)
local function arc(pts : {number}, cx : number, cy : number, rx : number, ry : number, a0 : number, a1 : number) : {number}
	local n = math.max(3, math.ceil(math.abs(a1 - a0) / 15))
	for i = 0, n do
		local a = math.rad(a0 + (a1 - a0) * i / n)
		pts[#pts + 1] = cx + rx * math.cos(a)
		pts[#pts + 1] = cy + ry * math.sin(a)
	end
	return pts
end
-- a polyline: arcs and points joined (each part a flat list)
local function join(...: {number}) : {number}
	local out : {number} = {}
	for _, part in ipairs({ ... }) do
		for _, v in ipairs(part) do out[#out + 1] = v end
	end
	return out
end

local GLYPHS : {string : {{number}}} = {
	["0"] = { arc({}, 0.3, 0.5, 0.3, 0.5, 0, 360) },
	["1"] = { { 0.12, 0.78, 0.33, 1, 0.33, 0 }, { 0.12, 0, 0.54, 0 } },
	["2"] = { join(arc({}, 0.3, 0.72, 0.29, 0.28, 160, -35), { 0, 0, 0.6, 0 }) },
	["3"] = { arc({}, 0.29, 0.75, 0.26, 0.25, 155, -90), arc({}, 0.3, 0.27, 0.3, 0.27, 90, -155) },
	["4"] = { { 0.46, 0, 0.46, 1, 0, 0.32, 0.6, 0.32 } },
	["5"] = { join({ 0.56, 1, 0.08, 1, 0.04, 0.56 }, arc({}, 0.3, 0.31, 0.3, 0.31, 125, -145)) },
	["6"] = { arc({}, 0.33, 0.52, 0.3, 0.48, 70, 190), arc({}, 0.3, 0.3, 0.3, 0.3, 180, -180) },
	["7"] = { { 0, 1, 0.6, 1, 0.2, 0 } },
	["8"] = { arc({}, 0.3, 0.76, 0.25, 0.24, -90, 270), arc({}, 0.3, 0.27, 0.3, 0.27, 90, 450) },
	["9"] = { arc({}, 0.3, 0.7, 0.3, 0.3, 0, 360), arc({}, 0.27, 0.48, 0.3, 0.48, 10, -110) },
	["%"] = { { 0, 0, 0.6, 1 }, arc({}, 0.12, 0.85, 0.12, 0.15, 0, 360), arc({}, 0.48, 0.15, 0.12, 0.15, 0, 360) },
	["."] = { arc({}, 0.3, 0.04, 0.04, 0.04, 0, 360) },
	["-"] = { { 0.1, 0.48, 0.5, 0.48 } },
	["^"] = { { 0.3, 0, 0.3, 1 }, { 0.02, 0.7, 0.3, 1, 0.58, 0.7 } },
	["v"] = { { 0.3, 1, 0.3, 0 }, { 0.02, 0.3, 0.3, 0, 0.58, 0.3 } },
	["S"] = { join(arc({}, 0.3, 0.76, 0.27, 0.24, 20, 270), arc({}, 0.3, 0.26, 0.3, 0.26, 90, -200)) },
	-- lowercase m: a stem and two arches, x-height 0.62
	["m"] = { { 0.02, 0, 0.02, 0.62 }, join(arc({}, 0.16, 0.44, 0.14, 0.18, 180, 0), { 0.3, 0 }),
		join(arc({}, 0.44, 0.44, 0.14, 0.18, 180, 0), { 0.58, 0 }) },
	-- (a space has no strokes: it only advances)
}
local ADVANCE = 0.85           -- character pitch (box width + gap)

local function straight(x0 : number, y0 : number, z0 : number, x1 : number, y1 : number, z1 : number, color : Vec4f, width : number) : Builtin.Type.EdgeRenderable.Edge
	local len = math.sqrt((x1 - x0) ^ 2 + (y1 - y0) ^ 2)
	if len < 0.02 then return nil end
	local ok, e = pcall(function() : Builtin.Type.EdgeRenderable.Edge
		local s = api.type.EdgeGeometry.Straight.new()
		s.pos = { api.type.Vec2f.new(x0, y0), api.type.Vec2f.new(x1, y1) }
		local g = api.type.EdgeGeometry.new()
		g.straight = s
		g.height = api.type.Vec2f.new(z0, z1)
		g.width = 1.0
		g.length = len
		local edge = builtin.type.EdgeRenderable.Edge.new(g)
		edge.colors = { color, color, color }
		edge.stepSize = 1
		edge.width = width
		edge.offsetZ = 1.0
		return edge
	end)
	return ok and e or nil
end

local function push(list : {Builtin.Type.EdgeRenderable.Edge}, e : Builtin.Type.EdgeRenderable.Edge)
	if e then list[#list + 1] = e end
end

-- camera: distance (for the text size) and the screen's right / up directions on the ground
local function camera() : number, number, number, number, number
	local dist, angle = 600.0, 0.0
	pcall(function()
		local d = api.gui.camera.getCameraData()
		dist = d[3] or dist
		angle = d[4] or angle
	end)
	-- the camera's angle points from the screen's top towards the viewer (the text came out upside
	-- down taking it as the view direction): screen-up on the ground is against it, screen-right is
	-- screen-up turned clockwise
	local ux, uy = -math.cos(angle), -math.sin(angle)
	return dist, uy, -ux, ux, uy
end

-- edges for one tag's lines of text, centred at (x, y)
local function drawLines(out : {Builtin.Type.EdgeRenderable.Edge}, x : number, y : number, z : number, lines : {string},
		size : number, rx : number, ry : number, ux : number, uy : number)
	local w = size * 0.11
	local lineH = size * 1.5
	local maxChars = 0
	for _, l in ipairs(lines) do maxChars = math.max(maxChars, #l) end
	local boxW = (maxChars * ADVANCE - 0.25 + 0.8) * size
	local boxH = #lines * lineH + 0.3 * size
	local function at(u : number, v : number) : number, number
		return x + rx * u + ux * v, y + ry * u + uy * v
	end
	-- filled background: one strip across the box, as wide as the box is high (drawn first: the
	-- frame and text go on top)
	do
		local ax, ay = at(-boxW / 2, 0)
		local bx, by = at(boxW / 2, 0)
		push(out, straight(ax, ay, z, bx, by, z, FILL, boxH))
	end
	-- frame
	local corners = { { -boxW / 2, -boxH / 2 }, { boxW / 2, -boxH / 2 }, { boxW / 2, boxH / 2 }, { -boxW / 2, boxH / 2 } }
	for i = 1, 4 do
		local a, b = corners[i], corners[i % 4 + 1]
		local ax, ay = at(a[1], a[2])
		local bx, by = at(b[1], b[2])
		push(out, straight(ax, ay, z, bx, by, z, FRAME, w * 0.8))
	end
	-- text, top line first
	for li, text in ipairs(lines) do
		local v0 = boxH / 2 - 0.15 * size - li * lineH + 0.25 * size
		local u0 = -(#text * ADVANCE - 0.25) * size / 2
		for ci = 1, #text do
			local glyph = GLYPHS[text:sub(ci, ci)]
			if glyph then
				local cu = u0 + (ci - 1) * ADVANCE * size
				for _, stroke in ipairs(glyph) do
					for k = 1, #stroke - 3, 2 do
						local ax, ay = at(cu + stroke[k] * size, v0 + stroke[k + 1] * size)
						local bx, by = at(cu + stroke[k + 2] * size, v0 + stroke[k + 3] * size)
						push(out, straight(ax, ay, z, bx, by, z, TEXT, w))
					end
				end
			end
		end
	end
end

local function tagEdges(tags : {Tag}) : {Builtin.Type.EdgeRenderable.Edge}
	local out : {Builtin.Type.EdgeRenderable.Edge} = {}
	if #tags == 0 then return out end
	local dist, rx, ry, ux, uy = camera()
	local size = math.max(1.2, math.min(30, dist * 0.012))
	for _, t in ipairs(tags) do
		local lines : {string} = {}
		if t.speed then lines[#lines + 1] = "S" .. string.format("%.0f", t.speed) end
		if t.grade and math.abs(t.grade) >= 0.5 then
			lines[#lines + 1] = (t.grade > 0 and "^" or "v") .. string.format("%.0f", math.abs(t.grade)) .. "%"
		end
		if #lines > 0 then drawLines(out, t.x, t.y, t.z + LIFT, lines, size, rx, ry, ux, uy) end
	end
	return out
end

-- Boxed one-line labels (e.g. block lengths), sized and turned like the tags
local function labelEdges(labels : {Label}) : {Builtin.Type.EdgeRenderable.Edge}
	local out : {Builtin.Type.EdgeRenderable.Edge} = {}
	if #labels == 0 then return out end
	local dist, rx, ry, ux, uy = camera()
	local size = math.max(1.2, math.min(30, dist * 0.012))
	for _, l in ipairs(labels) do
		if l.text and #l.text > 0 then drawLines(out, l.x, l.y, l.z + LIFT, { l.text }, size, rx, ry, ux, uy) end
	end
	return out
end

-- A tag per proposal segment: speed = the fastest lane's limit, incline along the segment.
local function tagsFor(segs : {Proposal.SegmentAndEntity}) : {Builtin.Type.EdgeRenderable.Edge}
	local tags : {Tag} = {}
	for _, seg in ipairs(segs or {}) do
		pcall(function()
			local c = seg.comp
			local p0, p1, t0, t1 = c.position0, c.position1, c.tangent0, c.tangent1
			-- midpoint of the Hermite curve
			local x = 0.5 * (p0.x + p1.x) + 0.125 * (t0.x - t1.x)
			local y = 0.5 * (p0.y + p1.y) + 0.125 * (t0.y - t1.y)
			local z = 0.5 * (p0.z + p1.z) + 0.125 * (t0.z - t1.z)
			local len = math.sqrt((p1.x - p0.x) ^ 2 + (p1.y - p0.y) ^ 2)
			if len < 8 then return end           -- too short for a readable tag
			local speed = 0.0
			for _, lc in ipairs(c.laneConfigs or {}) do speed = math.max(speed, lc.speed or 0) end
			tags[#tags + 1] = {
				x = x, y = y, z = z,
				speed = speed > 0 and speed * 3.6 or nil,
				grade = (p1.z - p0.z) / len * 100,
			}
		end)
	end
	return tagEdges(tags)
end

local M : GroundText = { tagsFor = tagsFor, tagEdges = tagEdges, labelEdges = labelEdges }
return M
