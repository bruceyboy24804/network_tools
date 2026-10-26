-- Network Tools: diagnostic logging. The publishing guidelines want a mod to run without errors or
-- warnings in the log, so the tools' traces (script loaded, previews, verdicts, the per-node /
-- per-segment dumps, caught errors, refused builds) go through log() and only print with DEBUG on.
-- DEBUG starts as below; the panel's Settings tab switches it while the game runs (M.setDebug).

-- true while developing: every trace goes to stdout.txt from the start
local DEBUG_AT_START = false

local record M
	DEBUG : boolean
	log : function(msg : string)
	setDebug : function(on : boolean)
end
local m : M = { DEBUG = DEBUG_AT_START }

m.log = function(msg : string)
	if m.DEBUG then print(msg) end
end

m.setDebug = function(on : boolean)
	m.DEBUG = on == true
	if m.DEBUG then print("[network_tools] debug logging on") end
end

return m
