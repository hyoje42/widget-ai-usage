#!/usr/bin/python3
"""Dev tool: capture the running widget window to PNG (X11 / XWayland).

Finds the window by its title with xwininfo and reads that screen area from the
root window, so the PNG shows the widget as composited over the desktop.

Usage: linux/tools/capture-widget.py [output.png] [--wait SECONDS]
Output defaults to <tmp>/widget-window.png. Not installed with the widget.
"""

import argparse
import os
import re
import subprocess
import sys
import tempfile
import time

os.environ.setdefault("GDK_BACKEND", "x11")

import gi  # noqa: E402

gi.require_version("Gdk", "3.0")
gi.require_version("Gtk", "3.0")
from gi.repository import Gdk, Gtk  # noqa: E402,F401  (importing Gtk initialises GDK)

TITLE = "AI Usage Widget"
KEYS = ("Absolute upper-left X", "Absolute upper-left Y", "Width", "Height")


def find_window():
    try:
        out = subprocess.run(["xwininfo", "-name", TITLE], stdout=subprocess.PIPE,
                             stderr=subprocess.DEVNULL, text=True, timeout=5).stdout
    except (OSError, subprocess.SubprocessError):
        return None
    fields = dict(re.findall(r"^\s*(%s):\s+(-?\d+)" % "|".join(KEYS), out, re.M))
    return tuple(int(fields[key]) for key in KEYS) if len(fields) == len(KEYS) else None


def main():
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    parser.add_argument("output", nargs="?", default=os.path.join(tempfile.gettempdir(), "widget-window.png"))
    parser.add_argument("--wait", type=float, default=0.0, help="seconds to wait for the window")
    args = parser.parse_args()

    if Gdk.Display.get_default() is None:
        print("no X11 display available", file=sys.stderr)
        return 1
    deadline = time.monotonic() + args.wait
    geometry = find_window()
    while geometry is None and time.monotonic() < deadline:
        time.sleep(0.2)
        geometry = find_window()
    if geometry is None:
        print("window not found", file=sys.stderr)
        return 1
    time.sleep(0.5)  # Let the first frame render before reading the screen.

    x, y, width, height = geometry
    root = Gdk.get_default_root_window()
    scale = root.get_scale_factor()
    pixbuf = Gdk.pixbuf_get_from_window(root, x // scale, y // scale, width // scale, height // scale)
    pixbuf.savev(args.output, "png", [], [])
    print("captured %dx%d at %d,%d -> %s" % (width, height, x, y, args.output))
    return 0


if __name__ == "__main__":
    sys.exit(main())
