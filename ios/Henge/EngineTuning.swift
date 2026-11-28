import Foundation

/// Engine settings, without a rebuild. Defaults below, then the Performance settings,
/// then Documents/henge-env.txt (KEY=VALUE per line, # comments; {Documents} in a value is that folder) overrides them all.
/// Applied at launch and again before each Mac starts, so changes need no relaunch.
enum EngineTuning {
    static let refreshKey = "henge.perf.hz"
    static let superblocksKey = "henge.perf.superblocks"
    static let wfiSpinKey = "henge.perf.wfiSpin"
    static let fastFlushKey = "henge.perf.fastFlush"
    static let pCoreQosKey = "henge.perf.pCoreQos"
    static let compactJitMetadataKey = "henge.perf.compactJitMetadata"

    static let defaults: [String: String] = [
        // 60, not 120: every frame macOS draws is emulated and replayed, so 120 Hz
        // halves the CPU left for apps for animation few will notice.
        "HV_HZ": "60",         // the refresh rate macOS is told its display has
        "HV_WFI_SPIN": "0",    // microseconds an idle CPU watches for work before sleeping
        "HV_SYNC_WAIT": "2",   // park long inter-CPU waits under serious or critical host heat pressure
        "HV_FLUSH": "2",       // disk flush: F_BARRIERFSYNC, ordered but without a full fsync
        "HV_QOS": "init",      // leave interactive priority to input and presentation by default
        "HV_STATS": "0",       // detailed CPU/MMU profiling adds work per event; opt in via henge-env.txt
    ]

    static func apply(defaults d: UserDefaults = .standard, documents: URL? = nil) {
        var env = defaults
#if os(iOS)
        let defaultCompact = ProcessInfo.processInfo.physicalMemory < (10_000 << 20)
        let compactOn = (d.object(forKey: compactJitMetadataKey) as? Bool) ?? defaultCompact
        env["HV_COMPACT_JIT_METADATA"] = compactOn ? "1" : "0"
#else
        env["HV_COMPACT_JIT_METADATA"] = d.bool(forKey: compactJitMetadataKey) ? "1" : "0"
#endif
        if [30, 120].contains(d.integer(forKey: refreshKey)) {
            let requestedHz = d.integer(forKey: refreshKey)
            if requestedHz == 120 && Device.maxDisplayRefreshHz < 120 {
                env["HV_HZ"] = "60"
                HengeLog.log("tuning", "HV_HZ capped to 60 for this \(Device.maxDisplayRefreshHz) Hz display")
            } else {
                env["HV_HZ"] = String(requestedHz)
            }
        }
        if (d.object(forKey: superblocksKey) as? Bool) ?? true { env["HV_SUPERBLOCKS"] = "1" } else { unsetenv("HV_SUPERBLOCKS") }
#if os(iOS)
        if d.bool(forKey: wfiSpinKey) {
            env["HV_WFI_SPIN"] = "50"
        } else if d.object(forKey: wfiSpinKey) == nil {
            env["HV_WFI_SPIN"] = "20"
        }
        if d.object(forKey: fastFlushKey) as? Bool == false { env["HV_FLUSH"] = "0" }
        else if d.object(forKey: fastFlushKey) == nil { env["HV_FLUSH"] = "1" }
#else
        if d.bool(forKey: wfiSpinKey) { env["HV_WFI_SPIN"] = "50" }
        if d.object(forKey: fastFlushKey) as? Bool == false { env["HV_FLUSH"] = "0" }
#endif
        if d.bool(forKey: pCoreQosKey) { env["HV_QOS"] = "ui" }
        let docs = documents ?? FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        // GPU command trace: on while Documents/trace-on exists (it is checked every frame, so it can be toggled live).
        env["HV_PVG_TRACE_FILE"] = docs.appendingPathComponent("trace-on").path
        let url = docs.appendingPathComponent("henge-env.txt")
        if let text = try? String(contentsOf: url, encoding: .utf8) {
            for raw in text.split(whereSeparator: \.isNewline) {
                let line = raw.split(separator: "#", maxSplits: 1, omittingEmptySubsequences: false).first.map(String.init)?
                    .trimmingCharacters(in: .whitespaces) ?? ""
                guard let eq = line.firstIndex(of: "="), eq != line.startIndex else { continue }
                // {Documents} stands for this folder: its absolute path changes when Henge is reinstalled.
                env[String(line[..<eq]).trimmingCharacters(in: .whitespaces)] = String(line[line.index(after: eq)...])
                    .trimmingCharacters(in: .whitespaces).replacingOccurrences(of: "{Documents}", with: docs.path)
            }
        }
        for (k, v) in env.sorted(by: { $0.key < $1.key }) {
            setenv(k, v, 1)
            HengeLog.log("tuning", "\(k)=\(v)")
        }
    }
}
