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
wrapper. Detects Claude Code, Codex, Antigravity (`agy`), Gemini, Aider, OpenCode, Cursor, and friends.

## States

| State | Meaning |
|---|---|
| `waiting` (yellow, top) | needs you — permission prompt or input |
| `error` (red) | auth error / API failure banner |
| `done` (cyan) | finished working while you weren't looking (clears when you visit) |
| `working` (green) | actively running |
| `idle` (dim) | at the prompt, seen |
| `unknown` (dim) | capture failed or the current UI has no reliable status signal |

## How detection works

One process snapshot identifies the foreground agent on each pane's tty, including agents
whose tool children temporarily own the foreground. Executable and interpreter entrypoints
are matched; filenames and arbitrary command arguments are not. Suspended/background jobs
are excluded. PID **and process start time** distinguish replacement agents in the same pane.

Status sources:

1. **Optional native events** — Pi and OpenCode adapters publish lifecycle and input events.
   See [native adapter installation](integrations/README.md). No harness configuration is
   changed automatically. Events require a matching foreground process identity; a 30s
   lease prevents dead integrations from remaining authoritative.
2. **Claude supervisor API** — `claude agents --json`, cached 3s, with PID/start validation.
   Calls time out after 2s and failures back off for 30s. Current screen dialogs/errors
   override cached API status; visible activity overrides a cached idle result.
3. **Harness-specific screen/title classifiers** — Claude, Codex, Antigravity (`agy`), Pi, and OpenCode each
   have their own prompt, permission, progress, and error patterns. Includes Pi 0.85's
   editor-border indicator and Codex's blinking `Action Required` titles. Other configured
   agents use a conservative generic fallback. Missing cues mean `unknown`, not `idle`.

A background collector polls every 2s even while the popup is closed. Unseen screen-based
completion requires two idle observations at least a second apart. A visible idle prompt is
acknowledged immediately. Missing/blank captures never imply
completion. Native settled events can record complete turns between polls. Without native
events, work that starts and finishes entirely between polls can still be missed; custom
UIs/keybindings may require new screen fixtures.

`done` is tracked in tmux pane options, bound to the current process/session identity. Focus
hooks acknowledge visits even between scans; linked windows count as viewed if any attached
session has the pane selected. Collector, native events, and focus updates share a lock.
Caches use unique temporary files, atomic publication, and a per-server namespace. Restarting
tmux cannot reuse the previous server's cache.

## Install

Requires tmux ≥ 3.2 (≥ 3.0 degrades to `display-menu`), and fzf for the popup UI (falls back
to `display-menu` without it). `jq` + Claude Code CLI enable the supervisor-API tier.

**TPM** (if published as a repo):

```tmux
set -g @plugin 'aram/tmux-fleet'
```

**Direct**, add the actual checkout path to `~/.tmux.conf`:

```tmux
run-shell ~/devel/oss/tmux-fleet/fleet.tmux
```

then `tmux source ~/.tmux.conf`. Reload after upgrading to install the monitor and focus hooks.
Repeated loading keeps one monitor per server and preserves unrelated hooks.

## Options

```tmux
set -g @fleet-key 'a'                  # prefix + this key opens the popup
set -g @fleet-width '90%'              # popup width
set -g @fleet-height '75%'             # popup height
set -g @fleet-preview 'right,55%'      # fzf preview-window spec
set -g @fleet-refresh-interval '2'     # seconds; 0 disables auto-refresh
set -g @fleet-poll-interval '2'        # background tracking; 0 stops monitor
set -g @fleet-api-cache-ttl '3'        # claude agents --json cache seconds
set -g @fleet-process-pattern 'claude|codex|gemini|aider|opencode|cursor-agent|amp|goose|droid|copilot|grok|crush|pi|agy'
```

## Status-line summary

Put `#{fleet_status}` anywhere in `status-right`/`status-left` **before** the `run-shell`
line, and it becomes e.g. `⏳1 ✔2 ⚙3` (waiting / done-unseen / working counts):

```tmux
set -g status-right '#{fleet_status} | %H:%M'
run-shell ~/devel/oss/tmux-fleet/fleet.tmux
```

(Or call `scripts/fleet-summary.sh` directly via `#()`.)

## Files

- `fleet.tmux` — TPM entrypoint: keybinding + status-line interpolation
- `scripts/fleet-list.sh` — detection engine; emits the agent table (also `--states`)
- `scripts/fleet-picker.sh` — fzf popup UI
- `scripts/fleet-menu.sh` — `display-menu` fallback (no fzf / old tmux)
- `scripts/fleet-summary.sh` — status-line segment
- `scripts/classify.sh` — per-harness screen/title classifiers
- `scripts/process-map.awk` — executable matching and foreground ancestry
- `scripts/state.sh` — completion transition logic
- `scripts/fleet-monitor.sh` — background collector lifecycle
- `scripts/fleet-event.sh` — native event and focus acknowledgement bridge
- `integrations/` — optional Pi/OpenCode adapters and installation instructions

## Verification

With tmux and jq available, no package install is needed. Shell suites run on Bash 3.2+; native adapter tests require
Node 22.18+ (built-in TypeScript stripping). The mock suites never access the user's tmux
server or agent processes.

```sh
bash tests/run.sh
bash tests/tmux-smoke.sh
```

The smoke test creates a dedicated temporary tmux server with a fake agent TUI, exercises
real tty/process joins and native events, then removes that test server. It needs permission
to create a local tmux socket and read the process table.
