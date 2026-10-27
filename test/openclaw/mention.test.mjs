import assert from "node:assert/strict";
import test from "node:test";
import { createMentionCommand, readGroupOwner } from "../../scripts/openclaw/config-plugin/mention.mjs";

const context = {
  channel: "feishu", accountId: "main", to: "chat:oc_test",
  from: "feishu:ou_owner",
  isAuthorizedSender: true, args: "off",
  config: { channels: { feishu: { requireMention: true } } },
};

test("group owner can write only the current whole group without global admin admission", async () => {
  const calls = [];
  const command = createMentionCommand(async (args) => {
    calls.push(args);
    return { ok: true };
  }, async () => "ou_owner");
  assert.equal(command.requireAuth, false);
  const result = await command.handler({ ...context, messageThreadId: "topic1", isAuthorizedSender: false });
  assert.match(result.text, /已保存/);
  await command.handler({ ...context, args: "on" });
  assert.deepEqual(calls, [
    ["set", "channels.feishu.groups.oc_test.requireMention", "false"],
    ["set", "channels.feishu.groups.oc_test.requireMention", "true"],
  ]);
});

test("invalid context, arguments and unauthorized senders cannot write", async () => {
  const command = createMentionCommand(async () => { assert.fail("unexpected write"); }, async () => "ou_owner");
  for (const changes of [
    { from: "feishu:ou_other" }, { from: undefined }, { channel: "slack" }, { to: "user:ou_test" },
    { to: "chat:oc_test:topic:root" }, { accountId: "other" },
    { args: "off oc_other" }, { args: "status" },
    { config: { channels: { feishu: { accounts: { main: { groups: {} } } } } } },
  ]) await command.handler({ ...context, ...changes });
});

test("status respects overrides and failed writes do not claim success", async () => {
  const command = createMentionCommand(async () => ({ ok: false }), async () => "ou_owner");
  assert.match((await command.handler(context)).text, /未确认成功/);
  assert.match((await command.handler({ ...context, args: "status" })).text, /需要 @/);
  const config = structuredClone(context.config);
  config.channels.feishu.groups = { oc_test: { requireMention: false } };
  assert.match((await command.handler({ ...context, args: "", config })).text, /无需 @/);
});

test("owner lookup failures and ownership transfer fail closed", async () => {
  let owner = "ou_owner";
  let writes = 0;
  const command = createMentionCommand(async () => { writes++; return { ok: true }; },
    async () => { if (!owner) throw new Error("offline"); return owner; });
  await command.handler(context);
  owner = "ou_new";
  assert.match((await command.handler(context)).text, /只有当前飞书群主/);
  owner = undefined;
  assert.match((await command.handler(context)).text, /无法查询群主/);
  assert.equal(writes, 1);
});

test("explicit command owners can act without group lookup, but pairing and wildcards cannot", async () => {
  let writes = 0;
  let lookups = 0;
  const command = createMentionCommand(async () => { writes++; return { ok: true }; },
    async () => { lookups++; return "ou_someone_else"; });
  for (const owner of ["feishu:ou_owner", "ou_owner"]) {
    const config = { ...context.config, commands: { ownerAllowFrom: [owner] } };
    assert.match((await command.handler({ ...context, config })).text, /已保存/);
  }
  assert.equal(writes, 2);
  assert.equal(lookups, 0);
  for (const owner of ["*", "feishu:*", "slack:ou_owner", "feishu:ou_other"]) {
    const config = { ...context.config, commands: { ownerAllowFrom: [owner] } };
    assert.match((await command.handler({ ...context, config })).text, /只有当前飞书群主/);
  }
  await command.handler(context);
  assert.equal(writes, 2);
  assert.equal(lookups, 5);
});

test("owner lookup uses fixed Feishu endpoints, open IDs and rejects API errors", async () => {
  const requests = [];
  const read = async (file) => file.endsWith("base.json")
    ? JSON.stringify({ channels: { feishu: { accounts: { main: { appId: "cli_test" } } } } })
    : "secret\n";
  const request = async (url, options) => {
    requests.push([url, options]);
    return { ok: true, json: async () => url.includes("tenant_access_token")
      ? { code: 0, tenant_access_token: "token" }
      : { code: 0, data: { owner_id: "ou_owner" } } };
  };
  assert.equal(await readGroupOwner("oc_test", { read, request }), "ou_owner");
  assert.equal(requests[1][0], "https://open.feishu.cn/open-apis/im/v1/chats/oc_test?user_id_type=open_id");
  assert.equal(requests[1][1].headers.Authorization, "Bearer token");
  assert.equal(requests[0][1].redirect, "error");
  const secretRead = async (file) => {
    if (file.endsWith("base.json")) return JSON.stringify({ channels: { feishu: { accounts: { main: {} } } } });
    if (file.endsWith("feishu-app-id")) return "cli_private\n";
    return "secret\n";
  };
  await readGroupOwner("oc_test", { read: secretRead, request });
  assert.equal(JSON.parse(requests[2][1].body).app_id, "cli_private");
  await assert.rejects(readGroupOwner("oc_test", { read, request: async () => ({
    ok: true, json: async () => ({ code: 99991672 }),
  }) }));
});
