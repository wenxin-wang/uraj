import { createHash, randomUUID } from "node:crypto";

export const SHARED = "household-shared";
const PRIVATE_HINT = "本群连接私人身份和记忆。新增成员后会暂停；恢复时请本人用 /persona 重新选择。";
const PAUSED = "私人角色已暂停：群成员发生变化或无法确认成员。请用 /persona 选择共享角色；恢复私人角色需本人手动选择。";
const safeId = (s) => typeof s === "string" && /^[a-z0-9][a-z0-9_-]*$/.test(s);
export const senderId = (s) => typeof s === "string" ? /^(?:feishu:)?(ou_[a-zA-Z0-9]+)$/.exec(s)?.[1] : undefined;
export const groupId = (s) => typeof s === "string" ? /^(?:chat:|feishu:)?(oc_[a-zA-Z0-9]+)(?::topic:[^\s]+)?$/.exec(s)?.[1] : undefined;
export function sessionAgent(key) {
  return typeof key === "string" ? /^agent:([a-z0-9_-]+):/.exec(key)?.[1] : undefined;
}
export function sessionGroup(key) {
  return typeof key === "string" ? /:group:(oc_[a-zA-Z0-9]+)(?::|$)/.exec(key)?.[1] : undefined;
}
// Feishu message-tool targets: optional provider and kind prefixes around an
// open chat or user ID.  Anything else is rejected rather than guessed.
export function feishuTarget(s) {
  if (typeof s !== "string") return null;
  const id = s.trim().replace(/^(?:feishu|lark):/i, "")
    .replace(/^(?:chat|group|channel|user|dm|open_id):/i, "").trim();
  return /^o[cu]_[a-zA-Z0-9]+$/.test(id) ? id : null;
}
const PRIVATE_GROUP_CONTEXT = "This Feishu group contains only the role owner and you, verified by membership checks. " +
  "For the owner's login or pairing, treat it as private: codes and verification links may be sent here.";
const SHARED_GROUP_CONTEXT = "In this shared Feishu group, send login/pairing codes privately with message " +
  "(action: send, target: user:<requester open_id>); acknowledge here without the code. " +
  "Keep the browser and follow-up in this group session. When a login wait is running, " +
  "report its result here without requiring a confirmation reply. " +
  "If the requester needs to report a problem, direct them to this group topic: " +
  "their private-chat replies go to another role and browser identity. " +
  "The message tool permits only this conversation or the requester's private chat.";
// Wake-ups have no sender; they continue the session's latest request.
const REQUESTER_TTL = 3600000;
export function sessionPeer(key) {
  return typeof key === "string" ? /:direct:(ou_[a-zA-Z0-9]+)$/.exec(key)?.[1] : undefined;
}
function admin(config, sender) {
  return config.commands?.ownerAllowFrom?.some((value) =>
    value === `feishu:${sender}` || value === sender) === true;
}
function label(role) { return `${role.name} · ${role.visibility === "private" ? "私人" : "共享"}`; }
export function validateDraft(value) {
  if (!value || typeof value !== "object") throw new Error("Invalid draft");
  const result = {};
  for (const [key, limit] of [["name", 40], ["description", 200], ["soul", 4000]]) {
    if (typeof value[key] !== "string" || !value[key].trim() || value[key].length > limit ||
        /[\u0000-\u0008\u000b\u000c\u000e-\u001f]/.test(value[key])) throw new Error("Invalid draft field");
    result[key] = value[key].trim();
  }
  // The model cannot choose ownership, visibility, paths, IDs or bindings.
  return result;
}

export class Personas {
  constructor({ store, config, register, bind, draft, writeIdentity, feishu, now = Date.now }) {
    Object.assign(this, { store, config, register, bind, draft, writeIdentity, feishu, now });
    this.runs = new Map();
    this.requesters = new Map();
    this.pendingNotices = new Set();
    this.controlReplies = new Map();
  }
  async setIdentity(id, workspace, identity) {
    return this.store.transact(async (state) => {
      const role = state.roles[id];
      if (!role) throw new Error("Role is not registered");
      const saved = await this.writeIdentity(id, workspace, identity);
      if (saved.name) role.name = saved.name;
      return saved;
    });
  }
  allowControlReply(chat, text) {
    if (!chat) return;
    this.controlReplies.set(`${chat}:${text}`, this.now() + 60000);
    for (const [key, until] of this.controlReplies) if (until < this.now()) this.controlReplies.delete(key);
  }
  async bootstrap(state) {
    state.defaults ??= {};
    if (!state.roles[SHARED]) {
      const role = { id: SHARED, name: "家庭助手", description: "共享群聊助手", visibility: "shared",
        owner: null, soul: "你是家庭共享助手。只使用当前工作区中的共享信息，不声称知道任何人的私人记忆。" };
      await this.register(role);
      state.roles[SHARED] = role;
    }
    // Preserve the existing main workspace as the sole configured owner's
    // private assistant. Never expose it as a new group's default.
    if (!state.roles.main) {
      const owners = this.config().commands?.ownerAllowFrom?.map(senderId).filter(Boolean) ?? [];
      if (owners.length === 1 && this.config().agents?.entries?.main) {
        state.roles.main = { id: "main", name: "日常助手", description: "原有的个人助手",
          visibility: "private", owner: owners[0] };
        state.users[owners[0]] ??= "main";
        state.defaults[owners[0]] ??= "main";
      }
    }
  }
  async start() {
    await this.store.transact(async (state) => {
      await this.bootstrap(state);
      for (const [sender, id] of Object.entries(state.users)) {
        const role = state.roles[id];
        if (!senderId(sender) || !role || role.visibility === "private" && role.owner !== sender) {
          throw new Error("Invalid saved private route");
        }
        const binding = this.config().bindings?.find((b) => b.match?.channel === "feishu" &&
          b.match.accountId === "main" && b.match.peer?.kind === "direct" && b.match.peer.id === sender);
        if (binding?.agentId !== id) await this.bind(id, "direct", sender);
      }
    });
  }
  async ensureUser(state, sender) {
    if (state.users[sender]) return state.roles[state.users[sender]];
    const id = `personal-${createHash("sha256").update(sender).digest("hex").slice(0, 20)}`;
    const role = { id, name: "日常助手", description: "我的默认私人助手", owner: sender,
      visibility: "private", soul: "你是用户的私人助手。只维护当前工作区的身份和记忆，不读取其他角色工作区。" };
    await this.register(role);
    state.roles[id] = role;
    state.users[sender] = id;
    state.defaults[sender] = id;
    return role;
  }
  async manager(sender, chat) {
    return admin(this.config(), sender) || await this.feishu.owner(chat) === sender;
  }
  async privateAllowed(role, sender, chat) {
    return role.owner === sender && (!chat || await this.feishu.alone(chat, sender));
  }
  async menu(state, sender, chat) {
    const current = chat ? state.groups[chat]?.role ?? SHARED : state.users[sender];
    let personal = !chat;
    if (chat) { try { personal = await this.feishu.alone(chat, sender); } catch { /* Hide private names. */ } }
    const selected = state.roles[current];
    const visible = selected && (selected.visibility === "shared" || personal && selected.owner === sender);
    const lines = [`当前角色：${visible ? label(selected) : selected ? "私人角色（详情仅本人可见）" : "尚未选择"}${state.groups[chat]?.paused ? "（已暂停）" : ""}`, "共享角色："];
    for (const role of Object.values(state.roles).filter((r) => r.visibility === "shared")) {
      lines.push(`• ${role.name}：${role.description}\n  /persona use ${role.id}`);
    }
    if (personal) {
      lines.push("我的私人角色：");
      for (const role of Object.values(state.roles).filter((r) => r.visibility === "private" && r.owner === sender)) {
        lines.push(`• ${role.name}：${role.description}\n  /persona use ${role.id}`);
      }
    } else lines.push("私人角色请到私聊查看，或在只有你和机器人的群中选择。");
    lines.push("创建角色：/persona new 描述用途\n恢复本入口默认角色：/persona default");
    return lines.join("\n");
  }
  async command({ sender, chat, args = "" }) {
    if (!senderId(sender)) return "无法确认你的飞书身份。";
    if (chat && !groupId(chat)) return "无法确认群聊。";
    const [verb = "", ...parts] = args.trim().split(/\s+/);
    const rest = parts.join(" ");
    // Slow model work is outside the registry lock so member checks can proceed.
    if (verb === "new") {
      if (!rest || rest.length > 2000) return "请发送 /persona new 用途描述（不超过 2000 字）。";
      if (chat && !await this.manager(sender, chat)) return "请群主或命令管理员创建群角色，也可到私聊创建。";
      const ticket = randomUUID();
      await this.store.transact(async (state) => {
        await this.bootstrap(state);
        const key = `${sender}:${chat ?? "dm"}`;
        const previous = state.drafts[key];
        if (previous?.busy && previous.expires > this.now()) throw new Error("Draft in progress");
        state.drafts[key] = { ticket, busy: true, expires: this.now() + 900000 };
      });
      let proposed;
      try { proposed = validateDraft(await this.draft(rest)); }
      catch {
        await this.store.transact((state) => {
          const key = `${sender}:${chat ?? "dm"}`;
          if (state.drafts[key]?.ticket === ticket) delete state.drafts[key];
        });
        return "起草失败，没有创建角色。请稍后重试 /persona new。";
      }
      return this.store.transact((state) => {
        const key = `${sender}:${chat ?? "dm"}`;
        if (state.drafts[key]?.ticket !== ticket) return "草稿已取消，请重新起草。";
        state.drafts[key] = { ...proposed, ticket, id: `role-${randomUUID().replaceAll("-", "")}`,
          expires: this.now() + 900000 };
        return `角色草稿（尚未创建）：\n名称：${proposed.name}\n简介：${proposed.description}\n人格说明：\n${proposed.soul}\n\n确认范围后创建：\n/persona confirm ${ticket} shared\n/persona confirm ${ticket} private\n修改：/persona edit name 新名称（也支持 description、soul）\n取消：/persona cancel\n私人角色仅本人可用；共享角色可在多人群选择。`;
      });
    }
    return this.store.transact(async (state) => {
      await this.bootstrap(state);
      if (!chat) await this.ensureUser(state, sender);
      const draftKey = `${sender}:${chat ?? "dm"}`;
      if (!verb || verb === "list" || verb === "status") return this.menu(state, sender, chat);
      if (verb === "cancel") { delete state.drafts[draftKey]; return "草稿已取消。"; }
      if (verb === "edit") {
        const draft = state.drafts[draftKey];
        if (!draft || draft.busy || draft.expires < this.now()) return "没有有效草稿，请 /persona new。";
        const [field, ...value] = parts;
        if (!["name", "description", "soul"].includes(field)) return "可修改 name、description、soul。";
        Object.assign(draft, validateDraft({ ...draft, [field]: value.join(" ") }));
        return `草稿已修改：${draft.name}\n${draft.description}\n${draft.soul}\n确认：/persona confirm ${draft.ticket} shared 或 private`;
      }
      let role;
      if (verb === "confirm") {
        const [ticket, visibility] = parts;
        const draft = state.drafts[draftKey];
        if (!draft || draft.busy || draft.ticket !== ticket || draft.expires < this.now() ||
            parts.length !== 2 || !["shared", "private"].includes(visibility)) return "确认无效或草稿已过期，请 /persona 查看或重新起草。";
        if (chat && !await this.manager(sender, chat)) return "只有群主或命令管理员可以创建群角色。";
        role = { id: draft.id, ...validateDraft(draft), owner: sender, visibility };
        if (visibility === "private" && !await this.privateAllowed(role, sender, chat)) return "私人角色只能在私聊或只有本人和机器人的群中创建。请到私聊继续。";
        if (Object.keys(state.roles).length >= 100) return "角色数量已达上限，请管理员整理后重试。";
        await this.register(role);
        state.roles[role.id] = role;
        delete state.drafts[draftKey];
        // Creation and switching are distinct: no partial binding on failed writes.
        return `已创建「${label(role)}」。独立工作区和记忆已就绪。\n切换：/persona use ${role.id}`;
      }
      if (verb === "default") {
        role = chat ? state.roles[SHARED] : state.roles[state.defaults[sender]] ?? await this.ensureUser(state, sender);
      } else if (verb === "use" && parts.length === 1 && safeId(rest)) role = state.roles[rest];
      else return "用法：/persona、/persona use 角色ID、/persona new 用途、/persona default。";
      if (!role || role.visibility === "private" && role.owner !== sender) return "角色不存在或你无权选择。";
      if (chat && !await this.manager(sender, chat)) return "只有群主或命令管理员可以切换本群角色。";
      if (role.visibility === "private" && !await this.privateAllowed(role, sender, chat)) return "私人角色只能由本人在私聊或只有本人和机器人的群中使用。";
      await this.bind(role.id, chat ? "group" : "direct", chat ?? sender);
      if (chat) {
        const revision = (state.groups[chat]?.revision ?? 0) + 1;
        state.groups[chat] = { role: role.id, paused: false, announced: true, revision };
      } else {
        state.users[sender] = role.id;
      }
      return `已切换到「${label(role)}」。不复制其他角色的历史或记忆。${role.visibility === "private" && chat ? `\n${PRIVATE_HINT}` : ""}`;
    });
  }
  async pause(chat) {
    // Persist before sending a warning. Failed delivery remains pending for retry.
    await this.store.transact((state) => {
      const group = state.groups[chat];
      if (group && !group.paused) {
        group.paused = true; group.revision++; group.noticePending = true;
      }
    });
    await this.notice(chat);
  }
  async notice(chat) {
    if (this.pendingNotices.has(chat)) return;
    const state = await this.store.read();
    if (!state.groups[chat]?.noticePending) return;
    this.pendingNotices.add(chat);
    try {
      await this.feishu.notify(chat, PAUSED);
      await this.store.transact((s) => { if (s.groups[chat]?.paused) s.groups[chat].noticePending = false; });
    } finally { this.pendingNotices.delete(chat); }
  }
  async verifyGroup(chat, role, sender) {
    const state = await this.store.read();
    const group = state.groups[chat];
    if (group?.paused || (group?.role ?? SHARED) !== role.id) return false;
    if (role.visibility !== "private") return true;
    if (sender && sender !== role.owner) return false;
    let alone;
    // A failed lookup refuses this message or reply but does not pause: only
    // confirmed membership changes need the owner to resume by hand.
    try { alone = await this.feishu.alone(chat, role.owner); } catch { return false; }
    if (!alone) { await this.pause(chat).catch(() => {}); return false; }
    return true;
  }
  async inbound(event, ctx) {
    if (ctx.channelId !== "feishu" || ctx.accountId !== "main") return;
    // Group management commands authorize themselves and never reach a model,
    // so they keep working while a private role is paused.
    if (/^\/(?:persona|mention|groupmodel)(?:\s|$)/i.test(event.content?.trim() ?? "")) return;
    const sender = senderId(event.senderId ?? ctx.senderId);
    const chat = event.isGroup ? groupId(ctx.parentConversationId ?? event.parentConversationId) ??
      groupId(ctx.conversationId ?? event.conversationId) ?? sessionGroup(ctx.sessionKey) : undefined;
    if (!sender || event.isGroup && !chat) return { handled: true, reply: { text: "无法确认消息来源，未调用角色。" } };
    let reply;
    await this.store.transact(async (state) => {
      await this.bootstrap(state);
      if (!chat) {
        const role = await this.ensureUser(state, sender);
        if ((ctx.agentId ?? sessionAgent(ctx.sessionKey)) !== role.id) {
          await this.bind(role.id, "direct", sender);
          reply = `已为你连接「${label(role)}」。请重发刚才的问题；用 /persona 可选择或创建其他角色。`;
        }
      } else if (!state.groups[chat]) {
        state.groups[chat] = { role: SHARED, paused: false, revision: 0, announced: false };
      }
    });
    if (reply) return { handled: true, reply: { text: reply } };
    const state = await this.store.read();
    const role = state.roles[chat ? state.groups[chat].role : state.users[sender]];
    if (!role || (ctx.agentId ?? sessionAgent(ctx.sessionKey)) !== role.id ||
        chat && !await this.verifyGroup(chat, role, sender)) {
      return { handled: true, reply: { text: chat ? PAUSED : "角色路由未就绪，请稍后重试。" } };
    }
  }
  async beforeRun(event, ctx) {
    const state = await this.store.read();
    const role = state.roles[ctx.agentId];
    if (!role) return { outcome: "block", reason: "Unknown persona", message: "角色尚未登记，请先 /persona。" };
    const chat = sessionGroup(ctx.sessionKey);
    const sender = senderId(event.senderId ?? ctx.senderId ?? ctx.senderExternalId);
    // Inbound messages without a sender are refused earlier, so a run without
    // one was started by the session itself, e.g. a finished background command
    // waking it.  It acts for the session's peer; groups are checked for
    // membership here and again before sending.
    const actor = sender ?? (chat ? role.owner : sessionPeer(ctx.sessionKey));
    if (chat && !await this.verifyGroup(chat, role, sender) ||
        role.visibility === "private" && (actor !== role.owner || !ctx.runId)) {
      return { outcome: "block", reason: "Private persona access denied", message: "私人角色权限或群成员状态不匹配，请 /persona。" };
    }
    if (ctx.runId) {
      this.runs.set(ctx.runId, { role: role.id, chat, revision: state.groups[chat]?.revision,
        created: this.now() });
      for (const [id, run] of this.runs) if (this.now() - run.created > 86400000) this.runs.delete(id);
    }
    if (sender && ctx.sessionKey) {
      this.requesters.set(ctx.sessionKey, { sender, at: this.now() });
      for (const [key, r] of this.requesters) if (this.now() - r.at > REQUESTER_TTL) this.requesters.delete(key);
    }
  }
  // The message tool can name any Feishu target, and private-chat deliveries
  // bypass the group checks in sending(). Confine it to this conversation and
  // the private chat of the person the run acts for; group sends still pass
  // sending() with this run's authority.
  async messageTool(event, ctx) {
    if (event.toolName !== "message") return;
    const deny = (reason) => ({ block: true, blockReason: reason });
    const params = event.params ?? {};
    if (params.action !== "send") return deny("The message tool may only send.");
    if (params.targets !== undefined) return deny("Send to one target at a time.");
    if (![undefined, "feishu"].includes(params.channel) || ![undefined, "main"].includes(params.accountId)) {
      return deny("The message tool may only use the current Feishu account.");
    }
    const role = (await this.store.read()).roles[ctx.agentId];
    if (!role) return deny("Unknown persona.");
    // A run without a requester, e.g. a finished background command waking
    // the session, acts for the session's latest sender within the hour.
    // In a shared topic that may be a later speaker than the one who started
    // the command; for a shared role and its shared browser that is accepted.
    const latest = this.requesters.get(ctx.sessionKey);
    const requester = ctx.requester?.senderId === undefined
      ? (latest && this.now() - latest.at < REQUESTER_TTL ? latest.sender : undefined)
      : ctx.requester.channel === undefined || ctx.requester.channel === "feishu"
        ? senderId(ctx.requester.senderId) : undefined;
    const allowed = [sessionGroup(ctx.sessionKey), sessionPeer(ctx.sessionKey),
      role.visibility === "private" ? role.owner : requester].filter(Boolean);
    for (const raw of [params.target, params.to]) {
      if (raw === undefined) continue;
      if (!allowed.includes(feishuTarget(raw))) {
        return deny("Only this conversation or the requester's private chat can be messaged.");
      }
    }
  }
  async promptContext(_event, ctx) {
    const chat = sessionGroup(ctx.sessionKey);
    if (!chat) return;
    const state = await this.store.read();
    const role = state.roles[ctx.agentId];
    if (!role || (state.groups[chat]?.role ?? SHARED) !== role.id) return;
    if (role.visibility === "shared") return { appendSystemContext: SHARED_GROUP_CONTEXT };
    if (await this.verifyGroup(chat, role)) return { appendSystemContext: PRIVATE_GROUP_CONTEXT };
  }
  async sending(event, ctx) {
    if ((event.channel ?? ctx.channelId) !== "feishu" || ctx.accountId !== "main") return;
    const chat = groupId(ctx.conversationId) ?? sessionGroup(event.sessionKey ?? ctx.sessionKey);
    if (!chat) return this.directWelcome(event, ctx);
    const state = await this.store.read();
    const group = state.groups[chat];
    if (!group) return;
    const agent = event.usageState?.agentId ?? sessionAgent(event.sessionKey ?? ctx.sessionKey);
    const role = state.roles[agent];
    // Only exact control replies produced by this plugin bypass private reply
    // verification. Durable model replays without a run ID do not bypass it.
    if (!event.usageState && !this.runs.has(event.runId) &&
        (this.controlReplies.get(`${chat}:${event.payload?.text}`) ?? 0) > this.now()) return;
    if (!role || !await this.verifyGroup(chat, role)) return { cancel: true, reason: "Persona binding changed or paused" };
    const run = this.runs.get(event.runId);
    if (role.visibility === "private" && (!run || run.role !== role.id ||
        run.chat !== chat || run.revision !== group.revision)) {
      return { cancel: true, reason: "Private persona turn authority is no longer current" };
    }
    if (event.kind !== "final" || group.announced) return;
    return this.store.transact((s) => {
      const current = s.groups[chat];
      if (current.announced || current.role !== role.id || current.revision !== group.revision ||
          current.announcementPending > this.now()) return;
      // Reserve across concurrent topics; failure acknowledgements release it.
      current.announcementPending = this.now() + 30000;
      const banner = `我目前是「${label(role)}」，${role.visibility === "shared" ? "不使用私人角色的记忆" : "使用你的私人身份和记忆"}。\n可以继续聊，或用 /persona 选择／创建角色。`;
      return { payload: { ...event.payload, text: `${banner}\n\n${event.payload.text ?? ""}` } };
    });
  }
  async directWelcome(event, ctx, delivered = false) {
    const key = event.sessionKey ?? ctx.sessionKey;
    const sender = senderId(ctx.senderId) ?? sessionPeer(key);
    const id = event.usageState?.agentId ?? sessionAgent(key);
    if (!sender || !id || !delivered && event.kind !== "final") return;
    // Commands and bootstrap notices already identify themselves. Only decorate
    // model replies, never turn a /new acknowledgement into a persona greeting.
    if (!delivered && !event.usageState) return;
    return this.store.transact((state) => {
      const role = state.roles[id];
      if (!role || state.users[sender] !== id || role.visibility === "private" && role.owner !== sender) return;
      state.dmNotices ??= {};
      const noticeKey = `${sender}:${id}`;
      const notice = state.dmNotices[noticeKey] ??= {};
      const banner = `我目前是「${label(role)}」。用 /persona 可以选择／创建角色。`;
      if (delivered) {
        if (!event.content?.startsWith(banner)) return;
        notice.pending = 0;
        if (event.success) notice.announced = true;
        return;
      }
      if (notice.announced || notice.pending > this.now()) return;
      notice.pending = this.now() + 30000;
      return { payload: { ...event.payload, text: `${banner}\n\n${event.payload.text ?? ""}` } };
    });
  }
  async sent(event, ctx) {
    if (ctx.channelId !== "feishu" || ctx.accountId !== "main") return;
    const chat = groupId(ctx.conversationId ?? event.to) ?? sessionGroup(event.sessionKey ?? ctx.sessionKey);
    if (!chat) return this.directWelcome(event, ctx, true);
    if (!event.content?.includes("或用 /persona 选择／创建角色。")) return;
    await this.store.transact((s) => {
      const group = s.groups[chat];
      const role = s.roles[group?.role];
      if (!group || !role || !event.content.startsWith(`我目前是「${label(role)}」`)) return;
      group.announcementPending = 0;
      if (event.success) group.announced = true;
    });
  }
  async poll() {
    const state = await this.store.read();
    for (const [chat, group] of Object.entries(state.groups)) {
      if (group.noticePending) await this.notice(chat).catch(() => {});
      const role = state.roles[group.role];
      // No leave-event handling and no automatic restoration after a pause.
      if (!group.paused && role?.visibility === "private") await this.verifyGroup(chat, role);
    }
  }
}
