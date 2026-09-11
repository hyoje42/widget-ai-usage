"""GTK 3 window of the Linux widget. Imported only when the UI runs.

Layout, colours and thresholds mirror windows/ai-usage-widget.ps1 (the
reference for shared UI elements, see the root AGENTS.md). Everything is drawn
with stock widgets and CSS: custom cairo drawing would need python3-gi-cairo,
which a default Ubuntu desktop does not ship.
"""

import os
import signal
import sys
import threading

# Window position and keep-above only work on X11, so a Wayland session runs
# the widget through XWayland. An explicit GDK_BACKEND still wins.
os.environ.setdefault("GDK_BACKEND", "x11,wayland")

import gi  # noqa: E402

gi.require_version("Gdk", "3.0")
gi.require_version("Gio", "2.0")
gi.require_version("Gtk", "3.0")
from gi.repository import GLib  # noqa: E402

from . import core  # noqa: E402

GLib.set_prgname(core.APP)  # WM_CLASS; must precede GTK initialisation.

from gi.repository import Gdk, Gio, Gtk  # noqa: E402

from . import panel  # noqa: E402

BAR_W, BAR_H = 150, 14
TAG_W = 44
RESET_W = 104
LOGO_SIZE = 22
EDGE_MARGIN = 12

# Text colours go through Pango markup; everything else lives in CSS below.
COLORS = {"text": "#F0F0F0", "dim": "#9A9A9A", "good": "#4CAF50", "warn": "#FFC107",
          "bad": "#F44336", "stale": "#707070"}
WINDOW_TAGS = {"5h": "5시간", "7d": "7일"}
STATUS_TEXT = {"ok": "", "init": "", "expired": "토큰 만료", "stale": "캐시된 값", "unset": "설정 필요"}
BAR_CLASSES = ("good", "warn", "bad")

# Scoped under the window's "aiw" class so the context menu keeps the theme.
CSS = b"""
window.aiw {
  background-color: rgba(28, 28, 30, 0.9);
  border: 1px solid rgba(255, 255, 255, 0.25);
  border-radius: 8px;
}
window.aiw.square { border-radius: 0; }
.aiw .name { font-size: 15px; font-weight: bold; }
.aiw .status { font-size: 10px; }
.aiw .reset { font-size: 12px; }
.aiw .footer { font-size: 9px; }
.aiw .tag {
  font-size: 11px; font-weight: bold; color: #F0F0F0;
  border-radius: 4px; padding: 1px 0;
}
.aiw .tag.w5h { background-color: #3B82F6; }
.aiw .tag.w7d { background-color: #8B5CF6; }
.aiw progressbar, .aiw progressbar trough, .aiw progressbar progress {
  margin: 0; padding: 0; border: none; box-shadow: none; background-image: none;
  min-width: 0; min-height: 14px;
}
.aiw progressbar trough { border-radius: 7px; background-color: rgba(255, 255, 255, 0.2); }
.aiw progressbar progress { border-radius: 7px; background-color: #707070; }
.aiw progressbar.good progress { background-color: #4CAF50; }
.aiw progressbar.warn progress { background-color: #FFC107; }
.aiw progressbar.bad progress { background-color: #F44336; }
.aiw .bar-label {
  font-size: 10px; font-weight: bold; color: #F0F0F0;
  text-shadow: 0 0 3px rgba(0, 0, 0, 0.9);
}
.aiw separator { min-height: 1px; margin: 7px 0 5px 0; background-color: rgba(255, 255, 255, 0.16); }
"""


def set_markup(label, text, color, bold=False):
    label.set_markup('<span foreground="%s"%s>%s</span>' % (
        color, ' weight="bold"' if bold else "", GLib.markup_escape_text(text)))


def bar_class(remaining, fresh):
    if remaining is None or not fresh:
        return None  # Stale grey.
    if remaining >= 50:
        return "good"
    return "warn" if remaining >= core.LOW_REMAINING else "bad"


def reset_presentation(resets_at, fresh, window, now, short=False):
    """(text, colour, bold) of a reset countdown, judged on time left only:
    close to the reset -> red and bold with an arrow (spend what is left),
    far away -> green, in between -> normal text; grey when stale."""
    text = core.format_countdown(resets_at, now, short)
    if not text:
        return "", COLORS["dim"], False
    if not fresh:
        return text, COLORS["stale"], False
    soon, far = core.RESET_THRESHOLDS[window]
    minutes_left = (resets_at - now).total_seconds() / 60.0
    if minutes_left <= soon:
        return ("↻" if short else "↻ ") + text, COLORS["bad"], True
    if minutes_left > far:
        return text, COLORS["good"], False
    return text, COLORS["text"], False


def new_label(css_class, xalign=0.0, text=""):
    label = Gtk.Label(label=text)
    label.get_style_context().add_class(css_class)
    label.set_xalign(xalign)
    return label


def new_logo(service):
    # GTK 3 renders an icon at the monitor's scale only when it is a file named
    # .svg; SVG bytes or a pixbuf are drawn at 1x and upscaled, which blurs.
    path = os.path.join(panel.LOGO_DIR, service.lower() + ".svg")
    icon = Gio.FileIcon.new(Gio.File.new_for_path(path))
    image = Gtk.Image.new_from_gicon(icon, Gtk.IconSize.LARGE_TOOLBAR)
    image.set_pixel_size(LOGO_SIZE)
    image.set_valign(Gtk.Align.CENTER)
    image.set_margin_end(8)
    return image


def new_tag(window):
    # Coloured per window so the 5-hour and 7-day rows are told apart at a glance.
    tag = new_label("tag", 0.5, WINDOW_TAGS[window])
    tag.get_style_context().add_class("w" + window)
    tag.set_size_request(TAG_W, -1)
    tag.set_valign(Gtk.Align.CENTER)
    tag.set_margin_top(3)
    tag.set_margin_bottom(3)
    tag.set_margin_end(8)
    return tag


def new_bar():
    """A gauge with its percentage overlaid; returns (container, bar, label)."""
    bar = Gtk.ProgressBar()
    bar.set_size_request(BAR_W, BAR_H)
    bar.set_valign(Gtk.Align.CENTER)
    label = new_label("bar-label", 0.5, "--")
    label.set_halign(Gtk.Align.CENTER)
    label.set_valign(Gtk.Align.CENTER)
    overlay = Gtk.Overlay()
    overlay.add(bar)
    overlay.add_overlay(label)
    overlay.set_valign(Gtk.Align.CENTER)
    overlay.set_margin_end(10)
    return overlay, bar, label


class Widget(Gtk.Window):
    def __init__(self, sources, settings, states):
        super().__init__(title=core.WINDOW_TITLE)
        self.sources, self.settings, self.states = sources, settings, states
        self.active = [s for s in core.SERVICES if sources[s]["enabled"]]
        self.fetching = False
        self.fetch_timer = self.tick_timer = self._save_pending = None
        self._quitting = False

        # A desktop widget: no frame, above other windows, on every workspace,
        # absent from the dock and the window switcher. It never takes focus, so
        # clicking it leaves keyboard focus in the window the user works in.
        self.set_decorated(False)
        self.set_resizable(False)
        self.set_keep_above(True)
        self.set_skip_taskbar_hint(True)
        self.set_skip_pager_hint(True)
        self.set_type_hint(Gdk.WindowTypeHint.UTILITY)
        self.set_accept_focus(False)
        self.stick()

        screen = self.get_screen()
        style = self.get_style_context()
        style.add_class("aiw")
        visual = screen.get_rgba_visual()
        if visual is not None and screen.is_composited():
            self.set_visual(visual)  # Transparent corners around the rounded background.
        else:
            style.add_class("square")
        provider = Gtk.CssProvider()
        provider.load_from_data(CSS)
        Gtk.StyleContext.add_provider_for_screen(screen, provider, Gtk.STYLE_PROVIDER_PRIORITY_APPLICATION)

        self.views = {}
        self.add(self._build_grid())
        self.menu = self._build_menu()
        Gtk.Widget.set_opacity(self, (100 - settings["transparency"]) / 100.0)  # Gtk.Window's is deprecated.
        self.panel = panel.Indicator(self._on_panel_available, self.show_widget, self.fetch, self.quit)

        self.add_events(Gdk.EventMask.BUTTON_PRESS_MASK)
        self.connect("button-press-event", self._on_button)
        self.connect("configure-event", self._on_configure)
        for signum in (signal.SIGTERM, signal.SIGINT):
            GLib.unix_signal_add(GLib.PRIORITY_DEFAULT, signum, self._on_signal)
        # A second launch sends SIGUSR1 to bring back a widget hidden to the top bar.
        GLib.unix_signal_add(GLib.PRIORITY_DEFAULT, signal.SIGUSR1, self._on_show_signal)

    # -- layout ------------------------------------------------------------
    def _build_grid(self):
        # Columns [label | bar | reset]; per service a header row and two gauge
        # rows, a separator between services, and a footer.
        grid = Gtk.Grid()
        grid.set_margin_start(12)
        grid.set_margin_end(12)
        grid.set_margin_top(9)
        grid.set_margin_bottom(9)
        row = 0
        for index, service in enumerate(self.active):
            if index:
                separator = Gtk.Separator(orientation=Gtk.Orientation.HORIZONTAL)
                separator.set_hexpand(True)
                grid.attach(separator, 0, row, 3, 1)
                row += 1
            header = Gtk.Box(orientation=Gtk.Orientation.HORIZONTAL)
            header.set_margin_bottom(4)
            header.pack_start(new_logo(service), False, False, 0)
            name = new_label("name")
            set_markup(name, service, COLORS["text"])
            header.pack_start(name, False, False, 0)
            status = new_label("status", 1.0)
            status.set_margin_bottom(4)
            grid.attach(header, 0, row, 2, 1)
            grid.attach(status, 2, row, 1, 1)
            row += 1
            view = {"status": status}
            for window in ("5h", "7d"):
                container, view["bar" + window], view["label" + window] = new_bar()
                view["reset" + window] = new_label("reset", 1.0)
                view["reset" + window].set_size_request(RESET_W, -1)
                grid.attach(new_tag(window), 0, row, 1, 1)
                grid.attach(container, 1, row, 1, 1)
                grid.attach(view["reset" + window], 2, row, 1, 1)
                row += 1
            self.views[service] = view
        self.footer = new_label("footer", 1.0)
        self.footer.set_margin_top(6)
        set_markup(self.footer, "시작 중...", COLORS["dim"])
        grid.attach(self.footer, 0, row, 3, 1)
        return grid

    def _build_menu(self):
        menu = Gtk.Menu()
        refresh = Gtk.MenuItem(label="지금 갱신")
        refresh.connect("activate", lambda _item: self.fetch())
        menu.append(refresh)
        for title, choices, current, label_of, handler in (
                ("갱신 주기", core.INTERVAL_CHOICES, self.settings["interval"],
                 lambda m: "%d분" % m, self.set_interval),
                ("투명도", core.TRANSPARENCY_CHOICES, self.settings["transparency"],
                 lambda t: "없음" if t == 0 else "%d%%" % t, self.set_transparency)):
            submenu, group = Gtk.Menu(), None
            for value in choices:
                item = Gtk.RadioMenuItem.new_with_label_from_widget(group, label_of(value))
                group = item
                item.set_active(value == current)
                item.connect("toggled", lambda i, v=value, h=handler: i.get_active() and h(v))
                submenu.append(item)
            parent = Gtk.MenuItem(label=title)
            parent.set_submenu(submenu)
            menu.append(parent)
        self.hide_item = Gtk.MenuItem(label="상단바로 숨기기")
        self.hide_item.set_sensitive(False)  # Until the top bar is known to show indicators.
        self.hide_item.connect("activate", lambda _item: self.hide_to_panel())
        menu.append(self.hide_item)
        menu.append(Gtk.SeparatorMenuItem())
        quit_item = Gtk.MenuItem(label="종료")
        quit_item.connect("activate", lambda _item: self.quit())
        menu.append(quit_item)
        menu.show_all()
        return menu

    def _place(self):
        # Saved position, or the bottom-right corner of the primary work area;
        # clamped onto the monitors so a detached screen never hides the widget.
        display = Gdk.Display.get_default()
        size = self.get_preferred_size()[1]
        if self.settings["left"] is not None and self.settings["top"] is not None:
            x, y = self.settings["left"], self.settings["top"]
        else:
            monitor = display.get_primary_monitor() or display.get_monitor(0)
            area = monitor.get_workarea()
            x = area.x + area.width - size.width - EDGE_MARGIN
            y = area.y + area.height - size.height - EDGE_MARGIN
        rects = [display.get_monitor(i).get_geometry() for i in range(display.get_n_monitors())]
        right = max(r.x + r.width for r in rects) - size.width
        bottom = max(r.y + r.height for r in rects) - size.height
        x = max(min(r.x for r in rects), min(x, right))
        y = max(min(r.y for r in rects), min(y, bottom))
        self.move(x, y)
        self.settings["left"], self.settings["top"] = x, y
        core.log("widget placed at %d,%d size %dx%d" % (x, y, size.width, size.height))

    # -- events --------------------------------------------------------------
    def _on_button(self, _widget, event):
        if event.type != Gdk.EventType.BUTTON_PRESS:
            return False
        if event.button == 1:
            self.begin_move_drag(event.button, int(event.x_root), int(event.y_root), event.time)
            return True
        if event.button == 3:
            self.menu.popup_at_pointer(event)
            return True
        return False

    def _on_configure(self, *_args):
        # Moves arrive as a burst of configure events; save once they settle.
        if self._save_pending is None:
            self._save_pending = GLib.timeout_add(800, self._save_position)
        return False

    def _save_position(self):
        self._save_pending = None
        if not self.get_visible():
            return False  # A hidden window has no position worth saving.
        x, y = self.get_position()
        if (x, y) != (self.settings["left"], self.settings["top"]):
            self.settings["left"], self.settings["top"] = x, y
            core.save_state(self.settings, self.states)
        return False

    def _on_signal(self, *_args):
        self.quit()
        return GLib.SOURCE_REMOVE

    def _on_show_signal(self, *_args):
        core.log("asked to show by another launch")
        self.show_widget()
        return GLib.SOURCE_CONTINUE

    # -- top bar -------------------------------------------------------------
    def _on_panel_available(self, available):
        self.hide_item.set_sensitive(available)
        self._apply_mode()

    def _apply_mode(self):
        # Hidden only while the top bar shows the indicator, so the widget is
        # never lost when the extension is off or GNOME Shell restarts.
        in_panel = self.settings["hidden"] and self.panel.available
        self.panel.set_active(in_panel)
        if in_panel and self.get_visible():
            self.hide()
        elif not in_panel and not self.get_visible():
            self.move(self.settings["left"], self.settings["top"])
            self.show()

    def hide_to_panel(self):
        if not self.panel.available:
            return
        self.settings["left"], self.settings["top"] = self.get_position()
        self.settings["hidden"] = True
        core.save_state(self.settings, self.states)
        core.log("hidden to the top bar")
        self._apply_mode()

    def show_widget(self):
        if self.settings["hidden"]:
            self.settings["hidden"] = False
            core.save_state(self.settings, self.states)
            core.log("shown from the top bar")
        self._apply_mode()

    # -- fetching and rendering -------------------------------------------
    def start(self):
        self.get_child().show_all()  # Children must be visible before measuring.
        self.update_view()
        self._place()
        self.panel.start()
        # A widget hidden to the top bar waits for the top bar's answer
        # (_on_panel_available) instead of flashing on screen first.
        if not self.settings["hidden"]:
            self.show()
        self.fetch()
        self.fetch_timer = GLib.timeout_add_seconds(self.settings["interval"] * 60, self._on_fetch_timer)
        self.tick_timer = GLib.timeout_add_seconds(30, self._on_tick)

    def fetch(self):
        if self.fetching:
            return
        self.fetching = True
        set_markup(self.footer, "갱신 중...", COLORS["dim"])
        # A refresh can run a CLI for minutes; keep the UI responsive meanwhile.
        threading.Thread(target=self._fetch_worker, daemon=True).start()

    def _fetch_worker(self):
        try:
            results = core.fetch_all(self.sources, allow_refresh=True, backoff=True)
        except Exception as exc:  # Last safety net: never let a fetch kill the widget.
            core.log("fetch failed: %s" % exc)
            results = None
        GLib.idle_add(self._apply_results, results)

    def _apply_results(self, results):
        self.fetching = False
        if results:
            for service in core.SERVICES:
                core.merge_result(self.states[service], results[service])
        self.update_view()
        core.save_state(self.settings, self.states)
        return False

    def _on_fetch_timer(self):
        self.fetch()
        return True

    def _on_tick(self):
        for service in core.SERVICES:
            core.apply_local_resets(self.states[service])
        self.update_view()
        return True

    def update_view(self):
        # Fills the widget and the top bar image from the same presentation rules.
        now = core.now_utc()
        rows, problems = [], []
        for service in self.active:
            state, view = self.states[service], self.views[service]
            fresh = state["status"] == "ok"
            cells = []
            for window, number in (("5h", "5"), ("7d", "7")):
                remaining = state["remaining" + number]
                bar = view["bar" + window]
                bar.set_fraction(0.0 if remaining is None else remaining / 100.0)
                bar_style = bar.get_style_context()
                for css_class in BAR_CLASSES:
                    bar_style.remove_class(css_class)
                css_class = bar_class(remaining, fresh)
                if css_class:
                    bar_style.add_class(css_class)
                percent = "--" if remaining is None else "%d%%" % remaining
                view["label" + window].set_text(percent)
                text, color, bold = reset_presentation(state["reset" + number], fresh, window, now)
                set_markup(view["reset" + window], text, color, bold)
                left, left_color, left_bold = reset_presentation(state["reset" + number], fresh, window, now, True)
                cells.append({"window": window, "pct": percent, "pct_color": COLORS[css_class or "stale"],
                              "left": left, "left_color": left_color, "left_bold": left_bold})
            rows.append({"service": service, "cells": cells})
            status = state["status"]
            text = STATUS_TEXT.get(status, "오류: " + state["message"])
            set_markup(view["status"], text, COLORS["dim"] if status in ("ok", "init") else COLORS["warn"])
            if text:
                problems.append("%s %s" % (service, text))
        if self.fetching:
            info = "갱신 중..."
        else:
            times = [self.states[s]["updated_at"] for s in self.active if self.states[s]["updated_at"]]
            if times:
                info = "%s 갱신  ·  %d분마다" % (max(times).astimezone().strftime("%H:%M"), self.settings["interval"])
            else:
                info = "데이터 없음  ·  %d분마다" % self.settings["interval"]
            set_markup(self.footer, info, COLORS["dim"])
        self.panel.update(rows, "  ·  ".join([info] + problems))

    def set_interval(self, minutes):
        self.settings["interval"] = minutes
        if self.fetch_timer:
            GLib.source_remove(self.fetch_timer)
        self.fetch_timer = GLib.timeout_add_seconds(minutes * 60, self._on_fetch_timer)
        self.update_view()
        core.save_state(self.settings, self.states)
        core.log("interval set to %dm" % minutes)

    def set_transparency(self, percent):
        self.settings["transparency"] = percent
        Gtk.Widget.set_opacity(self, (100 - percent) / 100.0)
        core.save_state(self.settings, self.states)
        core.log("transparency set to %d%%" % percent)

    def quit(self):
        if self._quitting:
            return
        self._quitting = True
        for source in (self.fetch_timer, self.tick_timer, self._save_pending):
            if source:
                GLib.source_remove(source)
        if self.get_visible():
            self.settings["left"], self.settings["top"] = self.get_position()
        core.save_state(self.settings, self.states)
        self.panel.stop()
        core.log("widget closed")
        Gtk.main_quit()


def run(sources, force=False, interval=0):
    if Gdk.Display.get_default() is None:
        print("no display available", file=sys.stderr)
        return 1
    # SIGUSR1 kills by default: ignore it until the widget installs its handler,
    # since the pid file is written as soon as the lock is taken.
    signal.signal(signal.SIGUSR1, signal.SIG_IGN)
    lock = core.InstanceLock()
    if not lock.acquire():
        # A running widget stays where the user left it; a second launch would
        # only restart the fetch cycle (and rapid restarts trip HTTP 429). It
        # only asks the running one to show itself, in case it hides in the top bar.
        if not force:
            pid = core.running_pid()
            if pid is not None:
                try:
                    os.kill(pid, signal.SIGUSR1)
                except OSError:
                    pass
            core.log("already running pid=%s; asked it to show" % pid)
            print("already running", file=sys.stderr)
            return 0
        core.stop_running()
        for _ in range(50):
            if lock.acquire():
                break
            GLib.usleep(100_000)
        else:
            core.log("could not replace the running widget")
            return 1
    try:
        settings, states = core.load_state()
        if interval:
            if interval in core.INTERVAL_CHOICES:
                settings["interval"] = interval
            else:
                core.log("ignoring unsupported interval %dm; using %dm" % (interval, settings["interval"]))
        core.log("widget starting pid=%d interval=%dm" % (os.getpid(), settings["interval"]))
        Widget(sources, settings, states).start()
        Gtk.main()
    finally:
        lock.release()
    return 0
