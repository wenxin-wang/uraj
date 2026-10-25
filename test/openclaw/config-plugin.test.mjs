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
  plugin.register({
    registerTool(tool) { tools.push(tool.name); },
    on(name, handler, options) {
      assert.equal(name, "before_tool_call");
      assert.equal(handler, blockConfigSet);
      assert.deepEqual(options.matcher, ["exec"]);
    },
  });
  assert.deepEqual(tools, ["openclaw_config_set"]);
});

test("tool passes exactly one path and JSON value to the checker", async () => {
  let call;
  const tool = createConfigSetTool((command, args, options) => {
    call = { command, args, options };
    return { status: 0, stdout: "Configuration committed.\n", stderr: "" };
  });
  const value = { name: "研究 助手", workspace: "/data/openclaw/workspaces/a" };
  const result = await tool.execute("call", { path: "agents.entries.a", value });
  assert.equal(call.command, process.execPath);
  assert.deepEqual(call.args,
    ["/etc/openclaw/config.mjs", "set", "agents.entries.a", JSON.stringify(value)]);
  assert.equal(result.content[0].text, "Configuration committed.");
  assert.equal(result.details.ok, true);
});

test("tool reports checker refusals and rejects incomplete calls", async () => {
  const tool = createConfigSetTool(() => ({
    status: 1, stdout: "", stderr: "Only agent and binding edits are accepted\n",
  }));
  const result = await tool.execute("call", { path: "tools.allow", value: ["*"] });
  assert.equal(result.details.ok, false);
  assert.match(result.content[0].text, /Only agent and binding edits/);
  await assert.rejects(tool.execute("call", { path: "bindings" }));
  await assert.rejects(tool.execute("call", { value: [] }));
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
