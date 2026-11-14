# Paseo 版本探测的坑

- The version probe runs `COMMAND[0] --version` and drops the other
  elements of a command override.  With `["contained-agent", "codex"]` the
  probe failed, Paseo concluded Codex was too old and rejected its default
  `auto-review` mode.  Hence one executable per agent, named after it.
- Paseo 0.10.3 gives this probe only five seconds.  The launcher handles
  exactly `--version` by executing the configured agent binary directly,
  without project policy, credentials or a Guix container/profile build.
  A cold profile must not make a recent Codex look too old for `auto-review`.
  All other invocations still use the container, including `auth status`.
  Restart the daemon after deploying this fix to clear a cached failed probe.
