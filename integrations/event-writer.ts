import { execFile } from "node:child_process";
import { dirname, isAbsolute, resolve } from "node:path";
import { fileURLToPath } from "node:url";

export type State = "working" | "waiting" | "idle" | "error" | "ended";

// Keep event order even when a harness invokes hooks concurrently. Failure must
// never interrupt an agent run. Native state expires if this writer disappears.
export function eventWriter(agent: string) {
  const root = process.env.TMUX_FLEET_DIR ?? resolve(dirname(fileURLToPath(import.meta.url)), "..");
  const enabled = isAbsolute(root) && !!process.env.TMUX && !!process.env.TMUX_PANE;
  const script = resolve(root, "scripts/fleet-event.sh");
  let queue = Promise.resolve();
  let current: [string, State, string] | undefined;
  let timer: ReturnType<typeof setInterval> | undefined;
  let pending = 0;

  function send(session: string, state: State, reason: string) {
    pending++;
    queue = queue.then(() => new Promise<void>((done) => {
      execFile("bash", [script, agent, String(process.pid), session, state, reason],
        // A collector may hold the shared lock while checking an API and many
        // panes. Match its 15s lock-wait budget plus subprocess overhead.
        { timeout: 20000, maxBuffer: 1024, windowsHide: true }, () => {
          pending--;
          done();
        });
    }));
    return queue;
  }

  return (session: string, state: State, reason = "") => {
    if (!enabled || !session) return Promise.resolve();
    current = [session, state, reason];
    if (state === "ended") {
      clearInterval(timer);
      timer = undefined;
      current = undefined;
    } else if (!timer) {
      timer = setInterval(() => {
        if (current && pending === 0) void send(...current);
      }, 10000);
      timer.unref();
    }
    return send(session, state, reason);
  };
}
