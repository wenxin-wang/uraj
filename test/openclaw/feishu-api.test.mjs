import assert from "node:assert/strict";
import test from "node:test";
import { createFeishuApi } from "../../scripts/openclaw/config-plugin/feishu-api.mjs";

test("private membership requires complete user and bot counts; token and endpoints stay fixed", async () => {
  let users = { has_more: false, items: [{ member_id: "ou_alice", member_id_type: "open_id" }] };
  let info = { owner_id: "ou_alice", user_count: "1", bot_count: "1" };
  let tokens = 0;
  const api = createFeishuApi({
    read: async (file) => file.endsWith("base.json") ? JSON.stringify({ channels: { feishu: { accounts: { main: {} } } } }) : "test-secret",
    request: async (url, options) => {
      assert.ok(url.startsWith("https://open.feishu.cn/open-apis/"));
      assert.equal(options.redirect, "error");
      let data;
      if (url.includes("tenant_access_token")) { tokens++; return { ok: true, json: async () => ({ code: 0, tenant_access_token: "token" }) }; }
      assert.equal(options.headers.Authorization, "Bearer token");
      if (url.includes("/members?")) data = users;
      else data = info;
      return { ok: true, json: async () => ({ code: 0, data }) };
    },
  });
  assert.equal(await api.owner("oc_group"), "ou_alice");
  assert.equal(await api.alone("oc_group", "ou_alice"), true);
  assert.equal(await api.alone("oc_group", "ou_other"), false);
  users.has_more = true;
  assert.equal(await api.alone("oc_group", "ou_alice"), false);
  delete users.has_more;
  assert.equal(await api.alone("oc_group", "ou_alice"), false);
  users.has_more = false;
  info.bot_count = "2";
  assert.equal(await api.alone("oc_group", "ou_alice"), false);
  info = {};
  assert.equal(await api.alone("oc_group", "ou_alice"), false);
  assert.equal(tokens, 1);
  await assert.rejects(api.owner("oc_group/../../secrets"));
});

test("API denial propagates instead of treating unknown members as private", async () => {
  const api = createFeishuApi({
    read: async (file) => file.endsWith("base.json") ? '{"channels":{"feishu":{"accounts":{"main":{"appId":"test"}}}}}' : "test",
    request: async () => ({ ok: true, json: async () => ({ code: 99991672 }) }),
  });
  await assert.rejects(api.alone("oc_group", "ou_alice"), /refused/);
});
