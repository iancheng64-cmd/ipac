#!/bin/sh
# Run in a guest or on a native Mac during the same interactive workload.
set -eu
export LC_ALL=C
case "${1-}" in
    -h|--help)
        printf '%s\n' 'Usage: sh measure_system.sh [seconds, 5..120; default 30]' \
            'During the sample: open an app, switch windows, or copy a file in Finder.' \
            'Reports delays waking this process and guest/host-local paging counters.' \
            'Does not open apps, write files, record the screen, or measure UI FPS.'
        exit 0 ;;
esac
seconds=${1-30}
case "$seconds" in ''|*[!0-9]*|????*) echo 'Expected 5..120 seconds.' >&2; exit 2;; esac
[ "$#" -le 1 ] && [ "$seconds" -ge 5 ] && [ "$seconds" -le 120 ] || { echo 'Expected 5..120 seconds.' >&2; exit 2; }

# Read vm_stat twice only. No I/O workload, permanent files or background monitors.
before=$(/usr/bin/vm_stat)
/usr/bin/osascript -l JavaScript - "$seconds" <<'JXA'
ObjC.import('Foundation');
function run(args) {
    var clock = $.NSProcessInfo.processInfo;
    function now() { return Number(clock.systemUptime); }
    var samples = [], step = 0.1, start = now(), end = start + Number(args[0]);
    while (now() < end) {
        var begin = now();
        $.NSThread.sleepForTimeInterval(step);
        samples.push(Math.max(0, (now() - begin - step) * 1000));
    }
    var elapsed = now() - start;
    samples.sort(function(a, b) { return a - b; });
    function at(q) { return Math.round(samples[Math.ceil(samples.length * q) - 1] * 10) / 10; }
    return JSON.stringify({metric:'process_wakeup_delay_ms', window_s:Math.round(elapsed * 10) / 10,
        interval_ms:100, samples:samples.length, p50:at(0.5), p95:at(0.95), worst:at(1)});
}
JXA
after=$(/usr/bin/vm_stat)
printf '%s\n' "$before" "--after--" "$after" | /usr/bin/awk -F: '
    function number(s) { gsub(/[[:space:].]/, "", s); return s ~ /^[0-9]+$/ ? s + 0 : -1 }
    $0 == "--after--" { final = 1; next }
    $1 ~ /^(Pageins|Pageouts|Swapins|Swapouts|Compressions|Decompressions)$/ {
        if (!final) { base[$1] = number($2); next }
        endval = number($2)
        if ($1 in base && base[$1] >= 0 && endval >= base[$1])
            printf "%s_pages_delta=%.0f\n", $1, endval - base[$1]
    }'
