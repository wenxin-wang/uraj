import assert from "node:assert/strict";
import fs from "node:fs/promises";
import os from "node:os";
import path from "node:path";
import test from "node:test";
import vm from "node:vm";
import {
  patchDirectory, patchFeishuGuardedProgress, patchFeishuStatusSession,
  urajFeishuToolStatus,
} from "../../env/docker/openclaw-gateway/feishu-guarded-progress.mjs";
import { patchFeishuCardStyle, urajFeishuCardSummary } from "../../env/docker/openclaw-gateway/feishu-card-style.mjs";
import { PersonaStore } from "../../scripts/openclaw/config-plugin/persona-store.mjs";
import { Personas, SHARED } from "../../scripts/openclaw/config-plugin/persona.mjs";

// Execute the actual upstream dispatcher, stubbing only its external services.
// FEISHU_DIST additionally validates both bundles copied from a target image.
const original = await fs.readFile(new URL("./fixtures/feishu-reply-dispatcher.txt", import.meta.url), "utf8");
const originalSession = await fs.readFile(new URL("./fixtures/feishu-streaming-session.txt", import.meta.url), "utf8");
const forwarding = await fs.readFile(new URL("./fixtures/feishu-progress-forwarding.txt", import.meta.url), "utf8");
const prefixSource = await fs.readFile(new URL("./fixtures/feishu-reply-prefix.txt", import.meta.url), "utf8");
const styledBundle = patchFeishuCardStyle(originalSession + patchFeishuGuardedProgress(original));
const patched = styledBundle.slice(styledBundle.indexOf("//#region extensions/feishu/src/streaming-update.ts"));
const createPrefix = vm.runInNewContext(prefixSource + "\ncreateReplyPrefixContext;", {
  normalizeOptionalString: value => value?.trim(),
  extractShortModelName: value => value.split("/").at(-1),
  resolveAgentIdentity: () => ({}),
  resolveEffectiveMessagesConfig: () => ({}),
});
const tick = () => new Promise(resolve => setImmediate(resolve));

function harness({ hooks = ["reply_payload_sending"], mode = "partial", renderMode = "card",
  requiredMentionTargets, startGate, startError, closeError, discardError, sendError } = {}) {
  const calls = { starts: [], updates: [], closes: [], discards: 0, static: [], errors: [] };
  const noReply = { visibleReplySent: false };
  const receipt = (content) => ({ visibleReplySent: true, content, messageId: "om_card" });
  const send = kind => async (params) => {
    if (sendError) throw sendError;
    calls.static.push({ kind, ...params });
    return receipt(params.text);
  };
  let now = 100000;
  const timers = new Set();
  class Session {
    active = false;
    async start(target, type, options) {
      calls.starts.push({ target, type, options });
      await startGate;
      if (startError) throw startError;
      this.active = true;
    }
    isActive() { return this.active; }
    async update(text) { calls.updates.push(text); }
    async closeWithResult(text, options) {
      calls.closes.push({ text, options });
      this.active = false;
      if (closeError) throw closeError;
      return receipt(text);
    }
    async discard() {
      calls.discards++;
      this.active = false;
      if (discardError) throw discardError;
      return noReply;
    }
  }
  const context = {
    Date: { now: () => now },
    setInterval: callback => { timers.add(callback); return callback; },
    clearInterval: callback => timers.delete(callback),
    getFeishuRuntime: () => ({ channel: { text: {
      resolveTextChunkLimit: () => 4000, resolveChunkMode: () => "length",
      resolveMarkdownTableMode: () => "off", convertMarkdownTables: t => t,
      chunkMarkdownTextWithMode: t => [t],
    } } }),
    resolveFeishuRuntimeAccount: () => ({ accountId: "main", appId: "test", appSecret: "test",
      config: { renderMode, streaming: { mode } } }),
    createChannelReplyPipeline: createPrefix,
    getGlobalHookRunner: () => ({ hasHooks: name => hooks.includes(name) }),
    resolveChannelPreviewStreamMode: config => config.streaming.mode,
    resolveChannelStreamingBlockEnabled: () => false,
    resolveHumanDelayConfig: () => undefined,
    resolveConfiguredHttpTimeoutMs: () => 10000,
    createFeishuClient: () => ({}),
    resolveReceiveIdType: () => "chat_id",
    resolveFeishuIdentityEmoji: () => "",
    FeishuStreamingSession: Session,
    FeishuStreamingFinalizationError: class extends Error {},
    streamingStartBackoffUntilByAccount: new Map(),
    noVisibleFeishuReplyDelivery: noReply,
    createFeishuReplyDeliveryResult: result => result,
    mergeFeishuReplyDeliveryResults: (results, content) => ({
      visibleReplySent: results.some(r => r.visibleReplySent),
      content: content ?? results.find(r => r.content)?.content,
    }),
    createFeishuPartialReplyDeliveryError: (cause, deliveryResult) =>
      Object.assign(new Error("Partial delivery", { cause }), { deliveryResult }),
    isChannelPartialDeliveryError: e => Boolean(e.deliveryResult),
    toStringifiedError: e => e,
    createDeferred: () => Promise.withResolvers(),
    renderFeishuReplyPayload: async payload => ({ payload }),
    consumeFeishuPresentationFallbackMarker: payload => ({ payload }),
    resolveSendableOutboundReplyParts: payload => ({ text: payload.text ?? "",
      hasText: Boolean(payload.text), hasMedia: false, mediaUrls: [] }),
    getReplyPayloadTtsSupplement: () => undefined,
    withinCardTableLimit: () => true,
    chunkFeishuCardMarkdown: ({ text }) => [text],
    chunkFeishuPostMarkdown: ({ text }) => [text],
    resolveTextChunksWithFallback: (_text, chunks) => chunks,
    sendStructuredCardFeishu: send("card"), sendMessageFeishu: send("post"),
    materializeFeishuPostMarkdownSoftBreaks: t => t,
    stripReasoningTagsFromText: t => t, formatReasoningMessage: t => t,
    mergeStreamingText: (_previous, next) => next,
    formatChannelProgressDraftLineForEntry: () => "upstream progress",
  };
  const create = vm.runInNewContext(patched + "\ncreateFeishuReplyDispatcher;", context);
  const dispatcher = create({ cfg: {}, agentId: SHARED, chatId: "oc_group",
    sendTarget: "chat:oc_group", accountId: "main", sessionKey: `agent:${SHARED}:feishu:group:oc_group`,
    identity: { name: "PRIVATE_IDENTITY" }, allowReasoningPreview: true,
    replyToMessageId: "om_topic", rootId: "om_topic", threadReply: true,
    requiredMentionTargets, runtime: { error: e => calls.errors.push(e) } });
  return { ...dispatcher, calls, timers, advance(ms) {
    now += ms;
    for (const callback of timers) callback();
  } };
}

// Execute the real core forwarding gate with its normal verbose-off policy.
function progressBridge(replyOptions) {
  return vm.runInNewContext(forwarding + "\n({ forwardItemEvent, wrapProgressCallback });", {
    params: { replyOptions },
    state: { suppressAutomaticSourceDelivery: false, getDispatchReplyOperation: () => undefined,
      getDispatchAbortOperation: () => undefined },
    shouldSendToolSummaries: () => false,
    isDispatchOperationAborted: () => false,
    markProgress: () => {},
    waitForPendingDirectBlockReplyDelivery: async () => {},
  });
}

async function finalize(h, text) {
  const result = await h.delivery.deliver({ text }, { kind: "final" });
  await h.dispatcherOptions.onIdle();
  return result.finalization ? await result.finalization : result;
}

test("default verbosity forwards sanitized progress only when the channel owns it", async () => {
  let forwarded = 0;
  const onItemEvent = () => { forwarded++; return false; };
  await progressBridge({ onItemEvent }).forwardItemEvent({ kind: "tool" });
  assert.equal(forwarded, 0, "the upstream gate reproduces PR 90's missing updates");
  await progressBridge({ onItemEvent, suppressDefaultToolProgressMessages: true })
    .forwardItemEvent({ kind: "tool" });
  assert.equal(forwarded, 1);
});

test("long model waits show elapsed time and time since real progress, then stop", async () => {
  const h = harness();
  await h.dispatcherOptions.onReplyStart();
  h.advance(615000);
  await tick();
  assert.match(h.calls.updates.at(-1), /正在等待模型响应/);
  assert.match(h.calls.updates.at(-1), /已用时 10 分 15 秒 · 距上次进展 10 分 15 秒/);
  await progressBridge(h.replyOptions).forwardItemEvent({ kind: "tool", name: "read" });
  h.advance(15000);
  await tick();
  assert.match(h.calls.updates.at(-1), /正在查阅资料/);
  assert.match(h.calls.updates.at(-1), /已用时 10 分 30 秒 · 距上次进展 15 秒/);
  await finalize(h, "answer");
  const count = h.calls.updates.length;
  h.advance(15000);
  h.replyOptions.onAssistantMessageStart();
  await tick();
  assert.equal(h.calls.updates.length, count);
  assert.equal(h.timers.size, 0);
});

test("cleanup during startup stops the timer and late progress cannot revive it", async () => {
  const gate = Promise.withResolvers();
  const h = harness({ startGate: gate.promise });
  await h.dispatcherOptions.onReplyStart();
  h.dispatcherOptions.onCleanup();
  h.replyOptions.onItemEvent({ kind: "tool", name: "exec" });
  assert.equal(h.timers.size, 0);
  gate.resolve();
  await h.dispatcherOptions.onIdle();
  assert.equal(h.calls.discards, 1);
});

for (const statusOnly of [true, false]) {
  test(`real CardKit session uses the correct card mode and endpoint: statusOnly=${statusOnly}`, async () => {
    let now = 100000;
    const requests = [];
    const errors = [];
    let failSummary = false;
    const Session = vm.runInNewContext(patchFeishuCardStyle(patchFeishuStatusSession(originalSession + original)) + "\nFeishuStreamingSession;", {
      STREAMING_UPDATE_THROTTLE_MS: 1000,
      Date: { now: () => now },
      resolveFeishuCardTemplate: value => value,
      requestFeishuApi: fn => fn(),
      shouldPushStreamingUpdate: () => true,
      truncateSummary: text => text.slice(0, 50),
    });
    const session = new Session({ im: { message: {
      create: async () => ({ code: 0, data: { message_id: "om_status" } }),
      delete: async () => { throw new Error("delete unavailable"); },
    } } }, {}, error => errors.push(error));
    session.requestCardKit = async (path, operation, method, body) => {
      requests.push({ path, operation, method, body: body() });
      if (operation === "status-summary" && failSummary) {
        failSummary = false;
        throw new Error("temporary summary failure");
      }
      return { code: 0, data: { card_id: "card_status" } };
    };
    await session.start("oc_group", "chat_id", { urajStatusOnly: statusOnly });
    const card = JSON.parse(requests[0].body.data);
    assert.equal(card.config.streaming_mode, !statusOnly);
    assert.equal(card.body.elements[0].text_size, "heading");
    assert.equal(card.body.padding, "8px 12px 8px 12px");
    assert.equal(card.config.summary.content, statusOnly ? "正在处理" : "[Generating...]");
    await session.update("正在等待模型响应…");
    now += 615000;
    failSummary = statusOnly;
    await session.update("正在执行任务…\n\n已用时 10 分 15 秒");
    assert.equal(session.state.sentText, "正在执行任务…\n\n已用时 10 分 15 秒");
    // A failed summary does not fail the body; the next heartbeat retries it.
    for (const seconds of [30, 45]) {
      now += 15000;
      await session.update(`正在执行任务…\n\n已用时 10 分 ${seconds} 秒`);
    }
    const updates = requests.filter(r => r.method === "PUT");
    assert.equal(updates.length, 4);
    for (const request of updates) {
      assert.equal(request.path, statusOnly ? "/card_status/elements/content" : "/card_status/elements/content/content");
      if (statusOnly) assert.equal(JSON.parse(request.body.element).text_size, "heading");
    }
    const summaries = requests.filter(r => r.operation === "status-summary");
    assert.deepEqual(summaries.map(r => JSON.parse(r.body.settings).config.summary.content),
      statusOnly ? ["正在等待模型响应…", "正在执行任务…", "正在执行任务…"] : []);
    // Failed deletion must still blank the status via the non-streaming API.
    await session.discard();
    const cleared = requests.filter(r => r.method === "PUT").at(-1);
    assert.equal(cleared.path, "/card_status/elements/content");
    assert.equal(JSON.parse(cleared.body.element).content, "");
    assert.equal(JSON.parse(requests.at(-1).body.settings).config.summary.content, "");
    const sequences = requests.slice(1).map(r => r.body.sequence);
    assert.equal(new Set(sequences).size, sequences.length);
    assert.deepEqual(sequences, [...sequences].sort((a, b) => a - b));
    assert.equal(session.isActive(), false);
    assert.equal(errors.filter(e => /failed/i.test(e)).length, statusOnly ? 2 : 1);
  });
}

test("status strings cannot contain tool arguments, names, prose or hidden events", () => {
  assert.equal(urajFeishuToolStatus({ kind: "tool", name: "read" }), "正在查阅资料…");
  assert.equal(urajFeishuToolStatus({ kind: "tool", name: "exec" }), "正在执行任务…");
  assert.equal(urajFeishuToolStatus({ kind: "tool", phase: "end" }), "正在继续处理…");
  for (const kind of ["preamble", "reasoning", "plan", "unknown", undefined]) {
    assert.equal(urajFeishuToolStatus({ kind, text: "SECRET" }), "");
  }
  for (const flag of ["hideFromChannelProgress", "suppressChannelProgress"]) {
    assert.equal(urajFeishuToolStatus({ kind: "tool", [flag]: true }), "");
  }
  assert.equal(urajFeishuToolStatus({ kind: "tool", name: "SECRET", text: "SECRET",
    label: "SECRET", args: { command: "SECRET" }, output: "SECRET" }), "正在使用工具…");
});

for (const hook of ["reply_payload_sending", "message_sending"]) {
  test(`${hook}: fixed progress reuses one card, accepted final uses a separate answer card`, async () => {
    const h = harness({ hooks: [hook] });
    assert.equal(h.replyOptions.onPartialReply, undefined);
    assert.equal(h.replyOptions.onReasoningStream, undefined);
    assert.equal(h.replyOptions.disableBlockStreaming, true);
    await h.dispatcherOptions.onReplyStart();
    const bridge = progressBridge(h.replyOptions);
    await bridge.forwardItemEvent({ kind: "tool", name: "exec", text: "SECRET" });
    await bridge.wrapProgressCallback(h.replyOptions.onCompactionStart,
      { requiresToolSummaryVisibility: true })();
    h.replyOptions.onCompactionEnd();
    h.replyOptions.onAssistantMessageStart();
    await tick();
    assert.equal(h.calls.starts.length, 1);
    assert.equal(h.calls.starts[0].options.replyToMessageId, "om_topic");
    assert.equal(h.calls.starts[0].options.replyInThread, true);
    assert.equal(h.calls.starts[0].options.urajStatusOnly, true);
    assert.equal(h.calls.starts[0].options.note, undefined);
    assert.match(h.calls.updates.join("\n"), /正在执行任务/);
    assert.match(h.calls.updates.join("\n"), /正在压缩上下文/);
    assert.doesNotMatch(JSON.stringify(h.calls), /SECRET|PRIVATE_IDENTITY/);
    const final = "我目前是「家庭助手 · 共享」。\n\n已检查的答案";
    assert.equal((await finalize(h, final)).visibleReplySent, true);
    assert.equal(h.calls.closes.length, 0);
    assert.equal(h.calls.discards, 1);
    assert.equal(h.calls.static.length, 1);
    assert.equal(h.calls.static[0].kind, "card");
    assert.equal(h.calls.static[0].text, final);
    assert.equal(h.calls.static[0].replyToMessageId, "om_topic");
    assert.equal(h.timers.size, 0);
    h.replyOptions.onItemEvent({ kind: "tool" });
    h.replyOptions.onCompactionStart();
    await tick();
    assert.equal(h.calls.starts.length, 1, "late callbacks must not resurrect the status card");
  });
}

for (const reason of ["cancelled_by_reply_payload_sending_hook", "empty_after_reply_payload_sending_hook",
  "cancelled_by_message_sending_hook", "empty_after_message_sending_hook", "silent"]) {
  test(`${reason}: discard status and preserve intentional silence`, async () => {
    const h = harness();
    await h.dispatcherOptions.onReplyStart();
    if (reason === "silent") h.dispatcherOptions.onSkip({}, { kind: "final", reason });
    else h.delivery.onDelivered({}, { kind: "final" }, { suppression: { reason } });
    await h.dispatcherOptions.onIdle();
    assert.equal(h.calls.discards, 1);
    assert.equal(h.calls.closes.length, 0);
    assert.equal(await h.ensureNoVisibleReplyFallback("test"), false);
    assert.equal(h.calls.static.length, 0);
  });
}

test("answer footer uses the actual selected model and effort, including fallback", async () => {
  const h = harness();
  h.replyOptions.onModelSelected({ provider: "primary", model: "gpt-6-astra", thinkLevel: "xhigh" });
  await h.dispatcherOptions.onReplyStart();
  h.replyOptions.onModelSelected({ provider: "fallback", model: "gpt-6-luna", thinkLevel: "low" });
  await tick();
  assert.doesNotMatch(JSON.stringify(h.calls), /gpt-6|Effort|PRIVATE_IDENTITY/);
  await finalize(h, "accepted answer");
  assert.match(h.calls.static[0].note, /Model: gpt-6-luna \| Effort: low \| Provider: fallback/);
  assert.doesNotMatch(h.calls.static[0].note, /astra|xhigh/);
});

test("unknown model/effort is omitted; a resolved off effort is shown", async () => {
  const unknown = harness();
  await finalize(unknown, "command reply");
  assert.doesNotMatch(unknown.calls.static[0].note, /Model:|Effort:/);
  const off = harness();
  off.replyOptions.onModelSelected({ provider: "test", model: "test-model", thinkLevel: "off" });
  await finalize(off, "answer");
  assert.match(off.calls.static[0].note, /Effort: off/);
});

test("cancel waits for an in-flight card start, then discards it", async () => {
  const gate = Promise.withResolvers();
  const h = harness({ startGate: gate.promise });
  await h.dispatcherOptions.onReplyStart();
  const idle = h.dispatcherOptions.onIdle();
  gate.resolve();
  await idle;
  assert.equal(h.calls.discards, 1);
  assert.equal(h.calls.closes.length, 0);
});

test("errors clean status without treating it as an answer", async () => {
  const h = harness();
  await h.dispatcherOptions.onReplyStart();
  await h.delivery.onError(new Error("model failed"), { kind: "final" });
  assert.equal(h.calls.discards, 1);
  assert.equal(await h.ensureNoVisibleReplyFallback("error"), true);
  assert.equal(h.calls.static.length, 1);
});

test("cleanup failures propagate without revealing persona metadata", async () => {
  const h = harness({ discardError: new Error("provider unavailable") });
  await h.dispatcherOptions.onReplyStart();
  await assert.rejects(h.dispatcherOptions.onIdle(), /provider unavailable/);
  assert.equal(h.calls.closes.length, 0);
  assert.equal(h.timers.size, 0);
  assert.doesNotMatch(JSON.stringify(h.calls), /PRIVATE_IDENTITY/);
});

test("CardKit start failure falls back to one accepted static reply", async () => {
  const h = harness({ startError: new Error("CardKit unavailable") });
  await h.dispatcherOptions.onReplyStart();
  await tick();
  const result = await finalize(h, "已检查的答案");
  assert.equal(result.visibleReplySent, true);
  assert.equal(h.calls.static.length, 1);
  assert.equal(h.calls.static[0].text, "已检查的答案");
});

test("long answers discard status and use upstream static delivery", async () => {
  const h = harness();
  await h.dispatcherOptions.onReplyStart();
  const text = "答案".repeat(2100);
  assert.equal((await finalize(h, text)).visibleReplySent, true);
  assert.equal(h.calls.discards, 1);
  assert.equal(h.calls.static[0].text, text);
});

test("status cleanup failure cannot prevent delivery of an accepted long answer", async () => {
  const h = harness({ discardError: new Error("CardKit cleanup failed") });
  await h.dispatcherOptions.onReplyStart();
  const text = "accepted answer".repeat(1000);
  const result = await h.delivery.deliver({ text }, { kind: "final" });
  assert.equal(result.visibleReplySent, true);
  assert.equal(result.finalization, undefined);
  await assert.rejects(h.dispatcherOptions.onIdle(), /CardKit cleanup failed/);
  assert.equal(h.calls.static.length, 1);
  assert.equal(h.calls.static[0].text, text);
  assert.equal(h.calls.static[0].kind, "card");
  assert.equal(await h.ensureNoVisibleReplyFallback("cleanup failed"), false);
  assert.equal(h.timers.size, 0);
});

test("failed answer card delivery is not reported as success and cleans up status", async () => {
  const h = harness({ sendError: new Error("card delivery failed") });
  await h.dispatcherOptions.onReplyStart();
  let failure;
  await assert.rejects(h.delivery.deliver({ text: "answer" }, { kind: "final" }), error => {
    failure = error;
    assert.equal(error.deliveryResult.visibleReplySent, false);
    return true;
  });
  await h.delivery.onError(failure, { kind: "final" });
  assert.equal(h.calls.static.length, 0);
  assert.equal(h.calls.discards, 1);
  assert.equal(h.timers.size, 0);
});

test("concurrent dispatchers keep card status and final answers separate", async () => {
  const first = harness();
  const second = harness();
  await Promise.all([first.dispatcherOptions.onReplyStart(), second.dispatcherOptions.onReplyStart()]);
  first.replyOptions.onCompactionStart();
  second.replyOptions.onItemEvent({ kind: "tool", name: "read" });
  await Promise.all([finalize(first, "first answer"), finalize(second, "second answer")]);
  assert.equal(first.calls.static[0].text, "first answer");
  assert.equal(second.calls.static[0].text, "second answer");
  assert.doesNotMatch(first.calls.updates.join("\n"), /正在查阅资料|second answer/);
  assert.doesNotMatch(second.calls.updates.join("\n"), /正在压缩上下文|first answer/);
});

for (const options of [{ mode: "off" }, { renderMode: "raw" }, { requiredMentionTargets: [{}] }]) {
  test(`disabled streaming remains disabled: ${JSON.stringify(options)}`, async () => {
    const h = harness(options);
    await h.dispatcherOptions.onReplyStart();
    assert.equal(h.replyOptions.onItemEvent, undefined);
    assert.equal(h.replyOptions.onCompactionStart, undefined);
    assert.equal(h.calls.starts.length, 0);
    assert.equal((await finalize(h, "普通答案")).visibleReplySent, true);
    assert.equal(h.calls.static[0].kind, options.renderMode === "raw" ? "post" : "card");
  });
}

test("without modifying hooks, upstream text and reasoning previews still work", async () => {
  const h = harness({ hooks: [] });
  await h.dispatcherOptions.onReplyStart();
  h.replyOptions.onPartialReply({ text: "partial answer" });
  h.replyOptions.onReasoningStream({ text: "thinking" });
  await tick();
  assert.match(h.calls.updates.join("\n"), /partial answer/);
  assert.match(h.calls.updates.join("\n"), /thinking/);
  await h.dispatcherOptions.onIdle();
  assert.equal(h.calls.discards, 0);
});

test("real persona hook still controls welcome receipt and cancels a changed private group", async t => {
  const directory = await fs.mkdtemp(path.join(os.tmpdir(), "feishu-persona-progress-"));
  t.after(() => fs.rm(directory, { recursive: true, force: true }));
  let alone = true;
  const store = new PersonaStore(directory);
  const personas = new Personas({ store, feishu: { alone: async () => alone, notify: async () => {} } });
  await store.transact(s => {
    s.roles[SHARED] = { id: SHARED, name: "家庭助手", visibility: "shared" };
    s.groups.oc_group = { role: SHARED, revision: 1, announced: false };
  });
  const ctx = { channelId: "feishu", accountId: "main", conversationId: "oc_group" };
  const event = { channel: "feishu", runId: "run", kind: "final",
    usageState: { agentId: SHARED }, payload: { text: "answer" } };
  const h = harness();
  await h.dispatcherOptions.onReplyStart();
  const accepted = await personas.sending(event, ctx);
  assert.match(accepted.payload.text, /家庭助手 · 共享/);
  assert.equal(urajFeishuCardSummary(accepted.payload.text), "answer");
  assert.equal((await store.read()).groups.oc_group.announced, false);
  const receipt = await finalize(h, accepted.payload.text);
  await personas.sent({ success: receipt.visibleReplySent, content: receipt.content }, ctx);
  assert.equal((await store.read()).groups.oc_group.announced, true);

  await store.transact(s => {
    s.roles[SHARED].visibility = "private";
    s.roles[SHARED].owner = "ou_alice";
  });
  personas.runs.set("run", { role: SHARED, chat: "oc_group", revision: 1 });
  const privateTurn = harness();
  await privateTurn.dispatcherOptions.onReplyStart();
  alone = false;
  assert.equal((await personas.sending(event, ctx)).cancel, true);
  privateTurn.delivery.onDelivered({}, { kind: "final" },
    { suppression: { reason: "cancelled_by_reply_payload_sending_hook" } });
  await privateTurn.dispatcherOptions.onIdle();
  assert.equal(privateTurn.calls.discards, 1);
  assert.equal(privateTurn.calls.closes.length, 0);
  assert.equal(privateTurn.calls.static.length, 0);
});

test("layout drift, duplicate patches and missing bundles fail before writing any file", async t => {
  assert.equal(patchFeishuGuardedProgress("unrelated code"), null);
  assert.throws(() => patchFeishuGuardedProgress(patched), /already patched/);
  const root = await fs.mkdtemp(path.join(os.tmpdir(), "feishu-progress-layout-"));
  t.after(() => fs.rm(root, { recursive: true, force: true }));
  assert.throws(() => patchDirectory(root), /not found/);
  const bundle = originalSession + original;
  await fs.writeFile(path.join(root, "runtime.mjs"), bundle);
  await fs.writeFile(path.join(root, "setup.mjs"), bundle.replace("onCompactionEnd:", "changedCallback:"));
  assert.throws(() => patchDirectory(root), /Unexpected Feishu dispatcher layout/);
  assert.equal(await fs.readFile(path.join(root, "runtime.mjs"), "utf8"), bundle);
  await fs.writeFile(path.join(root, "setup.mjs"), bundle.replace("streaming_mode: true,", "layout changed"));
  assert.throws(() => patchDirectory(root), /Unexpected Feishu streaming session layout/);
  assert.equal(await fs.readFile(path.join(root, "runtime.mjs"), "utf8"), bundle);
});

test("target image bundles match the pinned dispatcher and accept the patch", {
  skip: !process.env.FEISHU_DIST,
}, async () => {
  let count = 0;
  for (const file of await fs.readdir(process.env.FEISHU_DIST, { recursive: true })) {
    if (!file.endsWith(".mjs")) continue;
    const source = await fs.readFile(path.join(process.env.FEISHU_DIST, file), "utf8");
    if (patchFeishuGuardedProgress(source) === null) continue;
    patchFeishuStatusSession(source);
    const sessionStart = source.indexOf("var FeishuStreamingSession = class {");
    const sessionEnd = source.indexOf("\n};", sessionStart) + 4;
    assert.ok(originalSession.includes(source.slice(sessionStart, sessionEnd)), file);
    const start = source.indexOf("function createFeishuReplyDispatcher(params) {");
    const end = source.indexOf("\n//#endregion", start);
    // The setup bundle imports the SDK export under its public name.
    const dispatcher = source.slice(start, end)
      .replace("createChannelMessageReplyPipeline(", "createChannelReplyPipeline(");
    assert.ok(original.includes(dispatcher), file);
    count++;
  }
  assert.ok(count > 0);
});
