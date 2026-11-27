#!/bin/sh
# Compare from Terminal inside the guest or on a native Mac, in a logged-in GUI.
case "${1-}" in
    -h|--help)
        printf '%s\n' \
            'Usage: sh tools/measure_app_window.sh [--check]' \
            'With no arguments, opens Calculator only if it is not already running.' \
            '--check checks the prerequisites without opening anything.' \
            'Measures launch request to first observed onscreen layer-zero window' \
            '(at least 96 x 48 points, nontransparent); not first pixels or readiness.' \
            'Keep the current desktop visible. Manually quit Calculator between runs.' \
            'Compare first launches separately from repeats under the same settings.'
        exit 0 ;;
    ""|--check) ;;
    *) printf '%s\n' 'Unknown argument; use --help.' >&2; exit 2 ;;
esac
[ "$#" -le 1 ] || { printf '%s\n' 'Too many arguments; use --help.' >&2; exit 2; }

exec /usr/bin/osascript -l JavaScript - "$@" <<'JXA'
ObjC.import('AppKit');
ObjC.import('CoreGraphics');

function run(args) {
    var id = 'com.apple.calculator';
    var ws = $.NSWorkspace.sharedWorkspace;
    var info = $.NSProcessInfo.processInfo;
    var poll = 0.05;
    var url = ws.URLForApplicationWithBundleIdentifier(id);
    if (url.isNil()) throw Error('Calculator is not installed.');

    function windows() {
        // OnScreenOnly | ExcludeDesktopElements. No screenshots or window titles.
        var list = ObjC.castRefToObject($.CGWindowListCopyWindowInfo(17, 0));
        if (list.isNil()) throw Error('WindowServer metadata is unavailable.');
        return list;
    }
    function hasWindow(pid) {
        var list = windows();
        for (var i = 0, count = Number(list.count); i < count; ++i) {
            var w = list.objectAtIndex(i);
            if (Number(w.objectForKey('kCGWindowOwnerPID').integerValue) !== pid ||
                Number(w.objectForKey('kCGWindowLayer').integerValue) !== 0 ||
                Number(w.objectForKey('kCGWindowAlpha').doubleValue) <= 0) continue;
            var b = w.objectForKey('kCGWindowBounds');
            if (Number(b.objectForKey('Width').doubleValue) >= 96 &&
                Number(b.objectForKey('Height').doubleValue) >= 48) return true;
        }
        return false;
    }
    windows();
    var running = $.NSRunningApplication.runningApplicationsWithBundleIdentifier(id);
    if (Number(running.count) !== 0)
        throw Error('Calculator is already running. Nothing was opened or closed.');
    if (args.length && args[0] === '--check')
        return 'Ready: Calculator is not running and WindowServer metadata is available.';

    var start = Number(info.systemUptime);
    var app = ws.launchApplicationAtURLOptionsConfigurationError(
        url, $.NSWorkspaceLaunchAsync, $.NSDictionary.dictionary, null);
    if (app.isNil()) throw Error('Launch Services could not open Calculator.');
    var pid = Number(app.processIdentifier);
    if (!(pid > 0)) throw Error('No Calculator process ID; no timing available.');
    do {
        if (hasWindow(pid)) {
            var elapsed = Number(info.systemUptime) - start;
            return JSON.stringify({
                metric: 'calculator_first_observed_window_ms',
                ms: Math.round(elapsed * 1000), poll_ms: Math.round(poll * 1000),
                pid: pid
            });
        }
        $.NSThread.sleepForTimeInterval(poll);
    } while (Number(info.systemUptime) - start < 60);
    throw Error('No qualifying Calculator window observed in 60 s; no timing available.');
}
JXA
