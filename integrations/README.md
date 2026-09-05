# Optional native status adapters

Screen detection works without installing adapters. Native events improve completion
tracking for runs that start and finish between scans, and distinguish user prompts
from active work. These adapters send only agent/session IDs, state, and fixed reason
labels; no prompts, response content, or tool arguments.

Keep this repository at a stable absolute path. Both adapters resolve
`scripts/fleet-event.sh` relative to their own source file. An absolute
`TMUX_FLEET_DIR` overrides that location. Hooks call Bash with an argument array;
paths and session IDs never become shell source. No new runtime dependencies.

## Pi

Requires the `@earendil-works/pi-coding-agent` 0.85+ extension events. For one launch:

```sh
pi --extension /absolute/path/tmux-fleet/integrations/pi.ts
```

For automatic loading, create `~/.pi/agent/extensions/tmux-fleet.ts` containing:

```ts
export { default } from "/absolute/path/tmux-fleet/integrations/pi.ts";
```

The extension reports `agent_start` as working and `agent_settled` as idle/error.
`agent_end` alone is insufficient: retries, automatic compaction, and queued
continuations can follow it. Blocking extension UI prompts temporarily report
waiting; nested prompts remain waiting until all close. Manual compaction is also
tracked. Session replacement/reload/shutdown releases the previous identity.
Only TUI mode publishes; JSON, RPC, and print subagents cannot take over their
parent's tmux pane. Do not install this adapter on older Pi versions; use screen
detection there because missing settlement events could leave native state busy.

Pi's branch-summary navigation does not emit a completion hook on every error or
cancellation. The adapter does not invent a lifecycle for it; fleet may override
native idle with a positive working screen indicator during these operations.

## OpenCode

This is an optional **local server plugin with explicit session binding**. OpenCode
server events span multiple sessions and do not reliably identify the session shown
in a TUI. A first-busy-session guess can report another agent's state.

Create `.opencode/plugins/tmux-fleet.ts` in the project (or the corresponding
global OpenCode plugins directory):

```ts
export { default } from "/absolute/path/tmux-fleet/integrations/opencode.ts";
```

For an existing root session, launch the local TUI with matching IDs:

```sh
TMUX_FLEET_OPENCODE_SESSION_ID=ses_existing_id opencode --session ses_existing_id
```

Use a dedicated TUI for that session. Without a pin, or if the ID is invalid or
belongs to a child agent, the adapter does nothing. Other roots and child events
are ignored. Busy/retry map to working; permission/question requests map to waiting
until all requests are answered; idle maps to idle. Terminal session errors persist
until work resumes. The first relevant event establishes state; startup does not
guess idle for an already-running session.

An observed `tui.session.select` away from the pin releases native status until
restart. Ordinary navigation may not emit that server event, so switching sessions
in a pinned TUI is unsupported. Remote/shared servers, `opencode attach`, and
headless servers should use screen detection. The collector verifies the writer
PID belongs to the detected pane agent; a server without that association is ignored.

## Lifetime and tests

Events are ordered, heartbeat every 10 seconds, and expire after 30 seconds without
a refresh. Hook shutdown/disposal sends `ended`; unexpected process death is also
rejected by PID validation. Writer failures are swallowed so fleet cannot fail an
agent operation. Installation here never modifies global agent settings.

Run adapter regression tests with Node 22.18+ (native TypeScript stripping):

```sh
node --test tests/native-adapters.test.mjs
```

The tests mock harness hooks and the event writer executable; live harness UI
installation remains an opt-in integration check.
