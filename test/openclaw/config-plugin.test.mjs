import assert from "node:assert/strict";
import test from "node:test";
import { readFileSync } from "node:fs";
import plugin, { createConfigSetTool }
  from "../../scripts/openclaw/config-plugin/index.mjs";



test("shipped manifest activates at startup and declares the Gateway tool", () => {
  const root = new URL("../../scripts/openclaw/config-plugin/", import.meta.url);
  const manifest = JSON.parse(readFileSync(new URL("openclaw.plugin.json", root), "utf8"));
  const pkg = JSON.parse(readFileSync(new URL("package.json", root), "utf8"));
  // v2026.10.3 startup planning does not import enabled-only plugins. The
  // startup and hook activation paths both require explicit enablement, which
  // the generated Guix configuration tests cover separately.
  assert.equal(manifest.id, plugin.id);
  assert.equal(manifest.activation.onStartup, true);
  assert.ok(manifest.activation.onCapabilities.includes("hook"));
  assert.deepEqual(manifest.contracts.tools, ["openclaw_config_set"]);
  assert.deepEqual(pkg.openclaw.extensions, ["./index.mjs"]);
});

test("registers the declared tool and config proxy service", () => {
  const tools = [];
  const hooks = [];
  plugin.register({
    registerCommand(command) {
      assert.ok(["mention", "persona"].includes(command.name));
      assert.equal(command.requireAuth, false);
    },
    registerService(service) { assert.ok(["uraj-personas", "uraj-config-proxy"].includes(service.id)); },
    registerTool(tool) { tools.push(tool.name); },
    on(name, handler, options) {
      hooks.push(name);

    },
  });
  assert.deepEqual(tools, ["openclaw_config_set"]);
  assert.ok(hooks.includes("before_dispatch") && hooks.includes("reply_payload_sending") && hooks.includes("before_agent_run"));
});

test("tool passes exactly one path and JSON value to the checker", async () => {
  let call;
  const tool = createConfigSetTool(async (args) => {
    call = args;
    return { ok: true, stdout: "Configuration committed.\n", stderr: "" };
  });
  const value = "local/one";
  const result = await tool.execute("call", { path: "agents.defaults.model", value });
  assert.deepEqual(call, ["set", "agents.defaults.model", JSON.stringify(value)]);
  assert.equal(result.content[0].text, "Configuration committed.");
  assert.equal(result.details.ok, true);
});

test("tool reports checker refusals and rejects incomplete calls", async () => {
  const tool = createConfigSetTool(async () => ({
    ok: false, stdout: "", stderr: "Only agent and binding edits are accepted\n",
  }));
  const result = await tool.execute("call", { path: "agents.defaults.model", value: "local/one" });
  assert.equal(result.details.ok, false);
  assert.match(result.content[0].text, /Only agent and binding edits/);
  await assert.rejects(tool.execute("call", { path: "bindings" }));
  await assert.rejects(tool.execute("call", { value: [] }));
  await assert.rejects(tool.execute("call", { path: "bindings", value: [] }), /Use \/persona/);
  await assert.rejects(tool.execute("call", {
    path: "channels.feishu.groups.oc_test.requireMention", value: false,
  }), /only the Feishu group owner/);
});

test("the checker runs without blocking the Gateway event loop", async () => {
  // A synchronous child would starve the Gateway RPC it calls back into.
  let ticked = false;
  const tool = createConfigSetTool(() => new Promise((resolve) => {
    setImmediate(() => { ticked = true; resolve({ ok: true, stdout: "ok", stderr: "" }); });
  }));
  await tool.execute("call", { path: "agents.defaults.model", value: "local/one" });
  assert.equal(ticked, true);
  const source = readFileSync(new URL(
    "../../scripts/openclaw/config-plugin/index.mjs", import.meta.url), "utf8");
  assert.doesNotMatch(source, /spawnSync|execFileSync/);
});

test("exec capability uses trusted hook agentId, never command parameters", async () => {
  const fs = await import("node:fs/promises");
  const os = await import("node:os");
  const path = await import("node:path");
  const root = await fs.mkdtemp(path.join(os.tmpdir(), "cli-hook-"));
  try {
    const workspace = path.join(root, "main");
    const other = path.join(root, "other");
    await fs.mkdir(workspace);
    await fs.mkdir(other);
    let hook;
    plugin.register({
      runtime: { config: { current: () => ({ agents: { entries: {
        main: { workspace }, other: { workspace: other },
      } } }) } },
      registerCommand() {}, registerService() {}, registerTool() {},
      on(name, fn) { if (name === "before_tool_call") hook = fn; },
    });
    await hook({ toolName: "exec", params: { agentId: "other", command: "openclaw agents list" } }, { agentId: "main" });
    assert.match(await fs.readFile(path.join(workspace, ".openclaw-cli-capability"), "utf8"), /^[a-f0-9]{64}$/);
    await assert.rejects(fs.access(path.join(other, ".openclaw-cli-capability")));
    await hook({ toolName: "exec", params: { agentId: "other" } }, {});
    await assert.rejects(fs.access(path.join(other, ".openclaw-cli-capability")));
  } finally { await fs.rm(root, { recursive: true, force: true }); }
});
