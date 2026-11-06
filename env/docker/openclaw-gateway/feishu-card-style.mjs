// Styling for OpenClaw-generated Feishu cards in v2026.10.3. Explicit native
// cards keep their own layout. Apply after feishu-guarded-progress.mjs.
import { readdirSync, readFileSync, writeFileSync } from "node:fs";
import { join, resolve } from "node:path";
import { pathToFileURL } from "node:url";

// Preview only the accepted body, without our exact first-reply persona banner
// or card metadata. Keep the original body and delivery receipts untouched.
export function urajFeishuCardSummary(text) {
  const plain = text.trim()
    .replace(/<at\b[^>]*>[\s\S]*?<\/at>/giu, "").trim()
    .replace(/^我目前是「[^\r\n]+」(?:，(?:不使用私人角色的记忆|使用你的私人身份和记忆)。\r?\n可以继续聊，或用 \/persona 选择／创建角色。|。用 \/persona 可以选择／创建角色。)\r?\n\r?\n/u, "")
    .replace(/^ {0,3}(?:`{3,}|~{3,})[^\r\n]*$/gm, "")
    .replace(/!?\[([^\]\r\n]*)\]\([^\r\n)]*\)/g, "$1")
    .replace(/<\/?(?:font|text_tag|b|i|u|s)\b[^>]*>/giu, "")
    .replace(/^\s{0,3}(?:#{1,6}\s+|>\s*|[-+*]\s+|\d+[.)]\s+)/gm, "")
    .replace(/(\*\*|__|~~)([\s\S]*?)\1/g, "$2")
    .replace(/([*_])([^\s*_][^*_]*?)\1/g, "$2")
    .replace(/`+([^`]+?)`+/g, "$1")
    .replace(/\\([\\`*_{}\[\]()#+.!>|~-])/g, "$1")
    .replace(/&(amp|lt|gt|quot|apos|nbsp);/g, (_, entity) => ({
      amp: "&", lt: "<", gt: ">", quot: '"', apos: "'", nbsp: " ",
    })[entity])
    .replace(/\s+/g, " ").trim();
  const characters = Array.from(plain);
  return characters.length > 80 ? characters.slice(0, 79).join("") + "…" : plain;
}

// Feishu's "heading" text-size enum is 16px on both desktop and mobile; it
// changes the font size, not the Markdown structure or font weight.
// https://open.feishu.cn/document/feishu-cards/card-json-v2-components/content-components/rich-text
export function urajStyleFeishuCard(card) {
  card.body.padding = "8px 12px 8px 12px";
  card.body.vertical_spacing = "4px";
  if (card.header) card.header.padding = "8px 12px 8px 12px";
  for (const element of card.body.elements) {
    if (element.tag === "markdown") element.text_size ??= "heading";
  }
  card.config.summary ??= { content: urajFeishuCardSummary(card.body.elements
    .filter(element => element.tag === "markdown" && element.text_size !== "normal")
    .map(element => element.content).join("\n\n")) || "卡片消息" };
  return card;
}

function replaceOnce(source, before, after) {
  if (source.split(before).length !== 2) {
    throw new Error(`Unexpected Feishu card layout: ${before}`);
  }
  return source.replace(before, after);
}

function patchFunction(source, declaration, replacements) {
  const start = source.indexOf(declaration);
  const end = source.indexOf("\n}", start);
  if (start < 0 || end < 0 || source.split(declaration).length !== 2) {
    throw new Error(`Unexpected Feishu card function: ${declaration}`);
  }
  let body = source.slice(start, end + 2);
  for (const [before, after] of replacements) body = replaceOnce(body, before, after);
  return source.slice(0, start) + body + source.slice(end + 2);
}

export function patchFeishuCardStyle(source) {
  const session = "var FeishuStreamingSession = class {";
  const structured = "function buildStructuredCard(text, options) {";
  if (!source.includes(session) && !source.includes(structured)) return null;
  if (source.includes("urajStyleFeishuCard")) throw new Error("Feishu card style already patched");
  if (source.includes(session)) {
    source = patchFunction(source, "function resolveCardHeader(agentId, identity) {", [
      ['const name = identity?.name?.trim() || (agentId === "main" ? "" : agentId);',
        'const rawName = identity?.name?.trim() || (agentId === "main" ? "" : agentId);\n' +
        '\tconst name = rawName === "household-shared" ? "共享助手" : rawName;'],
    ]);
    source = patchFunction(source, "function resolveCardNote(agentId, identity, prefixCtx) {", [
      ['if (prefixCtx.model) parts.push(`Model: ${prefixCtx.model}`);',
        'if (prefixCtx.model) parts.push(`Model: ${prefixCtx.model}`);\n' +
        '\tif (prefixCtx.thinkingLevel) parts.push(`Effort: ${prefixCtx.thinkingLevel}`);'],
    ]);
    // Both initial creation and subsequent element replacements need the size.
    const contentId = 'element_id: "content"';
    if (source.split(contentId).length !== 3) throw new Error("Unexpected Feishu content elements");
    source = source.replaceAll(contentId, contentId + ',\n\t\t\ttext_size: "heading"');
    source = replaceOnce(source, 'element_id: "note"', 'element_id: "note",\n\t\t\t\ttext_size: "normal"');
    source = replaceOnce(source, "data: JSON.stringify(cardJson)", "data: JSON.stringify(urajStyleFeishuCard(cardJson))");
    source = replaceOnce(source, "summary: { content: truncateSummary(acceptedText) }",
      "summary: { content: urajFeishuCardSummary(acceptedText) }");
  }
  if (source.includes(structured)) {
    source = patchFunction(source, structured, [
      ["content: `<font color='grey'>${options.note}</font>`",
        "content: `<font color='grey'>${options.note}</font>`,\n\t\t\ttext_size: \"normal\""],
      ["return card;", "return urajStyleFeishuCard(card);"],
    ]);
    source = patchFunction(source, "function buildFeishuCardElementsForBlock(block) {", [
      ['tag: "markdown",', 'tag: "markdown",\n\t\ttext_size: block.type === "context" ? "normal" : "heading",'],
    ]);
    source = patchFunction(source, "function buildFeishuPresentationCard(params) {", [
      ['return {\n\t\tschema: "2.0",', 'return urajStyleFeishuCard({\n\t\tschema: "2.0",'],
      ['body: { elements: buildFeishuPresentationCardElements(params) }\n\t};',
        'body: { elements: buildFeishuPresentationCardElements(params) }\n\t});'],
    ]);
  }
  const anchor = source.includes(session) ? session : structured;
  return source.replace(anchor, urajFeishuCardSummary.toString() + "\n" + urajStyleFeishuCard.toString() + "\n" + anchor);
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
    const patched = patchFeishuCardStyle(readFileSync(path, "utf8"));
    if (patched !== null) updates.push([path, patched]);
  }
  // v2026.10.3 ships a dispatcher/session and a shared card renderer for each
  // of runtime and setup. Fail before writing if an upgrade moves any of them.
  if (updates.length !== 4) throw new Error(`Expected 4 Feishu card bundles, found ${updates.length}`);
  for (const [path, patched] of updates) writeFileSync(path, patched);
  return updates.length;
}

if (process.argv[1] && import.meta.url === pathToFileURL(resolve(process.argv[1])).href) {
  console.log(`styled ${patchDirectory(process.argv[2] ?? "/app/dist")} Feishu card bundle(s)`);
}
