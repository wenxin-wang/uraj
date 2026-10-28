import { mayManageGroup, readGroupOwner } from "./mention.mjs";

// Built-in /model works in groups only for senders in allowFrom, which holds
// the command owners.  Group owners change and are looked up per message, so
// they get this command; it stores the same session override as /model -s.
export function createGroupModelCommand(run, ownerOf = readGroupOwner) {
  return {
    name: "groupmodel",
    description: "切换本群当前话题的模型：/groupmodel 别名 或 default",
    channels: ["feishu"],
    acceptsArgs: true,
    requireAuth: false,
    async handler(ctx) {
      const match = /^chat:(oc_[a-zA-Z0-9]+)$/.exec(ctx.to ?? "");
      if ((ctx.channelId ?? ctx.channel) !== "feishu" || !match ||
          ctx.accountId !== "main" || typeof ctx.sessionKey !== "string" ||
          typeof ctx.agentId !== "string") {
        return { text: "请在飞书 main 机器人的群聊中使用此命令。" };
      }
      // Feishu post messages, such as a new topic's first message, arrive as
      // Markdown with "-" escaped; the checker validates the result.
      const model = ctx.args?.trim().replace(/\\([-._/])/g, "$1") ?? "";
      if (!model || /\s/.test(model)) {
        return { text: "用法：/groupmodel 别名（如 astra-6）或 provider/model；/groupmodel default 恢复默认。" };
      }
      const sender = /^feishu:(ou_[a-zA-Z0-9]+)$/.exec(ctx.from ?? "")?.[1];
      if (!sender) return { text: "无法确认发送者身份，未修改。" };
      try {
        if (!await mayManageGroup(ctx.config, match[1], sender, ownerOf)) {
          return { text: "只有当前飞书群主或 OpenClaw 命令管理员可以切换本群模型。" };
        }
      } catch {
        return { text: "无法查询群主，未修改。请检查飞书获取群信息权限（im:chat:read）及网络后重试，或请 OpenClaw 命令管理员操作。" };
      }
      const result = await run(["session-model", ctx.sessionKey, ctx.agentId, model]);
      if (!result.ok) return { text: "切换未成功：模型须是已声明的别名或 provider/model。" };
      return { text: model === "default"
        ? "已恢复本话题的默认模型。"
        : `已将本话题切换到 ${model}。其他话题不受影响。` };
    },
  };
}
