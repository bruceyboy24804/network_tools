-- Network Tools: leaving a tool with Escape / the "Leave the tool" button.
--
-- params.abort() only leaves the tool with a controller. With a mouse the engine hands the back
-- action on to the construction menu, which closes the tool when it gets constructionMenuQuit, so
-- the tools fire that themselves. (Debounced: Escape can arrive from onBack and the pad action.)

local react = ug_require "::/gui/main/react.lua" as React

local record Params
	abort : function()
end

local g_last = -1.0

local function leave(params : Params)
	local ok, gamepad = pcall(function() : boolean
		return api.util.getInputMode() == api.type["enum"].InputMode.Gamepad
	end)
	if ok and gamepad then
		params.abort()
		return
	end
	if os.clock() - g_last < 0.5 then return end
	g_last = os.clock()
	react.fireEvent(nil, "constructionMenuQuit", nil)
end

return leave
