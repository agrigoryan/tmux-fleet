#!/usr/bin/env bash
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
for script in "$ROOT/fleet.tmux" "$ROOT"/scripts/*.sh "$ROOT"/tests/*.sh; do bash -n "$script"; done
for suite in classify state presentation process-map helpers collector; do bash "$ROOT/tests/$suite.sh"; done
if command -v node >/dev/null 2>&1; then
  node --test "$ROOT/tests/native-adapters.test.mjs"
else
  printf 'Native adapter tests require Node >=22.18.\n' >&2
  exit 1
fi
