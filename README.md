# Portage

A WoW Forever addon that shows which shard of the server you are on. Forever puts everyone on one big server and
splits each zone into copies (shards). Portage works out your copy from the NPCs around you and shows it as a small
line under the minimap, like "Barrens B". In a group it tells your party which shard you see, so you can tell
whether you are all in the same one.

It only reads and writes down what it sees. It never invites, accepts, leaves a group or presses anything for you.

This is a test version (0.1.1). The goal is to find out how well shard detection works before building anything
on top of it.

## What it shows

- **The shard line**, under the minimap: the zone and a letter, like "Barrens A". Grey until Portage is sure
  (a few NPCs over a few seconds), white once it is, grey again when it hasn't seen an NPC for 2 minutes. `?` means
  nothing yet, a loading screen, a dungeon or a flight (shards aren't read there). Drag it to move it.
- **The letters are yours:** "Barrens A" is the first Barrens shard *you* saw. Your friend's "Barrens A" can be a
  different shard; compare the raw key (`6821-1-948`) in `/portage` instead.
- **Hover the line** (or type `/portage`) for the details: the raw key, how many NPC reads back it up, who in your
  party is on another shard, and which key each party member with Portage sees.
- **Chat lines** only when something happens: "a shard move is coming in 30 s", or "your shard changed while you
  stayed in the zone".

## How to help test

1. Install it, log in (a full relog, not just `/reload`, the first time), and play as usual. Target or mouse over a
   few NPCs.
2. Group up with someone else who runs Portage. Type `/portage`: the lines "<name> sees ..." say whether you see the
   same key.
3. At moments worth noting, type `/portage mark <text>`, e.g. `/portage mark crossed into Stonetalon` or
   `/portage mark accepted the invite`. It goes into the log with the time.
4. Afterwards, send the file `World of Warcraft\_forever_\WTF\Account\<your account>\SavedVariables\Portage.lua`.
   It holds the shard log: keys, zones, times, group size, the first names of your party members. No chat, nothing
   else.

## Commands

- `/portage`: which shard you are on, and the party.
- `/portage log [n]`: the last n lines of the log (15 by default).
- `/portage mark <text>`: a note in the log.
- `/portage hide` / `/portage show`: the shard line by the minimap.

## Install

Unzip `Portage-<version>.zip` into `World of Warcraft\_forever_\Interface\AddOns`, so the folder `Portage` holds
`Portage.toc`. Then log in.

World of Warcraft is Blizzard Entertainment's. A fan project, not affiliated with Blizzard.
