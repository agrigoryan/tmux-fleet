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
  printf '%s/tmux-fleet-list-%s-%s.txt' "${TMPDIR:-/tmp}" "$(id -u)" \
    "$(tmux display-message -p '#{socket_path}' 2>/dev/null | tr '/' '_')"
}

# file_age_lt <file> <seconds> — true if file exists and is younger
file_age_lt() {
  local f="$1" max="$2" now mtime
  [ -f "$f" ] || return 1
  now="$(date +%s)"
  mtime="$(stat -f %m "$f" 2>/dev/null || stat -c %Y "$f" 2>/dev/null || echo 0)"
  [ $((now - mtime)) -lt "$max" ]
}

# fzf "0.61.3" -> "61" (minor); returns 0 if fzf missing
fzf_minor_version() {
  command -v fzf >/dev/null 2>&1 || { echo 0; return; }
  fzf --version 2>/dev/null | grep -oE '^[0-9]+\.[0-9]+' | cut -d. -f2
}
