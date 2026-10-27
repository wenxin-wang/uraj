#!/usr/bin/env node
// Checked configuration command. Runs only in the Gateway: at startup and
// through the openclaw_config_set tool; sandboxed exec cannot reach it.
import fs from "node:fs/promises";
import os from "node:os";
import path from "node:path";
import { createRequire } from "node:module";
import { spawnSync } from "node:child_process";
import { pathToFileURL } from "node:url";
import { reconcile, validatePolicy } from "./config-policy.mjs";

const CONFIG = process.env.OPENCLAW_CONFIG_PATH;
const BASE = "/etc/openclaw/base.json";
const CLI = "/app/openclaw.mjs";

export function withFeishuAppId(base, text) {
  const appId = text.trim();
  if (!/^cli_[a-zA-Z0-9]+$/.test(appId)) {
    throw new Error("Invalid Feishu App ID secret");
  }
  const next = structuredClone(base);
  next.channels.feishu.accounts.main.appId = appId;
  return next;
}

export function withCommandOwners(base, text) {
  let owners;
  try { owners = JSON.parse(text); } catch {
    throw new Error("Command owners secret must be a JSON array");
  }
  if (!Array.isArray(owners) || owners.some((id) =>
    typeof id !== "string" || !/^feishu:ou_[a-zA-Z0-9]+$/.test(id))) {
    throw new Error("Command owners must be explicit Feishu open IDs");
  }
  return { ...base, commands: { ...base.commands,
    ownerAllowFrom: [...new Set(owners)] } };
}

function parse(text) {
  try { return JSON.parse(text); } catch {
    // Native config writes use JSON5. Resolve the image's pinned dependency.
    return createRequire("/app/package.json")("json5").parse(text);
  }
}

async function read(file) {
  const stat = await fs.lstat(file);
  if (!stat.isFile()) throw new Error("Configuration must be a regular file");
  return parse(await fs.readFile(file, "utf8"));
}

function cli(args, config = CONFIG) {
  const result = spawnSync(process.execPath, [CLI, ...args], {
    cwd: "/app",
    env: { ...process.env, OPENCLAW_CONFIG_PATH: config,
      OPENCLAW_CONFIG_READONLY: "0" },
    encoding: "utf8", timeout: 120_000, maxBuffer: 8 * 1024 * 1024,
  });
  // Do not echo native diagnostics: they can contain config values or credentials.
  // Name only the step and how it ended.
  if (result.error || result.status !== 0) {
    const step = args[0] === "gateway" ? `gateway call ${args[2]}` : `${args[0]} ${args[1]}`;
    const outcome = result.error?.code === "ETIMEDOUT" ? "timed out"
      : result.error ? `could not run (${result.error.code ?? "error"})`
        : `exited with status ${result.status}`;
    throw new Error(`Native OpenClaw ${step} ${outcome}; no successful commit confirmed`);
  }
  return result.stdout;
}

function rpc(method, params = {}) {
  return JSON.parse(cli(["gateway", "call", method, "--json", "--params",
    JSON.stringify(params)]));
}

export async function checkedSet(args, { base, snapshot, mutate, submit }) {
  // Restrict CLI flags: no --allow-exec, alternate providers, files, or config paths.
  if (!(args.length === 2 && !args[0].startsWith("--"))) {
    throw new Error("Usage: config.mjs set <path> <JSON value>");
  }
  const value = JSON.parse(args[1]);
  const current = await snapshot();
  validatePolicy(current.config, base);
  const preview = structuredClone(current.config);
  const normalized = args[0].replace(/\[(\d+)\]/g, ".$1");
  if (!/^[A-Za-z0-9_-]+(?:\.[A-Za-z0-9_-]+)*$/.test(normalized)) {
    throw new Error("Use dotted paths or numeric array indices");
  }
  const parts = normalized.split(".");
  if (parts.some((key) => ["__proto__", "constructor", "prototype"].includes(key))) {
    throw new Error("Invalid config path");
  }
  let cursor = preview;
  for (let index = 0; index < parts.length - 1; index++) {
    const key = parts[index];
    if (!Object.hasOwn(cursor, key)) {
      cursor[key] = /^\d+$/.test(parts[index + 1]) ? [] : {};
    }
    cursor = cursor[key];
    if (!cursor || typeof cursor !== "object") throw new Error("Invalid config path");
  }
  cursor[parts.at(-1)] = value;
  validatePolicy(preview, base);
  const candidate = await mutate(current.config, args[0], value);
  validatePolicy(candidate, base);
  await submit(candidate, current.hash);
}

export async function loadManagedBase() {
  let base = await read(BASE);
  if (process.env.OPENCLAW_FEISHU_APP_ID_FILE) {
    if (process.env.OPENCLAW_FEISHU_APP_ID_FILE !== "/run/secrets/feishu-app-id") {
      throw new Error("Unexpected Feishu App ID secret path");
    }
    base = withFeishuAppId(base,
      await fs.readFile(process.env.OPENCLAW_FEISHU_APP_ID_FILE, "utf8"));
  }
  if (process.env.OPENCLAW_COMMAND_OWNERS_FILE) {
    if (process.env.OPENCLAW_COMMAND_OWNERS_FILE !== "/run/secrets/command-owners") {
      throw new Error("Unexpected command owners secret path");
    }
    base = withCommandOwners(base,
      await fs.readFile(process.env.OPENCLAW_COMMAND_OWNERS_FILE, "utf8"));
  }
  return base;
}

async function main(args) {
  if (!CONFIG || !path.isAbsolute(CONFIG)) {
    throw new Error("OPENCLAW_CONFIG_PATH must be an absolute path");
  }
  const base = await loadManagedBase();
  if (args.length === 1 && args[0] === "reconcile") {
    // Only run during service start, after the previous Gateway has stopped.
    await fs.mkdir(path.dirname(CONFIG), { recursive: true, mode: 0o700 });
    let previous;
    try { previous = await read(CONFIG); } catch (error) {
      if (error.code !== "ENOENT") throw error;
    }
    const next = reconcile(previous, base);
    const dir = await fs.mkdtemp(path.join(path.dirname(CONFIG), ".reconcile-"));
    try {
      const candidate = path.join(dir, "openclaw.json");
      await fs.writeFile(candidate, JSON.stringify(next, null, 2), { mode: 0o600 });
      cli(["config", "validate"], candidate);
      if (previous) {
        await fs.writeFile(path.join(dir, "previous.json"),
          JSON.stringify(previous, null, 2), { mode: 0o600 });
        await fs.rename(path.join(dir, "previous.json"), `${CONFIG}.before-guix`);
      }
      await fs.rename(candidate, CONFIG);
    } finally { await fs.rm(dir, { recursive: true, force: true }); }
    console.log("Configuration reconciled with Guix.");
    return;
  }
  if (args.length === 1 && args[0] === "check") {
    validatePolicy(await read(CONFIG), base);
    console.log("Configuration satisfies Guix policy.");
    return;
  }
  if (args.shift() !== "set") throw new Error("Use check, reconcile, or set");
  await checkedSet(args, {
    base,
    snapshot: async () => {
      const before = rpc("config.get");
      const config = await read(CONFIG);
      const after = rpc("config.get");
      if (!before.hash || before.hash !== after.hash) {
        throw new Error("Configuration changed; retry");
      }
      return { config, hash: after.hash };
    },
    mutate: async (config, key, value) => {
      // Reject forbidden edits before invoking native validation/SecretRef logic.
      // Only agent metadata/model/path and routing edits are accepted by this CLI.
      if (!/^(agents\.(entries|defaults\.model)(\.|\[|$)|bindings(\.|\[|$))/.test(key) &&
          !/^channels\.feishu\.groups\.oc_[a-zA-Z0-9]+\.requireMention$/.test(key)) {
        throw new Error("Only agent, binding and per-group mention edits are accepted");
      }
      const dir = await fs.mkdtemp(path.join(os.tmpdir(), "openclaw-config-"));
      try {
        const file = path.join(dir, "openclaw.json");
        await fs.writeFile(file, JSON.stringify(config), { mode: 0o600 });
        cli(["config", "set", key, JSON.stringify(value), "--strict-json"], file);
        return await read(file);
      } finally { await fs.rm(dir, { recursive: true, force: true }); }
    },
    submit: async (candidate, hash) => {
      // Native Gateway writer owns locking, revision checks, backup and reload.
      const result = rpc("config.set", { raw: JSON.stringify(candidate), baseHash: hash });
      if (!result.ok) throw new Error("Gateway did not confirm the write");
    },
  });
  console.log("Configuration committed; Gateway applies changes by its reload policy.");
}

if (process.argv[1] && import.meta.url === pathToFileURL(process.argv[1]).href) {
  main(process.argv.slice(2)).catch((error) => {
    console.error(error.message);
    process.exitCode = 1;
  });
}
