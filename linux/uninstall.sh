#!/usr/bin/env bash
# Remove the AI Usage Widget: stop it, then delete its desktop entries, install
# directory, config, state (including the log) and top bar images. Token files
# are untouched.
set -euo pipefail

PYTHON=/usr/bin/python3
data_home="${XDG_DATA_HOME:-$HOME/.local/share}"
config_home="${XDG_CONFIG_HOME:-$HOME/.config}"
state_home="${XDG_STATE_HOME:-$HOME/.local/state}"
install_dir="$data_home/ai-usage-widget"

if [ -f "$install_dir/ai-usage-widget.py" ]; then
  echo "Widget: $("$PYTHON" "$install_dir/ai-usage-widget.py" --stop)"
fi
for entry in "$config_home/autostart/ai-usage-widget.desktop" "$data_home/applications/ai-usage-widget.desktop"; do
  if [ -e "$entry" ]; then
    rm -f "$entry"
    echo "Removed entry: $entry"
  fi
done
for dir in "$install_dir" "$config_home/ai-usage-widget" "$state_home/ai-usage-widget" \
    "${XDG_RUNTIME_DIR:+$XDG_RUNTIME_DIR/ai-usage-widget}"; do
  if [ -d "$dir" ]; then
    rm -rf "$dir"
    echo "Removed $dir"
  fi
done
echo "Done."
