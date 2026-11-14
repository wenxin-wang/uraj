# contained-agent open items

> 旧文档：只读，不再更新。现状见 [contained-agent](../contained-agent.md)。

> 迁移自 `docs/contained-agent.org` 的 “Open items”（2026-11-14，内容未改）。

## Open items

- Paseo outside the agent's container: see [Paseo broker design](paseo-broker.md)
  for the implemented host execution service, lappie trial commands and
  lifecycle/cleanup tests.  The host provider switch is explicit; existing
  direct provider commands still rely on Paseo's process-tree cleanup.
- Network: give the container its own network namespace and an allowlisting
  proxy reached through a Unix socket.  Until then agents reach the Paseo
  API on `127.0.0.1:6767` and the LAN.
- `codex-desktop` runs outside the sandbox and reads `~/.codex`.
- Per-agent SSH agents holding only chosen keys.
