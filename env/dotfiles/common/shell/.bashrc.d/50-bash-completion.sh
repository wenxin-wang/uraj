# Sourcing the loader is enough: its completion lookup also searches
# $XDG_DATA_DIRS/bash-completion/completions, where the Guix Home profile
# (and thus other packages, e.g. git, fd) drops its completions.
# (bash-minimal, which the dev shell may put on PATH, has no 'complete'.)
if command -v complete >/dev/null 2>&1 && [ -z "${BASH_COMPLETION_VERSINFO-}" ]; then
    _bc_dirs=${XDG_DATA_DIRS:-/usr/local/share:/usr/share}
    for _bc_dir in ${_bc_dirs//:/ }; do
        if [ -r "$_bc_dir/bash-completion/bash_completion" ]; then
            . "$_bc_dir/bash-completion/bash_completion"
            break
        fi
    done
    unset _bc_dir _bc_dirs
fi
