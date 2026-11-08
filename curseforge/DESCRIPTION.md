# NodeRadar

**Never ride past a herb or ore vein again.** NodeRadar takes the herb and ore nodes
from your minimap and shows them on a big radar around your character — turning with
your view, with the distance in yards next to every icon.

Made for **World of Warcraft: Forever**.

**Important since the November 2026 WoW Forever update:** your minimap blinks briefly
now and then while NodeRadar reads it, and GatherMate2 is recommended. Read why
below.

## Why the minimap blinks

In November 2026 Blizzard changed WoW Forever so that addons can no longer look at
the minimap in the background. That is exactly how NodeRadar 2.x found its nodes,
so after that update its radar stayed empty.

NodeRadar 3.0 still reads your minimap, but now it has to borrow it for a moment: it
moves the minimap under your mouse cursor for a split second, reads what is there,
and puts it straight back. That is the short blink you see where your minimap sits.

- It happens every twenty seconds, when a known spawn point comes into range (with
  GatherMate2), and for a little longer when a new node turns up — but never more
  than once every five seconds. Where GatherMate2 knows no spawn point for a node you
  want, only once a minute.
- Nodes your filters hide cost nothing: NodeRadar does not look for them.
- While it is away the minimap is invisible, so nothing shows at your cursor.
- NodeRadar only does it while your mouse rests on open world. It never gets in the
  way when you point at a monster, an NPC or a node, use a window or a bar, turn the
  camera or aim a spell — it simply waits, and the radar updates a moment later.

Blizzard may restrict this further in a later update. If that happens, NodeRadar
stops finding nodes until a new way is found.

### GatherMate2 is recommended

GatherMate2 knows where herbs and ores spawn. With it, NodeRadar looks at those spots
first instead of searching your whole range: new nodes appear sooner, and the minimap
blinks for a shorter time. Install **GatherMate2** and **GatherMate2_Data**, and
import the data into GatherMate2 once — see *Getting started*. NodeRadar works
without them too.

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
  first, including those from GatherMate2_Data
- **Light on performance**, available in all client languages

## Getting started

1. **Install NodeRadar.** The CurseForge app installs GatherMate2 and
   GatherMate2_Data along with it. Installing by hand, copy the `NodeRadar` folder
   into `World of Warcraft/_forever_/Interface/AddOns/`, and get GatherMate2 and
   GatherMate2_Data from CurseForge as well.
2. **Import the spawn points into GatherMate2 once** — GatherMate2 does not do this
   on its own: *Options → AddOns → GatherMate 2 → Import → GatherMate2Data*, tick
   **Mining** and **Herbalism** under *Databases to Import*, and click **Import
   GatherMate2Data**. GatherMate2 then also shows the spots on its own maps.
3. **Turn on Find Herbs or Find Minerals.**
4. **Start the radar:** click **Start scanning** in the small NodeRadar window, or
   type `/nr`.

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

**Do I need GatherMate2?**
No, but it is recommended — see *GatherMate2 is recommended* above.

**The radar is slow to show a node.**
NodeRadar reads the minimap only while your mouse rests on open world. If the cursor
keeps moving, sits on your bars, or you steer with a mouse button held, it waits.

## Known limitations

- Does not work inside instances.
- The minimap blinks briefly now and then — see *Why the minimap blinks* above.

## Bug reports and feedback

Type `/nr debug`, press Ctrl+C, and paste the report into an issue on
[GitHub](https://github.com/ThorbenP/wow-noderadar/issues).

## Support the project

NodeRadar is free and stays free. If it saves you time and you'd like to say thanks:
☕ [Buy me a coffee](https://buymeacoffee.com/thpi)

---

Licence: GPL-3.0-or-later. Node names based on Spotnick's NodeRadar (MIT).
