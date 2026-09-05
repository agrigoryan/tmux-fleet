#!/usr/bin/env bash
set -eu
source "$(cd "$(dirname "${BASH_SOURCE[0]}")/../scripts" && pwd)/presentation.sh"
[ "$(fleet_message working $'old text\n── Working ─────' 'pi' '' '')" = '── Working ─────' ]
[ "$(fleet_message waiting 'Permission required' 'OpenCode' '' '')" = 'Permission required' ]
[ "$(fleet_message waiting 'Permission required' 'OpenCode' 'input required' '')" = 'input required' ]
[ "$(fleet_message idle '' 'Claude Code' '' 'Named session')" = 'Named session' ]
[ "$(fleet_message idle '' $'a\tb\rc' '' '')" = 'a b c' ]
printf 'presentation: all checks passed\n'
