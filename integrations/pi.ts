import type { ExtensionAPI, ExtensionContext } from "@earendil-works/pi-coding-agent";
import { eventWriter } from "./event-writer.ts";

/** Optional Pi 0.85+ extension. JSON/RPC/print subagents must not own the pane. */
export default function fleetPi(pi: ExtensionAPI) {
  const publish = eventWriter("pi");
  let busy = false;
  let prompts = 0;
  let failed = false;

  function update(ctx: ExtensionContext) {
    if (ctx.mode !== "tui") return Promise.resolve();
    return publish(ctx.sessionManager.getSessionId(),
      prompts ? "waiting" : busy ? "working" : failed ? "error" : "idle",
      prompts ? "input required" : failed ? "agent error" : "");
  }

  pi.on("session_start", async (_event, ctx) => {
    busy = !ctx.isIdle();
    prompts = 0;
    failed = false;
    await update(ctx);
  });
  pi.on("agent_start", async (_event, ctx) => {
    busy = true;
    failed = false;
    await update(ctx);
  });
  pi.on("agent_end", (event) => {
    const last = [...event.messages].reverse().find((message) => message.role === "assistant");
    failed = last?.role === "assistant" && last.stopReason === "error";
    // agent_end can precede retry/compaction; only agent_settled means idle.
  });
  pi.on("agent_settled", async (_event, ctx) => {
    busy = false;
    await update(ctx);
  });
  pi.on("ui_prompt_start", async (_event, ctx) => {
    prompts++;
    await update(ctx);
  });
  pi.on("ui_prompt_end", async (_event, ctx) => {
    prompts = Math.max(0, prompts - 1);
    await update(ctx);
  });
  pi.on("session_before_compact", async (_event, ctx) => {
    busy = true;
    await update(ctx);
  });
  pi.on("session_compact", async (event, ctx) => {
    // Pi emits this before clearing its manual-compaction flag, so ctx.isIdle()
    // is still false. Automatic compaction remains busy until agent_settled.
    if (event.reason === "manual") {
      busy = false;
      failed = false;
    }
    await update(ctx);
  });
  pi.on("session_compact_failed", async (event, ctx) => {
    if (event.reason === "manual") {
      busy = false;
      failed = !event.aborted;
    }
    await update(ctx);
  });
  pi.on("session_shutdown", async (_event, ctx) => {
    if (ctx.mode === "tui") await publish(ctx.sessionManager.getSessionId(), "ended");
  });
}
