// v2026.10.3 disables all CardKit previews when a modifying send hook exists.
// Keep that guard for model text, reasoning and tool details. Only fixed status
// strings may precede the hooks. Status uses a non-streaming CardKit card so
// long model/tool waits do not hit Feishu's streaming timeout; accepted answers
// use upstream static card delivery, receipts and chunking. The separate card
// style patch sets readable text sizes and the final model/effort footer.
import { readdirSync, readFileSync, writeFileSync } from "node:fs";
import { join, resolve } from "node:path";
import { pathToFileURL } from "node:url";

export function urajFeishuToolStatus(payload) {
  if (payload.kind !== "tool" || payload.hideFromChannelProgress ||
      payload.suppressChannelProgress) return "";
  if (payload.phase === "end") return "正在继续处理…";
  // Never interpolate model-authored labels, arguments, output or tool names.
  switch (payload.name) {
    case "read": case "memory_search": case "memory_get":
      return "正在查阅资料…";
    case "web_fetch": return "正在读取网页…";
    case "exec": case "process": return "正在执行任务…";
    case "write": case "edit": case "apply_patch": return "正在整理文件…";
    default: return "正在使用工具…";
  }
}

export function createUrajFeishuProgress(update, clock = globalThis) {
  let startedAt;
  let changedAt;
  let status = "正在等待模型响应…";
  let timer;
  let stopped = false;
  const duration = ms => {
    const seconds = Math.max(0, Math.floor(ms / 1000));
    return seconds < 60 ? `${seconds} 秒` : `${Math.floor(seconds / 60)} 分 ${seconds % 60} 秒`;
  };
  const render = () => {
    if (stopped) return false;
    const now = clock.Date.now();
    return update(`${status}\n\n已用时 ${duration(now - startedAt)} · 距上次进展 ${duration(now - changedAt)}`);
  };
  return {
    update(nextStatus) {
      if (stopped) return false;
      const now = clock.Date.now();
      if (startedAt === undefined) {
        startedAt = now;
        timer = clock.setInterval(render, 15000);
        timer.unref?.();
      }
      changedAt = now;
      if (nextStatus) status = nextStatus;
      return render();
    },
    stop() {
      stopped = true;
      if (timer !== undefined) clock.clearInterval(timer);
    },
  };
}

const dispatcher = "function createFeishuReplyDispatcher(params) {";

export function patchFeishuGuardedProgress(source) {
  if (!source.includes(dispatcher)) return null;
  if (source.includes("urajGuardedStatus")) throw new Error("Feishu guarded progress already patched");
  const start = source.indexOf(dispatcher);
  const end = source.indexOf("\n//#endregion", start);
  if (end < 0 || source.split(dispatcher).length !== 2) throw new Error("Unexpected Feishu dispatcher boundary");
  const prefix = source.slice(0, start);
  const suffix = source.slice(end);
  source = source.slice(start, end);
  const replacements = [
    [dispatcher, urajFeishuToolStatus.toString() + "\n" + createUrajFeishuProgress.toString() + "\n" + dispatcher],
    ["const previewStreamingEnabled = streamingEnabled && !modifyingHooksRegistered;",
      "const previewStreamingEnabled = streamingEnabled && !modifyingHooksRegistered;\n" +
      "\tconst urajGuardedStatus = streamingEnabled && modifyingHooksRegistered;\n" +
      "\tconst urajProgress = createUrajFeishuProgress(text => updateStreamingStatusLine(text));"],
    ["const cardHeader = resolveCardHeader(agentId, identity);",
      'const cardHeader = urajGuardedStatus ? { title: "OpenClaw", template: "blue" } : resolveCardHeader(agentId, identity);'],
    ["const cardNote = resolveCardNote(agentId, identity, responsePrefixContextProvider());",
      'const cardNote = urajGuardedStatus ? void 0 : resolveCardNote(agentId, identity, responsePrefixContextProvider());'],
    ["note: cardNote", "note: cardNote,\n\t\t\t\t\turajStatusOnly: urajGuardedStatus"],
    ['const closeStreaming = (disposition = "closed") => {',
      'const closeStreaming = (disposition = "closed") => {\n' +
      // Empty status cards must not count as delivered answers or disclose the
      // persona via the final note after cancellation, silence or an error.
      '\t\tif (urajGuardedStatus) { urajProgress.stop(); disposition = "discarded"; }'],
    ["const updateStreamingStatusLine = (nextStatusLine, options) => {",
      "const updateStreamingStatusLine = (nextStatusLine, options) => {\n" +
      "\t\tif (urajGuardedStatus && (idleRequestedForReply || hasStreamingFinalText)) return false;"],
    ['if (previewStreamingEnabled && renderMode === "card") startStreaming();',
      'if (urajGuardedStatus && renderMode === "card") urajProgress.update();\n' +
      '\t\t\telse if (previewStreamingEnabled && renderMode === "card") startStreaming();'],
    ["onCleanup: () => {", "onCleanup: () => {\n\t\t\turajProgress.stop();"],
    ["deliver: async (inputPayload, info) => {",
      'deliver: async (inputPayload, info) => {\n\t\t\t\tif (urajGuardedStatus && info?.kind === "final") urajProgress.stop();'],
    ["const useStreamingCard = hasText &&", "const useStreamingCard = !modifyingHooksRegistered && hasText &&"],
    ['const shouldStreamText = info?.kind === "block" || info?.kind === "final";',
      'const shouldStreamText = !modifyingHooksRegistered && (info?.kind === "block" || info?.kind === "final");'],
    ["if (shouldDiscardStreamingPreview) await discardStreamingPreview();",
      "if (!urajGuardedStatus && shouldDiscardStreamingPreview) await discardStreamingPreview();"],
    // This option lets the core forward item/compaction events with verbose off.
    // Our callback emits fixed labels only; it never sends the tool summary.
    ["replyOptions: {\n\t\t\tonModelSelected,",
      "replyOptions: {\n\t\t\tonModelSelected,\n\t\t\tsuppressDefaultToolProgressMessages: urajGuardedStatus || void 0,"],
    ["onItemEvent: previewStreamingEnabled ? (payload) => {",
      "onItemEvent: (previewStreamingEnabled || urajGuardedStatus) ? (payload) => {\n" +
      "\t\t\t\tif (urajGuardedStatus) {\n" +
      "\t\t\t\t\tconst status = urajFeishuToolStatus(payload);\n" +
      "\t\t\t\t\treturn status ? urajProgress.update(status) : false;\n" +
      "\t\t\t\t}"],
    ['onAssistantMessageStart: previewStreamingEnabled ? () => updateStreamingStatusLine("", { startIfNeeded: false }) : void 0,',
      'onAssistantMessageStart: urajGuardedStatus ? () => urajProgress.update("正在生成回复…") : previewStreamingEnabled ? () => updateStreamingStatusLine("", { startIfNeeded: false }) : void 0,'],
    ['onCompactionStart: previewStreamingEnabled ? () => updateStreamingStatusLine("📦 **Compacting context...**") : void 0,',
      'onCompactionStart: urajGuardedStatus ? () => urajProgress.update("正在压缩上下文…") : previewStreamingEnabled ? () => updateStreamingStatusLine("📦 **Compacting context...**") : void 0,'],
    ['onCompactionEnd: previewStreamingEnabled ? () => updateStreamingStatusLine("") : void 0',
      'onCompactionEnd: urajGuardedStatus ? () => urajProgress.update("正在继续处理…") : previewStreamingEnabled ? () => updateStreamingStatusLine("") : void 0'],
  ];
  // Check every anchor before writing, including both runtime and setup bundles.
  for (const [before] of replacements) {
    if (source.split(before).length !== 2) {
      throw new Error(`Unexpected Feishu dispatcher layout: ${before}`);
    }
  }
  for (const [before, after] of replacements) source = source.replace(before, after);
  return prefix + source + suffix;
}

export function patchFeishuStatusSession(source) {
  const start = source.indexOf("var FeishuStreamingSession = class {");
  const end = source.indexOf("\n};", start) + 4;
  if (start < 0 || end < start) throw new Error("Unexpected Feishu streaming session boundary");
  const prefix = source.slice(0, start);
  const suffix = source.slice(end);
  source = source.slice(start, end);
  const replacements = [
    ["streaming_mode: true,", "streaming_mode: options?.urajStatusOnly !== true,"],
    ['summary: { content: "[Generating...]" },',
      'summary: { content: options?.urajStatusOnly ? "正在处理" : "[Generating...]" },'],
    ["hasNote: Boolean(options?.note)",
      "hasNote: Boolean(options?.note),\n\t\t\turajStatusOnly: options?.urajStatusOnly === true"],
    ["this.writeCardContent(nextText, false,", "this.writeCardContent(nextText, this.state.urajStatusOnly === true,"],
    // Clearing a status card after a failed delete must also use element
    // replacement, not the streaming-only content endpoint.
    ["const replace = !text.startsWith(this.state.sentText);",
      "const replace = this.state.urajStatusOnly === true || !text.startsWith(this.state.sentText);"],
  ];
  for (const [before] of replacements) {
    if (source.split(before).length !== 2) {
      throw new Error(`Unexpected Feishu streaming session layout: ${before}`);
    }
  }
  for (const [before, after] of replacements) source = source.replace(before, after);
  return prefix + source + suffix;
}

function* files(directory) {
  for (const entry of readdirSync(directory, { withFileTypes: true })) {
    const path = join(directory, entry.name);
    if (entry.isDirectory()) yield* files(path);
    else if (entry.name.endsWith(".mjs")) yield path;
  }
}

export function patchDirectory(root) {
  const updates = [];
  for (const path of files(root)) {
    const patched = patchFeishuGuardedProgress(readFileSync(path, "utf8"));
    if (patched !== null) updates.push([path, patchFeishuStatusSession(patched)]);
  }
  if (!updates.length) throw new Error("Feishu reply dispatcher not found");
  for (const [path, patched] of updates) writeFileSync(path, patched);
  return updates.length;
}

if (process.argv[1] && import.meta.url === pathToFileURL(resolve(process.argv[1])).href) {
  console.log(`patched ${patchDirectory(process.argv[2] ?? "/app/dist")} Feishu progress bundle(s)`);
}
