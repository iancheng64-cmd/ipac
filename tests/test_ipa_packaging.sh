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

HELPER="$ROOT/ios/HengeJITHelper/Info.plist"
[[ "$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$HELPER")" == "$VERSION" &&
   "$(/usr/libexec/PlistBuddy -c 'Print :CFBundleVersion' "$HELPER")" == "$BUILD" ]] || {
    echo "Main app and JIT helper source versions must match." >&2
    exit 1
}
checks=$((checks + 1))

PROJECT="$FIXTURE/project"
MOCK_BIN="$FIXTURE/bin"
BUILD_MARKER="$FIXTURE/mock-build-called"
mkdir -p "$PROJECT/ios/scripts" "$PROJECT/ios/Henge" "$PROJECT/ios/HengeJITHelper" \
    "$PROJECT/ios/deps/StikJIT.xcframework" "$MOCK_BIN"
cp "$PACKAGE" "$PROJECT/ios/scripts/package_ipa.sh"
cp "$ROOT/ios/Henge/Info.plist" "$PROJECT/ios/Henge/Info.plist"
cp "$HELPER" "$PROJECT/ios/HengeJITHelper/Info.plist"
printf '#!/bin/sh\nexit 0\n' > "$MOCK_BIN/xcodegen"
printf '#!/bin/sh\n: > "$HENGE_IPA_TEST_BUILD_MARKER"\nprintf "BUILD SUCCEEDED\\n"\n' > "$MOCK_BIN/xcodebuild"
printf '#!/bin/sh\necho "Unexpected signing attempt" >&2\nexit 99\n' > "$MOCK_BIN/codesign"
chmod +x "$MOCK_BIN/xcodegen" "$MOCK_BIN/xcodebuild" "$MOCK_BIN/codesign"

expect_rejected() {
    local expected="$1" output
    if output="$(env HOME="$FIXTURE" HENGE_IPA_OUT= HENGE_RELEASE_ROOT="$FIXTURE/unused-releases" \
        HENGE_IPA_TEST_BUILD_MARKER="$BUILD_MARKER" PATH="$MOCK_BIN:$PATH" \
        /bin/zsh "$PROJECT/ios/scripts/package_ipa.sh" 2>&1)"; then
        echo "Inconsistent bundle metadata must be rejected." >&2
        exit 1
    fi
    [[ "$output" == *"$expected"* ]] || {
        printf 'Expected rejection %s, got %s\n' "$expected" "$output" >&2
        exit 1
    }
    checks=$((checks + 1))
}

/usr/libexec/PlistBuddy -c "Set :CFBundleVersion ${BUILD}0" "$PROJECT/ios/HengeJITHelper/Info.plist"
expect_rejected "JIT helper source version/build mismatch"
[[ ! -e "$BUILD_MARKER" ]] || { echo "Source validation must precede the build." >&2; exit 1; }
actual="$(env HOME="$FIXTURE" HENGE_IPA_OUT= HENGE_RELEASE_ROOT= \
    /bin/zsh "$PROJECT/ios/scripts/package_ipa.sh" --print-output)"
[[ "$actual" == "$BASE.ipa" && ! -e "$BUILD_MARKER" ]] || {
    echo "--print-output must remain a read-only path query even with mismatched helper metadata." >&2
    exit 1
}
checks=$((checks + 1))
/usr/libexec/PlistBuddy -c "Set :CFBundleVersion $BUILD" "$PROJECT/ios/HengeJITHelper/Info.plist"

APP="$PROJECT/ios/build/DerivedData/Build/Products/Release-iphoneos/Henge.app"
mkdir -p "$APP/PlugIns/HengeJITHelper.appex"
cp "$ROOT/ios/Henge/Info.plist" "$APP/Info.plist"
cp "$HELPER" "$APP/PlugIns/HengeJITHelper.appex/Info.plist"
/usr/libexec/PlistBuddy -c 'Set :CFBundleShortVersionString 9.9.9' "$APP/Info.plist"
expect_rejected "Built main app version/build mismatch"
[[ -f "$BUILD_MARKER" ]] || { echo "Product validation must run after the mock build." >&2; exit 1; }
/usr/libexec/PlistBuddy -c "Set :CFBundleShortVersionString $VERSION" "$APP/Info.plist"
/usr/libexec/PlistBuddy -c 'Set :CFBundleShortVersionString 9.9.9' "$APP/PlugIns/HengeJITHelper.appex/Info.plist"
expect_rejected "Built JIT helper version/build mismatch"
/usr/libexec/PlistBuddy -c "Set :CFBundleShortVersionString $VERSION" "$APP/PlugIns/HengeJITHelper.appex/Info.plist"
/usr/libexec/PlistBuddy -c "Set :CFBundleVersion ${BUILD}0" "$APP/PlugIns/HengeJITHelper.appex/Info.plist"
expect_rejected "Built JIT helper version/build mismatch"
[[ ! -e "$FIXTURE/unused-releases" ]] || {
    echo "Rejected product metadata must not create release artifacts." >&2
    exit 1
}

printf '%s IPA packaging checks passed; no real build was started.\n' "$checks"
