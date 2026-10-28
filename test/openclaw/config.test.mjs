import assert from "node:assert/strict";
import test from "node:test";
import { checkedSet, withCommandOwners, withFeishuAppId } from "../../scripts/openclaw/config.mjs";
import { reconcile, validatePolicy } from "../../scripts/openclaw/config-policy.mjs";

const base = {
  models: { providers: { local: { models: [{ id: "one" }, { id: "two" }] } } },
  tools: { allow: ["exec"], exec: { host: "sandbox", mode: "full" } },
  plugins: { entries: { feishu: { enabled: true } } },
  agents: {
    defaults: { workspace: "/data/openclaw/workspaces/main", model: { primary: "local/one" } },
    entries: { main: { workspace: "/data/openclaw/workspaces/main",
      agentDir: "/data/openclaw/home/.openclaw/agents/main/agent" } },
  },
};
const alice = "/data/openclaw/workspaces/alice";

test("SOPS App ID is injected without leaking into the store template or permitting edits", () => {
  const template = structuredClone(base);
  template.channels = { feishu: { accounts: { main: {} } } };
  const managed = withFeishuAppId(template, "cli_test\n");
  assert.equal(template.channels.feishu.accounts.main.appId, undefined);
  assert.equal(managed.channels.feishu.accounts.main.appId, "cli_test");
  const changed = structuredClone(managed);
  changed.channels.feishu.accounts.main.appId = "cli_other";
  assert.throws(() => validatePolicy(changed, managed));
  assert.equal(reconcile(changed, managed).channels.feishu.accounts.main.appId, "cli_test");
  for (const text of ["", "wrong", "cli_test\nextra", "cli_${SECRET}"]) {
    assert.throws(() => withFeishuAppId(template, text));
  }
});

test("SOPS owner list is injected at runtime and cannot be edited by agents", () => {
  const managed = withCommandOwners(base, '["feishu:ou_test"]');
  assert.equal(base.commands, undefined);
  assert.deepEqual(managed.commands.ownerAllowFrom, ["feishu:ou_test"]);
  const next = reconcile(base, managed);
  assert.deepEqual(next.commands, managed.commands);
  const invalid = structuredClone(next);
  invalid.commands.ownerAllowFrom.push("feishu:ou_other");
  assert.throws(() => validatePolicy(invalid, managed));
  assert.deepEqual(reconcile(invalid, managed).commands, managed.commands);
  for (const text of ['["*"]', '["feishu:*"]', '{}', 'null', 'invalid']) {
    assert.throws(() => withCommandOwners(base, text));
  }
  assert.deepEqual(reconcile(next, withCommandOwners(base, "[]")).commands.ownerAllowFrom, []);
});

test("group mention overrides survive restart without preserving other channel edits", () => {
  const managed = structuredClone(base);
  managed.channels = { feishu: { requireMention: true, groupPolicy: "open" } };
  const config = structuredClone(managed);
  config.channels.feishu.groups = { oc_test: { requireMention: false } };
  validatePolicy(config, managed);
  assert.deepEqual(reconcile(config, managed), config);
  for (const group of [{ requireMention: "false" }, { requireMention: false, enabled: true }]) {
    const invalid = structuredClone(config);
    invalid.channels.feishu.groups.oc_test = group;
    assert.throws(() => validatePolicy(invalid, managed));
  }
  const wildcard = structuredClone(config);
  wildcard.channels.feishu.groups["*"] = { requireMention: false };
  assert.throws(() => validatePolicy(wildcard, managed));
  config.channels.feishu.requireMention = false;
  config.channels.feishu.accounts = { main: { appSecret: "unmanaged" } };
  assert.throws(() => validatePolicy(config, managed));
  const restored = reconcile(config, managed);
  assert.equal(restored.channels.feishu.requireMention, true);
  assert.equal(restored.channels.feishu.accounts, undefined);
  assert.equal(restored.channels.feishu.groups.oc_test.requireMention, false);
});

test("mention policy preserves managed group fields and allows only boolean overrides", () => {
  const managed = structuredClone(base);
  managed.channels = { feishu: { groups: { oc_test: { enabled: true, requireMention: true } } } };
  const config = structuredClone(managed);
  config.channels.feishu.groups.oc_test.requireMention = false;
  validatePolicy(config, managed);
  assert.deepEqual(reconcile(config, managed), config);
  config.channels.feishu.groups.oc_test.enabled = false;
  assert.throws(() => validatePolicy(config, managed));
  assert.equal(reconcile(config, managed).channels.feishu.groups.oc_test.enabled, true);
});

test("reconcile preserves registrations and approved model, restores managed values", () => {
  const existing = structuredClone(base);
  existing.agents.entries = { alice: { workspace: alice } };
  existing.bindings = [{ agentId: "alice", match: { channel: "feishu" } }];
  existing.agents.defaults.model = "local/two";
  existing.tools.allow.push("browser");
  const next = reconcile(existing, base);
  assert.deepEqual(next.tools, base.tools);
  assert.deepEqual(next.bindings, existing.bindings);
  assert.deepEqual(next.agents.entries, existing.agents.entries);
  assert.equal(next.agents.defaults.model, "local/two");
  assert.deepEqual(reconcile(next, base), next);
});

test("policy rejects override, include, environment, traversal and unapproved model", () => {
  const edits = [
    (c) => { c.tools.allow.push("browser"); },
    (c) => { c.hooks = { enabled: true }; },
    (c) => { c.agents.defaults.sandbox = { mode: "off" }; },
    (c) => { c.agents.entries.alice.tools = { allow: ["browser"] }; },
    (c) => { c.agents.entries.alice.workspace = "/data/openclaw/workspaces/../home"; },
    (c) => { c.agents.entries.alice.workspace = "/workspaces/alice"; },
    (c) => { c.agents.entries.alice.agentDir = "/data/openclaw/workspaces/alice/agent"; },
    (c) => { c.agents.entries.alice.workspace = "${HOME}/workspace"; },
    (c) => { delete c.agents.entries.alice.workspace; },
    (c) => { c.agents.entries.alice.agentDir = "/run/secrets"; },
    (c) => { c.agents.entries.alice.model = "unknown/model"; },
    (c) => { c.bindings = { $include: "anything" }; },
  ];
  for (const edit of edits) {
    const c = structuredClone(base);
    c.agents.entries = { alice: { workspace: alice } };
    edit(c);
    assert.throws(() => validatePolicy(c, base));
  }
});

test("agents may use host workspace and state paths below Guix's roots", () => {
  const c = structuredClone(base);
  c.agents.entries.alice = { workspace: alice,
    agentDir: "/data/openclaw/home/.openclaw/agents/alice/agent" };
  validatePolicy(c, base);
});

test("forbidden edit is rejected before native CLI can evaluate its contents", async () => {
  let invoked = false;
  await assert.rejects(checkedSet(["agents.entries.alice", JSON.stringify({
    workspace: alice, tools: { exec: { security: "full" } },
  })], {
    base, snapshot: async () => ({ config: base, hash: "revision" }),
    mutate: async () => { invoked = true; },
    submit: async () => { invoked = true; },
  }));
  assert.equal(invoked, false);
});

test("native normalization is checked and cannot silently expand permissions", async () => {
  let submitted = false;
  await assert.rejects(checkedSet(["bindings", "[]"], {
    base, snapshot: async () => ({ config: base, hash: "revision" }),
    mutate: async () => ({ ...base, tools: { allow: ["*"] } }),
    submit: async () => { submitted = true; },
  }));
  assert.equal(submitted, false);
});

test("commits exactly checked candidate with original revision; conflict propagates", async () => {
  const candidate = { ...base, bindings: [] };
  await assert.rejects(checkedSet(["bindings", "[]"], {
    base, snapshot: async () => ({ config: base, hash: "old-revision" }),
    mutate: async () => candidate,
    submit: async (config, hash) => {
      assert.equal(config, candidate);
      assert.equal(hash, "old-revision");
      throw new Error("conflict");
    },
  }), /conflict/);
});

test("unsafe flags and prototype paths never reach native code", async () => {
  for (const args of [["--allow-exec", "true"], ["agents.__proto__.x", "true"]]) {
    await assert.rejects(checkedSet(args, {
      base, snapshot: async () => ({ config: base, hash: "revision" }),
      mutate: async () => { assert.fail("must not invoke CLI"); },
      submit: async () => { assert.fail("must not submit"); },
    }));
  }
});

test("restart reconciliation emits canonical exec mode and still rejects drift", () => {
  const legacy = structuredClone(base);
  legacy.tools.exec = { host: "gateway", security: "full", ask: "off" };
  const next = reconcile(legacy, base);
  assert.deepEqual(next.tools.exec, { host: "sandbox", mode: "full" });
  validatePolicy(next, base);
  next.tools.exec.mode = "auto";
  assert.throws(() => validatePolicy(next, base), /differing paths: tools.exec.mode/);
  next.tools.exec.mode = "full";
  next.tools.allow = ["read"];
  assert.throws(() => validatePolicy(next, base), /differing paths: tools.allow/);
});

test("Doctor disable-only entries survive checks, model edits and restart", async () => {
  const config = structuredClone(base);
  config.skills = { entries: { "1password": { enabled: false }, github: { enabled: false } } };
  validatePolicy(config, base);
  assert.deepEqual(reconcile(config, base).skills, config.skills);
  await checkedSet(["agents.defaults.model", '"local/two"'], {
    base, snapshot: async () => ({ config, hash: "revision" }),
    mutate: async () => {
      const candidate = structuredClone(config);
      candidate.agents.defaults.model = "local/two";
      return candidate;
    },
    submit: async (candidate) => assert.deepEqual(candidate.skills, config.skills),
  });
});

test("skills exception cannot enable skills, add credentials or change declared entries", () => {
  for (const skills of [
    { entries: { github: { enabled: true } } },
    { entries: { github: {} } },
    { entries: { github: { enabled: false, env: { TOKEN: "x" } } } },
    { entries: { github: { enabled: false, apiKey: "x" } } },
    { load: { extraDirs: ["/tmp/skills"] } },
    { entries: [] }, null, [],
  ]) assert.throws(() => validatePolicy({ ...base, skills }, base), /Guix manages skills/);
  const declared = { ...base, skills: { entries: { github: { enabled: true } } } };
  assert.throws(() => validatePolicy({ ...declared,
    skills: { entries: { github: { enabled: false } } } }, declared), /Guix manages skills/);
  assert.throws(() => validatePolicy(base, declared), /Guix manages skills/);
});

test("upgrade installs shared fallback while retaining explicit persona routes and identities", () => {
  const managed = structuredClone(base);
  managed.agents.entries["household-shared"] = {
    workspace: "/data/openclaw/workspaces/household-shared",
    agentDir: "/data/openclaw/home/.openclaw/agents/household-shared/agent",
  };
  const current = structuredClone(base);
  const direct = { agentId: "main", match: { channel: "feishu", accountId: "main", peer: { kind: "direct", id: "ou_alice" } } };
  current.bindings = [direct, { agentId: "main", match: { channel: "feishu", accountId: "main" } }];
  const next = reconcile(current, managed);
  assert.deepEqual(next.agents.entries.main, current.agents.entries.main);
  assert.deepEqual(next.agents.entries["household-shared"], managed.agents.entries["household-shared"]);
  assert.deepEqual(next.bindings, [direct, { agentId: "household-shared", match: { channel: "feishu", accountId: "main" } }]);
  assert.deepEqual(reconcile(next, managed), next);
});


test("Doctor system-agent pin and model normalization permit later persona binding writes", async () => {
  const managed = structuredClone(base);
  managed.agents.defaults.systemAgent = { agentId: "main" };
  const restarted = structuredClone(managed);
  restarted.agents.defaults.model = "local/one";
  validatePolicy(restarted, managed);
  const binding = { agentId: "main", match: { channel: "feishu", accountId: "main",
    peer: { kind: "direct", id: "ou_alice" } } };
  let submitted;
  await checkedSet(["bindings", JSON.stringify([binding])], {
    base: managed, snapshot: async () => ({ config: restarted, hash: "revision" }),
    mutate: async () => ({ ...restarted, bindings: [binding] }),
    submit: async (candidate) => { submitted = candidate; },
  });
  assert.deepEqual(submitted.bindings, [binding]);
  assert.deepEqual(reconcile(submitted, managed).agents.defaults.systemAgent, { agentId: "main" });
  const changed = structuredClone(submitted);
  changed.agents.defaults.systemAgent.agentId = "household-shared";
  assert.throws(() => validatePolicy(changed, managed), /Guix manages agent defaults/);
});

test("command owners also authorize built-in commands in Feishu groups", () => {
  const managed = structuredClone(base);
  managed.channels = { feishu: { groupPolicy: "open" } };
  const next = withCommandOwners(managed, '["feishu:ou_test","feishu:ou_test"]');
  assert.deepEqual(next.channels.feishu.allowFrom, ["feishu:ou_test"]);
  assert.deepEqual(next.channels.feishu.groupAllowFrom, ["feishu:ou_test"]);
  assert.equal(managed.channels.feishu.allowFrom, undefined);
  const edited = structuredClone(next);
  edited.channels.feishu.allowFrom.push("feishu:ou_other");
  assert.throws(() => validatePolicy(edited, next));
  assert.deepEqual(reconcile(edited, next).channels.feishu.allowFrom, ["feishu:ou_test"]);
});
