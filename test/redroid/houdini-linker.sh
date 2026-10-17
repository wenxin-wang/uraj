#!/bin/sh
# Run from the repository root. Exercise the Android helper on host fixtures.
set -eu
work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT
mkdir "$work/bin"
cat > "$work/bin/setprop" <<'MOCK'
#!/bin/sh
printf '%s\n' "$*" >> "$TEST_LOG"
MOCK
chmod +x "$work/bin/setprop"
export TEST_LOG="$work/properties"
export PATH="$work/bin:$PATH"
sed "s|^config=.*|config=$work/ld.config.txt|; s|/linkerconfig/uraj-houdini|$work/uraj-houdini|" \
    src/guix/uraj/packages/aux-files/houdini-linker > "$work/helper"
allowance='namespace.default.permitted.paths += /system/${LIB}/arm64:/system/${LIB}/arm'
for section in middle last; do
    printf '[system]\nnamespace.default.permitted.paths = /system/lib\n' > "$work/ld.config.txt"
    if [ "$section" = middle ]; then
        printf '[vendor]\nkeep=yes\n' >> "$work/ld.config.txt"
    fi
    chmod 640 "$work/ld.config.txt"
    sh "$work/helper"
    [ "$(grep -F -c "$allowance" "$work/ld.config.txt")" = 1 ]
    [ "$(stat -c %a "$work/ld.config.txt")" = 640 ]
    cp "$work/ld.config.txt" "$work/once"
    sh "$work/helper"
    cmp "$work/once" "$work/ld.config.txt"
done
for invalid in missing duplicate; do
    if [ "$invalid" = missing ]; then
        printf '[vendor]\nkeep=yes\n' > "$work/ld.config.txt"
    else
        printf '[system]\n[system]\n' > "$work/ld.config.txt"
    fi
    cp "$work/ld.config.txt" "$work/before"
    cp "$TEST_LOG" "$work/properties-before"
    if sh "$work/helper"; then
        echo "Unexpected success for $invalid section" >&2
        exit 1
    fi
    cmp "$work/before" "$work/ld.config.txt"
    cmp "$work/properties-before" "$TEST_LOG"
done
printf 'PASS: section placement, idempotence, permissions and fail-closed behavior\n'
