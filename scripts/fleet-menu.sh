#!/usr/bin/env bash
# fleet-menu.sh — display-menu fallback (no fzf, or tmux < 3.2 without popups).

set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LIST="$SCRIPT_DIR/fleet-list.sh"
TAB=$'\t'

menu=(display-menu -T " agents " -x C -y C)
keys=(1 2 3 4 5 6 7 8 9 0 q w e r t y u i o p)
i=0
found=0

while IFS="$TAB" read -r display pane_id; do
  [ -n "$pane_id" ] || continue
  # strip ANSI for menu labels
  label="$(printf '%s' "$display" | sed -E $'s/\x1b\\[[0-9;]*m//g')"
  key="${keys[$i]:-}"
  menu+=("$label" "$key" "switch-client -Z -t '$pane_id'")
  i=$((i + 1))
  found=1
done < <("$LIST")

if [ "$found" = "0" ]; then
  menu+=("(no agent sessions found)" "" "")
fi

exec tmux "${menu[@]}"
