// v2026.10.3 disables all CardKit previews when a modifying send hook exists.
// Keep that guard for model text, reasoning and tool details. Only fixed status
// strings may precede the hooks; accepted payloads still use upstream delivery,
// finalization, receipts and fallback. No second message/timer implementation.
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

const dispatcher = "function createFeishuReplyDispatcher(params) {";

export function patchFeishuGuardedProgress(source) {
  if (!source.includes(dispatcher)) return null;
  if (source.includes("urajGuardedStatus")) throw new Error("Feishu guarded progress already patched");
  const replacements = [
    [dispatcher, urajFeishuToolStatus.toString() + "\n" + dispatcher],
    ["const previewStreamingEnabled = streamingEnabled && !modifyingHooksRegistered;",
      "const previewStreamingEnabled = streamingEnabled && !modifyingHooksRegistered;\n" +
      "\tconst urajGuardedStatus = streamingEnabled && modifyingHooksRegistered;"],
    ["const cardHeader = resolveCardHeader(agentId, identity);",
      'const cardHeader = urajGuardedStatus ? { title: "OpenClaw", template: "blue" } : resolveCardHeader(agentId, identity);'],
    ["const cardNote = resolveCardNote(agentId, identity, responsePrefixContextProvider());",
      'const cardNote = urajGuardedStatus ? "正在处理…" : resolveCardNote(agentId, identity, responsePrefixContextProvider());'],
    ['const closeStreaming = (disposition = "closed") => {',
      'const closeStreaming = (disposition = "closed") => {\n' +
      // Empty status cards must not count as delivered answers or disclose the
      // persona via the final note after cancellation, silence or an error.
      '\t\tif (urajGuardedStatus && !streamText.trim()) disposition = "discarded";'],
    ["const updateStreamingStatusLine = (nextStatusLine, options) => {",
      "const updateStreamingStatusLine = (nextStatusLine, options) => {\n" +
      "\t\tif (urajGuardedStatus && (idleRequestedForReply || hasStreamingFinalText)) return false;"],
    ['if (previewStreamingEnabled && renderMode === "card") startStreaming();',
      'if (urajGuardedStatus && renderMode === "card") updateStreamingStatusLine("正在处理…");\n' +
      '\t\t\telse if (previewStreamingEnabled && renderMode === "card") startStreaming();'],
    ["onItemEvent: previewStreamingEnabled ? (payload) => {",
      "onItemEvent: (previewStreamingEnabled || urajGuardedStatus) ? (payload) => {\n" +
      "\t\t\t\tif (urajGuardedStatus) {\n" +
      "\t\t\t\t\tconst status = urajFeishuToolStatus(payload);\n" +
      "\t\t\t\t\treturn status ? updateStreamingStatusLine(status) : false;\n" +
      "\t\t\t\t}"],
    ['onAssistantMessageStart: previewStreamingEnabled ? () => updateStreamingStatusLine("", { startIfNeeded: false }) : void 0,',
      'onAssistantMessageStart: (previewStreamingEnabled || urajGuardedStatus) ? () => updateStreamingStatusLine(urajGuardedStatus ? "正在整理回复…" : "", { startIfNeeded: false }) : void 0,'],
    ['onCompactionStart: previewStreamingEnabled ? () => updateStreamingStatusLine("📦 **Compacting context...**") : void 0,',
      'onCompactionStart: (previewStreamingEnabled || urajGuardedStatus) ? () => updateStreamingStatusLine(urajGuardedStatus ? "正在压缩上下文…" : "📦 **Compacting context...**") : void 0,'],
    ['onCompactionEnd: previewStreamingEnabled ? () => updateStreamingStatusLine("") : void 0',
      'onCompactionEnd: (previewStreamingEnabled || urajGuardedStatus) ? () => updateStreamingStatusLine(urajGuardedStatus ? "正在继续处理…" : "", { startIfNeeded: false }) : void 0'],
  ];
  // Check every anchor before writing, including both runtime and setup bundles.
  for (const [before] of replacements) {
    if (source.split(before).length !== 2) {
      throw new Error(`Unexpected Feishu dispatcher layout: ${before}`);
    }
  }
  for (const [before, after] of replacements) source = source.replace(before, after);
  return source;
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
    if (patched !== null) updates.push([path, patched]);
  }
  if (!updates.length) throw new Error("Feishu reply dispatcher not found");
  for (const [path, patched] of updates) writeFileSync(path, patched);
  return updates.length;
}

if (process.argv[1] && import.meta.url === pathToFileURL(resolve(process.argv[1])).href) {
  console.log(`patched ${patchDirectory(process.argv[2] ?? "/app/dist")} Feishu progress bundle(s)`);
}
