#!/usr/bin/env bash
# fleet-picker.sh — fzf UI (runs inside a tmux display-popup).
# Enter jumps to the selected agent pane; falls back to display-menu without fzf.

set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=helpers.sh
source "$SCRIPT_DIR/helpers.sh"

LIST="$SCRIPT_DIR/fleet-list.sh"

command -v fzf >/dev/null 2>&1 || exec "$SCRIPT_DIR/fleet-menu.sh"

# fzf runs preview/bind commands via $SHELL -c; force POSIX sh so this works
# under fish/nushell/etc.
export SHELL=/bin/sh

preview_window="$(get_tmux_option "@fleet-preview" "right,55%")"
refresh_interval="$(get_tmux_option "@fleet-refresh-interval" "2")"

fzf_args=(
  --ansi --no-sort --layout=reverse --info=inline-right
  --delimiter $'\t' --with-nth 1
  --prompt 'agents ❯ '
  --header 'enter: jump · ctrl-r: refresh · ctrl-x: kill pane'
  --preview 'tmux capture-pane -ep -t {2} 2>/dev/null | tail -n "${FZF_PREVIEW_LINES:-40}"'
  --preview-window "$preview_window"
  --bind "ctrl-r:reload($LIST)+refresh-preview"
  --bind 'focus:refresh-preview'
  --bind "ctrl-x:execute-silent(tmux kill-pane -t {2})+reload(sleep 0.2; $LIST)"
)

if [ "$refresh_interval" != "0" ]; then
  if [ "$(fzf_minor_version)" -ge 73 ] 2>/dev/null; then
    fzf_args+=(--bind "every($refresh_interval):reload-sync($LIST)+refresh-preview")
  else
    # pre-0.73 timer: the load event re-fires after each reload completes,
    # so this self-chains into a refresh loop
    fzf_args+=(--bind "load:reload-sync(sleep $refresh_interval; $LIST)")
  fi
fi

selection="$("$LIST" | fzf "${fzf_args[@]}")" || exit 0

pane_id="${selection##*$'\t'}"
[ -n "$pane_id" ] || exit 0

exec tmux switch-client -Z -t "$pane_id"
