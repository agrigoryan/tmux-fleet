#!/usr/bin/env bash
# tmux run-shell background job; one monitor per server, exits with the server.
set -u
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/helpers.sh"
runtime="$(fleet_runtime_dir)" || exit 1
fleet_lock_acquire "$runtime/monitor-lock" 2 || exit 0
trap 'fleet_lock_release "$runtime/monitor-lock"' EXIT
trap 'exit 130' INT
trap 'exit 143' TERM
while tmux has-session 2>/dev/null; do
  interval="$(fleet_uint "$(get_tmux_option @fleet-poll-interval 2)" 2)"
  [ "$interval" -gt 0 ] || exit 0
  bash "$SCRIPT_DIR/fleet-list.sh" --collect >/dev/null 2>&1
  sleep "$interval"
done
