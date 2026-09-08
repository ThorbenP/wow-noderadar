#!/usr/bin/env python3
"""Renders the CurseForge project icon: the addon's radar as a standalone symbol.

Drawn analytically - coverage comes from distance functions, so edges are smooth
without supersampling. No third party imaging library is required.
"""
import math
import struct
import zlib

SIZE = 400
CENTER = (SIZE - 1) / 2.0
RADIUS = 168.0
GRID = (160, 240, 190)
ORE = (255, 202, 110)
HERB = (150, 242, 150)

# angle in degrees, distance as a fraction of the radar radius, colour
NODES = [
    (35, 0.42, ORE),
    (150, 0.70, HERB),
    (255, 0.55, ORE),
    (310, 0.86, HERB),
    (98, 0.90, ORE),
]
RINGS = (1 / 3, 2 / 3, 1.0)


def clamp(value, low=0.0, high=1.0):
    return low if value < low else high if value > high else value


def band(distance, target, half_width, feather=1.1):
    """Coverage of a soft-edged band centred on `target`."""
    return clamp(1.0 - (abs(distance - target) - half_width) / feather)


def blend(base, colour, alpha):
    if alpha <= 0:
        return base
    return tuple(base[i] + (colour[i] - base[i]) * alpha for i in range(3))


def render():
    rows = []
    node_points = [
        (CENTER + math.cos(math.radians(a)) * RADIUS * f,
         CENTER - math.sin(math.radians(a)) * RADIUS * f, colour)
        for a, f, colour in NODES
    ]

    for y in range(SIZE):
        row = bytearray()
        for x in range(SIZE):
            dx, dy = x - CENTER, y - CENTER
            distance = math.hypot(dx, dy)

            # background: dark, slightly lighter towards the centre
            fade = clamp(distance / (SIZE / 2))
            pixel = (14 - 7 * fade, 18 - 9 * fade, 20 - 10 * fade)

            # the radar's own disc
            pixel = blend(pixel, (24, 48, 42), 0.6 * clamp((RADIUS + 2 - distance) / 3))

            # sweep wedge, suggesting the scan in progress
            if distance <= RADIUS:
                angle = math.degrees(math.atan2(-dy, dx)) % 360
                lead = (angle - 62) % 360
                if lead <= 58:
                    strength = (1.0 - lead / 58) ** 1.7
                    pixel = blend(pixel, GRID, 0.20 * strength * clamp((RADIUS - distance) / 6 + 1))

            # range rings and axes
            for fraction in RINGS:
                pixel = blend(pixel, GRID, 0.5 * band(distance, RADIUS * fraction, 0.9))
            pixel = blend(pixel, GRID, 0.6 * band(distance, RADIUS, 1.3))
            if distance <= RADIUS:
                pixel = blend(pixel, GRID, 0.26 * band(abs(dy), 0, 0.6))
                pixel = blend(pixel, GRID, 0.26 * band(abs(dx), 0, 0.6))

            # nodes: a soft glow with a bright core
            # generous glow and core: the icon is shown as a thumbnail, where small
            # dots disappear
            for nx, ny, colour in node_points:
                d = math.hypot(x - nx, y - ny)
                pixel = blend(pixel, colour, 0.75 * clamp(1.0 - d / 21.0) ** 2)
                pixel = blend(pixel, colour, 0.95 * clamp((8.0 - d) / 2.2))
                pixel = blend(pixel, (255, 255, 255), 0.85 * clamp((4.0 - d) / 2.0))

            # player marker: a triangle pointing up, the way the radar is oriented
            ty = dy + 5
            if -11 <= ty <= 8 and abs(dx) <= (ty + 11) * 0.5:
                pixel = blend(pixel, (240, 255, 245), 0.95)

            row += bytes(int(clamp(c, 0, 255)) for c in pixel)
        rows.append(bytes(row))
    return rows


def write_png(path, rows):
    def chunk(tag, data):
        return (struct.pack(">I", len(data)) + tag + data
                + struct.pack(">I", zlib.crc32(tag + data) & 0xffffffff))

    raw = b"".join(b"\x00" + row for row in rows)
    header = struct.pack(">IIBBBBB", SIZE, SIZE, 8, 2, 0, 0, 0)
    with open(path, "wb") as handle:
        handle.write(b"\x89PNG\r\n\x1a\n"
                     + chunk(b"IHDR", header)
                     + chunk(b"IDAT", zlib.compress(raw, 9))
                     + chunk(b"IEND", b""))


if __name__ == "__main__":
    write_png("curseforge/icon.png", render())
    print("curseforge/icon.png")
