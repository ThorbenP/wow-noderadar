#!/usr/bin/env python3
"""Generates NodeRadar/MinimapTiles.lua from the wowdev community listfile.

Usage: tools/gen_minimap_tiles.py community-listfile.csv NodeRadar/MinimapTiles.lua
The listfile: https://github.com/wowdev/wow-listfile/releases (community-listfile.csv)
"""
import re, sys
tiles = {}
for line in open(sys.argv[1]):
    m = re.match(r"(\d+);world/minimaps/(azeroth|kalimdor)/map(\d+)_(\d+)\.blp$", line.strip(), re.I)
    if m:
        tiles.setdefault(m.group(2).capitalize(), []).append((int(m.group(3)) * 64 + int(m.group(4)), int(m.group(1))))
out = ["local ADDON, NR = ...", "",
       "-- Minimap tile file ids per continent, keyed column * 64 + row (map<column>_<row>), from",
       "-- the wowdev community listfile, written by tools/gen_minimap_tiles.py; do not edit.",
       "NR.MINIMAP_TILES = {"]
for name in sorted(tiles):
    out.append("\t%s = {" % name)
    entries = ["[%d]=%d" % kv for kv in sorted(tiles[name])]
    for i in range(0, len(entries), 8):
        out.append("\t\t" + ",".join(entries[i:i+8]) + ",")
    out.append("\t},")
out.append("}")
open(sys.argv[2], "w").write("\n".join(out) + "\n")
print({k: len(v) for k, v in tiles.items()})
