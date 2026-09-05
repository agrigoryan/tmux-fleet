#!/usr/bin/env bash
set -eu
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../scripts" && pwd)"
source "$SCRIPT_DIR/state.sh"
passed=0
check() {
  local label="$1" expected="$2" actual
  shift 2
  actual="$(fleet_transition "$@")"
  if [ "$actual" != "$expected" ]; then
    printf 'FAIL %s: expected [%s], got [%s]\n' "$label" "$expected" "$actual" >&2
    exit 1
  fi
  passed=$((passed + 1))
}

# Arguments: observed last unseen had-work pending visible now authoritative.
# Result: persisted-state unseen had-work pending display-state.
check 'unknown preserves running state without completion' \
  'working 0 1 0 unknown' unknown working 0 1 0 0 100
check 'unknown cancels pending idle confirmation' \
  'working 0 1 0 unknown' unknown working 0 1 99 0 100
check 'unknown preserves an existing unread completion' \
  'idle 1 0 0 unknown' unknown idle 1 0 0 0 100
check 'unrecognized observation also stays unknown' \
  'working 0 1 0 unknown' broken working 0 1 0 0 100
check 'invalid persisted state is normalized' \
  'unknown 0 0 0 unknown' unknown done 0 0 0 0 100

check 'new work starts completion tracking and clears old badge' \
  'working 0 1 0 working' working idle 1 0 0 0 100
check 'new work cancels pending idle' \
  'working 0 1 0 working' working working 0 1 99 0 100
check 'first idle sample keeps running state' \
  'working 0 1 100 working' idle working 0 1 0 0 100
check 'same second second sample cannot confirm completion' \
  'working 0 1 100 working' idle working 0 1 100 0 100
check 'backwards clock restarts confirmation instead of waiting for old timestamp' \
  'working 0 1 90 working' idle working 0 1 100 0 90
check 'later idle sample confirms unread completion' \
  'idle 1 0 0 done' idle working 0 1 100 0 101
check 'visible completion does not create badge' \
  'idle 0 0 0 idle' idle working 0 1 100 1 101
check 'seeing first idle sample acknowledges completion before leaving' \
  'idle 0 0 0 idle' idle working 0 1 0 1 100
check 'idle with no observed work cannot create completion' \
  'idle 0 0 0 idle' idle unknown 0 0 0 0 101
check 'confirmed unread completion persists' \
  'idle 1 0 0 done' idle idle 1 0 0 0 102

check 'permission keeps had-work across a pause' \
  'waiting 0 1 0 waiting' waiting working 0 1 100 0 101
check 'idle after permission still needs confirmation' \
  'waiting 0 1 102 waiting' idle waiting 0 1 0 0 102
check 'confirmed idle after permission creates completion' \
  'idle 1 0 0 done' idle waiting 0 1 102 0 103
check 'permission before any work cannot create completion' \
  'idle 0 0 0 idle' idle waiting 0 0 0 0 103
check 'error keeps had-work and clears debounce' \
  'error 0 1 0 error' error working 0 1 100 0 101
check 'recovery after error remains debounced' \
  'error 0 1 102 error' idle error 0 1 0 0 102

check 'native idle confirms completion immediately' \
  'idle 1 0 0 done' idle working 0 1 0 0 100 1
check 'native idle after permission confirms completion immediately' \
  'idle 1 0 0 done' idle waiting 0 1 0 0 100 1
check 'native idle still requires known prior work' \
  'idle 0 0 0 idle' idle unknown 0 0 0 0 100 1
check 'native completion while visible remains acknowledged' \
  'idle 0 0 0 idle' idle working 0 1 0 1 100 1

check 'visiting idle acknowledges completion' \
  'idle 0 0 0 idle' idle idle 1 0 0 1 103
check 'visiting despite failed capture acknowledges completion' \
  'idle 0 0 0 unknown' unknown idle 1 0 0 1 103
check 'visiting a waiting pane acknowledges previous badge' \
  'waiting 0 0 0 waiting' waiting idle 1 0 0 1 103

# Identity validation is the caller responsibility; these are the reset inputs
# it must supply after an agent restart (same pane, new PID/start-time identity).
check 'fresh identity cannot inherit previous done badge' \
  'idle 0 0 0 idle' idle unknown 0 0 0 0 104
check 'fresh identity unknown cannot retain previous running state' \
  'unknown 0 0 0 unknown' unknown unknown 0 0 0 0 104

printf 'state: %s checks passed\n' "$passed"
