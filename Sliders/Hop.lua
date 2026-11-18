-- Sliders, the hop (0.3; docs/shards.md section 5): which shard your friends are on, who is open for invites, and one
-- click to move to another shard of your zone. A hop: an open host on that shard invites you, the server moves you to
-- the inviter's shard, you leave and stay (alcaras in game, 2026-11-09).
-- Level 1 (alcaras): every automatic step answers the user's own click on Hop, or a hop request to a host who opted in.
-- Defaults (alcaras): not open for invites, silent. Open modes: "solo" (only while alone) or "group" (also while
-- leading a party with room: never a raid, never in an instance or battleground, never while the party is listed or
-- queued, never off the party's shard). When someone asks: "ask" (a popup each time), "friends" (friends invited at
-- once, others asked), "anyone" (everyone invited at once). After a hop the guest stays in the host's group: leaving
-- undoes the move (alcaras 2026-11-09: "remove the leave the group option since it might just hop you back").
-- No spam (SPAM below): status only on a change, one message per route per 30 s (the public channel 60 s), hellos once
-- per session, nothing in combat or chat lockdown, a throttled send is dropped.
-- Messages (prefix Sliders, ";"-separated, version first):
--   HI2;<ver>;<uiMapID>;<shard>;<open>;<crowd>       hello at login, with my status; the answer is an ST2
--   ST2;<uiMapID>;<shard>;<open>;<crowd>;<ask>       my status; ask=1: "who else is in this zone?" (guild, channel)
--   HOP2;<to>;<req>;<uiMapID>;<shard>;<fullName>     please invite me to <shard> (to = the host)
--   OK2;<to>;<req>;<hostGUID>   NO2;<to>;<req>;<why>   DONE2;<to>;<req>;<shard>
local _, ns = ...
local L = ns.L
local A = ns.api
local P, say, log, now = A.P, A.say, A.log, A.now

local SPAM = {
	statusEvery = 30,    -- s between status messages on one route; a later change replaces the queued one
	channelEvery = 60,   -- the public channel: s between this player's messages
	askEvery = 120,      -- s between "who is here?" asks (guild, channel)
	answerDelay = 5,     -- answers to an ask wait 0-5 s; skipped when someone already answered for that shard
	fanout = 20,         -- direct status messages (Battle.net, whisper) per change
	hello = 50,          -- hellos per route kind per session
	reply = 10,          -- s between direct answers to one contact (a reload's hello must get its answer)
	hopEvery = 10,       -- s between Hop clicks
	perRequester = 120,  -- a host considers one request per requester per 2 min
	autoInvites = 5, autoWindow = 600,   -- an auto-inviting host: at most 5 invites per 10 min
	answerTimeout = 20, inviteTimeout = 60, moveTimeout = 120,
	askTimeout = 120,    -- a whispered Ask: a person has to read it and invite
	fresh = 1800,        -- a channel stranger's status older than 30 min is not shown
	guildFresh = 7200,   -- a guild member's: 2 h (their online state is not read here)
	tried = 120,         -- a host that did not work is skipped for 2 min
	party = 5,           -- a party's size; a host never invites past it (no raid conversion)
}
local VERSION = ns.VERSION   -- from the TOC (Sliders.lua)
local RANK = { BN = 4, WHISPER = 3, GUILD = 2, CHANNEL = 1 }
local ROUTE_NAME = { BN = "Battle.net", WHISPER = "whisper", GUILD = "guild", CHANNEL = "channel" }

-- AlcPrices' palette (addons/AlcPrices/UI.lua, S): the in-game look of the own windows
local C = {
	bg = { 0.04, 0.04, 0.05, 0.94 }, line = { 0.25, 0.25, 0.28, 1 }, divider = { 1, 1, 1, 0.08 },
	row = { 1, 1, 1, 0.03 }, rowYou = { 0.40, 0.85, 0.40, 0.07 },
	gold = { 0.93, 0.80, 0.50 }, action = { 0.55, 0.80, 1.00 }, muted = { 0.60, 0.60, 0.60 }, ink = { 0.90, 0.90, 0.90 },
	white = { 1, 1, 1 }, green = { 0.40, 0.85, 0.40 }, warn = { 1.00, 0.60, 0.20 },
}

local char
local contacts = {}           -- normalized full name -> contact
ns.contacts = contacts
local hop                     -- the guest's running hop
local lastHop = -100
local tried = {}              -- contact key -> now() of a failed hop
local lastSent, queued, deferred = {}, {}, {}
local lastAsk, lastMap = {}, {}
local answering = {}          -- route kind -> { shard, open, cancelled }
local asked = {}              -- host side: requester key -> now()
local autoLog = {}            -- host side: now() of each automatic invite
local hosting                 -- host side: { req, guest, t } while a guest is invited
local helloSent = false
local helloAt                 -- when the hello goes out: the tooltip says "asking" until its answers can be in
local openFlag                -- the open flag last advertised
local advertised = {}         -- the shard and map last advertised
local movePending             -- Blizzard scheduled a shard move for us (SHARD_TRANSFER_IMMINENT): not a host until it
                              -- happens or is cancelled, or a guest could land on a shard we are about to leave

-- ---------------------------------------------------------------- names (Sliders.lua)
local realm, norm, first, ownFull = A.realm, A.norm, A.first, A.ownFull
local function ownKey() return norm(ownFull()) end

-- online character friends, by key (a whisper contact counts as a friend only if it is on the friends list)
local function friendKeys()
	local set = {}
	for _, name in ipairs(A.charFriends()) do set[norm(name)] = true end
	return set
end

-- a contact we can reach right now: Battle.net and whisper contacts must be online; guild and channel are broadcasts
local function online(c, friends)
	if c.route == "BN" then
		local info = C_BattleNet and L.Read(C_BattleNet.GetGameAccountInfoByID, c.target)
		return type(info) == "table" and L.Value(info.isOnline) == true
	end
	if c.route == "WHISPER" then return (friends or friendKeys())[c.key] == true end
	return true
end

-- a status is sent only on a change, so it holds until the next one: a Battle.net or character friend's shows while
-- they are online (alcaras: friends vanished from the tooltip after 30 min in one zone); a guild member's for 2 h; a
-- channel stranger's for 30 min
local function current(c, friends)
	local st = c.st
	if not st then return false end
	if c.route == "BN" or c.route == "WHISPER" then return online(c, friends) end
	return now() - st.t < (c.route == "GUILD" and SPAM.guildFresh or SPAM.fresh)
end

-- ---------------------------------------------------------------- open for invites
local function inRaid() return L.Read(IsInRaid) == true end

-- the party is listed in the group finder or queued together for a battleground: a roster change would cost that
local function partyQueued()
	if C_LFGList and C_LFGList.HasActiveEntryInfo and L.Read(C_LFGList.HasActiveEntryInfo) == true then return true end
	local n = L.Num(L.Read(GetMaxBattlefieldID)) or 0
	for i = 1, math.min(n, 5) do
		if L.Value(L.Read(GetBattlefieldStatus, i)) == "queued" then return true end
	end
	return false
end

-- why this character is not open right now, or nil
local function closedWhy(kind)
	if not char or char.open == "off" then return "closed" end
	if A.instanced() or A.paused() then return "busy" end
	if L.Read(UnitIsAFK, "player") == true then return "busy" end
	if movePending then return "busy" end
	if A.inGroup() and not hosting then
		if char.open ~= "group" then return "full" end
		if inRaid() or not A.isLeader() or A.groupSize() >= SPAM.party then return "full" end
		if partyQueued() then return "busy" end
		if L.Read(UnitInPartyShard, "player") == false then return "busy" end
	end
	return nil
end
local function isOpen(kind) return closedWhy(kind) == nil end

local function statusFields(kind)
	return ("%d;%s;%d;%d"):format(A.mapID() or 0, A.current() or "-", isOpen(kind) and 1 or 0, ns.crowd())
end
-- ST2;<map>;<shard>;<open>;<crowd>;<ask>;<version> (0.3.0-0.3.3 read the first five fields and ignore the version)
-- our class file ("ROGUE"): friends colour our name by it (alcaras: "color code people by class")
local function myClass()
	local _, file = UnitClass("player")
	file = L.Value(file)
	return type(file) == "string" and file or ""
end
-- ST2;<map>;<shard>;<open>;<crowd>;<ask>;<version>;<class> (older versions read what they know and ignore the rest)
local function st2(kind, ask)
	return ("ST2;%s;%d;%s;%s"):format(statusFields(kind), ask and 1 or 0, VERSION, myClass())
end
-- HI2;<version>;<map>;<shard>;<open>;<crowd>;<class>
local function hi2(kind) return ("HI2;%s;%s;%s"):format(VERSION, statusFields(kind), myClass()) end

-- ---------------------------------------------------------------- sending
local function blocked() return L.InCombat() or A.lockdown() end

local function sendTo(c, msg)
	if c.route == "BN" then return ns.sendRoute("BN", msg, c.target) end
	if c.route == "WHISPER" then return ns.sendRoute("WHISPER", msg, c.target) end
	if c.route == "GUILD" then return ns.sendRoute("GUILD", msg) end
	local ch = ns.channelID()
	return ch and ns.sendRoute("CHANNEL", msg, tostring(ch)) or "not joined"
end

local function hasGuildContact()
	for _, c in pairs(contacts) do if c.guild then return true end end
	return false
end

-- one route kind ("direct", "GUILD", "CHANNEL"): the current status, now
local function sendKind(kind, ask)
	if blocked() then deferred[kind] = true return end
	lastSent[kind] = now()
	if kind == "direct" then
		local n = 0
		local msg = st2("direct")
		local friends = friendKeys()
		for _, c in pairs(contacts) do
			-- friends only (a stranger who whispered once gets no pushes), and only while they are online
			if (c.route == "BN" or c.route == "WHISPER") and c.friend and n < SPAM.fanout and online(c, friends) then
				n = n + 1
				sendTo(c, msg)
			end
		end
	elseif kind == "GUILD" then
		if L.Read(IsInGuild) == true and hasGuildContact() then
			ns.sendRoute("GUILD", st2("GUILD", ask))
		end
	elseif kind == "CHANNEL" then
		local ch = ns.channelID()
		if ch then ns.sendRoute("CHANNEL", st2("CHANNEL", ask), tostring(ch)) end
	end
end

local function every(kind) return kind == "CHANNEL" and SPAM.channelEvery or SPAM.statusEvery end

-- the status on one route kind, as soon as the limits allow; a change while one waits rides along with it
local function schedule(kind)
	local wait = every(kind) - (now() - (lastSent[kind] or -1e9))
	if wait <= 0 then
		local map, ask = A.mapID(), false
		if kind ~= "direct" and map and lastMap[kind] ~= map and now() - (lastAsk[kind] or -1e9) >= SPAM.askEvery then
			ask = true   -- a new zone: "who else is here?"
			lastAsk[kind], lastMap[kind] = now(), map
		end
		sendKind(kind, ask)
		return
	end
	if queued[kind] then return end
	queued[kind] = true
	L.After(wait, function()
		queued[kind] = false
		schedule(kind)
	end, "status")
end

local function pushStatus()
	if not char or not A.current() then return end
	schedule("direct")
	schedule("GUILD")
	schedule("CHANNEL")
end

local function refreshOpen()
	local o = isOpen("direct")
	if o ~= openFlag then
		openFlag = o
		pushStatus()
	end
	if ns.RefreshPanel then ns.RefreshPanel() end
end

-- ---------------------------------------------------------------- contacts
-- from a message: who sent it, by which route; the best route to them is kept (Battle.net > whisper > guild > channel)
local function contactFrom(channel, sender, bnID)
	local full, route, target, bnClass
	if bnID then
		local info = C_BattleNet and L.Read(C_BattleNet.GetGameAccountInfoByID, bnID)
		local name = type(info) == "table" and L.Value(info.characterName)
		if type(name) ~= "string" or name == "" then return nil end
		local r = type(info) == "table" and L.Value(info.realmName)
		full = name .. "-" .. (type(r) == "string" and r ~= "" and r or realm())
		route, target = "BN", bnID
		local cls = type(info) == "table" and L.Value(info.classFilename)
		bnClass = type(cls) == "string" and cls ~= "" and cls or nil
	else
		if type(sender) ~= "string" then return nil end
		full = sender
		if channel == "WHISPER" then route, target = "WHISPER", sender
		elseif channel == "GUILD" then route = "GUILD"
		elseif channel == "CHANNEL" then route = "CHANNEL"
		else return nil end   -- party: the 0.2 S1 exchange covers it
	end
	local key = norm(full)
	if not key or key == ownKey() then return nil end
	local c = contacts[key]
	if not c then
		-- the same character by another route (Battle.net spells the realm its own way): one contact, the best route
		local id = A.ident(full)
		for _, o in pairs(contacts) do if id and A.ident(o.full) == id then c = o break end end
	end
	if not c then
		c = { key = key, name = A.shortName(full), full = full, route = route, target = target }
		contacts[key] = c
	elseif RANK[route] > RANK[c.route] then
		c.route, c.target = route, target
	end
	if route == "GUILD" then c.guild = true end
	if bnClass then c.class = bnClass end
	-- Battle.net friends, guild members and character friends are friends (shown by name, auto-invited); a whisper from
	-- anyone else is a stranger, like the channel
	if route == "BN" or route == "GUILD" or (route == "WHISPER" and friendKeys()[key]) then c.friend = true end
	return c, route
end

-- friends remembered across a reload (SlidersDB.contacts, a day): a status holds until the next one, and a reload
-- would otherwise show nobody until the hello's answers come in (alcaras: "i reloaded and i don't see them")
local KEEP_CONTACTS = 86400
local function remember(c)
	local db = ns.db
	if not db or not c.st then return end
	db.contacts = db.contacts or {}
	db.contacts[c.key] = { name = c.name, full = c.full, route = c.route, friend = c.friend, guild = c.guild,
		version = c.version, class = c.class, map = c.st.map, shard = c.st.shard, open = c.st.open, crowd = c.st.crowd,
		at = A.stamp() }
end

-- back from SlidersDB.contacts: Battle.net friends by their character name in today's friends list (game account ids
-- change between sessions), the others as they were; whether they show still depends on being online
function ns.restoreContacts()
	local db = ns.db
	if not db or type(db.contacts) ~= "table" then return end
	local ids = {}
	-- by the whole name, and by the first name for records saved before 0.3.9 (they kept only "Crow")
	for _, f in ipairs(A.bnFriends()) do ids[A.shortName(f.name):lower()] = f.id ids[first(f.name):lower()] = f.id end
	local t = A.stamp()
	for key, r in pairs(db.contacts) do
		if type(r) ~= "table" or t - (r.at or 0) > KEEP_CONTACTS then
			db.contacts[key] = nil
		elseif not contacts[key] then
			local target = r.route == "WHISPER" and r.full or nil
			if r.route == "BN" then target = ids[(r.name or ""):lower()] end
			if r.route ~= "BN" or target then
				contacts[key] = { key = key, name = r.full and A.shortName(r.full) or r.name, full = r.full, route = r.route, target = target, friend = r.friend,
					guild = r.guild, version = r.version, class = r.class, restored = true,
					st = { map = r.map, shard = r.shard, open = r.open, crowd = r.crowd, t = now() - (t - (r.at or t)) } }
			end
		end
	end
end

local function setStatus(c, route, map, shard, open, crowd, version, class)
	if type(version) == "string" and version:match("^%d+%.%d+") then c.version = version end
	if type(class) == "string" and class:match("^%u+$") then c.class = class end
	local s = A.shardOf(shard)
	local old = c.st
	c.st = { map = tonumber(map), shard = s, open = open == "1", crowd = tonumber(crowd), t = now() }
	c.restored = nil
	remember(c)
	if not old or old.shard ~= s or old.map ~= c.st.map or old.open ~= c.st.open then
		log(("status %s by %s: %s map %s%s"):format(c.name, ROUTE_NAME[route] or route, s or "-", tostring(map),
			c.st.open and " open" or ""))
	end
	if ns.RefreshPanel then ns.RefreshPanel() end
end

-- answer a hello or an ask: directly to a contact, or once on a broadcast route unless someone answered for us
local function answer(c, route, map)
	if not A.current() then
		if route == "BN" or route == "WHISPER" then c.owesReply = true end   -- answered once our shard is known
		return
	end
	if route == "BN" or route == "WHISPER" then
		if now() - (c.replied or -1e9) < SPAM.reply or blocked() then return end
		c.replied = now()
		sendTo(c, st2("direct"))
		return
	end
	if tonumber(map) ~= A.mapID() or answering[route] then return end
	local mine = { shard = A.current(), open = isOpen(route) }
	answering[route] = mine
	L.After(math.random() * SPAM.answerDelay, function()
		answering[route] = nil
		if mine.cancelled or now() - (lastSent[route] or -1e9) < every(route) or blocked() then return end
		lastSent[route] = now()
		local msg = st2(route)
		if route == "GUILD" then ns.sendRoute("GUILD", msg)
		else local ch = ns.channelID() if ch then ns.sendRoute("CHANNEL", msg, tostring(ch)) end end
	end, "answer")
end

-- ---------------------------------------------------------------- quiet: the hop's own group lines
-- The hop's messages are addon messages (nobody sees them); the game's own system lines are not: "Bnpal joins the
-- party.", "You leave the group.", "Your group has been disbanded." ... alcaras: "the invites / joining leaving will
-- be annoying enough". While a hop runs (guest, host, and the host's party members told over PARTY with QT2), those
-- lines are filtered out of chat: the ones that name the hop's partner, and the nameless group lines, for the hop's
-- few seconds only. Everything else in chat is untouched.
local QUIET_NAMED = { "ERR_JOINED_GROUP_S", "ERR_LEFT_GROUP_S", "ERR_INVITE_PLAYER_S", "ERR_NEW_LEADER_S",
	"ERR_DECLINE_GROUP_S", "ERR_PARTY_CONVERTED_TO_RAID_S" }
local QUIET_PLAIN = { "ERR_LEFT_GROUP_YOU", "ERR_GROUP_DISBANDED", "JOINED_PARTY", "ERR_NEW_LEADER_YOU",
	"ERR_DUNGEON_DIFFICULTY_CHANGED_S", "ERR_RAID_DIFFICULTY_CHANGED_S", "ERR_LEGACY_RAID_DIFFICULTY_CHANGED_S" }
local QUIET_FOR = 90          -- s a window stays open at most
local quietNames, quietUntil = {}, 0
local patterns                -- built on first use, from the client's GlobalStrings

-- colour codes and links out, brackets out: "|Hplayer:Bnpal|h[Bnpal]|h joins the party." -> "Bnpal joins the party."
local function plainText(s)
	s = s:gsub("|c%x%x%x%x%x%x%x%x", ""):gsub("|r", ""):gsub("|H.-|h(.-)|h", "%1"):gsub("[%[%]]", "")
	return s
end

-- a GlobalStrings format -> a Lua pattern: "%s joins the party." -> "^(.+) joins the party%.$" ("%1$s" too)
local function toPattern(fmt)
	local p = plainText(fmt):gsub("%%%d%$([sd])", "%%%1")
	p = p:gsub("([%(%)%.%+%-%*%?%[%]%^%$])", "%%%1")
	p = p:gsub("%%s", "(.+)"):gsub("%%d", "%%d+")
	return "^" .. p .. "$"
end

local function buildPatterns()
	patterns = { named = {}, plain = {} }
	for kind, list in pairs({ named = QUIET_NAMED, plain = QUIET_PLAIN }) do
		for _, key in ipairs(list) do
			local fmt = _G[key]
			if type(fmt) == "string" and fmt ~= "" then patterns[kind][#patterns[kind] + 1] = toPattern(fmt) end
		end
	end
end

-- open (or extend) the window for these first names
local function quiet(...)
	for i = 1, select("#", ...) do
		local n = select(i, ...)
		if type(n) == "string" then quietNames[first(n):lower()] = true end
	end
	quietUntil = now() + QUIET_FOR
end
local function quietEnd(after)
	quietUntil = math.min(quietUntil, now() + (after or 10))
end

function ns.quietFilter(_, _, msg)
	if now() > quietUntil then
		if next(quietNames) then wipe(quietNames) end
		return false
	end
	msg = L.Value(msg)
	if type(msg) ~= "string" then return false end
	if not patterns then buildPatterns() end
	msg = plainText(msg)
	for _, p in ipairs(patterns.plain) do if msg:match(p) then return true end end
	for _, p in ipairs(patterns.named) do
		local who = msg:match(p)
		if who and quietNames[first(who):lower()] then return true end
	end
	return false
end

do
	local add = ChatFrameUtil and ChatFrameUtil.AddMessageEventFilter
	if type(add) == "function" then pcall(add, "CHAT_MSG_SYSTEM", ns.quietFilter) end
end

-- ---------------------------------------------------------------- versions
-- "0.3.10" > "0.3.4": numbers compared part by part
local function newer(a, b)
	local pa, pb = {}, {}
	for n in tostring(a):gmatch("%d+") do pa[#pa + 1] = tonumber(n) end
	for n in tostring(b):gmatch("%d+") do pb[#pb + 1] = tonumber(n) end
	for i = 1, math.max(#pa, #pb) do
		local x, y = pa[i] or 0, pb[i] or 0
		if x ~= y then return x > y end
	end
	return false
end
ns.newerVersion = newer

-- the highest version a friend runs, when it is newer than ours
function ns.newestFriendVersion()
	local best
	for _, c in pairs(contacts) do
		if c.version and newer(c.version, best or VERSION) then best = c.version end
	end
	return best
end

-- one entry per character name heard from in the last 30 min (a friend heard by Battle.net and by guild is one
-- person), the freshest status kept; friendsOnly: Battle.net, character friends and guild
local function people(friendsOnly)
	local byName = {}
	local friends = friendKeys()
	for _, c in pairs(contacts) do
		local st = c.st
		if st and current(c, friends) and (c.friend or not friendsOnly) then
			local k = c.name:lower()
			local old = byName[k]
			if not old or st.t > old.st.t or (c.friend and not old.friend) then byName[k] = c end
		end
	end
	return byName
end

-- a name in its class colour (RAID_CLASS_COLORS), white when the class is not known
function ns.classColored(name, class)
	local c = class and RAID_CLASS_COLORS and RAID_CLASS_COLORS[class]
	local hex = c and (c.colorStr or (c.r and ("ff%02x%02x%02x"):format(c.r * 255, c.g * 255, c.b * 255)))
	return hex and ("|c%s%s|r"):format(hex, name) or name
end

-- the hello's answers are still on their way (the first 30 s after loading)
function ns.asking() return helloAt ~= nil and now() < helloAt + 15 end

-- the tooltip's friends: your shard first, then your zone, then the rest; each with where they are
function ns.friendRows()
	local cur, map = A.current(), A.mapID()
	local rows = {}
	for _, c in pairs(people(true)) do
		local st = c.st
		rows[#rows + 1] = { name = c.name, class = c.class, where = st.shard and A.label(st.shard, st.map) or "no shard yet",
			same = st.shard ~= nil and st.shard == cur and st.map == map, here = st.map == map, open = st.open,
			old = c.version == nil or newer(VERSION, c.version) }
	end
	table.sort(rows, function(a, b)
		if a.same ~= b.same then return a.same end
		if a.here ~= b.here then return a.here end
		return a.name < b.name
	end)
	return rows
end

-- /sliders: one line per Sliders user heard from in the last 30 min (version, route, shard)
function ns.contactLines()
	local out = {}
	for _, c in pairs(people(false)) do
		local st = c.st
		out[#out + 1] = ("%s: %s%s (Sliders %s, by %s%s)."):format(c.name, st.shard and A.label(st.shard, st.map) or "no shard yet",
			st.open and ", open for invites" or "", c.version or "0.3.0-0.3.3", ROUTE_NAME[c.route],
			c.friend and "" or ", not a friend")
	end
	table.sort(out)
	return out
end

-- ---------------------------------------------------------------- the guest's hop
local refreshButton

local function endHop(text, ok, stay)
	if not hop then return end
	local h = hop
	hop = nil
	lastHop = now()
	quietEnd(10)
	if refreshButton then refreshButton:Hide() end
	if not ok then tried[h.host.key] = now() end
	if not stay and (h.phase == "joined" or h.phase == "accepting" or h.phase == "moved") and A.inGroup() then
		pcall(C_PartyInfo.LeaveParty)   -- the hop's own group (a failed hop, or "after the move: leave")
	end
	log(("hop_%s %s host %s: %s; ask->invite %s, invite->move %s, countdown %s, transfer %s"):format(
		ok and "done" or "failed", h.req, h.host.name, text, h.tInvite and (math.floor(h.tInvite - h.t) .. "s") or "-",
		(h.tInvite and h.tMove) and (math.floor(h.tMove - h.tInvite) .. "s") or "-", h.countdown or "no",
		h.transfer and "yes" or "no"))
	P(text)
	ns.lastResult = { text = text, ok = ok, t = now() }
	if ns.RefreshPanel then ns.RefreshPanel() end
end

local function pickHost(shard, map)
	local best
	local friends = friendKeys()
	for _, c in pairs(contacts) do
		local st = c.st
		if st and st.open and st.shard == shard and st.map == map and current(c, friends)
			and now() - (tried[c.key] or -1e9) > SPAM.tried then
			if not best or RANK[c.route] > RANK[best.route] or (RANK[c.route] == RANK[best.route] and st.t > best.st.t) then
				best = c
			end
		end
	end
	return best
end

function ns.Hop(shard)
	if not char then return end
	local map, cur = A.mapID(), A.current()
	local why
	if hop then why = "a hop is already running."
	elseif now() - lastHop < SPAM.hopEvery then why = "one hop per 10 seconds."
	elseif A.inGroup() then why = "leave your group first: a hop works by invite."
	elseif L.InCombat() then why = "not in combat."
	elseif A.instanced() or A.paused() then why = "not here: shards are read in the open world only."
	elseif not cur then why = "Sliders does not know your shard yet: look at an NPC or two."
	elseif shard == cur then why = "you are already on " .. A.label(shard) .. "."
	end
	if why then P(why) return end
	local host = pickHost(shard, map)
	if not host then P(("nobody open for invites is on %s right now."):format(A.label(shard))) return end
	local req = ("%d%03d"):format(A.stamp() % 100000, math.random(0, 999))
	hop = { req = req, host = host, shard = shard, from = cur, map = map, t = now(), phase = "asked" }
	quiet(host.name)
	local r = sendTo(host, ("HOP2;%s;%s;%d;%s;%s"):format(host.key, req, map, shard, ownFull()))
	log(("hop_ask %s host %s by %s shard %s from %s: %s"):format(req, host.name, ROUTE_NAME[host.route], shard, cur, r))
	if r ~= "ok" then endHop(("could not reach %s (%s)."):format(host.name, r), false) return end
	P(("asking %s to invite you to %s."):format(host.name, A.label(shard)))
	if ns.RefreshPanel then ns.RefreshPanel() end
	L.After(SPAM.answerTimeout, function()
		if hop and hop.req == req and hop.phase == "asked" then endHop(("no answer from %s."):format(host.name), false) end
	end, "hop")
end

-- ---------------------------------------------------------------- people in your zone (with or without Sliders)
-- Early on few friends run Sliders (alcaras, 2026-11-14: "make it easy to see if anyone in your guild or friends is in
-- the same zone and make it easy to ask them to invite you"). Battle.net friends (areaName), character friends (area)
-- and the guild (Communities: C_Club member info's zone) online in your zone, one entry per character; their shard
-- when they run Sliders, else unknown. Read when the panel draws, at most every 5 s.
local ASK_TEXT = "Hi! Could you invite me to your group for a moment? I'd like to hop onto your shard."
local mates, matesAt = nil, -100
local classByName                -- localized class name -> class file (character friends give the localized name)

local function classFromLocalized(name)
	if not classByName then
		classByName = {}
		for _, t in ipairs({ LOCALIZED_CLASS_NAMES_MALE or {}, LOCALIZED_CLASS_NAMES_FEMALE or {} }) do
			for file, loc in pairs(t) do if type(loc) == "string" then classByName[loc] = file end end
		end
	end
	return name and classByName[name] or nil
end

local function classFromID(id)
	local info = id and C_CreatureInfo and L.Read(C_CreatureInfo.GetClassInfo, id)
	local file = type(info) == "table" and L.Value(info.classFile)
	return type(file) == "string" and file or nil
end

local function zoneNames()
	local here = {}
	local a = A.mapName(A.mapID())
	if type(a) == "string" then here[a:lower()] = true end
	local b = L.Value(L.Read(GetZoneText))
	if type(b) == "string" and b ~= "" then here[b:lower()] = true end
	return here
end

function ns.ZoneMates(force)
	if mates and not force and now() - matesAt < 5 then return mates end
	local here, me, out, seen = zoneNames(), ownKey(), {}, {}
	-- us by our whole name (UnitName gives the first name and the surname apart; the lists give "First Surname")
	local _, myFirst, mySur = pcall(UnitName, "player")
	myFirst, mySur = L.Value(myFirst), L.Value(mySur)
	local myId = type(myFirst) == "string" and A.ident(myFirst .. (type(mySur) == "string" and mySur ~= "" and (" " .. mySur) or "")
		.. "-" .. realm()) or A.ident(A.ownFull())
	local byId = {}   -- contacts by identity: Battle.net and the guild name one character with different realms
	for _, c in pairs(contacts) do local id = A.ident(c.full) if id then byId[id] = byId[id] or c end end
	local function inZone(z) z = L.Value(z) return type(z) == "string" and here[z:lower()] == true end
	local function add(p)
		local key, id = norm(p.full), A.ident(p.full)
		if not key or key == me or id == myId then return end
		-- one row per character: a Battle.net friend who is also in the guild is "BN · guild"
		local had = seen[id]
		if had then
			had.sources[#had.sources + 1] = p.source
			had.class = had.class or p.class
			return
		end
		seen[id] = p
		p.key, p.name, p.sources = key, A.shortName(p.full), { p.source }
		local c = contacts[key] or byId[id]
		if c and c.st and current(c) and c.st.map == A.mapID() then
			p.sliders, p.shard, p.open, p.class, p.version = true, c.st.shard, c.st.open, p.class or c.class, c.version
		end
		out[#out + 1] = p
	end
	-- Battle.net friends playing Forever
	local same = FriendsListUtil and FriendsListUtil.IsPlayingSameWoWProject
	for i = 1, math.min(L.Num(L.Read(BNGetNumFriends)) or 0, 200) do
		local acc = C_BattleNet and L.Read(C_BattleNet.GetFriendAccountInfo, i)
		local g = type(acc) == "table" and acc.gameAccountInfo
		if type(g) == "table" and L.Value(g.isOnline) == true and (not same or L.Read(same, g) == true) and inZone(g.areaName) then
			local name, r = L.Value(g.characterName), L.Value(g.realmName)
			if type(name) == "string" and name ~= "" then
				add({ full = name .. "-" .. (type(r) == "string" and r ~= "" and r or realm()), source = "Battle.net friend",
					class = L.Value(g.classFilename), bnet = L.Num(acc.bnetAccountID) })
			end
		end
	end
	-- character friends
	for i = 1, math.min(C_FriendList and L.Num(L.Read(C_FriendList.GetNumFriends)) or 0, 100) do
		local f = L.Read(C_FriendList.GetFriendInfoByIndex, i)
		local name = type(f) == "table" and L.Value(f.name)
		if type(name) == "string" and L.Value(f.connected) == true and inZone(f.area) then
			add({ full = name, source = "friend", class = classFromLocalized(L.Value(f.className)) })
		end
	end
	-- the guild (Communities)
	local club = C_Club and L.Read(C_Club.GetGuildClubId)
	if club then
		local members = L.Read(C_Club.GetClubMembers, club)
		local P_ = Enum and Enum.ClubMemberPresence or {}
		local offline = { [P_.Offline or 3] = true, [P_.OnlineMobile or 2] = true, [P_.Unknown or 0] = true }
		for i, id in ipairs(type(members) == "table" and members or {}) do
			if i > 1000 then break end
			local info = L.Read(C_Club.GetMemberInfo, club, id)
			if type(info) == "table" and L.Value(info.isSelf) ~= true and not offline[L.Num(info.presence) or 0]
				and inZone(info.zone) then
				local name = L.Value(info.name)
				if type(name) == "string" and name ~= "" then
					add({ full = name, source = "guild", class = classFromID(L.Num(info.classID)) })
				end
			end
		end
	end
	table.sort(out, function(a, b)
		if (a.open or false) ~= (b.open or false) then return a.open == true end
		if (a.sliders or false) ~= (b.sliders or false) then return a.sliders == true end
		return a.name < b.name
	end)
	mates, matesAt = out, now()
	return out
end
function ns.ForgetZoneMates() mates = nil end

-- the whisper an Ask sends: plain, from the user's own click; /sliders asktext changes it
function ns.AskText()
	local db = ns.db
	-- no mention of Sliders (alcaras: "no sliders adv")
	return db and type(db.askText) == "string" and db.askText ~= "" and db.askText or ASK_TEXT
end

local askedAt = {}   -- person key -> now() of the last Ask
-- one click: whisper a friend or guild member in your zone (no Sliders needed on their side) to invite you; their
-- invite is accepted (only theirs, within 2 min), the server moves you, you stay in their group
function ns.Ask(p)
	if not char or type(p) ~= "table" then return end
	local why
	if hop then why = "a hop is already running."
	elseif now() - lastHop < SPAM.hopEvery then why = "one hop per 10 seconds."
	elseif now() - (askedAt[p.key] or -1e9) < SPAM.perRequester then why = ("you asked %s a moment ago."):format(p.name)
	elseif A.inGroup() then why = "leave your group first: a hop works by invite."
	elseif L.InCombat() then why = "not in combat."
	elseif A.instanced() or A.paused() then why = "not here: shards are read in the open world only."
	elseif A.lockdown() then why = "chat is locked right now (a boss fight or a rated match)."
	elseif p.shard and p.shard == A.current() then why = ("%s is on your shard already."):format(p.name)
	end
	if why then P(why) return end
	local text = ns.AskText()
	local ok
	if p.bnet and C_BattleNet and C_BattleNet.SendWhisper then
		ok = pcall(C_BattleNet.SendWhisper, p.bnet, text)
	elseif C_ChatInfo and C_ChatInfo.SendChatMessage then
		ok = pcall(C_ChatInfo.SendChatMessage, text, "WHISPER", nil, p.full)
	end
	log(("ask_sent %s (%s, %s): %s"):format(p.name, p.source or "?", p.sliders and "Sliders" or "no Sliders",
		ok and "ok" or "failed"))
	if not ok then P(("could not whisper %s."):format(p.name)) return end
	askedAt[p.key] = now()
	local req = "ask" .. ("%d"):format(A.stamp() % 100000)
	hop = { req = req, host = { key = p.key, name = p.name, full = p.full, route = "ASK", noSliders = true },
		shard = p.shard, from = A.current(), map = A.mapID(), t = now(), phase = "invited", ask = true }
	quiet(p.name)
	P(("asked %s to invite you; Sliders accepts their invite."):format(p.name))
	if ns.RefreshPanel then ns.RefreshPanel() end
	local h = hop
	L.After(SPAM.askTimeout, function()
		if hop == h and h.phase == "invited" then endHop(("no invite from %s."):format(p.name), false) end
	end, "hop")
end

local WHY = { closed = "is not open for invites", busy = "is busy", moved = "is not on that shard any more",
	full = "has no room in the group", declined = "said no", combat = "is in combat" }

local function onHostAnswer(v, req, a)
	if not hop or hop.req ~= req then return end
	if v == "NO2" then
		log(("hop_no %s %s: %s"):format(req, hop.host.name, tostring(a)))
		endHop(("%s %s."):format(hop.host.name, WHY[a] or "can't host now"), false)
		return
	end
	log(("hop_ok %s %s"):format(req, hop.host.name))
	if hop.phase == "asked" then hop.phase = "invited" end
	hop.hostGUID = a
	local h = hop
	L.After(SPAM.inviteTimeout, function()
		if hop == h and hop.phase == "invited" then endHop(("no invite from %s."):format(h.host.name), false) end
	end, "hop")
end

-- the same character in two spellings (with or without the realm, Battle.net's realm, a first name alone)
local function sameChar(a, b)
	if type(a) ~= "string" or type(b) ~= "string" then return false end
	local ia, ib = A.ident(a), A.ident(b)
	return (ia ~= nil and ia == ib) or first(a):lower() == first(b):lower()
end

-- An Ask to someone in a group who does not lead it: their invite becomes a suggestion to the leader, the game says so
-- ("Val Aran suggested that Stevie Bones invite you to their group.", ERR_INFORM_SUGGEST_INVITE_SS; the leader
-- unnamed: ERR_INFORM_SUGGEST_INVITE_S), and the leader's invite follows (alcaras, Un'Goro 2026-11-16: Sliders kept
-- waiting for Val Aran's own invite). PARTY_INVITE_REQUEST has no suggest flag, so the system line names the leader.
local suggestPatterns
function ns.onSystemMessage(msg)
	if not (hop and hop.ask and hop.phase == "invited") then return end
	msg = L.Value(msg)
	if type(msg) ~= "string" then return end
	if not suggestPatterns then
		-- from the client's own strings (any locale); "%1$s ... %2$s" may come in the other order in a translation, so
		-- each capture is put back at its argument's place
		suggestPatterns = {}
		for _, k in ipairs({ "ERR_INFORM_SUGGEST_INVITE_SS", "ERR_INFORM_SUGGEST_INVITE_S" }) do
			local fmt = _G[k]
			if type(fmt) == "string" and fmt ~= "" then
				local order, n = {}, 0
				for spec in plainText(fmt):gmatch("%%(%d*)%$?s") do
					n = n + 1
					order[n] = tonumber(spec) or n
				end
				suggestPatterns[#suggestPatterns + 1] = { pattern = toPattern(fmt), order = order }
			end
		end
	end
	msg = plainText(msg)
	for _, sp in ipairs(suggestPatterns) do
		local caps, args = { msg:match(sp.pattern) }, {}
		for i, v in ipairs(caps) do args[sp.order[i] or i] = v end
		local who, leader = args[1], args[2]
		if who and sameChar(who, hop.host.full) then
			hop.leader = leader and A.shortName(leader) or true   -- true: their leader, unnamed
			if ns.RefreshPanel then ns.RefreshPanel() end
			log(("ask_suggested %s: %s asked %s"):format(hop.req, hop.host.name, tostring(leader or "their leader")))
			return
		end
	end
end
L.On("CHAT_MSG_SYSTEM", function(_, msg) ns.onSystemMessage(msg) end, "suggest")

-- an Ask's invite from someone other than the asked person: their group's leader (named by the suggest line); with
-- the leader unnamed, a friend or guildmate in this zone not known to be elsewhere; without a suggest line, a friend or
-- guildmate known (Sliders) to be on the shard asked for. Anyone else's invite stays with Blizzard's popup, and a join
-- by hand still ends the wait (ns.hooks.joined).
local function askInviter(name)
	if not hop.ask or type(name) ~= "string" then return false end
	if type(hop.leader) == "string" then return sameChar(name, hop.leader) end
	for _, p in ipairs(ns.ZoneMates(true)) do
		if sameChar(name, p.full) then
			if hop.leader == true then return p.shard == nil or hop.shard == nil or p.shard == hop.shard end
			return p.shard ~= nil and p.shard == hop.shard
		end
	end
	return false
end

ns.hooks.invite = function(name, inviterGUID)
	if not hop or (hop.phase ~= "asked" and hop.phase ~= "invited") then return end
	local match
	if hop.hostGUID and hop.hostGUID ~= "" then match = inviterGUID == hop.hostGUID
	else match = norm(name) == hop.host.key or (A.ident(name) ~= nil and A.ident(name) == A.ident(hop.host.full)) end
	if not match and askInviter(name) then
		match = true
		hop.inviter = A.shortName(name)
	end
	if type(name) == "string" then hop.seenInvite = A.shortName(name) end
	if not match then return end   -- any other invite stays with Blizzard's popup
	hop.phase, hop.tInvite = "accepting", now()
	local h = hop
	L.After(SPAM.inviteTimeout, function()   -- never joined (declined, expired, Accept not clicked): the hop ends
		if hop == h and h.phase == "accepting" then endHop(("the invite from %s was not accepted."):format(h.host.name), false) end
	end, "hop")
	-- AcceptGroup has no flag in Forever's index (an undocumented global); retail addons call it on an invite. If the
	-- game blocks it (ADDON_ACTION_BLOCKED below), Blizzard's popup is still up: the user clicks Accept, and this
	-- character stops trying (char.manualAccept)
	if char.manualAccept then
		log(("hop_invite %s from %s: waiting for Accept"):format(hop.req, tostring(name)))
		P(("%s invited you: click Accept on the invite."):format(hop.inviter or hop.host.name))
		return
	end
	log(("hop_accept %s from %s"):format(hop.req, tostring(name)))
	pcall(AcceptGroup)
end

L.On("ADDON_ACTION_BLOCKED", function(_, who, func)
	who, func = L.Value(who), L.Value(func)
	if who ~= "Sliders" or type(func) ~= "string" or not func:find("AcceptGroup", 1, true) then return end
	if char then char.manualAccept = true end
	log("accept_blocked: the game does not let Sliders accept; Accept is clicked by hand from now on")
	if hop and hop.phase == "accepting" then P(("click Accept on %s's invite."):format(hop.host.name)) end
end, "blocked")

ns.hooks.joined = function()
	if hosting then hosting.joined = true end
	-- an Ask still waiting, and the user joined a group by hand (an invite Sliders did not take as theirs): that is the
	-- hop's group, whoever invited; never left by Sliders (the user chose it)
	if hop and hop.ask and hop.phase == "invited" then
		hop.phase, hop.tInvite, hop.byHand = "accepting", now(), true
		hop.inviter = hop.inviter or hop.seenInvite
		log(("hop_joined_by_hand %s via %s"):format(hop.req, tostring(hop.inviter)))
	end
	if not hop or hop.phase ~= "accepting" then return end
	hop.phase = "joined"
	pcall(StaticPopup_Hide, "PARTY_INVITE")   -- joined: Blizzard's invite popup, if still up, has nothing left to do
	local h = hop
	L.After(SPAM.moveTimeout, function()
		if hop ~= h or hop.phase ~= "joined" then return end
		if h.byHand then
			endHop(h.transfer and "moved, but Sliders could not read the new shard yet." or "no move after 2 minutes.",
				h.transfer == true, true)
			return
		end
		endHop(h.transfer and "moved, but Sliders could not read the new shard yet; left the group."
			or "no move after 2 minutes; left the group.", h.transfer == true)
	end, "hop")
end

ns.hooks.imminent = function(sec)
	local mine = {}
	movePending = mine
	-- a countdown that neither moves nor cancels (a loading screen in between): closed again at most 30 s after it
	L.After((sec or 300) + 30, function() if movePending == mine then movePending = nil refreshOpen() end end, "move")
	refreshOpen()
	if not hop or (hop.phase ~= "joined" and hop.phase ~= "accepting") then return end
	hop.countdown = sec and (math.floor(sec) .. "s") or "?"
	if refreshButton then refreshButton:Show() end
end

-- the move comes about 1 s after joining, without a countdown (alcaras' log, 2026-11-09 17:04): leave 3 s after it;
-- the new shard's name follows once Sliders has read a few NPCs there
ns.hooks.transfer = function(moved)
	if refreshButton then refreshButton:Hide() end
	if movePending then movePending = nil refreshOpen() end
	if not (moved and hop and (hop.phase == "joined" or hop.phase == "accepting")) then return end
	hop.transfer, hop.tMove = true, now()   -- the guest stays in the host's group; the new shard's key ends the hop
end

ns.hooks.left = function()
	if hosting then quietEnd(10) end
	hosting = nil
	if hop and hop.phase == "joined" then endHop("the group ended before the move.", false) end
	refreshOpen()
end

-- ---------------------------------------------------------------- the host
local popup

local function invite(c, req, guestFull)
	-- never past a party, never into a raid (alcaras: "never convert to raid")
	if inRaid() or (A.inGroup() and (not A.isLeader() or A.groupSize() >= SPAM.party)) then
		sendTo(c, ("NO2;%s;%s;full"):format(c.key, req))
		log(("host_full %s %s"):format(req, c.name))
		return
	end
	sendTo(c, ("OK2;%s;%s;%s"):format(c.key, req, L.Value(L.Read(UnitGUID, "player")) or ""))
	quiet(guestFull)
	if A.inGroup() and not A.lockdown() then   -- the party's other Sliders users hide the guest's join and leave too
		pcall(C_ChatInfo.SendAddonMessage, A.PREFIX, "QT2;" .. first(guestFull), "PARTY")
	end
	if not A.inGroup() then
		local hh = { req = req, guest = c.key, t = now() }
		hosting = hh
		-- declined, expired or failed: no join within the invite's life, so this is no longer a hop's group
		L.After(SPAM.inviteTimeout, function()
			if hosting == hh and not hh.joined then
				hosting = nil
				log(("host_expired %s %s"):format(req, c.name))
				refreshOpen()
			end
		end, "hosting")
	end
	pcall(C_PartyInfo.InviteUnit, guestFull)
	log(("host_invite %s %s"):format(req, guestFull))
end

local function onHopRequest(c, req, map, shard, guestFull)
	if now() - (asked[c.key] or -1e9) < SPAM.perRequester then return end   -- one request per requester per 2 min
	asked[c.key] = now()
	local why = closedWhy("direct")
	if not why and L.InCombat() then why = "combat" end
	if not why and (tonumber(map) ~= A.mapID() or A.shardOf(shard) ~= A.current()) then why = "moved" end
	log(("host_request %s from %s by %s: %s"):format(req, c.name, ROUTE_NAME[c.route], why or "ok"))
	if why then sendTo(c, ("NO2;%s;%s;%s"):format(c.key, req, why)) return end
	local t = now()
	local n = 0
	for i = #autoLog, 1, -1 do if t - autoLog[i] < SPAM.autoWindow then n = n + 1 else table.remove(autoLog, i) end end
	local auto = char.invite == "anyone" or (char.invite == "friends" and c.friend)
	if auto and n < SPAM.autoInvites then
		autoLog[#autoLog + 1] = t
		invite(c, req, guestFull)
		say(("invited %s for a hop to your shard."):format(c.name))
		return
	end
	if popup then popup:Ask(c, req, guestFull) end
end

ns.hooks.message = function(body, channel, sender, bnID)
	local f = { strsplit(";", body) }
	local v = f[1]
	if v == "QT2" then   -- the party's host is about to invite a hop guest: hide that guest's join and leave
		if channel == "PARTY" and f[2] then quiet(f[2]) end
		return
	end
	if v ~= "HI2" and v ~= "ST2" and v ~= "HOP2" and v ~= "OK2" and v ~= "NO2" and v ~= "DONE2" then return end
	local c, route = contactFrom(channel, sender, bnID)
	if not c then return end
	c.seen = now()
	if v == "HI2" then
		setStatus(c, route, f[3], f[4], f[5], f[6], f[2], f[7])
		answer(c, route, f[3])
	elseif v == "ST2" then
		setStatus(c, route, f[2], f[3], f[4], f[5], f[7], f[8])
		local mine = answering[route]
		if mine and tonumber(f[2]) == A.mapID() and A.shardOf(f[3]) == mine.shard and (f[4] == "1" or not mine.open) then
			mine.cancelled = true   -- someone already answered for our shard
		end
		if f[6] == "1" then answer(c, route, f[2]) end
	elseif f[2] == ownKey() then
		if v == "HOP2" then onHopRequest(c, f[3], f[4], f[5], f[6])
		elseif v == "OK2" or v == "NO2" then onHostAnswer(v, f[3], f[4])
		elseif v == "DONE2" then log(("host_done %s %s on %s"):format(f[3], c.name, tostring(f[4]))) end
	end
end

-- ---------------------------------------------------------------- key, combat, world
ns.hooks.key = function(key)
	if hop and (hop.phase == "joined" or hop.phase == "accepting" or hop.phase == "moved") and key ~= hop.from then
		hop.tMove = hop.tMove or now()
		local cr = hop.host.name
		if not hop.host.noSliders then sendTo(hop.host, ("DONE2;%s;%s;%s"):format(hop.host.key, hop.req, key)) end
		local stay = A.inGroup()
		-- invited by their group's leader: "via Val Aran (Stevie Bones invited)", the group is Stevie Bones'
		local by = (hop.inviter and not sameChar(hop.inviter, hop.host.full)) and hop.inviter or nil
		local via = cr .. (by and (" (%s invited)"):format(by) or "")
		local where = (key == hop.shard or hop.shard == nil) and ("moved to %s via %s."):format(A.label(key), via)
			or ("moved to %s (not %s's shard)."):format(A.label(key), cr)
		endHop(stay and (where .. (" You stay in %s's group: leaving may move you back."):format(by or cr)) or where, true, stay)
	end
	-- friends whose hello came before our shard was known get their answer now
	for _, c in pairs(contacts) do
		if c.owesReply then c.owesReply = nil c.replied = now() sendTo(c, st2("direct")) end
	end
	-- a re-confirm of the same shard (after a join, a transfer, a reload) is no news
	local map = A.mapID()
	if key ~= advertised.shard or map ~= advertised.map then
		advertised.shard, advertised.map = key, map
		pushStatus()
	end
	if ns.RefreshPanel then ns.RefreshPanel() end
end

ns.hooks.combat = function(inCombat)
	if inCombat then return end
	for kind in pairs(deferred) do deferred[kind] = nil schedule(kind) end
end

ns.hooks.roster = function() refreshOpen() end

-- one hello per session to every route, with my status: Sliders users answer, the rest hear nothing more
local function hello()
	if helloSent or not char then return end
	if blocked() then L.After(30, hello, "hello") return end
	helloSent = true
	local msg = hi2("direct")
	local bn, wh = 0, 0
	for _, f in ipairs(A.bnFriends()) do
		if bn < SPAM.hello then bn = bn + 1 ns.sendRoute("BN", msg, f.id) end
	end
	for _, name in ipairs(A.charFriends()) do
		if wh < SPAM.hello then wh = wh + 1 ns.sendRoute("WHISPER", msg, name) end
	end
	local guild = L.Read(IsInGuild) == true
	if guild then ns.sendRoute("GUILD", hi2("GUILD")) end
	local ch = ns.channelID()
	if ch then ns.sendRoute("CHANNEL", hi2("CHANNEL"), tostring(ch)) end
	log(("hello sent: %d Battle.net, %d whispers%s%s"):format(bn, wh, guild and ", guild" or "", ch and ", channel" or ""))
end

local restored = false
ns.hooks.world = function()
	if not restored then restored = true ns.restoreContacts() end
	helloAt = now() + 15
	L.After(15, hello, "hello")
	refreshOpen()
end

local matesQueued = false
local function matesChanged()
	ns.ForgetZoneMates()
	if matesQueued or not ns.RefreshPanel then return end
	matesQueued = true
	L.After(1, function() matesQueued = false if ns.RefreshPanel then ns.RefreshPanel() end end, "mates")
end
L.On("GUILD_ROSTER_UPDATE", matesChanged, "mates")
L.On("FRIENDLIST_UPDATE", matesChanged, "mates")
L.On("BN_FRIEND_INFO_CHANGED", matesChanged, "mates")
L.On("ZONE_CHANGED_NEW_AREA", matesChanged, "mates")

L.On("PLAYER_FLAGS_CHANGED", function(_, unit)
	if L.Value(unit) == "player" then refreshOpen() end
end, "afk")
L.On("LFG_LIST_ACTIVE_ENTRY_UPDATE", function() refreshOpen() end, "lfg")
L.On("UPDATE_BATTLEFIELD_STATUS", function() refreshOpen() end, "bg")

ns.hooks.load = function()
	char = ns.char
	if char.open ~= "solo" and char.open ~= "group" then char.open = "off" end   -- default: not open
	if char.invite == "auto" then char.invite = "friends" end   -- 0.3.0-0.3.6's "Invite friends at once"
	if char.invite ~= "friends" and char.invite ~= "anyone" then char.invite = "ask" end
	char.afterHop, char.strangers = nil, nil   -- settings of 0.3.0-0.3.6 that are gone
	if ns.db then ns.db.askPlug = nil end      -- an unreleased switch: the Ask whisper never mentions Sliders
end

-- ---------------------------------------------------------------- UI (AlcPrices' look, its UI.lua S table: flat panel,
-- Calibri, gold section labels, flat buttons in the action blue, the primary one filled)
-- Built inside buildUI() under pcall: if any of it fails on a client, the minimap button and the slash commands below
-- still work, and one line says what failed (Crow, 2026-11-09: no minimap button and no panel, his only addon).
local uiError
local function buildUI()
-- Calibri only when AlcFont is loaded (its files exist then); friends without it get the game's own font. Every text
-- starts from a game font object, so a font path the client refuses never leaves it without a font ("Font not set").
local CALIBRI = C_AddOns and L.Read(C_AddOns.IsAddOnLoaded, "AlcFont") == true
local FONT, FONT_BOLD = "Interface\\AddOns\\AlcFont\\Calibri.ttf", "Interface\\AddOns\\AlcFont\\CalibriBold.ttf"   -- standalone-ok: used only when CALIBRI (AlcFont loaded)

local function fill(f, c)
	local t = f:CreateTexture(nil, "BACKGROUND")
	t:SetAllPoints()
	t:SetColorTexture(c[1], c[2], c[3], c[4] or 1)
	return t
end

local function text(parent, size, color, bold)
	local fs = parent:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
	local ok = CALIBRI and fs:SetFont(bold and FONT_BOLD or FONT, size, "")
	if not ok then pcall(fs.SetFont, fs, STANDARD_TEXT_FONT, size, "") end
	fs:SetTextColor(color[1], color[2], color[3])
	fs:SetJustifyH("LEFT")
	return fs
end

-- a 1 px border; returns its four textures (a button recolours them)
local function edge(f, c) return L.Border(f, c or C.line) end

-- a flat button: "primary" (filled action blue, white label: Hop, Invite, Refresh now), "plain" (AlcPrices' button:
-- a light fill, the label in the action blue), "tab" (a segment: unselected quiet, selected like primary)
local function pill(parent, label, w, style, onClick)
	local b = CreateFrame("Button", nil, parent)
	b:SetSize(w, 22)
	b.bg = fill(b, C.action)
	b.border = edge(b, C.action)
	b.label = text(b, 12, C.action, true)
	b.label:SetPoint("CENTER")
	b.label:SetJustifyH("CENTER")
	b.label:SetText(label)
	b.style = style
	local a, q = C.action, C.muted
	local function paint(bgA, borderA, labelC)
		b.bg:SetColorTexture(a[1], a[2], a[3], bgA)
		for _, t in ipairs(b.border) do t:SetColorTexture(a[1], a[2], a[3], borderA) end
		b.label:SetTextColor(labelC[1], labelC[2], labelC[3])
	end
	function b:Paint()
		if not self:IsEnabled() then paint(0, 0.25, q) return end
		local hot = self.hot and 0.12 or 0
		if self.style == "primary" or (self.style == "tab" and self.selected) then paint(0.38 + hot, 0.9, C.white)
		elseif self.style == "tab" then paint(hot, 0, self.hot and C.ink or q)
		else paint(0.16 + hot, 0.5, a) end
	end
	function b:SetSelected(on) self.selected = on self:Paint() end
	function b:SetUsable(on) self:SetEnabled(on) self:Paint() end
	L.Script(b, "OnEnter", function(self) self.hot = true self:Paint() end, "button")
	L.Script(b, "OnLeave", function(self) self.hot = false self:Paint() end, "button")
	L.Script(b, "OnClick", onClick, "button")
	b:Paint()
	return b
end

local function card(name, w, h, strata)
	local f = CreateFrame("Frame", name, UIParent)
	f:SetPoint("TOP", UIParent, "TOP", 0, -150)
	f:SetSize(w, h)
	f:SetFrameStrata(strata or "DIALOG")
	fill(f, C.bg)
	edge(f)
	f:EnableMouse(true)
	f:Hide()
	return f
end

-- the refresh button: Blizzard's countdown for the hop's move; one click moves now (out of combat)
refreshButton = card("SlidersRefresh", 280, 64)
do
	local t = text(refreshButton, 12, C.ink)
	t:SetPoint("TOP", 0, -10)
	t:SetJustifyH("CENTER")
	t:SetText("A shard move is coming for your hop.")
	pill(refreshButton, "Refresh now", 120, "primary", function()
		if L.InCombat() then P("the move waits until you leave combat.") return end
		pcall(C_PlayerInteractionManager.ShardTransferConfirm)
		refreshButton:Hide()
	end):SetPoint("BOTTOM", 0, 10)
end

-- the host's popup: one request, Invite or No
popup = card("SlidersAsk", 320, 74)
do
	local eyebrow = text(popup, 10.5, C.gold, true)
	eyebrow:SetPoint("TOPLEFT", 12, -10)
	eyebrow:SetText("SLIDERS · HOP REQUEST")
	local t = text(popup, 13, C.ink)
	t:SetPoint("TOPLEFT", 12, -26)
	t:SetWidth(296)
	function popup:Invite()
		local q = self.q
		self:Hide()
		self.q = nil
		if q and now() - q.t < 60 then invite(q.c, q.req, q.full) end
	end
	function popup:Decline()
		local q = self.q
		self:Hide()
		self.q = nil
		if q then
			sendTo(q.c, ("NO2;%s;%s;declined"):format(q.c.key, q.req))
			log(("host_declined %s %s"):format(q.req, q.c.name))
		end
	end
	local yes = pill(popup, "Invite", 90, "primary", function() popup:Invite() end)
	yes:SetPoint("BOTTOMRIGHT", -108, 10)
	local no = pill(popup, "No", 90, "plain", function() popup:Decline() end)
	no:SetPoint("BOTTOMRIGHT", -12, 10)
	function popup:Ask(c, req, full)
		local old = self.q
		if old and now() - old.t < 60 then   -- one request at a time: the earlier one is told, not left to time out
			sendTo(old.c, ("NO2;%s;%s;busy"):format(old.c.key, old.req))
			log(("host_replaced %s %s"):format(old.req, old.c.name))
		end
		self.q = { c = c, req = req, full = full, t = now() }
		t:SetText(("%s asks to hop to your shard."):format(c.name))
		self:Show()
		local q = self.q
		L.After(60, function() if popup.q == q then popup:Hide() end end, "popup")
	end
end

ns.popup, ns.refreshButton, ns.ownKey = popup, refreshButton, ownKey
function ns.isHosting() return hosting ~= nil end

-- the Shards panel (2026-11-14; alcaras: "very spaced out. look at huddle", "tufte", "think about cuj user journeys";
-- then "settings should be another window, not a toggle for the window we're on"). Built for the journeys in NOTES.md:
-- (1) who of my friends and guild is in this zone, one click Ask; (2) someone asks me (the popup above); (3) did it
-- work (the status line, the shard in the title); (4) rarely, the settings: their own small window beside the panel
-- (the gear, or /sliders settings). Huddle's density: one 18 px line per person and per shard, columns, no boxed rows,
-- no repeated labels, a faint stripe on every other line; a long list scrolls with the wheel. Green = your shard,
-- everywhere. Every action word says on hover what it does, or why it can't right now; every line has a tooltip.
-- full names ("Crow Blackfeather", 2026-11-14) need the wider name column; a name too long still ends in "..." and
-- the line's tooltip has it whole; the source column fits "BN · guild"
local PL = { width = 360, pad = 10, row = 18, head = 16, people = 12, shards = 6, gap = 8, thumb = 2, top = 28,
	nameW = 168, srcW = 56, shardW = 44, whenW = 48, actW = 40, actH = 15, setWidth = 320 }
local panel = card("SlidersPanel", PL.width, 200)
panel:SetPoint("TOP", UIParent, "TOP", 0, -170)
L.Movable(panel, function(pos) if ns.db then ns.db.panelPos = pos end end)
panel:SetClampedToScreen(true)
tinsert(UISpecialFrames, "SlidersPanel")   -- Escape closes it (and the settings with it)

local function place(region, y, x, parent)
	region:ClearAllPoints()
	region:SetPoint("TOPLEFT", parent or panel, "TOPLEFT", x or PL.pad, y)
end

-- a tooltip of { text, colour } lines; the first is the heading
local function tip(owner, lines)
	GameTooltip:SetOwner(owner, "ANCHOR_RIGHT")
	for i, l in ipairs(lines) do
		local c = l[2] or (i == 1 and C.white or C.ink)
		GameTooltip:AddLine(l[1], c[1], c[2], c[3], true)
	end
	GameTooltip:Show()
end

-- a small text button in the action blue (Huddle's inline invite slot, as a word); muted when it can't act, and its
-- tooltip then says why
local function link(parent, label, onClick, size)
	local b = CreateFrame("Button", nil, parent)
	b:SetSize(PL.actW, PL.row)
	b:SetMotionScriptsWhileDisabled(true)
	b.label = text(b, size or 11, C.action, true)
	b.label:SetPoint("RIGHT")
	b.label:SetJustifyH("RIGHT")
	b.label:SetText(label)
	b.color = C.action
	function b:SetLabel(t) self.label:SetText(t) end
	function b:Paint(c)
		self.color = c or self.color
		local live = self.color == C.action
		local lc = (live and self.hot) and C.white or self.color
		self.label:SetTextColor(lc[1], lc[2], lc[3])
		if self.bg then
			local a = C.action
			if live then
				self.bg:SetColorTexture(a[1], a[2], a[3], self.hot and 0.32 or 0.16)
				for _, t in ipairs(self.edges) do t:SetColorTexture(a[1], a[2], a[3], self.hot and 0.9 or 0.55) end
			else
				self.bg:SetColorTexture(1, 1, 1, 0.03)
				for _, t in ipairs(self.edges) do t:SetColorTexture(C.line[1], C.line[2], C.line[3], 1) end
			end
		end
	end
	function b:SetUsable(on) self:SetEnabled(on) self:Paint(on and C.action or C.muted) end
	L.Script(b, "OnEnter", function(self)
		self.hot = self:IsEnabled()
		self:Paint()
		if self.tip then self.tip(self) end
	end, "link")
	L.Script(b, "OnLeave", function(self) self.hot = false self:Paint() GameTooltip:Hide() end, "link")
	L.Script(b, "OnClick", onClick, "link")
	return b
end

-- a row's action as a small button: a frame and a light action-blue fill, brighter under the mouse, grey when it
-- can't act (its tooltip then says why)
local function framed(b)
	b:SetSize(PL.actW, PL.actH)
	b.bg = fill(b, C.action)
	b.edges = edge(b, C.action)
	b.label:ClearAllPoints()
	b.label:SetPoint("CENTER", 0, 0)
	b.label:SetJustifyH("CENTER")
	b:Paint()
	return b
end

-- why Ask / Hop can't act right now (nil: they can); the same checks ns.Ask and ns.Hop make, said before the click
local function blockReason()
	if hop then return "A hop is running: wait for its result." end
	if A.instanced() or A.paused() then return "Only in the open world: shards are read there." end
	if not A.current() then return "Your shard is not read yet: look at an NPC or two." end
	if A.inGroup() then return "You are in a group: a hop works by invite, so leave it first." end
	if L.InCombat() then return "Not in combat." end
	if A.lockdown() then return "Chat is locked right now (a boss fight or a rated match)." end
end
ns.blockReason = blockReason

-- the title bar: zone, your shard (green), the gear, x
local title = text(panel, 13, C.ink, true)
title:SetPoint("TOPLEFT", PL.pad, -8)
local titleShard = text(panel, 12, C.green, true)
titleShard:SetPoint("LEFT", title, "RIGHT", 6, 0)
local close = link(panel, "x", function() panel:Hide() end, 13)
close:SetSize(16, 18)
close:SetPoint("TOPRIGHT", -6, -5)
close:Paint(C.muted)
close.tip = function(self) tip(self, { { "Close" }, { "Escape closes it too.", C.muted } }) end

local gear = CreateFrame("Button", nil, panel)
gear:SetSize(15, 15)
gear:SetPoint("RIGHT", close, "LEFT", -6, 0)
gear.tex = gear:CreateTexture(nil, "ARTWORK")
gear.tex:SetAllPoints()
if not pcall(gear.tex.SetAtlas, gear.tex, "gear") then gear.tex:SetColorTexture(C.muted[1], C.muted[2], C.muted[3], 1) end
function gear:Paint()
	local on = self.active or self.hot
	self.tex:SetDesaturated(not on)
	self.tex:SetAlpha(on and 1 or 0.6)
end
L.Script(gear, "OnEnter", function(self)
	self.hot = true self:Paint()
	tip(self, { { "Settings" }, { "Open for hop invites, what happens when someone asks, the Ask whisper, what Sliders shows.", C.muted } })
end, "gear")
L.Script(gear, "OnLeave", function(self) self.hot = false self:Paint() GameTooltip:Hide() end, "gear")
L.Script(gear, "OnClick", function() ns.ToggleSettings() end, "gear")
gear:Paint()

local status = text(panel, 10.5, C.muted)
status:SetWidth(PL.width - 2 * PL.pad)

-- a list of one-line rows, at most maxRows shown; the wheel scrolls, a thin line shows where; each row's tooltip
-- comes from rowTip(row, item)
local function list(maxRows, build, draw, rowTip)
	local box = CreateFrame("Frame", nil, panel)
	box:SetSize(PL.width - 2 * PL.pad, PL.row)
	box:EnableMouseWheel(true)
	box.rows, box.offset = {}, 0
	box.thumb = box:CreateTexture(nil, "OVERLAY")
	box.thumb:SetColorTexture(1, 1, 1, 0.25)
	box.thumb:SetWidth(PL.thumb)
	for i = 1, maxRows do
		local r = CreateFrame("Frame", nil, box)
		r:SetHeight(PL.row)
		r:SetPoint("TOPLEFT", box, "TOPLEFT", 0, -(i - 1) * PL.row)
		r:SetPoint("RIGHT", box, "RIGHT", -(PL.thumb + 2), 0)
		local stripe = r:CreateTexture(nil, "BACKGROUND")
		stripe:SetAllPoints()
		stripe:SetColorTexture(1, 1, 1, (i % 2 == 0) and 0.035 or 0)
		r.hover = r:CreateTexture(nil, "BACKGROUND")
		r.hover:SetAllPoints()
		r.hover:SetColorTexture(1, 1, 1, 0.06)
		r.hover:Hide()
		r:EnableMouse(true)
		L.Script(r, "OnEnter", function(self)
			self.hover:Show()
			if self.item and rowTip then rowTip(self, self.item) end
		end, "row")
		L.Script(r, "OnLeave", function(self) self.hover:Hide() GameTooltip:Hide() end, "row")
		build(r)
		r:Hide()
		box.rows[i] = r
	end
	function box:Fill(items)
		local maxOff = math.max(#items - maxRows, 0)
		if self.offset > maxOff then self.offset = maxOff end
		local n = math.min(#items, maxRows)
		for i = 1, maxRows do
			local r, it = self.rows[i], items[self.offset + i]
			r.item = it
			r:SetShown(it ~= nil)
			if it then draw(r, it) end
		end
		if #items > maxRows then
			local h = n * PL.row
			local size = math.max(h * maxRows / #items, 8)
			self.thumb:SetHeight(size)
			self.thumb:ClearAllPoints()
			self.thumb:SetPoint("TOPRIGHT", self, "TOPRIGHT", 0, -((h - size) * self.offset / maxOff))
			self.thumb:Show()
		else
			self.thumb:Hide()
		end
		self:SetHeight(math.max(n, 1) * PL.row)
		self:SetShown(n > 0)
		return n * PL.row
	end
	L.Script(box, "OnMouseWheel", function(self, delta)
		self.offset = math.max(self.offset - delta * 2, 0)
		ns.RefreshPanel()
	end, "wheel")
	return box
end

local function column(r, size, color, x, w)
	local fs = text(r, size, color)
	fs:SetPoint("LEFT", r, "LEFT", x, 0)
	if w then fs:SetWidth(w) end
	if fs.SetWordWrap then fs:SetWordWrap(false) end
	return fs
end

local function paint(fs, c) fs:SetTextColor(c[1], c[2], c[3]) end

-- readable ages: now, 13 min, 16 h, 2 d (never "966 min")
local function shortAge(sec)
	sec = math.max(0, math.floor(sec))
	if sec < 90 then return "now" end
	if sec < 90 * 60 then return math.floor(sec / 60 + 0.5) .. " min" end
	if sec < 36 * 3600 then return math.floor(sec / 3600 + 0.5) .. " h" end
	return math.floor(sec / 86400 + 0.5) .. " d"
end
ns.shortAge = shortAge
local function ago(sec) local a = shortAge(sec) return a == "now" and "a moment ago" or (a .. " ago") end

-- (1) people in this zone: name | source | shard | Ask / Hop ("here" when they are on yours)
local SRC = { ["Battle.net friend"] = "BN", friend = "friend", guild = "guild" }
local SRC_LONG = { ["Battle.net friend"] = "Battle.net friend", friend = "Friend", guild = "Guild" }
local function hopsTo(p) return p.sliders and p.open and p.shard end
-- "BN · guild" (short) / "Battle.net friend · Guild" (the tooltip): every list that names this character
local function sources(p, names)
	local out = {}
	for _, s in ipairs(p.sources or { p.source }) do out[#out + 1] = names[s] or s end
	return table.concat(out, " · ")
end
local matesLabel = text(panel, 10, C.gold, true)
local matesNone = text(panel, 10.5, C.muted)
matesNone:SetWidth(PL.width - 2 * PL.pad)
local mates = list(PL.people, function(r)
	r.name = column(r, 12, C.ink, 0, PL.nameW)
	r.src = column(r, 10.5, C.muted, PL.nameW + PL.gap, PL.srcW)
	r.shard = column(r, 11, C.muted, PL.nameW + PL.srcW + 2 * PL.gap, PL.shardW)
	r.act = link(r, "Ask", function()
		local p = r.item
		if not p then return end
		if hopsTo(p) then ns.Hop(p.shard) else ns.Ask(p) end
	end)
	framed(r.act)
	r.act:SetPoint("RIGHT", r, "RIGHT", -1, 0)
	r.act.tip = function(self)
		local p = r.item
		if not p then return end
		if self.why then tip(self, { { self.why } }) return end
		if hopsTo(p) then
			tip(self, { { ("Hop to %s's shard"):format(p.name) },
				{ "They run Sliders and are open: Sliders asks, they invite, the server moves you.", C.muted } })
		else
			tip(self, { { ("Ask %s for an invite"):format(p.name) }, { "Whispers: \"" .. ns.AskText() .. "\"" },
				{ "Their invite is accepted, the server moves you onto their shard, you stay in their group.", C.muted } })
		end
	end
end, function(r, p)
	local cur, why = A.current(), blockReason()
	local mine = p.shard ~= nil and p.shard == cur
	r.name:SetText(ns.classColored(p.name, p.class))
	r.src:SetText(sources(p, SRC))
	r.shard:SetText(p.shard and A.serverOf(p.shard) or "?")
	paint(r.shard, mine and C.green or (p.shard and C.ink or C.muted))
	if mine then
		r.act:SetLabel("here")
		r.act:SetUsable(false)
		r.act.why = ("%s is on your shard."):format(p.name)
	else
		r.act:SetLabel(hopsTo(p) and "Hop" or "Ask")
		r.act:SetUsable(why == nil)
		r.act.why = why
	end
end, function(r, p)
	local cur = A.current()
	local where = p.shard and ("shard %s%s"):format(A.serverOf(p.shard), p.shard == cur and " (yours)" or "") or "shard unknown"
	tip(r, { { ns.classColored(p.name, p.class) }, { sources(p, SRC_LONG) .. " · " .. where },
		p.sliders and { ("Sliders %s · %s"):format(p.version or "?", p.open and "open for hop invites" or "not open for hop invites"), C.muted }
		or { "No Sliders: Ask whispers them for an invite.", C.muted } })
end)

-- (2) shards of this zone: shard | when | who | Hop
local shardsLabel = text(panel, 10, C.gold, true)
ns.panelLabels = { mates = matesLabel, shards = shardsLabel }   -- for the harness: which section comes first
local shardsNone = text(panel, 10.5, C.muted)
shardsNone:SetWidth(PL.width - 2 * PL.pad)
local whoW = PL.width - 2 * PL.pad - PL.shardW - PL.whenW - PL.actW - 3 * PL.gap - PL.thumb - 2
local shards = list(PL.shards, function(r)
	r.name = column(r, 12, C.ink, 0, PL.shardW)
	r.when = column(r, 10.5, C.muted, PL.shardW + PL.gap, PL.whenW)
	r.who = column(r, 10.5, C.muted, PL.shardW + PL.whenW + 2 * PL.gap, whoW)
	r.act = link(r, "Hop", function() if r.item then ns.Hop(r.item.shard) end end)
	framed(r.act)
	r.act:SetPoint("RIGHT", r, "RIGHT", -1, 0)
	r.act.tip = function(self)
		local e = r.item
		if not e then return end
		if self.why then tip(self, { { self.why } }) return end
		local open = {}
		for _, p in ipairs(e.people) do if p.st and p.st.open then open[#open + 1] = p.name end end
		tip(self, { { ("Hop to %s"):format(A.serverOf(e.shard)) },
			{ ("Sliders asks %s to invite you; the server moves you."):format(table.concat(open, " or ")), C.muted } })
	end
end, function(r, e)
	r.name:SetText(A.serverOf(e.shard))
	paint(r.name, e.you and C.green or C.ink)
	r.when:SetText(e.you and "you" or (#e.people > 0 and "now") or (e.seen and shortAge(A.stamp() - e.seen)) or "")
	local who = {}
	for _, p in ipairs(e.people) do if p.friend then who[#who + 1] = ns.classColored(p.name, p.class) end end
	local others = #e.people - #who
	if others > 0 then who[#who + 1] = others .. " more" end
	local s = table.concat(who, ", ")
	if e.crowd then s = s .. (s ~= "" and " · " or "") .. e.crowd .. " players" end
	r.who:SetText(s)
	local canHop = not e.you and e.open > 0
	r.act:SetShown(canHop)
	if canHop then
		local why = blockReason()
		r.act:SetUsable(why == nil)
		r.act.why = why
	end
end, function(r, e)
	local lines = { { A.label(e.shard) },
		{ e.you and "You are here." or (e.seen and ("You were here %s."):format(ago(A.stamp() - e.seen))) or "You have not been here." } }
	if e.crowd then lines[#lines + 1] = { ("%d players seen on it."):format(e.crowd), C.muted } end
	for _, p in ipairs(e.people) do
		lines[#lines + 1] = { ns.classColored(p.name, p.class) .. (p.st and p.st.open and "  |cff66d966open|r" or "") }
	end
	tip(r, lines)
end)

-- (3) the status line: a hop in progress, its result for 2 min, why the shard is unknown, else whether you are open
local OPEN_SAY = { solo = "Open for hop invites when solo", group = "Open for hop invites when your party has room" }
local INVITE_SAY = { ask = "asks you", friends = "friends at once", anyone = "anyone at once" }
local function statusLine()
	if hop then
		-- in their group (whoever invited, Sliders or a click): the wait is for the move now
		if hop.phase == "joined" or hop.phase == "moved" then
			return ("In %s's group; waiting for the move..."):format(hop.inviter or hop.host.name), C.action
		end
		if hop.phase == "accepting" then
			return ("%s invited you; joining..."):format(hop.inviter or hop.host.name), C.action
		end
		-- the asked friend passed it on to their group's leader (the suggest line)
		if hop.ask and type(hop.leader) == "string" then
			return ("%s asked %s (leader) to invite you..."):format(hop.host.name, hop.leader), C.action
		elseif hop.ask and hop.leader == true then
			return ("%s asked their group's leader to invite you..."):format(hop.host.name), C.action
		end
		return hop.ask and ("Asked %s; waiting for the invite..."):format(hop.host.name)
			or ("Asking %s to invite you..."):format(hop.host.name), C.action
	end
	local r = ns.lastResult
	if r and now() - r.t < 120 then return (r.text:gsub("^%l", string.upper)), r.ok and C.green or C.warn end
	if A.instanced() or A.paused() then return "Shards are read in the open world only.", C.muted end
	if not A.current() then return "Your shard is not read yet: look at an NPC or two.", C.muted end
	local mode = char and char.open or "off"
	local s = OPEN_SAY[mode] and (OPEN_SAY[mode] .. ((closedWhy("direct") and " (paused now)") or "") .. " · "
		.. INVITE_SAY[char.invite or "ask"]) or "Not open for hop invites"
	local newest = ns.newestFriendVersion()
	if newest then s = s .. (" · Sliders %s is out"):format(newest) end
	return s, C.muted
end

-- shard -> { shard, you, seen (stamp), people = { contact }, open = n, crowd }
function ns.Shards()
	local map, cur = A.mapID(), A.current()
	local out = {}
	local function get(s)
		local e = out[s]
		if not e then e = { shard = s, people = {}, open = 0 } out[s] = e end
		return e
	end
	if cur then local e = get(cur) e.you, e.crowd = true, ns.crowd() end
	local m = char and map and char.maps[map]
	if m then
		for key, rec in pairs(m.keys) do
			local s = A.shardOf(key)
			if s then
				local e = get(s)
				e.seen = math.max(e.seen or 0, rec.last or 0)
				if not e.crowd and s ~= cur then e.crowd = ns.crowd(s) end   -- what we saw when we were there
			end
		end
	end
	local counted = {}   -- shard .. identity: a character known by two routes (Battle.net and the guild) counts once
	for _, c in pairs(contacts) do
		local st = c.st
		local once = st and st.shard and (st.shard .. "|" .. (A.ident(c.full) or c.key))
		if once and st.map == map and current(c) and not counted[once] then
			counted[once] = true
			local e = get(st.shard)
			e.people[#e.people + 1] = c
			if st.open then e.open = e.open + 1 end
			if st.crowd and not e.you then e.crowd = math.max(e.crowd or 0, st.crowd) end
		end
	end
	local list = {}
	for _, e in pairs(out) do list[#list + 1] = e end
	table.sort(list, function(a, b)
		if (a.you or false) ~= (b.you or false) then return a.you == true end
		if a.open ~= b.open then return a.open > b.open end
		if #a.people ~= #b.people then return #a.people > #b.people end
		return (a.seen or 0) > (b.seen or 0)
	end)
	return list
end

-- (4) the settings: their own small window beside the panel (the gear, /sliders settings), its own x; Escape closes it.
-- alcaras (2026-11-14): "these should look like buttons, think about good ux design": every choice is a real button
-- in a segmented row (a frame and a background on each, the chosen one lit like AlcUpgrades' active tab: a light
-- background, an action-blue underline and edge, the bright label; the others dimmed but button-shaped; a hover
-- highlight), the toggles are checkboxes, the Ask whisper an edit box with a visible frame. Hierarchy: section labels
-- gold and bold, help small and grey under the control it explains.
local SET = { width = PL.setWidth, segH = 22, segPad = 10, segGap = 3, check = 14, checkRow = 20, editH = 22,
	head = 16, afterHead = 2, afterControl = 4, help = 13, section = 12 }
local settings = card("SlidersSettings", SET.width, 200)
settings:SetClampedToScreen(true)
tinsert(UISpecialFrames, "SlidersSettings")
do
	local SW = SET.width - 2 * PL.pad
	local st = text(settings, 13, C.ink, true)
	st:SetPoint("TOPLEFT", PL.pad, -8)
	st:SetText("Sliders settings")
	local x = link(settings, "x", function() settings:Hide() end, 13)
	x:SetSize(16, 18)
	x:SetPoint("TOPRIGHT", -6, -5)
	x:Paint(C.muted)
	x.tip = function(self) tip(self, { { "Close" }, { "Escape closes it too.", C.muted } }) end
	local y = -PL.top - 2
	local function heading(label)
		local h = text(settings, 10.5, C.gold, true)
		place(h, y, nil, settings)
		h:SetText(label)
		y = y - SET.head - SET.afterHead
	end
	local function help(fs)
		place(fs, y, nil, settings)
		fs:SetWidth(SW)
		y = y - SET.help
	end
	settings.options, settings.helps = {}, {}

	-- a segmented row: one button per choice, stretched to the window's width, equal heights; the help line under it
	-- says what the chosen one does
	local function segmented(options, get, set)
		local buttons, natural, total = {}, {}, 0
		for i, o in ipairs(options) do
			local key = o[1]
			local b = CreateFrame("Button", nil, settings)
			b.bg = fill(b, { 1, 1, 1, 0.04 })
			b.edges = edge(b, C.line)
			b.under = b:CreateTexture(nil, "ARTWORK")
			b.under:SetHeight(2)
			b.under:SetPoint("BOTTOMLEFT", 1, 1)
			b.under:SetPoint("BOTTOMRIGHT", -1, 1)
			b.under:SetColorTexture(C.action[1], C.action[2], C.action[3], 1)
			b.label = text(b, 11.5, C.muted, true)
			b.label:SetPoint("CENTER", 0, 1)
			b.label:SetJustifyH("CENTER")
			b.label:SetText(o[2])
			b.key, b.note = key, o[3]
			natural[i] = math.ceil(L.Num(b.label:GetStringWidth()) or 40) + 2 * SET.segPad
			total = total + natural[i]
			function b:Paint()
				local on = get() == key
				self.on = on
				self.bg:SetColorTexture(1, 1, 1, on and 0.13 or (self.hot and 0.08 or 0.04))
				local e = on and C.action or (self.hot and C.muted or C.line)
				for _, t in ipairs(self.edges) do t:SetColorTexture(e[1], e[2], e[3], on and 0.8 or 1) end
				self.under:SetShown(on)
				paint(self.label, on and C.white or (self.hot and C.ink or C.muted))
			end
			L.Script(b, "OnEnter", function(self)
				self.hot = true self:Paint()
				tip(self, { { o[2] }, { o[3], C.muted } })
			end, "segment")
			L.Script(b, "OnLeave", function(self) self.hot = false self:Paint() GameTooltip:Hide() end, "segment")
			L.Script(b, "OnClick", function() set(key) ns.RefreshPanel() end, "segment")
			buttons[i] = b
			settings.options[#settings.options + 1] = b
		end
		local extra = math.max(SW - total - SET.segGap * (#buttons - 1), 0) / #buttons
		local xo = PL.pad
		for i, b in ipairs(buttons) do
			local w = math.floor(natural[i] + extra)
			if i == #buttons then w = PL.pad + SW - xo end   -- the last one ends flush with the window's edge
			b:SetSize(w, SET.segH)
			place(b, y, xo, settings)
			xo = xo + w + SET.segGap
		end
		y = y - SET.segH - SET.afterControl
		local h = text(settings, 10, C.muted)
		help(h)
		settings.helps[#settings.helps + 1] = function()
			local k = get()
			for _, o in ipairs(options) do if o[1] == k then h:SetText(o[3]) end end
		end
	end

	-- a checkbox line: a framed box with Blizzard's minimal check when on, the label, a short grey note; the whole line
	-- is the click target and lights under the mouse
	local function checkbox(label, note, isOn, toggle)
		local b = CreateFrame("Button", nil, settings)
		b:SetSize(SW, SET.checkRow)
		place(b, y, nil, settings)
		y = y - SET.checkRow
		b.hl = fill(b, { 1, 1, 1, 0 })
		b.box = CreateFrame("Frame", nil, b)
		b.box:SetSize(SET.check, SET.check)
		b.box:SetPoint("LEFT", 2, 0)
		fill(b.box, { 0, 0, 0, 0.35 })
		b.edges = edge(b.box, C.muted)
		b.check = b.box:CreateTexture(nil, "OVERLAY")
		if pcall(b.check.SetAtlas, b.check, "checkmark-minimal") then
			b.check:SetSize(SET.check, SET.check)
			b.check:SetPoint("CENTER")
		else
			b.check:SetPoint("TOPLEFT", 3, -3)
			b.check:SetPoint("BOTTOMRIGHT", -3, 3)
			b.check:SetColorTexture(C.action[1], C.action[2], C.action[3], 1)
		end
		b.label = text(b, 11.5, C.ink)
		b.label:SetPoint("LEFT", b.box, "RIGHT", 8, 0)
		b.label:SetText(label)
		b.note = text(b, 10, C.muted)
		b.note:SetPoint("LEFT", b.label, "RIGHT", 8, 0)
		b.note:SetText(note or "")
		function b:Paint()
			local on = isOn() and true or false
			self.on = on
			self.check:SetShown(on)
			self.hl:SetColorTexture(1, 1, 1, self.hot and 0.05 or 0)
			local e = on and C.action or (self.hot and C.ink or C.muted)
			for _, t in ipairs(self.edges) do t:SetColorTexture(e[1], e[2], e[3], 1) end
			paint(self.label, self.hot and C.white or C.ink)
		end
		L.Script(b, "OnEnter", function(self) self.hot = true self:Paint() end, "checkbox")
		L.Script(b, "OnLeave", function(self) self.hot = false self:Paint() end, "checkbox")
		L.Script(b, "OnClick", function() toggle() ns.RefreshPanel() end, "checkbox")
		settings.options[#settings.options + 1] = b
	end

	local function setOpen(k) if char then char.open = k log("open " .. k) refreshOpen() end end
	local function setInvite(k) if char then char.invite = k log("invite " .. k) end end
	heading("OPEN FOR HOP INVITES")
	segmented({ { "off", "Off", "Nobody can ask you to invite them." },
		{ "solo", "When solo", "Friends and guild can ask while you are alone." },
		{ "group", "When my party has room", "Also while you lead a party with room; never a raid, an instance or a BG." } },
		function() return char and char.open or "off" end, setOpen)
	y = y - SET.section
	heading("WHEN SOMEONE ASKS")
	segmented({ { "ask", "Ask me", "A small popup for each request: Invite or No." },
		{ "friends", "Friends at once", "Friends and guild are invited at once; others get the popup." },
		{ "anyone", "Anyone at once", "Everyone who asks is invited at once, no popup." } },
		function() return char and char.invite or "ask" end, setInvite)
	y = y - SET.section
	heading("ASK WHISPER")
	-- an edit box with a visible frame (darker inside, the edge lights under the mouse and while typing)
	local ask = CreateFrame("EditBox", nil, settings)
	ask:SetSize(SW, SET.editH)
	place(ask, y, nil, settings)
	ask:SetAutoFocus(false)
	ask:SetMaxLetters(240)
	ask:SetTextInsets(6, 6, 0, 0)
	ask:SetFontObject(GameFontHighlightSmall)
	if CALIBRI then pcall(ask.SetFont, ask, FONT, 11, "") end
	ask:SetTextColor(C.ink[1], C.ink[2], C.ink[3])
	fill(ask, { 0, 0, 0, 0.4 })
	local askEdges = edge(ask, C.muted)
	local function paintAsk(self)
		local e = self:HasFocus() and C.action or (self.hot and C.ink or C.muted)
		for _, t in ipairs(askEdges) do t:SetColorTexture(e[1], e[2], e[3], 1) end
	end
	local function saveAsk(self)
		local t = ((self:GetText() or ""):gsub("^%s+", ""):gsub("%s+$", ""))
		if ns.db then ns.db.askText = (t ~= "" and t ~= ASK_TEXT) and t or nil end
		self:SetText(ns.AskText())
		paintAsk(self)
	end
	L.Script(ask, "OnEnterPressed", function(self) self:ClearFocus() end, "asktext")
	L.Script(ask, "OnEscapePressed", function(self) self:SetText(ns.AskText()) self:ClearFocus() end, "asktext")
	L.Script(ask, "OnEditFocusLost", saveAsk, "asktext")
	L.Script(ask, "OnEditFocusGained", paintAsk, "asktext")
	L.Script(ask, "OnEnter", function(self) self.hot = true paintAsk(self) end, "asktext")
	L.Script(ask, "OnLeave", function(self) self.hot = false paintAsk(self) end, "asktext")
	settings.ask = ask
	y = y - SET.editH - SET.afterControl
	local askHelp = text(settings, 10, C.muted)
	help(askHelp)
	askHelp:SetText("What Ask whispers. Click to edit; Enter keeps it, Esc undoes, empty = the default.")
	y = y - SET.section
	heading("SHOW")
	checkbox("Shard line", "right-click it to move it", function() return ns.db and ns.db.shown end,
		function() if ns.setLineShown then ns.setLineShown(not (ns.db and ns.db.shown)) end end)
	checkbox("Minimap button", nil, function() return ns.db and type(ns.db.minimap) == "table" and not ns.db.minimap.hide end,
		function() if ns.setMinimapShown then ns.setMinimapShown(ns.db and type(ns.db.minimap) == "table" and ns.db.minimap.hide) end end)
	checkbox("Chat lines", "each step in chat, for testing", function() return ns.db and ns.db.chat end,
		function() if ns.db then ns.db.chat = not ns.db.chat end end)
	settings:SetHeight(-y + PL.pad)
end

function ns.RefreshSettings()
	if not settings:IsShown() then return end
	for _, b in ipairs(settings.options) do b:Paint() end
	for _, f in ipairs(settings.helps) do f() end
	if not settings.ask:HasFocus() then settings.ask:SetText(ns.AskText()) end
end

-- beside the panel (left of it when there is no room on the right), else where the panel would open
local function placeSettings()
	settings:ClearAllPoints()
	if panel:IsShown() then
		local right, width = L.Num(panel:GetRight()), L.Num(UIParent:GetWidth())
		if right and width and right + PL.setWidth + 6 > width then settings:SetPoint("TOPRIGHT", panel, "TOPLEFT", -6, 0)
		else settings:SetPoint("TOPLEFT", panel, "TOPRIGHT", 6, 0) end
	else
		settings:SetPoint("TOP", UIParent, "TOP", 0, -170)
	end
end

function ns.ToggleSettings(on)
	if on == nil then on = not settings:IsShown() end
	if on then placeSettings() settings:Show() else settings:Hide() end
	ns.RefreshPanel()
end

function ns.RefreshPanel()
	ns.RefreshSettings()
	if not panel:IsShown() then return end
	local map, cur = A.mapID(), A.current()
	local zone = A.mapName(map)
	title:SetText(zone or "?")
	titleShard:SetText(cur and A.serverOf(cur) or "?")
	paint(titleShard, cur and C.green or C.muted)
	gear.active = settings:IsShown()
	gear:Paint()
	local s, c = statusLine()
	status:SetText(s)
	paint(status, c)
	place(status, -PL.top + 2)
	local y = -PL.top + 2 - math.ceil(status:GetStringHeight() or 12) - 8
	place(matesLabel, y)
	matesLabel:SetText("FRIENDS AND GUILD HERE")
	y = y - PL.head
	local people = ns.ZoneMates()
	matesNone:SetShown(#people == 0)
	if #people == 0 then
		place(matesNone, y)
		matesNone:SetText(("None of your friends or guild are online in %s."):format(zone or "this zone"))
		y = y - PL.row
	end
	place(mates, y)
	y = y - mates:Fill(people) - 8
	place(shardsLabel, y)
	shardsLabel:SetText("SHARDS HERE")
	y = y - PL.head
	local known = ns.Shards()
	shardsNone:SetShown(#known == 0)
	if #known == 0 then
		place(shardsNone, y)
		shardsNone:SetText("None known yet: Sliders reads shards from the NPCs you look at.")
		y = y - PL.row
	end
	place(shards, y)
	y = y - shards:Fill(known)
	panel:SetHeight(-y + PL.pad)
end

function ns.TogglePanel()
	if panel:IsShown() then panel:Hide() return end
	if ns.db and ns.db.panelPos then L.RestorePoint(panel, ns.db.panelPos, function(f) f:SetPoint("TOP", UIParent, "TOP", 0, -170) end) end
	if C_GuildInfo and C_GuildInfo.GuildRoster and L.Read(IsInGuild) == true then pcall(C_GuildInfo.GuildRoster) end
	ns.ForgetZoneMates()
	panel:Show()
	if settings:IsShown() then placeSettings() end
	-- opening the panel asks guild and channel who is here (at most once per 2 min)
	for _, kind in ipairs({ "GUILD", "CHANNEL" }) do
		if now() - (lastAsk[kind] or -1e9) >= SPAM.askEvery and now() - (lastSent[kind] or -1e9) >= every(kind)
			and A.current() and not blocked() then
			lastAsk[kind], lastMap[kind] = now(), A.mapID()
			sendKind(kind, true)
		end
	end
	ns.RefreshPanel()
end
ns.panelLists = { mates = mates, shards = shards }                    -- for the harness
function ns.panelStatus() return status:GetText() end                 -- for the harness
function ns.panelEmpty()
	return { mates = matesNone:IsShown() and matesNone:GetText() or "", shards = shardsNone:IsShown() and shardsNone:GetText() or "" }
end
ns.panel, ns.settings, ns.gear = panel, settings, gear
L.Script(panel, "OnShow", function() ns.RefreshPanel() end, "panel")
L.Script(panel, "OnHide", function() settings:Hide() end, "panel")   -- the settings go with the panel they sit beside
L.Script(settings, "OnShow", function() ns.RefreshSettings() end, "settings")
L.Script(settings, "OnHide", function() if settings.ask:HasFocus() then settings.ask:ClearFocus() end ns.RefreshPanel() end, "settings")

end   -- buildUI
do
	local ok, err = pcall(buildUI)
	if not ok then uiError = tostring(err) end
end

-- ---------------------------------------------------------------- minimap button (LibDBIcon, embedded under Libs/)
-- the same glance as the shard line's tooltip (your shard, your friends' shards), with the button's own hint
local function iconTooltip(tt)
	if ns.tooltip then ns.tooltip(tt, "Click: shards here  ·  Drag: move this button") end
end

-- for the tooltips: whether you are open for hop invites, and if not right now, why
function ns.openText()
	local mode = char and char.open or "off"
	if mode == "off" then return nil end
	local why = closedWhy("direct")
	local what = mode == "solo" and "Open for hop invites when solo" or "Open for hop invites when your party has room"
	return why and (what .. " (paused now)") or what
end

local dbi
local function makeIcon()
	local ldb = LibStub and LibStub("LibDataBroker-1.1", true)
	dbi = LibStub and LibStub("LibDBIcon-1.0", true)
	if not (ldb and dbi and ns.db) then dbi = nil return end
	if type(ns.db.minimap) ~= "table" then ns.db.minimap = { minimapPos = 215 } end
	local obj = ldb:NewDataObject("Sliders", {
		type = "launcher", text = "Sliders", icon = "Interface\\Icons\\spell_arcane_portalthunderbluff",
		OnClick = L.Safe("minimap click", function() if ns.TogglePanel then ns.TogglePanel() end end),
		OnTooltipShow = L.Safe("minimap tooltip", iconTooltip),
	})
	if obj then dbi:Register("Sliders", obj, ns.db.minimap) end
end

local loadHook = ns.hooks.load
ns.hooks.load = function()
	loadHook()
	makeIcon()
	if uiError then
		log("ui_error " .. uiError)
		P("the Shards panel could not be built on this client: " .. uiError)
	end
end

-- ---------------------------------------------------------------- slash
ns.commands.settings = function()
	if ns.ToggleSettings then ns.ToggleSettings() else P("the settings window is not available: " .. tostring(uiError)) end
end
ns.commands.shards = function()
	if ns.TogglePanel then ns.TogglePanel() else P("the Shards panel is not available: " .. tostring(uiError)) end
end
ns.commands.open = function(arg)
	if not char then return end
	if arg == "solo" or arg == "group" or arg == "off" then char.open = arg
	else P("/sliders open off | solo | group: solo = only while alone; group = also while leading a party with room.") return end
	log("open " .. char.open)
	refreshOpen()
	P(char.open == "off" and "not open for hop invites." or (char.open == "solo" and "open for hop invites while solo."
		or "open for hop invites while solo or leading a party with room (never a raid, an instance or a battleground)."))
end
local INVITE_SAY = { ask = "each hop request asks you first.", friends = "friends are invited at once; others are asked.",
	anyone = "everyone who asks is invited at once." }
ns.commands.invite = function(arg)
	if not char then return end
	if arg == "auto" then arg = "friends" end
	if INVITE_SAY[arg] then char.invite = arg
	else P("/sliders invite ask | friends | anyone: ask everyone; invite friends and ask others; invite anyone.") return end
	log("invite " .. char.invite)
	if ns.RefreshPanel then ns.RefreshPanel() end
	P(INVITE_SAY[char.invite])
end
ns.commands.asktext = function(arg)
	local db = ns.db
	if not db then return end
	if arg == "reset" then db.askText = nil
	elseif arg ~= "" then db.askText = arg end
	P("Ask whispers: " .. ns.AskText())
end
function ns.setMinimapShown(on)
	if not (dbi and ns.db) then return false end
	ns.db.minimap.hide = not on
	if on then dbi:Show("Sliders") else dbi:Hide("Sliders") end
	if ns.RefreshSettings then ns.RefreshSettings() end
	return true
end
ns.commands.minimap = function()
	if not ns.setMinimapShown(ns.db and type(ns.db.minimap) == "table" and ns.db.minimap.hide) then
		P("no minimap button: LibDBIcon did not load.") return
	end
	P(ns.db.minimap.hide and "minimap button hidden (/sliders minimap shows it)." or "minimap button shown.")
end
ns.commands.hop = function(arg)
	local server = arg:match("^(%d+)$")
	if not server then P("/sliders hop <server>: e.g. /sliders hop 7074 (the number in the shard's name).") return end
	local cur = A.current()
	local mapPart = cur and cur:match("%-(%d+)$") or nil
	if not mapPart then P("Sliders does not know your shard yet: look at an NPC or two.") return end
	ns.Hop(server .. "-" .. mapPart)
end
