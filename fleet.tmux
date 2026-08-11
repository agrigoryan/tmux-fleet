#!/usr/bin/env bash
# tmux-fleet — see every AI agent session on the tmux server, with status,
# and jump to any of them. TPM entrypoint.

CURRENT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=scripts/helpers.sh
source "$CURRENT_DIR/scripts/helpers.sh"

key="$(get_tmux_option "@fleet-key" "a")"
width="$(get_tmux_option "@fleet-width" "90%")"
height="$(get_tmux_option "@fleet-height" "75%")"

ver="$(tmux_version_num)"

if [ "$ver" -ge 33 ] 2>/dev/null; then
  tmux bind-key "$key" display-popup -E -b rounded -T " ❯ agents " \
    -w "$width" -h "$height" "$CURRENT_DIR/scripts/fleet-picker.sh"
elif [ "$ver" -ge 32 ] 2>/dev/null; then
  tmux bind-key "$key" display-popup -E \
    -w "$width" -h "$height" "$CURRENT_DIR/scripts/fleet-picker.sh"
else
  tmux bind-key "$key" run-shell "$CURRENT_DIR/scripts/fleet-menu.sh"
fi

# optional status-line integration: replace #{fleet_status} placeholder
for opt in status-right status-left; do
  val="$(tmux show-option -gqv "$opt")"
  case "$val" in
    *'#{fleet_status}'*)
      tmux set-option -g "$opt" \
        "${val//\#\{fleet_status\}/#($CURRENT_DIR/scripts/fleet-summary.sh)}"
      ;;
  esac
done
