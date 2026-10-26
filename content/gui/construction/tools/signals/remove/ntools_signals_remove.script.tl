-- Network Tools: Auto-signal - Remove mode: remove the signals on the stretch (and alongside).
-- Each segment carrying signals is removed and re-added with its other objects (stops etc.) and
-- without the signals, which go in edgeObjectsToRemove (as the Automatic Signal Spacing mod rebuilds
-- segments).
--
-- Set up by the Auto-signal tool with its shared helpers (ctx).

local record ChainLink
	edge : Engine.Entity
	fwd : boolean
end

local record Ctx
	getEdge : function(Engine.Entity) : Engine.Component.BaseEdge
	isFrozenEdge : function(edge : Engine.Entity) : boolean
	isProtectedNode : function(node : Engine.Entity) : boolean
	configNodesFor : function(removedEdges : {Engine.Entity}, extraNodes? : {Engine.Entity}, skipNodes? : {Engine.Entity}) : {Engine.Entity}
	rebuildCrossings : function(proposal : SimpleProposal, removedEdges : {Engine.Entity}, skipNodes? : {Engine.Entity}) : integer
end

local record Remove
	makeRemoveProposal : function(chains : {{ChainLink}}) : SimpleProposal, integer
end

return function(ctx : Ctx) : Remove
	-- Returns the proposal and the number of signals removed.
	local function makeRemoveProposal(chains : {{ChainLink}}) : SimpleProposal, integer
		local toAdd : {Proposal.SegmentAndEntity} = {}
		local toRemove : {Engine.Entity} = {}
		local objsRemove : {Engine.Entity} = {}
		local seen : {Engine.Entity : boolean} = {}
		for _, ch in ipairs(chains) do
			for _, l in ipairs(ch) do
				local e = (not seen[l.edge]) and ctx.getEdge(l.edge) or nil
				seen[l.edge] = true
				if e then
					local keep : {{Engine.Entity, EdgeObjectType}} = {}
					local drop : {Engine.Entity} = {}
					for _, obj in ipairs(e.objects or {}) do
						if obj[2] == api.type["enum"].EdgeObjectType.SIGNAL then drop[#drop + 1] = obj[1]
						else keep[#keep + 1] = { obj[1], obj[2] } end
					end
					if #drop > 0 and not ctx.isFrozenEdge(l.edge)
						and not ctx.isProtectedNode(e.node0) and not ctx.isProtectedNode(e.node1) then
						local seg = api.type.SegmentAndEntity.new()
						seg.entity = -(#toAdd + 1)
						seg.comp = e
						seg.comp.objects = keep
						seg.type = 1
						pcall(function()
							local po = api.engine.getComponent(l.edge, api.type.ComponentType.PLAYER_OWNED)
							if po then seg.playerOwned = po end
						end)
						toAdd[#toAdd + 1] = seg
						toRemove[#toRemove + 1] = l.edge
						for _, d in ipairs(drop) do objsRemove[#objsRemove + 1] = d end
					end
				end
			end
		end
		if #toAdd == 0 then return nil, 0 end
		local proposal = api.type.SimpleProposal.new()
		proposal.streetProposal.edgesToAdd = toAdd
		proposal.streetProposal.edgesToRemove = toRemove
		proposal.streetProposal.edgeObjectsToRemove = objsRemove
		local cfg = ctx.configNodesFor(toRemove)
		if #cfg > 0 then proposal.streetProposal.nodeConfigsToRemove = cfg end
		ctx.rebuildCrossings(proposal, toRemove)
		return proposal, #objsRemove
	end

	return { makeRemoveProposal = makeRemoveProposal }
end
