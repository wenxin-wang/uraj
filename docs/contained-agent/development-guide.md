# Developing contained-agent

Run the module straight from the source tree:

```scheme
;; /tmp/ca-dev.scm
(use-modules (uraj bin contained-agent))
(contained-agent-main (cons "contained-agent" (cdr (command-line)))
  #:agents `(("bash" (program . ,(canonicalize-path
                                  "/run/current-system/profile/bin/bash"))
              (overlay "~/.claude")))
  #:common '((preserve "TERM")) #:packages '("bash" "coreutils" "bubblewrap")
  #:git "git")
```

```sh
CONTAINED_AGENT_PROJECTS=$PWD/env/dotfiles/llm/contained-agent/.config/contained-agent/projects.scm \
  guile --no-auto-compile -L src/guile /tmp/ca-dev.scm bash -c '...'
guix time-machine -C env/guix/channels-lock.scm -- build -L src/guix -L src/guile \
  -e '((@@ (uraj home llm) contained-agent-link) "codex")'
```

Test writes against a fake `HOME` in `/tmp`, never the real agent state, and
guard probes with the expected working directory.

## Implementation notes

- Inside the container `HOME` comes from `passwd`, not the caller's
  environment: tests with a fake `HOME` must use absolute paths.
- `execlp` replaces the process before Guile flushes the error port:
  warnings need `force-output`.
- `home-dotfiles-service-type` imports files with `local-file`, which follows
  links: a link in the dotfiles tree becomes a copy.  Use a `computed-file`
  that is itself a link.
- An explicit `ssh -F FILE` test does not cover OpenSSH's permission check on
  the default `~/.ssh/config`; exercise default config discovery too.

## Tests

All run from the repository root with the tools of `manifest.scm`:

```sh
# Codex state: overlays, config links, shared SQLite state, credentials.
# With the real binary it also exercises trust updates, login and rollout
# import; without it only the mount behaviour.
CODEX_TEST_BINARY=/path/to/real/codex \
  python3 test/python/uraj/guix/contained-agent/contained-agent-codex.py
# Per-project SSH agents (needs Guile 3, OpenSSH 8.9+, Git, bubblewrap).
python3 test/python/uraj/guix/contained-agent/contained-agent-ssh.py
# guix-daemon opt-in, cache seeding and mount ordering; needs no daemon.
python3 test/python/uraj/guix/contained-agent/contained-agent-guix.py
```

The Podman runtime has `podman-runtime-profile.py` and
`podman-runtime-session.py` in the same directory, and `podman-check` on a
deployed host, see [podman-guide](podman-guide.md).  The browser flow is
checked on a desktop host with `scripts/contained-agent/try-browser`.
After deploying `(guix-daemon)`, check in a new uraj session with
`guix build hello --dry-run` and
`guix time-machine -C env/guix/channels-lock.scm -- describe`.
