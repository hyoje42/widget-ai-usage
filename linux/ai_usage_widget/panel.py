"""Top bar indicator of the Linux widget, shown while the widget is hidden.

A StatusNotifierItem with a com.canonical.dbusmenu menu, spoken directly over
Gio D-Bus because the AppIndicator typelib is not part of a default Ubuntu
install. GNOME Shell shows it through the ubuntu-appindicators extension, which
draws an image at least 1.5 times wider than tall at its own size, so the whole
row (logo, window tag, percent, countdown) is one SVG file.
"""

import glob
import os
import re

import gi

gi.require_version("Pango", "1.0")
gi.require_version("PangoCairo", "1.0")
from gi.repository import Gio, GLib, Pango, PangoCairo  # noqa: E402

from . import core  # noqa: E402

LOGO_DIR = os.path.join(os.path.dirname(os.path.abspath(__file__)), "logos")

WATCHER = "org.kde.StatusNotifierWatcher"
ITEM_IFACE, ITEM_PATH = "org.kde.StatusNotifierItem", "/StatusNotifierItem"
MENU_IFACE, MENU_PATH = "com.canonical.dbusmenu", "/MenuBar"
MENU_INFO, MENU_SHOW, MENU_REFRESH, MENU_QUIT = 1, 3, 4, 6

HEIGHT, LOGO = 22, 16
TAG_SIZE, PCT_SIZE, LEFT_SIZE = 10, 13, 12
TAG_COLORS = {"5h": "#3B82F6", "7d": "#8B5CF6"}  # Same as the widget's window tags.
TEXT_COLOR = "#F0F0F0"
CELL_GAP, SERVICE_GAP = 8, 14
# Widest text each slot must hold, so the image keeps its width as values change.
LEFT_SAMPLES = ("↻59m", "↻12h", "59m", "23h", "<1m", "6d")

XML = """<node>
<interface name="org.kde.StatusNotifierItem">
  <property name="Category" type="s" access="read"/>
  <property name="Id" type="s" access="read"/>
  <property name="Title" type="s" access="read"/>
  <property name="Status" type="s" access="read"/>
  <property name="IconName" type="s" access="read"/>
  <property name="IconThemePath" type="s" access="read"/>
  <property name="ItemIsMenu" type="b" access="read"/>
  <property name="Menu" type="o" access="read"/>
  <method name="SecondaryActivate"><arg type="i" direction="in"/><arg type="i" direction="in"/></method>
  <signal name="NewIcon"/>
  <signal name="NewStatus"><arg type="s"/></signal>
</interface>
<interface name="com.canonical.dbusmenu">
  <property name="Version" type="u" access="read"/>
  <property name="TextDirection" type="s" access="read"/>
  <property name="Status" type="s" access="read"/>
  <property name="IconThemePath" type="as" access="read"/>
  <method name="GetLayout">
    <arg type="i" direction="in"/><arg type="i" direction="in"/><arg type="as" direction="in"/>
    <arg type="u" direction="out"/><arg type="(ia{sv}av)" direction="out"/>
  </method>
  <method name="GetGroupProperties">
    <arg type="ai" direction="in"/><arg type="as" direction="in"/><arg type="a(ia{sv})" direction="out"/>
  </method>
  <method name="GetProperty">
    <arg type="i" direction="in"/><arg type="s" direction="in"/><arg type="v" direction="out"/>
  </method>
  <method name="Event">
    <arg type="i" direction="in"/><arg type="s" direction="in"/><arg type="v" direction="in"/>
    <arg type="u" direction="in"/>
  </method>
  <method name="EventGroup"><arg type="a(isvu)" direction="in"/><arg type="ai" direction="out"/></method>
  <method name="AboutToShow"><arg type="i" direction="in"/><arg type="b" direction="out"/></method>
  <method name="AboutToShowGroup">
    <arg type="ai" direction="in"/><arg type="ai" direction="out"/><arg type="ai" direction="out"/>
  </method>
  <signal name="ItemsPropertiesUpdated"><arg type="a(ia{sv})"/><arg type="a(ias)"/></signal>
  <signal name="LayoutUpdated"><arg type="u"/><arg type="i"/></signal>
</interface>
</node>"""


def panel_font_family():
    source = Gio.SettingsSchemaSource.get_default()
    if source is not None and source.lookup("org.gnome.desktop.interface", True):
        name = Gio.Settings.new("org.gnome.desktop.interface").get_string("font-name")
        family = Pango.FontDescription.from_string(name).get_family()
        if family:
            return family
    return "sans-serif"


def text_width(context, family, size, bold, text):
    # librsvg lays out SVG text with Pango as well, so this matches the image.
    desc = Pango.FontDescription()
    desc.set_family(family)
    desc.set_absolute_size(size * Pango.SCALE)
    desc.set_weight(Pango.Weight.BOLD if bold else Pango.Weight.NORMAL)
    layout = Pango.Layout.new(context)
    layout.set_font_description(desc)
    layout.set_text(text, -1)
    return layout.get_pixel_size()[0]


def read_logo(service):
    """(viewBox, inner markup) of a logo file, to nest it unchanged in the row."""
    with open(os.path.join(LOGO_DIR, service.lower() + ".svg"), encoding="utf-8") as fh:
        raw = fh.read()
    view_box = re.search(r'viewBox="([^"]+)"', raw).group(1)
    inner = raw.split(">", 1)[1].rsplit("</svg>", 1)[0]
    return view_box, re.sub(r"<!--.*?-->", "", inner, flags=re.S)


def to_variants(props):
    return {key: GLib.Variant("b" if isinstance(value, bool) else "s", value) for key, value in props.items()}


def remove_file(path):
    try:
        os.remove(path)
    except OSError:
        pass


class Indicator:
    """The top bar item. on_available(bool) reports whether the shell shows
    indicators; on_show, on_refresh and on_quit are the menu actions."""

    def __init__(self, on_available, on_show, on_refresh, on_quit):
        self._on_available = on_available
        self._actions = {MENU_SHOW: on_show, MENU_REFRESH: on_refresh, MENU_QUIT: on_quit}
        self.available = self.active = False
        self._bus, self._registrations, self._watch = None, [], 0
        self._svg = self._icon = self._previous_icon = ""
        self._serial = 0
        self._info = core.WINDOW_TITLE
        self.family = panel_font_family()
        context = PangoCairo.FontMap.get_default().create_context()
        self.tag_w = max(text_width(context, self.family, TAG_SIZE, True, tag) for tag in TAG_COLORS) + 8
        self.pct_w = text_width(context, self.family, PCT_SIZE, True, "100%")
        self.left_w = max(text_width(context, self.family, LEFT_SIZE, True, text) for text in LEFT_SAMPLES)
        self.logos = {service: read_logo(service) for service in core.SERVICES}
        for path in glob.glob(os.path.join(core.RUNTIME_DIR, "panel-*.svg")):
            remove_file(path)  # Left behind by a crash.

    # -- lifecycle -----------------------------------------------------------
    def start(self):
        try:
            self._bus = Gio.bus_get_sync(Gio.BusType.SESSION, None)
            node = Gio.DBusNodeInfo.new_for_xml(XML)
            self._registrations = [
                self._bus.register_object(ITEM_PATH, node.lookup_interface(ITEM_IFACE), self._on_item_call,
                                          self._get_item_property, None),
                self._bus.register_object(MENU_PATH, node.lookup_interface(MENU_IFACE), self._on_menu_call,
                                          self._get_menu_property, None),
            ]
        except GLib.Error as exc:
            core.log("top bar unavailable: %s" % exc.message)
            GLib.idle_add(self._set_available, False)  # Callers expect an asynchronous answer.
            return
        # The watcher lives in GNOME Shell: it appears again after a shell restart.
        self._watch = Gio.bus_watch_name_on_connection(self._bus, WATCHER, Gio.BusNameWatcherFlags.NONE,
                                                       self._on_watcher_appeared, self._on_watcher_vanished)

    def stop(self):
        if self._watch:
            Gio.bus_unwatch_name(self._watch)
            self._watch = 0
        for registration in self._registrations:
            self._bus.unregister_object(registration)
        self._registrations = []
        for path in glob.glob(os.path.join(core.RUNTIME_DIR, "panel-*.svg")):
            remove_file(path)

    def _on_watcher_appeared(self, bus, _name, _owner):
        bus.call(WATCHER, "/StatusNotifierWatcher", WATCHER, "RegisterStatusNotifierItem",
                 GLib.Variant("(s)", (ITEM_PATH,)), None, Gio.DBusCallFlags.NONE, -1, None, self._on_registered)

    def _on_registered(self, bus, task):
        try:
            bus.call_finish(task)
        except GLib.Error as exc:
            core.log("top bar registration failed: %s" % exc.message)
            self._set_available(False)
            return
        self._set_available(True)

    def _on_watcher_vanished(self, _bus, _name):
        self._set_available(False)

    def _set_available(self, available):
        if available != self.available:
            core.log("top bar %s" % ("available" if available else "unavailable"))
        self.available = available
        self._on_available(available)
        return False

    # -- state ---------------------------------------------------------------
    def set_active(self, active):
        """Active shows the item in the top bar; Passive hides it."""
        if active == self.active:
            return
        self.active = active
        self._emit(ITEM_PATH, ITEM_IFACE, "NewStatus", GLib.Variant("(s)", (self._status(),)))

    def update(self, rows, info):
        """rows: [{service, cells: [{window, pct, pct_color, left, left_color, left_bold}]}]."""
        svg = self._render(rows)
        if svg != self._svg:
            self._write_icon(svg)
        if info != self._info:
            self._info = info
            changed = [(MENU_INFO, to_variants({"label": info}))]
            self._emit(MENU_PATH, MENU_IFACE, "ItemsPropertiesUpdated", GLib.Variant("(a(ia{sv})a(ias))", (changed, [])))

    def _status(self):
        return "Active" if self.active else "Passive"

    def _emit(self, path, iface, name, params):
        if self._bus is None:
            return
        try:
            self._bus.emit_signal(None, path, iface, name, params)
        except GLib.Error as exc:
            core.log("top bar signal %s failed: %s" % (name, exc.message))

    # -- image ---------------------------------------------------------------
    def _render(self, rows):
        font = GLib.markup_escape_text(self.family) + ", sans-serif"

        def text(x, y, size, bold, color, value, anchor):
            return ('<text x="%g" y="%d" font-family="%s" font-size="%d" font-weight="%s" fill="%s" '
                    'text-anchor="%s">%s</text>' % (x, y, font, size, "bold" if bold else "normal", color, anchor,
                                                   GLib.markup_escape_text(value)))

        parts, x = [], 0
        for index, row in enumerate(rows):
            if index:
                x += SERVICE_GAP - CELL_GAP
            view_box, inner = self.logos[row["service"]]
            parts.append('<svg x="%d" y="%d" width="%d" height="%d" viewBox="%s">%s</svg>'
                         % (x, (HEIGHT - LOGO) // 2, LOGO, LOGO, view_box, inner))
            x += LOGO + 5
            for cell in row["cells"]:
                parts.append('<rect x="%d" y="4" width="%d" height="14" rx="3" fill="%s"/>'
                             % (x, self.tag_w, TAG_COLORS[cell["window"]]))
                parts.append(text(x + self.tag_w / 2.0, 15, TAG_SIZE, True, TEXT_COLOR, cell["window"], "middle"))
                x += self.tag_w + 5 + self.pct_w
                parts.append(text(x, 16, PCT_SIZE, True, cell["pct_color"], cell["pct"], "end"))
                x += 4
                parts.append(text(x, 16, LEFT_SIZE, cell["left_bold"], cell["left_color"], cell["left"], "start"))
                x += self.left_w + CELL_GAP
        # The extension shows an image at its own size only when it is wide enough.
        width = max(x - CELL_GAP, HEIGHT * 2)
        return '<svg xmlns="http://www.w3.org/2000/svg" width="%d" height="%d">%s</svg>' % (width, HEIGHT, "".join(parts))

    def _write_icon(self, svg):
        # A new name per image, so no cache keyed by path can show an old one.
        self._serial += 1
        path = os.path.join(core.RUNTIME_DIR, "panel-%d.svg" % self._serial)
        try:
            os.makedirs(core.RUNTIME_DIR, exist_ok=True)
            with open(path, "w", encoding="utf-8") as fh:
                fh.write(svg)
        except OSError as exc:
            core.log("top bar image write failed: %s" % exc)
            return
        if self._previous_icon:
            remove_file(self._previous_icon)  # Keep one older image for a load still in flight.
        self._previous_icon, self._icon, self._svg = self._icon, path, svg
        self._emit(ITEM_PATH, ITEM_IFACE, "NewIcon", None)

    # -- D-Bus handlers ------------------------------------------------------
    def _get_item_property(self, _bus, _sender, _path, _iface, name):
        values = {"Category": ("s", "ApplicationStatus"), "Id": ("s", core.APP), "Title": ("s", core.WINDOW_TITLE),
                  "Status": ("s", self._status()), "IconName": ("s", self._icon), "IconThemePath": ("s", ""),
                  "ItemIsMenu": ("b", True), "Menu": ("o", MENU_PATH)}
        kind, value = values[name]
        return GLib.Variant(kind, value)

    def _on_item_call(self, _bus, _sender, _path, _iface, method, _params, invocation):
        invocation.return_value(None)
        if method == "SecondaryActivate":  # Middle click.
            self._run(MENU_SHOW)

    def _menu_items(self):
        return [(MENU_INFO, {"label": self._info, "enabled": False}),
                (2, {"type": "separator"}),
                (MENU_SHOW, {"label": "위젯 보이기"}),
                (MENU_REFRESH, {"label": "지금 갱신"}),
                (5, {"type": "separator"}),
                (MENU_QUIT, {"label": "종료"})]

    def _get_menu_property(self, _bus, _sender, _path, _iface, name):
        return {"Version": GLib.Variant("u", 3), "TextDirection": GLib.Variant("s", "ltr"),
                "Status": GLib.Variant("s", "normal"), "IconThemePath": GLib.Variant("as", [])}.get(name)

    def _on_menu_call(self, _bus, _sender, _path, _iface, method, params, invocation):
        # The menu is static apart from the info label, so the layout revision never changes.
        items = self._menu_items()
        if method == "GetLayout":
            children = [GLib.Variant("(ia{sv}av)", (item_id, to_variants(props), [])) for item_id, props in items]
            root = (0, to_variants({"children-display": "submenu"}), children)
            invocation.return_value(GLib.Variant("(u(ia{sv}av))", (1, root)))
        elif method == "GetGroupProperties":
            ids = params.unpack()[0]
            found = [(item_id, to_variants(props)) for item_id, props in items if not ids or item_id in ids]
            invocation.return_value(GLib.Variant("(a(ia{sv}))", (found,)))
        elif method == "GetProperty":
            item_id, name = params.unpack()
            props = to_variants(dict(items).get(item_id, {}))
            if name in props:
                invocation.return_value(GLib.Variant("(v)", (props[name],)))
            else:
                invocation.return_dbus_error("org.freedesktop.DBus.Error.InvalidArgs", "unknown property")
        elif method == "Event":
            item_id, event = params.unpack()[:2]
            invocation.return_value(None)
            if event == "clicked":
                self._run(item_id)
        elif method == "EventGroup":
            events = params.unpack()[0]
            invocation.return_value(GLib.Variant("(ai)", ([],)))
            for item_id, event, _data, _timestamp in events:
                if event == "clicked":
                    self._run(item_id)
        elif method == "AboutToShow":
            invocation.return_value(GLib.Variant("(b)", (False,)))
        else:  # AboutToShowGroup
            invocation.return_value(GLib.Variant("(aiai)", ([], [])))

    def _run(self, item_id):
        action = self._actions.get(item_id)
        if action:
            # After the D-Bus reply is sent: quitting tears the objects down.
            GLib.idle_add(lambda: action() and False)
