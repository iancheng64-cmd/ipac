#!/bin/zsh
# Builds Henge for iOS into a versioned folder in ~/Downloads/iPac-Releases.
# Unsigned build, then signed ad hoc inside out with the entitlements file named by the
# HENGE_ENTITLEMENTS environment variable (default Henge/Henge.entitlements), as Husk's
# package_ipa.sh does: the sideloader (SideStore, AltStore, Impactor) re-signs it
# with the user's own certificate and keeps the entitlements it can.
# --trollstore strips the entitlements TrollStore bans under PPL/TXM.
set -e
IOS="$(cd "$(dirname "$0")/.." && pwd)"
TROLLSTORE=false
PRINT_OUTPUT=false
for arg in "$@"; do
    case "$arg" in
        --trollstore) TROLLSTORE=true ;;
        --print-output) PRINT_OUTPUT=true ;;
        *) echo "Usage: $0 [--trollstore] [--print-output]" >&2; exit 2 ;;
    esac
done
VERSION="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$IOS/Henge/Info.plist")"
BUILD="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleVersion' "$IOS/Henge/Info.plist")"
if [[ ! "$VERSION" =~ '^[0-9]+(\.[0-9]+){1,2}$' || ! "$BUILD" =~ '^[0-9]+$' ]]; then
    echo "Invalid version/build metadata; refusing to choose a release directory." >&2
    exit 1
fi
RELEASE_ROOT="${HENGE_RELEASE_ROOT:-$HOME/Downloads/iPac-Releases}"
RELEASE_DIR="$RELEASE_ROOT/v${VERSION}-build${BUILD}"
EXT=ipa
[ "$TROLLSTORE" = true ] && EXT=tipa
OUT="${HENGE_IPA_OUT:-$RELEASE_DIR/iPac-v${VERSION}-build${BUILD}.${EXT}}"
OUT="${OUT:a}"
RELEASE_DIR="${RELEASE_DIR:a}"
if [ "$PRINT_OUTPUT" = true ]; then
    printf '%s\n' "$OUT"
    exit 0
fi
[ -d "$IOS/deps/StikJIT.xcframework" ] || "$IOS/scripts/fetch_deps.sh"
cd "$IOS"
xcodegen generate >/dev/null
DD="$IOS/build/DerivedData"
mkdir -p "$IOS/build"
xcodebuild -project Henge.xcodeproj -scheme Henge -configuration Release -sdk iphoneos -destination 'generic/platform=iOS' \
    -derivedDataPath "$DD" CODE_SIGNING_ALLOWED=NO CODE_SIGNING_REQUIRED=NO CODE_SIGN_IDENTITY="" build > "$DD.buildlog" 2>&1 || {
    # Never package what an older build left behind.
    grep -E "error:|BUILD" "$DD.buildlog" | sort -u
    echo "==> the build failed; nothing packaged" >&2
    exit 1
}
grep -E "BUILD" "$DD.buildlog" || true
APP="$DD/Build/Products/Release-iphoneos/Henge.app"
rc=0
for f in "$APP/Henge" "$APP/henge-jit.js" "$APP/PlugIns/HengeJITHelper.appex/HengeJITHelper" \
         "$APP/Frameworks/StikJIT.framework/StikJIT" "$APP/Frameworks/StikJIT.framework/Info.plist"; do
    if [ -f "$f" ]; then printf "  ok       %s\n" "${f#$APP/}"; else echo "  MISSING  ${f#$APP/}" >&2; rc=1; fi
done
[ $rc -eq 0 ] || { echo "==> bundle is not installable; refusing to package" >&2; exit 1; }

mkdir -p "${OUT:h}"
STAGE="$(mktemp -d "${OUT:h}/.ipac-stage.XXXXXX")"
trap 'rm -rf "$STAGE"' EXIT
mkdir -p "$STAGE/Payload"
cp -R "$APP" "$STAGE/Payload/"
xattr -cr "$STAGE" 2>/dev/null || true
ENT="$STAGE/entitlements.plist"
# HENGE_ENTITLEMENTS picks another file, as for xcodebuild (Henge/Henge.personal.entitlements for a free team).
cp "$IOS/${HENGE_ENTITLEMENTS:-Henge/Henge.entitlements}" "$ENT"
BANNED_KEYS=("com.apple.private.cs.debugger" "dynamic-codesigning" "com.apple.private.skip-library-validation")
if [ "$TROLLSTORE" = true ]; then for k in "${BANNED_KEYS[@]}"; do plutil -remove "$k" "$ENT" 2>/dev/null || true; done; fi
SAPP="$STAGE/Payload/Henge.app"
plutil -insert HengeBuildCommit -string "$(git -C "$IOS/.." rev-parse --short=12 HEAD 2>/dev/null || echo unknown)" "$SAPP/Info.plist"
plutil -insert HengeBuildDate -string "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$SAPP/Info.plist"
# Apple's boot ROM is fetched on the device (BootROM.swift) and must never ship. An older build folder can still
# hold a copy from when the app bundled it, so it goes, and nothing is packaged if any is left.
rm -f "$SAPP/AVPBooter.vmapple2.bin"
if [ -n "$(find "$STAGE" -iname 'AVPBooter*' -o -iname 'AVPSEPBooter*')" ]; then
  echo "Apple's boot ROM is in the app: not packaging." >&2
  exit 1
fi
sign() { xattr -cr "${@[-1]}" 2>/dev/null || true; codesign --force --sign - --timestamp=none "$@"; }
for fw in "$SAPP"/Frameworks/*.framework; do [ -d "$fw" ] && sign "$fw"; done
for ex in "$SAPP"/PlugIns/*.appex; do [ -d "$ex" ] && sign "$ex"; done
sign --entitlements "$ENT" "$SAPP"
EMBEDDED=$(codesign -d --entitlements - "$SAPP" 2>&1 || true)
# Every key the entitlements file asks for must be in the signature.
for k in $(plutil -convert json -o - "$ENT" | python3 -I -c 'import json, sys; print(" ".join(json.load(sys.stdin)))'); do
    grep -q "$k" <<< "$EMBEDDED" || { echo "==> $k did not embed; refusing to package" >&2; exit 1; }
done
( cd "$STAGE" && zip -qry "$STAGE/package.tmp" Payload )
if [[ "${OUT:h}" == "$RELEASE_DIR" ]]; then
    NOTES="$IOS/../docs/releases/v${VERSION}-build${BUILD}.md"
    if [ -f "$NOTES" ]; then
        cp "$NOTES" "$STAGE/README.md"
    else
        printf '# iPac v%s (Build %s)\n\nSource commit: `%s`.\n\nNo version-specific change notes were available at packaging time. Consult the GitHub release and source history for verified changes.\n' \
            "$VERSION" "$BUILD" "$(git -C "$IOS/.." rev-parse --short=12 HEAD 2>/dev/null || echo unknown)" > "$STAGE/README.md"
    fi
fi
mv -f "$STAGE/package.tmp" "$OUT" # atomic: a half-written IPA never sits where the good one was
[ -f "$STAGE/README.md" ] && mv -f "$STAGE/README.md" "$RELEASE_DIR/README.md"
echo "==> $OUT ($(du -h "$OUT" | cut -f1))"
