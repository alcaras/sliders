# Portage

A WoW Forever addon that shows which shard of the server you are on. Forever puts everyone on one big server and
splits each zone into copies (shards). Portage works out your copy from the NPCs around you and shows it as a small
line under the minimap, like "Barrens B". In a group it tells your party which shard you see, so you can tell
whether you are all in the same one.

It only reads and writes down what it sees. It never invites, accepts, leaves a group or presses anything for you.

This is a test version (0.2.0). The goal is to find out how well shard detection works, and which ways of
messaging reach a friend on another shard, before building shard hopping on top of it.

## What it shows

- **The shard line**, under the minimap: the zone and a letter, like "Barrens A". Grey until Portage is sure
  (3 reads from at least 2 NPCs over at least 5 seconds), white once it is, grey again when it hasn't seen an NPC for
  2 minutes. Before that it shows the raw key in grey. `?` means nothing yet, a loading screen, a dungeon or a flight
  (shards aren't read there). Drag it to move it.
- **How it knows:** every NPC's ID (its GUID, like `Creature-0-6821-1-948-3000-...`) names the server and zone copy
  that spawned it: `6821-1-948` is the key. NPCs near you were spawned by your shard, so their key is yours.
- **The names are Portage's, not WoW's,** and they are yours: "Barrens A" is the first Barrens shard *you* saw. Your
  friend's "Barrens A" can be a different shard; compare the raw key in `/portage` instead.
- **Hover the line** (or type `/portage`) for the details: the raw key, how many NPC reads back it up, who in your
  party is on another shard, and which key each party member with Portage sees.
- **Chat lines** only when something happens: "a shard move is coming in 30 s", or "your shard changed while you
  stayed in the zone".

## How to help test

1. Install it, log in (a full relog, not just `/reload`, the first time), and play as usual. Target or mouse over a
   few NPCs.
2. Group up with someone else who runs Portage. Type `/portage`: the lines "<name> sees ..." say whether you see the
   same key.
3. **The ping test**, with a friend who is *not* in your group and on a different key: type `/portage ping`. It sends
   one test message every way there is: guild, the `PortageTest` channel, a whisper to each online friend, and
   Battle.net to each Battle.net friend playing Forever. `/portage ping Name` also whispers that character. Each
   friend with Portage gets a chat line like "Alcara pinged you by Battle.net: 6821-1-948, a different key from
   yours" and answers automatically, so you see "Bob answered by guild: ...". Which ways arrive across shards is what
   we want to learn. Try it once on the same shard and once on different ones.
4. At moments worth noting, type `/portage mark <text>`, e.g. `/portage mark crossed into Stonetalon` or
   `/portage mark accepted the invite`. It goes into the log with the time.
5. Afterwards, send the file `World of Warcraft\_forever_\WTF\Account\<your account>\SavedVariables\Portage.lua`.
   It holds the shard log: keys, zones, times, group size, the character names of party members and of friends whose
   pings you got or sent. No chat, nothing else.

## Commands

- `/portage`: which shard you are on, the party, and which key each friend reported.
- `/portage ping [name]`: the ping test (once per 10 seconds).
- `/portage log [n]`: the last n lines of the log (15 by default).
- `/portage mark <text>`: a note in the log.
- `/portage hide` / `/portage show`: the shard line by the minimap.
- `/portage channel off` / `on`: Portage joins a hidden chat channel, `PortageTest`, for the ping test. Anyone who
  joins that channel can see who is in it; `off` leaves it.

## Install

Unzip `Portage-<version>.zip` into `World of Warcraft\_forever_\Interface\AddOns`, so the folder `Portage` holds
`Portage.toc`. Then log in.

World of Warcraft is Blizzard Entertainment's. A fan project, not affiliated with Blizzard.
