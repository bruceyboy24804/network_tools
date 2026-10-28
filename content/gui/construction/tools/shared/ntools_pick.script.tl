-- Network Tools: picking a track segment from the gaps between its sleepers.
--
-- The game's Selector reports a segment only while the cursor is over its rail / sleeper mesh, so
-- the gaps between sleepers (and the ballast beside them) pick nothing. wrap() adds a fallback to a
-- tool's Selector params: when the Selector reports no segment, the segment whose centreline passes
-- within the track bed's width of the mouse - measured on screen, so bridges, embankments and water
-- are right - is hovered and clicked instead. Roads are wide enough for the Selector; tunnels are
-- underground.
--
--   builtin.Selector(pick.wrap{ onSelect = ..., onHover = ..., filter = ... })

local HALF_WIDTH_M : number = 1.3     -- sleeper half-length
local PICK_RADIUS_PX : number = 8.0   -- the game cursor's hit circle
local SEARCH_M : number = 150.0       -- octree radius round the cursor's ground point
local SAMPLES : integer = 12
local CACHE_S : number = 0.4          -- reuse a result for a cursor that barely moved
local STALE_S : number = 0.25         -- no Selector report for this long while the mouse moves: it found nothing

local record Pick
	wrap : function(p : {string : any}) : {string : any}
	edgeAt : function(terrain : Vec3f) : Engine.Entity
end

local function isGamepad() : boolean
	local ok, g = pcall(function() : boolean
		return api.util.getInputMode() == api.type["enum"].InputMode.Gamepad
	end)
	return ok and g == true
end

-- the segment as a polyline (Hermite curve at SAMPLES + 1 points)
local function sample(e : Engine.Component.BaseEdge) : {Vec3f}
	local p0, p1, t0, t1 = e.position0, e.position1, e.tangent0, e.tangent1
	local pts : {Vec3f} = {}
	for i = 0, SAMPLES do
		local t = i / SAMPLES
		local t2 = t * t
		local t3 = t2 * t
		local h00, h10, h01, h11 = 2 * t3 - 3 * t2 + 1, t3 - 2 * t2 + t, -2 * t3 + 3 * t2, t3 - t2
		pts[#pts + 1] = api.type.Vec3f.new(
			h00 * p0.x + h10 * t0.x + h01 * p1.x + h11 * t1.x,
			h00 * p0.y + h10 * t0.y + h01 * p1.y + h11 * t1.y,
			h00 * p0.z + h10 * t0.z + h01 * p1.z + h11 * t1.z)
	end
	return pts
end

-- distance from (px, py) to the segment a-b, and the clamped parameter along it
local function segDistance(px : number, py : number, ax : number, ay : number, bx : number, by : number) : number, number
	local dx, dy = bx - ax, by - ay
	local lenSq = dx * dx + dy * dy
	local t = 0.0
	if lenSq > 1e-9 then
		t = math.max(0, math.min(1, ((px - ax) * dx + (py - ay) * dy) / lenSq))
	end
	local qx, qy = ax + t * dx, ay + t * dy
	return math.sqrt((px - qx) ^ 2 + (py - qy) ^ 2), t
end

local g_cacheX, g_cacheY, g_cacheTime = 0.0, 0.0, 0.0
local g_cacheEdge : Engine.Entity = -1
local g_cacheValid = false

-- The track segment under the mouse, nearest the camera, or -1. `terrain`: any point on the camera
-- ray through the mouse (api.gui.mouse.getTerrainPosition()), whose screen position is the mouse's.
local function edgeAt(terrain : Vec3f) : Engine.Entity
	if not terrain then return -1 end
	if g_cacheValid and os.clock() - g_cacheTime < CACHE_S
			and (terrain.x - g_cacheX) ^ 2 + (terrain.y - g_cacheY) ^ 2 < 0.25
			and (g_cacheEdge < 0 or api.engine.entityExists(g_cacheEdge)) then
		return g_cacheEdge
	end
	local mouse = api.gui.camera.world2Screen(terrain)
	local mx, my = mouse.x, mouse.y
	local eye, center = api.gui.camera.getEye(), api.gui.camera.getCenter()
	local fx, fy, fz = center.x - eye.x, center.y - eye.y, center.z - eye.z
	local function inFront(p : Vec3f) : boolean
		return (p.x - eye.x) * fx + (p.y - eye.y) * fy + (p.z - eye.z) * fz > 0
	end
	local tunnel = api.type["enum"].BaseEdgeType.TUNNEL
	local best : Engine.Entity = -1
	local bestDist = math.huge
	local nearby = api.engine.util.octree.findEntitiesInCircle(api.type.Vec2f.new(terrain.x, terrain.y), SEARCH_M,
		api.type.ComponentType.BASE_EDGE)
	for __, cand in ipairs(nearby or {}) do
		local ec = api.engine.getComponent(cand, api.type.ComponentType.BASE_EDGE) as Engine.Component.BaseEdge
		if ec and ec.type ~= tunnel and api.engine.getComponent(cand, api.type.ComponentType.BASE_EDGE_STREET) == nil then
			-- cheap reject on the projected chord before sampling the curve
			local s0, s1 = api.gui.camera.world2Screen(ec.position0), api.gui.camera.world2Screen(ec.position1)
			local chord = math.sqrt((s1.x - s0.x) ^ 2 + (s1.y - s0.y) ^ 2)
			local reach = chord * 0.75 + 60
			if (mx - (s0.x + s1.x) / 2) ^ 2 + (my - (s0.y + s1.y) / 2) ^ 2 <= reach * reach then
				local pts = sample(ec)
				local sx, sy, tol, dist, ok = {}, {}, {}, {}, {}
				for k, pt in ipairs(pts) do
					local sp = api.gui.camera.world2Screen(pt)
					sx[k], sy[k], ok[k] = sp.x, sp.y, inFront(pt)
					dist[k] = math.sqrt((pt.x - eye.x) ^ 2 + (pt.y - eye.y) ^ 2 + (pt.z - eye.z) ^ 2)
					-- the track bed's half-width in pixels here: project a point to the side
					local nx, pv = pts[math.min(k + 1, #pts)], pts[math.max(k - 1, 1)]
					local tx, ty = nx.x - pv.x, nx.y - pv.y
					local tl = math.sqrt(tx * tx + ty * ty)
					local ox, oy = HALF_WIDTH_M, 0.0
					if tl > 1e-6 then ox, oy = -ty / tl * HALF_WIDTH_M, tx / tl * HALF_WIDTH_M end
					local op = api.gui.camera.world2Screen(api.type.Vec3f.new(pt.x + ox, pt.y + oy, pt.z))
					tol[k] = math.sqrt((op.x - sp.x) ^ 2 + (op.y - sp.y) ^ 2) + PICK_RADIUS_PX
				end
				for k = 1, #pts - 1 do
					if ok[k] and ok[k + 1] then
						local d, t = segDistance(mx, my, sx[k], sy[k], sx[k + 1], sy[k + 1])
						if d <= tol[k] + t * (tol[k + 1] - tol[k]) then
							local cd = dist[k] + t * (dist[k + 1] - dist[k])
							if cd < bestDist then bestDist, best = cd, cand end
						end
					end
				end
			end
		end
	end
	g_cacheX, g_cacheY, g_cacheEdge, g_cacheValid, g_cacheTime = terrain.x, terrain.y, best, true, os.clock()
	return best
end

-- the Selector params with the fallback added (a controller's crosshair is the mouse here too)
local function wrap(p : {string : any}) : {string : any}
	local onSelect = p.onSelect as function(Engine.Entity, {integer}, Gui.SelectionDetails) : boolean
	local onHover = p.onHover as function(Engine.Entity, {integer}, Gui.SelectionDetails)
	local onMouse = p.onProcessMouseEvent as function(Gui.Mouse.Event) : boolean
	local filter = p.filter as function(Engine.Entity) : boolean
	local T = api.gui.mouse.Event.Type
	local lastReport = 0.0                         -- os.clock() of the Selector's last onHover
	local lastEdge : Engine.Entity = -1            -- ... and what it reported, if a segment the tool takes
	local lastDetails : Gui.SelectionDetails = nil
	local fallbackHover : Engine.Entity = -1       -- the segment we reported in its place, if any
	-- A click can reach the tool by the Selector's own onSelect and by our Pressed fallback; a second
	-- select of the same segment would undo the first (clicking the end of a chain removes it).
	local firedEdge : Engine.Entity = -1
	local firedAt = -1.0
	local function fire(e : Engine.Entity, idx : {integer}, d : Gui.SelectionDetails, via : string) : boolean
		if e == firedEdge and os.clock() - firedAt < 0.3 then
			return true
		end
		firedEdge, firedAt = e, os.clock()
		return onSelect(e, idx, d)
	end

	local function isTrackEdge(e : Engine.Entity) : boolean
		return e ~= nil and e >= 0 and api.engine.entityExists(e)
			and api.engine.getComponent(e, api.type.ComponentType.BASE_EDGE) ~= nil
			and (filter == nil or filter(e))
	end
	-- the segment the fallback picks under the mouse, if the Selector found none
	local function fallbackEdge() : Engine.Entity
		if os.clock() - lastReport < STALE_S and lastEdge >= 0 then return -1 end
		local ok, e = pcall(function() : Engine.Entity return edgeAt(api.gui.mouse.getTerrainPosition()) end)
		if ok and isTrackEdge(e) then return e end
		return -1
	end

	local q : {string : any} = {}
	for k, v in pairs(p) do q[k] = v end
	if onSelect then
		q.onSelect = function(e : Engine.Entity, idx : {integer}, d : Gui.SelectionDetails) : boolean
			return fire(e, idx, d, "selector")
		end
	end
	q.onHover = function(e : Engine.Entity, idx : {integer}, d : Gui.SelectionDetails)
		lastReport, lastDetails = os.clock(), d
		lastEdge = isTrackEdge(e) and e or -1
		if lastEdge >= 0 then
			fallbackHover = -1
			if onHover then onHover(e, idx, d) end
			return
		end
		-- no segment from the Selector (the world, or nothing): try the gaps
		local f = fallbackEdge()
		if f >= 0 then
			fallbackHover = f
			if onHover then onHover(f, {}, d) end
		else
			fallbackHover = -1
			if onHover then onHover(e, idx, d) end
		end
	end
	q.onProcessMouseEvent = function(evt : Gui.Mouse.Event) : boolean
		if onMouse and onMouse(evt) then return true end
		if evt.type == T.Moved then
			-- the Selector went quiet while the mouse moves: it found nothing under the cursor
			if os.clock() - lastReport > STALE_S then
				local f = fallbackEdge()
				if f >= 0 then
					fallbackHover = f
					if onHover then onHover(f, {}, lastDetails) end
				elseif fallbackHover >= 0 then
					fallbackHover = -1
					if onHover then onHover(-1, {}, lastDetails) end
				end
			end
		elseif evt.type == T.Pressed and evt.button == 0 and onSelect and not isGamepad() then
			-- a click in a gap: the Selector will not select, so select what the fallback found
			local f = fallbackEdge()
			if f >= 0 then
				fire(f, {}, lastDetails, "press")
				return true
			end
		end
		return false
	end
	return q
end

local M : Pick = { wrap = wrap, edgeAt = edgeAt }
return M
