#!/bin/zsh
# Copies the prebuilt iOS pieces Henge links into ios/deps (not in git):
#   StikJIT.xcframework   Built-in StikJIT (MPL-2.0), as Husk vendors it
#   libhusk_rppairing.a   on-device pairing (Husk's src/rppairing-ios, scripts/build_rppairing_ios.sh)
#   libslirp, glib, intl, pcre2 (arm64 iOS static libraries, Husk's scripts/build_ios.sh)
set -e
IOS="$(cd "$(dirname "$0")/.." && pwd)"
DEPS="$IOS/deps"
SIBLING="$IOS/../../Husk"
if [[ -z "$HUSK" && -f "$SIBLING/build/ios-arm64/sysroot/include/slirp/libslirp.h" ]]; then HUSK="$SIBLING"; fi
HUSK=${HUSK:-$HOME/Documents/Coding/Husk}
SLIRP="$HUSK/build/ios-arm64/sysroot/include/slirp"
for f in "$SLIRP/libslirp.h" "$SLIRP/libslirp-version.h"; do
    [[ -s "$f" ]] || { echo "Missing iOS dependency: $f" >&2; exit 1; }
done
mkdir -p "$DEPS/lib" "$DEPS/include/slirp"
cp "$SLIRP/libslirp.h" "$SLIRP/libslirp-version.h" "$DEPS/include/slirp/"
rm -rf "$DEPS/StikJIT.xcframework"
ditto "$HUSK/src/app/Frameworks/StikJIT.xcframework" "$DEPS/StikJIT.xcframework"
cp "$HUSK/build/ios-arm64/lib/libhusk_rppairing.a" "$DEPS/lib/"
for l in libslirp libglib-2.0 libintl libpcre2-8; do cp "$HUSK/build/ios-arm64/sysroot/lib/$l.a" "$DEPS/lib/"; done
echo "deps in $DEPS"
