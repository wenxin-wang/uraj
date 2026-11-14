# Agent specs

Specs are alists in `llm.scm` (Codex uses `codex-spec` in the launcher);
`~` stands for the home directory.

| Key | Meaning |
|---|---|
| `program` | The real executable |
| `arguments` | Arguments prepended to the caller's arguments |
| `share` | Paths shared read-write when they exist |
| `expose` | Paths exposed read-only when they exist |
| `overlay` | Directories writable for the session only, through a tmpfs overlay dropped on exit |
| `persist` | Paths within an `overlay` that do reach the host |
| `seed` | Files copied into the container's home, writable, dropped on exit |
| `preserve` | Regexps of environment variable names to keep |

Overlays are mounted inside the container by
`bwrap --dev-bind / / --overlay-src DIR --tmp-overlay DIR`, which needs no
privileges.  `persist` paths are first shared at
`/run/contained-agent/persist-N`, then bound back over the overlay by the
same `bwrap`.  `seed` files are exposed at `/run/contained-agent/seed-N` and
copied by the launcher script.

### OpenCode and Pi

`opencode` and `pi` run contained; the original commands remain in
`~/.guix-home/profile/bin/`.

OpenCode reads `~/.config/opencode` through a temporary overlay. Its data
and state directories (`~/.local/share/opencode` and
`~/.local/state/opencode`) persist, including authentication and session
storage. Treat those writable directories as shared state across sessions.
Its cache is temporary.

Pi reads `~/.pi/agent` and `~/.agents/skills` through temporary overlays;
`~/.pi/agent/sessions/` and `~/.pi/agent/settings.json` persist. Model
choices and other settings therefore survive restarting the container.
Pi keeps its usual behavior: press `Ctrl+S` in `/model` to save the startup
default; an ordinary selection only affects the current session.
The launcher creates an empty settings file on first use without replacing
existing preferences. Log in with the original host command first: changes
to Pi credentials and extensions inside the container are discarded on exit.
The default agent directories are used; custom `PI_CODING_AGENT_DIR` and XDG directory overrides are not
forwarded. Both agents receive `OPENAI_.*`, `ANTHROPIC_.*`,
`GEMINI_API_KEY` and `OPENROUTER_API_KEY`. Other provider variables can be
added with a project's central `preserve` clause.

### Claude Code

Paseo's system tier uses this same policy; its host tier bypasses
contained-agent. Terminal `claude`/`codex` remain contained by default. See
[Paseo provider and configuration management](../paseo/daemon-guide.md#configuration).

- `~/.claude` is an overlay.  Settings (`settings.json` links to one of the
  `settings.json.*` profiles), plugins, skills and any new file such as
  `CLAUDE.md` are the session's own.
- Persisted: `projects/` (transcripts, memory), `sessions/`, `session-env/`,
  `file-history/`, `paste-cache/`, `todos/`, `plans/`, `tasks/`,
  `history.jsonl`.
- `~/.claude.json` (project trust, MCP servers) is seeded and dropped.
- Consequences: `/config`, `claude mcp add` and plugin installs work for the
  session only; change them on the host.  The command line may ask for
  project trust again; Paseo uses the SDK and does not.

### Codex

The launcher overlays `~/.codex` and `~/.agents/skills`.  Configuration,
trust decisions, rules, skills and plugins are writable inside a session and
discarded on exit.  A relative `config.toml -> config.toml.new-api` link works
because its target is in the same overlay.  Custom `CODEX_HOME` locations are
rejected.

Codex's runtime databases live in the persistent
`~/.codex/contained-sqlite/` directory, selected with the `sqlite_home`
command-line setting.  Keeping the directory as one mount places every
database beside its WAL, SHM and journal files, preserving SQLite locking
across concurrent sessions.  The top-level host databases are outside the
contained runtime.

The following state is shared with the host and other contained sessions:

- `contained-sqlite/` and `sqlite/`;
- `sessions/`, `archived_sessions/` and `thread-writer-locks/`;
- `log/` and `history.jsonl`;
- `auth.json` when it exists before launch.

A missing `history.jsonl` is created with mode `0600`.  When `auth.json` is
missing, login is valid for the current session only; log in on the host first
when credentials must persist.  Credential refreshes rewrite an existing
`auth.json` in place and pass through the bind mount.  `logout` removes the
file and must therefore run on the host after contained sessions exit.

`session_index.jsonl` remains in the overlay.  Codex replaces it atomically
when deleting a thread, which is incompatible with a single-file bind mount.
Thread-name index changes are consequently session-local; the rollout and
database state remain persistent.

On first startup, Codex imports the shared rollouts into the contained
database before showing the trust screen.  Let this finish and do not delete
the database; an interrupted import may make startup report a damaged database
for a while.

Codex's own `workspace-write` sandbox (Paseo's `auto` mode) makes `.git`
entirely read-only.  Failures there do not say whether our layer would have
stopped them; test with `full-access` to see our layer alone.  Its
`read-only` and `workspace-write` sandboxes also build their own `/dev`,
without the render node, and block the network unless
`sandbox_workspace_write.network_access` is set.  Without it agent-browser
fails to start; with it browser tasks run on SwiftShader.  `full-access` has
both the network and the render node.

Plugin caches live in an overlay: a marketplace update is downloaded again by
every session until a host-side Codex syncs it.
