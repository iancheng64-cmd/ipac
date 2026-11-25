import Foundation

/// A Mac's portable identity and saved hardware configuration.
struct VirtualMac: Identifiable, Codable, Hashable {
    var id = UUID()
    var name: String
    var ecid: UInt64
    var seed: UInt64
    var ramMB: Int
    var diskBytes: Int64
    var added = Date()
    var osName: String?
    var lastUsed: Date?
    var screenWidth: Int?
    var screenHeight: Int?
    var retina: Bool?
    var reportHostIdentity: Bool?
    var reportHostModelID: Bool?
    var externalFolderBookmark: Data?
    var externalDriveName: String?
    var autoAdaptToHost: Bool?
    var externalRelativePath: String?
    var cpuCount: Int?

    var isExternal: Bool { externalFolderBookmark != nil }
    var adaptsToHost: Bool { autoAdaptToHost ?? isExternal }
    var effectiveRAMMB: Int { adaptsToHost ? Device.adaptiveGuestRAMMB : ramMB }
    var configuredCPUs: Int {
        if let cpuCount { return max(1, min(Device.maxEngineCPUs, cpuCount)) }
        let legacy = UserDefaults.standard.integer(forKey: "henge.cpus")
        let fallback = legacy > 0 ? legacy : min(4, Device.maxCPUCount)
        return max(1, min(Device.maxEngineCPUs, fallback))
    }
    var effectiveCPUs: Int {
        let cap = adaptsToHost ? Device.maxSafeCPUs : Device.maxCPUCount
        return max(1, min(configuredCPUs, cap))
    }
    mutating func overrideRAMMB(_ value: Int) {
        guard GuestRAMBudget.isValidPortableRAMMB(value) else { return }
        freezeEffectiveHardware()
        ramMB = value
    }
    mutating func overrideCPUCount(_ value: Int) {
        guard value > 0 else { return }
        freezeEffectiveHardware()
        cpuCount = max(1, min(Device.maxCPUCount, value))
    }
    private mutating func freezeEffectiveHardware() {
        if adaptsToHost {
            let currentRAM = effectiveRAMMB
            let currentCPUs = effectiveCPUs
            ramMB = currentRAM
            cpuCount = currentCPUs
        }
        autoAdaptToHost = false
    }
    var isAvailable: Bool { Machines.isAvailable(self) }
    var locationLabel: String { isExternal ? (externalDriveName ?? "外接硬碟") : "此 \(Device.name)" }
    var isRetina: Bool { Device.isPad && (retina ?? false) }
    var screen: (width: Int, height: Int) {
        if isRetina { return Device.retinaScreen }
        if adaptsToHost { return Device.fittingScreen }
        return (screenWidth ?? 1920, screenHeight ?? 1080)
    }
    var aspect: CGFloat { CGFloat(screen.width) / CGFloat(screen.height) }

    var directory: URL { Machines.directory(for: self) }
    var rom: URL { directory.appendingPathComponent("AVPBooter.vmapple2.bin") }
    var disk: URL { directory.appendingPathComponent("disk.img") }
    var aux: URL { directory.appendingPathComponent("auxiliary.bin") }
}
