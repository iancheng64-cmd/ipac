#!/usr/bin/env bash
set -euo pipefail

root="$(cd "$(dirname "$0")/.." && pwd)"
fixture="$(mktemp -d)"
trap 'rm -r -- "$fixture"' EXIT
export HOME="$fixture/home" BITRISE_DEPLOY_DIR="$fixture/deploy"
export HENGE_IPA_OUT="$fixture/new release/iPac-fixture.ipa"
mkdir -p "$HOME/Desktop" "$BITRISE_DEPLOY_DIR" "${HENGE_IPA_OUT%/*}" "$fixture/project/ios/scripts"
printf 'old desktop artifact' > "$HOME/Desktop/Henge.ipa"
archive="$BITRISE_DEPLOY_DIR/Henge-color-fix-unsigned.zip"
zip -q -j "$archive" "$HOME/Desktop/Henge.ipa"

cd "$fixture/project"
cat > ios/scripts/package_ipa.sh <<'SH'
#!/bin/sh
case "${1:-}" in
  --print-output) printf '%s\n' "$HENGE_IPA_OUT" ;;
  '') printf 'current build' > "$HENGE_IPA_OUT" ;;
  *) exit 2 ;;
esac
SH
chmod +x ios/scripts/package_ipa.sh
# Run just the CI packaging step, substituting the expensive iOS build.
sed -n '/^\.\/ios\/scripts\/package_ipa\.sh$/,$p' "$root/ci/build-bitrise.sh" | bash -eu
[[ "$(unzip -Z1 "$archive")" == "${HENGE_IPA_OUT##*/}" ]]
unzip -p "$archive" | cmp - "$HENGE_IPA_OUT"
echo 'Bitrise archived the new IPA only, replacing stale output.'
