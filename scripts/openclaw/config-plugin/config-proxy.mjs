// The socket grants only the same model-setting capability as the tool.
import http from "node:http";
import fs from "node:fs/promises";
import path from "node:path";

export const MODEL_PATH = "agents.defaults.model";
const HELP = "Supported: openclaw config get agents.defaults.model [--json]\n" +
  "openclaw config set agents.defaults.model <value> [--strict-json]\n";

export function createConfigCommand(tool, readConfig) {
  return async (args) => {
    if (!Array.isArray(args) || args.some((arg) => typeof arg !== "string")) {
      throw new Error("Expected command arguments");
    }
    if (args.join(" ") === "config --help" || args.join(" ") === "--help") {
      return { ok: true, stdout: HELP };
    }
    const [command, action, key, ...rest] = args;
    if (command !== "config" || key !== MODEL_PATH) throw new Error(HELP);
    if (action === "get" && (rest.length === 0 ||
        (rest.length === 1 && rest[0] === "--json"))) {
      const value = (await readConfig()).agents?.defaults?.model;
      return { ok: true, stdout: JSON.stringify(value ?? null) + "\n" };
    }
    if (action !== "set" || rest.length < 1 || rest.length > 2 ||
        (rest.length === 2 && rest[1] !== "--strict-json")) throw new Error(HELP);
    let value;
    try { value = JSON.parse(rest[0]); } catch {
      if (rest[1] === "--strict-json") throw new Error("Invalid JSON value");
      value = rest[0];
    }
    const result = await tool.execute("config-proxy", { path: key, value });
    return { ok: result.details.ok,
      [result.details.ok ? "stdout" : "stderr"]: result.content[0].text + "\n" };
  };
}

export function createConfigProxyService(handle, directory) {
  let server;
  let busy = false;
  return {
    id: "uraj-config-proxy",
    async start() {
      const dir = directory ?? path.join(process.env.OPENCLAW_STATE_DIR, "config-proxy");
      await fs.mkdir(dir, { recursive: true, mode: 0o700 });
      const client = path.join(dir, "openclaw.next");
      await fs.copyFile(new URL("./config-client.py", import.meta.url), client);
      await fs.chmod(client, 0o500);
      await fs.rename(client, path.join(dir, "openclaw"));
      const socket = path.join(dir, "config.sock");
      await fs.rm(socket, { force: true });
      server = http.createServer(async (req, res) => {
        const send = (result) => { res.setHeader("Content-Type", "application/json"); res.end(JSON.stringify(result)); };
        if (req.method !== "POST" || req.url !== "/config" || busy) {
          req.resume(); send({ ok: false, stderr: "Config proxy unavailable; retry\n" }); return;
        }
        busy = true;
        try {
          let body = "";
          for await (const chunk of req) {
            body += chunk;
            if (Buffer.byteLength(body) > 16384) throw new Error("Request too large");
          }
          send(await handle(JSON.parse(body)));
        } catch {
          // Never return exception text from config readers or native writers.
          send({ ok: false, stderr: "Config request rejected. Use openclaw config --help; check Gateway logs if a supported request fails.\n" });
        } finally { busy = false; }
      });
      server.requestTimeout = 10000;
      server.headersTimeout = 10000;
      await new Promise((resolve, reject) => {
        server.once("error", reject);
        server.listen(socket, resolve);
      });
      await fs.chmod(socket, 0o600);
    },
    async stop() {
      if (server) await new Promise((resolve) => server.close(resolve));
    },
  };
}
