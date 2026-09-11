#!/usr/bin/env bash
# Install or update the AI Usage Widget for the current Linux user.
#
# Idempotent. Copies the widget to $XDG_DATA_HOME/ai-usage-widget, detects token
# files and CLI paths (cached in config.json), registers an autostart entry and
# an application menu entry, then restarts the widget.
#
# Usage: linux/install.sh [--no-start]
set -euo pipefail

PYTHON=/usr/bin/python3
src="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
data_home="${XDG_DATA_HOME:-$HOME/.local/share}"
config_home="${XDG_CONFIG_HOME:-$HOME/.config}"
install_dir="$data_home/ai-usage-widget"
widget="$install_dir/ai-usage-widget.py"
icon="$install_dir/ai-usage-widget.png"

start=1
for arg in "$@"; do
  case "$arg" in
    --no-start) start=0 ;;
    *) echo "unknown option: $arg" >&2; exit 2 ;;
  esac
done

if ! "$PYTHON" -c 'import gi; gi.require_version("Gtk", "3.0"); gi.require_version("GdkPixbuf", "2.0")' 2>/dev/null; then
  echo "System Python lacks the GTK 3 bindings. Install them with:" >&2
  echo "  sudo apt install python3-gi gir1.2-gtk-3.0" >&2
  exit 1
fi

echo "Source:  $src"
echo "Install: $install_dir"

# Stop the running instance before overwriting its files.
if [ -f "$widget" ]; then
  echo "Previous instance: $("$PYTHON" "$widget" --stop)"
fi

mkdir -p "$install_dir/ai_usage_widget"
rm -rf "$install_dir/ai_usage_widget/__pycache__"
install -m 755 "$src/ai-usage-widget.py" "$widget"
install -m 644 "$src"/ai_usage_widget/*.py "$install_dir/ai_usage_widget/"
mkdir -p "$install_dir/ai_usage_widget/logos"
install -m 644 "$src"/ai_usage_widget/logos/*.svg "$install_dir/ai_usage_widget/logos/"
install -m 644 "$src/ai-usage-widget.png" "$icon"
install -m 755 "$src/uninstall.sh" "$install_dir/uninstall.sh"

# Prints file paths and flags only, never a token value.
layout="$("$PYTHON" "$widget" --configure)"
echo "Token locations:"
printf '%s\n' "$layout" | sed 's/^/  /'
if printf '%s' "$layout" | grep -q '"token_found": false'; then
  echo "WARNING: no token file for at least one service. Log in to that CLI and run this" >&2
  echo "installer again, or set its \"enabled\" to false in $config_home/ai-usage-widget/config.json." >&2
fi
if printf '%s' "$layout" | grep -q '"cli": ""'; then
  echo "WARNING: a CLI was not found, so its expired token cannot be refreshed." >&2
fi

# Entries are rewritten on every install so changes propagate. Neither passes
# --force: launching from the menu while the widget runs does nothing.
write_entry() {
  mkdir -p "$(dirname "$1")"
  cat > "$1" <<EOF
[Desktop Entry]
Type=Application
Name=AI Usage Widget
Comment=Remaining Claude Code / Codex usage
Exec="$PYTHON" "$widget"
Icon=$icon
Terminal=false
Categories=Utility;
StartupNotify=false
StartupWMClass=ai-usage-widget
$2
EOF
  echo "Entry:   $1"
}
write_entry "$config_home/autostart/ai-usage-widget.desktop" "X-GNOME-Autostart-enabled=true"
write_entry "$data_home/applications/ai-usage-widget.desktop" ""

if [ "$start" = 1 ]; then
  # Detached from this terminal; --force replaces an instance started elsewhere.
  setsid -f "$PYTHON" "$widget" --force </dev/null >/dev/null 2>&1
  echo "Started widget."
fi
echo "Done."
