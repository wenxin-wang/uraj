// Exec runs in the sandbox, which cannot reach the Gateway's configuration.
// Configuration edits therefore go through a Gateway-side tool that invokes
// the checked command; the hook only redirects native CLI attempts.
import { execFile } from "node:child_process";

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

const redirect = {
  block: true,
  blockReason: "openclaw config set cannot run in the sandbox. Use the " +
    "openclaw_config_set tool with a dotted path and a JSON value.",
};

export function blockConfigSet(event) {
  if (event.toolName !== "exec" || event.toolKind === "code_mode_exec" ||
      event.toolInputKind === "javascript" || typeof event.params?.command !== "string") {
    return;
  }
  // Convenience only: a sandboxed shell has no OpenClaw CLI or credentials.
  if (/openclaw[\s\S]*\bconfig\s+set\b/.test(event.params.command)) return { ...redirect };
}

export function createConfigSetTool(run = runChecker) {
  return {
    name: "openclaw_config_set",
    description: "Change OpenClaw agent registrations, agent models or bindings " +
      "after Guix policy checks. Other settings are managed by Guix.",
    parameters: {
      type: "object",
      additionalProperties: false,
      required: ["path", "value"],
      properties: {
        path: {
          type: "string",
          description: "Dotted path, e.g. agents.defaults.model or bindings[0].agentId",
        },
        value: { description: "New JSON value" },
      },
    },
    async execute(_id, params) {
      if (typeof params?.path !== "string" || !Object.hasOwn(params, "value")) {
        throw new Error("openclaw_config_set needs a path and a value");
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
    api.registerTool(createConfigSetTool());
    api.on("before_tool_call", blockConfigSet, { matcher: ["exec"], priority: 100 });
  },
};
