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
		c = { key = key, name = first(full), full = full, route = route, target = target }
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
	for _, f in ipairs(A.bnFriends()) do ids[f.name:lower()] = f.id end
	local t = A.stamp()
	for key, r in pairs(db.contacts) do
		if type(r) ~= "table" or t - (r.at or 0) > KEEP_CONTACTS then
			db.contacts[key] = nil
		elseif not contacts[key] then
			local target = r.route == "WHISPER" and r.full or nil
			if r.route == "BN" then target = ids[(r.name or ""):lower()] end
			if r.route ~= "BN" or target then
				contacts[key] = { key = key, name = r.name, full = r.full, route = r.route, target = target, friend = r.friend,
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

ns.hooks.invite = function(name, inviterGUID)
	if not hop or (hop.phase ~= "asked" and hop.phase ~= "invited") then return end
	local match
	if hop.hostGUID and hop.hostGUID ~= "" then match = inviterGUID == hop.hostGUID
	else match = norm(name) == hop.host.key end
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
		P(("%s invited you: click Accept on the invite."):format(hop.host.name))
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
	if not hop or hop.phase ~= "accepting" then return end
	hop.phase = "joined"
	pcall(StaticPopup_Hide, "PARTY_INVITE")   -- joined: Blizzard's invite popup, if still up, has nothing left to do
	local h = hop
	L.After(SPAM.moveTimeout, function()
		if hop ~= h or hop.phase ~= "joined" then return end
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
		sendTo(hop.host, ("DONE2;%s;%s;%s"):format(hop.host.key, hop.req, key))
		local stay = A.inGroup()
		local where = key == hop.shard and ("moved to %s via %s."):format(A.label(key), cr)
			or ("moved to %s (not %s's shard)."):format(A.label(key), cr)
		endHop(stay and (where .. (" You stay in %s's group: leaving may move you back."):format(cr)) or where, true, stay)
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

-- the Shards panel: one row per shard known in this zone; it sizes itself to what it shows
local W, ROWS, ROWH, PAD = 460, 7, 42, 16
local panel = card("SlidersPanel", W, 300)
panel:SetPoint("TOP", UIParent, "TOP", 0, -170)
L.Movable(panel, function(pos) if ns.db then ns.db.panelPos = pos end end)
panel:SetClampedToScreen(true)
tinsert(UISpecialFrames, "SlidersPanel")   -- Escape closes it

local eyebrow = text(panel, 10.5, C.gold, true)
eyebrow:SetPoint("TOPLEFT", PAD, -14)
eyebrow:SetText("SLIDERS " .. VERSION .. " · SHARDS HERE")
local title = text(panel, 17, C.ink, true)
title:SetPoint("TOPLEFT", PAD, -28)
local sub = text(panel, 11, C.muted)
sub:SetPoint("TOPLEFT", PAD, -54)
sub:SetWidth(W - 2 * PAD - 30)

local close = CreateFrame("Button", nil, panel)
close:SetSize(24, 24)
close:SetPoint("TOPRIGHT", -8, -8)
close.label = text(close, 16, C.muted)
close.label:SetPoint("CENTER")
close.label:SetText("×")
L.Script(close, "OnEnter", function() close.label:SetTextColor(C.ink[1], C.ink[2], C.ink[3]) end, "close")
L.Script(close, "OnLeave", function() close.label:SetTextColor(C.muted[1], C.muted[2], C.muted[3]) end, "close")
L.Script(close, "OnClick", function() panel:Hide() end, "close")

local rows = {}
for i = 1, ROWS do
	local r = CreateFrame("Frame", nil, panel)
	r:SetSize(W - 2 * PAD, ROWH)
	r.bg = fill(r, C.row)
	r.name = text(r, 13, C.ink, true)
	r.name:SetPoint("TOPLEFT", 12, -7)
	r.detail = text(r, 11, C.muted)
	r.detail:SetPoint("TOPLEFT", 12, -24)
	r.detail:SetWidth(W - 2 * PAD - 110)
	r.detail:SetWordWrap(false)
	r.tag = text(r, 11, C.green)
	r.tag:SetPoint("RIGHT", -12, 0)
	r.tag:SetJustifyH("RIGHT")
	r.hop = pill(r, "Hop", 70, "primary", function() if r.shard then ns.Hop(r.shard) end end)
	r.hop:SetPoint("RIGHT", -10, 0)
	r.hop:SetMotionScriptsWhileDisabled(true)
	L.Script(r.hop, "OnEnter", function(self)
		GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
		GameTooltip:AddLine(self:IsEnabled() and "Ask someone open on this shard to invite you"
			or "Nobody open for invites is known on this shard", 1, 1, 1, true)
		GameTooltip:Show()
	end, "hop tip")
	L.Script(r.hop, "OnLeave", function() GameTooltip:Hide() end, "hop tip")
	r:Hide()
	rows[i] = r
end

local empty = CreateFrame("Frame", nil, panel)
empty:SetSize(W - 2 * PAD, 54)
fill(empty, C.row)
local emptyText = text(empty, 12, C.muted)
emptyText:SetPoint("LEFT", 12, 0)
emptyText:SetWidth(W - 2 * PAD - 24)
emptyText:SetText("No shard read yet. Target an NPC or move the mouse over one: Sliders reads the shard from it.")

local divider = panel:CreateTexture(nil, "BORDER")
divider:SetColorTexture(C.divider[1], C.divider[2], C.divider[3], C.divider[4])
divider:SetHeight(1)

-- a segmented control like Profit Margin's tabs: one strip, the selected option in ink
local function segmented(options, onPick)
	local box = CreateFrame("Frame", nil, panel)
	fill(box, C.row)
	edge(box)
	box.buttons = {}
	local x = 3
	for _, o in ipairs(options) do
		local mode = o[1]
		local b = pill(box, o[2], o[3], "tab", function() onPick(mode) end)
		b:SetPoint("LEFT", x, 0)
		x = x + o[3] + 2
		box.buttons[mode] = b
	end
	box:SetSize(x + 1, 28)
	function box:Select(mode) for m, b in pairs(self.buttons) do b:SetSelected(m == mode) end end
	return box
end

local openLabel = text(panel, 10.5, C.gold, true)
openLabel:SetText("OPEN FOR HOP INVITES")
local openSeg = segmented({ { "off", "Off", 70 }, { "solo", "When solo", 96 }, { "group", "When my party has room", 170 } },
	function(mode)
		if not char then return end
		char.open = mode
		log("open " .. mode)
		refreshOpen()
	end)
local inviteLabel = text(panel, 10.5, C.gold, true)
inviteLabel:SetText("WHEN SOMEONE ASKS TO HOP")
local inviteSeg = segmented({ { "ask", "Ask everyone", 104 }, { "friends", "Invite friends, ask others", 170 },
	{ "anyone", "Invite anyone", 110 } }, function(mode)
	if not char then return end
	char.invite = mode
	log("invite " .. mode)
	ns.RefreshPanel()
end)
local hint = text(panel, 10, C.muted)
hint:SetWidth(W - 2 * PAD)

local function place(region, y, x)
	region:ClearAllPoints()
	region:SetPoint("TOPLEFT", panel, "TOPLEFT", x or PAD, y)
end

local function ago(t) return t < 90 and "now" or (A.age(t) .. " ago") end

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
	for _, c in pairs(contacts) do
		local st = c.st
		if st and st.shard and st.map == map and current(c) then
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

local WHY_CLOSED = { busy = "Open for invites is paused right now: an instance, a flight, away, your party is queued,"
	.. " or the game is about to move you to another shard.",
	full = "Open for invites is paused right now: you are in a group (or it has no room, or you don't lead it)." }

function ns.RefreshPanel()
	if not panel:IsShown() then return end
	local map, cur = A.mapID(), A.current()
	title:SetText(A.mapName(map))
	local list = ns.Shards()
	sub:SetText(cur and ("You are on %s · %d players seen in 5 min · %d %s known here"):format(A.label(cur),
		ns.crowd(), #list, #list == 1 and "shard" or "shards") or "Your shard here is not read yet.")
	local y = -78
	empty:SetShown(#list == 0)
	if #list == 0 then
		place(empty, y)
		y = y - 54 - 4
	end
	for i = 1, ROWS do
		local r, e = rows[i], list[i]
		r.shard = e and e.shard
		r:SetShown(e ~= nil)
		if e then
			place(r, y)
			y = y - ROWH - 4
			local who, strangers = {}, 0
			for _, c in ipairs(e.people) do
				if c.friend then who[#who + 1] = ns.classColored(c.name, c.class) .. (c.st.open and " (open)" or "")
					.. ((c.version and c.version ~= VERSION) and (" (" .. c.version .. ")") or "")
				else strangers = strangers + 1 end
			end
			if strangers > 0 then who[#who + 1] = strangers .. " more with Sliders" end
			local parts = {}
			if #who > 0 then parts[#parts + 1] = table.concat(who, ", ") end
			if e.crowd then parts[#parts + 1] = e.crowd .. " players seen" end
			if not e.you and #e.people == 0 and e.seen then parts[#parts + 1] = "you were here " .. ago(A.stamp() - e.seen) end
			r.name:SetText(A.label(e.shard))
			r.detail:SetText(#parts > 0 and table.concat(parts, " · ") or "nobody with Sliders known here")
			if e.you then
				r.bg:SetColorTexture(C.rowYou[1], C.rowYou[2], C.rowYou[3], C.rowYou[4])
				r.tag:SetText("you are here")
				r.tag:Show()
				r.hop:Hide()
			else
				r.bg:SetColorTexture(C.row[1], C.row[2], C.row[3], C.row[4])
				r.tag:Hide()
				r.hop:Show()
				r.hop:SetUsable(e.open > 0 and not hop)
			end
		end
	end
	y = y - 10
	divider:ClearAllPoints()
	divider:SetPoint("TOPLEFT", panel, "TOPLEFT", PAD, y)
	divider:SetPoint("TOPRIGHT", panel, "TOPRIGHT", -PAD, y)
	y = y - 14
	place(openLabel, y)
	place(openSeg, y - 16)
	y = y - 16 - 28 - 12
	place(inviteLabel, y)
	place(inviteSeg, y - 16)
	y = y - 16 - 28 - 14
	local mode = char and char.open or "off"
	openSeg:Select(mode)
	inviteSeg:Select(char and char.invite or "ask")
	local why = mode ~= "off" and closedWhy("direct") or nil
	if hop then
		hint:SetText(("Hop: asking %s to invite you to %s..."):format(hop.host.name, A.label(hop.shard)))
		hint:SetTextColor(C.action[1], C.action[2], C.action[3])
	else
		local newest = ns.newestFriendVersion()
		hint:SetText(newest and ("A friend runs Sliders %s (you have %s): github.com/alcaras/sliders/releases."):format(newest, VERSION)
			or why and WHY_CLOSED[why] or "Hop asks a friend who is open for invites on that shard to invite you; "
			.. "the server moves you, and Sliders leaves the group for you a few seconds later.")
		hint:SetTextColor(C.muted[1], C.muted[2], C.muted[3])
	end
	place(hint, y)
	panel:SetHeight(-y + math.ceil(hint:GetStringHeight() or 12) + 14)
end

function ns.TogglePanel()
	if panel:IsShown() then panel:Hide() return end
	if ns.db and ns.db.panelPos then L.RestorePoint(panel, ns.db.panelPos, function(f) f:SetPoint("TOP", UIParent, "TOP", 0, -170) end) end
	panel:Show()
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
L.Script(panel, "OnShow", function() ns.RefreshPanel() end, "panel")

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
ns.commands.minimap = function()
	if not (dbi and ns.db) then P("no minimap button: LibDBIcon did not load.") return end
	ns.db.minimap.hide = not ns.db.minimap.hide
	if ns.db.minimap.hide then dbi:Hide("Sliders") else dbi:Show("Sliders") end
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
