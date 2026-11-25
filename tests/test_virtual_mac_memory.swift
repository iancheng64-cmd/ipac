import Darwin
import Foundation

enum Device {
    static var maxCPUCount = 8
    static let maxEngineCPUs = 8
    static let maxSafeCPUs = 4
    static let adaptiveGuestRAMMB = 7644
    static let physicalMemoryGB = 7
    static let name = "test host"
    static let isPad = true
    static let fittingScreen = (width: 1920, height: 1080)
    static let retinaScreen = (width: 2560, height: 1440)
}

enum Machines {
    static let root = FileManager.default.temporaryDirectory.appendingPathComponent("henge-memory-regression-\(UUID().uuidString)")
    static func isAvailable(_ mac: VirtualMac) -> Bool { true }
    static func directory(for mac: VirtualMac) -> URL { root.appendingPathComponent(mac.id.uuidString) }
}

enum ExternalInstallStorage {
    static var freeBytes: Int64 = 64 << 30
    static func volumeFreeBytes(at url: URL) -> Int64 { freeBytes }
}

enum HengeLog {
    static func log(_ category: String, _ message: String) {}
}

private enum EngineFixture {
    static var releaseCalls = 0
    static var footprintCalls = 0
    static var mappingCalls = 0
    static var noFootprint: Int32 = 1
    static var largestMapping: UInt64 = 65_536
}

func henge_ios_release_high_hold() { EngineFixture.releaseCalls += 1 }
func henge_vm_can_no_footprint() -> Int32 {
    EngineFixture.footprintCalls += 1
    return EngineFixture.noFootprint
}
func henge_largest_mapping_mb() -> UInt64 {
    EngineFixture.mappingCalls += 1
    return EngineFixture.largestMapping
}

private struct MemoryCheckFailure: Error, CustomStringConvertible {
    let description: String
}

@main
struct VirtualMacMemoryTests {
    private static var checks = 0

    private static func check(_ condition: @autoclosure () -> Bool, _ text: String) throws {
        checks += 1
        if !condition() { throw MemoryCheckFailure(description: text) }
    }

    private static func mac(ramMB: Int = 3072, cpus: Int = 8, automatic: Bool = true) -> VirtualMac {
        VirtualMac(
            name: "fixture Mac", ecid: 123, seed: 0, ramMB: ramMB, diskBytes: 64 << 30,
            externalFolderBookmark: Data([1]), autoAdaptToHost: automatic, cpuCount: cpus
        )
    }

    static func main() throws {
        let previousFile = getenv("HV_RAM_FILE").map { String(cString: $0) }
        defer {
            try? FileManager.default.removeItem(at: Machines.root)
            if let previousFile { setenv("HV_RAM_FILE", previousFile, 1) }
            else { unsetenv("HV_RAM_FILE") }
        }

        let advice = GuestRAMBudget(physicalMemoryBytes: 7644 << 20, jitCacheMB: 1024)
        try check(advice.allPhysicalRAMMB == 7644, "Full physical RAM is exact, not a 512 MB aligned budget")
        try check(advice.notice(for: 7644)?.isHighRisk == true, "Full physical RAM has an advisory warning")
        for value in [1024, 3072, 3073, 7644, 8192, 12288, 16384] {
            try check(GuestRAMBudget.isValidPortableRAMMB(value), "Legal portable RAM \(value)")
        }
        for value in [Int.min, -1, 0, 1023, 16385, Int.max] {
            try check(!GuestRAMBudget.isValidPortableRAMMB(value), "Illegal portable RAM \(value)")
        }

        var cpuOnly = mac()
        cpuOnly.overrideCPUCount(6)
        try check(cpuOnly.ramMB == 7644 && cpuOnly.effectiveRAMMB == 7644, "Auto CPU-only override preserves current full RAM")
        try check(cpuOnly.cpuCount == 6 && !cpuOnly.adaptsToHost, "CPU override becomes an explicit manual configuration")
        var ramOnly = mac()
        ramOnly.overrideRAMMB(12288)
        try check(ramOnly.ramMB == 12288 && ramOnly.effectiveRAMMB == 12288, "Manual high RAM is retained without a host clamp")
        try check(ramOnly.cpuCount == 4 && ramOnly.effectiveCPUs == 4, "Auto RAM-only override freezes the effective CPU count")
        Device.maxCPUCount = 4
        var manualRAM = mac(ramMB: 12288, cpus: 8, automatic: false)
        manualRAM.overrideRAMMB(8192)
        try check(manualRAM.cpuCount == 8 && manualRAM.effectiveCPUs == 4, "Manual RAM override preserves a portable stored CPU count above the current host cap")
        var manualCPU = mac(ramMB: 12288, automatic: false)
        manualCPU.overrideCPUCount(2)
        try check(manualCPU.ramMB == 12288 && manualCPU.effectiveRAMMB == 12288, "Manual CPU override does not alter stored RAM")
        var invalidOverride = mac()
        let beforeInvalid = invalidOverride
        invalidOverride.overrideRAMMB(-1)
        invalidOverride.overrideCPUCount(0)
        try check(invalidOverride == beforeInvalid, "Invalid overrides leave the configuration untouched")
        Device.maxCPUCount = 8

        let decoder = JSONDecoder()
        for selectedRAM in [1536, 7644, 12288] {
            let configured = mac(ramMB: selectedRAM, automatic: false)
            let reopened = try decoder.decode(VirtualMac.self, from: JSONEncoder().encode(configured))
            try check(!reopened.adaptsToHost, "An explicit installation configuration survives reopening")
            try check(reopened.effectiveRAMMB == selectedRAM, "Reopening retains selected RAM \(selectedRAM) instead of the host's RAM")
        }
        var optedIn = mac(ramMB: 1536, automatic: false)
        optedIn.autoAdaptToHost = true
        try check(optedIn.effectiveRAMMB == 7644, "Host adaptation remains available when explicitly enabled")
        for value in [1024, 3073, 7644, 12288, 16384] {
            let manifest = try decoder.decode(PortableMachineManifest.self, from: Data("{\"ecid\":123,\"ramMB\":\(value)}".utf8))
            try check(manifest.hasValidRAM, "Valid legacy manifest RAM \(value) is not rewritten or rejected")
            try check(manifest.ramMB == value, "Manifest retains its exact saved RAM \(value)")
        }
        for value in [-1, 0, 1023, 16385] {
            let manifest = try decoder.decode(PortableMachineManifest.self, from: Data("{\"ecid\":123,\"ramMB\":\(value)}".utf8))
            try check(!manifest.hasValidRAM, "Invalid manifest RAM \(value) is rejected")
        }
        let legacy = try decoder.decode(PortableMachineManifest.self, from: Data("{\"ecid\":123}".utf8))
        try check(legacy.hasValidRAM && legacy.ramMB == nil, "A legacy manifest without RAM remains compatible")

        for value in [Int.min, -1, 0, 1023, 16385, Int.max] {
            let calls = EngineFixture.releaseCalls + EngineFixture.footprintCalls + EngineFixture.mappingCalls
            try check(GuestMemory.prepare(mac(), requestedRAMMB: value) == 0, "Invalid guest RAM fails without an unsigned conversion trap")
            try check(EngineFixture.releaseCalls + EngineFixture.footprintCalls + EngineFixture.mappingCalls == calls, "Invalid RAM is rejected before engine or mapping calls")
            try check(GuestMemory.lastFailure != nil, "Invalid RAM explains the startup failure")
        }
        try check(!FileManager.default.fileExists(atPath: Machines.root.path), "Invalid RAM does not create backing storage")
        try check(GuestMemory.prepare(mac()) == 7644, "Automatic full physical RAM is not rounded down to 7168")
        try check(GuestMemory.lastFailure == nil, "A valid startup resets an earlier failure")
        try check(GuestMemory.prepare(mac(ramMB: 16384, automatic: false)) == 16384, "Legal RAM exceeding host physical memory is allowed")
        try check(GuestMemory.prepare(mac(ramMB: 3073, automatic: false)) == 3073, "A legal non-aligned manual RAM value is exact")
        ExternalInstallStorage.freeBytes = 1 << 20
        try check(GuestMemory.prepare(mac()) == 7644, "No-footprint mapping does not apply disk backing or safe-budget quotas")
        EngineFixture.noFootprint = 0
        ExternalInstallStorage.freeBytes = 4 << 30
        try check(GuestMemory.prepare(mac(ramMB: 3072, automatic: false)) == 0, "Insufficient technical disk backing fails instead of lowering RAM")
        try check(GuestMemory.lastFailure?.contains("備援檔") == true, "Disk backing failure is explicit")
        EngineFixture.noFootprint = 1
        EngineFixture.largestMapping = 8000
        try check(GuestMemory.prepare(mac()) == 0, "Insufficient contiguous mapping fails instead of lowering RAM")
        try check(GuestMemory.lastFailure?.contains("映射") == true, "Mapping failure is explicit")
        EngineFixture.largestMapping = 7644 + 512
        try check(GuestMemory.prepare(mac()) == 7644, "An exact fitting mapping keeps the requested RAM")
        print("Virtual Mac and guest memory: \(checks) checks passed")
    }
}
