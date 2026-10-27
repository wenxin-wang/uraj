import assert from "node:assert/strict";
import test from "node:test";
import fs from "node:fs/promises";
import os from "node:os";
import path from "node:path";
import { PersonaStore } from "../../scripts/openclaw/config-plugin/persona-store.mjs";
import { Personas, SHARED, validateDraft } from "../../scripts/openclaw/config-plugin/persona.mjs";
import { createRuntimePersonas, registerPersonas } from "../../scripts/openclaw/config-plugin/persona-runtime.mjs";

const proposed = { name: "读书搭子", description: "讨论书籍", soul: "先准确理解文本，再讨论不同解释。" };
async function setup(t) {
  const directory = await fs.mkdtemp(path.join(os.tmpdir(), "persona-test-"));
  t.after(() => fs.rm(directory, { recursive: true, force: true }));
  const config = { commands: { ownerAllowFrom: ["feishu:ou_alice"] }, agents: { entries: { main: {} } } };
  const calls = { register: [], bind: [], notify: [], llm: 0 };
  const state = { alone: true, fail: false, owner: "ou_alice" };
  const service = new Personas({ store: new PersonaStore(directory), config: () => config,
    register: async (role) => { config.agents.entries[role.id] = {}; calls.register.push(role); },
    bind: async (...args) => { calls.bind.push(args); },
    draft: async () => { calls.llm++; return { ...proposed, visibility: "shared", owner: "ou_evil" }; },
    feishu: {
      owner: async () => state.owner,
      alone: async () => { if (state.fail) throw new Error("offline"); return state.alone; },
      notify: async (...args) => { if (state.fail) throw new Error("offline"); calls.notify.push(args); },
    },
  });
  await service.store.transact((s) => service.bootstrap(s));
  return { service, calls, state, config, directory };
}
const groupCtx = (agent = SHARED) => ({ channelId: "feishu", accountId: "main",
  conversationId: "oc_group:topic:om_thread", senderId: "ou_alice", agentId: agent,
  sessionKey: `agent:${agent}:feishu:group:oc_group:topic:om_thread` });
const groupEvent = { isGroup: true, content: "hello", senderId: "ou_alice" };

test("shared fallback never adopts the existing private workspace; users get separate defaults", async (t) => {
  const { service, calls } = await setup(t);
  await service.inbound(groupEvent, groupCtx());
  let s = await service.store.read();
  assert.equal(s.groups.oc_group.role, SHARED);
  assert.equal(s.roles.main.visibility, "private");
  assert.equal(s.roles.main.owner, "ou_alice");
  const response = await service.inbound({ ...groupEvent, isGroup: false, senderId: "ou_bob" },
    { channelId: "feishu", accountId: "main", agentId: SHARED });
  assert.equal(response.handled, true);
  s = await service.store.read();
  assert.notEqual(s.users.ou_bob, "main");
  assert.equal(s.roles[s.users.ou_bob].owner, "ou_bob");
  assert.deepEqual(calls.bind.at(-1), [s.users.ou_bob, "direct", "ou_bob"]);
});

test("first reply banner is deterministic and persists only after successful delivery", async (t) => {
  const { service, directory } = await setup(t);
  await service.inbound(groupEvent, groupCtx());
  const event = { channel: "feishu", runId: "run1", sessionKey: groupCtx().sessionKey,
    kind: "final", payload: { text: "模型正文" }, usageState: { agentId: SHARED } };
  const result = await service.sending(event, groupCtx());
  assert.match(result.payload.text, /家庭助手 · 共享/);
  assert.match(result.payload.text, /模型正文/);
  await service.sent({ success: false, content: result.payload.text }, groupCtx());
  assert.ok((await service.sending(event, groupCtx())).payload);
  await service.sent({ success: true, content: result.payload.text }, groupCtx());
  assert.equal(await service.sending(event, groupCtx()), undefined);
  const restarted = new PersonaStore(directory);
  assert.equal((await restarted.read()).groups.oc_group.announced, true);
});

test("new drafts do not create an agent until the owner confirms an explicit scope", async (t) => {
  const { service, calls } = await setup(t);
  const baseline = calls.register.length;
  assert.match(await service.command({ sender: "ou_alice", args: "new 帮我读书" }), /尚未创建/);
  assert.equal(calls.llm, 1);
  assert.equal(calls.register.length, baseline);
  let s = await service.store.read();
  const draft = s.drafts["ou_alice:dm"];
  assert.equal(draft.visibility, undefined);
  assert.match(await service.command({ sender: "ou_bob", args: `confirm ${draft.ticket} private` }), /确认无效/);
  await service.command({ sender: "ou_alice", args: "edit name 论文搭子" });
  const result = await service.command({ sender: "ou_alice", args: `confirm ${draft.ticket} private` });
  assert.match(result, /已创建/);
  s = await service.store.read();
  assert.equal(s.roles[draft.id].owner, "ou_alice");
  assert.equal(s.roles[draft.id].visibility, "private");
  assert.equal(s.roles[draft.id].name, "论文搭子");
  assert.equal(calls.bind.length, 0);
  assert.match(await service.command({ sender: "ou_alice", args: `confirm ${draft.ticket} shared` }), /确认无效/);
});

test("model output cannot choose paths/ownership; malformed or expired drafts cannot publish", async (t) => {
  assert.deepEqual(validateDraft({ ...proposed, workspace: "/secret", owner: "ou_evil" }), proposed);
  assert.throws(() => validateDraft({ ...proposed, soul: "" }));
  const { service } = await setup(t);
  await service.command({ sender: "ou_alice", args: "new test" });
  const s = await service.store.read();
  service.now = () => Date.now() + 1000000;
  assert.match(await service.command({ sender: "ou_alice", args: `confirm ${s.drafts["ou_alice:dm"].ticket} shared` }), /过期/);
});

test("private roles are hidden in public groups and cannot be selected by another owner/admin", async (t) => {
  const { service, state, config, calls } = await setup(t);
  config.commands.ownerAllowFrom.push("feishu:ou_bob");
  assert.match(await service.command({ sender: "ou_bob", chat: "oc_group", args: "use main" }), /无权/);
  state.alone = false;
  assert.match(await service.command({ sender: "ou_alice", chat: "oc_group", args: "use main" }), /只有本人/);
  const menu = await service.command({ sender: "ou_bob", chat: "oc_group" });
  assert.doesNotMatch(menu, /日常助手/);
  assert.equal(calls.bind.length, 0);
});

test("private group switch checks owner and membership; join suspends and leave never restores", async (t) => {
  const { service, state, calls } = await setup(t);
  assert.match(await service.command({ sender: "ou_alice", chat: "oc_group", args: "use main" }), /已切换/);
  state.alone = false;
  await service.poll();
  assert.equal((await service.store.read()).groups.oc_group.paused, true);
  assert.equal(calls.notify.length, 1);
  state.alone = true;
  await service.poll();
  assert.equal((await service.store.read()).groups.oc_group.paused, true);
  assert.equal(calls.notify.length, 1);
  await service.command({ sender: "ou_alice", chat: "oc_group", args: "use main" });
  assert.equal((await service.store.read()).groups.oc_group.paused, false);
});

test("failed membership lookup pauses and pending notice is retried", async (t) => {
  const { service, state, calls } = await setup(t);
  await service.command({ sender: "ou_alice", chat: "oc_group", args: "use main" });
  state.fail = true;
  await service.poll();
  assert.equal((await service.store.read()).groups.oc_group.noticePending, true);
  state.fail = false;
  await service.poll();
  assert.equal(calls.notify.length, 1);
  assert.equal((await service.store.read()).groups.oc_group.paused, true);
});

test("in-flight private replies are cancelled after switching, even after switching back", async (t) => {
  const { service } = await setup(t);
  await service.command({ sender: "ou_alice", chat: "oc_group", args: "use main" });
  const ctx = { ...groupCtx("main"), runId: "old" };
  assert.equal(await service.beforeRun({ senderId: "ou_alice" }, ctx), undefined);
  await service.command({ sender: "ou_alice", chat: "oc_group", args: `use ${SHARED}` });
  await service.command({ sender: "ou_alice", chat: "oc_group", args: "use main" });
  const event = { channel: "feishu", kind: "final", runId: "old", payload: { text: "私人内容" },
    sessionKey: ctx.sessionKey, usageState: { agentId: "main" } };
  assert.equal((await service.sending(event, ctx)).cancel, true);
});

test("wrong DM identity, unknown roles and missing private run identity block before model", async (t) => {
  const { service } = await setup(t);
  assert.equal((await service.beforeRun({ senderId: "ou_bob" }, { agentId: "main", runId: "r" })).outcome, "block");
  assert.equal((await service.beforeRun({ senderId: "ou_alice" }, { agentId: "main" })).outcome, "block");
  assert.equal((await service.beforeRun({}, { agentId: "unknown" })).outcome, "block");
});

test("registry serializes concurrent edits, persists restart state and never resets corrupt data", async (t) => {
  const { service, directory } = await setup(t);
  await Promise.all(Array.from({ length: 8 }, (_, i) => service.store.transact(async (s) => {
    s.users[`ou_${i}`] = "main";
  })));
  const fresh = new PersonaStore(directory);
  assert.equal(Object.keys((await fresh.read()).users).length, 9);
  assert.equal((await fs.stat(fresh.file)).mode & 0o777, 0o600);
  await fs.writeFile(fresh.file, "invalid");
  await assert.rejects(fresh.read());
});

test("hook adapters fail closed and command uses transport identity instead of arguments", async (t) => {
  const { service } = await setup(t);
  const hooks = new Map();
  let command;
  registerPersonas({ registerCommand: (c) => { command = c; }, on: (name, fn) => hooks.set(name, fn),
    registerService() {}, logger: { warn() {} } }, service);
  assert.equal(command.requireAuth, false);
  const result = await command.handler({ channel: "feishu", accountId: "main", from: "feishu:ou_bob",
    to: "chat:oc_group", args: "use main" });
  assert.match(result.text, /无权/);
  service.beforeRun = async () => { throw new Error("bad state"); };
  assert.equal((await hooks.get("before_agent_run")({}, {})).outcome, "block");
  service.sending = async () => { throw new Error("bad state"); };
  assert.equal((await hooks.get("reply_payload_sending")({}, {})).cancel, true);
});

test("DM default survives selecting another role, without a model call", async (t) => {
  const { service, calls } = await setup(t);
  await service.command({ sender: "ou_alice", args: `use ${SHARED}` });
  assert.equal((await service.store.read()).users.ou_alice, SHARED);
  await service.command({ sender: "ou_alice", args: "default" });
  assert.deepEqual(calls.bind.at(-1), ["main", "direct", "ou_alice"]);
  assert.equal(calls.llm, 0);
});

test("suspended group still delivers exact command replies with dispatch IDs, never model replays", async (t) => {
  const { service, state } = await setup(t);
  await service.command({ sender: "ou_alice", chat: "oc_group", args: "use main" });
  state.alone = false;
  await service.poll();
  const ctx = groupCtx("main");
  const event = { channel: "feishu", kind: "final", runId: "command-dispatch",
    sessionKey: ctx.sessionKey, payload: { text: "角色菜单" } };
  service.allowControlReply("oc_group", "角色菜单");
  assert.equal(await service.sending(event, ctx), undefined);
  assert.equal((await service.sending({ ...event, payload: { text: "私人内容" } }, ctx)).cancel, true);
  assert.equal((await service.sending({ ...event, usageState: { agentId: "main" } }, ctx)).cancel, true);
});

test("concurrent topic replies reserve one welcome; failed send releases it", async (t) => {
  const { service } = await setup(t);
  await service.inbound(groupEvent, groupCtx());
  const event = { channel: "feishu", kind: "final", sessionKey: groupCtx().sessionKey,
    usageState: { agentId: SHARED }, payload: { text: "hello" } };
  const results = await Promise.all([service.sending(event, groupCtx()), service.sending(event, groupCtx())]);
  assert.equal(results.filter(Boolean).length, 1);
  await service.sent({ success: false, content: results.find(Boolean).payload.text }, groupCtx());
  assert.ok((await service.sending(event, groupCtx())).payload);
});

test("failed publishing retains draft for retry; failed binding never changes selected role", async (t) => {
  const { service } = await setup(t);
  await service.command({ sender: "ou_alice", args: "new reader" });
  const draft = (await service.store.read()).drafts["ou_alice:dm"];
  service.register = async () => { throw new Error("write failed"); };
  await assert.rejects(service.command({ sender: "ou_alice", args: `confirm ${draft.ticket} private` }));
  assert.ok((await service.store.read()).drafts["ou_alice:dm"]);
  assert.equal((await service.store.read()).roles[draft.id], undefined);
  service.bind = async () => { throw new Error("write failed"); };
  await assert.rejects(service.command({ sender: "ou_alice", args: `use ${SHARED}` }));
  assert.equal((await service.store.read()).users.ou_alice, "main");
});

test("runtime uses native source transaction, preserves SecretRefs and existing workspace files", async (t) => {
  const root = await fs.mkdtemp(path.join(os.tmpdir(), "persona-runtime-"));
  t.after(() => fs.rm(root, { recursive: true, force: true }));
  const secret = { source: "file", provider: "secrets", id: "/app-secret" };
  const base = {
    agents: { defaults: { workspace: path.join(root, "workspaces/main"), model: "local/one" },
      entries: { main: { workspace: path.join(root, "workspaces/main"), agentDir: path.join(root, "agents/main/agent") } } },
    models: { providers: { local: { models: [{ id: "one" }] } } },
    channels: { feishu: { accounts: { main: { appSecret: secret } } } },
  };
  let source = structuredClone(base);
  let writes = 0;
  const service = createRuntimePersonas({ runtime: { config: {
    current: () => {
      const resolved = structuredClone(source);
      resolved.channels.feishu.accounts.main.appSecret = "resolved-secret-must-not-be-written";
      return resolved;
    },
    mutateConfigFile: async (options) => {
      assert.equal(options.base, "source");
      assert.deepEqual(options.afterWrite, { mode: "auto" });
      const draft = structuredClone(source);
      await options.mutate(draft);
      source = draft;
      writes++;
    },
  } } }, { directory: path.join(root, "personas"), loadBase: async () => base });
  const role = { id: "reader", ...proposed };
  await service.register(role);
  await fs.writeFile(path.join(root, "workspaces/reader/SOUL.md"), "user customized");
  await service.register(role);
  assert.equal(await fs.readFile(path.join(root, "workspaces/reader/SOUL.md"), "utf8"), "user customized");
  source.bindings = [
    { agentId: "main", match: { channel: "feishu", accountId: "main", peer: { kind: "group", id: "oc_group:topic:om_old" } } },
    { agentId: "main", match: { channel: "feishu", accountId: "main", peer: { kind: "direct", id: "ou_alice" } } },
  ];
  await service.bind("reader", "group", "oc_group");
  assert.equal(writes, 2);
  assert.equal(source.bindings.length, 2);
  assert.equal(source.bindings[0].agentId, "reader");
  assert.equal(source.bindings[1].match.peer.kind, "direct");
  assert.deepEqual(source.channels.feishu.accounts.main.appSecret, secret);
  await assert.rejects(service.bind("unregistered", "group", "oc_group"));
});
