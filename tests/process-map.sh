#!/usr/bin/env bash
set -eu
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
failures=0
check() {
  local name="$1" expected="$2" snapshot="$3" actual
  actual="$(printf '%s\n' "$snapshot" | awk -f "$ROOT/scripts/process-map.awk" | cut -f1-3 | sort)"
  if [ "$actual" != "$expected" ]; then
    printf 'FAIL %s\nexpected: %s\nactual: %s\n' "$name" "$expected" "$actual" >&2
    failures=$((failures + 1))
  fi
}
check 'ignore agent names in editor or inline-program arguments' '' '
10 1 10 S+ ttys001 Sat Sep 5 12:00:00 2026 nvim /tmp/claude
11 1 11 S+ ttys002 Sat Sep 5 12:00:00 2026 node -e codex
12 1 12 S+ ttys003 Sat Sep 5 12:00:00 2026 bash -c claude
13 1 13 S+ ttys004 Sat Sep 5 12:00:00 2026 python -c pi
14 1 14 S+ ttys005 Sat Sep 5 12:00:00 2026 tail /tmp/opencode'
check 'exact executable and installed interpreter entrypoints' $'ttys001\tpi\t10\nttys002\tcodex\t11\nttys003\topencode\t12\nttys004\tclaude\t13\nttys005\taider\t14\nttys006\tagy\t15' '
10 1 10 S+ ttys001 Sat Sep 5 12:00:00 2026 node /opt/lib/node_modules/@earendil-works/pi-coding-agent/dist/cli.js
11 1 11 S+ ttys002 Sat Sep 5 12:00:00 2026 /bin/codex --model test
12 1 12 S+ ttys003 Sat Sep 5 12:00:00 2026 /opt/lib/node_modules/@opencode-ai/cli/bin/opencode2.exe
13 1 13 S+ ttys004 Sat Sep 5 12:00:00 2026 node --require setup.js /opt/lib/node_modules/@anthropic-ai/claude-code/cli.js
14 1 14 S+ ttys005 Sat Sep 5 12:00:00 2026 python3 -m aider
15 1 15 S+ ttys006 Sat Sep 5 12:00:00 2026 /Users/aram/.local/bin/agy --continue'
check 'ignore stopped and background agents' $'ttys001\topencode\t12' '
10 1 10 T ttys001 Sat Sep 5 12:00:00 2026 claude
11 1 11 S ttys001 Sat Sep 5 12:00:00 2026 codex
12 1 12 S+ ttys001 Sat Sep 5 12:00:00 2026 opencode
13 1 13 S ?? Sat Sep 5 12:00:00 2026 pi'
check 'foreground tool child keeps agent visible' $'ttys001\tcodex\t10' '
10 1 10 S ttys001 Sat Sep 5 12:00:00 2026 codex
11 10 11 S ttys001 Sat Sep 5 12:00:00 2026 bash
12 11 11 S+ ttys001 Sat Sep 5 12:00:00 2026 npm test'
check 'do not claim a separate nested terminal' '' '
10 1 10 S ttys001 Sat Sep 5 12:00:00 2026 codex
11 10 11 S+ ttys002 Sat Sep 5 12:00:00 2026 bash'
check 'prefer native foreground binary over launcher' $'ttys001\tcodex\t11' '
10 1 10 S+ ttys001 Sat Sep 5 12:00:00 2026 node /opt/lib/node_modules/@openai/codex/bin/codex.js
11 10 10 S+ ttys001 Sat Sep 5 12:00:01 2026 /opt/codex'
check 'anchored custom names do not match executable suffixes' '' '
10 1 10 S+ ttys001 Sat Sep 5 12:00:00 2026 notclaude
11 1 11 S+ ttys002 Sat Sep 5 12:00:00 2026 claude-helper
12 1 12 S+ ttys003 Sat Sep 5 12:00:00 2026 notagy
13 1 13 S+ ttys004 Sat Sep 5 12:00:00 2026 agy-helper'
api_actual="$(printf '%s\n' '10 1 10 S+ ttys001 Sat Sep 5 12:00:00 2026 renamed-title' |
  awk -v api_file=<(printf '10\t10:Sat_Sep_5_12:00:00_2026\tbusy\n99\t99:Sat_Sep_5_12:00:00_2026\tbusy\n') -f "$ROOT/scripts/process-map.awk")"
if [ "$api_actual" != $'ttys001\tclaude\t10\t10:Sat_Sep_5_12:00:00_2026' ]; then
  printf 'FAIL API PID validation and process start identity: %s\n' "$api_actual" >&2
  failures=$((failures + 1))
fi
stale_api_actual="$(printf '%s\n' '10 1 10 S+ ttys001 Sat Sep 5 12:00:01 2026 zsh' |
  awk -v api_file=<(printf '10\t10:Sat_Sep_5_12:00:00_2026\tbusy\n') -f "$ROOT/scripts/process-map.awk")"
if [ -n "$stale_api_actual" ]; then
  printf 'FAIL reused PID inherited stale API record: %s\n' "$stale_api_actual" >&2
  failures=$((failures + 1))
fi
[ "$failures" = 0 ] || exit 1
printf 'process-map: all checks passed\n'
