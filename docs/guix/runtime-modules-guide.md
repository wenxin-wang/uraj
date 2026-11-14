# Guix runtime modules

> 迁移自 `docs/coding-style.org` 的 “Guix runtime modules”（2026-11-14，内容未改）。

## Guix runtime modules

Use `(uraj utils gexp)` when a generated program or activation gexp imports local
modules. List the runtime entry modules; `with-uraj-modules` collects their
transitive `uraj`, `guix` and `gnu` dependencies from `define-module` forms:

```scheme
(program-file "prepare"
  (with-uraj-modules '((uraj build redroid))
    #~(begin
        (use-modules (uraj build redroid))
        (prepare-redroid #$data-directory #$render-node))))
```

`use-modules` inside a gexp only loads modules at runtime; it does not copy
them into the store. Guix's `source-module-closure` defaults to selecting
only `guix` / `gnu`, silently excluding local roots. Do not duplicate its
selector or hand-maintain transitive local imports at call sites.

Guile supplies built-in modules such as `ice-9` and `srfi`. Keep external
libraries such as `guile-json` in an enclosing `with-extensions`. Modules
loaded dynamically and absent from `define-module` imports must be listed
explicitly as roots. Special closures, such as the Asus initrd's deliberate
exclusion of `(guix store deduplication)`, retain their custom selector.
The crate-mirror driver runs under the supplied Guix command and adds its
local source with `-L`; that separate mechanism deliberately uses the
command's own Guix modules.

Validate module metadata and execute the network entry points in the build
sandbox (building a `program-file` alone does not execute its body):

```sh
guix repl -L src/guix -L src/guile test/guix/uraj/utils/gexp.scm
guix build -L src/guix -L src/guile -f test/guix/uraj/restricted-network-programs.scm
```
