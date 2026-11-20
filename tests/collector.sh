#!/usr/bin/env bash
set -eu
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
command -v jq >/dev/null || { printf 'collector tests require jq\n' >&2; exit 1; }
test_dir="$(mktemp -d "${TMPDIR:-/tmp}/fleet-collector-test.XXXXXX")"
trap 'rm -rf "$test_dir"' EXIT
mkdir "$test_dir/bin" "$test_dir/runtime"
for command in tmux ps claude date; do
  cp "$ROOT/tests/mocks/$command" "$test_dir/bin/$command"
  chmod +x "$test_dir/bin/$command"
done
export PATH="$test_dir/bin:$PATH" TMPDIR="$test_dir/runtime"
fixture=0 failures=0
check() {
  if [ "$2" != "$3" ]; then
    printf 'FAIL %s\nexpected: %s\nactual: %s\n' "$1" "$2" "$3" >&2
    failures=$((failures + 1))
  fi
}
fresh() {
  fixture=$((fixture + 1))
  export FLEET_TEST_DATA="$test_dir/fixture-$fixture"
  mkdir "$FLEET_TEST_DATA"
  : >"$FLEET_TEST_DATA/panes"
  : >"$FLEET_TEST_DATA/ps"
  printf '[]\n' >"$FLEET_TEST_DATA/api.json"
  /bin/date +%s >"$FLEET_TEST_DATA/now"
}
property() { printf '%s' "$3" >"$FLEET_TEST_DATA/$1/$2"; }
pane() {
  local id="$1" tty="$2" pid="$3" agent="$4" content="$5"
  mkdir "$FLEET_TEST_DATA/$id"
  printf '%s\n' "$id" >>"$FLEET_TEST_DATA/panes"
  property "$id" pane_id "$id"
  property "$id" pane_tty "/dev/$tty"
  property "$id" session_name "session-${id#%}"
  property "$id" window_index 1
  property "$id" pane_index 0
  property "$id" window_activity 100
  property "$id" pane_active 0
  property "$id" window_active 0
  property "$id" session_attached 1
  property "$id" pane_current_path /tmp/project
  printf '%s\n' "$content" >"$FLEET_TEST_DATA/$id/content"
  printf '%s 1 %s S+ %s Sat Sep 5 12:00:00 2026 %s\n' "$pid" "$pid" "$tty" "$agent" >>"$FLEET_TEST_DATA/ps"
}
scan() { /bin/bash "$ROOT/scripts/fleet-list.sh" --states; }
event() { TMUX_PANE="$1" /bin/bash "$ROOT/scripts/fleet-event.sh" "${@:2}"; }
advance() { printf '%s\n' "$(( $(<"$FLEET_TEST_DATA/now") + $1 ))" >"$FLEET_TEST_DATA/now"; }
get() { cat "$FLEET_TEST_DATA/$1/$2"; }

fresh
pane %1 ttys001 101 pi '── Working ─────────────────'
pane %2 ttys002 102 opencode 'esc interrupt'
pane %3 ttys003 103 codex $'Question 1/1\n› 1. Yes\nEnter to submit answer'
pane %4 ttys004 104 claude $'✳ Working…\nDo you want to proceed\n❯ Yes'
pane %5 ttys005 105 agy $'⣟  Running command...\n─────────────────────────────\n>\n─────────────────────────────\nesc to cancel   auto · Gemini'
check 'five harnesses and empty field joins' $'working\nworking\nwaiting\nwaiting\nworking' "$(scan)"
display="$(/bin/bash "$ROOT/scripts/fleet-list.sh")"
case "$display" in *session-1:1.0*project*) ;; *) check 'display pane metadata join' present "$display" ;; esac
case "$display" in *agy*session-5:1.0*Running\ command...*) ;; *) check 'agy display row' present "$display" ;; esac

fresh
pane %1 ttys001 101 codex '• Working (3s • esc to interrupt)'
check 'initial working' working "$(scan)"
# Missing capture is simulated by an empty visible pane: no capture file emitted.
: >"$FLEET_TEST_DATA/%1/content"
check 'missing capture cannot fabricate completion' unknown "$(scan)"
check 'missing capture retains last working observation' working "$(get %1 @fleet_last_state)"
check 'missing capture does not mark unseen' 0 "$(get %1 @fleet_unseen)"
property %1 content '› '
check 'first confirmed idle debounces completion' working "$(scan)"
advance 2
check 'second idle sample marks completion' done "$(scan)"
property %1 pane_active 1
property %1 window_active 1
/bin/bash "$ROOT/scripts/fleet-event.sh" --seen %1
property %1 pane_active 0
property %1 window_active 0
check 'focus acknowledgement clears unseen completion' idle "$(scan)"
property %1 @fleet_unseen 1
property %1 @fleet_last_state idle
printf '101 1 101 S+ ttys001 Sat Sep 5 12:00:01 2026 codex\n' >"$FLEET_TEST_DATA/ps"
check 'reused PID start identity resets completion' idle "$(scan)"

fresh
pane %1 ttys001 101 claude '❯ '
printf '[{"kind":"interactive","pid":101,"status":"busy","name":"API session"}]\n' >"$FLEET_TEST_DATA/api.json"
check 'Claude API state' working "$(scan)"
property %1 content $'Do you want to proceed\n❯ Yes'
check 'active dialog overrides cached API busy state' waiting "$(scan)"
printf '102 1 102 S+ ttys001 Sat Sep 5 12:00:01 2026 zsh\n' >"$FLEET_TEST_DATA/ps"
check 'cached API cannot resurrect an exited agent' '' "$(scan)"
printf '101 1 101 S+ ttys001 Sat Sep 5 12:00:01 2026 zsh\n' >"$FLEET_TEST_DATA/ps"
check 'cached API cannot attach to reused shell PID' '' "$(scan)"

fresh
pane %1 ttys001 101 claude $'✳ Working…\nesc to interrupt'
printf '[{"kind":"interactive","pid":101,"status":"idle"}]\n' >"$FLEET_TEST_DATA/api.json"
check 'active screen progress overrides cached API idle' working "$(scan)"

fresh
pane %1 ttys001 101 pi $'──────────────────\n\n──────────────────'
event %1 pi 101 pi-session working
check 'native working overrides idle screen' working "$(scan)"
event %1 pi 101 pi-session idle
check 'native lifecycle catches completion between scans' done "$(scan)"
advance 31
check 'lease expiry preserves acknowledged session identity and completion' done "$(scan)"
event %1 pi 101 next-session idle
check 'new native session resets old completion' idle "$(scan)"
event %1 pi 101 next-session waiting 'Choose a branch'
check 'native prompt event' waiting "$(scan)"
advance 31
check 'expired native lease falls back to screen' idle "$(scan)"
event %1 pi 101 next-session working
event %1 pi 101 old-session ended
check 'old session end cannot clear new session' working "$(scan)"
event %1 pi 101 next-session ended
check 'matching session end falls back to debounced screen idle' working "$(scan)"
advance 2
check 'matching session end allows confirmed completion' done "$(scan)"
pane %2 ttys002 102 pi $'──────────────────\n\n──────────────────'
if event %2 pi 101 bad-pane working; then check 'native event rejects wrong pane tty' rejected accepted; fi
printf '101 1 101 T ttys001 Sat Sep 5 12:00:00 2026 pi\n103 1 103 S+ ttys001 Sat Sep 5 12:00:01 2026 zsh\n' >"$FLEET_TEST_DATA/ps"
if event %1 pi 101 stopped-session working; then check 'native event rejects stopped agent' rejected accepted; fi

fresh
pane %1 ttys001 101 pi $'──────────────────\n\n──────────────────'
event %1 pi 101 old-session waiting 'Old prompt'
printf '101 1 101 S+ ttys001 Sat Sep 5 12:00:01 2026 pi\n' >"$FLEET_TEST_DATA/ps"
check 'fresh native lease cannot survive PID reuse' idle "$(scan)"

fresh
pane %1 ttys001 101 pi $'──────────────────\n\n──────────────────'
event %1 pi 101 manual-session idle
property %1 content '── Working ─────────────────'
check 'screen working overrides native idle for manual operations' working "$(scan)"
event %1 pi 101 manual-session idle
check 'duplicate idle heartbeat does not complete manual operation' working "$(get %1 @fleet_last_state)"
check 'duplicate idle heartbeat preserves had-work' 1 "$(get %1 @fleet_had_work)"
property %1 content $'──────────────────\n\n──────────────────'
check 'manual completion still debounces screen-only work' working "$(scan)"
advance 2
check 'manual completion still records unseen work' done "$(scan)"

fresh
pane %1 ttys001 101 opencode 'esc interrupt'
pids=()
for iteration in 1 2 3 4 5 6; do
  scan >"$FLEET_TEST_DATA/output-$iteration" 2>"$FLEET_TEST_DATA/error-$iteration" &
  pids+=("$!")
done
for pid in "${pids[@]}"; do wait "$pid" || check 'concurrent scan exit' success failed; done
for iteration in 1 2 3 4 5 6; do
  check 'concurrent scan result' working "$(<"$FLEET_TEST_DATA/output-$iteration")"
  check 'concurrent scan stderr' '' "$(<"$FLEET_TEST_DATA/error-$iteration")"
done
touch "$FLEET_TEST_DATA/fail-ps"
result="$(scan)" && check 'failed ps exit code' failure success
check 'failed ps preserves cached state' working "$result"

[ "$failures" = 0 ] || exit 1
printf 'collector: all checks passed\n'
