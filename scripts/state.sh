# shellcheck shell=bash
# Pure transition function; unknown samples never manufacture completion.
# Outputs: persisted state, unseen, had-work, pending-idle timestamp, display state.
fleet_transition() {
  local observed="$1" last="$2" unseen="$3" had_work="$4" pending="$5"
  local visible="$6" now="$7" authoritative="${8:-0}" display
  case "$last" in working|waiting|idle|error|unknown) ;; *) last=unknown ;; esac
  if [ "$visible" = 1 ]; then unseen=0; fi
  display="$observed"
  case "$observed" in
    working)
      last=working; had_work=1; unseen=0; pending=0 ;;
    waiting|error)
      last="$observed"; pending=0 ;;
    idle)
      if [ "$had_work" = 1 ] && [ "$authoritative" != 1 ] && [ "$visible" != 1 ]; then
        if [ "$pending" = 0 ] || [ "$now" -lt "$pending" ]; then
          pending="$now"; display="$last"
        elif [ "$now" -le "$pending" ]; then
          display="$last"
        else
          last=idle; pending=0; had_work=0
          [ "$visible" = 1 ] || unseen=1
        fi
      else
        if [ "$had_work" = 1 ] && [ "$visible" != 1 ]; then unseen=1; fi
        last=idle; pending=0; had_work=0
      fi
      ;;
    *) display=unknown; pending=0 ;;
  esac
  if [ "$display" = idle ] && [ "$unseen" = 1 ]; then display=done; fi
  printf '%s %s %s %s %s\n' "$last" "$unseen" "$had_work" "$pending" "$display"
}
