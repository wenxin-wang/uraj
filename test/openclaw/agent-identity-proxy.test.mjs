import assert from "node:assert/strict";
import test from "node:test";
import fs from "node:fs/promises";
import os from "node:os";
import path from "node:path";
import { AgentIdentityProxy, CAPABILITY_FILE, parseIdentity }
  from "../../scripts/openclaw/config-plugin/agent-identity-proxy.mjs";
import { createRuntimePersonas } from "../../scripts/openclaw/config-plugin/persona-runtime.mjs";

async function fixture(t) {
  const root = await fs.mkdtemp(path.join(os.tmpdir(), "identity-proxy-"));
  t.after(() => fs.rm(root, { recursive: true, force: true }));
  const config = { agents: { entries: {} } };
  for (const id of ["main", "other"]) {
    const workspace = path.join(root, id);
    await fs.mkdir(workspace);
    config.agents.entries[id] = { workspace, name: id, identity: { emoji: "🦀" } };
  }
  const writes = [];
  const dependencies = { config: () => config, setIdentity: async (...args) => {
    writes.push(args);
    const entry = config.agents.entries[args[0]];
    entry.identity = { ...entry.identity, ...args[2] };
    return entry.identity;
  } };
  const proxy = new AgentIdentityProxy(dependencies);
  await proxy.prepare("main");
  const workspace = config.agents.entries.main.workspace;
  const token = await fs.readFile(path.join(workspace, CAPABILITY_FILE), "utf8");
  return { root, config, proxy, token, workspace, writes, dependencies };
}

test("list exposes only the authenticated agent; client ID cannot select another", async (t) => {
  const { proxy, token, writes } = await fixture(t);
  const result = await proxy.handle(["agents", "list", "--json"], token);
  assert.deepEqual(JSON.parse(result.stdout).map((agent) => agent.id), ["main"]);
  assert.doesNotMatch(result.stdout, /other/);
  for (const [args, capability] of [
    [["agents", "list"], undefined], [["agents", "list"], "main"],
    [["agents", "list", "--bindings"], token],
    [["agents", "set-identity", "--agent", "other", "--name", "stolen"], token],
    [["agents", "set-identity", "--workspace", "/other", "--name", "x"], token],
    [["agents", "set-identity", "--identity-file", "/etc/passwd"], token],
    [["agents", "set-identity", "--name", "x", "--name", "y"], token],
    [["agents", "delete", "main"], token],
  ]) await assert.rejects(proxy.handle(args, capability));
  assert.equal(writes.length, 0);
});

test("bootstrap explicit options and from-identity preserve unspecified fields", async (t) => {
  const { proxy, token, workspace, writes } = await fixture(t);
  const result = await proxy.handle(["agents", "set-identity", "--agent", "main",
    "--workspace", "/workspace", "--name", "Claw老师", "--theme", "靠谱、清楚", "--json"], token);
  assert.deepEqual(JSON.parse(result.stdout).identity, { name: "Claw老师", theme: "靠谱、清楚", emoji: "🦀" });
  await fs.writeFile(path.join(workspace, "IDENTITY.md"), "# Identity\n- **Name:** 老师\n- **Vibe:** 机灵\n- **Emoji:** 🦀\n- Avatar: (workspace-relative path, http(s) URL, or data URI)\n");
  await proxy.handle(["agents", "set-identity", "--from-identity", "--name", "覆盖名称"], token);
  assert.deepEqual(writes.at(-1)[2], { name: "覆盖名称", theme: "机灵", emoji: "🦀" });
  assert.deepEqual(parseIdentity("- Name: (pick something you like)\n- Theme: 确定\n- Vibe: ignored\n"), { theme: "确定" });
});

test("identity file and avatar cannot escape the workspace or read special files", async (t) => {
  const { proxy, token, workspace, root, writes } = await fixture(t);
  const outside = path.join(root, "private-file");
  await fs.writeFile(outside, "Name: secret");
  const identityFile = path.join(workspace, "IDENTITY.md");
  await fs.symlink(outside, identityFile);
  await assert.rejects(proxy.handle(["agents", "set-identity", "--from-identity"], token));
  await fs.unlink(identityFile);
  await fs.link(outside, identityFile);
  await assert.rejects(proxy.handle(["agents", "set-identity", "--from-identity"], token));
  await fs.unlink(identityFile);
  await fs.writeFile(identityFile, "x".repeat(65537));
  await assert.rejects(proxy.handle(["agents", "set-identity", "--from-identity"], token));
  for (const avatar of ["../private-file", outside, "https://example.com/avatar", "data:image/png;base64,abc"]) {
    await assert.rejects(proxy.handle(["agents", "set-identity", "--avatar", avatar], token));
  }
  await fs.symlink(outside, path.join(workspace, "escape.png"));
  await assert.rejects(proxy.handle(["agents", "set-identity", "--avatar", "escape.png"], token));
  assert.equal(writes.length, 0);
  await fs.writeFile(path.join(workspace, "avatar.png"), "image");
  await proxy.handle(["agents", "set-identity", "--avatar", "avatar.png"], token);
  assert.equal(writes.length, 1);
});

test("capabilities survive concurrent exec preparation but not restart or workspace change", async (t) => {
  const { proxy, token, workspace, config, root, dependencies } = await fixture(t);
  await Promise.all([proxy.prepare("main"), proxy.prepare("main")]);
  assert.equal(await fs.readFile(path.join(workspace, CAPABILITY_FILE), "utf8"), token);
  const restarted = new AgentIdentityProxy(dependencies);
  await assert.rejects(restarted.handle(["agents", "list"], token));
  const replacement = path.join(root, "replacement");
  await fs.mkdir(replacement);
  config.agents.entries.main.workspace = replacement;
  await assert.rejects(proxy.handle(["agents", "list"], token));
  await proxy.prepare("main");
  await assert.rejects(proxy.handle(["agents", "list"], token));
  config.agents.entries.other.workspace = replacement;
  await assert.rejects(proxy.prepare("main"), /overlap/);
});

test("capability installation replaces a symlink without writing its target", async (t) => {
  const { proxy, workspace, root } = await fixture(t);
  const target = path.join(root, "untouched");
  await fs.writeFile(target, "unchanged");
  await fs.unlink(path.join(workspace, CAPABILITY_FILE));
  await fs.symlink(target, path.join(workspace, CAPABILITY_FILE));
  await proxy.prepare("main");
  assert.equal(await fs.readFile(target, "utf8"), "unchanged");
  assert.equal((await fs.stat(path.join(workspace, CAPABILITY_FILE))).mode & 0o777, 0o600);
});

test("identity writer uses native transaction and changes only metadata and persona name", async (t) => {
  const { root } = await fixture(t);
  const model = "provider/model";
  const base = { models: { providers: { provider: { models: [{ id: "model" }] } } },
    agents: { ownership: "explicit", defaults: { workspace: path.join(root, "main"), model }, entries: {
      main: { workspace: path.join(root, "main"), agentDir: path.join(root, "agents/main/agent"), identity: { emoji: "🦀" } },
    } }, bindings: [] };
  let current = structuredClone(base);
  let fail = false;
  const api = { runtime: { config: { current: () => current, async mutateConfigFile(options) {
    assert.equal(options.base, "source");
    assert.deepEqual(options.afterWrite, { mode: "auto" });
    const draft = structuredClone(current);
    await options.mutate(draft);
    if (fail) throw new Error("write failed");
    current = draft;
  } } } };
  const personas = createRuntimePersonas(api, { loadBase: async () => base, directory: path.join(root, "personas") });
  await personas.store.transact((state) => { state.roles.main = { id: "main", name: "old", visibility: "private", owner: "user" }; });
  await personas.setIdentity("main", base.agents.entries.main.workspace, { name: "new" });
  assert.deepEqual(current.agents.entries.main.identity, { name: "new", emoji: "🦀" });
  assert.equal(current.agents.entries.main.name, "new");
  assert.deepEqual((await personas.store.read()).roles.main,
    { id: "main", name: "new", visibility: "private", owner: "user" });
  assert.deepEqual(current.bindings, []);
  fail = true;
  await assert.rejects(personas.setIdentity("main", base.agents.entries.main.workspace, { name: "failed" }));
  assert.equal((await personas.store.read()).roles.main.name, "new");
  assert.equal(current.agents.entries.main.name, "new");
});
