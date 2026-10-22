import assert from "node:assert/strict";
import test from "node:test";
import { checkedSet } from "../../scripts/openclaw/config.mjs";
import { reconcile, validatePolicy } from "../../scripts/openclaw/config-policy.mjs";

const base = {
  models: { providers: { local: { models: [{ id: "one" }, { id: "two" }] } } },
  tools: { allow: ["exec"], exec: { host: "gateway", mode: "full" } },
  plugins: { entries: { feishu: { enabled: true } } },
  agents: { defaults: { workspace: "/workspace", model: { primary: "local/one" } } },
};

test("reconcile preserves registrations and approved model, restores managed values", () => {
  const existing = structuredClone(base);
  existing.agents.entries = { alice: { workspace: "/workspaces/alice" } };
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
    (c) => { c.agents.entries.alice.workspace = "/workspaces/../secrets"; },
    (c) => { c.agents.entries.alice.workspace = "${HOME}/workspace"; },
    (c) => { delete c.agents.entries.alice.workspace; },
    (c) => { c.agents.entries.alice.agentDir = "/run/secrets"; },
    (c) => { c.agents.entries.alice.model = "unknown/model"; },
    (c) => { c.bindings = { $include: "anything" }; },
  ];
  for (const edit of edits) {
    const c = structuredClone(base);
    c.agents.entries = { alice: { workspace: "/workspaces/alice" } };
    edit(c);
    assert.throws(() => validatePolicy(c, base));
  }
});

test("forbidden edit is rejected before native CLI can evaluate its contents", async () => {
  let invoked = false;
  await assert.rejects(checkedSet(["agents.entries.alice", JSON.stringify({
    workspace: "/workspaces/alice", tools: { exec: { security: "full" } },
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
  assert.deepEqual(next.tools.exec, { host: "gateway", mode: "full" });
  validatePolicy(next, base);
  next.tools.exec.mode = "auto";
  assert.throws(() => validatePolicy(next, base), /differing paths: tools.exec.mode/);
  next.tools.exec.mode = "full";
  next.tools.allow = ["read"];
  assert.throws(() => validatePolicy(next, base), /differing paths: tools.allow/);
});
