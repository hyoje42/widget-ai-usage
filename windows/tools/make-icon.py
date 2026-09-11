#!/usr/bin/env python3
"""Render ai-usage-widget.ico from code (no image libraries required).

The Windows host has no Python and no image tooling, so the icon is generated
here in WSL with the standard library only and committed to the repository.
Shapes are drawn from signed distance fields, which gives clean antialiasing
without supersampling. Colours mirror the widget UI palette.

Usage: python3 tools/make-icon.py [output.ico | output.png]
A .png path writes a single 256px image (used by linux/ for its .desktop entry).
"""

import math
import os
import struct
import sys
import zlib

SIZES = (256, 128, 64, 48, 32, 24, 16)

# Widget palette (see $script:Colors in ai-usage-widget.ps1).
BG_TOP = "#2E2E35"
BG_BOTTOM = "#191920"
BORDER = "#FFFFFF"
BORDER_ALPHA = 0.18
TRACK = "#FFFFFF"
TRACK_ALPHA = 0.22
CLAUDE = "#D97757"
CODEX = "#F0F0F0"

# Filled fraction of each ring. Chosen for a balanced gauge silhouette rather
# than to represent any real usage value.
OUTER_FILL = 0.70
INNER_FILL = 0.45


def rgb(hex_str):
    h = hex_str.lstrip("#")
    return tuple(int(h[i:i + 2], 16) / 255.0 for i in (0, 2, 4))


def clamp(v, lo=0.0, hi=1.0):
    return lo if v < lo else hi if v > hi else v


def round_rect_sdf(x, y, half, radius):
    """Distance to a rounded square centred on the origin."""
    dx = abs(x) - (half - radius)
    dy = abs(y) - (half - radius)
    ox, oy = max(dx, 0.0), max(dy, 0.0)
    return math.hypot(ox, oy) + min(max(dx, dy), 0.0) - radius


def ring_sdf(x, y, radius, thickness, sweep=None):
    """Distance to a ring, or to an arc with round caps when sweep is given."""
    dist = math.hypot(x, y)
    if sweep is not None:
        # Angle measured clockwise from 12 o'clock (y grows downwards).
        angle = math.atan2(x, -y)
        if angle < 0.0:
            angle += 2.0 * math.pi
        if angle > sweep:
            cap = min(
                math.hypot(x - radius * math.sin(a), y + radius * math.cos(a))
                for a in (0.0, sweep)
            )
            return cap - thickness / 2.0
    return abs(dist - radius) - thickness / 2.0


def coverage(sdf_value, size):
    """Convert a distance in normalised units to pixel coverage."""
    return clamp(0.5 - sdf_value * size)


def blend(dst, color, alpha):
    """Composite a colour over a straight-alpha RGBA pixel."""
    if alpha <= 0.0:
        return dst
    r, g, b, a = dst
    out_a = alpha + a * (1.0 - alpha)
    if out_a <= 0.0:
        return (0.0, 0.0, 0.0, 0.0)
    inv = a * (1.0 - alpha)
    return (
        (color[0] * alpha + r * inv) / out_a,
        (color[1] * alpha + g * inv) / out_a,
        (color[2] * alpha + b * inv) / out_a,
        out_a,
    )


def render(size):
    """Return straight-alpha RGBA bytes, top-down, for one icon size."""
    bg_top, bg_bottom = rgb(BG_TOP), rgb(BG_BOTTOM)
    border, track = rgb(BORDER), rgb(TRACK)
    claude, codex = rgb(CLAUDE), rgb(CODEX)

    # Two concentric rings collapse into a smudge below 64px, so the small
    # icons carry a single thicker ring instead.
    if size >= 64:
        rings = ((0.330, 0.100, claude, OUTER_FILL), (0.165, 0.090, codex, INNER_FILL))
    else:
        rings = ((0.300, 0.180, claude, 0.72),)

    # Below 64px the grey track muddies the arc instead of framing it.
    track_alpha = TRACK_ALPHA if size >= 64 else 0.0

    half, radius = 0.5, 0.22
    stroke = 1.0 / size  # Hairline border, one pixel at every size.
    out = bytearray()

    for py in range(size):
        v = (py + 0.5) / size
        y = v - 0.5
        top = blend((0, 0, 0, 0), bg_top, 1.0)
        row_bg = tuple(bg_top[i] * (1.0 - v) + bg_bottom[i] * v for i in range(3))
        for px in range(size):
            x = (px + 0.5) / size - 0.5
            pixel = (0.0, 0.0, 0.0, 0.0)

            plate = round_rect_sdf(x, y, half, radius)
            pixel = blend(pixel, row_bg, coverage(plate, size))
            if size >= 32:
                edge = max(plate, -(plate + stroke))
                pixel = blend(pixel, border, coverage(edge, size) * BORDER_ALPHA)

            for ring_r, thick, color, fill in rings:
                if track_alpha > 0.0:
                    d_track = ring_sdf(x, y, ring_r, thick)
                    pixel = blend(pixel, track, coverage(d_track, size) * track_alpha)
                d_arc = ring_sdf(x, y, ring_r, thick, fill * 2.0 * math.pi)
                pixel = blend(pixel, color, coverage(d_arc, size))

            out += bytes(int(round(clamp(c) * 255)) for c in pixel)

    del top
    return bytes(out)


def to_png(rgba, size):
    raw = bytearray()
    stride = size * 4
    for row in range(size):
        raw.append(0)  # Filter type: none.
        raw += rgba[row * stride:(row + 1) * stride]

    def chunk(tag, payload):
        body = tag + payload
        return struct.pack(">I", len(payload)) + body + struct.pack(">I", zlib.crc32(body))

    return (b"\x89PNG\r\n\x1a\n"
            + chunk(b"IHDR", struct.pack(">IIBBBBB", size, size, 8, 6, 0, 0, 0))
            + chunk(b"IDAT", zlib.compress(bytes(raw), 9))
            + chunk(b"IEND", b""))


def to_bmp(rgba, size):
    """32bpp bottom-up DIB plus AND mask, as ICO expects for small entries."""
    pixels = bytearray()
    for row in range(size - 1, -1, -1):
        base = row * size * 4
        for col in range(size):
            r, g, b, a = rgba[base + col * 4:base + col * 4 + 4]
            pixels += bytes((b, g, r, a))

    mask_stride = ((size + 31) // 32) * 4
    mask = bytearray(mask_stride * size)  # All zero: every pixel opaque-capable.

    header = struct.pack("<IiiHHIIiiII", 40, size, size * 2, 1, 32, 0,
                         len(pixels) + len(mask), 0, 0, 0, 0)
    return header + bytes(pixels) + bytes(mask)


def build(path):
    if path.lower().endswith(".png"):
        with open(path, "wb") as fh:
            fh.write(to_png(render(256), 256))
        print("wrote {0} ({1} bytes)".format(path, os.path.getsize(path)))
        return

    entries = []
    for size in SIZES:
        rgba = render(size)
        blob = to_bmp(rgba, size) if size <= 48 else to_png(rgba, size)
        entries.append((size, blob))
        print("rendered {0}x{0} ({1} bytes)".format(size, len(blob)))

    offset = 6 + 16 * len(entries)
    directory = b""
    for size, blob in entries:
        directory += struct.pack("<BBBBHHII", size & 0xFF, size & 0xFF, 0, 0,
                                 1, 32, len(blob), offset)
        offset += len(blob)

    with open(path, "wb") as fh:
        fh.write(struct.pack("<HHH", 0, 1, len(entries)))
        fh.write(directory)
        for _, blob in entries:
            fh.write(blob)
    print("wrote {0} ({1} bytes)".format(path, os.path.getsize(path)))


if __name__ == "__main__":
    target = sys.argv[1] if len(sys.argv) > 1 else os.path.join(
        os.path.dirname(os.path.dirname(os.path.abspath(__file__))),
        "ai-usage-widget.ico")
    build(target)
