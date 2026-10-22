import assert from "node:assert/strict";
import test from "node:test";
import { spawnSync } from "node:child_process";
import { readFileSync } from "node:fs";
import plugin, { routeConfigSet } from "../../scripts/openclaw/config-plugin/index.mjs";

const event = (command) => ({ toolName: "exec", params: { command, timeout: 30 } });

test("shipped manifest activates the hook at Gateway startup, not only CLI inspection", () => {
  const root = new URL("../../scripts/openclaw/config-plugin/", import.meta.url);
  const manifest = JSON.parse(readFileSync(new URL("openclaw.plugin.json", root), "utf8"));
  const pkg = JSON.parse(readFileSync(new URL("package.json", root), "utf8"));
  // v2026.10.3 startup planning does not import enabled-only plugins. The
  // startup and hook activation paths both require explicit enablement, which
  // the generated Guix configuration tests cover separately.
  assert.equal(manifest.id, plugin.id);
  assert.equal(manifest.activation.onStartup, true);
  assert.ok(manifest.activation.onCapabilities.includes("hook"));
  assert.deepEqual(pkg.openclaw.extensions, ["./index.mjs"]);
});

test("registers an exec-only native hook", () => {
  plugin.register({ on(name, handler, options) {
    assert.equal(name, "before_tool_call");
    assert.equal(handler, routeConfigSet);
    assert.deepEqual(options.matcher, ["exec"]);
  } });
});

test("native string and JSON forms reach checker with equivalent arguments", () => {
  for (const [command, expected] of [
    ["openclaw config set agents.defaults.model local/one", '"local/one"'],
    ["node /app/openclaw.mjs config set bindings '[]' --strict-json", "[]"],
    ['openclaw config set --json bindings "[]"', "[]"],
    ["openclaw config set agents.entries.a '{\"name\":\"研究 助手\",\"workspace\":\"/workspaces/a\"}'",
      JSON.stringify({ name: "研究 助手", workspace: "/workspaces/a" })],
    ["openclaw config set 'bindings[0].agentId' research", '"research"'],
    ["openclaw config set agents.entries.a.name ''", '""'],
    [String.raw`openclaw config set agents.entries.a.name 'a'\''b $HOME $(touch nope)'`,
      JSON.stringify("a'b $HOME $(touch nope)")],
  ]) {
    const result = routeConfigSet(event(command));
    assert.equal(result.params.timeout, 30);
    // Ask the real POSIX shell to decode the generated command into argv without
    // executing node or any payload: replace node with a shell function.
    const script = 'node() { printf "%s\\0" "$@"; }; ' + result.params.command;
    const run = spawnSync("sh", ["-c", script], { encoding: "utf8" });
    assert.equal(run.status, 0, run.stderr);
    const argv = run.stdout.split("\0").slice(0, -1);
    assert.equal(argv[0], "/etc/openclaw/config.mjs");
    assert.equal(argv[1], "set");
    assert.equal(argv[3], expected);
  }
});

test("complex or unsupported config set calls are blocked without execution", () => {
  for (const command of [
    "openclaw config set --help",
    "node /app/openclaw.mjs config set --help",
    "openclaw config set bindings '[]'; echo done",
    "openclaw config set bindings '[]' | cat",
    "openclaw config set bindings '[]' > file",
    'openclaw config set agents.defaults.model "$MODEL"',
    "openclaw config set bindings $(cat file)",
    "openclaw config set bindings `cat file`",
    "OPENCLAW_CONFIG_PATH=/tmp/x openclaw config set bindings '[]'",
    "openclaw config set bindings '[]' --dry-run",
    "openclaw config set --batch-json '[]'",
    "openclaw config set bindings '[{unquoted:true}]'",
    "openclaw config set bindings '[]'\necho done",
    "openclaw config set agents.entries.a.name 'unfinished",
    "openclaw config set agents.defaults.model local/one --strict-json",
  ]) {
    const result = routeConfigSet(event(command));
    assert.equal(result.block, true, command);
    assert.equal(result.params, undefined);
  }
});

test("unrelated shell, reads, checker calls and non-shell tools are untouched", () => {
  for (const command of ["ls | head", "openclaw config get tools", "echo $HOME",
    "node /etc/openclaw/config.mjs set bindings '[]'"]) {
    assert.equal(routeConfigSet(event(command)), undefined);
  }
  assert.equal(routeConfigSet({ ...event("openclaw config set x 1"),
    toolName: "read" }), undefined);
  assert.equal(routeConfigSet({ ...event("openclaw config set x 1"),
    toolKind: "code_mode_exec" }), undefined);
});
