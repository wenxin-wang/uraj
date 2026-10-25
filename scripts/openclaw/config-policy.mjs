// Shared by startup reconciliation and the checked config command.
import { isDeepStrictEqual } from "node:util";
import path from "node:path";

const mutableRoot = new Set(["agents", "bindings", "meta", "wizard"]);
const agentFields = new Set(["name", "identity", "model", "workspace", "agentDir"]);
const own = (value, key) => Object.hasOwn(value, key);

function disabledSkillAdditions(actual, expected) {
  const entries = actual?.entries;
  if (!entries || typeof entries !== "object" || Array.isArray(entries)) return [];
  return Object.entries(entries).filter(([key, entry]) =>
    !own(expected?.entries ?? {}, key) && isDeepStrictEqual(entry, { enabled: false }));
}

function matchesSkillsPolicy(actual, expected) {
  if (isDeepStrictEqual(actual, expected)) return true;
  if (!actual || typeof actual !== "object" || Array.isArray(actual)) return false;
  const projected = structuredClone(actual);
  for (const [key] of disabledSkillAdditions(actual, expected)) {
    delete projected.entries[key];
  }
  if (projected.entries && !Array.isArray(projected.entries) &&
      typeof projected.entries === "object" && Object.keys(projected.entries).length === 0 &&
      !own(expected ?? {}, "entries")) delete projected.entries;
  return isDeepStrictEqual(projected, expected ?? {}) && expected !== null;
}

function differingPaths(actual, expected, prefix) {
  if (isDeepStrictEqual(actual, expected)) return [];
  if (!actual || !expected || typeof actual !== "object" ||
      typeof expected !== "object" || Array.isArray(actual) || Array.isArray(expected)) {
    return [prefix];
  }
  return [...new Set([...Object.keys(actual), ...Object.keys(expected)])]
    .flatMap((key) => differingPaths(actual[key], expected[key], `${prefix}.${key}`));
}

function object(value, label) {
  if (!value || typeof value !== "object" || Array.isArray(value)) {
    throw new Error(`${label} must be an object`);
  }
}

function literalTree(value) {
  if (typeof value === "string" && value.includes("${")) {
    throw new Error("Environment interpolation is not allowed");
  }
  if (!value || typeof value !== "object") return;
  for (const [key, child] of Object.entries(value)) {
    if (["$include", "__proto__", "constructor", "prototype"].includes(key)) {
      throw new Error(`Unsupported config key: ${key}`);
    }
    literalTree(child);
  }
}

function model(value, base) {
  const allowed = new Set(Object.entries(base.models.providers).flatMap(
    ([provider, config]) => config.models.map((item) => `${provider}/${item.id}`),
  ));
  const refs = typeof value === "string" ? [value] : (() => {
    object(value, "model");
    if (Object.keys(value).some((key) => !["primary", "fallbacks"].includes(key)) ||
        (value.fallbacks !== undefined && !Array.isArray(value.fallbacks))) {
      throw new Error("Unsupported model selection");
    }
    return [value.primary, ...(value.fallbacks ?? [])];
  })();
  if (!refs.length || refs.some((ref) => !allowed.has(ref))) {
    throw new Error("Model must be declared by Guix");
  }
}

function directory(value, root) {
  if (typeof root !== "string" || typeof value !== "string" ||
      !value.startsWith(`${root}/`) ||
      path.posix.normalize(value) !== value || value === root) {
    throw new Error(`Directory must be a normalized path below ${root}`);
  }
}

export function validatePolicy(config, base) {
  object(config, "config");
  literalTree(config);
  for (const key of new Set([...Object.keys(base), ...Object.keys(config)])) {
    if (key === "skills" && matchesSkillsPolicy(config.skills, base.skills)) continue;
    if (!mutableRoot.has(key) && !isDeepStrictEqual(config[key], base[key])) {
      // Paths only: config values may contain credentials.
      const paths = differingPaths(config[key], base[key], key).slice(0, 8);
      throw new Error(`Guix manages ${key}; differing paths: ${paths.join(", ")}`);
    }
  }
  object(config.agents, "agents");
  const agents = config.agents;
  if (Object.keys(agents).some((key) => !["defaults", "entries", "ownership"].includes(key))) {
    throw new Error("Use agents.entries; other agent settings are managed");
  }
  if (agents.ownership !== undefined && agents.ownership !== "explicit") {
    throw new Error("Agent ownership must be explicit");
  }
  object(agents.defaults, "agents.defaults");
  const defaults = structuredClone(agents.defaults);
  model(defaults.model, base);
  defaults.model = base.agents.defaults.model;
  if (!isDeepStrictEqual(defaults, base.agents.defaults)) {
    throw new Error("Guix manages agent defaults except model selection");
  }
  object(agents.entries ?? {}, "agents.entries");
  // Roots follow Guix's declared main agent; sandboxes bind these host paths.
  const workspaces = path.posix.dirname(base.agents.defaults.workspace);
  const mainDir = base.agents.entries?.main?.agentDir;
  const agentDirs = mainDir && path.posix.dirname(path.posix.dirname(mainDir));
  for (const [id, entry] of Object.entries(agents.entries ?? {})) {
    if (!/^[a-z0-9][a-z0-9_-]*$/.test(id)) throw new Error("Invalid agent ID");
    object(entry, `agent ${id}`);
    if (Object.keys(entry).some((key) => !agentFields.has(key))) {
      throw new Error(`Agent ${id} contains an unmanaged override`);
    }
    if (own(entry, "model")) model(entry.model, base);
    // Explicit paths avoid several agents silently sharing the default workspace.
    directory(entry.workspace, workspaces);
    if (!own(entry, "workspace")) throw new Error(`Agent ${id} needs a workspace`);
    if (own(entry, "agentDir")) directory(entry.agentDir, agentDirs);
  }
  if (config.bindings !== undefined && !Array.isArray(config.bindings)) {
    throw new Error("bindings must be an array");
  }
}

export function reconcile(config, base) {
  const next = structuredClone(base);
  if (config) {
    for (const key of mutableRoot) {
      if (own(config, key)) next[key] = structuredClone(config[key]);
    }
    // Doctor can disable unavailable skills. Preserve only pure disable markers;
    // all declared entries and other skill settings still come from Guix.
    const disabledSkills = disabledSkillAdditions(config.skills, base.skills);
    if (disabledSkills.length) {
      next.skills = { ...next.skills,
        entries: { ...next.skills?.entries, ...Object.fromEntries(disabledSkills) } };
    }
    next.agents.defaults = structuredClone(base.agents.defaults);
    // Keep a user's selected model only while it remains in the approved catalog.
    try {
      model(config.agents?.defaults?.model, base);
      next.agents.defaults.model = structuredClone(config.agents.defaults.model);
    } catch { /* A removed model falls back to the declared default. */ }
  }
  validatePolicy(next, base);
  return next;
}
