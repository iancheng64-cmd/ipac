#!/bin/sh
set -u

case "${0##*/}" in
    uname)
        [ "$*" = '-s' ] || exit 91
        printf '%s\n' "${MOCK_PLATFORM:-Darwin}"
        ;;
    sysctl)
        [ "$*" = '-n hw.machine' ] || exit 91
        printf '%s\n' "${MOCK_MACHINE:-iPhone9,1}"
        ;;
    id)
        [ "$*" = '-u' ] || exit 91
        printf '%s\n' "${MOCK_UID:-501}"
        ;;
    plutil)
        if [ "${MOCK_PLUTIL_FAIL:-0}" = 1 ]; then
            exit 92
        fi
        if [ "${MOCK_PRODUCT_VERSION+x}" = x ]; then
            printf '%s\n' "$MOCK_PRODUCT_VERSION"
        else
            exec /usr/bin/plutil "$@"
        fi
        ;;
    *)
        printf '%s\n' "Unexpected execution of ${0##*/}" >&2
        exit 93
        ;;
esac
