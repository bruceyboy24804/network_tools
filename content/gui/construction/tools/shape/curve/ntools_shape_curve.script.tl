-- Network Tools: Shape - Curve mode: edit by hand, like Connect's Curve mode: every node in between
-- gets a centre handle (move it) and a front / back handle (they stay in line: turn the road there;
-- each one's length: how far the curve swings on its side); the two ends keep their direction (the
-- road goes on there), their handle sets only how far the curve swings.
--
-- Set up by the Shape tool with its shared helpers (ctx). Holds the hand edits of the current stretch
-- (state: its version is part of the tool's preview key).

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

local record ChainLink
	edge : Engine.Entity
	fwd : boolean
end

local record Curve
	t0 : P3
	t1 : P3
end

local record Handle
	x : number
	y : number
	z : number
end

local record Canvas
	line : function(x0 : number, y0 : number, z0 : number, x1 : number, y1 : number, z1 : number, color : Vec4f, width : number)
	circle : function(cx : number, cy : number, z : number, r : number, color : Vec4f, width : number)
end

local record Shape
	moves : {Engine.Entity : P3}
	curves : {Engine.Entity : Curve}
	why : string
	info : string
	handles : {Handle}
	onDrag : function(i : integer, x : number, y : number)
	onPress : function(i : integer)
	draw : function(c : Canvas)
end

local record Options
	curveMirror : boolean
	curveFree : boolean
	curveReset : integer
	curveSelLabel : string
	curveHeight : number
end

local record Ctx
	opts : Options
	p3 : function(x : number, y : number, z : number) : P3
	hdist : function(a : P3, b : P3) : number
	getEdge : function(entity : Engine.Entity) : Engine.Component.BaseEdge
	edgePiece : function(e : Engine.Component.BaseEdge) : Piece
	linkCurve : function(link : ChainLink, t0 : P3, t1 : P3) : Curve
	gradedTangent : function(dx : number, dy : number, len : number, z0 : number, z1 : number, hChord : number) : P3
end

-- Curve: the hand edits of the current stretch (dropped when the stretch changes). Per node: a new
-- position (x, y; middle nodes), its front handle as an offset (fx, fy; middle nodes - the back
-- handle points the other way, bl long), or at an end only a handle length (fl first node, bl last)
local record NodeEdit
	x : number
	y : number
	fx : number
	fy : number
	fl : number
	bl : number
	bx : number       -- free handles: the back handle's own offset (nil = opposite the front one)
	by : number
	dz : number       -- height change (metres; nil = as it is)
end
local record CurveEdits
	key : string
	edits : {Engine.Entity : NodeEdit}
	version : integer
	reset : integer   -- the opts.curveReset last acted on
	sel : Engine.Entity   -- the selected node whose height the panel's slider shows (the last clicked)
	selSet : {Engine.Entity : boolean}   -- every selected node (Shift+click adds / removes)
	sentHeight : number   -- the height we last showed the panel for it
end

local record CurveMode
	state : CurveEdits
	computeCurve : function(chain : {ChainLink}, nodes : {Engine.Entity}, P : {P3}) : Shape
end

-- Shift (the game's precision modifier) held
local function shiftHeld() : boolean
	local ok, active = pcall(function() : boolean
		return api.gui.inputAction.modifierOnlyActionIsActive("IA_PRECISION_MODE")
	end)
	return ok and active == true
end

return function(ctx : Ctx) : CurveMode
	local opts = ctx.opts
	local p3, hdist = ctx.p3, ctx.hdist
	local g_curve : CurveEdits = { key = "", edits = {}, version = 0, reset = 0, selSet = {} }

	local function computeCurve(chain : {ChainLink}, nodes : {Engine.Entity}, P : {P3}) : Shape
		local n = #nodes
		local parts : {string} = {}
		for _, l in ipairs(chain) do parts[#parts + 1] = tostring(l.edge) end
		local ck = table.concat(parts, ",")
		if g_curve.key ~= ck or g_curve.reset ~= (opts.curveReset or 0) then
			g_curve.key, g_curve.edits, g_curve.reset = ck, {}, opts.curveReset or 0
			g_curve.sel, g_curve.sentHeight, g_curve.selSet = nil, nil, {}
		end
		local edits = g_curve.edits

		-- the selected nodes' height: the panel's slider moved -> every selected node gets it; else
		-- show the last clicked one's
		local selK : integer = nil
		local nSel = 0
		for k, nd in ipairs(nodes) do
			if nd == g_curve.sel then selK = k end
			if g_curve.selSet[nd] then nSel = nSel + 1 end
		end
		if selK then
			local e = edits[nodes[selK]]
			local own = e and e.dz or 0
			if g_curve.sentHeight ~= nil and opts.curveHeight ~= nil and opts.curveHeight ~= g_curve.sentHeight then
				for _, nd in ipairs(nodes) do
					if g_curve.selSet[nd] then
						local ne : NodeEdit = edits[nd] or {}
						ne.dz = opts.curveHeight ~= 0 and opts.curveHeight or nil
						edits[nd] = ne
					end
				end
				g_curve.sentHeight = opts.curveHeight
			elseif own ~= g_curve.sentHeight then
				opts.curveHeight, g_curve.sentHeight = own, own
			end
			opts.curveSelLabel = nSel > 1 and (tostring(nSel) .. " " .. _("nodes"))
				or (selK == 1 and _("start node") or (selK == n and _("end node") or (_("node") .. " " .. tostring(selK))))
		else
			opts.curveSelLabel, opts.curveHeight, g_curve.sentHeight = nil, nil, nil
		end

		-- the stretch's own tangents, in its direction: leaving node i along link i / arriving at node
		-- i + 1 along it
		local outT : {integer : P3} = {}
		local inT : {integer : P3} = {}
		for i, l in ipairs(chain) do
			local pc = ctx.edgePiece(ctx.getEdge(l.edge))
			if l.fwd then
				outT[i], inT[i + 1] = pc.t0, pc.t1
			else
				outT[i] = p3(-pc.t1.x, -pc.t1.y, -pc.t1.z)
				inT[i + 1] = p3(-pc.t0.x, -pc.t0.y, -pc.t0.z)
			end
		end
		local function unit(x : number, y : number) : number, number, number
			local l = math.sqrt(x * x + y * y)
			if l < 1e-9 then return 0, 0, 0 end
			return x / l, y / l, l
		end

		-- per node: position, front direction / handle length, back direction (pointing back) / length
		local Q : {P3} = {}
		local fdx, fdy, flen : {integer : number}, {integer : number}, {integer : number} = {}, {}, {}
		local bdx, bdy, blen : {integer : number}, {integer : number}, {integer : number} = {}, {}, {}
		for k = 1, n do
			local e = edits[nodes[k]]
			local middle = k > 1 and k < n
			Q[k] = (middle and e and e.x) and p3(e.x, e.y, P[k].z) or P[k]
			if e and e.dz then Q[k] = p3(Q[k].x, Q[k].y, Q[k].z + e.dz) end
			if k < n then
				local x, y, l = unit(outT[k].x, outT[k].y)
				fdx[k], fdy[k], flen[k] = x, y, l / 3
			end
			if k > 1 then
				local x, y, l = unit(-inT[k].x, -inT[k].y)
				bdx[k], bdy[k], blen[k] = x, y, l / 3
			end
			if e then
				if middle and e.fx then
					local x, y, l = unit(e.fx, e.fy)
					if l > 0.5 then
						fdx[k], fdy[k], flen[k] = x, y, l
						bdx[k], bdy[k] = -x, -y
						blen[k] = e.bl or blen[k]
					end
				end
				-- a free back handle (a corner): its own direction and length
				if middle and e.bx then
					local x, y, l = unit(e.bx, e.by)
					if l > 0.5 then bdx[k], bdy[k], blen[k] = x, y, l end
				end
				if k == 1 and e.fl then flen[k] = e.fl end
				if k == n and e.bl then blen[k] = e.bl end
			end
		end

		-- the handles: an end has one (its length only), a node in between three - centre, front, back
		local hs : {Handle} = {}
		local hmap : {{integer, string}} = {}
		local function add(k : integer, kind : string, x : number, y : number)
			hs[#hs + 1] = { x = x, y = y, z = Q[k].z }
			hmap[#hmap + 1] = { k, kind }
		end
		for k = 1, n do
			if k > 1 and k < n then add(k, "c", Q[k].x, Q[k].y) end
			if k < n then add(k, "f", Q[k].x + fdx[k] * flen[k], Q[k].y + fdy[k] * flen[k]) end
			if k > 1 then add(k, "b", Q[k].x + bdx[k] * blen[k], Q[k].y + bdy[k] * blen[k]) end
		end

		-- only the segments next to an edited node are rebuilt; the others keep their curve
		local moves : {Engine.Entity : P3} = {}
		local maxMove = 0.0
		for k = 1, n do
			local e = edits[nodes[k]]
			-- (moved in plan: nodes in between; raised / lowered: any, the ends too)
			if e and ((e.x and k > 1 and k < n) or e.dz) then
				moves[nodes[k]] = Q[k]
				maxMove = math.max(maxMove, hdist(P[k], Q[k]))
			end
		end
		local curves : {Engine.Entity : Curve} = {}
		local nEdited = 0
		for i, l in ipairs(chain) do
			if edits[nodes[i]] or edits[nodes[i + 1]] then
				local a, b = Q[i], Q[i + 1]
				local h = hdist(a, b)
				-- (Hermite tangents are three times the handle length; the climb spreads evenly)
				local t0 = ctx.gradedTangent(fdx[i], fdy[i], 3 * flen[i], a.z, b.z, h)
				local t1 = ctx.gradedTangent(-bdx[i + 1], -bdy[i + 1], 3 * blen[i + 1], a.z, b.z, h)
				curves[l.edge] = ctx.linkCurve(l, t0, t1)
				nEdited = nEdited + 1
			end
		end

		local function onDrag(i : integer, x : number, y : number)
			local m = hmap[i]
			if not m then return end
			local k, kind = m[1], m[2]
			local nd = nodes[k]
			local e : NodeEdit = edits[nd] or {}
			local vx, vy = x - Q[k].x, y - Q[k].y
			if kind == "c" then
				e.x, e.y = x, y
				-- the other selected nodes in between move with it, by as much
				if g_curve.selSet[nd] then
					local dx, dy = x - Q[k].x, y - Q[k].y
					for j = 2, n - 1 do
						local o = nodes[j]
						if o ~= nd and g_curve.selSet[o] then
							local oe : NodeEdit = edits[o] or {}
							oe.x, oe.y = Q[j].x + dx, Q[j].y + dy
							edits[o] = oe
						end
					end
				end
			elseif k == 1 then
				-- the first end keeps its direction: only how far its handle reaches along it
				e.fl = math.max(1, vx * fdx[k] + vy * fdy[k])
			elseif k == n then
				e.bl = math.max(1, vx * bdx[k] + vy * bdy[k])
			elseif kind == "f" then
				local _ux, _uy, l = unit(vx, vy)
				e.fx, e.fy = vx, vy
				if opts.curveFree then
					-- free: the back handle stays where it is
					e.bx = e.bx or bdx[k] * blen[k]
					e.by = e.by or bdy[k] * blen[k]
					if opts.curveMirror then
						local bx, by = unit(e.bx, e.by)
						e.bx, e.by = bx * l, by * l
					end
				else
					e.bx, e.by = nil, nil
					e.bl = opts.curveMirror and l or (e.bl or blen[k])
				end
			else
				local ux, uy, l = unit(vx, vy)
				if l < 0.5 then return end
				local fl = opts.curveMirror and l or flen[k]
				if opts.curveFree then
					-- free: only the back handle moves (the front one keeps its direction)
					e.bx, e.by = vx, vy
					e.fx, e.fy = fdx[k] * fl, fdy[k] * fl
				else
					-- in line: the front one turns with it, keeping its length (or matching it)
					e.bx, e.by = nil, nil
					e.fx, e.fy = -ux * fl, -uy * fl
					e.bl = l
				end
			end
			edits[nd] = e
			g_curve.version = g_curve.version + 1
		end

		-- a click on any of a node's handles selects it (the panel then shows its height); Shift+click
		-- adds it to the selection or takes it out. A plain click on a node already selected keeps the
		-- selection (a drag of its centre then moves them all)
		local function onPress(i : integer)
			local m = hmap[i]
			if not m then return end
			local nd = nodes[m[1]]
			local set = g_curve.selSet
			if shiftHeld() then
				if set[nd] then
					set[nd] = nil
					if g_curve.sel == nd then
						g_curve.sel = nil
						for _, o in ipairs(nodes) do if set[o] then g_curve.sel = o end end
					end
				else
					set[nd] = true
					g_curve.sel = nd
				end
			elseif not set[nd] then
				g_curve.selSet = { [nd] = true }
				g_curve.sel = nd
			else
				g_curve.sel = nd
			end
			g_curve.sentHeight = nil   -- (show the newly clicked node's height)
			g_curve.version = g_curve.version + 1
		end

		local function draw(c : Canvas)
			local col = api.type.Vec4f.new(1.0, 1.0, 1.0, 0.5)
			local selCol = api.type.Vec4f.new(0.3, 1.0, 0.5, 0.9)
			for k = 1, n do
				local z = Q[k].z
				-- the selected node (its height is the panel's slider)
				if g_curve.selSet[nodes[k]] then
					-- (the one the panel's height shows: a second ring)
					c.circle(Q[k].x, Q[k].y, z, 8, selCol, 1.2)
					if nodes[k] == g_curve.sel then c.circle(Q[k].x, Q[k].y, z, 10, selCol, 0.8) end
				end
				if k < n then c.line(Q[k].x, Q[k].y, z, Q[k].x + fdx[k] * flen[k], Q[k].y + fdy[k] * flen[k], z, col, 0.6) end
				if k > 1 then c.line(Q[k].x, Q[k].y, z, Q[k].x + bdx[k] * blen[k], Q[k].y + bdy[k] * blen[k], z, col, 0.6) end
			end
		end

		local info = nEdited == 0 and _("Drag a handle to change the curve")
			or string.format("%s: %d   %s: %.1f m", _("Segments changed"), nEdited, _("Largest node move"), maxMove)
		return { moves = moves, curves = curves, info = info, handles = hs, onDrag = onDrag, onPress = onPress, draw = draw }
	end

	return { state = g_curve, computeCurve = computeCurve }
end
