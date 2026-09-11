#!/usr/bin/python3
"""Always-on-top desktop widget showing remaining Claude Code / Codex usage.

Run with the system Python (/usr/bin/python3), which ships PyGObject. See
linux/AGENTS.md and the root AGENTS.md for the rules this follows.

Modes:
  (no option)   run the widget
  --fetch-only  fetch once and print JSON (no tokens); never refreshes tokens
  --configure   detect token files and CLI paths, save config.json, print paths
  --stop        stop the running widget
  --force       replace a running widget instead of exiting
  --interval N  fetch interval in minutes (2, 5 or 10), saved to state.json
"""

import argparse
import json
import os
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))

from ai_usage_widget import core  # noqa: E402


def print_json(data):
    print(json.dumps(data, indent=2, ensure_ascii=False))


def main():
    parser = argparse.ArgumentParser(description="AI Usage Widget")
    mode = parser.add_mutually_exclusive_group()
    mode.add_argument("--fetch-only", action="store_true", help="fetch once, print JSON and exit")
    mode.add_argument("--configure", action="store_true", help="detect token files and CLIs, then exit")
    mode.add_argument("--stop", action="store_true", help="stop the running widget")
    parser.add_argument("--force", action="store_true", help="replace a running widget")
    parser.add_argument("--interval", type=int, default=0, help="fetch interval in minutes")
    args = parser.parse_args()

    if args.stop:
        print("stopped" if core.stop_running() else "not running")
        return 0

    sources = core.resolve_sources(redetect=args.configure)

    if args.configure:
        print_json({
            "config_file": core.CONFIG_FILE,
            "services": {core.SPEC[s]["key"]: {
                "enabled": sources[s]["enabled"],
                "token_file": sources[s]["token_file"],
                "token_found": os.path.isfile(sources[s]["token_file"]),
                "cli": sources[s]["cli"],
            } for s in core.SERVICES},
        })
        return 0

    if args.fetch_only:
        results = core.fetch_all(sources)
        print_json({s: {
            "status": r["status"],
            "message": r["message"],
            "five_hour": {"remaining": r["five_hour"]["remaining"],
                          "resets_at": core.iso_or_none(r["five_hour"]["resets_at"]),
                          "resets_in": core.format_countdown(r["five_hour"]["resets_at"])},
            "seven_day": {"remaining": r["seven_day"]["remaining"],
                          "resets_at": core.iso_or_none(r["seven_day"]["resets_at"]),
                          "resets_in": core.format_countdown(r["seven_day"]["resets_at"])},
        } for s, r in results.items()})
        return 0

    from ai_usage_widget import ui
    return ui.run(sources, force=args.force, interval=args.interval)


if __name__ == "__main__":
    sys.exit(main())
