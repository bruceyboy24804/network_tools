-- Network Tools: the build preview - the game's own builtin.ProposalViewer (3D preview, red where
-- it collides), in Anarchy too: as the Move It mod, Anarchy only builds with ignoreErrors (the
-- collisions shown red are let through), it draws nothing of its own (the user's choice, 2026-10-25).
--
-- A proposal the game refuses outright (critical) gets no preview at all from ProposalViewer: then
-- its new segments are drawn as strips (blue: it passes with the network tidied up, red: refused).
-- Two engine rules shape how (both learned from crashes):
--   * an ActionDescriptor's children must be the game's builtin pieces - a recipe of our own there
--     crashed in CollectActionConfig ("identity2node")
--   * only ONE builtin.EdgeRenderable per tool, and most tools use theirs for handles
-- So the strips are left "pending": the tool's handle canvas (shared/ntools_handles) draws them in
-- its one EdgeRenderable, and a tool that drew no canvas this frame calls leftover() for them.

local builtin = ug_require "::/gui/main/builtin.lua" as Builtin
local labels = require "network_tools_1::/gui/construction/tools/shared/ntools_labels.script.tl" as {string : any}
local labelProposal = labels.proposal as function(sp : SimpleProposal)
local labelNode = labels.node as function() : TreeNodeId
local labelClear = labels.clear as function()


local record ViewerParams
	proposal : SimpleProposal
	id : string                                      -- changes whenever the proposal changes
	onData : function(ProposalData)                  -- costs / errors, as ProposalViewer reports them
	anarchy : boolean                                -- (no longer changes the preview - see above)
	noTags : boolean                                 -- no speed / gradient tags on the new segments
end

local record Preview
	viewer : function(p : ViewerParams) : TreeNodeId
	takeEdges : function() : {Builtin.Type.EdgeRenderable.Edge}
	leftover : function() : TreeNodeId
	tags : function() : TreeNodeId
	clear : function()
end

-- strips waiting to be drawn by this frame's canvas
local g_pending : {Builtin.Type.EdgeRenderable.Edge} = {}
local GREEN = api.type.Vec4f.new(0.34, 0.78, 0.43, 0.55)
local BLUE = api.type.Vec4f.new(0.35, 0.62, 1.0, 0.55)
local RED = api.type.Vec4f.new(1.0, 0.3, 0.3, 0.55)

-- A proposal the game refuses outright (critical): ProposalViewer then draws nothing at all. Loops
-- crossing other tracks are refused so unless the game may tidy the network up (cleanupStreetGraph,
-- which the builds use but the viewer can't) - the tools said "ok" over an empty view. Such a
-- proposal's id, and whether it passes with that cleanup: drawn as our strips instead, blue / red.
local g_critId : string = nil
local g_critOk = false

-- sum of a segment's lane widths (its full width), with a floor so tiny paths still show
local function segWidth(seg : Proposal.SegmentAndEntity) : number
	local w = 0.0
	pcall(function()
		for _, lc in ipairs(seg.comp.laneConfigs or {}) do w = w + (lc.width or 0) end
	end)
	return math.max(w, 3)
end

-- the segment as one smooth cubic-spline edge, or nil if the engine refuses the geometry
local function splineEdge(seg : Proposal.SegmentAndEntity, width : number, color : Vec4f) : Builtin.Type.EdgeRenderable.Edge
	local ok, edge = pcall(function() : Builtin.Type.EdgeRenderable.Edge
		local c = seg.comp
		local sp = api.type.EdgeGeometry.CubicSpline.new()
		sp.pos = { api.type.Vec2f.new(c.position0.x, c.position0.y), api.type.Vec2f.new(c.position1.x, c.position1.y) }
		sp.tangent = { api.type.Vec2f.new(c.tangent0.x, c.tangent0.y), api.type.Vec2f.new(c.tangent1.x, c.tangent1.y) }
		local geom = api.type.EdgeGeometry.new()
		geom.type = api.type.EdgeGeometry.Type.CUBIC_SPLINE
		geom.cubicSpline = sp
		geom.height = api.type.Vec2f.new(c.position0.z, c.position1.z)
		geom.tangent = api.type.Vec2f.new(c.tangent0.z, c.tangent1.z)
		geom.width = width
		local dx, dy = c.position1.x - c.position0.x, c.position1.y - c.position0.y
		geom.length = math.sqrt(dx * dx + dy * dy)
		local e = builtin.type.EdgeRenderable.Edge.new(geom)
		e.colors = { color, color, color }
		e.stepSize = 1
		e.width = width
		e.offsetZ = 0.5
		return e
	end)
	return ok and edge or nil
end

local g_loggedFail = false

-- the proposal's new segments as strips (green: Anarchy)
local function strips(proposal : SimpleProposal, color? : Vec4f) : {Builtin.Type.EdgeRenderable.Edge}
	local edges : {Builtin.Type.EdgeRenderable.Edge} = {}
	pcall(function()
		for _, seg in ipairs(proposal.streetProposal.edgesToAdd or {}) do
			local e = splineEdge(seg, segWidth(seg), color or GREEN)
			if e then
				edges[#edges + 1] = e
			elseif not g_loggedFail then
				g_loggedFail = true
				do ((require "network_tools_1::/gui/construction/tools/shared/ntools_debug.script.tl" as {string : any}).log as function(string))("[network_tools] preview: spline geometry not accepted") end
			end
		end
	end)
	return edges
end

-- this frame's pending strips (handed to the canvas, which draws them), and cleared
local function takeEdges() : {Builtin.Type.EdgeRenderable.Edge}
	local out = g_pending
	g_pending = {}
	return out
end

-- an EdgeRenderable for strips no canvas took this frame (or nil)
local function leftover() : TreeNodeId
	local edges = takeEdges()
	if #edges == 0 then return nil end
	return builtin.EdgeRenderable{ edges = edges, ignoreDepth = false }
end

-- The tools' preview: the game's ProposalViewer (Anarchy too); plus speed / incline tags on the new
-- segments, shown by the tool's labels.node().
local function viewer(p : ViewerParams) : TreeNodeId
	-- replaces anything no canvas took last frame
	g_pending = {}
	-- (refused outright: the viewer shows nothing - strips instead)
	if g_critId ~= nil and g_critId == p.id then
		g_pending = strips(p.proposal, g_critOk and BLUE or RED)
	end
	if not p.noTags then labelProposal(p.proposal) end
	return builtin.ProposalViewer{
		simpleProposal = p.proposal,
		onCreateProposalData = function(pd : ProposalData)
			pcall(function()
				local es = (pd.errorState as any) as {string : any}
				if es and es.critical == true then
					local verdict = (require "network_tools_1::/gui/construction/tools/shared/ntools_speed.script.tl" as {string : any}).verdictWithCleanup as function(SimpleProposal) : string
					g_critId, g_critOk = p.id, verdict(p.proposal) == ""
				elseif g_critId == p.id then
					g_critId = nil
				end
			end)
			if p.onData then p.onData(pd) end
		end,
		-- (no entityForRefundableContext: with it, a preview that removes a segment - an end along a
		-- road splits it - crashed the game natively once the preview went away and the segment came
		-- back: "it != components.end()" on BaseEdge in UI::CSelector, 2026-10-25. The game sets it
		-- only with a native Proposal (bridge / tunnel swap); Move It and the Overpass Builder preview
		-- SimpleProposals without it and don't crash)
		proposalId = p.id,
	}
end

-- the tags layer (shared/ntools_labels): the preview's segment tags and the tool's own. Added to
-- the tool's children once per render, after viewer()
local function tags() : TreeNodeId
	return labelNode()
end

-- for a tool's react.onUnmount: its tags leave with it
local function clear()
	g_pending = {}
	labelClear()
end

local M : Preview = { viewer = viewer, takeEdges = takeEdges, leftover = leftover, tags = tags, clear = clear }
return M
