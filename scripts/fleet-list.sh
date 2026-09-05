#!/usr/bin/env bash
# One serialized collector for the picker, summary, monitor, and native events.
set -u
umask 077
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/helpers.sh"
source "$SCRIPT_DIR/classify.sh"
source "$SCRIPT_DIR/state.sh"
source "$SCRIPT_DIR/presentation.sh"
MODE="${1:-display}"
runtime="$(fleet_runtime_dir)" || exit 1
workdir="$(mktemp -d "$runtime/scan.XXXXXX")" || exit 1
locked=0
cleanup() {
  [ "$locked" = 0 ] || fleet_lock_release "$runtime/lock"
  rm -rf "$workdir"
}
trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM

emit_cache() {
  case "$MODE" in
    --collect) return ;;
    --states) [ ! -f "$runtime/states" ] || cat "$runtime/states" ;;
    *) [ ! -f "$runtime/list" ] || cat "$runtime/list" ;;
  esac
}
if ! fleet_lock_acquire "$runtime/lock"; then emit_cache; exit 1; fi
locked=1

TAB=$'\t' US=$'\x1f'
AGENT_REGEX="$(get_tmux_option @fleet-process-pattern 'claude|codex|gemini|aider|opencode|cursor-agent|amp|goose|droid|copilot|grok|crush|pi')"
API_TTL="$(fleet_uint "$(get_tmux_option @fleet-api-cache-ttl 3)" 3)"
panes_f="$workdir/panes" ps_f="$workdir/ps" agents_f="$workdir/agents"
api_cache="$runtime/api" map_f="$workdir/map"

# Preserve empty fields; title is last. A failed snapshot keeps the last cache.
format="#{pane_id}${US}#{pane_tty}${US}#{session_name}${US}#{window_index}${US}#{pane_index}${US}#{window_activity}${US}#{pane_active}${US}#{window_active}${US}#{session_attached}${US}#{pane_current_path}${US}#{@fleet_last_state}${US}#{@fleet_unseen}${US}#{@fleet_identity}${US}#{@fleet_had_work}${US}#{@fleet_pending_idle}${US}#{@fleet_event_agent}${US}#{@fleet_event_pid}${US}#{@fleet_event_session}${US}#{@fleet_event_state}${US}#{@fleet_event_reason}${US}#{@fleet_event_time}${US}#{@fleet_event_identity}${US}#{pane_title}"
# tmux escapes control characters other than tabs (US becomes literal \\037).
format="${format//$US/$TAB}"
if ! tmux list-panes -a -F "$format" >"$panes_f" 2>/dev/null ||
   ! LC_ALL=C ps -eo pid=,ppid=,pgid=,stat=,tty=,lstart=,args= >"$ps_f" 2>/dev/null; then
  emit_cache; exit 1
fi
awk -F '\t' -v OFS="$US" '{$1=$1; print}' "$panes_f" >"$workdir/decoded-panes"
mv "$workdir/decoded-panes" "$panes_f"

# Linked windows may list one pane in several sessions. Prefer any viewed copy.
awk -F "$US" '
  !seen[$1]++ { order[++n]=$1; row[$1]=$0 }
  $7==1 && $8==1 && $9>0 { row[$1]=$0 }
  END { for(i=1;i<=n;i++) print row[order[i]] }
' "$panes_f" >"$workdir/unique-panes"
mv "$workdir/unique-panes" "$panes_f"

# Keep PID + start identity, never cached tty alone. Failed APIs back off for 30s.
if ! file_age_lt "$runtime/api.checked" "$API_TTL" &&
   ! file_age_lt "$runtime/api.failed" 30; then
  touch "$runtime/api.checked"
  if command -v claude >/dev/null 2>&1 && command -v jq >/dev/null 2>&1 &&
     fleet_timeout 2 "$workdir/api.json" claude agents --json &&
     jq -e 'type == "array"' "$workdir/api.json" >/dev/null 2>&1 &&
     jq -r '.[] | select(.kind == "interactive") |
       select(.status == "busy" or .status == "waiting" or .status == "idle") |
       [(.pid|tostring), .status, (.waitingFor // ""), (.name // "")] |
       map(tostring | gsub("[\t\r\n\u001f]"; " ")) | join("\t")' \
       "$workdir/api.json" >"$workdir/api.raw" 2>/dev/null; then
    awk -v pf="$ps_f" -v OFS="$TAB" '
      FILENAME == pf { identity[$1]=$1 ":" $6 "_" $7 "_" $8 "_" $9 "_" $10; next }
      { split($0,a,"\t"); if (a[1] in identity) print a[1],identity[a[1]],a[2],a[3],a[4] }
    ' "$ps_f" "$workdir/api.raw" >"$workdir/api"
    fleet_publish "$workdir/api" "$api_cache"
    rm -f "$runtime/api.failed"
  else
    touch "$runtime/api.failed"
    : >"$workdir/api"
    fleet_publish "$workdir/api" "$api_cache"
  fi
fi
[ -f "$api_cache" ] || : >"$api_cache"
awk -v re="$AGENT_REGEX" -v api_file="$api_cache" -f "$SCRIPT_DIR/process-map.awk" "$ps_f" >"$map_f"

# Process ownership is mandatory even for API/native status.
awk -v OFS="$US" -v af="$api_cache" -v mf="$map_f" -v sep="$US" '
  FILENAME == af { split($0,a,"\t"); api[a[1]]=a[2] OFS a[3] OFS a[4] OFS a[5]; next }
  FILENAME == mf { split($0,a,"\t"); agent[a[1]]=a[2]; pid[a[1]]=a[3]; identity[a[1]]=a[4]; next }
  {
    split($0,p,sep); tty=p[2]; sub(/^\/dev\//,"",tty)
    if (p[1] !~ /^%[0-9]+$/ || !(tty in agent) || seen[p[1]]++) next
    status=""; reason=""; name=""
    split(api[pid[tty]],a,sep)
    if (agent[tty]=="claude" && a[1]==identity[tty]) {status=a[2];reason=a[3];name=a[4]}
    print agent[tty],pid[tty],identity[tty],status,reason,name,$0
  }
' "$api_cache" "$map_f" "$panes_f" >"$agents_f"

# Capture failures (including a pane disappearing mid-batch) are unknown samples.
if [ -s "$agents_f" ]; then
  cap_args=()
  while IFS="$US" read -r _ _ _ _ _ _ pane_id rest; do
    cap_args+=(display-message -p "@@FLEET@@${pane_id#%}" ";" capture-pane -p -J -t "$pane_id" ";")
  done <"$agents_f"
  unset "cap_args[$((${#cap_args[@]} - 1))]"
  tmux "${cap_args[@]}" >"$workdir/captures" 2>/dev/null || true
  # Replace the whole NBSP character, not individual UTF-8 bytes.
  sed $'s/\302\240/ /g' "$workdir/captures" | awk -v dir="$workdir" '
    /^@@FLEET@@[0-9]+$/ { f=dir "/cap_" substr($0,10); next }
    f { print > f }
  '
fi

: >"$workdir/rows"
: >"$workdir/states"
now="$(date +%s)"
updates=()
while IFS="$US" read -r agent agent_pid identity api_status api_reason api_name \
  pane_id pane_tty sess widx pidx activity pane_active window_active attached path \
  last unseen old_identity had_work pending event_agent event_pid event_session \
  event_state event_reason event_time event_identity title; do
  content=""
  [ ! -f "$workdir/cap_${pane_id#%}" ] || content="$(<"$workdir/cap_${pane_id#%}")"
  screen="$(fleet_classify "$agent" "$content" "$title")"
  state="$screen" authoritative=0 reason=""
  native=0
  event_time="$(fleet_uint "$event_time" 0)"
  if [ "$event_agent" = "$agent" ] && [ "$event_pid" = "$agent_pid" ] &&
     [ "$event_identity" = "$identity" ] && [ -n "$event_session" ]; then
    identity="$identity/$event_session"
    if [ "$now" -ge "$event_time" ] && [ $((now - event_time)) -le 30 ]; then
      case "$event_state" in working|waiting|idle|error) native=1 ;; esac
    fi
  fi
  if [ "$native" = 1 ]; then
    state="$event_state" authoritative=1 reason="$event_reason"
    # Exact native transitions were already applied by the event writer. If
    # had-work remains during native idle, it came from a manual screen-only
    # operation: require the same idle confirmation as any other screen state.
    if [ "$state" = idle ]; then
      authoritative=0
      case "$screen" in
        working|waiting|error) state="$screen" ;;
        unknown) [ "$had_work" != 1 ] || state=unknown ;;
      esac
    elif [ "$state" = working ] && [ "$screen" = waiting ]; then
      state=waiting
    fi
  else
    case "$api_status" in
      busy) state=working ;;
      waiting) state=waiting; reason="$api_reason" ;;
      idle) state=idle ;;
    esac
    # A current dialog/error is stronger evidence than a cached busy API row.
    case "$screen" in
      waiting|error) state="$screen" ;;
      working) [ "$api_status" != idle ] || state=working ;;
    esac
  fi
  unseen="$(fleet_uint "$unseen" 0)"
  had_work="$(fleet_uint "$had_work" 0)"
  pending="$(fleet_uint "$pending" 0)"
  if [ "$identity" != "$old_identity" ]; then
    last=unknown; unseen=0; had_work=0; pending=0
  fi
  visible=0
  if [ "$pane_active" = 1 ] && [ "$window_active" = 1 ] &&
     [ "$(fleet_uint "$attached" 0)" -gt 0 ]; then visible=1; fi
  read -r persisted unseen had_work pending display_state < <(
    fleet_transition "$state" "$last" "$unseen" "$had_work" "$pending" "$visible" "$now" "$authoritative")
  updates+=(set -p -t "$pane_id" @fleet_identity "$identity" ";"
    set -p -t "$pane_id" @fleet_last_state "$persisted" ";"
    set -p -t "$pane_id" @fleet_unseen "$unseen" ";"
    set -p -t "$pane_id" @fleet_had_work "$had_work" ";"
    set -p -t "$pane_id" @fleet_pending_idle "$pending" ";")
  printf '%s\n' "$display_state" >>"$workdir/states"
  case "$display_state" in
    waiting) color='1;33'; priority=0 ;;
    error) color='1;31'; priority=1 ;;
    done) color='1;36'; priority=2 ;;
    working) color='1;32'; priority=3 ;;
    idle) color='2;37'; priority=4 ;;
    *) color='2;37'; priority=5 ;;
  esac
  message="$(fleet_message "$display_state" "$content" "$title" "$reason" "$api_name")"
  location="$sess:$widx.$pidx" directory="${path##*/}"
  location="$(printf '%s' "$location" | tr '\001-\037\177' ' ')"
  directory="$(printf '%s' "$directory" | tr '\001-\037\177' ' ')"
  printf -v row '\033[%sm●\033[0m %-7s %-8s %-20s \033[2m%-14s\033[0m %s' \
    "$color" "$display_state" "${agent:0:8}" "${location:0:20}" "${directory:0:14}" "$message"
  printf '%s\t%s\t%s\t%s\n' "$priority" "$activity" "$row" "$pane_id" >>"$workdir/rows"
done <"$agents_f"

if [ -s "$agents_f" ]; then
  unset "updates[$((${#updates[@]} - 1))]"
  tmux "${updates[@]}" 2>/dev/null || true
fi
if [ -s "$workdir/rows" ]; then
  sort -t "$TAB" -k1,1n -k2,2nr "$workdir/rows" | cut -f3- >"$workdir/list"
else
  printf '\033[2m(no agent sessions found)\033[0m\t\n' >"$workdir/list"
fi
fleet_publish "$workdir/list" "$runtime/list"
fleet_publish "$workdir/states" "$runtime/states"
emit_cache
