#!/bin/zsh
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
PACKAGE="$ROOT/ios/scripts/package_ipa.sh"
VERSION="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$ROOT/ios/Henge/Info.plist")"
BUILD="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleVersion' "$ROOT/ios/Henge/Info.plist")"
FIXTURE="$(mktemp -d /tmp/ipac-package-test.XXXXXX)"
trap 'rm -rf "$FIXTURE"' EXIT
checks=0

expect_output() {
    local expected="$1" override="$2" release_root="$3"
    shift 3
    local actual
    actual="$(env HOME="$FIXTURE" HENGE_IPA_OUT="$override" HENGE_RELEASE_ROOT="$release_root" \
        /bin/zsh "$PACKAGE" "$@" --print-output)"
    [[ "$actual" == "$expected" ]] || {
        printf 'Expected %s, got %s\n' "$expected" "$actual" >&2
        exit 1
    }
    checks=$((checks + 1))
}

BASE="$FIXTURE/Downloads/iPac-Releases/v${VERSION}-build${BUILD}/iPac-v${VERSION}-build${BUILD}"
expect_output "$BASE.ipa" "" ""
expect_output "$BASE.tipa" "" "" --trollstore

CUSTOM="$FIXTURE/custom output/trial.ipa"
expect_output "$CUSTOM" "$CUSTOM" ""
expect_output "$CUSTOM" "$CUSTOM" "" --trollstore

CUSTOM_ROOT="$FIXTURE/workspace releases"
CUSTOM_BASE="$CUSTOM_ROOT/v${VERSION}-build${BUILD}/iPac-v${VERSION}-build${BUILD}"
expect_output "$CUSTOM_BASE.ipa" "" "$CUSTOM_ROOT"
expect_output "$CUSTOM_BASE.tipa" "" "$CUSTOM_ROOT" --trollstore

if env HOME="$FIXTURE" /bin/zsh "$PACKAGE" --unknown >/dev/null 2>&1; then
    echo "Unknown options must be rejected." >&2
    exit 1
fi
checks=$((checks + 1))

[[ ! -e "$FIXTURE/Downloads" && ! -e "$CUSTOM_ROOT" && ! -e "${CUSTOM:h}" ]] || {
    echo "--print-output must not create directories or build artifacts." >&2
    exit 1
}
checks=$((checks + 1))

printf '%s IPA output-path checks passed; no build was started.\n' "$checks"
