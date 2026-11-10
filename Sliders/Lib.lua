-- Lib.lua: the few helpers Sliders needs, so it runs on its own. They mirror the author's shared library (AlcCore,
-- 2026-11-09), cut down to what Sliders calls:
--   secret values (Value, Num, Kind, Read): in combat and in some places the client hands addons "secret" values
--     that Lua may not compare or do arithmetic on; these return nil (or "secret") for them
--   error isolation (Safe): every way into Sliders's code runs under xpcall; the first error goes to the game's error
--     handler (BugSack shows it), repeats are counted, and after 20 that part switches itself off until /reload
--   timers, scripts, guarded event registration on one shared event frame (unit events on their own frames)
--   combat state from the regen events, OnLoad (saved variables are ready)
--   Fill (defaults), Cap (a ring), CharKey, a movable frame whose spot is saved, Printer, Slash
local ADDON, ns = ...
local L = {}
ns.L = L

--------------------------------------------------------------------- secret values
local function IsSecret(v) return issecretvalue ~= nil and issecretvalue(v) == true end
L.IsSecret = IsSecret

-- the value when Lua may use it, else nil (always exactly one return)
function L.Value(v)
	if v ~= nil and not IsSecret(v) then return v end
	return nil
end

-- a readable number, else nil
function L.Num(v)
	if v == nil or IsSecret(v) or type(v) ~= "number" then return nil end
	return v
end

-- "nil", "secret" or "value": tells a sealed value apart from an absent one
function L.Kind(v)
	if v == nil then return "nil" end
	if IsSecret(v) then return "secret" end
	return "value"
end

-- pcall(fn, ...) and Value() in one: the first return when the call worked and it is readable, else nil
function L.Read(fn, ...)
	if type(fn) ~= "function" then return nil end
	local ok, v = pcall(fn, ...)
	if not ok then return nil end
	return L.Value(v)
end

--------------------------------------------------------------------- error isolation
local MAX_ERRORS = 20
local errors = {}
L.errors = errors

local function report(label, err)
	local e = errors[label]
	if not e then
		e = { count = 0, first = tostring(err) }
		errors[label] = e
	end
	e.count = e.count + 1
	if e.count == 1 then
		local handler = geterrorhandler and geterrorhandler()
		if handler then pcall(handler, ADDON .. ": " .. label .. ": " .. tostring(err)) end
	elseif e.count == MAX_ERRORS then
		e.off = true
		print("|cff66ccff" .. ADDON .. "|r: " .. label .. " failed " .. MAX_ERRORS .. " times and is off until /reload.")
	end
end

-- the game's xpcall passes extra arguments on; plain Lua 5.1's does not (the test harness runs that)
local XPCALL_ARGS = select(2, xpcall(function(a) return a end, function() end, true)) == true

function L.Safe(label, fn)
	local function trace(err) return debugstack and (tostring(err) .. "\n" .. debugstack(2, 6, 0)) or tostring(err) end
	return function(...)
		local e = errors[label]
		if e and e.off then return end
		local ok, err
		if XPCALL_ARGS then
			ok, err = xpcall(fn, trace, ...)
		else
			local n, args = select("#", ...), { ... }
			ok, err = xpcall(function() return fn(unpack(args, 1, n)) end, trace)
		end
		if not ok then report(label, err) end
	end
end

--------------------------------------------------------------------- timers, scripts, events
function L.After(seconds, fn, label)
	local safe = L.Safe(label or "timer", fn)
	if C_Timer and C_Timer.After then C_Timer.After(seconds, safe) else safe() end
end

function L.Script(frame, script, fn, label)
	frame:SetScript(script, L.Safe(label or script, fn))
end

-- RegisterEvent / RegisterUnitEvent (units given) that never throws: an event a patch removed is skipped
function L.Register(frame, event, ...)
	local valid = C_EventUtils and C_EventUtils.IsEventValid
	if valid then
		local ok, v = pcall(valid, event)   -- guard: a client whose test throws
		if ok and v == false then return false end
	end
	local ok
	if select("#", ...) > 0 then ok = pcall(frame.RegisterUnitEvent, frame, event, ...)   -- guard: unknown events throw
	else ok = pcall(frame.RegisterEvent, frame, event) end                                 -- guard: as above
	return ok
end

local ev = CreateFrame("Frame")
local handlers = {}

-- fn(event, ...) on every `event`, each handler isolated
function L.On(event, fn, label)
	if not handlers[event] then
		handlers[event] = {}
		L.Register(ev, event)
	end
	local list = handlers[event]
	list[#list + 1] = L.Safe(label or event, fn)
end

ev:SetScript("OnEvent", function(_, event, ...)
	local list = handlers[event]
	if not list then return end
	for i = 1, #list do list[i](event, ...) end
end)

--------------------------------------------------------------------- combat
-- from the regen events: on this client the lockdown query did not report true when the events fired
local inCombat = false
if UnitAffectingCombat then
	local ok, v = pcall(UnitAffectingCombat, "player")   -- guard: legacy global
	if ok and v == true then inCombat = true end
end
function L.InCombat() return inCombat end

local combatSubs = {}
function L.OnCombatChanged(fn, label) combatSubs[#combatSubs + 1] = L.Safe(label or "combat", fn) end

-- registered here, before Sliders.lua's own handlers: the state is right when theirs run
L.On("PLAYER_REGEN_DISABLED", function()
	inCombat = true
	for _, f in ipairs(combatSubs) do f(true) end
end, "combat")
L.On("PLAYER_REGEN_ENABLED", function()
	inCombat = false
	for _, f in ipairs(combatSubs) do f(false) end
end, "combat")

--------------------------------------------------------------------- loading
local loadFns = {}
function L.OnLoad(fn) loadFns[#loadFns + 1] = L.Safe("OnLoad", fn) end

L.On("ADDON_LOADED", function(_, name)
	if name ~= ADDON then return end
	for _, f in ipairs(loadFns) do f() end
end, "ADDON_LOADED")

--------------------------------------------------------------------- saved data
-- missing keys from the defaults, nested; what is saved wins
function L.Fill(t, defaults)
	for k, v in pairs(defaults) do
		if t[k] == nil then
			if type(v) == "table" then
				t[k] = {}
				L.Fill(t[k], v)
			else
				t[k] = v
			end
		elseif type(v) == "table" and type(t[k]) == "table" then
			L.Fill(t[k], v)
		end
	end
	return t
end

-- keep the newest `keep` entries of an array (oldest first), in place
function L.Cap(list, keep)
	local n = #list
	if n <= keep then return list end
	local drop = n - keep
	for i = 1, keep do list[i] = list[i + drop] end
	for i = keep + 1, n do list[i] = nil end
	return list
end

-- "Name-Realm" (UnitName's first value: on Forever the second is the surname); the last readable one while the name
-- is secret
local lastKey
function L.CharKey()
	local name = UnitName and L.Value((UnitName("player")))
	local realm = GetRealmName and L.Value((GetRealmName()))
	if type(name) == "string" and name ~= "" then
		lastKey = name .. "-" .. tostring(realm or "?")
		return lastKey
	end
	return lastKey or ("?-" .. tostring(realm or "?"))
end

--------------------------------------------------------------------- frames
-- the frame's first anchor as { point, relativePoint, x, y } relative to UIParent, or nil
function L.SavePoint(frame)
	local point, _, relPoint, x, y = frame:GetPoint(1)
	if not point then return nil end
	return { point, relPoint, math.floor((x or 0) + 0.5), math.floor((y or 0) + 0.5) }
end

-- back to a saved { point, relativePoint, x, y }; any failure (bad data, the engine's anchor family error) falls back
-- to default(frame)
function L.RestorePoint(frame, pos, default)
	if type(pos) == "table" and type(pos[1]) == "string" then
		frame:ClearAllPoints()
		local ok = pcall(frame.SetPoint, frame, pos[1], UIParent, pos[2] or pos[1], tonumber(pos[3]) or 0,
			tonumber(pos[4]) or 0)   -- guard: the anchor family error
		if ok and frame:GetNumPoints() > 0 then return true end
	end
	if default then
		frame:ClearAllPoints()
		default(frame)
	end
	return false
end

-- left-drag moves the frame; on release onMoved(pos) gets SavePoint's table
function L.Movable(frame, onMoved)
	frame:SetMovable(true)
	frame:EnableMouse(true)
	frame:RegisterForDrag("LeftButton")
	if frame.SetClampedToScreen then frame:SetClampedToScreen(true) end
	frame:SetScript("OnDragStart", function(self) self:StartMoving() end)
	frame:SetScript("OnDragStop", function(self)
		self:StopMovingOrSizing()
		if onMoved then onMoved(L.SavePoint(self)) end
	end)
	return frame
end

--------------------------------------------------------------------- chat
function L.Printer(name, colour)
	local prefix = "|cff" .. colour .. name .. "|r: "
	return function(msg) print(prefix .. msg) end
end

-- a SlashCmdList handler: handlers[cmd](arg) with the command lower-cased and the rest as typed; else the usage line
function L.Slash(handlers, usage, say)
	return L.Safe("slash", function(msg)
		local cmd, arg = (msg or ""):match("^%s*(%S*)%s*(.-)%s*$")
		local handler = handlers[(cmd or ""):lower()]
		if handler then handler(arg or "") else say(usage) end
	end)
end
