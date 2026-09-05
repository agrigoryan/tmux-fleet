#!/usr/bin/env bash
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "$ROOT/scripts/helpers.sh"
testdir="$(mktemp -d "${TMPDIR:-/tmp}/fleet-smoke.XXXXXX")"
socket="$testdir/socket"
cleanup() {
  result=$?
  if [ "$result" != 0 ] && tmux -S "$socket" has-session 2>/dev/null; then
    tmux -S "$socket" list-panes -a -F '#{pane_id} #{pane_tty} #{pane_current_command} #{pane_dead}'
    tmux -S "$socket" capture-pane -p -t fleet-review:0.0
  fi
  tmux -S "$socket" kill-server 2>/dev/null || true
  rm -rf "$testdir"
}
trap cleanup EXIT
unset TMUX TMUX_PANE
tmux -S "$socket" -f /dev/null new-session -d -s fleet-review -x 100 -y 35 \
  "bash $(fleet_shell_quote "$ROOT/tests/fixtures/pi")"
export TMUX="$(tmux -S "$socket" display-message -p '#{socket_path},#{pid},0')"
export TMPDIR="$testdir"
tmux set-environment -g TMPDIR "$testdir"
export TMUX_PANE="$(tmux display-message -p '#{pane_id}')"
tmux set -g @fleet-poll-interval 0
bash "$ROOT/fleet.tmux"
tmux show-hooks -g | grep -q 'after-select-pane\[782\]'
runtime="$(fleet_runtime_dir)"
# No real supervisor command is needed in this isolated server.
touch "$runtime/api.failed"
sleep 0.15
assert_state() {
  local actual
  actual="$(bash "$ROOT/scripts/fleet-list.sh" --states)"
  [ "$actual" = "$1" ] || { printf 'expected %s, got %s\n' "$1" "$actual" >&2; exit 1; }
}
assert_state working
tmux send-keys -t "$TMUX_PANE" idle Enter
sleep 0.1
assert_state working
sleep 1.1
assert_state done
identity="$(tmux show-option -pqv -t "$TMUX_PANE" @fleet_identity)"
pid="${identity%%:*}"
bash "$ROOT/scripts/fleet-event.sh" pi "$pid" smoke-session working
bash "$ROOT/scripts/fleet-event.sh" pi "$pid" smoke-session waiting 'permission test'
assert_state waiting
bash "$ROOT/scripts/fleet-event.sh" pi "$pid" smoke-session idle
assert_state done
tmux set -p -t "$TMUX_PANE" @fleet_event_time 1
assert_state done
# A real attached control client exercises focus hooks without a user terminal.
mkfifo "$testdir/client-in"
tmux -C attach-session -t fleet-review <"$testdir/client-in" >"$testdir/client-out" &
client_pid=$!
exec 9>"$testdir/client-in"
sleep 0.15
tmux new-window -d -n other
tmux select-window -t fleet-review:other
tmux set -p -t "$TMUX_PANE" @fleet_unseen 1
tmux select-window -t fleet-review:0
for attempt in 1 2 3 4 5 6 7 8 9 10; do
  [ "$(tmux show-option -pqv -t "$TMUX_PANE" @fleet_unseen)" != 0 ] || break
  sleep 0.1
done
[ "$(tmux show-option -pqv -t "$TMUX_PANE" @fleet_unseen)" = 0 ]
exec 9>&-
wait "$client_pid" || true
# TPM reload starts only one poller, which refreshes without an open picker.
tmux set -g @fleet-poll-interval 1
bash "$ROOT/fleet.tmux"
sleep 0.25
monitor_pid="$(cat "$runtime/monitor-lock/pid")"
bash "$ROOT/fleet.tmux"
sleep 0.15
[ "$(cat "$runtime/monitor-lock/pid")" = "$monitor_pid" ]
tmux send-keys -t "$TMUX_PANE" working Enter
for attempt in 1 2 3 4 5 6 7 8 9 10; do
  [ "$(cat "$runtime/states")" != working ] || break
  sleep 0.2
done
[ "$(cat "$runtime/states")" = working ]
tmux set -g @fleet-poll-interval 0
sleep 1.2
[ ! -d "$runtime/monitor-lock" ]
# Exiting the process removes the row even if native status remains on the pane.
tmux set -g remain-on-exit on
tmux send-keys -t "$TMUX_PANE" C-d
sleep 0.1
assert_state ''
printf 'tmux-smoke: tty detection, completion, native events, lease expiry, focus hooks, singleton polling, exit passed\n'
