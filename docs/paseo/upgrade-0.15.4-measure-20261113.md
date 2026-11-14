# Paseo upgrade from 0.11.4 to 0.15.4

## Upgrade from 0.11.4 to 0.15.4

As checked on 2026-11-13, [0.15.4](https://github.com/getpaseo/paseo/releases/tag/v0.15.4) is the latest stable release;
0.16.0 is still in beta. The official amd64 Debian archive retains the
Electron launcher, CLI and native-addon layout used by our Guix package.
Its SHA-256 matches the upstream release asset digest. Provider `command`
arrays, `extends`, `PASEO_AGENT_ID` and `PASEO_AGENT_CWD` still support the
broker clients. The workspace registry remains
`~/.paseo/projects/workspaces.json` with the ownership/archive fields used
by branch GC.

Before deploying, let active work finish, stop the daemon and close the
desktop app. Back up `~/.paseo` and `~/.config/Paseo/desktop-settings.json`
before Home activation or the first new-version launch. Install the new
Home/system generation and restart the managed service; a running container
keeps its old profile mount. Account for these upstream changes:

- [0.13.0](https://github.com/getpaseo/paseo/releases/tag/v0.13.0) requires the daemon password on relay connections when one is
  configured. Re-add hosts previously paired without that password. Removing
  `PASEO_PASSWORD` from the launcher does not remove a password saved in
  `config.json`.
- [0.14.0](https://github.com/getpaseo/paseo/releases/tag/v0.14.0) changes speech credentials and idle-cleanup settings; voice mode
  becomes opt-in. If environment variables select OpenAI speech, move keys
  and endpoints stored only in legacy `providers.openai` into Voice settings.
  [0.15.0](https://github.com/getpaseo/paseo/releases/tag/v0.15.0) adds agent-resume and usage-check settings. Rollback needs the
  pre-upgrade configuration as well as the previous Guix generation;
  older releases reject some newly saved settings.
- 0.15 introduces a separate terminal worker. The first upgrade closes old
  terminals. Our Shepherd stop sends SIGTERM, and restarting the Guix
  container destroys its PID namespace, so do not expect terminal survival
  across managed service restarts. Agent recovery is off by default;
  enabling it sends a new prompt in interrupted conversations rather than
  preserving their provider processes.
- Fable 5.2 and Mythos 5.2 require Claude Code >= 2.1.321. The currently
  packaged 2.1.287 keeps these models unavailable; existing models remain
  usable. Mythos also requires access advertised by Claude Code.
- [0.12.0](https://github.com/getpaseo/paseo/releases/tag/v0.12.0) deprecates `paseo run --background` in favor of `--no-wait`;
  `paseo permit allow/deny` now fail if the daemon does not confirm within
  15 seconds. Our service uses `paseo daemon run` and is unaffected.

Validation covered the Guix package/profile build, native-addon loading,
activation/service/branch-GC tests, and a disposable real daemon container
with a fake broker provider and a working terminal. Authenticated provider
turns, desktop rendering and mobile relay pairing still need deployment
smoke tests.
