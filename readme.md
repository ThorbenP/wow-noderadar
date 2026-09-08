# NodeRadar

Shows the herb and ore nodes that **actually exist** around your character, on a
radar centred on the screen — so you stop missing the little yellow dots on the
minimap while you ride past them.

For WoW Burning Crusade Classic / TBC Anniversary (client 2.5.6, interface
`20506`).

## Support the project

If this saves you time and you'd like to say thanks, you can buy me a coffee —
entirely optional, the addon stays free either way.

- ☕ **Buy me a coffee**: <https://buymeacoffee.com/thpi>

## Requirements

**[GatherMate2](https://www.curseforge.com/wow/addons/gathermate2), with its data
imported.** Both parts are mandatory; NodeRadar disables itself and says so if
GatherMate2 is missing.

Import once after installing: `/gathermate` → *Import* → tick *Mining* and
*Herbalism* → *Import GatherMate2Data*.

**An active tracking ability** — *Find Minerals* or *Find Herbs*. The client draws
minimap blips only for the tracking type that is currently active, and Burning
Crusade allows exactly one at a time. NodeRadar can only confirm what the client
is willing to draw.

### Why GatherMate2 cannot be optional

Its node positions are the smaller half of it. NodeRadar also needs GatherMate2's
**localised node names**, and there is no substitute: the minimap shows blips for
things that are not nodes at all. A measured sweep through Stormwind returned
`Auctioneer Lympkin`, `Auctioneer Buckler`, `Auctioneer Redmuse` and
`Myra Tyrngaarde` — without a name list to check against, every auctioneer in the
city would appear on your radar as an ore vein.

On top of that it supplies the HereBeDragons coordinate maths behind every yard
distance, the minimap's yards-per-zoom table, the tracking distance, and the node
icons.

## Installation

Copy the `NodeRadar` folder into `Interface/AddOns/`, or install through the
CurseForge app.

## Usage

| Command | Effect |
|---|---|
| `/nr` | start and stop the radar |
| `/nr options` | open the settings |
| `/nr debug` | write a diagnostic snapshot into the SavedVariables |

A small draggable control window with a start/stop button and a settings button is
shown by default; it can be turned off in the options.

## Options

`/nr options`, the gear on the control window, or
Esc → Interface → AddOns → NodeRadar.

- Show the control window
- Show the radar grid — range rings and axes
- Show distance in yards on each icon
- Start automatically on login
- Radar radius, 100–400 px
- Icon size, 8–40 px
- Seconds between scans, 0.5–10 s
- Restore defaults

## How it works

The Lua API exposes no way to read minimap tracking blips: there is no getter for
blip positions, and no function enumerates world objects. What blips do have is a
**tooltip on hover**.

So NodeRadar hovers them. It takes the minimap, makes it invisible, and moves it
under your mouse cursor one sample point at a time — the cursor cannot be moved by
an addon, so the minimap comes to the cursor instead. When a tooltip appears, its
text is matched against GatherMate2's node names, and the offset from the minimap
centre gives direction and distance to the node.

GatherMate2's imported positions are what aims those samples: a pass costs one
sample per candidate. The database supplies the candidate list and the exact
position, the tooltip supplies the proof that the node is there right now.

The client resolves mouse focus once per frame, so one sample costs one frame.
That is the hard limit on how fast this can be.

Two details fall out of that design:

- **Nodes sharing a spot cost one sample, not several.** The tooltip lists
  everything under the cursor — three auctioneers in one text is a measured case —
  so candidates within a few pixels of each other share a single sample point, and
  each node named in the resulting tooltip claims the candidate it fits.
- **The tooltip outranks the database.** If the database expects copper where tin
  has spawned, the radar shows tin.

### What the scan hides while it runs

Everything: the map image via alpha, the tracking blips and the player arrow via a
transparent texture, the tooltip via its alpha, and mouse clicks via
`SetMouseClickEnabled(false)` so the minimap's context menu cannot open under your
cursor. Addon pins on the minimap — GatherMate2's own icons, Questie's — have their
mouse interaction switched off for the duration, because their tooltips sit exactly
where a node is only *expected* and would otherwise be read as confirmed nodes.
Everything is restored when the pass ends.

## Limitations

- **No scanning while you hold the right mouse button.** During mouselook the
  client resolves no mouse focus at all, so no tooltip appears — measured: 22
  samples produced 0 tooltips against a 24% baseline. Instead of dropping the
  display, hit expiry pauses while scanning is impossible, so the radar keeps
  showing what it last confirmed until you let go.
- **Only nodes the database knows about.** A spawn point missing from
  GatherMate2's data is never aimed at and therefore never confirmed.
- **One tracking type at a time**, which is a Burning Crusade limitation, not an
  addon one.
- **A harvested node lingers** for the scan interval plus 1.5 seconds, until the
  missing confirmation lets it expire.
- **The minimap disappears briefly** during each pass — one frame per sample.

## Reporting a bug

Run `/nr debug`, then `/reload`, and attach
`WTF/Account/<account>/SavedVariables/NodeRadar.lua` to the issue. It records the
scan geometry, the candidate list with distances and confirmation state, the
cluster sizes, and a rolling log of distinct tooltips with the reason each one was
accepted or rejected.

## Licence

GPL-3.0-or-later. See [LICENSE](LICENSE).
