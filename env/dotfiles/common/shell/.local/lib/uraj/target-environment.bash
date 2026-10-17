# Shared environment selection for the Guix configuration entry points.
uraj_target_environment() {
    local environment
    uraj_root=$HOME/src/uraj
    if [[ -n ${1-} ]]; then
        uraj_target=$(realpath -e -- "$1") || return
        uraj_root=$(dirname -- "$uraj_target")
        while [[ ! -f $uraj_root/.envrc ]]; do
            if [[ $uraj_root == / ]]; then
                printf 'No .envrc found for target: %s\n' "$1" >&2
                return 1
            fi
            uraj_root=$(dirname -- "$uraj_root")
        done
    fi
    environment=$(cd -- "$uraj_root" && direnv export bash) || return
    eval "$environment"
}
