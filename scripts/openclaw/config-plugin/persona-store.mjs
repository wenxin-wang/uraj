import fs from "node:fs/promises";
import path from "node:path";
import { randomUUID } from "node:crypto";

export class PersonaStore {
  constructor(directory) {
    this.directory = directory;
    this.file = path.join(directory, "personas.json");
    this.queue = Promise.resolve();
  }
  async read() {
    try {
      const state = JSON.parse(await fs.readFile(this.file, "utf8"));
      if (state.version !== 1 || !state.roles || !state.groups || !state.users || !state.drafts) {
        throw new Error("Invalid persona registry");
      }
      return state;
    } catch (error) {
      if (error.code !== "ENOENT") throw error;
      return { version: 1, roles: {}, groups: {}, users: {}, drafts: {} };
    }
  }
  transact(fn) {
    const run = this.queue.then(async () => {
      const state = await this.read();
      const result = await fn(state);
      await fs.mkdir(this.directory, { recursive: true, mode: 0o700 });
      const temp = path.join(this.directory, `.${randomUUID()}.json`);
      try {
        await fs.writeFile(temp, JSON.stringify(state), { mode: 0o600, flag: "wx" });
        await fs.rename(temp, this.file);
      } finally { await fs.rm(temp, { force: true }); }
      return result;
    });
    this.queue = run.catch(() => {});
    return run;
  }
}
