#!/usr/bin/env sh
# Fake command for runtime ordering/failure tests; never invokes real tools.
set -eu
tool=${0##*/}
printf '%s %s\n' "$tool" "$*" >> "$RESTRICTED_MOCK_DIR/log"
case "$tool $1" in
    'ip -j')
        printf '[]\n'
        ;;
    'docker network')
        case "$2" in
            ls)
                [ "${RESTRICTED_MOCK_FAILURE:-}" != docker ] || exit 1
                if [ -f "$RESTRICTED_MOCK_DIR/exists" ]; then
                    printf 'agents\n'
                fi
                ;;
            inspect)
                cat "$RESTRICTED_MOCK_DIR/network.json"
                ;;
            create)
                touch "$RESTRICTED_MOCK_DIR/exists"
                ;;
            *) exit 2 ;;
        esac
        ;;
    'nft --check')
        [ "${RESTRICTED_MOCK_FAILURE:-}" != check ] || exit 1
        ;;
    'nft --file')
        [ "${RESTRICTED_MOCK_FAILURE:-}" != load ] || exit 1
        ;;
    *) exit 2 ;;
esac
