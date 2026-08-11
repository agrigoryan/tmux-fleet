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

workdir="$(mktemp -d "${TMPDIR:-/tmp}/tmux-fleet.XXXXXX")"
trap 'rm -rf "$workdir"' EXIT

panes_f="$workdir/panes" ps_f="$workdir/ps" out_f="$workdir/out"
api_cache="${TMPDIR:-/tmp}/tmux-fleet-api-$(id -u).tsv"

# ---------------------------------------------------------------- snapshots --
tmux list-panes -a -F "#{pane_id}${TAB}#{pane_pid}${TAB}#{pane_tty}${TAB}#{session_name}${TAB}#{window_index}${TAB}#{pane_index}${TAB}#{window_activity}${TAB}#{pane_active}${TAB}#{window_active}${TAB}#{session_attached}${TAB}#{pane_current_path}${TAB}#{@fleet_last_state}${TAB}#{@fleet_unseen}${TAB}#{pane_title}" >"$panes_f" 2>/dev/null || exit 0

ps -eo pid=,tty=,command= >"$ps_f" 2>/dev/null

# Supervisor API rows (tty_base \t status \t waiting_for \t name), cached API_TTL seconds
api_fresh=0
if [ -f "$api_cache" ]; then
  now="$(date +%s)"
  mtime="$(stat -f %m "$api_cache" 2>/dev/null || stat -c %Y "$api_cache" 2>/dev/null || echo 0)"
  [ $((now - mtime)) -lt "$API_TTL" ] && api_fresh=1
fi
if [ "$api_fresh" = "0" ]; then
  : >"$api_cache.tmp"
  if command -v claude >/dev/null 2>&1 && command -v jq >/dev/null 2>&1; then
    claude agents --json 2>/dev/null |
      jq -r '.[]? | select(.kind == "interactive")
             | [(.pid|tostring), .status, (.waitingFor // ""), (.name // "")] | @tsv' 2>/dev/null |
      while IFS="$TAB" read -r apid astatus awaiting aname; do
        atty="$(awk -v p="$apid" '$1 == p { print $2; exit }' "$ps_f")"
        [ -n "$atty" ] && [ "$atty" != "??" ] &&
          printf '%s\t%s\t%s\t%s\n' "$atty" "$astatus" "$awaiting" "$aname"
      done >"$api_cache.tmp"
  fi
  mv -f "$api_cache.tmp" "$api_cache"
fi

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
    'ctrl\+c to interrupt|esc to interrupt|^[[:space:]]*[✳✽✶✻✢·][[:space:]].*…|….*tokens'; then
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

while IFS="$TAB" read -r pane_id pane_pid pane_tty sess widx pidx activity \
                          pane_active window_active sess_attached cur_path \
                          last_state prev_unseen title; do
  tty_base="${pane_tty#/dev/}"
  agent="" state="" waiting_for="" api_name="" content=""

  # tier 1: supervisor API
  api_row="$(grep -m1 "^$tty_base$TAB" "$api_cache" 2>/dev/null || true)"
  if [ -n "$api_row" ]; then
    agent="claude"
    IFS="$TAB" read -r _ api_status waiting_for api_name <<<"$api_row"
    case "$api_status" in
      busy)    state=working ;;
      waiting) state=waiting ;;
      idle)    state=idle ;;
    esac
  fi

  # tier 2: any agent process on this pane's tty
  if [ -z "$agent" ]; then
    match="$(awk -v t="$tty_base" '$2 == t' "$ps_f" |
      grep -m1 -oE "(^|[/ ])($AGENT_REGEX)( |\$)" || true)"
    if [ -n "$match" ]; then
      match="${match# }"; match="${match% }"   # trim the boundary chars we captured
      agent="${match##*/}"
    fi
  fi

  [ -z "$agent" ] && continue

  # tier 3: screen heuristics — only when the API didn't answer
  if [ -z "$state" ]; then
    content="$(tmux capture-pane -p -J -t "$pane_id" 2>/dev/null | tr "$NBSP" ' ')"
    state="$(classify "$content" "$title")"
  fi

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
      if [ -z "$msg" ]; then
        [ -z "$content" ] && content="$(tmux capture-pane -p -J -t "$pane_id" 2>/dev/null | tr "$NBSP" ' ')"
        msg="$(printf '%s\n' "$content" |
          grep -E 'Do you want|Would you like|Do you trust|Allow this|Run this command' |
          tail -1 | sed -E 's/[│╭╰─]+//g; s/^[[:space:]]+//; s/[[:space:]]+$//')"
      fi
      ;;
    working)
      [ -n "$content" ] && msg="$(spinner_line "$content")"
      ;;
  esac
  [ -z "$msg" ] && msg="$(clean_title "$title")"
  if [ -z "$msg" ] && [ "$display_state" = "working" ] && [ -z "$content" ]; then
    # API said busy but the title is generic — grab the live spinner line
    content="$(tmux capture-pane -p -J -t "$pane_id" 2>/dev/null | tr "$NBSP" ' ')"
    msg="$(spinner_line "$content")"
  fi
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
done <"$panes_f"

# persist state transitions in one tmux invocation
if [ "${#pane_opt_updates[@]}" -gt 0 ]; then
  unset "pane_opt_updates[$((${#pane_opt_updates[@]} - 1))]"   # trailing ";"
  tmux "${pane_opt_updates[@]}" 2>/dev/null
fi

[ "$MODE" = "--states" ] && exit 0

if [ -s "$out_f" ]; then
  sort -t "$TAB" -k1,1n -k2,2nr "$out_f" | cut -f3-
else
  printf '%b(no agent sessions found)%b\t\n' "$C_DIM" "$RESET"
fi
