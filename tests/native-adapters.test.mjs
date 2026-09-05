import assert from "node:assert/strict";
import { mkdtemp, mkdir, readFile, writeFile, rm } from "node:fs/promises";
import { tmpdir } from "node:os";
import { join } from "node:path";
import test from "node:test";
import pi from "../integrations/pi.ts";
import opencode from "../integrations/opencode.ts";
import { eventWriter } from "../integrations/event-writer.ts";

async function fixture(t) {
  const root = await mkdtemp(join(tmpdir(), "fleet-adapters-"));
  await mkdir(join(root, "scripts"));
  const log = join(root, "events");
  await writeFile(join(root, "scripts/fleet-event.sh"),
    'printf "%s\\t%s\\t%s\\t%s\\t%s\\n" "$1" "$2" "$3" "$4" "$5" >> "$FLEET_TEST_EVENT_LOG"\n');
  const env = {
    TMUX: "/tmp/fake,1,0", TMUX_PANE: "%1", TMUX_FLEET_DIR: root,
    TMUX_FLEET_OPENCODE_SESSION_ID: "root-session", FLEET_TEST_EVENT_LOG: log,
  };
  const previous = Object.fromEntries(Object.keys(env).map((key) => [key, process.env[key]]));
  Object.assign(process.env, env);
  t.after(async () => {
    for (const [key, value] of Object.entries(previous)) {
      if (value === undefined) delete process.env[key];
      else process.env[key] = value;
    }
    await rm(root, { recursive: true, force: true });
  });
  return async () => {
    const content = await readFile(log, "utf8").catch(() => "");
    return content.trim().split("\n").filter(Boolean).map((line) => line.split("\t"));
  };
}

test("Pi stays working through retries; nested prompts resume prior state", async (t) => {
  const events = await fixture(t);
  const hooks = new Map();
  pi({ on: (name, callback) => hooks.set(name, callback) });
  const ctx = { mode: "tui", isIdle: () => true,
    sessionManager: { getSessionId: () => "pi-session" } };
  const emit = (name, event = {}) => hooks.get(name)(event, ctx);
  t.after(() => emit("session_shutdown"));
  await emit("session_start");
  await emit("agent_start");
  await emit("agent_end", { messages: [{ role: "assistant", stopReason: "error" }] });
  assert.deepEqual((await events()).map((row) => row[3]), ["idle", "working"]);
  await emit("ui_prompt_start");
  await emit("ui_prompt_start");
  await emit("ui_prompt_end");
  await emit("ui_prompt_end");
  await emit("agent_end", { messages: [{ role: "assistant", stopReason: "stop" }] });
  await emit("agent_settled");
  assert.deepEqual((await events()).map((row) => row[3]),
    ["idle", "working", "waiting", "waiting", "waiting", "working", "idle"]);
  await emit("agent_start");
  await emit("agent_end", { messages: [{ role: "assistant", stopReason: "error" }] });
  await emit("agent_settled");
  assert.equal((await events()).at(-1)[3], "error");
});

test("Pi ignores headless subagents inheriting TMUX_PANE", async (t) => {
  const events = await fixture(t);
  const hooks = new Map();
  pi({ on: (name, callback) => hooks.set(name, callback) });
  for (const mode of ["rpc", "json", "print"]) {
    const ctx = { mode, isIdle: () => true, sessionManager: { getSessionId: () => "child" } };
    await hooks.get("session_start")({}, ctx);
    await hooks.get("agent_start")({}, ctx);
    await hooks.get("session_shutdown")({}, ctx);
  }
  assert.deepEqual(await events(), []);
});

test("Pi manual compaction completes before the harness clears its busy flag", async (t) => {
  const events = await fixture(t);
  const hooks = new Map();
  pi({ on: (name, callback) => hooks.set(name, callback) });
  const ctx = { mode: "tui", isIdle: () => false,
    sessionManager: { getSessionId: () => "pi-session" } };
  t.after(() => hooks.get("session_shutdown")({}, ctx));
  await hooks.get("session_before_compact")({ reason: "manual" }, ctx);
  await hooks.get("session_compact")({ reason: "manual", willRetry: false }, ctx);
  assert.deepEqual((await events()).map((row) => row[3]), ["working", "idle"]);
  await hooks.get("session_before_compact")({ reason: "manual" }, ctx);
  await hooks.get("session_compact_failed")({ reason: "manual", aborted: true }, ctx);
  assert.equal((await events()).at(-1)[3], "idle");
});

test("OpenCode pins a root session, tracks concurrent prompts, survives retry", async (t) => {
  const events = await fixture(t);
  const hooks = await opencode({ client: { session: { get: async () => ({ data: { id: "root-session" } }) } } });
  t.after(() => hooks.dispose());
  const emit = (type, properties = {}) => hooks.event({ event: {
    type, properties: { sessionID: "root-session", ...properties },
  } });
  await emit("session.status", { sessionID: "child", status: { type: "busy" } });
  await emit("permission.asked", { sessionID: "other-root", id: "p0" });
  assert.deepEqual(await events(), []);
  await emit("session.status", { status: { type: "busy" } });
  await Promise.all([
    emit("permission.asked", { id: "p1" }), emit("question.asked", { id: "q1" }),
    emit("permission.replied", { requestID: "p1" }),
  ]);
  assert.equal((await events()).at(-1)[3], "waiting");
  await emit("question.rejected", { requestID: "q1" });
  assert.equal((await events()).at(-1)[3], "working");
  await emit("session.status", { status: { type: "retry" } });
  assert.equal((await events()).at(-1)[3], "working");
  await emit("session.error");
  await emit("session.status", { status: { type: "idle" } });
  assert.equal((await events()).at(-1)[3], "error");
  await emit("session.status", { status: { type: "busy" } });
  await emit("session.status", { status: { type: "idle" } });
  assert.equal((await events()).at(-1)[3], "idle");
  await emit("tui.session.select", { sessionID: "other-root" });
  await emit("session.status", { status: { type: "busy" } });
  assert.equal((await events()).at(-1)[3], "ended");
});

test("OpenCode refuses a child pin or an unspecified session", async (t) => {
  const events = await fixture(t);
  const childClient = { session: { get: async () => ({ data: { id: "child", parentID: "parent" } }) } };
  assert.deepEqual(await opencode({ client: childClient }), {});
  delete process.env.TMUX_FLEET_OPENCODE_SESSION_ID;
  assert.deepEqual(await opencode({ client: { session: { get: () => assert.fail("unexpected API call") } } }), {});
  assert.deepEqual(await events(), []);
});

test("native writer tolerates collector lock contention beyond two seconds", async (t) => {
  const events = await fixture(t);
  const script = join(process.env.TMUX_FLEET_DIR, "scripts/fleet-event.sh");
  const original = await readFile(script, "utf8");
  await writeFile(script, 'if [ "$4" = working ]; then sleep 2.1; fi\n' + original);
  t.mock.timers.enable({ apis: ["setInterval"] });
  const publish = eventWriter("pi");
  t.after(() => publish("contended-session", "ended"));
  const pending = publish("contended-session", "working");
  // Heartbeats do not accumulate behind the slow lifecycle write.
  t.mock.timers.tick(40000);
  await pending;
  // Flush the entire queue so accidentally queued heartbeats cannot hide after
  // the first write resolves.
  await publish("contended-session", "ended");
  assert.deepEqual((await events()).map((row) => row[3]), ["working", "ended"]);
});
