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
picker="$(fleet_shell_quote "$CURRENT_DIR/scripts/fleet-picker.sh")"
menu="$(fleet_shell_quote "$CURRENT_DIR/scripts/fleet-menu.sh")"

if [ "$ver" -ge 33 ] 2>/dev/null; then
  tmux bind-key "$key" display-popup -E -b rounded -T " ❯ agents " \
    -w "$width" -h "$height" "$picker"
elif [ "$ver" -ge 32 ] 2>/dev/null; then
  tmux bind-key "$key" display-popup -E \
    -w "$width" -h "$height" "$picker"
else
  tmux bind-key "$key" run-shell "$menu"
fi

# optional status-line integration: replace #{fleet_status} placeholder
for opt in status-right status-left; do
  val="$(tmux show-option -gqv "$opt")"
  case "$val" in
    *'#{fleet_status}'*)
      tmux set-option -g "$opt" \
        "${val//\#\{fleet_status\}/#($(fleet_shell_quote "$CURRENT_DIR/scripts/fleet-summary.sh"))}"
      ;;
  esac
done

# Indexed hooks coexist with user hooks and remain idempotent on TPM reload.
event="$(fleet_shell_quote "$CURRENT_DIR/scripts/fleet-event.sh")"
for hook in after-select-pane after-select-window client-session-changed; do
  tmux set-hook -g "$hook[782]" "run-shell -b \"$event --seen '#{pane_id}'\""
done
tmux run-shell -b "$(fleet_shell_quote "$CURRENT_DIR/scripts/fleet-monitor.sh")"
