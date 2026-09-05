#!/usr/bin/env bash
set -eu
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "$ROOT/scripts/helpers.sh"
test_dir="$(mktemp -d "${TMPDIR:-/tmp}/fleet-helpers-test.XXXXXX")"
trap 'rm -rf "$test_dir"' EXIT
fail() { printf 'FAIL %s\n' "$*" >&2; exit 1; }

touch "$test_dir/recent"
file_age_lt "$test_dir/recent" 10 || fail 'recent file age'
file_age_lt "$test_dir" 10 || fail 'recent directory age'
! file_age_lt "$test_dir/missing" 10 || fail 'missing file age'
touch -t 202001020304.05 "$test_dir/recent"
! file_age_lt "$test_dir/recent" 10 || fail 'old file age'

# Mock only tmux: runtime directory creation and OS stat remain real.
tmux() { printf '%s\n' "$FLEET_TEST_SERVER"; }
FLEET_TEST_SERVER='/tmp/socket-one:123'
runtime_one="$(TMPDIR="$test_dir" fleet_runtime_dir)"
[ "$runtime_one" = "$(TMPDIR="$test_dir" fleet_runtime_dir)" ] || fail 'stable runtime namespace'
FLEET_TEST_SERVER='/tmp/socket-one:456'
runtime_two="$(TMPDIR="$test_dir" fleet_runtime_dir)"
[ "$runtime_one" != "$runtime_two" ] || fail 'server PID namespace isolation'
FLEET_TEST_SERVER='/tmp/socket-two:456'
[ "$runtime_two" != "$(TMPDIR="$test_dir" fleet_runtime_dir)" ] || fail 'socket namespace isolation'
case "$(uname -s)" in
  Darwin|*BSD) mode="$(stat -f %Lp "$runtime_one")" ;;
  *) mode="$(stat -c %a "$runtime_one")" ;;
esac
[ "$mode" = 700 ] || fail "runtime permissions: $mode"

lock="$test_dir/lock"
mkdir "$lock"
! fleet_lock_acquire "$lock" 2 || fail 'fresh ownerless lock was stolen'
[ -d "$lock" ] || fail 'fresh ownerless lock removed'
touch -t 202001020304.05 "$lock"
fleet_lock_acquire "$lock" 10 || fail 'stale ownerless lock recovery'
! fleet_lock_acquire "$lock" 2 || fail 'live lock was stolen'
fleet_lock_release "$lock"
[ ! -d "$lock" ] || fail 'lock release'
mkdir "$lock"
printf '99999999\n' >"$lock/pid"
fleet_lock_acquire "$lock" 10 || fail 'dead owner recovery'
fleet_lock_release "$lock"

pids=()
for worker in 1 2 3 4 5 6 7 8; do
  bash -eu -c '
    source "$1/scripts/helpers.sh"
    for iteration in 1 2 3 4 5; do
      fleet_lock_acquire "$2/lock" 400
      mkdir "$2/inside-critical-section" || exit 20
      sleep 0.01
      rmdir "$2/inside-critical-section"
      fleet_lock_release "$2/lock"
    done
  ' bash "$ROOT" "$test_dir" &
  pids+=("$!")
done
for worker in "${pids[@]}"; do wait "$worker" || fail 'concurrent lock exclusion'; done
[ ! -d "$lock" ] || fail 'concurrent lock cleanup'

awk 'BEGIN { for (i = 0; i < 1000; i++) print "A" }' >"$test_dir/source-a"
awk 'BEGIN { for (i = 0; i < 1000; i++) print "B" }' >"$test_dir/source-b"
fleet_publish "$test_dir/source-a" "$test_dir/published"
pids=()
for source_name in source-a source-b source-a source-b; do
  bash -eu -c '
    source "$1/scripts/helpers.sh"
    for iteration in 1 2 3 4 5 6 7 8 9 10; do
      fleet_publish "$2/$3" "$2/published"
    done
  ' bash "$ROOT" "$test_dir" "$source_name" &
  pids+=("$!")
done
for iteration in 1 2 3 4 5 6 7 8 9 10; do
  awk 'NR == 1 { first = $0 } $0 != first { exit 1 } END { if (NR != 1000) exit 1 }' "$test_dir/published" || fail 'partial atomic publication'
done
for worker in "${pids[@]}"; do wait "$worker" || fail 'concurrent publication'; done
if fleet_publish "$test_dir/missing" "$test_dir/published" 2>/dev/null; then fail 'missing publish source succeeded'; fi
set -- "$test_dir"/published.*
[ ! -e "$1" ] || fail 'temporary publication file leaked'

for iteration in 1 2 3 4 5 6 7 8 9 10; do
  fleet_timeout 10 "$test_dir/output" printf 'ok' || fail 'successful timeout command'
  [ -d "$test_dir" ] || fail 'watchdog inherited caller EXIT cleanup'
  [ "$(<"$test_dir/output")" = ok ] || fail 'timeout output capture'
done
if fleet_timeout 10 "$test_dir/output" bash -c 'exit 7'; then
  fail 'timeout swallowed command failure'
else
  [ "$?" = 7 ] || fail 'timeout changed command exit status'
fi
start="$(date +%s)"
if fleet_timeout 0.1 "$test_dir/output" bash -c 'trap "" TERM; while :; do :; done'; then
  fail 'TERM-resistant command succeeded'
fi
elapsed=$(( $(date +%s) - start ))
[ "$elapsed" -lt 4 ] || fail "TERM-resistant command exceeded bound: $elapsed seconds"

# A fake sleep makes lingering watchdog children observable without ps access.
# Fast command completion must cancel and reap that sleep before returning.
sleep() { trap 'printf stopped >"$test_dir/sleeper-stopped"; exit 0' TERM; printf started >"$test_dir/sleeper-started"; while :; do :; done; }
fleet_timeout 20 "$test_dir/output" bash -c 'sleep 0.1' || fail 'watchdog cancellation command'
[ -f "$test_dir/sleeper-started" ] || fail 'watchdog sleep did not start'
[ -f "$test_dir/sleeper-stopped" ] || fail 'watchdog sleep leaked'
unset -f sleep
printf 'helpers: all checks passed\n'
