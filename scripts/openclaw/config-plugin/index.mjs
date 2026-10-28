// Exec runs in the sandbox, which cannot reach the Gateway's configuration.
// Configuration edits therefore go through a Gateway-side tool that invokes
// the checked command; a Unix socket exposes the same capability to the CLI.
import { AgentIdentityProxy } from "./agent-identity-proxy.mjs";
import { createConfigCommand, createConfigProxyService } from "./config-proxy.mjs";
import { execFile } from "node:child_process";
import { createGroupModelCommand } from "./group-model.mjs";
import { createMentionCommand } from "./mention.mjs";
import { registerPersonas } from "./persona-runtime.mjs";

const CHECKER = "/etc/openclaw/config.mjs";

// Asynchronous: the checker calls back into this Gateway over RPC, which a
// blocked event loop could never answer.
function runChecker(args) {
  return new Promise((resolve) => {
    execFile(process.execPath, [CHECKER, ...args],
      { encoding: "utf8", timeout: 180_000, maxBuffer: 1024 * 1024 },
      (error, stdout, stderr) => resolve({ ok: !error, stdout, stderr }));
  });
}

export function createConfigSetTool(run = runChecker) {
  return {
    name: "openclaw_config_set",
    description: "Change the default OpenClaw model after Guix policy checks. " +
      "Use /persona to create roles or change their routing and /mention for mention gating.",
    parameters: {
      type: "object",
      additionalProperties: false,
      required: ["path", "value"],
      properties: {
        path: {
          type: "string",
          description: "Dotted path: agents.defaults.model",
        },
        value: { description: "New JSON value" },
      },
    },
    async execute(_id, params) {
      if (typeof params?.path !== "string" || !Object.hasOwn(params, "value")) {
        throw new Error("openclaw_config_set needs a path and a value");
      }
      if (params.path.startsWith("channels")) {
        throw new Error("Use /mention in the group; only the Feishu group owner or command owner can change it");
      }
      if (params.path !== "agents.defaults.model") {
        throw new Error("Use /persona for agent registrations and bindings; this tool only changes agents.defaults.model");
      }
      // The checker validates before and after native normalization, and
      // never echoes native diagnostics that may contain credentials.
      const result = await run(["set", params.path, JSON.stringify(params.value)]);
      const ok = result.ok;
      const text = (ok ? result.stdout : result.stderr || "Configuration check failed")
        .trim();
      return { content: [{ type: "text", text }], details: { ok } };
    },
  };
}

export default {
  id: "uraj-config-policy",
  name: "Guix checked configuration",
  register(api) {
    const personas = registerPersonas(api);
    const mention = createMentionCommand(runChecker);
    const mentionHandler = mention.handler;
    mention.handler = async (ctx) => {
      const reply = await mentionHandler(ctx);
      const chat = /^chat:(oc_[a-zA-Z0-9]+)$/.exec(ctx.to ?? "")?.[1];
      personas.allowControlReply(chat, reply.text);
      return reply;
    };
    api.registerCommand(mention);
    // Like /mention, its replies must pass the paused-group reply filter.
    const groupModel = createGroupModelCommand(runChecker);
    const groupModelHandler = groupModel.handler;
    groupModel.handler = async (ctx) => {
      const reply = await groupModelHandler(ctx);
      const chat = /^chat:(oc_[a-zA-Z0-9]+)$/.exec(ctx.to ?? "")?.[1];
      personas.allowControlReply(chat, reply.text);
      return reply;
    };
    api.registerCommand(groupModel);
    const configTool = createConfigSetTool();
    api.registerTool(configTool);
    const identities = new AgentIdentityProxy({
      config: () => api.runtime.config.current(),
      setIdentity: (id, workspace, identity) => personas.setIdentity(id, workspace, identity),
    });
    api.on("before_tool_call", async (event, ctx) => {
      if (event.toolName !== "exec") return;
      try { await identities.prepare(ctx.agentId); }
      catch {
        // Ordinary shell work remains usable; identity commands fail without
        // a valid capability. Never log workspace contents or the token.
        api.logger?.warn("Could not prepare scoped CLI identity capability");
      }
    }, { matcher: ["exec"], priority: 100 });
    api.registerService(createConfigProxyService(createConfigCommand(
      configTool, () => api.runtime.config.current(), identities)));
  },
};
