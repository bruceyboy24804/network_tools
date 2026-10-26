-- Network Tools: tags in the world, like the game's street / track builder shows - a speed row
-- (speed icon + km/h) and, when not level, a gradient row (slope arrow + %), plus whatever a tool
-- adds. The game draws its own tags natively and its HUD icons don't take segments (verified: the
-- HUD icon manager never asks for BASE_EDGE), so these are ordinary GUI widgets on a full-screen
-- layer (builtin.FullScreenComponent, as the game's town layer legend), each moved every frame to
-- its world point's place on screen (api.gui.camera.world2Screen) - the way the game's callouts are
-- placed (a FloatingLayoutChild at h / v, a share of the screen, with an anchorPoint).
--
-- Every tool adds labels.node() to its children, after its preview (shared/ntools_preview): the
-- preview's new segments are tagged by themselves through labels.proposal(), which the preview
-- calls - tags for this render only, shown by node(). A segment's tag shows:
--   always      speed (the lane's limit, or the curve's where that is lower), gradient, the curve
--               radius where it lowers the speed, bridge / tunnel with the height over / under the
--               ground, and on one tag of the preview the total length
--   on hover    (the tag nearest the cursor) length, radius, height over the ground, the type
--   colour      amber past the player's build limits (gradient / radius), red past the type's own
-- A tool's own tags: labels.set({ [entity] = Tag, ... }, { Point, ... }) every render
-- (labels.set({}) when there are none):
--   entity - a segment (tag at its middle, as above) or a node (tag at the node)
--   Tag / Point fields (all optional): grade (% - segments: nil = their own), speed (km/h, points),
--   text, rows / detail ({ icon, text } rows always shown / shown on hover), level (0 / 1 amber /
--   2 red). Points also take x, y, z.

local builtin = ug_require "::/gui/main/builtin.lua" as Builtin
local engine_react_util = ug_require "::/gui/main/engine_react_util.tl" as EngineReactUtil
local react = ug_require "::/gui/main/react.lua" as React

local record Row
	icon : string
	text : string
end

local record Tag
	grade : number
	text : string
	rows : {Row}
	detail : {Row}
	level : integer
end

local record Point
	x : number
	y : number
	z : number
	grade : number
	speed : number        -- km/h
	text : string
	rows : {Row}
	detail : {Row}
	level : integer
end

local record Labels
	set : function(tags : {Engine.Entity : Tag}, points? : {Point})
	proposal : function(sp : SimpleProposal)
	node : function() : TreeNodeId
	clear : function()
	icons : {string : string}
end

do ((require "network_tools_1::/gui/construction/tools/shared/ntools_debug.script.tl" as {string : any}).log as function(string))("[network_tools] labels script loaded (v5: radius, warnings, length, bridges, hover detail)") end

local ICON_DIR = "::/gui/construction/build_control/"
local ICONS : {string : string} = {
	speed = ICON_DIR .. "symbol_speed_16.tga",
	bridge = ICON_DIR .. "infrastructure_bridge_32.tga",
	tunnel = ICON_DIR .. "infrastructure_tunnel_32.tga",
	crossing = ICON_DIR .. "infrastructure_railroad_crossing_32.tga",
	up = ICON_DIR .. "symbol_arrow_straight_up_20.tga",
	down = ICON_DIR .. "symbol_arrow_straight_down_20.tga",
	warning = ICON_DIR .. "symbol_x_20.tga",
	ok = ICON_DIR .. "symbol_check_20.tga",
	radius = "::/gui/construction/street_builder/build_mode_street_curve.tga",
	angle = "::/gui/construction/street_builder/symbol_build_mode_angle.tga",
	height = "::/gui/construction/street_builder/symbol_build_mode_height.tga",
	-- our own (icons/labels): the game has only preview photos for these
	switch = "network_tools_1::/gui/icons/labels/ntools_label_split.tga",
	join = "network_tools_1::/gui/icons/labels/ntools_label_join.tga",
	signal = "network_tools_1::/gui/icons/labels/ntools_label_signal.tga",
	exit = "network_tools_1::/gui/icons/labels/ntools_label_exit.tga",
	entry = "network_tools_1::/gui/icons/labels/ntools_label_entry.tga",
	user = "network_tools_1::/gui/icons/labels/ntools_label_user.tga",
}
local function slopeIcon(level : integer) : string
	return ICON_DIR .. "symbol_slope_" .. tostring(level) .. "_20.tga"
end

local LIFT = 2.0              -- metres above the road / node the tag's bottom sits at
local MAX_DIST = 4000.0       -- no tags further than this from the camera (the Range setting's default)

-- the label settings (the panel's Settings tab, shared/ntools_options): labels, labelSpeed,
-- labelGrade, labelRadius, labelHeight, labelTotal, labelDetail, labelSize, labelRange
local sharedOpts = (require "network_tools_1::/gui/construction/tools/shared/ntools_options.script.tl" as {string : {string : any}}).opts
local function setting(k : string) : any return sharedOpts and sharedOpts[k] end
local function maxDist() : number
	local r = setting("labelRange") as number
	return (r and r > 0) and r or MAX_DIST
end
local FAR_DIST = 1500.0       -- every tag beyond this: only the one that matters most is shown
local SMALL_DIST = 600.0      -- tags beyond this are drawn compact (smaller text and icons)
local MARGIN = 60             -- px: tags this far off screen are still placed (they slide in)
local HOVER_PX = 110          -- px: the tag nearest the cursor within this shows its detail
local STRAIGHT_R = 5000       -- m: curves wider than this count as straight
local MIN_TAG_LENGTH = 8.0    -- m: preview segments shorter than this get no tag

-- entity -> tag and the free points; replaced wholesale by set()
local g_tags : {Engine.Entity : Tag} = {}
local g_points : {Point} = {}
-- the preview's segment tags: gathered during a render (proposal()), shown from node() on
local g_pendingPreview : {Point} = {}
local g_preview : {Point} = {}

---------------------------------------------------------------------------------------------------
-- Segment geometry and type limits

-- the game's nine slope arrows: 0 = level, +-1 .. +-4 steeper (2 % a step)
local function slopeLevel(grade : number) : integer
	local a = math.abs(grade)
	if a < 0.5 then return 0 end
	local l = math.floor(math.min(4, math.floor(a / 2) + 1))
	return grade < 0 and -l or l
end

-- a point on the segment's curve (cubic Hermite, t in 0..1) and its first / second derivatives
local function hermite(e : Engine.Component.BaseEdge, t : number) : number, number, number
	local p0, p1, t0, t1 = e.position0, e.position1, e.tangent0, e.tangent1
	local t2, t3 = t * t, t * t * t
	local a, b, c, d = 2 * t3 - 3 * t2 + 1, t3 - 2 * t2 + t, -2 * t3 + 3 * t2, t3 - t2
	return a * p0.x + b * t0.x + c * p1.x + d * t1.x,
		a * p0.y + b * t0.y + c * p1.y + d * t1.y,
		a * p0.z + b * t0.z + c * p1.z + d * t1.z
end

-- the tightest radius along the segment, in plan (nil = straight)
local function minRadius(e : Engine.Component.BaseEdge) : number
	local p0, p1, t0, t1 = e.position0, e.position1, e.tangent0, e.tangent1
	local best = 0.0
	for i = 0, 10 do
		local t = i / 10
		-- first and second derivatives of the Hermite curve
		local a1, b1, c1, d1 = 6 * t * t - 6 * t, 3 * t * t - 4 * t + 1, -6 * t * t + 6 * t, 3 * t * t - 2 * t
		local a2, b2, c2, d2 = 12 * t - 6, 6 * t - 4, -12 * t + 6, 6 * t - 2
		local dx = a1 * p0.x + b1 * t0.x + c1 * p1.x + d1 * t1.x
		local dy = a1 * p0.y + b1 * t0.y + c1 * p1.y + d1 * t1.y
		local ddx = a2 * p0.x + b2 * t0.x + c2 * p1.x + d2 * t1.x
		local ddy = a2 * p0.y + b2 * t0.y + c2 * p1.y + d2 * t1.y
		local v2 = dx * dx + dy * dy
		if v2 > 1e-6 then
			local k = math.abs(dx * ddy - dy * ddx) / (v2 ^ 1.5)
			if k > best then best = k end
		end
	end
	if best <= 1 / STRAIGHT_R then return nil end
	return 1 / best
end

-- length along the curve (3D)
local function curveLength(e : Engine.Component.BaseEdge) : number
	local len = 0.0
	local px, py, pz = hermite(e, 0)
	for i = 1, 16 do
		local x, y, z = hermite(e, i / 16)
		len = len + math.sqrt((x - px) ^ 2 + (y - py) ^ 2 + (z - pz) ^ 2)
		px, py, pz = x, y, z
	end
	return len
end

local record Limits
	name : string
	maxGrade : number          -- % the type allows at all
	maxGradeBuild : number     -- % the player may build
	minR : number
	minRBuild : number
	coeffs : {number}
end
local g_limits : {string : Limits} = {}
-- the type's speed coefficients as a plain list: the game hands them over as userdata (declared
-- {number}), which # can't measure - read by index, else as a vector's x / y / z
local function coeffList(v : any) : {number}
	if v == nil then return nil end
	local out : {number} = {}
	pcall(function()
		local t = v as {number}
		for i = 1, 3 do
			local x = t[i]
			if type(x) ~= "number" then return end
			out[i] = x
		end
	end)
	if #out < 3 then
		out = {}
		pcall(function()
			local r = v as {string : number}
			out = { r.x, r.y, r.z }
		end)
	end
	return #out == 3 and out or nil
end
local function limitsOf(templateName : string) : Limits
	if not templateName or templateName == "" then return nil end
	local cached = g_limits[templateName]
	if cached ~= nil then return cached end
	local ok, lim = pcall(function() : Limits
		local id = api.res.streetTemplateRep.find(templateName)
		if not id or id < 0 then return nil end
		local t = api.res.streetTemplateRep.get(id)
		local name = templateName
		pcall(function() if t.description.name and t.description.name ~= "" then name = t.description.name end end)
		return {
			name = name,
			maxGrade = (t.maxSlope or 0) * 100,
			maxGradeBuild = (t.maxSlopeBuild or 0) * 100,
			minR = t.minCurveRadius or 0,
			minRBuild = t.minCurveRadiusBuild or 0,
			coeffs = coeffList(t.speedCoeffs),
		}
	end)
	g_limits[templateName] = ok and lim or nil
	return g_limits[templateName]
end

-- the curve's speed limit, km/h, from the type's speed coefficients: a * (radius + b) ^ c m/s
local function curveSpeed(lim : Limits, radius : number) : number
	if not lim or not radius or not lim.coeffs or #lim.coeffs < 3 then return nil end
	local c = lim.coeffs
	return c[1] * (radius + c[2]) ^ c[3] * 3.6
end

local function terrainAt(x : number, y : number) : number
	local ok, h = pcall(function() : number return api.engine.terrain.getHeightAt(api.type.Vec2f.new(x, y)) end)
	return ok and h or nil
end

local function fmtLength(m : number) : string
	if m >= 1000 then return string.format("%.2f km", m / 1000) end
	return string.format("%.0f m", m)
end

-- A segment's tag: position and rows. laneSpeed: km/h, the lane's limit (nil = from its lanes);
-- trueSpeed: km/h, the engine's own figure for a built segment (lane and curve), used as is.
local function segmentTag(e : Engine.Component.BaseEdge, trueSpeed : number) : Point
	local mx, my, mz = hermite(e, 0.5)
	local dx, dy = e.position1.x - e.position0.x, e.position1.y - e.position0.y
	local plan = math.sqrt(dx * dx + dy * dy)
	local grade = plan > 0.5 and (e.position1.z - e.position0.z) / plan * 100 or 0
	local lim = limitsOf(e.roadTemplate)
	local radius = minRadius(e)
	local length = curveLength(e)

	local laneSpeed = 0.0
	for __, lc in ipairs(e.laneConfigs or {}) do laneSpeed = math.max(laneSpeed, lc.speed or 0) end
	laneSpeed = laneSpeed * 3.6
	local cSpeed = curveSpeed(lim, radius)
	local speed = trueSpeed
	local curveLimits = false
	if not speed then
		speed = laneSpeed > 0 and laneSpeed or nil
		if cSpeed and (not speed or cSpeed < speed) then
			speed = cSpeed
			curveLimits = true
		end
	elseif cSpeed and laneSpeed > 0 and cSpeed < laneSpeed - 1 then
		curveLimits = true
	end

	local level = 0
	local rows : {Row} = {}
	local detail : {Row} = {}
	if lim then
		local g = math.abs(grade)
		if lim.maxGrade > 0 and g > lim.maxGrade + 0.05 then level = 2
		elseif lim.maxGradeBuild > 0 and g > lim.maxGradeBuild + 0.05 then level = 1 end
		if radius then
			if lim.minR > 0 and radius < lim.minR then level = 2
			elseif lim.minRBuild > 0 and radius < lim.minRBuild and level < 1 then level = 1 end
		end
	end
	local radiusRow : Row = radius and { icon = ICONS.radius, text = string.format("R %.0f m", radius) } or nil
	if radiusRow then
		if curveLimits or level > 0 then rows[#rows + 1] = radiusRow else detail[#detail + 1] = radiusRow end
	end

	-- over / under the ground: bridges and tunnels always, other segments on hover
	local ground = terrainAt(mx, my)
	local kind = e.type
	if kind == api.type["enum"].BaseEdgeType.BRIDGE then
		rows[#rows + 1] = { icon = ICONS.bridge, text = ground and string.format("%.0f m", mz - ground) or "" }
	elseif kind == api.type["enum"].BaseEdgeType.TUNNEL then
		rows[#rows + 1] = { icon = ICONS.tunnel, text = ground and string.format("%.0f m", ground - mz) or "" }
	elseif ground and math.abs(mz - ground) >= 0.5 then
		-- (in words: no icon at tag size says "height above the ground" clearly)
		detail[#detail + 1] = { text = string.format(mz > ground and _("%.1f m above ground") or _("%.1f m below ground"), math.abs(mz - ground)) }
	end
	detail[#detail + 1] = { text = _("Length") .. " " .. fmtLength(length) }
	if lim then detail[#detail + 1] = { text = lim.name } end

	return {
		x = mx, y = my, z = mz,
		speed = speed, grade = grade,
		rows = rows, detail = detail, level = level,
	}
end

-- engine speed of a built segment (fastest lane, the lower of the road's limit and the curve's)
local function builtSpeed(entity : Engine.Entity) : number
	local ok, v = pcall(function() : number
		local tn = api.engine.getComponent(entity, api.type.ComponentType.TRANSPORT_NETWORK) as Engine.Component.TransportNetwork
		if not tn then return nil end
		local best = 0.0
		for __, e in ipairs(tn.edges or {}) do
			local s = math.min(e.speedLimit or 0, (e.curveSpeedLimit and e.curveSpeedLimit > 0) and e.curveSpeedLimit or math.huge)
			if s > best then best = s end
		end
		return best > 0 and best * 3.6 or nil
	end)
	return ok and v or nil
end

---------------------------------------------------------------------------------------------------
-- Placing the tags on screen

-- What one tag shows and where (shares of the screen): the overlay's state, compared deeply each
-- frame, so the tags re-render only when one moves or changes
local record Placed
	key : string
	h : number
	v : number
	level : integer
	rows : {Row}
	small : boolean           -- compact (far from the camera)
end

local record Cam
	w : number
	h : number
	ex : number
	ey : number
	ez : number
	fx : number
	fy : number
	fz : number
end

local function camera() : Cam
	local ok, c = pcall(function() : Cam
		local size = api.gui.camera.getSize()
		local eye = api.gui.camera.getEye()
		local ctr = api.gui.camera.getCenter()
		if not size or size.x <= 0 or size.y <= 0 then return nil end
		return {
			w = size.x, h = size.y,
			ex = eye.x, ey = eye.y, ez = eye.z,
			fx = ctr.x - eye.x, fy = ctr.y - eye.y, fz = ctr.z - eye.z,
		}
	end)
	return ok and c or nil
end

-- a world point's place on screen in pixels (nil: behind the camera, too far or well off screen)
local g_loggedProjection = false
local function project(cam : Cam, x : number, y : number, z : number) : number, number
	local dx, dy, dz = x - cam.ex, y - cam.ey, z - cam.ez
	if dx * cam.fx + dy * cam.fy + dz * cam.fz <= 0 then return nil end
	local md = maxDist()
	if dx * dx + dy * dy + dz * dz > md * md then return nil end
	local ok, s = pcall(function() : Vec2i
		return api.gui.camera.world2Screen(api.type.Vec3f.new(x, y, z))
	end)
	if not ok or not s then return nil end
	if not g_loggedProjection then
		g_loggedProjection = true
		do ((require "network_tools_1::/gui/construction/tools/shared/ntools_debug.script.tl" as {string : any}).log as function(string))("[network_tools] labels: screen " .. tostring(cam.w) .. "x" .. tostring(cam.h)
			.. ", first tag at " .. tostring(s.x) .. "," .. tostring(s.y)) end
	end
	if s.x < -MARGIN or s.y < -MARGIN or s.x > cam.w + MARGIN or s.y > cam.h + MARGIN then return nil end
	return s.x, s.y
end

-- the cursor on screen (through the terrain point under it), or nil
local function cursorPx(cam : Cam) : number, number
	local ok, x, y = pcall(function() : number, number
		if not api.gui.mouse.hasTerrainPosition() then return nil, nil end
		local m = api.gui.mouse.getTerrainPosition()
		local s = api.gui.camera.world2Screen(m)
		return s.x, s.y
	end)
	if not ok then return nil end
	return x, y
end

-- the rows a tag shows, top first (each kind only where the Settings tab leaves it on)
local function rowsOf(p : Point, withDetail : boolean) : {Row}
	local out : {Row} = {}
	if p.speed and setting("labelSpeed") ~= false then out[#out + 1] = { icon = ICONS.speed, text = string.format("%.0f", p.speed) } end
	if p.grade and math.abs(p.grade) >= 0.5 and setting("labelGrade") ~= false then
		out[#out + 1] = { icon = slopeIcon(slopeLevel(p.grade)), text = string.format("%.0f%%", math.abs(p.grade)) }
	end
	local function wanted(r : Row) : boolean
		if r.icon == ICONS.radius then return setting("labelRadius") ~= false end
		if r.icon == ICONS.bridge or r.icon == ICONS.tunnel then return setting("labelHeight") ~= false end
		if r.text and r.text:find(_("Total"), 1, true) == 1 then return setting("labelTotal") ~= false end
		return true
	end
	for __, r in ipairs(p.rows or {}) do
		if wanted(r) then out[#out + 1] = r end
	end
	if p.text and p.text ~= "" then out[#out + 1] = { text = p.text } end
	if withDetail and setting("labelDetail") ~= false then
		for __, r in ipairs(p.detail or {}) do
			if wanted(r) then out[#out + 1] = r end
		end
	end
	return out
end

local record Candidate
	key : string
	px : number
	py : number
	point : Point
end

-- every published tag that is on screen, in a stable order; the one nearest the cursor with detail
local function placeAll() : {Placed}
	local out : {Placed} = {}
	-- (Settings: preview labels off)
	if setting("labels") == false then return out end
	local cam = camera()
	if not cam then return out end
	local cands : {Candidate} = {}
	local function add(key : string, p : Point)
		if not p then return end
		local px, py = project(cam, p.x, p.y, p.z + LIFT)
		if px then cands[#cands + 1] = { key = key, px = px, py = py, point = p } end
	end

	local entities : {Engine.Entity} = {}
	for e in pairs(g_tags) do entities[#entities + 1] = e end
	table.sort(entities)
	for __, entity in ipairs(entities) do
		pcall(function()
			if not entity or entity < 0 or not api.engine.entityExists(entity) then return end
			local tag = g_tags[entity]
			local p : Point
			local e = api.engine.getComponent(entity, api.type.ComponentType.BASE_EDGE) as Engine.Component.BaseEdge
			if e then
				p = segmentTag(e, builtSpeed(entity))
				if tag.grade ~= nil then p.grade = tag.grade end
			else
				local n = api.engine.getComponent(entity, api.type.ComponentType.BASE_NODE) as Engine.Component.BaseNode
				if not n then return end
				p = { x = n.position.x, y = n.position.y, z = n.position.z, grade = tag.grade, rows = {}, detail = {}, level = 0 }
			end
			for __, r in ipairs(tag.rows or {}) do p.rows[#p.rows + 1] = r end
			for __, r in ipairs(tag.detail or {}) do p.detail[#p.detail + 1] = r end
			p.text = tag.text
			if tag.level and tag.level > (p.level or 0) then p.level = tag.level end
			add("e" .. tostring(entity), p)
		end)
	end
	for i, pt in ipairs(g_points) do add("p" .. tostring(i), pt) end
	for i, pt in ipairs(g_preview) do add("s" .. tostring(i), pt) end

	-- the tag nearest the cursor, if near enough
	local hover = 0
	local cx, cy = cursorPx(cam)
	if cx then
		local best = HOVER_PX * HOVER_PX
		for i, c in ipairs(cands) do
			-- (the tag stands above its point: measure to its middle)
			local d = (c.px - cx) ^ 2 + (c.py - 20 - cy) ^ 2
			if d < best then best, hover = d, i end
		end
	end

	-- Like the game's own tags: never on top of each other, compact further out, and when the view
	-- is zoomed right out just the one that matters most. Placed in order - the hovered one, then
	-- warnings / errors, then the one with the total, then nearest first; a tag that would cover one
	-- already placed is left out (it comes back as the view zooms in).
	local scale = cam.w / 1920                       -- (screen px per UI px)
	local function dist2(c : Candidate) : number
		local p = c.point
		return (p.x - cam.ex) ^ 2 + (p.y - cam.ey) ^ 2 + (p.z - cam.ez) ^ 2
	end
	local function hasTotal(c : Candidate) : boolean
		for __, r in ipairs(c.point.rows or {}) do
			if r.text and r.text:find(_("Total"), 1, true) == 1 then return true end
		end
		return false
	end
	local zoomedOut = #cands > 0
	for __, c in ipairs(cands) do
		if dist2(c) <= FAR_DIST * FAR_DIST then zoomedOut = false; break end
	end
	local order : {integer} = {}
	for i in ipairs(cands) do order[#order + 1] = i end
	table.sort(order, function(a : integer, b : integer) : boolean
		if (a == hover) ~= (b == hover) then return a == hover end
		local la, lb = cands[a].point.level or 0, cands[b].point.level or 0
		if la ~= lb then return la > lb end
		local ta, tb = hasTotal(cands[a]), hasTotal(cands[b])
		if ta ~= tb then return ta end
		if zoomedOut then
			-- (all far: the one nearest the middle of the screen)
			local ca = (cands[a].px - cam.w / 2) ^ 2 + (cands[a].py - cam.h / 2) ^ 2
			local cb = (cands[b].px - cam.w / 2) ^ 2 + (cands[b].py - cam.h / 2) ^ 2
			if ca ~= cb then return ca < cb end
		end
		local da, db = dist2(cands[a]), dist2(cands[b])
		if da ~= db then return da < db end
		return a < b
	end)
	local taken : {{number}} = {}
	for __, i in ipairs(order) do
		if zoomedOut and #out >= 1 then break end
		local c = cands[i]
		local rows = rowsOf(c.point, i == hover)
		if #rows > 0 then
			-- (Settings: size 1 auto - compact far off, 2 always compact, 3 always full)
			local size = (setting("labelSize") as integer) or 1
			local small : boolean
			if size == 2 then small = true
			elseif size == 3 then small = false
			else small = dist2(c) > SMALL_DIST * SMALL_DIST end
			-- the box's rough size on screen (padding, an icon, ~9 / 7 px a character, 24 / 19 px a row)
			local chars = 0
			for __, r in ipairs(rows) do chars = math.max(chars, #(r.text or "") + (r.icon and 3 or 0)) end
			local w = (16 + chars * (small and 7 or 9)) * scale
			local h = (6 + #rows * (small and 19 or 24)) * scale
			local x0, x1, y0, y1 = c.px - w / 2, c.px + w / 2, c.py - h, c.py
			local clear = true
			if i ~= hover then
				for __, t in ipairs(taken) do
					if x0 < t[2] and x1 > t[1] and y0 < t[4] and y1 > t[3] then clear = false; break end
				end
			end
			if clear then
				taken[#taken + 1] = { x0, x1, y0, y1 }
				out[#out + 1] = { key = c.key, h = c.px / cam.w, v = c.py / cam.h, level = c.point.level or 0, rows = rows, small = small }
			end
		end
	end
	-- (a stable order, so the layer re-renders only when a tag moves or changes)
	table.sort(out, function(a : Placed, b : Placed) : boolean return a.key < b.key end)
	return out
end

-- A tag per new segment of a preview (see segmentTag); the total length goes on the tag nearest
-- the middle of the whole build. Segments too short for a tag are left out (but count in the total).
local g_loggedTagFail = false
local function proposal(sp : SimpleProposal)
	pcall(function()
		local tags : {Point} = {}
		local total, n = 0.0, 0
		local sx, sy, sz = 0.0, 0.0, 0.0
		for __, seg in ipairs(sp.streetProposal.edgesToAdd or {}) do
			local ok, err = pcall(function()
				local c = seg.comp
				total = total + curveLength(c)
				local plan = math.sqrt((c.position1.x - c.position0.x) ^ 2 + (c.position1.y - c.position0.y) ^ 2)
				if plan >= MIN_TAG_LENGTH then
					local p = segmentTag(c, nil)
					tags[#tags + 1] = p
					sx, sy, sz = sx + p.x, sy + p.y, sz + p.z
					n = n + 1
				end
			end)
			-- (a failing segment just has no tag: said once, so it isn't silent)
			if not ok and not g_loggedTagFail then
				g_loggedTagFail = true
				do ((require "network_tools_1::/gui/construction/tools/shared/ntools_debug.script.tl" as {string : any}).log as function(string))("[network_tools] labels: a preview segment's tag failed: " .. tostring(err)) end
			end
		end
		if n >= 2 then
			sx, sy, sz = sx / n, sy / n, sz / n
			local best, bi = math.huge, 0
			for i, p in ipairs(tags) do
				local d = (p.x - sx) ^ 2 + (p.y - sy) ^ 2 + (p.z - sz) ^ 2
				if d < best then best, bi = d, i end
			end
			if bi > 0 then
				local p = tags[bi]
				p.rows[#p.rows + 1] = { text = _("Total") .. " " .. fmtLength(total) }
			end
		end
		for __, p in ipairs(tags) do g_pendingPreview[#g_pendingPreview + 1] = p end
	end)
end

---------------------------------------------------------------------------------------------------
-- Drawing

-- styles set on the widgets themselves (the css rules drew no box in game): the box is the game's
-- tooltip surface tinted by level - its tooltip colour (AccentDark), its Warning, its Error - at
-- its tooltip transparency (0.9); the anchor puts the box's bottom middle on the world point
local g_boxStyles : {integer : StyleSheet} = {}
local g_colors : {string : {number}} = nil
local function gameColor(name : string, r : number, g : number, b : number) : Vec4f
	if g_colors == nil then
		local ok, c = pcall(function() : {string : {number}}
			return api.gui.genericRep.get(api.gui.genericRep.find("::/gui/main/default_colors.gres")).data as {string : {number}}
		end)
		g_colors = ok and c or {}
	end
	local c = g_colors[name]   -- { r, g, b, a }
	if c then return api.type.Vec4f.new(c[1], c[2], c[3], 0.9) end
	return api.type.Vec4f.new(r, g, b, 0.9)
end
local function boxStyle(level : integer) : StyleSheet
	level = level or 0
	if g_boxStyles[level] then return g_boxStyles[level] end
	local ok, st = pcall(function() : StyleSheet
		local s = api.gui.StyleSheet.new()
		local img = api.gui.NinePatch.new()
		img.fileName = "::/gui/builtin/tooltip/surface.tga"
		img.horizontal = { 0, 5, 7, 12 }
		img.vertical = { 0, 5, 7, 12 }
		s.backgroundImage1 = img
		if level >= 2 then s.backgroundColor1 = gameColor("Error", 0.80, 0.16, 0.14)
		elseif level == 1 then s.backgroundColor1 = gameColor("Warning", 0.85, 0.65, 0.13)
		else s.backgroundColor1 = gameColor("AccentDark", 0.30, 0.52, 0.78) end
		s.padding = api.type.Vec4f.new(3, 8, 3, 8)
		s.anchorPoint = api.type.Vec2f.new(0.5, 1)
		return s
	end)
	if not ok then ((require "network_tools_1::/gui/construction/tools/shared/ntools_debug.script.tl" as {string : any}).log as function(string))("[network_tools] labels: tag style failed: " .. tostring(st)) end
	g_boxStyles[level] = ok and st or nil
	return g_boxStyles[level]
end

-- icons all 20 px (the game's are 16 - 32; 16 on a compact tag), a small gap before the text
local g_iconStyles : {integer : StyleSheet} = {}
local function iconStyle(px : integer) : StyleSheet
	if g_iconStyles[px] then return g_iconStyles[px] end
	local ok, st = pcall(function() : StyleSheet
		local s = api.gui.StyleSheet.new()
		s.size = api.type.Vec2f.new(px, px)
		s.padding = api.type.Vec4f.new(0, 4, 0, 0)
		return s
	end)
	g_iconStyles[px] = ok and st or nil
	return g_iconStyles[px]
end

local function rowView(r : Row, small : boolean) : TreeNodeId
	local children : {TreeNodeId} = {}
	if r.icon then
		children[#children + 1] = builtin.ImageView{
			meta = { class = "ntools-edge-label-icon", mouseTransparent = true, styleSheet = iconStyle(small and 16 or 20) },
			path = r.icon,
		}
	end
	if r.text and r.text ~= "" then
		-- (compact: the game's smaller annotation text)
		children[#children + 1] = builtin.TextView{ meta = { mouseTransparent = true, class = small and "font-scale-annotation" or nil }, text = r.text }
	end
	return builtin.BoxLayout{ orientation = builtin.type.Orientation.Horizontal, children = children }
end

local function tagView(p : Placed) : TreeNodeId
	local rows : {TreeNodeId} = {}
	for __, r in ipairs(p.rows) do rows[#rows + 1] = rowView(r, p.small) end
	return builtin.Component{
		meta = { class = "ntools-edge-label", mouseTransparent = true, styleSheet = boxStyle(p.level) },
		layout = builtin.BoxLayout{
			orientation = builtin.type.Orientation.Vertical,
			children = rows,
		},
	}
end

-- The full-screen layer: polls the published tags, the camera and the cursor every frame
local LabelOverlay = react.RegisterRecipe("NtoolsLabelOverlay", function(_p : any) : TreeNodeId
	react.setMouseTransparent(true)
	react.setDisableFocusable(true)
	local placedUi = engine_react_util.useStepState(function() : {Placed}
		local ok, list = pcall(placeAll)
		return ok and list or {}
	end)
	local children : {TreeNodeId} = {}
	for __, p in ipairs(placedUi:old() or {}) do
		children[#children + 1] = builtin.FloatingLayoutChild{
			localKey = p.key,
			h = p.h,
			v = p.v,
			item = tagView(p),
		}
	end
	-- (stretched over the whole screen by the css - unstretched it is only as big as its tags, and
	-- every tag lands in one spot)
	return builtin.FloatingLayout{ meta = { class = "ntools-label-layer" }, children = children }
end)

local function set(tags : {Engine.Entity : Tag}, points? : {Point})
	g_tags = tags or {}
	g_points = points or {}
end

-- every tag gone (a tool closing: shared/ntools_preview clear())
local function clear()
	g_tags, g_points = {}, {}
	g_pendingPreview, g_preview = {}, {}
end

-- (called once per render, after the preview: this render's preview tags replace the last ones)
local function node() : TreeNodeId
	g_preview = g_pendingPreview
	g_pendingPreview = {}
	local ok, n = pcall(function() : TreeNodeId
		return builtin.FullScreenComponent{ recipe = LabelOverlay as Recipe<any>, param = {} }
	end)
	if not ok then
		do ((require "network_tools_1::/gui/construction/tools/shared/ntools_debug.script.tl" as {string : any}).log as function(string))("[network_tools] labels: full-screen layer failed: " .. tostring(n)) end
		return nil
	end
	return n
end

local M : Labels = { set = set, proposal = proposal, node = node, clear = clear, icons = ICONS }
return M
