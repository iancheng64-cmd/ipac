import Foundation

enum Device {
    static let maxDisplayRefreshHz = 60
}

enum HengeLog {
    static func log(_ category: String, _ message: String) {}
}

@main
struct EngineTuningTests {
    static func main() throws {
        let suite = "com.henge.tests.tuning.\(UUID().uuidString)"
        let preferences = UserDefaults(suiteName: suite)!
        let documents = FileManager.default.temporaryDirectory
            .appendingPathComponent("ipac-tuning-test-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: documents, withIntermediateDirectories: true)
        defer {
            preferences.removePersistentDomain(forName: suite)
            try? FileManager.default.removeItem(at: documents)
        }
        var checks = 0
        func expect(_ condition: @autoclosure () -> Bool, _ message: String) {
            precondition(condition(), message)
            checks += 1
        }
        func environment(_ key: String) -> String? {
            getenv(key).map { String(cString: $0) }
        }

        setenv("HV_RAM_TEST_SENTINEL", "over-physical-memory", 1)
        EngineTuning.apply(defaults: preferences, documents: documents)
        expect(environment("HV_COMPACT_JIT_METADATA") == "0", "Compact metadata is opt-in")
        expect(environment("HV_RAM_TEST_SENTINEL") == "over-physical-memory",
               "Metadata settings preserve unrelated environment entries")
        expect(environment("HV_HZ") == "60", "Unchanged refresh defaults")

        preferences.set(true, forKey: EngineTuning.compactJitMetadataKey)
        EngineTuning.apply(defaults: preferences, documents: documents)
        expect(environment("HV_COMPACT_JIT_METADATA") == "1", "The option reaches the engine")
        preferences.set(false, forKey: EngineTuning.compactJitMetadataKey)
        EngineTuning.apply(defaults: preferences, documents: documents)
        expect(environment("HV_COMPACT_JIT_METADATA") == "0", "Disabling clears a previous enable")

        preferences.set(true, forKey: EngineTuning.compactJitMetadataKey)
        try "HV_COMPACT_JIT_METADATA=0\n".write(
            to: documents.appendingPathComponent("henge-env.txt"), atomically: true, encoding: .utf8
        )
        EngineTuning.apply(defaults: preferences, documents: documents)
        expect(environment("HV_COMPACT_JIT_METADATA") == "0", "Existing explicit env overrides still win")
        expect(preferences.bool(forKey: EngineTuning.compactJitMetadataKey),
               "Overrides do not rewrite the saved preference")
        expect(environment("HV_RAM_TEST_SENTINEL") == "over-physical-memory",
               "Enabling also preserves unrelated environment entries")

        print("Engine tuning: \(checks) checks passed")
    }
}
