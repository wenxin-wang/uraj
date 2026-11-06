import assert from "node:assert/strict";
import fs from "node:fs/promises";
import os from "node:os";
import path from "node:path";
import test from "node:test";
import vm from "node:vm";
import { patchDirectory, patchFeishuCardStyle } from "../../env/docker/openclaw-gateway/feishu-card-style.mjs";
import { patchFeishuGuardedProgress, patchFeishuStatusSession } from "../../env/docker/openclaw-gateway/feishu-guarded-progress.mjs";

const fixture = name => fs.readFile(new URL(`./fixtures/${name}.txt`, import.meta.url), "utf8");
const builders = await fixture("feishu-card-builders");
const dispatcher = await fixture("feishu-reply-dispatcher");
const session = await fixture("feishu-streaming-session");
const styledBuilders = patchFeishuCardStyle(builders);

function harness() {
  const sent = [];
  const api = vm.runInNewContext(styledBuilders + "\n({buildStructuredCard, chunkFeishuCardMarkdown, sendStructuredCardFeishu, buildFeishuPresentationCard});", {
    Buffer,
    resolveFeishuCardTemplate: value => value,
    buildMentionedCardContent: (mentions, text) => mentions.map(m => `<at id=${m.id}></at>`).join("") + text,
    sendCardFeishu: params => { sent.push(params); return { messageId: "om_answer" }; },
    chunkFeishuMarkdownByEnvelope: params => params,
    escapeFeishuCardMarkdownText: text => text,
    buildFeishuPayloadButton: button => ({ tag: "button", text: { tag: "plain_text", content: button.label } }),
  });
  return { ...api, sent };
}

test("shared sender styles final and background answer cards; byte budget includes styles and metadata", async () => {
  const h = harness();
  const options = { header: { title: "助手", template: "blue" }, note: "Model: test-model | Effort: xhigh" };
  const text = "正文 **加粗**\n\n```sh\nprintf hello\n```";
  await h.sendStructuredCardFeishu({ text, ...options });
  const card = h.sent[0].card;
  assert.equal(card.body.elements[0].content, text);
  assert.equal(card.body.elements[0].text_size, "heading");
  assert.equal(card.body.elements.at(-1).text_size, "normal");
  assert.equal(card.header.padding, "8px 12px 8px 12px");
  assert.equal(card.body.padding, card.header.padding);
  assert.equal(card.body.vertical_spacing, "4px");
  assert.equal(card.config.summary.content, "正文 加粗 printf hello");
  const mentions = [{ id: "ou_test" }];
  const chunks = h.chunkFeishuCardMarkdown({ text, ...options, firstChunkMentions: mentions });
  assert.equal(chunks.contentBytes(text, true), Buffer.byteLength(JSON.stringify(h.buildStructuredCard(text, { ...options, mentions }))));
  assert.equal(chunks.contentBytes(text, false), Buffer.byteLength(JSON.stringify(card)));
});

test("generated presentation cards retain buttons and distinguish context from body text", () => {
  const h = harness();
  const card = h.buildFeishuPresentationCard({ fallbackText: "正文", presentation: {
    title: "结果", tone: "success", blocks: [
      { type: "text", text: "详细说明" },
      { type: "context", text: "附加信息" },
      { type: "buttons", buttons: [{ label: "查看" }] },
    ],
  } });
  assert.equal(card.body.elements[0].text_size, "heading");
  assert.equal(card.body.elements[1].text_size, "heading");
  assert.equal(card.body.elements[2].text_size, "normal");
  assert.equal(card.body.elements[3].tag, "button");
  assert.equal(card.body.elements[3].text.content, "查看");
  assert.equal(card.header.template, "green");
  assert.equal(card.config.summary.content, "正文 详细说明");
});

test("answer previews skip only known persona banners and exclude mentions and metadata", () => {
  const h = harness();
  for (const banner of [
    "我目前是「家庭助手 · 共享」，不使用私人角色的记忆。\n可以继续聊，或用 /persona 选择／创建角色。",
    "我目前是「私人助手 · 私人」，使用你的私人身份和记忆。\n可以继续聊，或用 /persona 选择／创建角色。",
    "我目前是「私人助手 · 私人」。用 /persona 可以选择／创建角色。",
  ]) {
    const text = banner + "\n\n## 未能确认验证通过\n\n请查看 [日志](https://example.com)。";
    const card = h.buildStructuredCard(text, { mentions: [{ id: "ou_test" }], note: "Model: hidden | Effort: high" });
    assert.equal(card.config.summary.content, "未能确认验证通过 请查看 日志。");
    assert.ok(card.body.elements[0].content.endsWith(text), "only the preview omits the banner");
  }
  const normal = "我目前是「值班人」。这里是本次检查结果。";
  assert.equal(h.buildStructuredCard(normal).config.summary.content, normal);
});

test("previews retain readable code, cap Unicode text, and handle cards with only controls", () => {
  const h = harness();
  const card = h.buildStructuredCard("**检查完成**\n- `foo_bar` &lt; 3\n- ![截图](https://example.com/image)");
  assert.equal(card.config.summary.content, "检查完成 foo_bar < 3 截图");
  const long = h.buildStructuredCard("😀".repeat(90)).config.summary.content;
  assert.equal(long, "😀".repeat(79) + "…");
  const controls = h.buildFeishuPresentationCard({ presentation: { blocks: [
    { type: "buttons", buttons: [{ label: "查看" }] },
  ] } });
  assert.equal(controls.config.summary.content, "卡片消息");
});

test("shared identity has a friendly title without changing custom identities", () => {
  const resolve = vm.runInNewContext(patchFeishuCardStyle(session + dispatcher) + "\nresolveCardHeader;", {
    resolveFeishuIdentityEmoji: value => value ?? "",
  });
  assert.equal(resolve("household-shared").title, "共享助手");
  assert.equal(resolve("household-shared", { name: "household-shared", emoji: "🏠" }).title, "🏠 共享助手");
  assert.equal(resolve("household-shared", { name: "家庭管家" }).title, "家庭管家");
  assert.equal(resolve("private-alice", { name: "Alice" }).title, "Alice");
  assert.equal(resolve("main"), undefined);
});

test("style layout drift fails atomically across all four runtime/setup bundles", async t => {
  const root = await fs.mkdtemp(path.join(os.tmpdir(), "feishu-card-style-"));
  t.after(() => fs.rm(root, { recursive: true, force: true }));
  const monitor = session + dispatcher;
  for (const [name, content] of Object.entries({ "runtime.mjs": monitor, "setup.mjs": monitor,
    "send.mjs": builders, "setup-send.mjs": builders })) await fs.writeFile(path.join(root, name), content);
  const drift = builders.replace("return card;", "return changedCard;");
  await fs.writeFile(path.join(root, "setup-send.mjs"), drift);
  assert.throws(() => patchDirectory(root), /Unexpected Feishu card layout/);
  assert.equal(await fs.readFile(path.join(root, "runtime.mjs"), "utf8"), monitor);
  await fs.writeFile(path.join(root, "setup-send.mjs"), builders);
  assert.equal(patchDirectory(root), 4);
  assert.throws(() => patchDirectory(root), /already patched/);
});

test("actual target bundles match the card builders and accept progress then style patches", {
  skip: !process.env.FEISHU_DIST,
}, async () => {
  let count = 0;
  for (const file of await fs.readdir(process.env.FEISHU_DIST, { recursive: true })) {
    if (!file.endsWith(".mjs")) continue;
    const source = await fs.readFile(path.join(process.env.FEISHU_DIST, file), "utf8");
    const progress = patchFeishuGuardedProgress(source);
    const styled = patchFeishuCardStyle(progress === null ? source : patchFeishuStatusSession(progress));
    if (styled === null) continue;
    if (source.includes("function buildStructuredCard")) {
      const start = source.indexOf("function buildStructuredCard");
      const end = source.indexOf("\n//#endregion", start);
      assert.ok(builders.includes(source.slice(start, end)), file);
    }
    count++;
  }
  assert.equal(count, 4);
});
