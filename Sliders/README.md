# Sliders

A WoW Forever addon for shards. Forever puts everyone on one big server and splits each zone into copies (shards,
or layers). Sliders shows which shard you are on, which shard your friends are on, and lets you **hop** to another
shard of your zone with one click, when a friend there is open for invites.

It is quiet: nothing in chat unless you ask, and it never invites anyone or joins a group unless you clicked for it
(or you switched on "open for invites").

This is a test version (0.3.2). It was called Portage before; remove the old `Portage` folder.

## What it shows

- **The shard line**: a small line like "Desolace 7074". The number is the shard (the game's server for it), so
  everyone on the same shard sees the same name. Grey until Sliders is sure (3 reads from at least 2 NPCs over at
  least 5 seconds), white once it is. `?` means nothing read yet, a loading screen, a dungeon or a flight.
  - The first time, the line sits near the top of the screen in a blue box: **drag it** where you want it, then
    **right-click** it to lock it there. Right-click again to unlock.
- **How it knows:** every NPC's ID (its GUID, like `Creature-0-7074-1-9-3000-...`) names the server that spawned it:
  `7074` is the shard, `1` the continent. The number after that differs from player to player even on one shard,
  so Sliders ignores it.
- **The Shards panel** (left-click the line, the minimap button, or `/sliders shards`): every shard known in your zone,
  who of your friends is on it, who is open for invites, how many players you saw there. **Hop** sits on every shard
  where someone is open.

## Hopping

1. Open the panel, click **Hop** on a shard.
2. Sliders asks a friend who is open on that shard to invite you. Their Sliders either invites you at once, or shows
   them a small "Alcara asks to hop to your shard [Invite] [No]".
3. You accept the invite (Sliders does it for you when the game allows; otherwise click Accept).
4. The server moves you within a second or two. Sliders leaves the group for you 3 seconds later, and you stay on
   the new shard.

The hop's own messages are silent (addon messages nobody sees). The game's own group lines for the hop ("Bnpal
joins the party", "You leave the group", "Your group has been disbanded") are hidden for the hop's few seconds, for
you, the host and the host's party members who run Sliders. Nothing else in chat is touched.

You must be out of a group, out of combat, and in the open world to hop.

## Open for invites (off by default)

In the panel, or `/sliders open`:

- **Off**: nobody can ask you.
- **When solo**: friends can ask while you are alone.
  (Paused while the game has a shard move scheduled for you, so nobody lands on a shard you are about to leave.)
- **When my party has room**: also while you lead a party of 4 or fewer. Never a raid, never in a dungeon or
  battleground, never while your party is listed in the group finder or queued together. Your party will see the
  guest join and leave a few seconds later.

And **when someone asks**: **Ask me** (a popup each time) or **Invite friends at once**.
"Friends" are your Battle.net friends, character friends and guild members who run Sliders.

## Commands

- `/sliders`: your shard, and the shards your friends reported.
- `/sliders shards`: the panel. `/sliders hop 7074`: hop to that shard of your zone.
- `/sliders open off | solo | group`, `/sliders invite ask | auto`.
- `/sliders lock` / `unlock`, `/sliders hide` / `show`: the shard line. `/sliders minimap`: the minimap button.
- `/sliders chat on | off`: the automatic chat lines ("your shard changed", "a shard move is coming"), off by default.
- `/sliders channel on | off`: a public chat channel (`SlidersTest`) where everyone running Sliders can see each other,
  strangers too. Off by default; anyone in that channel can see who is in it. `/sliders strangers on` also lets
  strangers there ask you for a hop (when you are open).
- `/sliders ping [name]`: a test of which routes reach your friends; `/sliders log [n]`, `/sliders mark <text>`.

## How to help test

- Hop a few times, and host a few hops. Try: inviting from another zone, relogging, crossing a zone line together.
- At moments worth noting, `/sliders mark <what happened>`.
- Afterwards, send the file `World of Warcraft\_forever_\WTF\Account\<your account>\SavedVariables\Sliders.lua`.
  It holds the shard log: shards, zones, times, group size, hop steps with their timings, and the character names
  of friends whose shard you saw. No chat, nothing else.

## Messages

Sliders talks only to friends and guild members who run it (and the public channel, if you switch it on), with small
addon messages you never see: a hello at login, your shard when it changes (at most once per 30 seconds), and the
hop request and answers. Nothing in combat, nothing on a timer.

## Install

Unzip `Sliders-<version>.zip` into `World of Warcraft\_forever_\Interface\AddOns`, so the folder `Sliders` holds
`Sliders.toc`. Then log in (a full relog, not just `/reload`, the first time).

Sliders embeds LibStub, CallbackHandler, LibDataBroker and LibDBIcon for its minimap button.
World of Warcraft is Blizzard Entertainment's. A fan project, not affiliated with Blizzard.
