import type { Plugin } from "@opencode-ai/plugin";
import { eventWriter } from "./event-writer.ts";
import type { State } from "./event-writer.ts";

/** A server plugin cannot discover the displayed TUI session. Require a pin. */
const fleetOpenCode: Plugin = async ({ client }) => {
  const session = process.env.TMUX_FLEET_OPENCODE_SESSION_ID;
  if (!session || !process.env.TMUX || !process.env.TMUX_PANE) return {};

  // Ignore child agents and invalid IDs. Do not guess from the first busy event:
  // a server can have many simultaneously running root sessions.
  try {
    const result = await client.session.get({ path: { id: session } });
    if (!result.data || result.data.parentID) return {};
  } catch {
    return {};
  }

  const publish = eventWriter("opencode");
  const prompts = new Set<string>();
  let state: State | undefined;
  let disposed = false;
  let queue = Promise.resolve();
  const update = () => state
    ? publish(session, prompts.size ? "waiting" : state, prompts.size ? "input required" : "")
    : Promise.resolve();

  return {
    event: ({ event }) => {
      // Serialize bookkeeping as well as output: OpenCode can dispatch in parallel.
      queue = queue.then(async () => {
        if (disposed) return;
        // Local structural typing also supports newer permission/question events
        // when the installed plugin package reexports an older SDK Event union.
        const { type, properties } = event as unknown as {
          type: string;
          properties: { sessionID?: string; id?: string; requestID?: string;
            status?: { type: string }; info?: { id: string } };
        };
        if (type === "tui.session.select" && properties.sessionID !== session) {
          // Once navigation away is observed, release the pin until restart.
          disposed = true;
          await publish(session, "ended");
          return;
        }
        if ((properties.sessionID ?? properties.info?.id) !== session) return;
        if (type === "session.deleted") {
          disposed = true;
          await publish(session, "ended");
          return;
        }
        if (type === "session.status") {
          if (properties.status?.type === "idle") {
            state = state === "error" ? "error" : "idle";
            prompts.clear();
          } else if (["busy", "retry"].includes(properties.status?.type ?? "")) {
            state = "working";
          } else return;
        } else if (type === "session.error") {
          state = "error";
          prompts.clear();
        } else if (type === "permission.asked" || type === "question.asked") {
          if (!properties.id) return;
          prompts.add(`${type.split(".")[0]}:${properties.id}`);
          state ??= "working";
        } else if (["permission.replied", "question.replied", "question.rejected"].includes(type)) {
          if (!properties.requestID) return;
          prompts.delete(`${type.split(".")[0]}:${properties.requestID}`);
        } else return;
        await update();
      });
      return queue;
    },
    dispose: async () => {
      disposed = true;
      await queue;
      await publish(session, "ended");
    },
  };
};

export default fleetOpenCode;
