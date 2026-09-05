#!/usr/bin/env bash
# Native bridges: <agent> <pid> <session-id> <working|waiting|idle|error|ended> [reason]
# Focus acknowledgement: --seen <pane-id>. All writes share the collector lock.
set -u
umask 077
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/helpers.sh"
source "$SCRIPT_DIR/state.sh"
runtime="$(fleet_runtime_dir)" || exit 1
fleet_lock_acquire "$runtime/lock" || exit 1
workdir="$(mktemp -d "$runtime/event.XXXXXX")" || { fleet_lock_release "$runtime/lock"; exit 1; }
trap 'fleet_lock_release "$runtime/lock"; rm -rf "$workdir"' EXIT
trap 'exit 130' INT
trap 'exit 143' TERM
US=$'\x1f'
if [ "${1:-}" = --seen ]; then
  pane="${2:-}"
  case "$pane" in %*) case "${pane#%}" in ''|*[!0-9]*) exit 2 ;; esac ;; *) exit 2 ;; esac
  visible="$(tmux list-panes -a -F '#{pane_id} #{pane_active} #{window_active} #{session_attached}' |
    awk -v p="$pane" '$1==p && $2==1 && $3==1 && $4>0 {print 1; exit}')"
  [ "$visible" = 1 ] || exit 0
  tmux set -p -t "$pane" @fleet_unseen 0
  exit
fi
[ "$#" -ge 4 ] || exit 2
agent="$1" pid="$2" session="$3" state="$4" reason="${5:-}"
pane="${TMUX_PANE:-}"
case "$agent" in pi|opencode|codex|claude) ;; *) exit 2 ;; esac
case "$pid" in ''|*[!0-9]*) exit 2 ;; esac
case "$pane" in %*) case "${pane#%}" in ''|*[!0-9]*) exit 2 ;; esac ;; *) exit 2 ;; esac
case "$state" in working|waiting|idle|error|ended) ;; *) exit 2 ;; esac
session="$(printf '%s' "$session" | tr '\t\r\n\037' '    ')"
reason="$(printf '%s' "$reason" | tr '\t\r\n\037' '    ')"
[ -n "$session" ] || exit 2

# A background adapter sharing the tty must not alter the foreground lifecycle.
LC_ALL=C ps -eo pid=,ppid=,pgid=,stat=,tty=,lstart=,args= >"$workdir/ps" 2>/dev/null || exit 1
process="$(awk -f "$SCRIPT_DIR/process-map.awk" "$workdir/ps" |
  awk -F '\t' -v p="$pid" -v a="$agent" '$3==p && $2==a {print; exit}')"
[ -n "$process" ] || exit 1
IFS=$'\t' read -r tty detected_agent detected_pid event_identity <<<"$process"
identity="$event_identity/$session"
format="#{pane_tty}${US}#{pane_active}${US}#{window_active}${US}#{session_attached}${US}#{@fleet_identity}${US}#{@fleet_last_state}${US}#{@fleet_unseen}${US}#{@fleet_had_work}${US}#{@fleet_pending_idle}${US}#{@fleet_event_pid}${US}#{@fleet_event_session}${US}#{@fleet_event_state}${US}#{@fleet_event_identity}"
snapshot="$(tmux display-message -p -t "$pane" "${format//$US/$'\t'}")" || exit 1
snapshot="${snapshot//$'\t'/$US}"
IFS="$US" read -r pane_tty active window attached old_identity last unseen had_work pending old_pid old_session old_event_state old_event_identity <<<"$snapshot"
[ "${pane_tty#/dev/}" = "$tty" ] || exit 1
if [ "$state" = ended ]; then
  [ "$old_pid" = "$pid" ] && [ "$old_session" = "$session" ] || exit 0
  tmux set -p -t "$pane" @fleet_event_state ended \; set -p -t "$pane" @fleet_event_time 0
  exit
fi
now="$(date +%s)"
# Heartbeats refresh the lease, not lifecycle. A duplicate idle must not finish
# a manual operation whose working state was learned from the screen.
if [ "$old_event_identity" = "$event_identity" ] && [ "$old_session" = "$session" ] &&
   [ "$old_event_state" = "$state" ]; then
  tmux set -p -t "$pane" @fleet_event_time "$now" \; \
    set -p -t "$pane" @fleet_event_reason "${reason:0:160}"
  exit
fi
if [ "$old_identity" != "$identity" ]; then last=unknown; unseen=0; had_work=0; pending=0; fi
visible="$(tmux list-panes -a -F '#{pane_id} #{pane_active} #{window_active} #{session_attached}' |
  awk -v p="$pane" '$1==p && $2==1 && $3==1 && $4>0 {print 1; exit}')"
visible="${visible:-0}"
read -r persisted unseen had_work pending display < <(fleet_transition "$state" "${last:-unknown}" \
  "$(fleet_uint "$unseen" 0)" "$(fleet_uint "$had_work" 0)" "$(fleet_uint "$pending" 0)" "$visible" "$now" 1)
tmux set -p -t "$pane" @fleet_event_agent "$agent" \; \
  set -p -t "$pane" @fleet_event_pid "$pid" \; \
  set -p -t "$pane" @fleet_event_session "$session" \; \
  set -p -t "$pane" @fleet_event_state "$state" \; \
  set -p -t "$pane" @fleet_event_reason "${reason:0:160}" \; \
  set -p -t "$pane" @fleet_event_time "$now" \; \
  set -p -t "$pane" @fleet_event_identity "$event_identity" \; \
  set -p -t "$pane" @fleet_identity "$identity" \; \
  set -p -t "$pane" @fleet_last_state "$persisted" \; \
  set -p -t "$pane" @fleet_unseen "$unseen" \; \
  set -p -t "$pane" @fleet_had_work "$had_work" \; \
  set -p -t "$pane" @fleet_pending_idle "$pending"
