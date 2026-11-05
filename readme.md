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
- **Works with any minimap addon**, whatever size or skin
- **No dependencies**, light on performance, available in all client languages

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
- **General** — the NodeRadar window, start on login

## FAQ

**The radar stays empty.**
Check that Find Herbs or Find Minerals is active — NodeRadar tells you in chat if it
is not. Inside dungeons and raids the radar does not work.

**A node on my minimap does not show up on the radar.**
NodeRadar knows all classic herbs and ores. A name it does not know yet is learned
the first time you gather that node, and shows from then on. Also check *Which nodes*
in the settings.

**Do I need GatherMate2?**
No. NodeRadar needs no other addon.

## Known limitations

- Does not work inside instances.
- A gathered node stays on the radar for up to half a second.

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
- How it reads the minimap: twice a second it moves the minimap's mouseover across a
  grid with `Minimap:UpdateMouseoverAtPoint` (soft cursor on, so the real cursor can
  be anywhere) and reads the names with `C_TooltipInfo.GetMinimapMouseover`. A new
  node's hit square — a fixed 16 screen pixels — is measured edge to edge once, then
  the node is kept in world coordinates.

## Credits and licence

GPL-3.0-or-later, see [LICENSE](LICENSE). The node name list
(`NodeRadar/Nodes.lua`) is based on [Spotnick's
NodeRadar](https://github.com/Spotnick2/NodeRadar) under the MIT License; its licence
text is in that file.
