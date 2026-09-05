# shellcheck shell=bash
# Shared helpers for tmux-fleet.

get_tmux_option() {
  local option="$1" default_value="$2" option_value
  option_value="$(tmux show-option -gqv "$option")"
  if [ -z "$option_value" ]; then
    echo "$default_value"
  else
    echo "$option_value"
  fi
}

# "3.5a" -> "35"; "3.2" -> "32" (digits only, for numeric comparison)
tmux_version_num() {
  tmux -V | grep -oE '[0-9]+\.[0-9]+' | head -1 | tr -d '.'
}

# Rendered-list cache, unique per user + tmux server socket.
fleet_cache_file() {
  local dir
  dir="$(fleet_runtime_dir)" || return 1
  printf '%s/list\n' "$dir"
}

fleet_shell_quote() {
  printf "'%s'" "${1//\'/\'\\\'\'}"
}

# file_age_lt <path> <seconds> — files and lock directories are supported.
file_age_lt() {
  local f="$1" max="$2" now mtime
  [ -e "$f" ] || return 1
  now="$(date +%s)"
  case "$(uname -s)" in
    Darwin|*BSD) mtime="$(stat -f %m "$f" 2>/dev/null || true)" ;;
    *) mtime="$(stat -c %Y "$f" 2>/dev/null || true)" ;;
  esac
  case "$mtime" in ''|*[!0-9]*) return 1 ;; esac
  [ "$now" -ge "$mtime" ] && [ $((now - mtime)) -lt "$max" ]
}

# Private, server-lifetime namespace: restarted servers cannot reuse pane caches.
fleet_runtime_dir() {
  local server key dir
  server="$(tmux display-message -p '#{socket_path}:#{pid}' 2>/dev/null)" || return 1
  [ -n "$server" ] || return 1
  key="$(printf '%s' "$server" | cksum | awk '{print $1}')"
  dir="${TMPDIR:-/tmp}/tmux-fleet-$(id -u)-$key"
  (umask 077; mkdir -p "$dir") || return 1
  [ ! -L "$dir" ] && [ -O "$dir" ] || return 1
  printf '%s\n' "$dir"
}

fleet_uint() {
  case "$1" in ''|*[!0-9]*) printf '%s\n' "$2" ;; *) printf '%s\n' "$1" ;; esac
}

# mkdir locks work on both macOS and Linux, without a flock dependency.
# Every writer (collector, event bridge, focus acknowledgement) uses this lock.
fleet_lock_acquire() {
  local lock="$1" attempts="${2:-300}" owner owner_valid lock_inode i=0
  while ! mkdir "$lock" 2>/dev/null; do
    lock_inode="$(ls -di "$lock" 2>/dev/null | awk '{print $1}' || true)"
    owner="$(cat "$lock/pid" 2>/dev/null || true)"
    case "$owner" in ''|*[!0-9]*) owner_valid=0 ;; *) owner_valid=1 ;; esac
    if { [ "$owner_valid" = 1 ] && ! kill -0 "$owner" 2>/dev/null; } ||
       { [ "$owner_valid" = 0 ] && ! file_age_lt "$lock" 10; }; then
      # Only one contender reaps a dead owner; never remove another live lock.
      if mkdir "$lock/reaping" 2>/dev/null; then
        if [ -n "$lock_inode" ] &&
           [ "$(ls -di "$lock" 2>/dev/null | awk '{print $1}')" = "$lock_inode" ] &&
           [ "$(cat "$lock/pid" 2>/dev/null)" = "$owner" ]; then
          rm -f "$lock/pid"
          rmdir "$lock/reaping" "$lock" 2>/dev/null || true
        else
          rmdir "$lock/reaping" 2>/dev/null || true
        fi
      fi
    fi
    i=$((i + 1))
    [ "$i" -lt "$attempts" ] || return 1
    sleep 0.05
  done
  if ! printf '%s\n' "$$" >"$lock/pid"; then
    rmdir "$lock" 2>/dev/null || true
    return 1
  fi
}

fleet_lock_release() {
  local lock="$1"
  if [ "$(cat "$lock/pid" 2>/dev/null)" = "$$" ]; then
    rm -f "$lock/pid"
    rmdir "$lock" 2>/dev/null || true
  fi
}

# Atomic publication using a unique file on the destination filesystem.
fleet_publish() {
  local source="$1" destination="$2" temporary
  temporary="$(mktemp "$destination.XXXXXX")" || return 1
  if cp "$source" "$temporary" && mv -f "$temporary" "$destination"; then
    return 0
  fi
  rm -f "$temporary"
  return 1
}

# Bounded read-only helper command. Never let a stuck CLI freeze the picker.
fleet_timeout() {
  local seconds="$1" output="$2" child watchdog result
  shift 2
  (trap - EXIT INT TERM HUP; exec "$@") >"$output" 2>/dev/null &
  child=$!
  (
    # Subshells inherit EXIT traps: the collector cleanup must never run here.
    trap - EXIT INT TERM HUP
    sleeper=""
    # wait on a background sleep so TERM interrupts promptly; a foreground
    # sleep would delay the trap and could outlive a successful CLI command.
    trap 'if [ -n "$sleeper" ]; then kill "$sleeper" 2>/dev/null || true; wait "$sleeper" 2>/dev/null || true; fi; exit 0' TERM INT HUP
    sleep "$seconds" & sleeper=$!
    wait "$sleeper" || exit 0
    sleeper=""
    kill -TERM "$child" 2>/dev/null || exit 0
    sleep 0.2 & sleeper=$!
    wait "$sleeper" || exit 0
    sleeper=""
    kill -KILL "$child" 2>/dev/null || true
  ) &
  watchdog=$!
  if wait "$child" 2>/dev/null; then result=0; else result=$?; fi
  kill "$watchdog" 2>/dev/null || true
  wait "$watchdog" 2>/dev/null || true
  return "$result"
}

# fzf "0.61.3" -> "61" (minor); returns 0 if fzf missing
fzf_minor_version() {
  command -v fzf >/dev/null 2>&1 || { echo 0; return; }
  fzf --version 2>/dev/null | grep -oE '^[0-9]+\.[0-9]+' | cut -d. -f2
}
