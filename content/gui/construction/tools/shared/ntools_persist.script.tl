-- Network Tools: the tools' options are kept in the savegame (api.gui.game.get/setGuiSaveData under
-- the mod's id), so a save opens with the settings it was left with.
--
-- Kept: the plain values (numbers, booleans, strings) of the option tables, one level of string
-- maps (the signal models per kind), and some of the Connect tool's own settings. Not kept: what
-- only describes the current selection (Connect's selected circle, Smooth's selected node, the
-- signal tool's stats), ids that may differ in another save or mod set (network, bridge / tunnel /
-- crossing types), and Anarchy (a save should never open with collision checks off unnoticed).
--
-- init() loads once; tick() (called every engine step by the panel and the Connect recipe) writes
-- the data back only when something changed. reset() puts every table back to the values it had
-- when registered (the panel's Settings tab). With the shared option saveSettings off, the save
-- keeps only that switch (so the save remembers it is off, and nothing else comes back from it).

local MOD_ID = "network_tools_1"
local VERSION = 1
-- a value that was set before and is now off (nil): saved as this, so loading clears it again
local NIL = "__nil"

local record Host
	get : function(key : string) : any
	set : function(key : string, value : any)
end

-- the option tables, by the name they are saved under, and their fields that are not kept
local g_tables : {string : {string : any}} = {}
local g_skip : {string : {string : boolean}} = {}
-- every field each table has had a value in (so a field switched off can be saved as NIL)
local g_known : {string : {string : boolean}} = {}
local g_host : Host = nil
local HOST_KEYS = { "mode", "follow", "snap", "bridges", "replace", "live", "dubinsRadius" }
-- every table's values when registered, and the host's settings at init (for reset)
local g_defaults : {string : {string : any}} = {}
local g_hostDefaults : {string : any} = {}

local g_loaded = false
local g_last : string = nil

local function plain(v : any) : boolean
	local t = type(v)
	return t == "number" or t == "boolean" or t == "string"
end

local function stringMap(v : any) : boolean
	if type(v) ~= "table" then return false end
	for k, x in pairs(v as {any : any}) do
		if type(k) ~= "string" or type(x) ~= "string" then return false end
	end
	return true
end

local function remember(name : string)
	local known = g_known[name]
	for k, v in pairs(g_tables[name]) do
		if plain(v) or stringMap(v) then known[k] = true end
	end
end

local function register(name : string, tbl : {string : any}, skip? : {string})
	g_tables[name] = tbl
	local s : {string : boolean} = {}
	for _, k in ipairs(skip or {}) do s[k] = true end
	g_skip[name] = s
	g_known[name] = {}
	remember(name)
	-- the starting values (one level deep: string maps are copied)
	local d : {string : any} = {}
	for k, v in pairs(tbl) do
		if plain(v) then
			d[k] = v
		elseif stringMap(v) then
			local copy : {string : string} = {}
			for a, b in pairs(v as {string : string}) do copy[a] = b end
			d[k] = copy
		end
	end
	g_defaults[name] = d
end

-- every registered table (and the host's settings) back to its starting values; fields left out of
-- saving (the current selection ...) are left alone
local function reset()
	for name, tbl in pairs(g_tables) do
		local d, skip = g_defaults[name] or {}, g_skip[name] or {}
		remember(name)
		for k in pairs(g_known[name]) do
			if not skip[k] then
				local v = d[k]
				if stringMap(v) then
					local copy : {string : string} = {}
					for a, b in pairs(v as {string : string}) do copy[a] = b end
					tbl[k] = copy
				else
					tbl[k] = v
				end
			end
		end
	end
	if g_host then
		for k, v in pairs(g_hostDefaults) do pcall(g_host.set, k, v) end
	end
end

-- the data as saved, and a string of it in a fixed order (to see whether anything changed)
local function snapshot() : {string : any}, string
	local data : {string : any} = { version = VERSION }
	local parts : {string} = {}
	local names : {string} = {}
	for name in pairs(g_tables) do names[#names + 1] = name end
	table.sort(names)
	for _, name in ipairs(names) do
		remember(name)
		local tbl, skip = g_tables[name], g_skip[name]
		local out : {string : any} = {}
		local keys : {string} = {}
		for k in pairs(g_known[name]) do
			if not skip[k] then keys[#keys + 1] = k end
		end
		table.sort(keys)
		for _, k in ipairs(keys) do
			local v = tbl[k]
			if v == nil then
				out[k] = NIL
				parts[#parts + 1] = name .. "." .. k .. "=nil"
			elseif plain(v) then
				out[k] = v
				parts[#parts + 1] = name .. "." .. k .. "=" .. tostring(v)
			elseif stringMap(v) then
				local copy : {string : string} = {}
				local mk : {string} = {}
				for a, b in pairs(v as {string : string}) do copy[a] = b; mk[#mk + 1] = a .. ":" .. b end
				table.sort(mk)
				out[k] = copy
				parts[#parts + 1] = name .. "." .. k .. "={" .. table.concat(mk, ",") .. "}"
			end
		end
		data[name] = out
	end
	if g_host then
		local out : {string : any} = {}
		for _, k in ipairs(HOST_KEYS) do
			local v = g_host.get(k)
			if plain(v) then
				out[k] = v
				parts[#parts + 1] = "host." .. k .. "=" .. tostring(v)
			end
		end
		data.host = out
	end
	return data, table.concat(parts, ";")
end

-- a saved value goes back only where it fits: the same type as the current one (or the field off)
local function apply(tbl : {string : any}, skip : {string : boolean}, saved : {string : any})
	for k, v in pairs(saved) do
		if type(k) == "string" and not skip[k] then
			local cur = tbl[k]
			if v == NIL then
				tbl[k] = nil
			elseif cur == nil or type(cur) == type(v) then
				if plain(v) then
					tbl[k] = v
				elseif stringMap(v) then
					local copy : {string : string} = {}
					for a, b in pairs(v as {string : string}) do copy[a] = b end
					tbl[k] = copy
				end
			end
		end
	end
end

local function load() : boolean
	local ok, saved = pcall(function() : table return api.gui.game.getGuiSaveData(MOD_ID) end)
	if not ok then return false end   -- no game yet: tried again on the next tick
	local data = saved as {string : any}
	if type(data) == "table" and data.version ~= nil then
		local okApply, err = pcall(function()
			for name, tbl in pairs(g_tables) do
				if type(data[name]) == "table" then apply(tbl, g_skip[name], data[name] as {string : any}) end
			end
			if g_host and type(data.host) == "table" then
				for _, k in ipairs(HOST_KEYS) do
					local v = (data.host as {string : any})[k]
					if plain(v) and type(v) == type(g_host.get(k)) then g_host.set(k, v) end
				end
			end
		end)
		if okApply then
			do ((require "network_tools_1::/gui/construction/tools/shared/ntools_debug.script.tl" as {string : any}).log as function(string))("[network_tools] options loaded from the savegame") end
		else
			do ((require "network_tools_1::/gui/construction/tools/shared/ntools_debug.script.tl" as {string : any}).log as function(string))("[network_tools] loading the saved options failed: " .. tostring(err)) end
		end
	end
	return true
end

local function tick()
	if not g_loaded then
		g_loaded = load()
		if not g_loaded then return end
		local _, s = snapshot()
		g_last = s   -- what was just loaded needn't be written back
		return
	end
	local data, s = snapshot()
	-- Settings: "Remember settings with the savegame" off - the save keeps only that it is off
	local shared = g_tables["shared"]
	if shared and shared.saveSettings == false then
		data = { version = VERSION, shared = { saveSettings = false } }
		s = "off"
	end
	if s == g_last then return end
	local ok, err = pcall(function() api.gui.game.setGuiSaveData(MOD_ID, data) end)
	if ok then
		g_last = s
	else
		do ((require "network_tools_1::/gui/construction/tools/shared/ntools_debug.script.tl" as {string : any}).log as function(string))("[network_tools] saving the options failed: " .. tostring(err)) end
		g_last = s   -- not again every step
	end
end

local function init(host : any)
	g_host = host as Host
	for __, k in ipairs(HOST_KEYS) do
		local v = g_host.get(k)
		if plain(v) then g_hostDefaults[k] = v end
	end
	tick()
end

local record M
	register : function(name : string, tbl : {string : any}, skip? : {string})
	init : function(host : any)
	tick : function()
	reset : function()
end
local m : M = { register = register, init = init, tick = tick, reset = reset }
return m
