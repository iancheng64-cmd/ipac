#!/bin/sh
set -u

usage() {
    printf '%s\n' \
        'Usage: sh probe.sh [--fixture-root ABSOLUTE_DIRECTORY]' \
        'Read-only iPhone 7 / iOS 15 environment diagnostics; not a USB disk driver.'
}

fs_root=
fixture_mode=false
case $# in
    0) ;;
    1)
        case "$1" in
            --help|-h) usage; exit 0 ;;
            *) usage >&2; exit 64 ;;
        esac
        ;;
    2)
        if [ "$1" != --fixture-root ]; then
            usage >&2
            exit 64
        fi
        case "$2" in
            /*) ;;
            *) printf '%s\n' 'Fixture root must be an absolute directory.' >&2; exit 64 ;;
        esac
        if [ "$2" = / ] || [ ! -d "$2" ]; then
            printf '%s\n' 'Fixture root must exist and must not be the system root.' >&2
            exit 64
        fi
        fs_root=${2%/}
        fixture_mode=true
        ;;
    *) usage >&2; exit 64 ;;
esac

# These public identifiers are restricted to JSON-safe characters.
identifier() {
    case "$1" in
        ''|*[!A-Za-z0-9,._-]*) printf '%s' unknown ;;
        *) printf '%s' "$1" ;;
    esac
}

version() {
    case "$1" in
        ''|*[!0-9.]*|.*|*.|*..*) printf '%s' unknown ;;
        *) printf '%s' "$1" ;;
    esac
}

path_present() {
    for probe_path in "$@"; do
        if [ -e "$fs_root$probe_path" ]; then
            return 0
        fi
    done
    return 1
}

binary_present() {
    for probe_path in "$@"; do
        if [ -x "$fs_root$probe_path" ]; then
            return 0
        fi
    done
    return 1
}

raw_platform=$(uname -s 2>/dev/null) || raw_platform=
platform=$(identifier "$raw_platform")
raw_machine=$(sysctl -n hw.machine 2>/dev/null) || raw_machine=
hardware=$(identifier "$raw_machine")
uid_value=$(id -u 2>/dev/null) || uid_value=
case "$uid_value" in
    ''|*[!0-9]*|0[0-9]*) uid_value=null ;;
esac

ios_version=unknown
ios_version_source=unavailable
plist=$fs_root/System/Library/CoreServices/SystemVersion.plist
if [ "$platform" = Darwin ] && [ -f "$plist" ]; then
    if command -v plutil >/dev/null 2>&1; then
        raw_version=$(plutil -extract ProductVersion raw -o - "$plist" 2>/dev/null) || raw_version=
        ios_version=$(version "$raw_version")
    fi
    if [ "$ios_version" = unknown ]; then
        for buddy in /usr/libexec/PlistBuddy /var/jb/usr/libexec/PlistBuddy; do
            if [ -x "$fs_root$buddy" ]; then
                raw_version=$("$fs_root$buddy" -c 'Print :ProductVersion' "$plist" 2>/dev/null) || raw_version=
                ios_version=$(version "$raw_version")
                if [ "$ios_version" != unknown ]; then
                    break
                fi
            fi
        done
    fi
    if [ "$ios_version" != unknown ]; then
        ios_version_source=system-version-plist
    fi
fi

rootless_marker=false
rootful_marker=false
ssh_binary_present=false
sftp_binary_present=false
dropbear_binary_present=false
if [ "$platform" = Darwin ]; then
    if path_present /var/jb; then
        rootless_marker=true
    fi
    if path_present /Library/MobileSubstrate /usr/lib/libsubstrate.dylib /Applications/Cydia.app; then
        rootful_marker=true
    fi
    if binary_present /usr/sbin/sshd /var/jb/usr/sbin/sshd; then
        ssh_binary_present=true
    fi
    if binary_present /usr/libexec/sftp-server /var/jb/usr/libexec/sftp-server; then
        sftp_binary_present=true
    fi
    if binary_present /usr/sbin/dropbear /usr/bin/dropbear /var/jb/usr/sbin/dropbear /var/jb/usr/bin/dropbear; then
        dropbear_binary_present=true
    fi
fi

bootstrap=unknown
case "$rootless_marker:$rootful_marker" in
    true:false) bootstrap=rootless-marker-present ;;
    false:true) bootstrap=rootful-marker-present ;;
    true:true) bootstrap=mixed-markers ;;
esac

target_match=false
target_status=unsupported-platform
if [ "$platform" = Darwin ]; then
    case "$hardware" in
        iPhone9,1|iPhone9,3)
            case "$ios_version" in
                15|15.*) target_match=true; target_status=model-and-os-match ;;
                unknown) target_status=unverified-os ;;
                *) target_status=unsupported-os ;;
            esac
            ;;
        unknown) target_status=unverified-hardware ;;
        *) target_status=unsupported-model ;;
    esac
fi

printf '{\n'
printf '  "schema": "ipac-iphone-storage-probe/v1",\n'
printf '  "read_only": true,\n'
printf '  "fixture_mode": %s,\n' "$fixture_mode"
printf '  "platform": "%s",\n' "$platform"
printf '  "hardware": "%s",\n' "$hardware"
printf '  "ios_version": "%s",\n' "$ios_version"
printf '  "ios_version_source": "%s",\n' "$ios_version_source"
printf '  "uid": %s,\n' "$uid_value"
printf '  "iphone7_ios15_match": %s,\n' "$target_match"
printf '  "target_status": "%s",\n' "$target_status"
printf '  "jailbreak_bootstrap": "%s",\n' "$bootstrap"
printf '  "jailbreak_tool": "unknown",\n'
printf '  "jailbreak_detection": "markers-only",\n'
printf '  "ssh_binary_at_known_path": %s,\n' "$ssh_binary_present"
printf '  "sftp_binary_at_known_path": %s,\n' "$sftp_binary_present"
printf '  "dropbear_binary_at_known_path": %s,\n' "$dropbear_binary_present"
printf '  "server_running_state": "not-checked",\n'
printf '  "usb_mass_storage_capability": "unverified",\n'
printf '  "usb_mass_storage_driver": "not-implemented",\n'
printf '  "storage_export_started": false,\n'
printf '  "changes_made": false\n'
printf '}\n'
