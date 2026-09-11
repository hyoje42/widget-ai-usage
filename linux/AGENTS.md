# AGENTS.md (linux)

Rules for the Linux implementation. Follow them together with the root [AGENTS.md](../AGENTS.md)
(shared rules and contract). Relative paths are from `linux/`. User docs: [README.md](./README.md).

## 1. Architecture decisions (do not revert)

- **Floating GTK 3 window in Python, run by `/usr/bin/python3`** (chosen by the user, 2026-09-11). Use only what a
  default Ubuntu GNOME desktop ships: PyGObject, GTK 3, the GdkPixbuf SVG loader. No pip, no venv.
- **No custom cairo drawing.** `python3-gi-cairo` is not installed by default; without it every `draw` handler fails with
  `Couldn't find foreign struct converter for 'cairo.Context'`. Build the UI from stock widgets styled by the CSS in
  `ai_usage_widget/ui.py` (a bar is a `Gtk.ProgressBar` with an overlaid label).
- Logos are `.svg` files loaded through `Gio.FileIcon`. GTK 3 renders an icon at the HiDPI scale only when it is a file
  named `.svg`; SVG bytes (`Gio.BytesIcon`) or a pixbuf are drawn at 1x and upscaled, which blurs at scale 2.
- `GDK_BACKEND` defaults to `x11,wayland`: keep-above, `move()` and `begin_move_drag()` need X11, so a Wayland
  session runs the widget through XWayland. Not yet verified in a Wayland session (as of 2026-09-11).
- `core.py` must not import GTK, so `--fetch-only`, `--configure` and `--stop` work without a display.
- Fetches run on a worker thread; results reach widgets only through `GLib.idle_add` on the main thread.
- Token files: `$CLAUDE_CONFIG_DIR` / `$CODEX_HOME` when set, else `~/.claude`, `~/.codex`.
- CLI paths are detected (`shutil.which`, then `$SHELL -lic 'command -v <cli>'`, then common install dirs) and cached in
  `config.json`, because an autostarted session lacks the PATH nvm adds in `~/.bashrc`. Refresh runs the cached path
  with its directory prepended to PATH (npm CLIs are `#!/usr/bin/env node` scripts) and the state dir as cwd, so
  `claude -p` history does not land in a real project.
- Single instance: an `flock` on `widget.lock` guards the UI; `widget.pid` lets `--stop` find it, and
  `/proc/<pid>/cmdline` guards against pid reuse.
- Window: undecorated, `UTILITY` hint, keep-above, sticky, skip taskbar/pager, `accept_focus=False`. Mutter still sets
  `_NET_WM_STATE_DEMANDS_ATTENTION`; GNOME Shell shows no "ready" notification for skip-taskbar windows.
- Desktop entries never pass `--force`; only `install.sh`'s own launch does.
- **Top bar mode** (chosen by the user, 2026-09-11; Linux only): the widget menu's `상단바로 숨기기` hides the window and
  shows one top bar item: per service the logo, then per window a `5h`/`7d` tag, percent coloured like the bars, and a
  one-unit countdown (`25m`, `3h`, `2d`). `panel.py` speaks StatusNotifierItem and `com.canonical.dbusmenu` over Gio
  D-Bus; the AppIndicator typelib is not installed by default. The row is one SVG in `$XDG_RUNTIME_DIR`, renamed on
  every change, with slot widths measured with Pango so the item never changes width.
  - The window stays hidden only while the watcher answers, so it reappears when the extension is off or GNOME Shell
    restarts, and hides again when the watcher returns. `HiddenToPanel` in `state.json` keeps the choice.
  - Back to the window: the item's menu `위젯 보이기`, a middle click, or launching the app again (the second launch
    sends SIGUSR1; `run()` ignores SIGUSR1 until the widget installs its handler, because SIGUSR1 kills by default).

## 2. Files

```
ai-usage-widget.py        # entry point and modes (--fetch-only, --configure, --stop, --force, --interval)
ai_usage_widget/core.py   # config, fetch, refresh, state, single instance (no GTK)
ai_usage_widget/ui.py     # GTK window, CSS, menu, timers
ai_usage_widget/panel.py  # top bar item: StatusNotifierItem + dbusmenu over D-Bus, SVG row
ai_usage_widget/logos/    # claude.svg, codex.svg: path data copied verbatim from windows/ai-usage-widget.ps1
ai-usage-widget.png       # icon, generated: python3 ../windows/tools/make-icon.py ai-usage-widget.png
install.sh, uninstall.sh  # install/update (idempotent) and removal
tools/capture-widget.py   # dev only: capture the widget window to PNG (not installed)
```

- Install dir `$XDG_DATA_HOME/ai-usage-widget/`; config `$XDG_CONFIG_HOME/ai-usage-widget/config.json`; state dir
  `$XDG_STATE_HOME/ai-usage-widget/` (`state.json`, `widget.pid`, `widget.lock`, `widget.log`); top bar images
  `$XDG_RUNTIME_DIR/ai-usage-widget/panel-N.svg`; entries in `$XDG_CONFIG_HOME/autostart/` and `$XDG_DATA_HOME/applications/`.
- Test `install.sh` against scratch dirs: export `XDG_DATA_HOME`, `XDG_CONFIG_HOME`, `XDG_STATE_HOME`, pass `--no-start`,
  and check the entries with `desktop-file-validate`.

## 3. Run and verify

```bash
/usr/bin/python3 ai-usage-widget.py --fetch-only   # both services must report "ok"
/usr/bin/python3 ai-usage-widget.py --configure    # token files and CLI paths (paths only)
setsid -f /usr/bin/python3 ai-usage-widget.py --force </dev/null >/dev/null 2>&1   # (re)start detached
/usr/bin/python3 ai-usage-widget.py --stop
/usr/bin/python3 tools/capture-widget.py --wait 15 # PNG of the window; prints its geometry
```

- A launch without `setsid -f` blocks while the widget lives. Rapid restarts trip HTTP 429 (root AGENTS.md §3).
- Check UI changes by viewing the captured PNG. On HiDPI it is in device pixels (this dev machine uses scale 2).
  Redirect the widget's stderr to a file when debugging a launch; GTK and Python errors go there, not to the log.
- The log adds `fetch claude=ok codex=ok` every interval when healthy.
- Drag and the right-click menu cannot be driven from a shell here (no xdotool); ask the user to try them.
- Top bar item: find its bus name in the watcher, then click a menu item (ids in `panel.py`, 3 = `위젯 보이기`):
  ```bash
  gdbus call --session --dest org.kde.StatusNotifierWatcher --object-path /StatusNotifierWatcher \
    --method org.freedesktop.DBus.Properties.Get org.kde.StatusNotifierWatcher RegisteredStatusNotifierItems
  gdbus call --session --dest <:1.N> --object-path /MenuBar --method com.canonical.dbusmenu.Event 3 clicked '<int32 0>' 0
  ```

## 4. Environment facts

Checked on Ubuntu 24.04 GNOME, X11 session, 2026-09-11.

- `ubuntu-appindicators` (GNOME Shell 46) ignores a single left click on an item without a dbusmenu; a double click
  calls `Activate`. When the item has an `Activate` method, a single click waits out the double-click time before
  opening the menu, so `panel.py` leaves `Activate` out. Middle click calls `SecondaryActivate`. No tooltips.
- It loads an `IconName` that is an absolute path under the user's home as a file, and draws an image at least 1.5 times
  wider than tall at its own size. `Status` `Passive` hides the item. Items sit left of the system menu (`tray-pos` right).

- System Python has PyGObject (GTK 3, GTK 4, libadwaita), pycairo and the GdkPixbuf SVG loader, but not
  `python3-gi-cairo`. A user-installed Python earlier on PATH may lack `gi`.
- Importing `Gdk` without `gi.require_version("Gdk", "3.0")` loads GTK 4's Gdk and breaks the GTK 3 import.
- A clean login shell finds `claude` in `~/.local/bin` but not the nvm-installed `codex`.
- Ubuntu 26.04 LTS removed the GNOME Xorg session, so XWayland is the only X11 path there.
- Native Linux has no `powershell.exe`, so the Windows implementation cannot be run or verified here.
