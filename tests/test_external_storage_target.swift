import Darwin
import Foundation

protocol ObservableObject {}

@propertyWrapper
struct Published<Value> {
    var wrappedValue: Value
    init(wrappedValue: Value) { self.wrappedValue = wrappedValue }
}

final class FixtureDefaults {
    static let standard = FixtureDefaults()
    private var values: [String: Any] = [:]
    func set(_ value: Any?, forKey key: String) { values[key] = value }
    func string(forKey key: String) -> String? { values[key] as? String }
    func data(forKey key: String) -> Data? { values[key] as? Data }
    func removeObject(forKey key: String) { values.removeValue(forKey: key) }
}

typealias UserDefaults = FixtureDefaults

enum Device { static let name = "test host" }
enum ByteText { static func string(_ bytes: UInt64) -> String { "\(bytes) bytes" } }
enum HengeLog { static func log(_ category: String, _ text: String) {} }

struct MacOSRelease {
    let id: String
    let url: URL
}

final class RestoreImageValidation {
    static let shared = RestoreImageValidation()
    func validatedSize(of url: URL, expectedBuild: String) -> Int64? { nil }
}

@MainActor
final class Installer {
    static let shared = Installer()
    var busy = false
}

struct VirtualMac {
    let id: UUID
    var externalDriveName: String? = "fixture drive"
    var externalRelativePath: String? = nil
    var isExternal: Bool { true }
    var directory: URL {
        ExternalDriveRegistry.shared.machineDirectory(for: id)
            ?? URL(fileURLWithPath: "/unavailable/\(id.uuidString)")
    }
    var isAvailable: Bool {
        guard let root = ExternalDriveRegistry.shared.rootFolder(for: id) else { return false }
        return MachineStorageSafety.isRegularFile(directory.appendingPathComponent("disk.img"), within: root)
    }
}

@MainActor
final class Machines {
    static let shared = Machines()
    nonisolated static var isVMRunning: Bool { false }
    var all: [VirtualMac] = []
    var isBusy = false
    func refreshExternalMachines(clearEjectedOnConfiguredDrive: Bool = false) {}
    func clearAllEjectedFlags() {}
    nonisolated static func isValidPortableFolder(_ dir: URL) -> Bool {
        MachineStorageSafety.isPortableMachineDirectory(dir)
    }
    nonisolated static func knownMachineBytes(in dir: URL) -> Int64 {
        MachineStorageSafety.knownMachineEntries.reduce(0) { total, name in
            guard let size = (try? dir.appendingPathComponent(name).resourceValues(forKeys: [.fileSizeKey]))?.fileSize else { return total }
            return total + Int64(size)
        }
    }
    nonisolated static func safelyDeleteMachineFiles(
        in dir: URL, allowRemovingDirectory: Bool, approvedRoot: URL,
        validating target: ExternalDriveTarget? = nil
    ) throws -> Int64 {
        try MachineStorageSafety.deleteMachineFiles(
            in: dir, approvedRoot: approvedRoot, allowRemovingDirectory: allowRemovingDirectory, validating: target
        )
    }
    func ejectAllExternalMacs(
        on driveURL: URL?, markAsExplicitlyEjected: Bool = true, keepURL: URL? = nil,
        onlyDirectories: Set<String>? = nil
    ) -> Int {
        let ids = all.filter { mac in
            if let onlyDirectories, !onlyDirectories.contains(ExternalDriveRegistry.canonicalPath(mac.directory)) {
                return false
            }
            guard let driveURL else { return true }
            return ExternalDriveRegistry.shared.rootFolder(for: mac.id).map {
                ExternalDriveRegistry.isSameVolumeOrPath($0, driveURL)
            } ?? false
        }.map(\.id)
        for id in ids {
            ExternalDriveRegistry.shared.unregister(id: id, releaseEvenIfMounted: true, keepURL: keepURL)
        }
        all.removeAll { ids.contains($0.id) }
        return ids.count
    }
}

private struct TargetCheckFailure: Error, CustomStringConvertible {
    let description: String
}

@main
@MainActor
struct ExternalStorageTargetTests {
    private static var checks = 0
    private static let fm = FileManager.default

    private static func check(_ condition: @autoclosure () -> Bool, _ text: String) throws {
        checks += 1
        if !condition() { throw TargetCheckFailure(description: text) }
    }

    private static func machine(in root: URL, id: UUID = UUID(), folderName: String? = nil) throws -> URL {
        let dir = root.appendingPathComponent(folderName ?? id.uuidString, isDirectory: true)
        try fm.createDirectory(at: dir, withIntermediateDirectories: true)
        for file in ["disk.img", "AVPBooter.vmapple2.bin", "auxiliary.bin"] {
            try Data("fixture bytes".utf8).write(to: dir.appendingPathComponent(file))
        }
        let manifest: [String: Any] = ["ecid": 123, "id": id.uuidString, "ramMB": 7644]
        try JSONSerialization.data(withJSONObject: manifest).write(to: dir.appendingPathComponent("machine.json"))
        return dir
    }

    static func main() async throws {
        let root = fm.temporaryDirectory.appendingPathComponent("henge-target-regression-\(UUID().uuidString)", isDirectory: true)
        try fm.createDirectory(at: root, withIntermediateDirectories: true)
        defer {
            for mac in Machines.shared.all {
                ExternalDriveRegistry.shared.unregister(id: mac.id, releaseEvenIfMounted: true)
            }
            Machines.shared.all.removeAll()
            try? fm.removeItem(at: root)
        }
        let storage = ExternalInstallStorage.shared
        let driveA = root.appendingPathComponent("SSD-A", isDirectory: true)
        let driveB = root.appendingPathComponent("SSD-B", isDirectory: true)
        let driveC = root.appendingPathComponent("other-bookmark", isDirectory: true)
        try fm.createDirectory(at: driveA, withIntermediateDirectories: true)
        let idB = UUID()
        let idDuplicate = UUID()
        let idC = UUID()
        let bMachineRoot = driveB.appendingPathComponent("HengeMachines", isDirectory: true)
        let vmB = try machine(in: bMachineRoot, id: idB)
        let vmC = try machine(in: driveC, id: idC)
        ExternalDriveRegistry.shared.register(id: idB, folderURL: driveB, relativePath: "HengeMachines/\(idB.uuidString)")
        ExternalDriveRegistry.shared.register(id: idDuplicate, folderURL: driveB, relativePath: "HengeMachines/\(idB.uuidString)")
        ExternalDriveRegistry.shared.register(id: idC, folderURL: driveC, relativePath: idC.uuidString)
        Machines.shared.all = [VirtualMac(id: idB), VirtualMac(id: idDuplicate), VirtualMac(id: idC)]

        try check(storage.selectFolder(driveA), "Fixture SSD A can be selected")
        let driveAName = storage.configuredName
        guard let oldSummary = storage.inspectHengeDataOnDrive() else {
            throw TargetCheckFailure(description: "Cannot inspect fixture SSD A")
        }
        try fm.removeItem(at: driveA)
        storage.refreshConnection()
        try check(storage.isConfigured && !storage.isConnected, "Configured SSD A becomes offline without losing its binding")
        try check(storage.effectiveDriveURL == nil, "Offline configured SSD A must not fall back to an available SSD B")
        try check(storage.effectiveDriveName == driveAName, "An offline binding still names SSD A")
        try check(storage.inspectHengeDataOnDrive() == nil, "Offline SSD A cannot produce a clearable snapshot of SSD B")
        try check(fm.fileExists(atPath: vmB.appendingPathComponent("disk.img").path), "SSD B remains untouched by inspection")

        try check(storage.selectFolder(driveB), "Fixture SSD B can be explicitly selected")
        var oldConfirmationResult: Bool?
        storage.clearAllHengeDataOnDrive(confirmed: oldSummary) { oldConfirmationResult = $0 }
        try check(oldConfirmationResult == false, "An old SSD A confirmation cannot clear selected SSD B")
        try check(fm.fileExists(atPath: vmB.appendingPathComponent("disk.img").path), "A rejected old confirmation preserves SSD B")
        guard let summaryB = storage.inspectHengeDataOnDrive() else {
            throw TargetCheckFailure(description: "Cannot inspect fixture SSD B")
        }
        try check(summaryB.machineCount == 1, "Duplicate registry entries for one VM directory are counted once")
        try check(summaryB.target != oldSummary.target, "An explicitly selected drive has a new confirmation token")
        let unknown = bMachineRoot.appendingPathComponent("Personal", isDirectory: true)
        try fm.createDirectory(at: unknown, withIntermediateDirectories: true)
        try Data("personal data".utf8).write(to: unknown.appendingPathComponent("disk.img"))
        let cleared = await withCheckedContinuation { (continuation: CheckedContinuation<Bool, Never>) in
            storage.clearAllHengeDataOnDrive(confirmed: summaryB) { continuation.resume(returning: $0) }
        }
        try check(cleared, "The current SSD B confirmation clears successfully")
        try check(!fm.fileExists(atPath: vmB.appendingPathComponent("disk.img").path), "The confirmed SSD B VM disk is removed")
        try check(fm.fileExists(atPath: unknown.appendingPathComponent("disk.img").path), "An unknown same-name personal disk is preserved")
        try check(fm.fileExists(atPath: vmC.appendingPathComponent("disk.img").path), "A VM outside the confirmed bookmark root remains on the same physical volume")
        try check(Machines.shared.all.map(\.id) == [idC], "Only successfully cleared VM entries are ejected")
        try check(ExternalDriveRegistry.shared.machineDirectory(for: idC) != nil, "An unrelated bookmark retains its VM registration")
        try check(fm.fileExists(atPath: driveB.path), "Clearing does not remove the selected SSD root")

        let activeWork = driveB.appendingPathComponent("HengeInstall/restore-\(UUID().uuidString)", isDirectory: true)
        try fm.createDirectory(at: activeWork, withIntermediateDirectories: true)
        try Data("worker data".utf8).write(to: activeWork.appendingPathComponent("payload"))
        Installer.shared.busy = true
        storage.cleanupStaleRestoreDirs(force: true)
        storage.cleanupEmptyStagingIfUnused(force: true)
        try check(fm.fileExists(atPath: activeWork.appendingPathComponent("payload").path), "A forced generic cleanup cannot remove a busy install worker's work")
        Installer.shared.busy = false
        storage.cleanupEmptyStagingIfUnused(force: true)
        try check(!fm.fileExists(atPath: activeWork.path), "Idle stale work can be cleaned within its captured authorized root")

        let detachedB = root.appendingPathComponent("detached-SSD-B", isDirectory: true)
        try fm.moveItem(at: driveB, to: detachedB)
        let replacedB = try machine(in: driveB)
        try check(storage.effectiveDriveURL == nil, "A same-path replacement cannot be silently recaptured as the selected SSD")
        try check(fm.fileExists(atPath: replacedB.appendingPathComponent("disk.img").path), "A same-path replacement remains intact")

        let registeredRoot = root.appendingPathComponent("registered-drive", isDirectory: true)
        let registeredID = UUID()
        let registeredVM = try machine(in: registeredRoot, id: registeredID)
        ExternalDriveRegistry.shared.register(id: registeredID, folderURL: registeredRoot, relativePath: registeredID.uuidString)
        defer { ExternalDriveRegistry.shared.unregister(id: registeredID, releaseEvenIfMounted: true) }
        try check(ExternalDriveRegistry.shared.driveTarget(for: registeredID) != nil, "A VM registration retains the original drive descriptor")
        let detached = root.appendingPathComponent("detached-registered-drive", isDirectory: true)
        try fm.moveItem(at: registeredRoot, to: detached)
        let replacementVM = try machine(in: registeredRoot, id: registeredID)
        try check(ExternalDriveRegistry.shared.driveTarget(for: registeredID) == nil, "A replaced drive path invalidates the registered target")
        try check(ExternalDriveRegistry.shared.machineDirectory(for: registeredID) == nil, "A replaced drive cannot masquerade as the registered VM")
        try check(fm.fileExists(atPath: replacementVM.appendingPathComponent("disk.img").path), "Registered-drive replacement is not modified")
        try check(fm.fileExists(atPath: detached.appendingPathComponent(registeredVM.lastPathComponent).appendingPathComponent("disk.img").path), "Original registered VM remains detached and intact")

        let existingID = UUID()
        let existingRoot = try machine(in: root, id: existingID, folderName: "existing-machine-root")
        let newID = UUID()
        let newDirectory = ExternalDriveRegistry.resolveMachineDirectory(in: existingRoot, for: newID)
        try check(newDirectory == existingRoot.appendingPathComponent("HengeMachines/\(newID.uuidString)", isDirectory: true), "A new VM ID cannot overwrite a picked existing machine root")
        try check(ExternalDriveRegistry.resolveMachineDirectory(in: existingRoot, for: existingID) == existingRoot, "A matching manifest ID still resolves an existing machine root")
        try check(ExternalDriveRegistry.resolveMachineDirectory(in: existingRoot, for: newID, relativePath: ".") == existingRoot, "Explicit existing portable-folder registrations stay compatible")
        let invalidID = UUID()
        ExternalDriveRegistry.shared.register(id: invalidID, folderURL: driveB, relativePath: "../Personal")
        defer { ExternalDriveRegistry.shared.unregister(id: invalidID, releaseEvenIfMounted: true) }
        try check(ExternalDriveRegistry.shared.machineDirectory(for: invalidID) == nil, "Stored parent-traversal relative paths are rejected")
        print("External storage targets: \(checks) checks passed")
    }
}
