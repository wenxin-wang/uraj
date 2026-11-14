# broker 首版的验证记录

以下段落原在 [broker-guide](../../../paseo/broker-guide.md) 的 Implemented trial 一节，2026-10-09 随 1e624f0 写入，原文未改。

Validated on 2026-10-09: Guix builds of native supervisor and bundle; ten
integration tests (streams, probes, numeric/signal results, detached child
cleanup, client/parent/broker death, restart, replacement barrier, config
backup/restore, status and malformed request); isolated Shepherd load/start/
status/stop using the exact trial file.  Real contained-agent version probes
returned Codex 0.155.0 and Claude Code 2.1.287.  Real Codex app-server initialize
and stdin-EOF exit passed through the full broker/Guix path with temporary
state and no credentials.  Codex warns about PATH helper creation with a
temporary CODEX_HOME; this test warning did not prevent the handshake.
Authenticated model turns and the actual lappie Paseo UI remain host-side tests.
