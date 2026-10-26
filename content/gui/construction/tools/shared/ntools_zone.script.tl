-- Network Tools: a tinted footprint on the ground under a shape being placed (Generate),
-- drawn as a mission zone (api.gui.mission.setZone): the outline round the layout's nodes, pushed
-- out by `margin` so the roads' width is inside. It doesn't stop building (prohibitBuilding off).
--
-- show() is called every render; the zone is only sent again when its outline changed (each send
-- would start the zone's animation over). clear() when the shape is gone or the tool closes.

local record Pt
	x : number
	y : number
end

local g_last : {string : string} = {}
local g_failLogged = false

-- convex hull (Andrew's monotone chain), counter-clockwise
local function hull(pts : {Pt}) : {Pt}
	table.sort(pts, function(a : Pt, b : Pt) : boolean
		if a.x ~= b.x then return a.x < b.x end
		return a.y < b.y
	end)
	if #pts < 3 then return pts end
	local function cross(o : Pt, a : Pt, b : Pt) : number
		return (a.x - o.x) * (b.y - o.y) - (a.y - o.y) * (b.x - o.x)
	end
	local lower : {Pt} = {}
	for __, p in ipairs(pts) do
		while #lower >= 2 and cross(lower[#lower - 1], lower[#lower], p) <= 0 do lower[#lower] = nil end
		lower[#lower + 1] = p
	end
	local upper : {Pt} = {}
	for i = #pts, 1, -1 do
		local p = pts[i]
		while #upper >= 2 and cross(upper[#upper - 1], upper[#upper], p) <= 0 do upper[#upper] = nil end
		upper[#upper + 1] = p
	end
	lower[#lower] = nil
	upper[#upper] = nil
	for __, p in ipairs(upper) do lower[#lower + 1] = p end
	return lower
end

-- the outline round `nodes` (anything with x, y; entries without them are skipped), each corner moved
-- `margin` metres out from the middle
local function outline(nodes : {any}, margin : number) : {Pt}
	local pts : {Pt} = {}
	for __, n in ipairs(nodes) do
		local p = n as Pt
		if p and p.x and p.y then pts[#pts + 1] = { x = p.x, y = p.y } end
	end
	if #pts == 0 then return {} end
	local h = hull(pts)
	local cx, cy = 0.0, 0.0
	for __, p in ipairs(h) do cx, cy = cx + p.x, cy + p.y end
	cx, cy = cx / #h, cy / #h
	local out : {Pt} = {}
	for __, p in ipairs(h) do
		local dx, dy = p.x - cx, p.y - cy
		local l = math.sqrt(dx * dx + dy * dy)
		if l < 1e-6 then dx, dy, l = 1, 0, 1 end
		out[#out + 1] = { x = p.x + dx / l * margin, y = p.y + dy / l * margin }
	end
	-- a single node or a straight row: a small square round it instead of a sliver
	if #out < 3 then
		local m = math.max(margin, 5)
		return { { x = cx - m, y = cy - m }, { x = cx + m, y = cy - m }, { x = cx + m, y = cy + m }, { x = cx - m, y = cy + m } }
	end
	return out
end

local function clear(key : string)
	if g_last[key] == nil then return end
	g_last[key] = nil
	pcall(function() api.gui.mission.removeZone(key) end)
end

-- the footprint of `nodes` as zone `key`, tinted (r, g, b, a)
local function show(key : string, nodes : {any}, margin : number, r : number, g : number, b : number, a : number)
	local pts = outline(nodes, margin)
	if #pts < 3 then clear(key) return end
	local sig : {string} = { string.format("%.2f,%.2f,%.2f,%.2f", r, g, b, a) }
	for __, p in ipairs(pts) do sig[#sig + 1] = string.format("%.1f,%.1f", p.x, p.y) end
	local s = table.concat(sig, ";")
	if g_last[key] == s then return end
	local ok, err = pcall(function()
		local poly : {Vec2f} = {}
		for __, p in ipairs(pts) do poly[#poly + 1] = api.type.Vec2f.new(p.x, p.y) end
		-- draw, the colour, no building ban, no animation (it follows every drag)
		api.gui.mission.setZone(key, poly, true, api.type.Vec4f.new(r, g, b, a), false, false)
	end)
	if ok then
		g_last[key] = s
	elseif not g_failLogged then
		g_failLogged = true
		do ((require "network_tools_1::/gui/construction/tools/shared/ntools_debug.script.tl" as {string : any}).log as function(string))("[network_tools] footprint zone: " .. tostring(err)) end
		g_last[key] = s   -- not again every frame
	end
end

local record M
	show : function(key : string, nodes : {any}, margin : number, r : number, g : number, b : number, a : number)
	clear : function(key : string)
end
local m : M = { show = show, clear = clear }
return m
