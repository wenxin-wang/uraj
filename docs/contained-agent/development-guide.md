# Developing contained-agent

## Development

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
