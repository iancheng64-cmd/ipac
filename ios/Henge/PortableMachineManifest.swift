import Foundation

/// Optional additions preserve compatibility with older machine.json files.
struct PortableMachineManifest: Codable {
    var id: UUID?
    var name: String?
    var ecid: UInt64
    var seed: UInt64?
    var ramMB: Int?
    var cpuCount: Int?
    var diskBytes: Int64?
    var osName: String?
    var lastUsed: Date?
    var reportHostIdentity: Bool?
    var portableAutoAdapt: Bool?

    var hasValidRAM: Bool { ramMB.map(GuestRAMBudget.isValidPortableRAMMB) ?? true }
}
