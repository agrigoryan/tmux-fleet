# shellcheck shell=bash
# Preserve the activity column without classifying arbitrary transcript text.
fleet_message() {
  local state="$1" content="$2" title="$3" reason="$4" name="$5" message="$4"
  if [ -z "$message" ]; then
    case "$state" in
      working)
        message="$(printf '%s\n' "$content" | awk 'NF' | tail -20 |
          grep -E 'Working|Retrying|[Cc]ompacting|[Ss]ummarizing branch|^[[:space:]]*[✳✽✶✻✢·].*…' | tail -1)"
        ;;
      waiting)
        message="$(printf '%s\n' "$content" | awk 'NF' | tail -20 |
          grep -iE 'Do you want|Would you like|Do you trust|Allow this|Run this command|Permission required|Question [0-9]+/' | tail -1)"
        ;;
    esac
  fi
  if [ -z "$message" ]; then
    message="$(printf '%s' "$title" | sed -E 's/^[⠀-⣿✳✻✽✶✢·[:space:]]+//')"
    case "$message" in 'Claude Code'|'Codex'|'Gemini CLI') message="" ;; esac
  fi
  [ -n "$message" ] || message="$name"
  # UI rows use tabs as framing. No data field may introduce another column.
  message="$(printf '%s' "$message" | tr '\001-\037\177' ' ')"
  if [ "${#message}" -gt 80 ]; then message="${message:0:79}…"; fi
  printf '%s' "$message"
}
