#!/usr/bin/env bash
# fleet-summary.sh — status-line segment: colored per-state agent counts.
# Wire up with:  set -g status-right '#(/path/to/tmux-fleet/scripts/fleet-summary.sh) …'
# or put #{fleet_status} in status-right/status-left before loading fleet.tmux.

set -u
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

"$SCRIPT_DIR/fleet-list.sh" --states | sort | uniq -c | awk '
  { count[$2] = $1 }
  END {
    out = ""
    if (count["waiting"]) out = out "#[fg=yellow,bold]⏳" count["waiting"] " "
    if (count["error"])   out = out "#[fg=red,bold]✖"    count["error"]   " "
    if (count["done"])    out = out "#[fg=cyan,bold]✔"   count["done"]    " "
    if (count["working"]) out = out "#[fg=green]⚙"       count["working"] " "
    if (count["idle"])    out = out "#[fg=colour244]●"   count["idle"]    " "
    if (out != "") printf "%s#[default]", out
  }'
