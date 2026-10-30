// Feishu message events report chat_type "group" for topic-mode chats, so
// the plugin's topic_group branch never runs: a topic starter keys its session
// on thread_id and quote replies on root_id, splitting one topic in two.
// Look up chat_mode once per chat and mark topic chats as topic_group.
// Upstream: https://github.com/openclaw/openclaw/issues/160330
// Persist a reply anchor even for topic starters, which have no root_id.
// Ingress access, conversation.threadId and reply.messageThreadId use it
// so background completions and message tools stay in the originating topic.
// TODO: before enabling cron, anchor agent-initiated sends in topic chats;
// a session without an inbound message posts top-level, i.e. a new topic.
// The upstream fix PR #160332 covers this.
//
// The plugin also runs one agent turn at a time per chat, so in a topic chat
// a long turn in one topic holds every other topic's messages.  Queue by
// thread instead; a thread is a single session, so its turns stay ordered.
// Upstream: https://github.com/openclaw/openclaw/issues/54409 (same queue).
import { readdirSync, readFileSync, writeFileSync } from "node:fs";
import { join } from "node:path";

const root = process.argv[2] ?? "/app/dist";
const handler = "async function handleFeishuMessage(params) {";
const session = "\tlet effectiveThreadId = ctx.threadId;\n";

const threadAnchor = "ctx.rootId && isTopicSession ? ctx.rootId : void 0";
const anchoredThread = "isTopicSession ? ctx.rootId ?? ctx.messageId : void 0";

const helper = `// uraj: topic chats arrive as chat_type "group" (openclaw#160330).
const urajTopicModeChats = new Map();
async function urajIsTopicModeChat(account, chatId) {
	const key = \`\${account.accountId}:\${chatId}\`;
	if (!urajTopicModeChats.has(key)) {
		const response = await createFeishuClient(account).im.chat.get({ path: { chat_id: chatId } });
		if (response.code !== 0) throw new Error(response.msg ?? "chat lookup failed");
		urajTopicModeChats.set(key, response.data?.chat_mode === "topic");
	}
	return urajTopicModeChats.get(key);
}
`;

const queueKey = "\tconst baseKey = `feishu:${accountId}:${event.message.chat_id?.trim() || \"unknown\"}`;\n";
// Abort and /btw lanes derive from baseKey and become per-thread as well.
const threadQueueKey = `\tconst urajThreadId = event.message.thread_id?.trim();
\tconst baseKey = \`feishu:\${accountId}:\${event.message.chat_id?.trim() || "unknown"}\${urajThreadId ? \`:thread:\${urajThreadId}\` : ""}\`;
`;

const promote = `\tif (isGroup && ctx.chatType === "group" && ctx.threadId && isFeishuTopicSessionScope(groupSessionScope ?? "group")) try {
\t\tif (await urajIsTopicModeChat(account, ctx.chatId)) ctx = { ...ctx, chatType: "topic_group" };
\t} catch (err) {
\t\tlog(\`feishu[\${account.accountId}]: failed to resolve chat mode: \${String(err)}\`);
\t}
`;

function count(text, needle) {
  return text.split(needle).length - 1;
}

function* files(directory) {
  for (const entry of readdirSync(directory, { withFileTypes: true })) {
    const path = join(directory, entry.name);
    if (entry.isDirectory()) yield* files(path);
    else if (entry.name.endsWith(".mjs")) yield path;
  }
}

let patched = 0;
for (const path of files(root)) {
  const text = readFileSync(path, "utf8");
  if (!text.includes(handler)) continue;
  if (count(text, handler) !== 1 || count(text, session) !== 1 || count(text, queueKey) !== 1 ||
      count(text, threadAnchor) !== 3 ||
      !/\bcreateFeishuClient\b/.test(text) || text.includes("urajIsTopicModeChat")) {
    throw new Error(`Unexpected Feishu handler layout in ${path}`);
  }
  writeFileSync(path, text.replace(handler, helper + handler)
    .replace(session, promote + session).replace(queueKey, threadQueueKey).replaceAll(threadAnchor, anchoredThread));
  patched += 1;
}
if (patched === 0) throw new Error("Feishu message handler not found");
console.log(`patched ${patched} Feishu handler bundle(s)`);
