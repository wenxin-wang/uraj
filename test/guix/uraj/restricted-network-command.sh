#!/usr/bin/env sh
# Fake command for runtime ordering/failure tests; never invokes real tools.
set -eu
tool=${0##*/}
printf '%s %s\n' "$tool" "$*" >> "$RESTRICTED_MOCK_DIR/log"
case "$tool $1" in
    'ip -j')
        if [ "$3 $4" = 'rule show' ] && [ -f "$RESTRICTED_MOCK_DIR/rules.json" ]; then
            cat "$RESTRICTED_MOCK_DIR/rules.json"
        elif [ "$3 $4" = 'route get' ]; then
            if [ -f "$RESTRICTED_MOCK_DIR/route-hijacked" ]; then
                printf '[{"dst":"%s","dev":"wlan0","table":"220"}]\n' "$5"
            else
                printf '[{"dst":"%s","dev":"br-policy-test"}]\n' "$5"
            fi
        elif [ "${5:-}" = default ] && [ -f "$RESTRICTED_MOCK_DIR/route-ready" ]; then
            printf '[{"dst":"default","dev":"lo"}]\n'
        else
            printf '[]\n'
        fi
        ;;
    'ip -4')
        # rule add pref 200 to SUBNET lookup main; one subnet per test fixture.
        [ "$2 $3 $6 $8 $9" = 'rule add to lookup main' ] || exit 2
        printf '[{"priority":%s,"src":"all","dst":"%s","dstlen":%s,"table":"main"}]\n' \
            "$5" "${7%/*}" "${7#*/}" > "$RESTRICTED_MOCK_DIR/rules.json"
        ;;
    'docker network')
        case "$2" in
            ls)
                [ "${RESTRICTED_MOCK_FAILURE:-}" != docker ] || exit 1
                if [ -f "$RESTRICTED_MOCK_DIR/exists" ]; then
                    printf 'static-agent\n'
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
