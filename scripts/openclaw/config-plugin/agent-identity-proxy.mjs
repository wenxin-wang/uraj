import fs from "node:fs/promises";
import { constants } from "node:fs";
import path from "node:path";
import { randomBytes } from "node:crypto";

export const CAPABILITY_FILE = ".openclaw-cli-capability";
const FIELDS = ["name", "theme", "emoji", "avatar"];
const PLACEHOLDERS = new Set([
  "not set yet", "pick something you like",
  "ai? robot? familiar? ghost in the machine? something weirder?",
  "how do you come across? sharp? warm? chaotic? calm?",
  "your signature - pick one that feels right",
  "workspace-relative path, http(s) url, or data uri",
]);

export class IdentityCommandError extends Error {}
function reject(message) { throw new IdentityCommandError(message); }

export function parseIdentity(content) {
  const values = {};
  for (const line of content.split(/\r?\n/)) {
    const match = /^\s*(?:-\s*)?([^:]+):(.*)$/.exec(line);
    if (!match) continue;
    const key = match[1].replace(/[*_`]/g, "").trim().toLowerCase();
    const value = match[2].replace(/^[*_`\s]+|[*_`\s]+$/g, "").trim();
    const normalized = value.replace(/^\((.*)\)$/, "$1")
      .replace(/[\u2013\u2014]/g, "-").replace(/\s+/g, " ").toLowerCase();
    if ([...FIELDS, "creature", "vibe"].includes(key) && value && !PLACEHOLDERS.has(normalized)) {
      values[key] = value;
    }
  }
  const identity = {};
  for (const field of FIELDS) {
    const value = field === "theme" ? values.theme ?? values.creature ?? values.vibe : values[field];
    if (value) identity[field] = value;
  }
  return identity;
}

async function readIdentity(workspace) {
  const file = await fs.open(path.join(workspace, "IDENTITY.md"),
    constants.O_RDONLY | constants.O_NOFOLLOW | constants.O_NONBLOCK);
  try {
    const stat = await file.stat();
    if (!stat.isFile() || stat.nlink !== 1 || stat.size > 65536) reject("IDENTITY.md must be a regular file of at most 64 KiB.");
    const buffer = Buffer.alloc(65537);
    const { bytesRead } = await file.read(buffer, 0, buffer.length, 0);
    if (bytesRead > 65536) reject("IDENTITY.md is too large.");
    return parseIdentity(buffer.subarray(0, bytesRead).toString("utf8"));
  } finally { await file.close(); }
}

// A capability is generated from trusted hook context, never from CLI arguments.
// It lives only in that agent's workspace and is invalid after Gateway restart.
export class AgentIdentityProxy {
  constructor({ config, setIdentity }) {
    Object.assign(this, { config, setIdentity });
    this.byAgent = new Map();
    this.byToken = new Map();
  }
  async workspace(id) {
    const entries = this.config().agents?.entries ?? {};
    const entry = entries[id];
    if (!entry || !path.isAbsolute(entry.workspace)) reject("Current agent is not registered.");
    const workspace = await fs.realpath(entry.workspace);
    if (workspace !== entry.workspace) reject("Agent workspace must not be a symlink.");
    // Never place a capability in an overlapping/shared workspace.
    for (const [otherId, other] of Object.entries(entries)) {
      if (otherId === id) continue;
      const otherPath = await fs.realpath(other.workspace).catch((error) => {
        if (error.code === "ENOENT") return path.resolve(other.workspace);
        throw error;
      });
      if (workspace === otherPath || workspace.startsWith(`${otherPath}/`) ||
          otherPath.startsWith(`${workspace}/`)) reject("Agent workspaces overlap.");
    }
    return workspace;
  }
  async prepare(id) {
    if (typeof id !== "string" || !/^[a-z0-9][a-z0-9_-]*$/.test(id)) reject("Missing trusted agent ID.");
    const workspace = await this.workspace(id);
    let grant = this.byAgent.get(id);
    if (!grant || grant.workspace !== workspace) {
      if (grant) this.byToken.delete(grant.token);
      grant = { id, workspace, token: randomBytes(32).toString("hex") };
      this.byAgent.set(id, grant);
      this.byToken.set(grant.token, grant);
    }
    const temporary = path.join(workspace, `.${randomBytes(16).toString("hex")}.cli`);
    try {
      await fs.writeFile(temporary, grant.token, { mode: 0o600, flag: "wx" });
      await fs.rename(temporary, path.join(workspace, CAPABILITY_FILE));
    } finally { await fs.rm(temporary, { force: true }); }
  }
  async handle(args, token) {
    const grant = typeof token === "string" && this.byToken.get(token);
    if (!grant) reject("Agent identity unavailable. Run this command through the current agent's exec tool.");
    const { id } = grant;
    if (await this.workspace(id) !== grant.workspace) reject("Agent workspace changed; run through exec again.");
    const entry = this.config().agents.entries[id];
    if (args[1] === "list" && (args.length === 2 ||
        (args.length === 3 && args[2] === "--json"))) {
      return { ok: true, stdout: JSON.stringify([{
        id, name: entry.name, identity: entry.identity ?? {}, workspace: "/workspace",
      }]) + "\n" };
    }
    if (args[1] !== "set-identity") reject("Only agents list [--json] and agents set-identity are supported.");
    const options = {};
    for (let i = 2; i < args.length; i++) {
      const flag = args[i];
      if (Object.hasOwn(options, flag)) reject("Duplicate identity option.");
      if (["--from-identity", "--json"].includes(flag)) options[flag] = true;
      else if (["--agent", "--workspace", ...FIELDS.map((field) => `--${field}`)].includes(flag)) {
        const value = args[++i];
        if (!value || value.startsWith("--")) reject("Identity option requires a value.");
        options[flag] = value;
      } else reject("Unsupported identity option; arbitrary identity files and routing changes are not allowed.");
    }
    if (options["--agent"] && options["--agent"] !== id) reject("Only the current agent's identity may be changed.");
    if (options["--workspace"] && !["/workspace", grant.workspace].includes(options["--workspace"])) {
      reject("Only the current workspace may be used.");
    }
    const explicit = Object.fromEntries(FIELDS.filter((field) => options[`--${field}`] !== undefined)
      .map((field) => [field, options[`--${field}`]]));
    const identity = { ...(options["--from-identity"] || !Object.keys(explicit).length
      ? await readIdentity(grant.workspace) : {}), ...explicit };
    if (!Object.keys(identity).length) reject("No identity fields found.");
    for (const [field, value] of Object.entries(identity)) {
      if (!value.trim() || value.length > (field === "theme" ? 2000 : 256) ||
          /[\u0000-\u001f\u007f]/.test(value) || value.includes("${")) reject("Invalid identity value.");
      identity[field] = value.trim();
    }
    if (identity.avatar) {
      const avatar = identity.avatar;
      if (path.isAbsolute(avatar) || avatar.includes(":") || avatar.includes("\\") ||
          avatar.split("/").some((part) => !part || part === "." || part === "..")) {
        reject("Avatar must be a file relative to the current workspace.");
      }
      const resolved = await fs.realpath(path.join(grant.workspace, avatar));
      if (!resolved.startsWith(`${grant.workspace}/`)) reject("Avatar leaves the current workspace.");
      const stat = await fs.stat(resolved);
      if (!stat.isFile() || stat.nlink !== 1 || stat.size > 2 * 1024 * 1024) reject("Avatar must be a regular file of at most 2 MiB.");
    }
    const saved = await this.setIdentity(id, grant.workspace, identity);
    return { ok: true, stdout: JSON.stringify({ agentId: id, identity: saved, workspace: "/workspace" }) + "\n" };
  }
}
