# NodeRadar

**Never ride past a herb or ore vein again.** NodeRadar takes the herb and ore nodes
from your minimap and shows them on a big radar around your character — turning with
your view, with the distance in yards next to every icon.

Made for **World of Warcraft: Forever**. Classic Era and TBC Anniversary are covered
by version 1.2.1.

## Features

- **Big, clear radar** in the middle of your screen instead of tiny yellow dots on
  the minimap
- **Only what is really there** — every icon is a node your minimap shows right now;
  a node someone else just gathered disappears
- **A sound** when a new node you can gather comes into range
- **Skill colours** — nodes beyond your skill show red, or can be hidden entirely,
  just like grey nodes that no longer give a skill-up
- **Pick your herbs and ores** — one checkbox each
- **Required skill in the minimap tooltip** — hover a node and see "Requires Mining
  (75)", coloured from red to grey
- **Faster with GatherMate2** — if it is installed, NodeRadar checks its spawn points
  first, including GatherMate2_Data, which it loads by itself
- **Light on performance**, available in all client languages

## Installation

Install it with the CurseForge app, or copy the `NodeRadar` folder into
`World of Warcraft/_forever_/Interface/AddOns/`.

## Getting started

1. Turn on **Find Herbs** or **Find Minerals**.
2. Click **Start scanning** in the small NodeRadar window, or type `/nr`.

## Commands

| Command | What it does |
|---|---|
| `/nr` | start or stop the radar |
| `/nr options` | open the settings |
| `/nr debug` | copy a diagnostic report for a bug report |

## Settings

Open them with `/nr options`, the gear button in the NodeRadar window, or
*Options → AddOns → NodeRadar*.

- **Radar** — size, icon size, opacity, distances, range rings
- **Which nodes** — hide nodes beyond your skill or without a skill-up, choose herbs
  and ores
- **Hints** — highlight and sound for new nodes, red icons, skill in the tooltip
- **General** — the NodeRadar window, start on login, hide in combat

## FAQ

**The radar stays empty.**
Check that Find Herbs or Find Minerals is active — NodeRadar tells you in chat if it
is not. Inside dungeons and raids the radar does not work.

**A node on my minimap does not show up on the radar.**
NodeRadar knows all classic herbs and ores. A name it does not know yet is learned
the first time you gather that node, and shows from then on. Also check *Which nodes*
in the settings.

**Why does my minimap blink?**
To read a node, NodeRadar moves the minimap under your mouse cursor for a moment —
every few seconds, and a little longer when a new node turns up. Nothing is ever
read while the cursor is on a window, a bar, or something in the world.

**Do I need GatherMate2?**
No. With GatherMate2 — and GatherMate2_Data, if it has spawn points for your area —
new nodes show up sooner, because NodeRadar looks at the known spawn points first.

## Known limitations

- Does not work inside instances.
- Nodes are only read while the mouse cursor rests on open world: not while you turn
  the camera with a mouse button held, and not while the cursor is on a window, a bar
  or something in the world you are pointing at.

## Bug reports and feedback

Type `/nr debug`, press Ctrl+C, and paste the report into an
[issue](https://github.com/ThorbenP/wow-noderadar/issues).

## Support the project

NodeRadar is free and stays free. If it saves you time and you'd like to say thanks:
☕ [Buy me a coffee](https://buymeacoffee.com/thpi)

## Development

- `just sync [flavor]` copies the addon into the local game folder (`forever` by
  default); `/reload` in game picks it up.
- `just build` packages `dist/NodeRadar-v<version>.zip` for upload.
- How it reads the minimap: Forever lets addons read the minimap's mouseover only
  under the real cursor (`Minimap:UpdateMouseoverAtPoint` was disabled in build
  70862), and resolves it once per frame. So for one reading NodeRadar moves the
  minimap — invisible, its icons shrunk, addon pins switched off — under the resting
  cursor and reads `C_TooltipInfo.GetMinimapMouseover` the next frame; the map is back in its
  place once a burst of readings ends. Other minimap addons' hooks are bypassed with
  the frame type's own methods.
  - A node's hit square is a fixed 16 screen pixels. Shrunk to about 21 pixels most
    of the map fits under one, so a single reading counts every node in a square
    around the player. The presence check reads that square and one pushed to each
    side - together the whole reach - and compares the counts with what the radar
    shows: every twenty seconds, and when a GatherMate2 spawn point comes into reach.
  - A burst of readings starts at most every five seconds. The map is resized off
    screen a frame before it goes under the cursor and stays away until the burst
    ends. Alpha does not reach the icons the client draws itself - nodes, town and
    quest markers, the player arrow - so `SetIconScale` shrinks them out of sight
    while the map is away.
  - Only a difference costs more readings: known spawn points from GatherMate2 first,
    otherwise a quadtree search whose quadrants are each read with a hit square a
    quarter wider than they are, on a map that grows to 1400 pixels for the last
    steps.
  - A successful gathering cast removes its node at once. A node found again where
    one was taken off the radar within two minutes is the same node, without sound
    or highlight. Nodes are kept in world coordinates.

## Credits and licence

GPL-3.0-or-later, see [LICENSE](LICENSE). The node name list
(`NodeRadar/Nodes.lua`) is based on [Spotnick's
NodeRadar](https://github.com/Spotnick2/NodeRadar) under the MIT License; its licence
text is in that file.
