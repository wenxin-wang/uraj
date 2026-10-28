import assert from "node:assert/strict";
import test from "node:test";
import { createGroupModelCommand } from "../../scripts/openclaw/config-plugin/group-model.mjs";
import { sessionModelParams } from "../../scripts/openclaw/config.mjs";

const key = "agent:household-shared:feishu:group:oc_test:topic:omt_1";
const context = {
  channel: "feishu", accountId: "main", to: "chat:oc_test", from: "feishu:ou_owner",
  sessionKey: key, agentId: "household-shared", args: "astra-6", isAuthorizedSender: false,
  config: {},
};

test("group owner and command owners switch only the current session", async () => {
  const calls = [];
  let lookups = 0;
  const command = createGroupModelCommand(async (args) => { calls.push(args); return { ok: true }; },
    async () => { lookups++; return "ou_owner"; });
  assert.equal(command.requireAuth, false);
  assert.match((await command.handler(context)).text, /astra-6/);
  await command.handler({ ...context, from: "feishu:ou_admin", args: "default",
    config: { commands: { ownerAllowFrom: ["feishu:ou_admin"] } } });
  assert.deepEqual(calls, [
    ["session-model", key, "household-shared", "astra-6"],
    ["session-model", key, "household-shared", "default"],
  ]);
  assert.equal(lookups, 1);
});

test("others, lookup failures and bad context cannot switch", async () => {
  const command = createGroupModelCommand(async () => assert.fail("unexpected switch"),
    async (chat) => { if (chat === "oc_test") return "ou_owner"; throw new Error("offline"); });
  assert.match((await command.handler({ ...context, from: "feishu:ou_other" })).text, /只有当前飞书群主/);
  assert.match((await command.handler({ ...context, to: "chat:oc_offline" })).text, /无法查询群主/);
  for (const changes of [{ to: "user:ou_owner" }, { channel: "slack" }, { accountId: "other" },
    { sessionKey: undefined }, { args: "" }, { args: "astra-6 -g" }, { from: undefined }]) {
    await command.handler({ ...context, ...changes });
  }
});

test("session-model accepts only one Feishu group session and model reference", () => {
  assert.deepEqual(sessionModelParams(key, "household-shared", "new-api-gpt/gpt-6-astra"),
    { key, agentId: "household-shared", model: "new-api-gpt/gpt-6-astra" });
  assert.equal(sessionModelParams("agent:main:feishu:group:oc_test", "main", "default").model, null);
  for (const [k, agent, model] of [
    ["agent:main:feishu:direct:ou_x", "main", "astra-6"],
    [key, "main", "astra-6"],
    [key, "household-shared", "a b"],
    [key, "household-shared", "../x"],
  ]) assert.throws(() => sessionModelParams(k, agent, model));
});
