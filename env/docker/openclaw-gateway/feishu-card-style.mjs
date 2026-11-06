// Styling for OpenClaw-generated Feishu cards in v2026.10.3. Explicit native
// cards keep their own layout. Apply after feishu-guarded-progress.mjs.
import { readdirSync, readFileSync, writeFileSync } from "node:fs";
import { join, resolve } from "node:path";
import { pathToFileURL } from "node:url";

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
  return source.replace(anchor, urajStyleFeishuCard.toString() + "\n" + anchor);
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
