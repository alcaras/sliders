-- Portage: which shard of WoW Forever's mega server you are on, read from the NPCs around you and logged per zone;
-- grouped, it tells your party which shard you see. It only reads and records: it never invites, accepts, leaves or
-- calls anything protected. Standalone (its helpers in Lib.lua). Design: wow-addons docs/shards.md (was AlcShard).
--
-- How (API checked against Forever's API index, build 1.60.1.70862, 2026-11-08):
--   UnitGUID(target | mouseover | nameplateN) on PLAYER_TARGET_CHANGED, UPDATE_MOUSEOVER_UNIT, NAME_PLATE_UNIT_ADDED.
--   UnitGUID is SecretWhenUnitIdentityRestricted and takes a UnitTokenPvPRestrictedForAddOns token: every read goes
--   through pcall + L.Kind first; a refused, nil or secret read is only counted (per token, in / out of combat),
--   never parsed. C_Secrets.ShouldUnitIdentityBeSecret(unit) is asked first; "yes" counts as secret without a read.
--   Kinds Creature and Vehicle only, no UnitPlayerControlled units (a pet keeps its summon-time GUID).
--   Key = serverID-mapID-zoneUID, whatever its shape (in-game zoneUIDs differ from the combat log's).
--   Confirmed by dwell and majority (RULE below), not by two reads: keys of other shards flicker in often.
--   Party: UnitInPartyShard (no flag) and UnitPhaseReason (identity flag, L.Value) for player and party1..4.
--   Shard moves: SHARD_TRANSFER_IMMINENT (+ GetEvictionTimeRemaining), SHARD_TRANSFER_CANCELLED, SHARD_TRANSFER.
--   Party exchange, to learn whether two clients see the same key: "S1;<uiMapID>;<key>;<ageSec>" over PARTY only.
--   Ping test (0.2): /portage ping sends P1 over guild, the PortageTest channel, whispers and Battle.net; R1 answers.
local _, ns = ...
local L = ns.L

local LAYOUT = {
	point = { "TOP", "BOTTOM", 0, -6 },             -- under the minimap (left of it, the buffs drew over the line)
	fallback = { "TOPRIGHT", "TOPRIGHT", -40, -200 },   -- no Minimap frame: about where it would be
	width = 120, height = 14,
	font = 11,
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
local KEEP = { log = 1000, sightings = 4000, slack = 100, labelHours = 12, keyDays = 14, sightEvery = 20, sendEvery = 30 }
local PREFIX = "Portage"
local KINDS = { Creature = true, Vehicle = true }

local P = L.Printer("Portage", "66ccff")
local db, char

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
local lastSend, sendQueued = -1e9, false

local function now() return L.Num(GetTime()) or 0 end
local function stamp() return L.Num(time()) or 0 end

-- ---------------------------------------------------------------- context
local function mapID()
	return L.Num(L.Read(C_Map.GetBestMapForUnit, "player"))
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
		c = { maps = {}, labels = {}, log = {}, sightings = {} }
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

local LETTERS = "ABCDEFGHIJKLMNOPQRSTUVWXYZ"
local function labelOf(key, id)
	if not char then return key end
	local t = stamp()
	local rec = char.labels[key]
	if rec then rec.last = t return rec.name end
	local zone = shortZone(mapName(id))
	local used = {}
	for k, r in pairs(char.labels) do
		if t - (r.last or 0) > KEEP.labelHours * 3600 then
			char.labels[k] = nil                       -- unseen 12 h: keys get reused
		elseif r.zone == zone then
			used[r.letter] = true
		end
	end
	local letter = "?"
	for i = 1, #LETTERS do
		local l = LETTERS:sub(i, i)
		if not used[l] then letter = l break end
	end
	rec = { name = zone .. " " .. letter, zone = zone, letter = letter, last = t }
	char.labels[key] = rec
	return rec.name
end

local function shownLabel(key)
	local rec = char and char.labels[key]
	return rec and rec.name or key
end

-- ---------------------------------------------------------------- the line on screen
local frame = CreateFrame("Frame", "PortageFrame", UIParent)
local function DefaultPoint(f)
	local p = Minimap and LAYOUT.point or LAYOUT.fallback
	f:SetPoint(p[1], Minimap or UIParent, p[2], p[3], p[4])
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

local offShard = {}   -- names of members (or "you") off the party shard, for the tooltip and /portage
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
	local first = sender:match("^[^%s%-]+") or sender
	if first == L.Value((UnitName("player"))) then return end
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
	if v ~= "S1" or not key then return end
	local known = peers[first]
	peers[first] = { key = key, map = tonumber(id), t = now(), age = tonumber(age) }
	log(("peer %s %s map %s ours %s (%s)"):format(first, key, tostring(id), current or "-",
		current == nil and "we have none" or (current == key and "same" or "differs")))
	if not known then send() end   -- a new peer gets ours once (throttled)
end

-- ---------------------------------------------------------------- ping (0.2): which routes reach a friend on another shard
-- /portage ping [name] sends one P1 over every route there is: guild, party, the PortageTest channel, a whisper to
-- each online character friend (and to [name]), Battle.net game data to each Battle.net friend in this game. Each
-- receiver logs it, says it in chat and answers R1 over the route it came by. Nothing is sent but on that command and
-- as its answer; the log keeps each route's send result (offline, throttled ...) for docs/shards.md question 10.
local CHANNEL = "PortageTest"
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
	if not db or db.channel == false or ns.channelID() or type(JoinTemporaryChannel) ~= "function" then return end
	local ok = pcall(JoinTemporaryChannel, CHANNEL)   -- pcall: a full channel list refuses
	log(ok and ns.channelID() and "channel joined" or "channel join failed")
end

-- "ok", or why not (the SendAddonMessageResult in words)
function ns.sendRoute(route, msg, target)
	local ok, r
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
	local parts, n = {}, 0
	local function try(label, route, target)
		local r = ns.sendRoute(route, msg, target)
		parts[#parts + 1] = label .. " " .. r
		if r == "ok" then n = n + 1 end
	end
	if L.Read(IsInGuild) == true then try("guild", "GUILD") end
	if inGroup() then try("party", "PARTY") end
	local ch = ns.channelID()
	if ch then try("channel", "CHANNEL", tostring(ch)) else parts[#parts + 1] = "channel not joined" end
	local seen = {}
	if arg ~= "" then seen[arg] = true try("whisper " .. arg, "WHISPER", arg) end
	for _, name in ipairs(charFriends()) do
		if not seen[name] then seen[name] = true try("whisper " .. name, "WHISPER", name) end
	end
	for _, f in ipairs(bnFriends()) do try("Battle.net " .. f.name, "BN", f.id) end
	log(("ping %s sent: %s"):format(id, table.concat(parts, ", ")))
	P(("ping sent by %d routes: %s. Answers show up here."):format(n, table.concat(parts, ", ")))
end

local function compare(key)
	if key == nil or key == "-" then return "they have no shard yet" end
	if current == nil then return "you have none yet" end
	return key == current and "the same key as you" or "a different key from yours"
end
ns.compare = compare

function ns.onPing(v, id, map, key, route, from, reply)
	if type(id) ~= "string" then return end
	local how = ROUTES[route] or tostring(route)
	key = key or "-"
	local state = key == "-" and "none" or (current == nil and "we have none" or (key == current and "same" or "differs"))
	log(("%s %s by %s from %s map %s key %s ours %s (%s)"):format(v == "P1" and "ping_in" or "pong", id, how, from,
		tostring(map), key, current or "-", state))
	if key ~= "-" then peers[from] = { key = key, map = tonumber(map), t = now(), how = how } end
	if v == "R1" then
		P(("%s answered by %s: %s, %s."):format(from, how, key, compare(key)))
		return
	end
	P(("%s pinged you by %s: %s, %s."):format(from, how, key, compare(key)))
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
	if v ~= "P1" and v ~= "R1" then return end
	local info = C_BattleNet and L.Read(C_BattleNet.GetGameAccountInfoByID, senderID)
	local name = type(info) == "table" and L.Value(info.characterName)
	ns.onPing(v, id, map, key, "BN", type(name) == "string" and name or ("account " .. senderID),
		function(msg) return ns.sendRoute("BN", msg, senderID) end)
end, "bn")

-- ---------------------------------------------------------------- keys
local function reset(why)
	if current then prev = { key = current, map = mapID(), why = why } end
	current, currentSince, tentative = nil, nil, nil
	wipe(window)
	show()
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
		P(("your shard changed while you stayed in the zone: %s -> %s."):format(shownLabel(before), label))
	end
	prev = nil
	checkParty("new key")
	send()
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

local function keyed(key, guid, npc, token)
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
	sighting(key, guid, npc, token)
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
	local gk, server, map, zone, npc = guid:match("^(%a+)%-%d+%-(%d+)%-(%d+)%-(%d+)%-(%d+)%-")
	if not gk or not KINDS[gk] then return end   -- players, pets, objects: not a shard reading
	if L.Value(L.Read(UnitPlayerControlled, unit)) == true then return end
	count(token, "ok")
	if paused() then return end
	keyed(server .. "-" .. map .. "-" .. zone, guid, npc, token)
end
ns.Read = read

-- ---------------------------------------------------------------- tooltip
local function age(sec)
	sec = math.floor(sec)
	if sec < 90 then return sec .. " s" end
	return math.floor(sec / 60 + 0.5) .. " min"
end

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
		local label = shownLabel(key)
		out[#out + 1] = ("%s, %s; %d reads from %d NPCs in the last minute."):format(
			label == key and ("key " .. key) or ("%s (key %s)"):format(label, key), state, n, u)
	end
	if inGroup() then
		checkParty("asked")
		out[#out + 1] = #offShard == 0 and "party: everyone is on the party's shard."
			or ("party: not on the party's shard: %s."):format(table.concat(offShard, ", "))
	end
	for name, p in pairs(peers) do
		out[#out + 1] = ("%s sees %s (%s ago%s): %s."):format(name, p.key, age(now() - p.t),
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
	return out
end

L.Script(frame, "OnEnter", function(self)
	GameTooltip:SetOwner(self, "ANCHOR_BOTTOMLEFT")
	GameTooltip:AddLine("Portage")
	for _, line in ipairs(statusLines()) do GameTooltip:AddLine(line, 1, 1, 1, true) end
	GameTooltip:Show()
end, "tooltip")
L.Script(frame, "OnLeave", function() GameTooltip:Hide() end, "tooltip")

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
	P(("a shard move is coming%s."):format(sec and (" in " .. age(sec)) or ""))
end)
L.On("SHARD_TRANSFER_CANCELLED", function()
	lastTransfer = { t = now(), what = "cancelled" }
	log("cancelled")
end)
L.On("SHARD_TRANSFER", function()
	lastTransfer = { t = now(), what = "transfer" }
	log("transfer")
	reset("transfer")
end)

L.On("GROUP_JOINED", function()
	lastGroup = { t = now(), what = "joined" }
	log("joined")
	reset("joined")
	checkParty("joined")
end)
L.On("GROUP_LEFT", function()
	lastGroup = { t = now(), what = "left" }
	log("left")
	wipe(peers)
	checkParty("left")
end)
L.On("PARTY_LEADER_CHANGED", function()
	log("leader " .. (isLeader() and "you" or "other"))
end)
L.On("PARTY_INVITE_REQUEST", function(_, name)
	name = L.Value(name)
	lastGroup = { t = now(), what = "invite" }
	log("invite " .. (type(name) == "string" and name or "?"))
end)
L.On("GROUP_ROSTER_UPDATE", function()
	checkParty("roster")
	if current then send() end
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
end, "combat")

-- ---------------------------------------------------------------- load
-- AlcShardDB (the name before 0.1.0) is not read: it was never written in game, and the game only loads a saved
-- variables file for the addon of that name
L.OnLoad(function()
	if type(PortageDB) ~= "table" then PortageDB = {} end
	db = L.Fill(PortageDB, { version = 1, shown = true, chars = {} })
	char = charData()
	ns.db, ns.char = db, char
	local old = stamp() - KEEP.keyDays * 86400   -- keys unseen for two weeks: records of shards long gone
	for _, m in pairs(char.maps) do
		for key, rec in pairs(m.keys) do if (rec.last or 0) < old then m.keys[key] = nil end end
	end
	L.RestorePoint(frame, db.pos, DefaultPoint)
	L.Movable(frame, function(pos) db.pos = pos end)
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

SLASH_PORTAGE1 = "/portage"
SlashCmdList.PORTAGE = L.Slash({
	[""] = function() for _, line in ipairs(statusLines()) do P(line) end end,
	log = showLog,
	mark = function(arg)
		if arg == "" then P("/portage mark <text>: a note in the log, like \"crossed into Stonetalon\".") return end
		log("mark " .. arg)
		P("marked: " .. arg)
	end,
	hide = function() db.shown = false frame:Hide() P("the shard line is hidden (/portage show brings it back).") end,
	show = function() db.shown = true frame:Show() show() P("the shard line is shown.") end,
	ping = ping,
	channel = function(arg)
		if arg == "off" then
			db.channel = false
			if ns.channelID() then pcall(LeaveChannelByName, CHANNEL) end
			P("left the " .. CHANNEL .. " channel; /portage channel on joins it again.")
		elseif arg == "on" then
			db.channel = true
			joinChannel()
			P(ns.channelID() and ("in the " .. CHANNEL .. " channel.")
				or "could not join the channel (the channel list may be full).")
		else
			P(ns.channelID() and ("in the " .. CHANNEL .. " channel (/portage channel off leaves it).")
				or ("not in the " .. CHANNEL .. " channel (/portage channel on)."))
		end
	end,
}, "/portage: which shard you are on | /portage ping [name]: test which routes reach your friends | /portage log [n]:"
	.. " the last n log lines | /portage mark <text>: a note in the log | /portage hide | show: the shard line"
	.. " | /portage channel on | off", P)
