# NodeRadar

**Never ride past a herb or ore vein again.** NodeRadar takes the herb and ore nodes
from your minimap and shows them on a big radar around your character — turning with
your view, with the distance in yards next to every icon.

Made for **World of Warcraft: Forever**. Classic Era and TBC Anniversary are covered
by version 1.2.1.

**Important since the November 2026 WoW Forever update:** NodeRadar has to borrow your
minimap for a split second now and then to read it — since 3.1.0 a stand-in hides that
almost completely. GatherMate2 is recommended. Read why below.

## Why the minimap blinks

In November 2026 Blizzard changed WoW Forever so that addons can no longer look at
the minimap in the background. That is exactly how NodeRadar 2.x found its nodes,
so after that update its radar stayed empty.

NodeRadar 3.0 still reads your minimap, but now it has to borrow it for a moment: it
moves the minimap under your mouse cursor for a split second, reads what is there,
and puts it straight back. That is the short blink you see where your minimap sits.
Meanwhile a stand-in covers its place: the minimap's own terrain around you, with its
frame, the buttons and pins of your addons, your arrow and dots for the nodes on the
radar and your group. It fades back into
the real minimap a moment later.

- It happens every twenty seconds, the moment a known spawn point comes into range
  (with GatherMate2), and for a little longer when a new node turns up.
- With GatherMate2, NodeRadar only looks where a node you want can spawn: no spawn
  point of one in range and none on the radar, no blink at all. Nodes your filters
  hide cost nothing. Where GatherMate2's spawn points turn out not to match a zone,
  NodeRadar ignores them there and checks every twenty seconds.
- While it is away the minimap is invisible, so nothing shows at your cursor. Quest
  areas, the group finder's eye and frames other addons attach to the minimap hide
  with it.
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
- With GatherMate2, a node standing where GatherMate2 knows no spawn point of a node
  you want is found only once such a spawn point is in range too.

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
    shows: every twenty seconds while a GatherMate2 spawn point of a node the
    filters let through is in reach or such a node is on the radar - always, without
    spawn data - and when a filter changes what it lets through. The client shows a
    node only within about 185 yards of the player, so a spawn point is read once it
    comes within 175 yards, through the square centred nearest to it alone. Nodes the
    filters hide are never looked for.
  - A burst ends when the routine waits for its next look at the spawn points, a
    quarter second later. The map is resized off screen a frame before it goes under
    the cursor and stays away until the burst ends; each reading's frame places the
    next one, so a burst takes a frame per reading plus one to settle each new size.
    Alpha does not reach the icons the client draws itself - nodes, town and quest
    markers, the player arrow - so `SetIconScale` shrinks them out of sight while the
    map is away.
  - Minimap buttons and map pins are placed by their addons from the map's width at
    that moment, so any that moved while the map was away get their anchor back, and
    the map stays in place for five seconds after a loading screen.
  - While the map is away, `StandIn.lua` draws over its place: the minimap's terrain
    tiles centred on the player at its view radius, masked to the map's shape, dots for
    the radar's nodes and the group, the player arrow, and a picture of every visible
    texture and text in the map's tree and its followers, taken as the map leaves and
    stacked at the originals' strata and levels; texts keep updating. The client
    loads the tiles only by file id; `NodeRadar/MinimapTiles.lua` maps them for both
    continents and is generated by `tools/gen_minimap_tiles.py` from the wowdev
    community listfile. Indoors and elsewhere the zone's world map art stands in. It fades out
    0.2 s after the map is back. Frames outside the minimap's tree but anchored into
    it (Blizzard's coordinates, the LFG eye, a skin's border) get alpha 0 and no
    mouse, and the `QuestPOIs` tracking is off, since quest areas ignore the map's
    alpha; `NodeRadarDB.questAreasOff` puts it back at the next login if a session
    ends mid-reading.
  - Only a difference costs more readings: known spawn points from GatherMate2 first,
    otherwise a quadtree search whose quadrants are each read with a hit square a
    quarter wider than they are, on a map that grows to 1400 pixels for the last
    steps. Three searched nodes at different spots of one zone, none near a spawn
    point there and none found at one, switch that zone's spawn points off: the
    GatherMate2 data does not match it.
  - A successful gathering cast removes its node at once. A node found again where
    one was taken off the radar within two minutes is the same node, without sound
    or highlight. Nodes are kept in world coordinates. A node in reach leaves only
    when the checks of a minute no longer confirm it; one out of reach or hidden by
    the filters after a minute.

## Credits and licence

GPL-3.0-or-later, see [LICENSE](LICENSE). The node name list
(`NodeRadar/Nodes.lua`) is based on [Spotnick's
NodeRadar](https://github.com/Spotnick2/NodeRadar) under the MIT License; its licence
text is in that file.
