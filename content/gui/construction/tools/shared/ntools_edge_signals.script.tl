-- Network Tools: reading the signals on a segment, so a tool that re-adds the segment can place them
-- again. Each signal is removed (edgeObjectsToRemove) and placed again on the new segment, same model,
-- facing and one-way (as the Automatic Signal Spacing mod re-places signals). Stops and waypoints
-- (lines refer to them) can't be carried over that way: a segment with one is refused.
-- Used by Parallel (crossed tracks) and Auto-signal (segments that get new signals).

local record SignalCopy
	entity : Engine.Entity
	param : number             -- 0..1 along the old edge
	model : string
	left : boolean             -- faces travel against the segment's own direction
	oneWay : boolean
end

-- The edge's signals as they'd be placed again, or nil and why the edge can't be re-added
local function readSignals(e : Engine.Entity, oe : Engine.Component.BaseEdge) : {SignalCopy}, string
	local out : {SignalCopy} = {}
	for _, obj in ipairs(oe.objects or {}) do
		if obj[2] ~= api.type["enum"].EdgeObjectType.SIGNAL then return nil, "has stops" end
		local eo = api.engine.getComponent(obj[1], api.type.ComponentType.EDGE_OBJECT) as Engine.Component.EdgeObject
		if not eo then return nil, "has unreadable objects" end
		local sc : SignalCopy = { entity = obj[1], param = eo.param, model = eo.edgeObjectConstruction as string, left = false, oneWay = false }
		local found = false
		local okT, tn = pcall(function() : any return api.engine.getComponent(e, api.type.ComponentType.TRANSPORT_NETWORK) end)
		local nEdges = okT and tn and #((tn as {string : {any}}).edges or {}) or 0
		for k = 0, nEdges - 1 do
			for _, reversed in ipairs({ false, true }) do
				local sid = api.engine.system.signalSystem.getSignal(api.type.EdgeId.new(e, k), reversed)
				if not found and sid and sid.entity == obj[1] then
					found = true
					sc.left = reversed
					local sl = api.engine.getComponent(sid.entity, api.type.ComponentType.SIGNAL_LIST) as Engine.Component.SignalList
					local sd = sl and sl.signals and sl.signals[sid.index + 1]
					if sd and sd.type == api.type.Signal.Type.WAYPOINT then return nil, "has waypoints" end
					sc.oneWay = sd ~= nil and sd.type == api.type.Signal.Type.ONE_WAY_SIGNAL
				end
			end
		end
		if not found then return nil, "has objects of unknown direction" end
		out[#out + 1] = sc
	end
	return out, nil
end

return {
	readSignals = readSignals,
}
