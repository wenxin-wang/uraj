# Codex Desktop / ChatGPT on Guix

The `(uraj packages codex-desktop)` module repackages OpenAI's official
Linux amd64 Debian package.  Version 26.930.41038 is distributed under the
ChatGPT name.  Its versioned download URL and SHA256 come from the official
APT repository's `dists/stable/main/binary-amd64/Packages` index.

## Build and try

From the repository root:

```sh
uraj-guix build -L src/guix -L src/guile \
  -e '(@ (uraj packages codex-desktop) codex-desktop)'
uraj-guix shell -L src/guix -L src/guile \
  -e '(@ (uraj packages codex-desktop) codex-desktop)' -- codex-desktop
```

If `uraj-guix` cannot find `maak`, use the equivalent prefix
`guix time-machine -C env/guix/channels-lock.scm --`.
No Home installs the package (it was removed from Home on 2026-10-10); build
and try it manually as above.

## Coexistence with the CLI

- `codex` remains the separately packaged CLI.
- `codex-desktop` and `chatgpt` launch the desktop application.
- The desktop keeps its bundled Codex and Code Mode host.  Do not
  replace these with the independently updated CLI without testing protocol
  compatibility with the GUI.
- The clients can share `~/.codex/config.toml`, including MCP configuration.
  See https://learn.chatgpt.com/docs/extend/mcp .  Shared configuration means
  changes made by either client may affect the other.

## Limits

Only x86_64-linux is packaged.  Optional Qt shims and foreign-platform or
musl addons are retained but excluded from ELF patching; the default UI uses
GTK.  The desktop can download additional runtimes/plugins into user state:
those downloads are not part of this Guix package's pinned dependency closure.
