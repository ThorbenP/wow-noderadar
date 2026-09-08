# NodeRadar

You have *Find Minerals* up, you are riding through Nagrand, and you sail straight
past a Fel Iron vein because the yellow dot on your minimap is four pixels wide and
you were watching the road.

NodeRadar puts those nodes on a **radar centred on your screen** — big, turning with
your view, with the distance in yards next to every icon.

## What makes it different from a node database

Addons that draw node positions from a database show you where a node **might** be.
That list never changes: it does not know whether the vein was mined two minutes ago
by the rogue ahead of you.

NodeRadar shows only nodes it has **confirmed exist right now**. Every icon on the
radar is a node the client itself is currently drawing on your minimap. If it is not
there, it is not on the radar.

## Support the project

If this saves you time and you'd like to say thanks, you can buy me a coffee —
entirely optional, the addon stays free either way.

- ☕ **Buy me a coffee**: <https://buymeacoffee.com/thpi>

## Features

- **Live confirmation** — every icon is a node that exists at that moment, not a
  database guess.
- **Screen-centred radar** with range rings, axes and a heading marker, turning with
  your view. Radius, icon size and grid are configurable.
- **Live tracking between scans** — node positions are held in world coordinates, so
  the icons move and rotate smoothly as you ride, independent of the scan rate.
- **Stays out of your way** — during a scan the minimap image, blips, player arrow
  and tooltip are all suppressed, and minimap clicks are disabled so no context menu
  can open under your cursor.
- **Ignores database pins** — GatherMate2's and Questie's own minimap icons are
  excluded from the measurement, so a "possible" node is never mistaken for a real
  one.
- **Nodes sharing a spot cost one sample** — the tooltip lists everything under the
  cursor, so candidates a few pixels apart are checked together, and the tooltip
  decides which of them are actually there. Where the database expects copper and
  tin has spawned, the radar shows tin.
- **Draggable control window** with start/stop and a settings button, plus a full
  options panel and `/nr`.

## Requirements

**[GatherMate2](https://www.curseforge.com/wow/addons/gathermate2) with its data
imported.** Both parts are mandatory. Install it, then run `/gathermate` → *Import*
→ tick *Mining* and *Herbalism* → *Import GatherMate2Data*.

**An active tracking ability** — *Find Minerals* or *Find Herbs*. The client draws
blips only for the tracking type that is active, and Burning Crusade allows one at
a time. NodeRadar can confirm only what the client draws.

### Why the dependency is not optional

Its node positions are the smaller half of it. NodeRadar also needs GatherMate2's
localised node names, and there is no substitute: the minimap shows blips for
things that are not nodes. A measured sweep through Stormwind returned *Auctioneer
Lympkin*, *Auctioneer Buckler*, *Auctioneer Redmuse* and *Myra Tyrngaarde* —
without a name list to check against, every auctioneer in the city would show up on
your radar as an ore vein.

## Honest limitations

- **No scanning while you hold the right mouse button.** During mouselook the client
  resolves no mouse focus, so no tooltip appears and no node can be confirmed.
  Rather than clearing the display, the radar freezes what it last confirmed until
  you let go.
- **Only nodes the database knows about.** A spawn point missing from GatherMate2's
  data is never aimed at and therefore never confirmed.
- **The minimap blinks.** Confirming a node means putting the minimap under your
  cursor for one frame per sample. With a handful of candidates that is a few frames
  every few seconds — invisible in practice, but it is there.
- **A harvested node lingers** for the scan interval plus 1.5 seconds before the
  missing confirmation expires it.

## How it works

The Lua API has no getter for minimap blips and no function that enumerates world
objects. What blips do have is a tooltip on hover — so the addon hovers them: it
makes the minimap invisible and moves it under your cursor, one sample point at a
time, and matches the resulting tooltip against GatherMate2's node names. The offset
from the minimap centre is the direction and distance to the node. The client
resolves mouse focus once per frame, so one sample costs one frame — that is the
hard limit on how fast this can be.

Source, issues and the full technical write-up:
<https://github.com/ThorbenP/wow-noderadar>

Licence: GPL-3.0-or-later.
