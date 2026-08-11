#!/usr/bin/env bash
# fleet-list.sh — enumerate AI agent panes across the whole tmux server.
#
# Default output (one line per agent pane, sorted by attention priority then recency):
#   <ansi-colored display row> \t <pane_id>
# --states: emit just the state word per agent pane (for the status-line summary).
#
# Detection tiers (best available wins):
#   1. `claude agents --json` supervisor API, joined pid -> tty -> #{pane_tty}
#   2. process-on-pane-tty scan matching known agent CLI names
#   3. capture-pane + pane-title heuristics for status when the API didn't answer
#
# Performance: everything is joined in single awk passes, all pane captures happen
# in ONE tmux round trip, and the rendered list is cached for instant popup open.

set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=helpers.sh
source "$SCRIPT_DIR/helpers.sh"

MODE="${1:-display}"

AGENT_REGEX="$(get_tmux_option "@fleet-process-pattern" \
  'claude|codex|gemini|aider|opencode|cursor-agent|amp|goose|droid|copilot|grok|crush|pi')"
API_TTL="$(get_tmux_option "@fleet-api-cache-ttl" "3")"

NBSP=$'\302\240'
RESET=$'\033[0m'
C_WAIT=$'\033[1;33m'   # yellow
C_ERR=$'\033[1;31m'    # red
C_DONE=$'\033[1;36m'   # cyan
C_WORK=$'\033[1;32m'   # green
C_IDLE=$'\033[2;37m'   # dim
C_DIM=$'\033[2m'

TAB=$'\t'
US=$'\x1f'   # unit separator: unlike \t it is not IFS-whitespace, so empty
             # fields survive `read` (consecutive tabs would collapse)

workdir="$(mktemp -d "${TMPDIR:-/tmp}/tmux-fleet.XXXXXX")"
trap 'rm -rf "$workdir"' EXIT

panes_f="$workdir/panes" ps_f="$workdir/ps" agents_f="$workdir/agents"
map_f="$workdir/agents_by_tty" out_f="$workdir/out" final_f="$workdir/final"
api_cache="${TMPDIR:-/tmp}/tmux-fleet-api-$(id -u).tsv"

# ---------------------------------------------------------------- snapshots --
tmux list-panes -a -F "#{pane_id}${TAB}#{pane_pid}${TAB}#{pane_tty}${TAB}#{session_name}${TAB}#{window_index}${TAB}#{pane_index}${TAB}#{window_activity}${TAB}#{pane_active}${TAB}#{window_active}${TAB}#{session_attached}${TAB}#{pane_current_path}${TAB}#{@fleet_last_state}${TAB}#{@fleet_unseen}${TAB}#{pane_title}" >"$panes_f" 2>/dev/null || exit 0

ps -eo pid=,tty=,command= >"$ps_f" 2>/dev/null

# Supervisor API rows (tty_base \t status \t waiting_for \t name), cached API_TTL seconds
if ! file_age_lt "$api_cache" "$API_TTL"; then
  : >"$api_cache.tmp"
  if command -v claude >/dev/null 2>&1 && command -v jq >/dev/null 2>&1; then
    claude agents --json 2>/dev/null |
      jq -r '.[]? | select(.kind == "interactive")
             | [(.pid|tostring), .status, (.waitingFor // ""), (.name // "")] | join("\u001f")' 2>/dev/null |
      while IFS="$US" read -r apid astatus awaiting aname; do
        atty="$(awk -v p="$apid" '$1 == p { print $2; exit }' "$ps_f")"
        [ -n "$atty" ] && [ "$atty" != "??" ] &&
          printf '%s\t%s\t%s\t%s\n' "$atty" "$astatus" "$awaiting" "$aname"
      done >"$api_cache.tmp"
  fi
  mv -f "$api_cache.tmp" "$api_cache"
fi

# tty -> agent-name map, one pass over ps
awk -v re="[/ ]($AGENT_REGEX) " '
  $2 != "??" && !($2 in seen) {
    cmd = " "
    for (i = 3; i <= NF; i++) cmd = cmd $i " "
    if (match(cmd, re)) {
      m = substr(cmd, RSTART + 1, RLENGTH - 2)   # drop boundary chars
      sub(/.*\//, "", m)                         # basename
      print $2 "\t" m
      seen[$2] = 1
    }
  }' "$ps_f" >"$map_f"

# join panes + API + process map -> agent pane rows (18 US-separated fields,
# title last; US instead of \t so empty fields survive bash `read`)
awk -F'\t' -v OFS="$US" -v af="$api_cache" -v mf="$map_f" '
  FILENAME == af { api[$1] = $2 OFS $3 OFS $4; next }
  FILENAME == mf { amap[$1] = $2; next }
  {
    tty = $3; sub(/^\/dev\//, "", tty)
    agent = ""; astat = ""; await = ""; aname = ""
    if (tty in api) {
      agent = "claude"
      split(api[tty], a, OFS); astat = a[1]; await = a[2]; aname = a[3]
    } else if (tty in amap) {
      agent = amap[tty]
    }
    if (agent == "") next
    title = $0
    for (i = 1; i < 14; i++) sub(/^[^\t]*\t/, "", title)
    print $1, $2, tty, $4, $5, $6, $7, $8, $9, $10, $11, $12, $13,
          agent, astat, await, aname, title
  }' "$api_cache" "$map_f" "$panes_f" >"$agents_f"

[ -s "$agents_f" ] || {
  if [ "$MODE" != "--states" ]; then
    printf '%b(no agent sessions found)%b\t\n' "$C_DIM" "$RESET" | tee "$final_f"
    cp "$final_f" "$(fleet_cache_file).tmp" 2>/dev/null &&
      mv -f "$(fleet_cache_file).tmp" "$(fleet_cache_file)"
  fi
  exit 0
}

# capture every agent pane in ONE tmux round trip, split into per-pane files
cap_args=()
while IFS="$US" read -r pane_id _; do
  # sentinel carries the pane id without '%' — display-message expands % sequences
  cap_args+=(display-message -p "@@FLEET@@${pane_id#%}" ";"
             capture-pane -p -J -t "$pane_id" ";")
done <"$agents_f"
unset "cap_args[$((${#cap_args[@]} - 1))]"   # trailing ";"
tmux "${cap_args[@]}" 2>/dev/null | tr "$NBSP" ' ' |
  awk -v dir="$workdir" '
    /^@@FLEET@@/ { f = dir "/cap_" substr($0, 10); next }
    f { print > f }'

hostname_l="$(hostname 2>/dev/null)"
hostname_s="$(hostname -s 2>/dev/null)"

# --------------------------------------------------------------- functions --
# Pane title minus spinner/marker glyphs and generic app names.
clean_title() {
  local t="$1"
  t="$(printf '%s' "$t" | sed -E 's/^[⠀-⣿✳✻✽✶✢·[:space:]]+//')"
  case "$t" in
    "Claude Code"|"Codex"*|"Gemini CLI"|"$hostname_l"|"$hostname_s"|"") echo "" ;;
    *) echo "$t" ;;
  esac
}

# last spinner/progress line from screen content, glyph stripped
spinner_line() {
  printf '%s\n' "$1" |
    grep -E '^[[:space:]]*[✳✽✶✻✢·][[:space:]].*…|^[[:space:]]*[•◦][[:space:]]+Working \(' |
    tail -1 |
    sed -E 's/^[[:space:]]*[✳✽✶✻✢·•◦][[:space:]]*//; s/[[:space:]]+$//'
}

# classify <visible-screen-content> <pane_title>; echoes state word
classify() {
  local content="$1" title="$2" tail15
  # last 15 non-empty lines — busy cues must be near the bottom of the screen
  # (spinner lines linger higher up in the transcript while a dialog is open)
  tail15="$(printf '%s\n' "$content" |
    awk 'NF { l[++n] = $0 } END { s = n - 14; if (s < 1) s = 1; for (i = s; i <= n; i++) print l[i] }')"

  # any braille spinner char (U+2800-U+28FF = UTF-8 E2 A0..A3 xx) leading the
  # OSC title means the agent is animating = working
  case "$title" in
    $'\342\240'*|$'\342\241'*|$'\342\242'*|$'\342\243'*) echo working; return ;;
  esac

  if printf '%s' "$content" | grep -qE 'Please run /login|API Error: 401|socket connection closed'; then
    echo error; return
  fi
  if printf '%s' "$tail15" | grep -qiE \
    'ctrl\+c to interrupt|esc to interrupt|^[[:space:]]*[✳✽✶✻✢·][[:space:]].*…|….*tokens|Working\.\.\.'; then
    echo working; return
  fi
  if printf '%s' "$content" | grep -qE \
    'No, and tell Claude|Yes, allow (once|always)|│ Do you want|│ Would you like|Do you want to proceed|Run this command\?|Do you trust the files|Allow this MCP server|❯ (Yes|No|[0-9]\.)|Press Enter to select|\((Y/n|y/N)\)|\[(Y/n|y/N)\]'; then
    echo waiting; return
  fi
  echo idle
}

# --------------------------------------------------------------- main loop --
pane_opt_updates=()

while IFS="$US" read -r pane_id pane_pid tty_base sess widx pidx activity \
                          pane_active window_active sess_attached cur_path \
                          last_state prev_unseen agent api_status waiting_for \
                          api_name title; do
  content=""
  [ -f "$workdir/cap_${pane_id#%}" ] && content="$(<"$workdir/cap_${pane_id#%}")"

  state=""
  case "$api_status" in
    busy)    state=working ;;
    waiting) state=waiting ;;
    idle)    state=idle ;;
  esac
  [ -z "$state" ] && state="$(classify "$content" "$title")"

  # done/unseen tracking: flag panes that finished while you weren't looking
  visible=0
  [ "$pane_active" = "1" ] && [ "$window_active" = "1" ] && [ "${sess_attached:-0}" -ge 1 ] && visible=1
  unseen="${prev_unseen:-0}"
  if [ "$visible" = "1" ]; then
    unseen=0
  elif [ "$state" = "idle" ] && [ "$last_state" = "working" ]; then
    unseen=1
  fi
  display_state="$state"
  [ "$state" = "idle" ] && [ "$unseen" = "1" ] && display_state="done"

  if [ "$state" != "$last_state" ] || [ "$unseen" != "${prev_unseen:-0}" ]; then
    pane_opt_updates+=("set" "-p" "-t" "$pane_id" "@fleet_last_state" "$state" ";"
                       "set" "-p" "-t" "$pane_id" "@fleet_unseen" "$unseen" ";")
  fi

  if [ "$MODE" = "--states" ]; then
    echo "$display_state"
    continue
  fi

  # message column: API waiting reason > dialog/spinner line > cleaned title
  msg=""
  case "$display_state" in
    waiting)
      msg="$waiting_for"
      [ -z "$msg" ] && msg="$(printf '%s\n' "$content" |
        grep -E 'Do you want|Would you like|Do you trust|Allow this|Run this command' |
        tail -1 | sed -E 's/[│╭╰─]+//g; s/^[[:space:]]+//; s/[[:space:]]+$//')"
      ;;
    working)
      msg="$(spinner_line "$content")"
      ;;
  esac
  [ -z "$msg" ] && msg="$(clean_title "$title")"
  [ -z "$msg" ] && [ -n "$api_name" ] && msg="$api_name"
  msg="${msg//$TAB/ }"
  [ "${#msg}" -gt 80 ] && msg="${msg:0:79}…"

  case "$display_state" in
    waiting) color="$C_WAIT"; prio=0 ;;
    error)   color="$C_ERR";  prio=1 ;;
    done)    color="$C_DONE"; prio=2 ;;
    working) color="$C_WORK"; prio=3 ;;
    *)       color="$C_IDLE"; prio=4 ;;
  esac

  loc="$sess:$widx.$pidx"
  dir="${cur_path##*/}"
  printf -v display '%b●%b %-7s %-8s %-20s %b%-14s%b %s' \
    "$color" "$RESET" "$display_state" "${agent:0:8}" "${loc:0:20}" \
    "$C_DIM" "${dir:0:14}" "$RESET" "$msg"

  printf '%s\t%s\t%s\t%s\n' "$prio" "$activity" "$display" "$pane_id" >>"$out_f"
done <"$agents_f"

# persist state transitions in one tmux invocation
if [ "${#pane_opt_updates[@]}" -gt 0 ]; then
  unset "pane_opt_updates[$((${#pane_opt_updates[@]} - 1))]"   # trailing ";"
  tmux "${pane_opt_updates[@]}" 2>/dev/null
fi

[ "$MODE" = "--states" ] && exit 0

if [ -s "$out_f" ]; then
  sort -t "$TAB" -k1,1n -k2,2nr "$out_f" >"$final_f.sorted"
  cut -f3- "$final_f.sorted" >"$final_f"
else
  printf '%b(no agent sessions found)%b\t\n' "$C_DIM" "$RESET" >"$final_f"
fi

cat "$final_f"

# refresh the instant-open cache for the picker
cache="$(fleet_cache_file)"
cp "$final_f" "$cache.tmp" 2>/dev/null && mv -f "$cache.tmp" "$cache"
