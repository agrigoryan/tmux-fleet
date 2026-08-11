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

# fzf "0.61.3" -> "61" (minor); returns 0 if fzf missing
fzf_minor_version() {
  command -v fzf >/dev/null 2>&1 || { echo 0; return; }
  fzf --version 2>/dev/null | grep -oE '^[0-9]+\.[0-9]+' | cut -d. -f2
}
