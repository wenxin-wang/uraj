// Test the actual added patch code without loading OpenClaw or contacting Feishu.
import assert from "node:assert/strict";
import { readFileSync } from "node:fs";
import test from "node:test";
import vm from "node:vm";

const patch = readFileSync(
  new URL("../../env/docker/openclaw-feishu/patches/feishu-get-receipt.patch", import.meta.url),
  "utf8",
);
const patchedHunk = patch.split("\n")
  .filter((line) => (line.startsWith("+") && !line.startsWith("+++")) || line.startsWith(" "))
  .map((line) => line.slice(1)).join("\n");
const code = patchedHunk.slice(
  patchedHunk.indexOf("    // Receipt means"),
  patchedHunk.indexOf("    // In group chats"),
);

async function receive({ enabled = true, synthetic = false, suppressed = false,
  messageId = "om_received", create = async () => ({ code: 0, data: { reaction_id: "r1" } }),
} = {}) {
  const requests = [];
  const logs = [];
  const context = {
    process: { env: { OPENCLAW_FEISHU_RECEIPT_REACTION: enabled ? "GET" : "" } },
    directPreDispatchTarget: synthetic ? "chat:synthetic" : undefined,
    ctx: { messageId, suppressReplyTarget: suppressed },
    effectiveCfg: { current: true },
    account: { accountId: "main" },
    resolveFeishuRuntimeAccount: (value) => value,
    createFeishuClient: (account) => {
      assert.equal(account.accountId, "main");
      assert.equal(account.cfg.current, true);
      return { im: { messageReaction: { create: (request) => {
        requests.push(request);
        return create(request);
      } } } };
    },
    log: (line) => logs.push(line),
  };
  vm.runInNewContext(code, context);
  // Dispatch continues even while the reaction promise is pending.
  context.dispatched = true;
  await new Promise((resolve) => setImmediate(resolve));
  return { requests, logs, dispatched: context.dispatched };
}

test("GET targets the incoming message and does not wait for a model or reaction response", async () => {
  const result = await receive({ create: () => new Promise(() => {}) });
  assert.equal(result.dispatched, true);
  assert.equal(result.requests.length, 1);
  assert.equal(result.requests[0].path.message_id, "om_received");
  assert.equal(result.requests[0].data.reaction_type.emoji_type, "GET");
});

test("disabled and synthetic events do not create reactions", async () => {
  for (const options of [
    { enabled: false }, { synthetic: true }, { suppressed: true }, { messageId: "synthetic-1" },
  ]) {
    assert.equal((await receive(options)).requests.length, 0);
  }
});

test("API failures are logged without blocking dispatch", async () => {
  for (const response of [{ code: 99991672 }, { code: 0 }, undefined]) {
    const result = await receive({ create: async () => response });
    assert.equal(result.dispatched, true);
    assert.equal(result.logs.length, 1);
  }
});

test("thrown SDK errors do not leak credentials or reject the message", async () => {
  const result = await receive({ create: () => { throw new Error("secret-token"); } });
  assert.equal(result.dispatched, true);
  assert.equal(result.logs.length, 1);
  assert.ok(!result.logs[0].includes("secret-token"));
});

test("successful receipt is retained without a follow-up message", async () => {
  const result = await receive();
  assert.equal(result.requests.length, 1);
  assert.deepEqual(result.logs, []);
});
