-- Sliders: which shard of WoW Forever's mega server you are on, read from the NPCs around you and logged per zone;
-- friends running it see each other's shard, and (Hop.lua) one click asks a friend open for invites to move you to
-- theirs. Silent by default: nothing in chat unless asked (/sliders chat on). Standalone (its helpers in Lib.lua).
-- Design: wow-addons docs/shards.md (was Portage, was AlcShard).
--
-- How (API checked against Forever's API index, build 1.60.1.70862, 2026-11-08):
--   UnitGUID(target | mouseover | nameplateN) on PLAYER_TARGET_CHANGED, UPDATE_MOUSEOVER_UNIT, NAME_PLATE_UNIT_ADDED.
--   UnitGUID is SecretWhenUnitIdentityRestricted and takes a UnitTokenPvPRestrictedForAddOns token: every read goes
--   through pcall + L.Kind first; a refused, nil or secret read is only counted (per token, in / out of combat),
--   never parsed. C_Secrets.ShouldUnitIdentityBeSecret(unit) is asked first; "yes" counts as secret without a read.
--   Kinds Creature and Vehicle only, no UnitPlayerControlled units (a pet keeps its summon-time GUID).
--   Shard = serverID-mapID from the GUID ("7074-1"). The zoneUID after them differs per client on one shard (alcaras
--   and Crow grouped on one shard, 2026-11-09: 7074-1-9 and 7074-1-5), so it is only kept in the sightings.
--   Confirmed by dwell and majority (RULE below), not by two reads: keys of other shards flicker in often.
--   Party: UnitInPartyShard (no flag) and UnitPhaseReason (identity flag, L.Value) for player and party1..4.
--   Shard moves: SHARD_TRANSFER_IMMINENT (+ GetEvictionTimeRemaining), SHARD_TRANSFER_CANCELLED, SHARD_TRANSFER.
--   Party exchange, to learn whether two clients see the same key: "S1;<uiMapID>;<key>;<ageSec>" over PARTY only.
--   Ping test (0.2): /sliders ping sends P1 over guild, the SlidersTest channel, whispers and Battle.net; R1 answers.
local ADDON, ns = ...
local L = ns.L
-- the version from the TOC (one place): shown in the tooltip, the panel, /sliders version, and sent to friends
ns.VERSION = (C_AddOns and L.Value(L.Read(C_AddOns.GetAddOnMetadata, ADDON, "Version"))) or "?"

local LAYOUT = {
	-- first run: unlocked near the top centre, in a box with a hint, so it is found; drag it, right-click locks it
	-- (alcaras/Crow 2026-11-09: under the minimap it was easy to miss)
	point = { "TOP", "TOP", 0, -120 },
	width = 140, height = 18,
	font = 12,
	box = { 0.04, 0.04, 0.05, 0.85 }, edge = { 0.55, 0.80, 1.00, 0.9 },   -- unlocked: AlcPrices' panel and action blue
	boxPadX = 6, boxPadY = 4,        -- the unlocked box around the text
	hintFont = 10, hintGap = 6,      -- the hint under it
	grey = { 0.55, 0.55, 0.55 },     -- unconfirmed or stale
	white = { 0.9, 0.9, 0.9 },       -- confirmed
}

-- the confirmation rule (docs/shards.md section 2); every sighting is saved, so tools can re-run another rule
local RULE = {
	window = 60,     -- seconds of reads that count
	reads = 3,       -- at least this many reads of the key in the window
	npcs = 2,        -- from at least this many distinct units
	span = 5,        -- spanning at least this many seconds
	share = 2 / 3,   -- and at least this share of all reads in the window
	stale = 120,     -- no read for this long: the shown key turns grey
}
-- rings are trimmed in batches of `slack` (L.Cap shifts the whole list)
local KEEP = { log = 1000, sightings = 4000, slack = 100, keyDays = 14, sightEvery = 20, sendEvery = 30 }
local PREFIX = "Sliders"
local KINDS = { Creature = true, Vehicle = true }

local P = L.Printer("Sliders", "66ccff")
local db, char
-- automatic lines (a shard change, a move coming): only with /sliders chat on (Crow: nothing in chat unless asked)
local function say(...) if db and db.chat then P(...) end end

-- ---------------------------------------------------------------- state (this session)
local loading = true          -- between PLAYER_LEAVING_WORLD and PLAYER_ENTERING_WORLD: nothing is read
local window = {}             -- recent reads: { t, key, guid }
local current                 -- the confirmed key, or nil
local currentSince            -- GetTime() it was confirmed
local lastRead                -- GetTime() of the last keyed read
local prev                    -- { key, map, why } the key before the last reset (did the zone line change it?)
local lastZone, lastGroup, lastTransfer   -- { t = GetTime(), what = "..." }
local seenGUID = {}           -- guid -> GetTime() of its last saved sighting
local seenN = 0
local keyUnits = {}           -- key .. guid -> true (distinct units per key, this session)
local partyState = {}         -- unit -> "true Sharding" (the last logged state)
local peers = {}              -- first name -> { key, map, t }
local players = {}            -- player GUID -> { t, key }: players seen while on a shard (crowding, 5 min)
local ownGUID
local lastSend, sendQueued = -1e9, false
local lastRoster = 0

local function now() return L.Num(GetTime()) or 0 end
ns.hooks = {}
local function hook(name, ...)
	local f = ns.hooks[name]
	if f then f(...) end
end
local function stamp() return L.Num(time()) or 0 end

-- ---------------------------------------------------------------- context
local function mapID()
	return L.Num(L.Read(C_Map.GetBestMapForUnit, "player"))
end

-- ---------------------------------------------------------------- names
-- "Name-Realm" -> "name-realm" (the realm without spaces, apostrophes or hyphens): one key per character, whatever
-- route named it (Battle.net gives "Living Flame", addon messages "LivingFlame"); a bare "Name" is on our realm
local ownRealm
local function realm()
	if ownRealm then return ownRealm end
	local r = L.Value(L.Read(GetNormalizedRealmName))
	if type(r) ~= "string" or r == "" then r = L.Value(L.Read(GetRealmName)) end
	if type(r) ~= "string" or r == "" then return "?" end   -- not readable yet: asked again next time, never cached
	ownRealm = r
	return r
end
local function norm(full)
	if type(full) ~= "string" then return nil end
	local name, r = full:match("^([^%-]+)%-?(.*)$")
	if not name then return nil end
	if r == "" then r = realm() end
	return (name .. "-" .. r:gsub("[%s'%-]", "")):lower()
end
local function firstName(full) return type(full) == "string" and (full:match("^[^%s%-]+") or full) or "?" end
local function ownFull()
	local name = L.Value(L.Read(UnitName, "player"))
	return (type(name) == "string" and name or "?") .. "-" .. realm()
end
-- a message from this character (guild and channel echo our own sends); another player with our first name is not us
local sentBodies = {}   -- body -> GetTime() we sent it (guild and channel echo our own messages back)
local function sentRecently(body)
	local t = body and sentBodies[body]
	return t ~= nil and (L.Num(GetTime()) or 0) - t < 10
end
-- our own echo: the same full name, or (the realm spelled another way: alcaras' "Alcara" showed up as a friend on his
-- own shard in 0.3.1) our first name with a message we sent ourselves a moment ago. Another player with our first name
-- on another realm is not us.
function ns.isSelf(full, body)
	if full == nil then return false end
	if norm(full) == norm(ownFull()) then return true end
	return firstName(full):lower() == firstName(ownFull()):lower() and sentRecently(body)
end

-- "41 s", "3 min"
local function age(sec)
	sec = math.floor(sec)
	if sec < 90 then return sec .. " s" end
	return math.floor(sec / 60 + 0.5) .. " min"
end

local function mapName(id)
	if not id then return "?" end
	local info = L.Read(C_Map.GetMapInfo, id)
	local name = type(info) == "table" and L.Value(info.name) or nil
	return type(name) == "string" and name or tostring(id)
end

local function instanced()
	local ok, inside, kind = pcall(IsInInstance)   -- guard: a client that refuses the query
	if not ok then return false, nil end
	return L.Value(inside) == true, L.Value(kind)
end

local function paused()
	if instanced() then return "instance" end
	if L.Value(L.Read(UnitOnTaxi, "player")) == true then return "taxi" end
	return nil
end

-- "world", "combat", "contested", "pvp", "arena", "party" ...: where nameplate reads may be refused (question 16)
local function pvpContext()
	local inside, kind = instanced()
	if inside then return kind or "instance" end
	local get = C_PvP and C_PvP.GetZonePVPInfo
	local kindOf = get and L.Value(L.Read(get)) or nil
	return type(kindOf) == "string" and kindOf ~= "" and kindOf or "world"
end

local function groupSize()
	local n = L.Num(L.Read(GetNumGroupMembers))
	return n or 0
end

local function inGroup() return L.Value(L.Read(IsInGroup)) == true end

local function isLeader()
	return inGroup() and L.Value(L.Read(UnitIsGroupLeader, "player")) == true
end

-- ---------------------------------------------------------------- saved records
local function charData()
	if not db then return nil end
	local key = L.CharKey()
	local c = db.chars[key]
	if not c then
		c = { maps = {}, log = {}, sightings = {} }
		db.chars[key] = c
	end
	return c
end

local function mapData(id)
	if not char or not id then return nil end
	local m = char.maps[id]
	if not m then
		m = { name = mapName(id), keys = {}, reads = {} }
		char.maps[id] = m
	end
	return m
end

-- one timeline line: { time, uiMapID, group size, leader 0/1, combat 0/1, text }
local function log(text)
	if not char then return end
	char.log[#char.log + 1] = { stamp(), mapID() or 0, groupSize(), isLeader() and 1 or 0, L.InCombat() and 1 or 0, text }
	if #char.log > KEEP.log + KEEP.slack then L.Cap(char.log, KEEP.log) end
end

local function ago(ev)
	if not ev then return "-" end
	return ("%s %ds"):format(ev.what, math.floor(now() - ev.t))
end

-- ---------------------------------------------------------------- labels ("Barrens B")
local function shortZone(name)
	name = (name or "?"):gsub("^The ", "")
	if #name <= 10 then return name end
	return name:match("^(%S+)") or name
end

local function serverOf(key) return type(key) == "string" and key:match("^(%d+)") or "?" end
-- "7074-1" from any key shape ("7074-1-9" from 0.2, a full GUID part): the comparable shard
local function shardOf(key) return type(key) == "string" and key:match("^(%d+%-%d+)") or nil end

-- a shard's name: the zone and the server, the same for everyone on it ("Desolace 7074")
local function labelOf(key, id) return shortZone(mapName(id or mapID())) .. " " .. serverOf(key) end
local function shownLabel(key) return labelOf(key) end

-- ---------------------------------------------------------------- the line on screen
local frame = CreateFrame("Frame", "SlidersFrame", UIParent)
local function DefaultPoint(f)
	local p = LAYOUT.point
	f:SetPoint(p[1], UIParent, p[2], p[3], p[4])
end
DefaultPoint(frame)
frame:SetSize(LAYOUT.width, LAYOUT.height)
frame:SetFrameStrata("LOW")
local text = frame:CreateFontString(nil, "OVERLAY")
text:SetFont(STANDARD_TEXT_FONT, LAYOUT.font, "OUTLINE")
text:SetPoint("CENTER", frame, "CENTER", 0, 0)
text:SetJustifyH("CENTER")
text:SetText("?")
text:SetTextColor(LAYOUT.grey[1], LAYOUT.grey[2], LAYOUT.grey[3])

-- the unlocked look: a box, a blue edge and the hint under it
local unlockedParts = {}
do
	local bg = frame:CreateTexture(nil, "BACKGROUND")
	bg:SetPoint("TOPLEFT", -LAYOUT.boxPadX, LAYOUT.boxPadY) bg:SetPoint("BOTTOMRIGHT", LAYOUT.boxPadX, -LAYOUT.boxPadY)
	bg:SetColorTexture(LAYOUT.box[1], LAYOUT.box[2], LAYOUT.box[3], LAYOUT.box[4])
	unlockedParts[#unlockedParts + 1] = bg
	for _, t in ipairs(L.Border(frame, LAYOUT.edge, bg)) do unlockedParts[#unlockedParts + 1] = t end
	local hint = frame:CreateFontString(nil, "OVERLAY")
	hint:SetFont(STANDARD_TEXT_FONT, LAYOUT.hintFont, "OUTLINE")
	hint:SetPoint("TOP", frame, "BOTTOM", 0, -LAYOUT.hintGap)
	hint:SetTextColor(LAYOUT.edge[1], LAYOUT.edge[2], LAYOUT.edge[3])
	hint:SetText("Sliders: your shard. Drag me where you like, right-click to lock.")
	unlockedParts[#unlockedParts + 1] = hint
end
local function showLock()
	local unlocked = db and not db.locked
	for _, part in ipairs(unlockedParts) do part:SetShown(unlocked and true or false) end
end
local function setLocked(on)
	if not db then return end
	db.locked = on
	showLock()
	log(on and "line locked" or "line unlocked")
end
ns.setLocked = setLocked


local tentative   -- the leading key while none is confirmed

local function stale() return not lastRead or now() - lastRead > RULE.stale end

local function show()
	local why = paused()
	local key, sure = current, current ~= nil
	if not key then key = tentative end
	if why or loading or not key then
		text:SetText("?")
		text:SetTextColor(LAYOUT.grey[1], LAYOUT.grey[2], LAYOUT.grey[3])
		return
	end
	local c = (sure and not stale()) and LAYOUT.white or LAYOUT.grey
	text:SetText(shownLabel(key))
	text:SetTextColor(c[1], c[2], c[3])
end
ns.Text = function() return text:GetText() end

-- a stale check without a poller: one timer, re-armed while reads keep coming
local staleArmed = false
local function armStale()
	if staleArmed then return end
	staleArmed = true
	L.After(RULE.stale + 1, function()
		staleArmed = false
		show()
		if lastRead and not stale() then armStale() end
	end, "stale")
end

-- ---------------------------------------------------------------- party
local PARTY = { "player", "party1", "party2", "party3", "party4" }
local REASON = {}
if Enum and Enum.PhaseReason then for k, v in pairs(Enum.PhaseReason) do REASON[v] = k end end

local function unitName(unit)
	local n = L.Value((UnitName(unit)))
	return type(n) == "string" and n or unit
end

local offShard = {}   -- names of members (or "you") off the party shard, for the tooltip and /sliders
local function checkParty(why)
	wipe(offShard)
	if not inGroup() then wipe(partyState) return end
	for _, unit in ipairs(PARTY) do
		if L.Value(L.Read(UnitExists, unit)) == true then
			local inShard = L.Value(L.Read(UnitInPartyShard, unit))
			local reason = L.Num(L.Read(UnitPhaseReason, unit))
			local state = tostring(inShard) .. " " .. (reason and (REASON[reason] or tostring(reason)) or "-")
			if inShard == false then offShard[#offShard + 1] = unit == "player" and "you" or unitName(unit) end
			if partyState[unit] ~= state then
				partyState[unit] = state
				log(("party_shard %s %s %s (%s)"):format(unit, unit == "player" and "you" or unitName(unit), state, why))
			end
		else
			partyState[unit] = nil
		end
	end
end

-- ---------------------------------------------------------------- party exchange (S1 over PARTY only)
local function lockdown()
	local f = C_ChatInfo and C_ChatInfo.InChatMessagingLockdown
	return f and L.Value(L.Read(f)) == true
end

local send
local function queueSend(delay)
	if sendQueued then return end
	sendQueued = true
	L.After(delay, function() sendQueued = false send() end, "send")
end

send = function()
	if not current or not inGroup() or not (C_ChatInfo and C_ChatInfo.SendAddonMessage) then return end
	if L.InCombat() or lockdown() then return end   -- OnCombatChanged sends it after the fight
	local wait = KEEP.sendEvery - (now() - lastSend)
	if wait > 0 then queueSend(wait) return end
	local id = mapID() or 0
	local msg = ("S1;%d;%s;%d"):format(id, current, math.floor(now() - (currentSince or now())))
	lastSend = now()
	local ok, result = pcall(C_ChatInfo.SendAddonMessage, PREFIX, msg, "PARTY")   -- pcall: a blocked send throws on some builds
	local r = ok and L.Num(result) or nil
	if not ok or (r and r ~= 0) then log("send_failed " .. tostring(ok and r or "error")) end
end

local function onAddonMessage(_, prefix, body, channel, sender)
	prefix, body, channel, sender = L.Value(prefix), L.Value(body), L.Value(channel), L.Value(sender)
	if prefix ~= PREFIX or type(body) ~= "string" or type(sender) ~= "string" then return end
	if ns.isSelf(sender, body) then return end
	local first = firstName(sender)
	local v, id, key, age = strsplit(";", body)
	if v == "P1" or v == "R1" then
		ns.onPing(v, id, key, age, channel, first, function(msg)
			if channel == "WHISPER" then return ns.sendRoute("WHISPER", msg, sender) end
			if channel == "CHANNEL" then
				local ch = ns.channelID()
				return ch and ns.sendRoute("CHANNEL", msg, tostring(ch)) or "not joined"
			end
			return ns.sendRoute(channel, msg)
		end)
		return
	end
	if v ~= "S1" then
		if ns.hooks.message then ns.hooks.message(body, channel, sender, nil) end
		return
	end
	key = shardOf(key)
	if not key then return end
	local known = peers[first]
	peers[first] = { key = key, map = tonumber(id), t = now(), age = tonumber(age), how = "party" }
	if not known or known.key ~= key then   -- logged on a change only (0.2 logged every 30 s)
		log(("peer %s %s map %s ours %s (%s)"):format(first, key, tostring(id), current or "-",
			current == nil and "we have none" or (current == key and "same" or "differs")))
	end
	if not known then send() end   -- a new peer gets ours once (throttled)
end

-- ---------------------------------------------------------------- ping (0.2): which routes reach a friend on another shard
-- /sliders ping [name] sends one P1 over every route there is: guild, party, the SlidersTest channel, a whisper to
-- each online character friend (and to [name]), Battle.net game data to each Battle.net friend in this game. Each
-- receiver logs it, says it in chat and answers R1 over the route it came by. Nothing is sent but on that command and
-- as its answer; the log keeps each route's send result (offline, throttled ...) for docs/shards.md question 10.
local CHANNEL = "SlidersTest"
local ROUTES = { GUILD = "guild", PARTY = "party", RAID = "raid", INSTANCE_CHAT = "instance", WHISPER = "whisper",
	CHANNEL = "channel", BN = "Battle.net" }
local RESULTS = { [1] = "bad prefix", [2] = "bad message", [3] = "throttled", [4] = "bad route", [5] = "not in a group",
	[6] = "no target", [7] = "no channel", [8] = "channel throttled", [9] = "error", [10] = "no guild",
	[11] = "chat locked", [12] = "offline" }
local lastPing, answered = -100, {}

function ns.channelID()
	local id = L.Num(L.Read(GetChannelName, CHANNEL))
	return id and id > 0 and id or nil
end

local function joinChannel()
	if not db or not db.channel or ns.channelID() or type(JoinTemporaryChannel) ~= "function" then return end
	local ok = pcall(JoinTemporaryChannel, CHANNEL)   -- pcall: a full channel list refuses
	log(ok and ns.channelID() and "channel joined" or "channel join failed")
end

-- "ok", or why not (the SendAddonMessageResult in words)
function ns.sendRoute(route, msg, target)
	local ok, r
	sentBodies[msg] = now()
	if next(sentBodies) and math.random() < 0.05 then   -- now and then: forget the old ones
		for b, t in pairs(sentBodies) do if now() - t > 60 then sentBodies[b] = nil end end
	end
	if route == "BN" then
		if not (C_BattleNet and C_BattleNet.SendGameData) then return "no Battle.net" end
		ok, r = pcall(C_BattleNet.SendGameData, target, PREFIX, msg)
	else
		if not (C_ChatInfo and C_ChatInfo.SendAddonMessage) then return "no addon messages" end
		ok, r = pcall(C_ChatInfo.SendAddonMessage, PREFIX, msg, route, target)
	end
	if not ok then return "error" end
	r = L.Num(r)
	if r == nil or r == 0 then return "ok" end   -- some builds return nothing on success
	return RESULTS[r] or ("result " .. r)
end

local function charFriends()
	local out = {}
	local n = C_FriendList and L.Num(L.Read(C_FriendList.GetNumFriends)) or 0
	for i = 1, math.min(n, 100) do
		local f = L.Read(C_FriendList.GetFriendInfoByIndex, i)
		local name = type(f) == "table" and L.Value(f.name)
		if type(name) == "string" and L.Value(f.connected) == true then out[#out + 1] = name end
	end
	return out
end

local function bnFriends()
	local out = {}
	if not (C_BattleNet and C_BattleNet.GetFriendAccountInfo) then return out end
	local n = L.Num(L.Read(BNGetNumFriends)) or 0
	local same = FriendsListUtil and FriendsListUtil.IsPlayingSameWoWProject
	for i = 1, math.min(n, 200) do
		local a = L.Read(C_BattleNet.GetFriendAccountInfo, i)
		local g = type(a) == "table" and a.gameAccountInfo
		local id = type(g) == "table" and L.Num(g.gameAccountID)
		if id and L.Value(g.isOnline) == true and (not same or L.Read(same, g) == true) then
			local name = L.Value(g.characterName)
			out[#out + 1] = { id = id, name = type(name) == "string" and name or ("account " .. id) }
		end
	end
	return out
end

local function ping(arg)
	if now() - lastPing < 10 then P("one ping per 10 seconds.") return end
	if lockdown() then P("chat is locked for addons right now (a boss fight or a rated match); try after it.") return end
	lastPing = now()
	local id = tostring(math.floor(stamp()))
	local msg = ("P1;%s;%d;%s"):format(id, mapID() or 0, current or "-")
	local parts, sent, failed = {}, {}, 0
	local function try(kind, label, route, target)
		local r = ns.sendRoute(route, msg, target)
		parts[#parts + 1] = label .. " " .. r
		if r == "ok" then sent[kind] = (sent[kind] or 0) + 1 else failed = failed + 1 end
	end
	if L.Read(IsInGuild) == true then try("guild", "guild", "GUILD") end
	if inGroup() then try("party", "party", "PARTY") end
	local ch = ns.channelID()
	if ch then try("channel", "channel", "CHANNEL", tostring(ch)) end
	local seen = {}
	if arg ~= "" then seen[arg] = true try("whisper", "whisper " .. arg, "WHISPER", arg) end
	for _, name in ipairs(charFriends()) do
		if not seen[name] then seen[name] = true try("whisper", "whisper " .. name, "WHISPER", name) end
	end
	for _, f in ipairs(bnFriends()) do try("Battle.net", "Battle.net " .. f.name, "BN", f.id) end
	log(("ping %s sent: %s"):format(id, table.concat(parts, ", ")))
	local short = {}
	for _, kind in ipairs({ "guild", "party", "channel", "whisper", "Battle.net" }) do
		local k = sent[kind]
		if k then short[#short + 1] = (k > 1 and (k .. " ") or "") .. kind end
	end
	P(("ping sent (%s)%s; answers show up here."):format(#short > 0 and table.concat(short, ", ") or "nowhere",
		failed > 0 and (", " .. failed .. " failed: /sliders log") or ""))
end

local function compare(key)
	if key == nil or key == "-" then return "they have no shard yet" end
	if current == nil then return "you have none yet" end
	return key == current and "the same shard as you" or "a different shard"
end
ns.compare = compare

function ns.onPing(v, id, map, key, route, from, reply)
	if type(id) ~= "string" then return end
	local how = ROUTES[route] or tostring(route)
	key = shardOf(key) or "-"
	local state = key == "-" and "none" or (current == nil and "we have none" or (key == current and "same" or "differs"))
	log(("%s %s by %s from %s map %s key %s ours %s (%s)"):format(v == "P1" and "ping_in" or "pong", id, how, from,
		tostring(map), key, current or "-", state))
	if key ~= "-" then peers[from] = { key = key, map = tonumber(map), t = now(), how = how } end
	if v == "R1" then
		P(("%s answered by %s: %s, %s."):format(from, how, key ~= "-" and labelOf(key, tonumber(map)) or "-", compare(key)))
		return
	end
	say(("%s pinged you by %s: %s, %s."):format(from, how, key ~= "-" and labelOf(key, tonumber(map)) or "-", compare(key)))
	local k = id .. route .. from
	if answered[k] or lockdown() then return end
	answered[k] = true
	local r = reply(("R1;%s;%d;%s"):format(id, mapID() or 0, current or "-"))
	if r ~= "ok" then log(("pong_failed %s by %s to %s: %s"):format(id, how, from, r)) end
end

L.On("BN_CHAT_MSG_ADDON", function(_, prefix, body, _, senderID)
	prefix, body, senderID = L.Value(prefix), L.Value(body), L.Num(senderID)
	if prefix ~= PREFIX or type(body) ~= "string" or not senderID then return end
	local v, id, map, key = strsplit(";", body)
	if v ~= "P1" and v ~= "R1" then
		if ns.hooks.message then ns.hooks.message(body, "BN", nil, senderID) end
		return
	end
	local info = C_BattleNet and L.Read(C_BattleNet.GetGameAccountInfoByID, senderID)
	local name = type(info) == "table" and L.Value(info.characterName)
	ns.onPing(v, id, map, key, "BN", type(name) == "string" and name or ("account " .. senderID),
		function(msg) return ns.sendRoute("BN", msg, senderID) end)
end, "bn")

ns.api = {
	P = P, say = say, log = log, now = now, stamp = stamp, mapID = mapID, mapName = mapName, label = labelOf,
	serverOf = serverOf, shardOf = shardOf, current = function() return current end, inGroup = inGroup,
	isLeader = isLeader, lockdown = lockdown, paused = paused, instanced = instanced, PREFIX = PREFIX,
	charFriends = charFriends, bnFriends = bnFriends, groupSize = groupSize, age = age, realm = realm, norm = norm,
	first = firstName, ownFull = ownFull,
}

-- players seen on this shard in the last 5 minutes (target, mouseover, nameplates): how crowded it is
local lastCrowd = {}   -- shard -> { n, t = time() }: players seen there the last time we were on it (this session)
-- players seen on `shard` (default: ours) in the last 5 minutes; for a shard we left, the count from when we left it
-- and when that was
function ns.crowd(shard)
	if shard and shard ~= current then
		local c = lastCrowd[shard]
		return c and c.n, c and c.t
	end
	local n, t = 0, now()
	for g, p in pairs(players) do
		if t - p.t > 300 then players[g] = nil elseif p.key == current then n = n + 1 end
	end
	if current then lastCrowd[current] = { n = n, t = stamp() } end
	return n
end

-- ---------------------------------------------------------------- keys
local function reset(why)
	if current then
		prev = { key = current, map = mapID(), why = why }
		ns.crowd()   -- keep the count for the shard we leave
	end
	current, currentSince, tentative = nil, nil, nil
	wipe(window)
	show()
	hook("reset", why)
end

local function confirm(key)
	local before = current
	current, currentSince = key, now()
	local id = mapID()
	local label = labelOf(key, id)
	local parts = { ("key %s %s"):format(key, label) }
	if before then
		parts[#parts + 1] = "was " .. before .. " (no reset: an in-zone change)"
	elseif prev then
		parts[#parts + 1] = ("prev %s after %s (%s)"):format(prev.key, prev.why, prev.key == key and "same" or "changed")
	end
	parts[#parts + 1] = ("zone %s, group %s, transfer %s"):format(ago(lastZone), ago(lastGroup), ago(lastTransfer))
	log(table.concat(parts, "; "))
	if before and before ~= key then
		say(("your shard changed while you stayed in the zone: %s -> %s."):format(shownLabel(before), label))
	end
	prev = nil
	checkParty("new key")
	send()
	hook("key", key, before)
end

local function evaluate()
	local t = now()
	local i = 1
	while window[i] do
		if t - window[i].t > RULE.window then table.remove(window, i) else i = i + 1 end
	end
	local total = #window
	local stats = {}
	for _, r in ipairs(window) do
		local s = stats[r.key]
		if not s then s = { n = 0, units = {}, u = 0, first = r.t, last = r.t } stats[r.key] = s end
		s.n = s.n + 1
		if not s.units[r.guid] then s.units[r.guid] = true s.u = s.u + 1 end
		if r.t < s.first then s.first = r.t end
		if r.t > s.last then s.last = r.t end
	end
	local best, bs
	for key, s in pairs(stats) do
		if not bs or s.n > bs.n then best, bs = key, s end
	end
	if not best then return end
	local ok = bs.n >= RULE.reads and bs.u >= RULE.npcs and bs.last - bs.first >= RULE.span and bs.n >= RULE.share * total
	if ok and best ~= current then confirm(best) end
	tentative = best
	show()
end
ns.Evaluate = evaluate

-- per map and token: ok / secret / none / refused, each with a "c" twin for reads in combat
local function count(token, what)
	local m = mapData(mapID())
	if not m then return end
	m.ctx = pvpContext()
	local r = m.reads[token]
	if not r then r = {} m.reads[token] = r end
	local k = L.InCombat() and (what .. "c") or what
	r[k] = (r[k] or 0) + 1
end

local function sighting(key, guid, npc, token)
	local t = now()
	local last = seenGUID[guid]
	if last and t - last < KEEP.sightEvery then return end
	if not last then
		seenN = seenN + 1
		if seenN > 2000 then wipe(seenGUID) seenN = 0 end
	end
	seenGUID[guid] = t
	-- time;uiMapID;token;key;npcID;combat
	char.sightings[#char.sightings + 1] = ("%d;%d;%s;%s;%s;%d"):format(stamp(), mapID() or 0, token, key, npc,
		L.InCombat() and 1 or 0)
	if #char.sightings > KEEP.sightings + KEEP.slack then L.Cap(char.sightings, KEEP.sightings) end
end

local function keyed(key, guid, npc, token, zone)
	local m = mapData(mapID())
	if not m then return end
	local t = stamp()
	local rec = m.keys[key]
	if not rec then
		rec = { first = t, last = t, n = 0, npcs = 0, tokens = {} }
		m.keys[key] = rec
	end
	rec.last, rec.n = t, rec.n + 1
	rec.tokens[token] = (rec.tokens[token] or 0) + 1
	if not keyUnits[key .. guid] then keyUnits[key .. guid] = true rec.npcs = rec.npcs + 1 end
	sighting(key .. "-" .. (zone or "?"), guid, npc, token)
	window[#window + 1] = { t = now(), key = key, guid = guid }
	lastRead = now()
	armStale()
	evaluate()
end

local function read(unit, token)
	if loading or not char then return end
	if L.Value(L.Read(UnitExists, unit)) ~= true then return end
	local hidden = C_Secrets and C_Secrets.ShouldUnitIdentityBeSecret
	if hidden and L.Value(L.Read(hidden, unit)) == true then count(token, "secret") return end
	local ok, raw = pcall(UnitGUID, unit)   -- guard: a PvP-restricted token may be refused
	if not ok then count(token, "refused") return end
	local kind = L.Kind(raw)
	if kind == "secret" then count(token, "secret") return end
	if kind == "nil" then count(token, "none") return end
	local guid = L.Value(raw)
	if type(guid) ~= "string" then count(token, "none") return end
	if guid:sub(1, 7) == "Player-" then
		if current and guid ~= ownGUID and not paused() then players[guid] = { t = now(), key = current } end
		return
	end
	local gk, server, map, zone, npc = guid:match("^(%a+)%-%d+%-(%d+)%-(%d+)%-(%d+)%-(%d+)%-")
	if not gk or not KINDS[gk] then return end   -- players, pets, objects: not a shard reading
	if L.Value(L.Read(UnitPlayerControlled, unit)) == true then return end
	count(token, "ok")
	if paused() then return end
	keyed(server .. "-" .. map, guid, npc, token, zone)
end
ns.Read = read

-- ---------------------------------------------------------------- tooltip

local function inWindow(key)
	local n, units = 0, {}
	local u = 0
	for _, r in ipairs(window) do
		if r.key == key then
			n = n + 1
			if not units[r.guid] then units[r.guid] = true u = u + 1 end
		end
	end
	return n, u
end

local function statusLines()
	local out = {}
	local why = paused()
	local key = current or tentative
	if loading then
		out[#out + 1] = "loading."
	elseif why then
		out[#out + 1] = ("paused %s: shards are not read there."):format(why == "taxi" and "on a flight" or "in an instance")
	elseif not key then
		out[#out + 1] = "no shard yet: target an NPC or move the mouse over one (nameplates count too)."
	else
		local n, u = inWindow(key)
		local state
		if current and not stale() then state = "confirmed " .. age(now() - currentSince) .. " ago"
		elseif current then state = "stale: no reading for " .. age(now() - (lastRead or now()))
		else state = ("not confirmed yet (it needs %d reads from %d NPCs over %d s)"):format(RULE.reads, RULE.npcs, RULE.span) end
		out[#out + 1] = ("%s, %s; %d reads from %d NPCs in the last minute; %d players seen in 5 min."):format(
			shownLabel(key), state, n, u, ns.crowd())
	end
	if inGroup() then
		checkParty("asked")
		out[#out + 1] = #offShard == 0 and "party: everyone is on the party's shard."
			or ("party: not on the party's shard: %s."):format(table.concat(offShard, ", "))
	end
	for name, p in pairs(peers) do
		out[#out + 1] = ("%s is on %s (%s ago%s): %s."):format(name, labelOf(p.key, p.map), age(now() - p.t),
			p.how and (", by " .. p.how) or "", ns.compare(p.key))
	end
	local m = char and char.maps[mapID() or -1]
	if m then
		local parts = {}
		for _, token in ipairs({ "target", "mouseover", "nameplate" }) do
			local r = m.reads[token]
			if r then
				parts[#parts + 1] = ("%s %d ok / %d secret / %d nil (in combat %d / %d / %d)"):format(token,
					r.ok or 0, (r.secret or 0) + (r.refused or 0), r.none or 0, r.okc or 0,
					(r.secretc or 0) + (r.refusedc or 0), r.nonec or 0)
			end
		end
		if #parts > 0 then out[#out + 1] = "reads here: " .. table.concat(parts, "; ") .. "." end
	end
	if ns.contactLines then for _, line in ipairs(ns.contactLines()) do out[#out + 1] = line end end
	return out
end

-- the tooltip: a few short lines in Blizzard's tooltip layout (alcaras: "tooltip is really bad / hard to read"); the
-- read counts and the full lists stay in /sliders
local TIP = { gold = { 1, 0.82, 0 }, white = { 1, 1, 1 }, muted = { 0.6, 0.6, 0.6 }, green = { 0.4, 0.85, 0.4 },
	warn = { 1, 0.6, 0.2 } }
local function tipLine(tt, text, c) tt:AddLine(text, c[1], c[2], c[3], true) end
local function tipPair(tt, left, right, lc, rc) tt:AddDoubleLine(left, right, lc[1], lc[2], lc[3], rc[1], rc[2], rc[3]) end

local function tooltip(tt, hint)
	tipPair(tt, "Sliders", ns.VERSION, TIP.gold, TIP.muted)
	local why = paused()
	local key = current or tentative
	if loading then
		tipLine(tt, "Loading...", TIP.muted)
	elseif why then
		tipLine(tt, why == "taxi" and "Paused on a flight: shards are not read there."
			or "Paused in an instance: shards are not read there.", TIP.muted)
	elseif not key then
		tipLine(tt, "No shard yet: target an NPC or move the mouse over one.", TIP.white)
	else
		local state, c
		if current and not stale() then state, c = "confirmed", TIP.green
		elseif current then state, c = "no NPC for " .. age(now() - (lastRead or now())), TIP.muted
		else state, c = "reading NPCs...", TIP.muted end
		tipPair(tt, shownLabel(key), state, TIP.white, c)
		tipLine(tt, ("%d players seen in the last 5 min"):format(ns.crowd()), TIP.muted)
	end
	if inGroup() then
		checkParty("asked")
		if #offShard == 0 then tipLine(tt, "Party: everyone on the party's shard", TIP.muted)
		else tipLine(tt, "Party: not on the party's shard: " .. table.concat(offShard, ", "), TIP.warn) end
	end
	local open = ns.openText and ns.openText()
	if open then tipLine(tt, open, TIP.muted) end
	local rows = ns.friendRows and ns.friendRows() or {}
	tt:AddLine(" ")
	tipLine(tt, "Friends with Sliders", TIP.gold)
	if #rows == 0 then
		tipLine(tt, ns.asking and ns.asking() and "Asking your friends..."
			or "None online. Friends show here once they run Sliders too.", TIP.muted)
	else
		for _, r in ipairs(rows) do
			local name = ns.classColored(r.name, r.class) .. (r.open and " |cff66d966open|r" or "")
				.. (r.old and " |cff999999old version|r" or "")
			tipPair(tt, name, r.where, TIP.white, r.same and TIP.green or (r.here and TIP.white or TIP.muted))
		end
	end
	tt:AddLine(" ")
	tipLine(tt, hint or (db and db.locked and "Click: shards here  ·  Right-click: unlock"
		or "Drag: move  ·  Right-click: lock  ·  Click: shards here"), TIP.muted)
end
ns.tooltip = tooltip

L.Script(frame, "OnEnter", function(self)
	GameTooltip:SetOwner(self, "ANCHOR_BOTTOMLEFT")
	tooltip(GameTooltip)
	GameTooltip:Show()
end, "tooltip")
L.Script(frame, "OnLeave", function() GameTooltip:Hide() end, "tooltip")
-- a click (not a drag) opens the shards panel (Hop.lua)
local downX, downY
L.Script(frame, "OnMouseDown", function() downX, downY = GetCursorPosition() end, "click")
L.Script(frame, "OnMouseUp", function(_, button)
	local x, y = GetCursorPosition()
	if not downX or math.abs(x - downX) + math.abs(y - downY) >= 6 then return end   -- a drag, not a click
	if button == "RightButton" then
		setLocked(not db.locked)
	elseif button == "LeftButton" and ns.TogglePanel then
		ns.TogglePanel()
	end
end, "click")

-- ---------------------------------------------------------------- events
L.On("PLAYER_TARGET_CHANGED", function() read("target", "target") end)
L.On("UPDATE_MOUSEOVER_UNIT", function() read("mouseover", "mouseover") end)
L.On("NAME_PLATE_UNIT_ADDED", function(_, unit)
	unit = L.Value(unit)
	if type(unit) == "string" then read(unit, "nameplate") end
end)

L.On("PLAYER_LEAVING_WORLD", function() loading = true show() end)
L.On("PLAYER_ENTERING_WORLD", function(_, login, reload)
	loading = false
	lastZone = { t = now(), what = "world" }
	log(("world %s%s"):format(mapName(mapID()), L.Value(login) == true and " login" or (L.Value(reload) == true and " reload" or "")))
	reset("world")
	checkParty("world")
	L.After(10, joinChannel, "channel")
	hook("world", L.Value(login) == true)
end)
L.On("ZONE_CHANGED_NEW_AREA", function()
	lastZone = { t = now(), what = "zone" }
	log(("zone %s"):format(mapName(mapID())))
	reset("zone")
end)

L.On("SHARD_TRANSFER_IMMINENT", function()
	local sec = L.Num(L.Read(GetEvictionTimeRemaining))
	lastTransfer = { t = now(), what = "imminent" }
	log(("transfer_imminent %s"):format(sec and tostring(math.floor(sec)) or "?"))
	say(("a shard move is coming%s."):format(sec and (" in " .. age(sec)) or ""))
	hook("imminent", sec)
end)
L.On("SHARD_TRANSFER_CANCELLED", function()
	lastTransfer = { t = now(), what = "cancelled" }
	log("cancelled")
	hook("transfer", false)
end)
L.On("SHARD_TRANSFER", function()
	lastTransfer = { t = now(), what = "transfer" }
	log("transfer")
	reset("transfer")
	hook("transfer", true)
end)

L.On("GROUP_JOINED", function()
	lastGroup = { t = now(), what = "joined" }
	log("joined")
	-- no reset: the inviter never moves, and whoever is moved gets SHARD_TRANSFER (reset there); a move without it
	-- would still show as an in-zone change (alcaras 2026-11-09: "if you invite, it thinks it doesn't know what shard
	-- you're in")
	checkParty("joined")
	hook("joined")
end)
L.On("GROUP_LEFT", function()
	lastGroup = { t = now(), what = "left" }
	log("left")
	wipe(peers)
	checkParty("left")
	hook("left")
end)
L.On("PARTY_LEADER_CHANGED", function()
	log("leader " .. (isLeader() and "you" or "other"))
end)
L.On("PARTY_INVITE_REQUEST", function(_, name, _, _, _, _, _, inviterGUID)
	name, inviterGUID = L.Value(name), L.Value(inviterGUID)
	lastGroup = { t = now(), what = "invite" }
	log("invite " .. (type(name) == "string" and name or "?"))
	hook("invite", name, inviterGUID)
end)
L.On("GROUP_ROSTER_UPDATE", function()
	checkParty("roster")
	local size = groupSize()
	if current and size ~= lastRoster then send() end   -- a new member gets ours; not every roster event
	lastRoster = size
	hook("roster")
end)
L.On("CHAT_MSG_ADDON", onAddonMessage)

-- UNIT_PHASE for the player and party1..4 only (RegisterUnitEvent takes two units per frame)
local function onPhase() checkParty("phase") end
for _, pair in ipairs({ { "player", "party1" }, { "party2", "party3" }, { "party4" } }) do
	local f = CreateFrame("Frame")
	L.Register(f, "UNIT_PHASE", unpack(pair))
	L.Script(f, "OnEvent", onPhase, "UNIT_PHASE")
end

L.OnCombatChanged(function(inCombat)
	if not inCombat and current then send() end
	show()
	hook("combat", inCombat)
end, "combat")

-- ---------------------------------------------------------------- load
-- AlcShardDB (the name before 0.1.0) is not read: it was never written in game, and the game only loads a saved
-- variables file for the addon of that name
L.OnLoad(function()
	if type(SlidersDB) ~= "table" then SlidersDB = {} end
	db = L.Fill(SlidersDB, { version = 1, shown = true, locked = false, chat = false, channel = false, chars = {} })
	ownGUID = L.Value(L.Read(UnitGUID, "player"))
	char = charData()
	ns.db, ns.char = db, char
	hook("load")
	local old = stamp() - KEEP.keyDays * 86400   -- keys unseen for two weeks: records of shards long gone
	for _, m in pairs(char.maps) do
		for key, rec in pairs(m.keys) do if (rec.last or 0) < old then m.keys[key] = nil end end
	end
	L.RestorePoint(frame, db.pos, DefaultPoint)
	L.Movable(frame, function(pos) db.pos = pos end)
	L.Script(frame, "OnDragStart", function(self) if not db.locked then self:StartMoving() end end, "drag")
	showLock()
	frame:SetShown(db.shown)
	if C_ChatInfo and C_ChatInfo.RegisterAddonMessagePrefix then
		pcall(C_ChatInfo.RegisterAddonMessagePrefix, PREFIX)   -- guard: a client that throws on a known prefix
	end
end)

-- ---------------------------------------------------------------- slash
local function showLog(arg)
	if not char or #char.log == 0 then P("nothing logged yet.") return end
	local n = math.max(1, math.min(tonumber(arg) or 15, 200))
	local first = math.max(1, #char.log - n + 1)
	for i = first, #char.log do
		local e = char.log[i]
		P(("%s %s g%d%s%s: %s"):format(date("%H:%M:%S", e[1]), mapName(e[2] ~= 0 and e[2] or nil), e[3],
			e[4] == 1 and " lead" or "", e[5] == 1 and " combat" or "", e[6]))
	end
end

SLASH_SLIDERS1 = "/sliders"
local commands
commands = {
	[""] = function() for _, line in ipairs(statusLines()) do P(line) end end,
	log = showLog,
	mark = function(arg)
		if arg == "" then P("/sliders mark <text>: a note in the log, like \"crossed into Stonetalon\".") return end
		log("mark " .. arg)
		P("marked: " .. arg)
	end,
	hide = function() db.shown = false frame:Hide() P("the shard line is hidden (/sliders show brings it back).") end,
	show = function() db.shown = true frame:Show() show() P("the shard line is shown.") end,
	ping = ping,
	channel = function(arg)
		if arg == "off" then
			db.channel = false
			if ns.channelID() then pcall(LeaveChannelByName, CHANNEL) end
			P("left the " .. CHANNEL .. " channel; /sliders channel on joins it again.")
		elseif arg == "on" then
			db.channel = true
			joinChannel()
			P(ns.channelID() and ("in the " .. CHANNEL .. " channel.")
				or "could not join the channel (the channel list may be full).")
		else
			P(ns.channelID() and ("in the " .. CHANNEL .. " channel (/sliders channel off leaves it).")
				or ("not in the " .. CHANNEL .. " channel (/sliders channel on)."))
		end
	end,
	version = function() P("Sliders " .. ns.VERSION .. " (github.com/alcaras/sliders/releases).") end,
	lock = function() setLocked(true) P("the shard line is locked (right-click it or /sliders unlock to move it).") end,
	unlock = function() setLocked(false) P("the shard line is unlocked: drag it, then right-click to lock.") end,
	chat = function(arg)
		if arg == "on" or arg == "off" then db.chat = arg == "on" end
		P(db.chat and "automatic chat lines are on (/sliders chat off)." or "silent: nothing in chat unless you ask (/sliders chat on).")
	end,
}
ns.commands = commands
SlashCmdList.SLIDERS = L.Slash(commands, "/sliders: your shard | /sliders shards: the shards here, with Hop | /sliders open"
	.. " off | solo | group | /sliders invite ask | friends | anyone | /sliders hop <server> | /sliders ping [name] | /sliders log [n]"
	.. " | /sliders version | /sliders mark <text> | /sliders hide | show | lock | unlock | /sliders chat on | off | /sliders channel on | off | /sliders minimap", P)
