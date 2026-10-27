import { readFile } from "node:fs/promises";

// This deployment has one Feishu app. Never send its secret to a configured URL.
export async function readGroupOwner(id, { read = readFile, request = fetch } = {}) {
  const base = JSON.parse(await read("/etc/openclaw/base.json", "utf8"));
  const appId = base.channels.feishu.accounts.main.appId ??
    (await read("/run/secrets/feishu-app-id", "utf8")).trim();
  if (!/^cli_[a-zA-Z0-9]+$/.test(appId)) throw new Error("Invalid Feishu App ID");
  const secret = (await read("/run/secrets/feishu-app-secret", "utf8")).trim();
  const call = async (path, options) => {
    const response = await request(`https://open.feishu.cn/open-apis/${path}`, {
      ...options, redirect: "error", signal: AbortSignal.timeout(10000),
    });
    if (!response.ok) throw new Error("Feishu request failed");
    const body = await response.json();
    if (body.code !== 0) throw new Error("Feishu request denied");
    return body;
  };
  if (!/^oc_[a-zA-Z0-9]+$/.test(id)) throw new Error("Invalid group ID");
  const auth = await call("auth/v3/tenant_access_token/internal", {
    method: "POST", headers: { "Content-Type": "application/json" },
    body: JSON.stringify({ app_id: appId, app_secret: secret }),
  });
  if (!auth.tenant_access_token) throw new Error("Missing tenant token");
  const chat = await call(`im/v1/chats/${id}?user_id_type=open_id`, {
    headers: { Authorization: `Bearer ${auth.tenant_access_token}` },
  });
  const owner = chat.data?.owner_id;
  if (typeof owner !== "string" || !/^ou_[a-zA-Z0-9]+$/.test(owner)) {
    throw new Error("Missing group owner");
  }
  return owner;
}

export function createMentionCommand(run, ownerOf = readGroupOwner) {
  return {
    name: "mention",
    description: "设置本群是否需要 @机器人：on / off / status",
    channels: ["feishu"],
    acceptsArgs: true,
    // Either an explicitly configured command owner or the actual group owner.
    // Pairing/isAuthorizedSender alone never grants administrator privileges.
    requireAuth: false,
    async handler(ctx) {
      const match = /^chat:(oc_[a-zA-Z0-9]+)$/.exec(ctx.to ?? "");
      if ((ctx.channelId ?? ctx.channel) !== "feishu" || !match ||
          ctx.accountId !== "main") {
        return { text: "请在飞书 main 机器人的群聊中使用此命令。" };
      }
      const id = match[1];
      const action = ctx.args?.trim().toLowerCase() || "status";
      if (action === "status") {
        const channel = ctx.config.channels?.feishu ?? {};
        const account = channel.accounts?.main ?? {};
        const groups = account.groups ?? channel.groups ?? {};
        const enabled = groups[id]?.requireMention ?? groups["*"]?.requireMention ??
          account.requireMention ?? channel.requireMention ?? true;
        return { text: enabled ? "本群当前需要 @机器人。" : "本群当前无需 @机器人，会响应普通消息。" };
      }
      if (!["on", "off"].includes(action)) {
        return { text: "用法：/mention on、/mention off、/mention status（作用于整个群）。" };
      }
      const sender = /^feishu:(ou_[a-zA-Z0-9]+)$/.exec(ctx.from ?? "")?.[1];
      if (!sender) return { text: "无法确认发送者身份，未修改。" };
      const owners = ctx.config.commands?.ownerAllowFrom;
      const admin = Array.isArray(owners) && owners.some((entry) =>
        typeof entry === "string" && [sender, `feishu:${sender}`].includes(entry.trim()));
      if (!admin) {
        try {
          if (await ownerOf(id) !== sender) {
            return { text: "只有当前飞书群主或 OpenClaw 命令管理员可以修改本群设置。" };
          }
        } catch {
          return { text: "无法查询群主，未修改。请检查飞书获取群信息权限（im:chat:read）及网络后重试，或请 OpenClaw 命令管理员操作。" };
        }
      }
      // Account-local settings would shadow the channel-level override.
      const account = ctx.config.channels?.feishu?.accounts?.main;
      if (account?.groups !== undefined) {
        return { text: "账号有独立 groups 配置，请先由管理员统一配置层级；未修改。" };
      }
      const result = await run(["set", `channels.feishu.groups.${id}.requireMention`,
        JSON.stringify(action === "on")]);
      if (!result.ok) return { text: "设置未确认成功，请稍后重试或查看 Gateway 日志。" };
      return { text: action === "on"
        ? "已保存：本群需要 @机器人。Gateway 加载配置后生效。"
        : "已保存：本群无需 @机器人，所有话题的普通消息都可能触发回复和模型费用。Gateway 加载后生效；飞书需开通 im:message.group_msg。" };
    },
  };
}
