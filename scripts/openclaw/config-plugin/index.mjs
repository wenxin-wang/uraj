// Convenience routing, not a shell security boundary. No shell is evaluated here.
const refusal = {
  block: true,
  blockReason: "Use a standalone openclaw config set <path> <value> command " +
    "(optionally --strict-json or --json). Pipelines, redirects, environment " +
    "assignments, expansion, batch and other flags cannot be forwarded. " +
    "Quote JSON values and bracketed paths. JSON5 is not supported; use JSON.",
};

export function shellWords(command) {
  if (/[\r\n\0]/.test(command)) throw new Error("Not a single command");
  const words = [];
  let word = "", quote = "", started = false;
  for (let i = 0; i < command.length; i++) {
    const char = command[i];
    if (quote === "'") {
      if (char === "'") quote = "";
      else word += char;
    } else if (char === "\\") {
      const next = command[++i];
      if (next === undefined) throw new Error("Trailing escape");
      // POSIX double quotes retain backslashes except before these characters.
      if (quote === '"' && !['$', '`', '"', '\\'].includes(next)) word += "\\";
      word += next;
      started = true;
    } else if (quote === '"') {
      if (char === '"') quote = "";
      else if (char === "$" || char === "`") throw new Error("Expansion");
      else word += char;
    } else if (char === "'" || char === '"') {
      quote = char;
      started = true;
    } else if (/\s/.test(char)) {
      if (started) words.push(word);
      word = "";
      started = false;
    } else {
      if (/[;&|<>()$`*?\[\]{}~#]/.test(char)) throw new Error("Shell syntax");
      word += char;
      started = true;
    }
  }
  if (quote) throw new Error("Unclosed quote");
  if (started) words.push(word);
  return words;
}

const shellQuote = (value) => "'" + value.replaceAll("'", "'\\''") + "'";

export function routeConfigSet(event) {
  if (event.toolName !== "exec" || event.toolKind === "code_mode_exec" ||
      event.toolInputKind === "javascript" || typeof event.params?.command !== "string") {
    return;
  }
  const command = event.params.command;
  // A failed parse is blocked only if it looks like the operation we own.
  // Indirect scripts/obfuscated commands remain outside this convenience hook.
  const resemblesSet = /openclaw[\s\S]*\bconfig\s+set\b/.test(command);
  let words;
  try { words = shellWords(command); } catch {
    return resemblesSet ? { ...refusal } : undefined;
  }
  const offset = words[0] === "openclaw" ? 1 :
    words[0] === "node" && ["openclaw.mjs", "/app/openclaw.mjs"].includes(words[1]) ? 2 : 0;
  if (!offset || words[offset] !== "config" || words[offset + 1] !== "set") {
    return resemblesSet ? { ...refusal } : undefined;
  }
  const args = words.slice(offset + 2);
  let strict = false;
  const positional = [];
  for (const arg of args) {
    if (arg === "--strict-json" || arg === "--json") strict = true;
    else if (arg.startsWith("--")) return { ...refusal };
    else positional.push(arg);
  }
  if (positional.length !== 2) return { ...refusal };
  const [key, raw] = positional;
  let value;
  try { value = JSON.parse(raw); } catch {
    // Preserve the native CLI's common bare-string form, but do not silently
    // reinterpret JSON5 objects/arrays as strings.
    if (strict || /^[\s]*[\[{]/.test(raw)) return { ...refusal };
    value = raw;
  }
  const rewritten = ["node", "/etc/openclaw/config.mjs", "set", key,
    JSON.stringify(value)].map(shellQuote).join(" ");
  return { params: { ...event.params, command: rewritten } };
}

export default {
  id: "uraj-config-policy",
  name: "Guix checked configuration",
  register(api) {
    api.on("before_tool_call", routeConfigSet, { matcher: ["exec"], priority: 100 });
  },
};
