#!/bin/sh
set -eu

repo=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
probe=$repo/tools/phone_ssd/iphone/probe.sh
fixture=$repo/tests/fixtures/iphone_probe
tmp=$(mktemp -d "${TMPDIR:-/tmp}/ipac-iphone-probe-tests.XXXXXX")
cleanup() {
    if [ -d "$tmp" ]; then
        rm -r -- "$tmp"
    fi
}
trap cleanup 0 HUP INT TERM

command -v jq >/dev/null
mkdir -p "$tmp/bin"
cp "$fixture/mock_system.sh" "$tmp/mock-system"
chmod u+x "$tmp/mock-system"
for tool in uname sysctl id plutil; do
    ln -s "$tmp/mock-system" "$tmp/bin/$tool"
done

prepare_root() {
    mkdir -p "$1/System/Library/CoreServices"
    cp "$fixture/SystemVersion.plist" "$1/System/Library/CoreServices/SystemVersion.plist"
}
prepare_root "$tmp/unknown"
prepare_root "$tmp/rootless"
prepare_root "$tmp/rootful"
prepare_root "$tmp/mixed"
mkdir -p "$tmp/rootless/var/jb/usr/sbin" "$tmp/rootless/var/jb/usr/libexec"
mkdir -p "$tmp/rootful/Library/MobileSubstrate" "$tmp/rootful/usr/sbin"
mkdir -p "$tmp/mixed/var/jb" "$tmp/mixed/Library/MobileSubstrate"
ln -s "$tmp/mock-system" "$tmp/rootless/var/jb/usr/sbin/sshd"
ln -s "$tmp/mock-system" "$tmp/rootless/var/jb/usr/libexec/sftp-server"
ln -s "$tmp/mock-system" "$tmp/rootful/usr/sbin/dropbear"

MOCK_PLATFORM=Darwin
MOCK_MACHINE=iPhone9,1
MOCK_UID=501
MOCK_PLUTIL_FAIL=0
export MOCK_PLATFORM MOCK_MACHINE MOCK_UID MOCK_PLUTIL_FAIL
checks=0
failures=0
report=
run_probe() {
    report=$(PATH="$tmp/bin:$PATH" sh "$probe" --fixture-root "$1")
}
check() {
    checks=$((checks + 1))
    if ! printf '%s\n' "$report" | jq -e "$1" >/dev/null; then
        failures=$((failures + 1))
        printf '%s\n' "FAIL: $2" >&2
    fi
}

before=$(find "$tmp/rootless" -type f -exec cksum {} \;)
run_probe "$tmp/rootless"
check '.schema == "ipac-iphone-storage-probe/v1"' schema
check '.read_only and .fixture_mode and (.changes_made | not)' readonly
check '.hardware == "iPhone9,1" and .ios_version == "15.8.3"' identifiers
check '.ios_version_source == "system-version-plist" and .uid == 501' plist_and_uid
check '.iphone7_ios15_match and .target_status == "model-and-os-match"' target_match
check '.jailbreak_bootstrap == "rootless-marker-present"' rootless_marker
check '.jailbreak_tool == "unknown" and .jailbreak_detection == "markers-only"' no_tool_guess
check '.ssh_binary_at_known_path and .sftp_binary_at_known_path' known_server_binaries
check '(.dropbear_binary_at_known_path | not) and .server_running_state == "not-checked"' no_server_execution
check '.usb_mass_storage_capability == "unverified" and .usb_mass_storage_driver == "not-implemented"' no_fake_usb_driver
check '.storage_export_started | not' no_export
after=$(find "$tmp/rootless" -type f -exec cksum {} \;)
checks=$((checks + 1))
if [ "$before" != "$after" ]; then
    failures=$((failures + 1))
    printf '%s\n' 'FAIL: fixture content changed' >&2
fi

MOCK_MACHINE=iPhone9,3
MOCK_UID=0
run_probe "$tmp/rootful"
check '.iphone7_ios15_match and .uid == 0' second_iphone7_variant
check '.jailbreak_bootstrap == "rootful-marker-present" and .dropbear_binary_at_known_path' rootful_markers
check '(.ssh_binary_at_known_path | not) and (.sftp_binary_at_known_path | not)' no_host_binary_leak

run_probe "$tmp/mixed"
check '.jailbreak_bootstrap == "mixed-markers" and .jailbreak_tool == "unknown"' mixed_markers
run_probe "$tmp/unknown"
check '.jailbreak_bootstrap == "unknown"' absent_markers_unknown

MOCK_PLUTIL_FAIL=1
run_probe "$tmp/unknown"
check '.ios_version == "unknown" and .ios_version_source == "unavailable"' unavailable_parser
check '(.iphone7_ios15_match | not) and .target_status == "unverified-os"' missing_os_not_accepted
MOCK_PLUTIL_FAIL=0
MOCK_PRODUCT_VERSION=16.7.10
export MOCK_PRODUCT_VERSION
run_probe "$tmp/unknown"
check '(.iphone7_ios15_match | not) and .target_status == "unsupported-os"' different_os
MOCK_PRODUCT_VERSION='15.8.3"unsafe'
MOCK_MACHINE='iPhone9,1"unsafe'
MOCK_UID='0"unsafe'
run_probe "$tmp/unknown"
check '.hardware == "unknown" and .ios_version == "unknown" and .uid == null' json_safe_unknowns
check '.target_status == "unverified-hardware" and (.iphone7_ios15_match | not)' no_invalid_target
unset MOCK_PRODUCT_VERSION

MOCK_PLATFORM=Linux
MOCK_MACHINE=iPhone9,1
MOCK_UID=0
run_probe "$tmp/rootless"
check '.target_status == "unsupported-platform" and (.iphone7_ios15_match | not)' non_darwin
check '.jailbreak_bootstrap == "unknown" and (.ssh_binary_at_known_path | not)' non_darwin_no_ios_markers

printf 'iPhone storage probe: %s checks, %s failures\n' "$checks" "$failures"
[ "$failures" = 0 ]
