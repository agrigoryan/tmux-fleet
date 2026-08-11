# tmux-fleet

See every AI coding-agent session running anywhere on your tmux server — status, current
activity, live preview — and jump to any of them with one keystroke.

```
● waiting claude   reachlabs:1.4   reach_server   permission prompt
● done    claude   reachlabs:2.2   reach_app      Build onboarding screens
● working claude   reachlabs:3.1   reachlabs      Pondering… (53s · ↓ 749 tokens)
● idle    codex    sandbox:1.1     video-abr      transcoding video pipeline
```

`prefix + a` opens a popup with the list. `Enter` jumps to the pane (across sessions),
`ctrl-r` refreshes, `ctrl-x` kills the selected pane. The list auto-refreshes every 2s and the
preview shows the live pane content.

Works with agents started any way, in any pane — nothing needs to be launched through a
wrapper. Detects Claude Code, Codex, Gemini, Aider, OpenCode, Cursor, and friends.

## States

| State | Meaning |
|---|---|
| `waiting` (yellow, top) | needs you — permission prompt or input |
| `error` (red) | auth error / API failure banner |
| `done` (cyan) | finished working while you weren't looking (clears when you visit) |
| `working` (green) | actively running |
| `idle` (dim) | at the prompt, seen |

## How detection works

Three tiers, best available wins (see `docs/agent-session-monitoring/` in this repo for the
full research):

1. **Claude Code supervisor API** — `claude agents --json` reports `busy|idle|waiting` per pid;
   joined to panes via pid → tty → `#{pane_tty}`. Exact, zero config. Cached 3s.
2. **Process scan** — one `ps` pass matching agent CLI names against each pane's tty.
3. **Screen + title heuristics** — battle-tested patterns from herdr/agent-deck: braille
   spinner in the OSC pane title, `esc to interrupt` / `ctrl+c to interrupt`,
   spinner+ellipsis+token lines, `Do you want to proceed?` dialogs, `❯` prompt.

The `done` state is tracked with tmux pane user options (`@fleet_last_state`,
`@fleet_unseen`) — state lives in the tmux server and disappears with the pane.

## Install

Requires tmux ≥ 3.2 (≥ 3.0 degrades to `display-menu`), and fzf for the popup UI (falls back
to `display-menu` without it). `jq` + Claude Code CLI enable the supervisor-API tier.

**TPM** (if published as a repo):

```tmux
set -g @plugin 'aram/tmux-fleet'
```

**Direct** (from this monorepo), add to `~/.tmux.conf`:

```tmux
run-shell ~/devel/reachlabs/tmux-fleet/fleet.tmux
```

then `tmux source ~/.tmux.conf`.

## Options

```tmux
set -g @fleet-key 'a'                  # prefix + this key opens the popup
set -g @fleet-width '90%'              # popup width
set -g @fleet-height '75%'             # popup height
set -g @fleet-preview 'right,55%'      # fzf preview-window spec
set -g @fleet-refresh-interval '2'     # seconds; 0 disables auto-refresh
set -g @fleet-api-cache-ttl '3'        # claude agents --json cache seconds
set -g @fleet-process-pattern 'claude|codex|gemini|aider|opencode|cursor-agent|amp|goose|droid|copilot|grok|crush|pi'
```

## Status-line summary

Put `#{fleet_status}` anywhere in `status-right`/`status-left` **before** the `run-shell`
line, and it becomes e.g. `⏳1 ✔2 ⚙3` (waiting / done-unseen / working counts):

```tmux
set -g status-right '#{fleet_status} | %H:%M'
run-shell ~/devel/reachlabs/tmux-fleet/fleet.tmux
```

(Or call `scripts/fleet-summary.sh` directly via `#()`.)

## Files

- `fleet.tmux` — TPM entrypoint: keybinding + status-line interpolation
- `scripts/fleet-list.sh` — detection engine; emits the agent table (also `--states`)
- `scripts/fleet-picker.sh` — fzf popup UI
- `scripts/fleet-menu.sh` — `display-menu` fallback (no fzf / old tmux)
- `scripts/fleet-summary.sh` — status-line segment

## Design notes / research

Full write-ups in [`docs/agent-session-monitoring/`](../docs/agent-session-monitoring/):
prior art (cmux, herdr, claude-squad), the tmux plugin ecosystem, Claude Code's external
status signals (supervisor API, hooks, statusline, OSC titles), and verified tmux/fzf popup
mechanics.
