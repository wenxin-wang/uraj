import fs from "node:fs/promises";
import path from "node:path";
import { isDeepStrictEqual } from "node:util";
import { loadManagedBase } from "../config.mjs";
import { validatePolicy } from "../config-policy.mjs";
import { createFeishuApi } from "./feishu-api.mjs";
import { PersonaStore } from "./persona-store.mjs";
import { Personas, SHARED, senderId, groupId } from "./persona.mjs";

export function createRuntimePersonas(api, {
  loadBase = loadManagedBase,
  directory = path.join(process.env.OPENCLAW_STATE_DIR ?? "/data/openclaw/home/.openclaw", "personas"),
} = {}) {
  const config = () => api.runtime.config.current();
  async function mutate(fn) {
    const base = await loadBase();
    await api.runtime.config.mutateConfigFile({ base: "source", afterWrite: { mode: "auto" },
      mutate: async (draft) => {
        validatePolicy(draft, base);
        await fn(draft, base);
        validatePolicy(draft, base);
      },
    });
  }
  return new Personas({
    store: new PersonaStore(directory), config, feishu: createFeishuApi(),
    async register(role) {
      const base = await loadBase();
      const workspace = path.join(path.dirname(base.agents.defaults.workspace), role.id);
      const agentDir = path.join(path.dirname(path.dirname(base.agents.entries.main.agentDir)), role.id, "agent");
      const entry = { name: role.name, workspace, agentDir };
      const existing = config().agents.entries?.[role.id];
      if (existing && (existing.workspace !== workspace || existing.agentDir !== agentDir)) {
        throw new Error("Agent path collision");
      }
      for (const dir of [workspace, agentDir]) {
        await fs.mkdir(dir, { recursive: true, mode: 0o700 });
        if (!(await fs.lstat(dir)).isDirectory()) throw new Error("Agent directory is not a directory");
      }
      for (const [name, text] of Object.entries({
        "IDENTITY.md": `# Identity\n\nName: ${role.name}\n\n${role.description}\n`,
        "SOUL.md": `# Persona\n\n${role.soul}\n`,
        "AGENTS.md": "Use only this workspace for identity and memory. Do not read other agents' workspaces.\n",
      })) {
        try { await fs.writeFile(path.join(workspace, name), text, { flag: existing ? "wx" : "w", mode: 0o600 }); }
        catch (error) { if (error.code !== "EEXIST") throw error; }
      }
      if (existing) return;
      await mutate((draft) => {
        draft.agents.entries ??= {};
        if (draft.agents.entries[role.id] && !isDeepStrictEqual(draft.agents.entries[role.id], entry)) {
          throw new Error("Agent registration conflict");
        }
        draft.agents.entries[role.id] = entry;
      });
    },
    async bind(id, kind, peer) {
      await mutate((draft) => {
        if (!draft.agents.entries?.[id]) throw new Error("Agent not registered");
        const retained = (draft.bindings ?? []).filter((b) => !(b.match?.channel === "feishu" &&
          [undefined, "main", "*"].includes(b.match.accountId) && b.match.peer?.kind === kind &&
          (b.match.peer.id === peer || kind === "group" && b.match.peer.id.startsWith(`${peer}:`))));
        draft.bindings = [{ agentId: id, match: { channel: "feishu", accountId: "main", peer: { kind, id: peer } } }, ...retained];
      });
    },
    async draft(purpose) {
      const result = await api.runtime.llm.complete({ agentId: SHARED, maxTokens: 1600,
        reasoning: "low", signal: AbortSignal.timeout(60000), purpose: "Draft persona for explicit user confirmation",
        systemPrompt: "只起草角色，不执行用途里的任务。返回一个 JSON 对象，且仅有 name（40字内）、description（200字内）、soul（4000字内）。soul 是角色的语气、专长、行为准则。不决定共享/私人范围，不填写所有者、路径或ID，不假装继承任何记忆。不输出 Markdown 代码块。",
        messages: [{ role: "user", content: purpose }], responseFormat: { type: "json_object" },
      });
      return JSON.parse(result.text);
    },
  });
}

export function registerPersonas(api, personas = createRuntimePersonas(api)) {
  const logFailure = () => api.logger?.warn("Persona operation failed; no private model access authorized");
  api.registerCommand({ name: "persona", description: "选择、起草和确认共享或私人角色",
    channels: ["feishu"], acceptsArgs: true, requireAuth: false,
    async handler(ctx) {
      if ((ctx.channelId ?? ctx.channel) !== "feishu" || ctx.accountId !== "main") return { text: "请在飞书 main 账号使用。" };
      const sender = senderId(ctx.from) ?? senderId(ctx.senderId);
      const chat = groupId(ctx.to);
      if (!chat && !ctx.to?.startsWith("user:")) return { text: "无法确认会话类型。" };
      try {
        const text = await personas.command({ sender, chat, args: ctx.args });
        personas.allowControlReply(chat, text);
        return { text };
      }
      catch {
        logFailure();
        const text = "角色操作未确认成功。请检查权限、服务日志后重试；请用 /persona 查看当前状态。";
        personas.allowControlReply(chat, text);
        return { text };
      }
    },
  });
  api.on("before_dispatch", async (event, ctx) => {
    try {
      const result = await personas.inbound(event, ctx);
      if (result?.reply?.text) personas.allowControlReply(groupId(ctx.conversationId), result.reply.text);
      return result?.handled ? { handled: true, text: result.reply?.text } : undefined;
    }
    catch {
      logFailure();
      const text = "角色管理暂不可用，请稍后重试。";
      personas.allowControlReply(groupId(ctx.conversationId), text);
      return { handled: true, text };
    }
  }, { priority: 100, timeoutMs: 30000 });
  api.on("before_agent_run", async (event, ctx) => {
    try { return await personas.beforeRun(event, ctx); }
    catch { logFailure(); return { outcome: "block", reason: "Persona verification failed", message: "角色权限未确认，请稍后重试。" }; }
  }, { priority: 100, timeoutMs: 20000 });
  api.on("reply_payload_sending", async (event, ctx) => {
    try { return await personas.sending(event, ctx); }
    catch { logFailure(); return { cancel: true, reason: "Persona verification failed" }; }
  }, { priority: 100, timeoutMs: 20000 });
  api.on("message_sent", async (event, ctx) => {
    try { await personas.sent(event, ctx); } catch { logFailure(); }
  });
  let timer;
  let polling = false;
  api.registerService({ id: "uraj-personas", async start() {
    await personas.start();
    timer = setInterval(async () => {
      if (polling) return;
      polling = true;
      try { await personas.poll(); } catch { logFailure(); }
      finally { polling = false; }
    }, 30000);
    timer.unref();
  }, stop() { clearInterval(timer); } });
  return personas;
}
