import assert from "node:assert/strict";
import test from "node:test";
import { execFile } from "node:child_process";
import { promisify } from "node:util";
import { fileURLToPath } from "node:url";
import http from "node:http";
import fs from "node:fs/promises";
import os from "node:os";
import path from "node:path";
import { createConfigCommand, createConfigProxyService }
  from "../../scripts/openclaw/config-plugin/config-proxy.mjs";
import { createConfigSetTool } from "../../scripts/openclaw/config-plugin/index.mjs";

test("CLI strings and strict JSON use the existing restricted tool", async () => {
  const calls = [];
  const handle = createConfigCommand(createConfigSetTool(async (args) => {
    calls.push(args); return { ok: true, stdout: "committed" };
  }), () => ({ agents: { defaults: { model: "provider/model" } }, secret: "hidden" }));
  await handle(["config", "set", "agents.defaults.model", "provider/model"]);
  await handle(["config", "set", "agents.defaults.model", '{"primary":"p/m"}', "--strict-json"]);
  assert.deepEqual(calls, [["set", "agents.defaults.model", '"provider/model"'],
    ["set", "agents.defaults.model", '{"primary":"p/m"}']]);
  assert.equal((await handle(["config", "get", "agents.defaults.model", "--json"])).stdout, '"provider/model"\n');
  for (const args of [
    ["config", "get", "gateway"], ["config", "get"],
    ["config", "set", "bindings", "[]"],
    ["config", "set", "agents.defaults.model", "bad", "--strict-json"],
    ["config", "set", "agents.defaults.model", "x", "--allow-exec"],
    ["config", "unset", "agents.defaults.model"], ["agents", "list"],
  ]) await assert.rejects(handle(args));
  assert.equal(calls.length, 2);
});

test("Unix socket transport rejects invalid input and hides internal errors", async () => {
  const directory = await fs.mkdtemp(path.join(os.tmpdir(), "config-proxy-"));
  const service = createConfigProxyService(async (args) => {
    if (args[0] === "fail") throw new Error("secret credential");
    return { ok: true, stdout: JSON.stringify(args) };
  }, directory);
  try {
    await service.start();
    const request = (body) => new Promise((resolve, reject) => {
      const req = http.request({ socketPath: path.join(directory, "config.sock"),
        path: "/config", method: "POST" }, (res) => {
        let text = ""; res.on("data", (chunk) => text += chunk);
        res.on("end", () => resolve(JSON.parse(text)));
      });
      req.on("error", reject); req.end(body);
    });
    assert.equal((await request('["config","--help"]')).ok, true);
    const client = fileURLToPath(new URL(
      "../../scripts/openclaw/config-plugin/config-client.py", import.meta.url));
    const script = `import importlib.util, sys
spec = importlib.util.spec_from_file_location("client", sys.argv[1])
module = importlib.util.module_from_spec(spec)
spec.loader.exec_module(module)
module.SOCKET_PATH = sys.argv[2]
sys.argv = ["openclaw", "config", "--help"]
sys.exit(module.main())`;
    const result = await promisify(execFile)("python3", ["-B", "-c", script, client,
      path.join(directory, "config.sock")]);
    assert.equal(result.stdout, '["config","--help"]');

    for (const body of ['["fail"]', '{', 'x'.repeat(17000)]) {
      const result = await request(body);
      assert.equal(result.ok, false);
      assert.doesNotMatch(JSON.stringify(result), /secret credential/);
    }
    assert.equal((await fs.stat(path.join(directory, "config.sock"))).mode & 0o777, 0o600);
    assert.equal((await fs.stat(path.join(directory, "openclaw"))).mode & 0o777, 0o500);
    await service.stop();
    await service.start();
    assert.equal((await request('["after-restart"]')).ok, true);
  } finally { await service.stop(); await fs.rm(directory, { recursive: true, force: true }); }
});
