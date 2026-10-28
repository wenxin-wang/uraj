import { readFile } from "node:fs/promises";

// Credentials never leave the Gateway or travel to configurable endpoints.
export function createFeishuApi({ read = readFile, request = fetch } = {}) {
  let cached;
  async function http(resource, options = {}) {
    const response = await request(`https://open.feishu.cn/open-apis/${resource}`, {
      ...options, redirect: "error", signal: AbortSignal.timeout(10000),
    });
    if (!response.ok) throw new Error("Feishu HTTP request failed");
    const body = await response.json();
    if (body.code !== 0) throw new Error("Feishu API refused request");
    return body;
  }
  async function call(resource, options = {}) {
    if (!cached || cached.until < Date.now()) {
      const base = JSON.parse(await read("/etc/openclaw/base.json", "utf8"));
      const appId = base.channels.feishu.accounts.main.appId ??
        (await read("/run/secrets/feishu-app-id", "utf8")).trim();
      const appSecret = (await read("/run/secrets/feishu-app-secret", "utf8")).trim();
      const result = await http("auth/v3/tenant_access_token/internal", {
        method: "POST", headers: { "Content-Type": "application/json" },
        body: JSON.stringify({ app_id: appId, app_secret: appSecret }),
      });
      if (!result.tenant_access_token) throw new Error("Missing Feishu token");
      cached = { token: result.tenant_access_token, until: Date.now() + 300000 };
    }
    return http(resource, { ...options, headers: {
      "Content-Type": "application/json", Authorization: `Bearer ${cached.token}`,
    } });
  }
  function chatId(id) {
    if (!/^oc_[a-zA-Z0-9]+$/.test(id)) throw new Error("Invalid chat ID");
    return id;
  }
  return {
    async owner(id) {
      const result = await call(`im/v1/chats/${chatId(id)}?user_id_type=open_id`);
      return result.data?.owner_id;
    },
    async alone(id, owner) {
      // The chat-member API lists users; bots are a separate membership list.
      // Refuse partial/unexpected responses rather than assuming a private group.
      const info = await call(`im/v1/chats/${chatId(id)}?user_id_type=open_id`);
      const members = await call(`im/v1/chats/${chatId(id)}/members?member_id_type=open_id&page_size=100`);
      const users = members.data?.items;
      return Array.isArray(users) && members.data.has_more === false && users.length === 1 &&
        users[0].member_id === owner && users[0].member_id_type === "open_id" &&
        Number(info.data?.user_count) === 1 && Number(info.data?.bot_count) === 1;
    },
    async notify(id, text) {
      await call("im/v1/messages?receive_id_type=chat_id", { method: "POST",
        body: JSON.stringify({ receive_id: chatId(id), msg_type: "text",
          content: JSON.stringify({ text }) }),
      });
    },
  };
}
