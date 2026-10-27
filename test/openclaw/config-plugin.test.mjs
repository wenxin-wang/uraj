import assert from "node:assert/strict";
import test from "node:test";
import { readFileSync } from "node:fs";
import plugin, { blockConfigSet, createConfigSetTool }
  from "../../scripts/openclaw/config-plugin/index.mjs";

const event = (command) => ({ toolName: "exec", params: { command, timeout: 30 } });

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

test("registers the declared tool and an exec-only hook", () => {
  const tools = [];
  const hooks = [];
  plugin.register({
    registerCommand(command) {
      assert.ok(["mention", "persona"].includes(command.name));
      assert.equal(command.requireAuth, false);
    },
    registerService(service) { assert.equal(service.id, "uraj-personas"); },
    registerTool(tool) { tools.push(tool.name); },
    on(name, handler, options) {
      hooks.push(name);
      if (name === "before_tool_call") {
        assert.equal(handler, blockConfigSet);
        assert.deepEqual(options.matcher, ["exec"]);
      }
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

test("native config set attempts are redirected without execution", () => {
  for (const command of [
    "openclaw config set agents.defaults.model local/one",
    "node /app/openclaw.mjs config set bindings '[]' --strict-json",
    "openclaw config set bindings '[]'; echo done",
    "cd /tmp && openclaw  config   set x 1",
  ]) {
    const result = blockConfigSet(event(command));
    assert.equal(result.block, true, command);
    assert.match(result.blockReason, /openclaw_config_set/);
  }
});

test("unrelated shell, reads and non-shell tools are untouched", () => {
  for (const command of ["ls | head", "openclaw config get tools", "echo $HOME"]) {
    assert.equal(blockConfigSet(event(command)), undefined);
  }
  assert.equal(blockConfigSet({ ...event("openclaw config set x 1"),
    toolName: "read" }), undefined);
  assert.equal(blockConfigSet({ ...event("openclaw config set x 1"),
    toolKind: "code_mode_exec" }), undefined);
});
