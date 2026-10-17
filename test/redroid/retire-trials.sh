#!/bin/sh
# No Docker daemon needed: ensure readiness/mount failures prevent all deletion.
set -eu
work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT
mkdir "$work/bin" "$work/data"
export TEST_DATA="$work/data"
export TEST_LOG="$work/docker.log"
export TEST_MODE=ready
export PATH="$work/bin:$PATH"
printf '%s\n' redroid-waydroid-houdini-test-data > "$TEST_DATA.source"
cat > "$work/bin/id" <<'MOCK'
#!/bin/sh
echo 0
MOCK
cat > "$work/bin/docker" <<'MOCK'
#!/bin/sh
printf '%s\n' "$*" >> "$TEST_LOG"
case "$1 $2" in
    'inspect redroid-maa') echo "$TEST_DATA" ;;
    'exec redroid-maa')
        case "$4" in
            sys.boot_completed) [ "$TEST_MODE" = unready ] && echo 0 || echo 1 ;;
            uraj.houdini.linker.ready) echo 1 ;;
            ro.dalvik.vm.native.bridge) echo libhoudini.so ;;
        esac ;;
    'container inspect'|'volume inspect') exit 0 ;;
    'inspect '*)
        if [ "$TEST_MODE" = wrong-mount ] && [ "$2" = redroid-codysk-test ]; then
            echo production-data
        else
            echo "$2-data"
        fi ;;
    'image inspect') exit 1 ;;
esac
MOCK
chmod +x "$work/bin/id" "$work/bin/docker"
sed "s|^target=.*|target=$TEST_DATA|" scripts/redroid/retire-trials > "$work/retire"
for TEST_MODE in unready wrong-mount; do
    export TEST_MODE
    : > "$TEST_LOG"
    if sh "$work/retire"; then
        echo "Unexpected success for $TEST_MODE" >&2
        exit 1
    fi
    if grep -E '^(stop |rm |volume rm |image rm )' "$TEST_LOG"; then
        echo 'Mutation before all checks passed' >&2
        exit 1
    fi
done
export TEST_MODE=ready
: > "$TEST_LOG"
sh "$work/retire"
[ "$(grep -c '^rm ' "$TEST_LOG")" = 4 ]
[ "$(grep -c '^volume rm ' "$TEST_LOG")" = 4 ]
if grep -E '^((stop|rm) redroid-maa|.*prune)' "$TEST_LOG"; then
    exit 1
fi
printf 'PASS: failed readiness/mount checks block cleanup; only four trials removed\n'
