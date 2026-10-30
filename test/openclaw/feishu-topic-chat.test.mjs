import assert from "node:assert/strict";
import { execFileSync } from "node:child_process";
import fs from "node:fs/promises";
import os from "node:os";
import path from "node:path";
import test from "node:test";
import vm from "node:vm";

const patch = new URL("../../env/docker/openclaw-gateway/feishu-topic-chat.mjs", import.meta.url);
// Small build-layout fixture; FEISHU_DIST also runs these checks against the
// original image bundles, without loading the Gateway or its dependencies.
const fixture = [
  "async function handleFeishuMessage(params) {",
  "\tlet effectiveThreadId = ctx.threadId;",
  "createFeishuClient(account);",
  "}",
  '\tconst baseKey = `feishu:${accountId}:${event.message.chat_id?.trim() || "unknown"}`;',
  "const ingress = { threadId: ctx.rootId && isTopicSession ? ctx.rootId : void 0 };",
  "const conversation = { threadId: ctx.rootId && isTopicSession ? ctx.rootId : void 0 };",
  "const reply = { messageThreadId: ctx.rootId && isTopicSession ? ctx.rootId : void 0 };",
].join("\n");

test("topic starter and replies persist the same background delivery anchor", async () => {
  const root = await fs.mkdtemp(path.join(os.tmpdir(), "feishu-anchor-"));
  try {
    if (process.env.FEISHU_DIST) {
      await fs.cp(process.env.FEISHU_DIST, root, { recursive: true });
    } else {
      await fs.writeFile(path.join(root, "handler.mjs"), fixture);
    }
    execFileSync(process.execPath, [patch.pathname, root]);
    const files = (await fs.readdir(root, { recursive: true })).filter(p => p.endsWith(".mjs"));
    for (const file of files) {
      const text = await fs.readFile(path.join(root, file), "utf8");
      for (const field of ["threadId", "messageThreadId"]) {
        const matches = [...text.matchAll(new RegExp("\\b" + field + ": (isTopicSession \\? ctx\\.rootId \\?\\? ctx\\.messageId : void 0)", "g"))];
        assert.equal(matches.length, field === "threadId" ? 2 : 1, file + ": " + field);
        for (const match of matches) {
          const evaluate = (ctx, isTopicSession) => vm.runInNewContext(match[1], { ctx, isTopicSession });
          assert.equal(evaluate({ messageId: "om_starter" }, true), "om_starter");
          assert.equal(evaluate({ rootId: "om_starter", messageId: "om_reply" }, true), "om_starter");
          assert.equal(evaluate({ rootId: "om_starter", messageId: "om_reply" }, false), undefined);
          assert.equal(evaluate({ messageId: "om_dm" }, false), undefined);
        }
      }
    }
    assert.throws(() => execFileSync(process.execPath, [patch.pathname, root], { stdio: "pipe" }), /Unexpected Feishu handler layout/);
  } finally {
    await fs.rm(root, { recursive: true, force: true });
  }
});

test("an upstream layout change fails instead of silently omitting an anchor", async () => {
  const root = await fs.mkdtemp(path.join(os.tmpdir(), "feishu-anchor-layout-"));
  try {
    await fs.writeFile(path.join(root, "handler.mjs"), fixture.replace("messageThreadId: ctx.rootId", "messageThreadId: changedRoot"));
    assert.throws(() => execFileSync(process.execPath, [patch.pathname, root], { stdio: "pipe" }), /Unexpected Feishu handler layout/);
    assert.equal(await fs.readFile(path.join(root, "handler.mjs"), "utf8"), fixture.replace("messageThreadId: ctx.rootId", "messageThreadId: changedRoot"));
  } finally {
    await fs.rm(root, { recursive: true, force: true });
  }
});
