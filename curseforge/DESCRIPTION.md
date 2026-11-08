# NodeRadar

**Never ride past a herb or ore vein again.** NodeRadar takes the herb and ore nodes
from your minimap and shows them on a big radar around your character — turning with
your view, with the distance in yards next to every icon.

Made for **World of Warcraft: Forever**.

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

## Getting started

1. Install NodeRadar.
2. Turn on **Find Herbs** or **Find Minerals**.
3. Click **Start scanning** in the small NodeRadar window, or type `/nr`.

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

Type `/nr debug`, press Ctrl+C, and paste the report into an issue on
[GitHub](https://github.com/ThorbenP/wow-noderadar/issues).

## Support the project

NodeRadar is free and stays free. If it saves you time and you'd like to say thanks:
☕ [Buy me a coffee](https://buymeacoffee.com/thpi)

---

Licence: GPL-3.0-or-later. Node names based on Spotnick's NodeRadar (MIT).
