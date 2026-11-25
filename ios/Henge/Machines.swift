import Foundation
import UIKit

/// A Mac made on the Mac (HengeVM or Henge) and brought over: its boot ROM,
/// disk and auxiliary storage, and the identity it was installed with.
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
    /// The size macOS is told its screen is. Macs made before this was a choice have none: 16:9.
    var screenWidth: Int?
    var screenHeight: Int?
    /// m4 fork: the iPad's own panel at Retina density. On by default on iPad, for Macs that never chose.
    var retina: Bool?
    /// About This Mac reports the device Henge runs on (its name and chip) instead of the
    /// virtual Mac. nil/false: the vmapple identity. Applied at the next boot.
    var reportHostIdentity: Bool?
    /// With reportHostIdentity: also report the device's model identifier (hw.model).
    /// Experimental — it may bring the device's icon, and may confuse macOS.
    var reportHostModelID: Bool?
    /// Security-scoped bookmark to the external folder holding `HengeMachines/<id>/`, or nil for internal Macs.
    var externalFolderBookmark: Data?
    /// User-visible external drive/folder name shown even when the drive is unplugged.
    var externalDriveName: String?
    /// When true (default for external Macs), automatically adapts RAM, CPU ceiling, and screen ratio to the current host.
    var autoAdaptToHost: Bool?
    /// Relative path from the bookmarked folder to the Mac's directory when stored outside standard `HengeMachines/<id>`.
    var externalRelativePath: String?
    /// Per-Mac virtual CPU count (nil = inherit legacy default until adjusted in settings).
    var cpuCount: Int?

    var isExternal: Bool { externalFolderBookmark != nil }
    var adaptsToHost: Bool { autoAdaptToHost ?? isExternal }
    var effectiveRAMMB: Int { adaptsToHost ? Device.suggestedRAMGB * 1024 : ramMB }
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

/// How much RAM a Mac gets. The engine first asks the kernel to leave it out of Henge's footprint,
/// which is allowed once a debugger has attached (how JIT is turned on). If that is refused it uses
/// a file beside the disk: iOS's memory limit does not count a mapped file's pages either.
enum GuestMemory {
    /// Points the engine at the file (it is unlinked as soon as it is open) and returns the size that fits.
    /// When `LEDGER_NO_FOOTPRINT` is available (after JIT debugger attaches), VM RAM does not count toward
    /// app footprint or consume disk backing, so internal free storage does not clamp guest RAM.
    static func prepare(_ mac: VirtualMac, requestedRAMMB: Int? = nil) -> UInt64 {
        henge_ios_release_high_hold()
        try? FileManager.default.createDirectory(at: Machines.root, withIntermediateDirectories: true)
        let file = Machines.root.appendingPathComponent("ram.tmp")
        setenv("HV_RAM_FILE", file.path, 1)
        let noFootprint = henge_vm_can_no_footprint() != 0
        let free = ExternalInstallStorage.volumeFreeBytes(at: Machines.root)
        let room: UInt64 = noFootprint
            ? UInt64.max
            : (free > 0 ? UInt64(max(free - (2 << 30), 0)) >> 20 : UInt64.max)
        let reach = henge_largest_mapping_mb()
        let headroom = reach > 512 ? reach - 512 : reach
        let rawTarget = requestedRAMMB ?? mac.effectiveRAMMB
        let targetMB = (requestedRAMMB == nil && mac.adaptsToHost)
            ? min(UInt64(rawTarget), UInt64(Device.suggestedRAMGB) * 1024)
            : UInt64(rawTarget)
        let ram = min(targetMB, room, headroom) / 512 * 512
        let roomNote = noFootprint ? "no-footprint" : "\(room) MB"
        HengeLog.log("session", "guest RAM \(ram) MB (requested \(targetMB), physical \(Device.physicalMemoryGB) GB, noFootprint \(noFootprint), autoAdapt \(mac.adaptsToHost), internal room \(roomNote), largest mapping \(reach))")
        return ram
    }
}

/// machine.json in a machine or exported folder. Optional portable fields stay backward compatible with older manifests.
private struct MachineFile: Codable {
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
}

@MainActor
final class Machines: ObservableObject {
    static let shared = Machines()

    @Published private(set) var all: [VirtualMac] = []
    @Published private(set) var importing: String?
    @Published var lastError: String?
    @Published var statusNotice: String?

    /// The files an exported machine folder holds; its disk is disk.img, or disk.img.hvsparse (tools/export_ios.sh packs it).
    nonisolated static let required = ["AVPBooter.vmapple2.bin", "auxiliary.bin", "machine.json"]
    nonisolated static let packedDisk = "disk.img.hvsparse"
    nonisolated static let knownMachineEntries = [
        "disk.img", "disk.img.hvsparse", "AVPBooter.vmapple2.bin", "auxiliary.bin",
        "machine.json", installedMarker, installingMarker, "preview.jpg",
        "resume.hsnap", "resume.hsnap.part", "restore"
    ]

    nonisolated static var isVMRunning: Bool {
        let s = henge_vm_state()
        return s == 1 || s == 3 || s == 4
    }

    nonisolated static func hasDisk(_ folder: URL) -> Bool {
        let fm = FileManager.default
        return fm.fileExists(atPath: folder.appendingPathComponent("disk.img").path)
            || fm.fileExists(atPath: folder.appendingPathComponent(packedDisk).path)
    }

    @Published private(set) var unpacked: Double = 0
    /// While a Mac is being exported: its name and how far along.
    @Published private(set) var exporting: String?
    @Published private(set) var exported: Double = 0
    /// While a Mac is being moved between this iPad and an external drive.
    @Published private(set) var moving: String?
    @Published private(set) var moved: Double = 0
    /// While a Mac's files are being safely deleted.
    @Published private(set) var deleting: String?
    /// The last finished export, ready to be moved out of Henge.
    @Published var lastExport: URL?

    var isBusy: Bool {
        moving != nil || exporting != nil || importing != nil || deleting != nil || Installer.shared.busy
    }

    private static let ejectedIDsKey = "henge.ejectedExternalIDs"

    private var explicitlyEjectedIDs: Set<UUID> {
        get {
            let raw = UserDefaults.standard.stringArray(forKey: Self.ejectedIDsKey) ?? []
            return Set(raw.compactMap(UUID.init(uuidString:)))
        }
        set {
            UserDefaults.standard.set(newValue.map(\.uuidString), forKey: Self.ejectedIDsKey)
        }
    }

    func clearEjectedFlag(for id: UUID) {
        var ids = explicitlyEjectedIDs
        if ids.remove(id) != nil {
            explicitlyEjectedIDs = ids
        }
    }

    func clearAllEjectedFlags() {
        UserDefaults.standard.removeObject(forKey: Self.ejectedIDsKey)
    }

    private init() {
        load()
        removeLeftovers()
    }

    /// The file the installer puts in a machine's folder once macOS is on its disk (it holds the release's name).
    nonisolated static let installedMarker = "installed"
    /// Marker present only while an install is actively in progress, so unfinished installs can be cleaned safely without touching unknown SSD folders.
    nonisolated static let installingMarker = ".installing"

    nonisolated static func isValidPortableFolder(_ folder: URL) -> Bool {
        let fm = FileManager.default
        let hasCoreFiles = fm.fileExists(atPath: folder.appendingPathComponent("disk.img").path)
            && fm.fileExists(atPath: folder.appendingPathComponent("AVPBooter.vmapple2.bin").path)
            && fm.fileExists(atPath: folder.appendingPathComponent("auxiliary.bin").path)
            && fm.fileExists(atPath: folder.appendingPathComponent("machine.json").path)
        guard hasCoreFiles else { return false }
        let isInstalling = fm.fileExists(atPath: folder.appendingPathComponent(installingMarker).path)
        let isInstalled = fm.fileExists(atPath: folder.appendingPathComponent(installedMarker).path)
        return !isInstalling || isInstalled
    }

    nonisolated static func knownMachineBytes(in dir: URL) -> Int64 {
        let fm = FileManager.default
        var total: Int64 = 0
        for name in knownMachineEntries {
            let item = dir.appendingPathComponent(name)
            guard fm.fileExists(atPath: item.path) else { continue }
            var isDir: ObjCBool = false
            if fm.fileExists(atPath: item.path, isDirectory: &isDir), isDir.boolValue {
                total += ExternalInstallStorage.directoryBytes(item)
            } else {
                let vals = try? item.resourceValues(forKeys: [.totalFileAllocatedSizeKey, .fileSizeKey])
                if let allocated = vals?.totalFileAllocatedSize, allocated > 0 {
                    total += Int64(allocated)
                } else if let size = vals?.fileSize, size > 0 {
                    total += Int64(size)
                }
            }
        }
        return total
    }

    /// Removes only known Henge files in `dir`, never deleting unrelated user files or an external volume root.
    nonisolated static func safelyDeleteMachineFiles(in dir: URL, allowRemovingDirectory: Bool) throws -> Int64 {
        let fm = FileManager.default
        var freedBytes: Int64 = 0
        for name in knownMachineEntries {
            let item = dir.appendingPathComponent(name)
            guard fm.fileExists(atPath: item.path) else { continue }
            var itemBytes: Int64 = 0
            var isDir: ObjCBool = false
            if fm.fileExists(atPath: item.path, isDirectory: &isDir), isDir.boolValue {
                itemBytes = ExternalInstallStorage.directoryBytes(item)
            } else {
                let vals = try? item.resourceValues(forKeys: [.totalFileAllocatedSizeKey, .fileSizeKey])
                if let allocated = vals?.totalFileAllocatedSize, allocated > 0 {
                    itemBytes = Int64(allocated)
                } else if let size = vals?.fileSize, size > 0 {
                    itemBytes = Int64(size)
                }
            }
            do {
                try fm.removeItem(at: item)
                freedBytes += itemBytes
            } catch {
                let nsErr = error as NSError
                if nsErr.domain == NSCocoaErrorDomain && nsErr.code == NSFileNoSuchFileError { continue }
                if let posixErr = error as? POSIXError, posixErr.code == .ENOENT { continue }
                throw error
            }
        }

        let isVol = (try? dir.resourceValues(forKeys: [.isVolumeKey]))?.isVolume ?? false
        if allowRemovingDirectory && !isVol {
            let remaining = (try? fm.contentsOfDirectory(atPath: dir.path)) ?? []
            if remaining.filter({ $0 != ".DS_Store" }).isEmpty {
                try? fm.removeItem(at: dir)
                let parent = dir.deletingLastPathComponent()
                let parentIsVol = (try? parent.resourceValues(forKeys: [.isVolumeKey]))?.isVolume ?? false
                if parent.lastPathComponent == "HengeMachines", !parentIsVol,
                   let parentItems = try? fm.contentsOfDirectory(atPath: parent.path),
                   parentItems.filter({ $0 != ".DS_Store" }).isEmpty {
                    try? fm.removeItem(at: parent)
                }
            }
        }
        return freedBytes
    }

    nonisolated static func writePortableManifest(for mac: VirtualMac, in dir: URL) {
        let fm = FileManager.default
        let info = MachineFile(
            id: mac.id,
            name: mac.name,
            ecid: mac.ecid,
            seed: mac.seed,
            ramMB: mac.ramMB,
            cpuCount: mac.cpuCount,
            diskBytes: mac.diskBytes,
            osName: mac.osName,
            lastUsed: mac.lastUsed,
            reportHostIdentity: mac.reportHostIdentity,
            portableAutoAdapt: mac.autoAdaptToHost
        )
        if let data = try? JSONEncoder().encode(info) {
            try? data.write(to: dir.appendingPathComponent("machine.json"), options: .atomic)
        }
        let markerURL = dir.appendingPathComponent(installedMarker)
        let installingURL = dir.appendingPathComponent(installingMarker)
        if !fm.fileExists(atPath: markerURL.path) && !fm.fileExists(atPath: installingURL.path) {
            try? (mac.osName ?? "").write(to: markerURL, atomically: true, encoding: .utf8)
        }
    }

    /// Machine folders nothing refers to (an install cut short by a crash or by quitting): their disks take real space.
    /// A folder whose install finished (Henge stopped before it was listed) is listed again instead, and nothing is
    /// removed when the list itself could not be read: every Mac would look unreferenced.
    /// Downloads by builds before 0.3 kept a stopped download in the system's temporary files, where nothing could resume
    /// or delete it (#58): those go. Downloads now stay in Restore images as .part files and go on from there.
    private func removeOldTemporaryDownloads() {
        let tmp = URL(fileURLWithPath: NSTemporaryDirectory())
        guard let names = try? FileManager.default.contentsOfDirectory(atPath: tmp.path) else { return }
        for name in names where name.hasPrefix("CFNetworkDownload_") && name.hasSuffix(".tmp") {
            try? FileManager.default.removeItem(at: tmp.appendingPathComponent(name))
        }
    }

    private func removeLeftovers() {
        removeOldTemporaryDownloads()
        if listUnreadable {
            HengeLog.log("machines", "the list of Macs could not be read: no machine folder is removed")
            return
        }
        let known = Set(all.map(\.id))
        let fm = FileManager.default
        let items = (try? fm.contentsOfDirectory(at: Self.root, includingPropertiesForKeys: nil)) ?? []
        for item in items {
            guard let id = UUID(uuidString: item.lastPathComponent), !known.contains(id) else { continue }
            let marker = item.appendingPathComponent(Self.installedMarker)
            if fm.fileExists(atPath: marker.path), let data = try? Data(contentsOf: item.appendingPathComponent("machine.json")),
               let info = try? JSONDecoder().decode(MachineFile.self, from: data),
               fm.fileExists(atPath: item.appendingPathComponent("disk.img").path) {
                var mac = VirtualMac(id: id, name: info.name ?? "Mac", ecid: info.ecid, seed: info.seed ?? 0,
                                     ramMB: info.ramMB ?? Device.suggestedRAMGB * 1024, diskBytes: 64 << 30,
                                     cpuCount: info.cpuCount)
                let os = (try? String(contentsOf: marker, encoding: .utf8))?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                mac.osName = os.isEmpty ? nil : os
                (mac.screenWidth, mac.screenHeight) = Device.fittingScreen
                all.append(mac)
                save()
                try? fm.removeItem(at: item.appendingPathComponent("restore"))
                HengeLog.log("machines", "\(mac.name) finished installing but was not listed: listed again")
                continue
            }
            HengeLog.log("machines", "removing the unfinished machine \(id)")
            try? fm.removeItem(at: item)
        }
    }

    nonisolated static var root: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return base.appendingPathComponent("Machines", isDirectory: true)
    }
    nonisolated static func directory(for id: UUID) -> URL { root.appendingPathComponent(id.uuidString, isDirectory: true) }
    nonisolated static func unmountedDirectory(for id: UUID) -> URL {
        URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("henge-unmounted", isDirectory: true)
            .appendingPathComponent(id.uuidString, isDirectory: true)
    }
    nonisolated static func directory(for mac: VirtualMac) -> URL {
        if mac.isExternal {
            return ExternalDriveRegistry.shared.machineDirectory(for: mac.id) ?? unmountedDirectory(for: mac.id)
        }
        return directory(for: mac.id)
    }
    nonisolated static func isAvailable(_ mac: VirtualMac) -> Bool {
        if mac.isExternal {
            guard let dir = ExternalDriveRegistry.shared.machineDirectory(for: mac.id) else { return false }
            return FileManager.default.fileExists(atPath: dir.appendingPathComponent("disk.img").path)
        }
        return FileManager.default.fileExists(atPath: directory(for: mac.id).appendingPathComponent("disk.img").path)
    }
    /// Where Finder file sharing puts what the user drops on Henge.
    nonisolated static var inbox: URL { FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0] }

    /// Folders dropped into Henge's Documents over Finder (or the Files app) that look like
    /// an exported machine are moved in. A move, not a copy: a disk image is tens of gigabytes.
    func collectImports() {
        Task { await collect() }
    }

    private func collect() async {
        guard importing == nil, let items = try? FileManager.default.contentsOfDirectory(at: Self.inbox, includingPropertiesForKeys: nil) else { return }
        for folder in items where Self.hasDisk(folder) && Self.required.allSatisfy({ FileManager.default.fileExists(atPath: folder.appendingPathComponent($0).path) }) {
            await adopt(folder, move: true)
        }
    }

    /// A folder chosen in the Files picker: copied (it may be on another volume).
    func importFolder(_ folder: URL) {
        Task {
            let scoped = folder.startAccessingSecurityScopedResource()
            defer { if scoped { folder.stopAccessingSecurityScopedResource() } }
            await adopt(folder, move: false)
        }
    }

    private func adopt(_ folder: URL, move: Bool) async {
        do {
            let data = try Data(contentsOf: folder.appendingPathComponent("machine.json"))
            let info = try JSONDecoder().decode(MachineFile.self, from: data)
            let missing = Self.required.filter { !FileManager.default.fileExists(atPath: folder.appendingPathComponent($0).path) }
            guard missing.isEmpty, Self.hasDisk(folder) else { throw message("資料夾缺少必要檔案：\((missing + (Self.hasDisk(folder) ? [] : ["disk.img"])).joined(separator: ", "))。") }
            var mac = VirtualMac(name: info.name ?? folder.lastPathComponent, ecid: info.ecid, seed: info.seed ?? 0,
                                 ramMB: info.ramMB ?? 2048, diskBytes: 0, cpuCount: info.cpuCount)
            importing = mac.name
            unpacked = 0
            let dest = mac.directory
            let fm = FileManager.default
            try fm.createDirectory(at: dest, withIntermediateDirectories: true)
            excludeFromBackup()
            for name in ["AVPBooter.vmapple2.bin", "auxiliary.bin", "machine.json", "disk.img"] {
                let from = folder.appendingPathComponent(name)
                guard fm.fileExists(atPath: from.path) else { continue }
                if move { try fm.moveItem(at: from, to: dest.appendingPathComponent(name)) }
                else { try fm.copyItem(at: from, to: dest.appendingPathComponent(name)) }
            }
            let packed = folder.appendingPathComponent(Self.packedDisk)
            if fm.fileExists(atPath: packed.path) {
                // Off the main thread: unpacking tens of gigabytes takes minutes.
                let target = mac.disk.path, source = packed.path
                let ok = await Task.detached { () -> Bool in
                    hv_sparse_unpack(source, target, { done, total, _ in
                        let fraction = Double(done) / Double(max(total, 1))
                        Task { @MainActor in Machines.shared.unpacked = fraction }
                    }, nil) == 0
                }.value
                guard ok else { try? fm.removeItem(at: dest); throw message("無法解開壓縮磁碟映像（可能是剩餘空間不足）。") }
                if move { try? fm.removeItem(at: packed) }
            }
            if move { try? fm.removeItem(at: folder) }
            mac.diskBytes = (try? fm.attributesOfItem(atPath: mac.disk.path)[.size] as? Int64) ?? 0
            all.append(mac)
            save()
            HengeLog.log("machines", "imported \(mac.name) (ECID \(mac.ecid), \(mac.diskBytes >> 30) GB disk)")
        } catch {
            lastError = error.localizedDescription
            HengeLog.log("machines", "import of \(folder.lastPathComponent) failed: \(error.localizedDescription)")
        }
        importing = nil
    }

    /// Makes a folder "Bring in a Mac" can read back (the same files tools/export_ios.sh writes),
    /// in Documents/Exports, which the Files app can reach. Deleting Henge deletes that folder too,
    /// so it has to be moved out of Henge before a reinstall that replaces the app's data.
    func export(_ mac: VirtualMac) {
        guard exporting == nil, importing == nil else { return }
        exporting = mac.name
        exported = 0
        lastExport = nil
        lastError = nil
        UIApplication.shared.isIdleTimerDisabled = true // a locked screen would suspend the app mid-way
        Task {
            defer {
                exporting = nil
                UIApplication.shared.isIdleTimerDisabled = false
            }
            do { lastExport = try await writeExport(mac) } catch {
                lastError = error.localizedDescription
                HengeLog.log("machines", "export of \(mac.name) failed: \(error.localizedDescription)")
            }
        }
    }

    private func writeExport(_ mac: VirtualMac) async throws -> URL {
        if mac.isExternal && !ensureExternalAccess(for: mac) {
            throw message("請先連接「\(mac.externalDriveName ?? "外接硬碟")」，再匯出「\(mac.name)」。")
        }
        let fm = FileManager.default
        let exports = Self.inbox.appendingPathComponent("Exports", isDirectory: true)
        let safeName = mac.name.replacingOccurrences(of: "/", with: "-")
        let final = exports.appendingPathComponent(safeName, isDirectory: true)
        // Not under its final name until it is whole, so a cut-short export can't be mistaken for a Mac.
        let partial = exports.appendingPathComponent(safeName + ".partial", isDirectory: true)
        try? fm.removeItem(at: partial)
        try? fm.removeItem(at: final)
        let used = Int(mac.bytesUsed)
        let free = ExternalInstallStorage.volumeFreeBytes(at: Self.inbox)
        let needed = Int64(used) + (256 << 20)
        if free > 0 && free < needed {
            throw message("匯出「\(mac.name)」需要約 \(ByteText.string(UInt64(needed))) 可用空間，這台\(Device.name)目前剩餘 \(ByteText.string(UInt64(free)))。刪除已下載的 macOS 安裝檔可釋放約 16 GB。")
        }
        try fm.createDirectory(at: partial, withIntermediateDirectories: true)
        do {
            try fm.copyItem(at: mac.rom, to: partial.appendingPathComponent("AVPBooter.vmapple2.bin"))
            try fm.copyItem(at: mac.aux, to: partial.appendingPathComponent("auxiliary.bin"))
            let info: [String: Any] = ["name": mac.name, "ecid": mac.ecid, "seed": mac.seed, "ramMB": mac.ramMB]
            try JSONSerialization.data(withJSONObject: info).write(to: partial.appendingPathComponent("machine.json"))
            let source = mac.disk.path, target = partial.appendingPathComponent(Self.packedDisk).path
            let ok = await Task.detached { () -> Bool in
                hv_sparse_pack_progress(source, target, { done, total, _ in
                    let fraction = Double(done) / Double(max(total, 1))
                    Task { @MainActor in Machines.shared.exported = fraction }
                }, nil) == 0
            }.value
            guard ok else { throw message("磁碟無法寫入（可能是剩餘空間不足）。") }
            try fm.moveItem(at: partial, to: final)
        } catch {
            try? fm.removeItem(at: partial)
            throw error
        }
        HengeLog.log("machines", "exported \(mac.name) to \(final.path)")
        return final
    }

    /// A machine made here (the installer), already in its directory.
    func add(_ mac: VirtualMac) {
        clearEjectedFlag(for: mac.id)
        all.removeAll { $0.id == mac.id }
        all.append(mac)
        save()
    }

    func update(_ mac: VirtualMac) {
        guard let i = all.firstIndex(where: { $0.id == mac.id }) else { return }
        all[i] = mac
        save()
        if mac.isAvailable {
            Self.writePortableManifest(for: mac, in: mac.directory)
        }
    }

    @discardableResult
    func ejectExternalMac(_ id: UUID, markAsExplicitlyEjected: Bool = true) -> Bool {
        guard !Self.isVMRunning && !isBusy else {
            lastError = "請先將執行中的 macOS 關機並等待目前作業完成，再執行安全退出。"
            return false
        }
        guard let mac = all.first(where: { $0.id == id }), mac.isExternal else {
            return false
        }
        let macRoot = ExternalDriveRegistry.shared.rootFolder(for: id)
        all.removeAll { $0.id == id }
        let otherOnSameDrive: Bool = {
            guard let macRoot else { return false }
            return all.contains { other in
                other.isExternal && ExternalDriveRegistry.shared.rootFolder(for: other.id).map {
                    ExternalDriveRegistry.isSameVolumeOrPath($0, macRoot)
                } == true
            }
        }()
        if otherOnSameDrive {
            ExternalDriveRegistry.shared.unregister(
                id: id,
                releaseEvenIfMounted: true,
                keepURL: ExternalInstallStorage.shared.folderURL
            )
            if markAsExplicitlyEjected {
                var ejected = explicitlyEjectedIDs
                ejected.insert(id)
                explicitlyEjectedIDs = ejected
            }
            statusNotice = "已從此\(Device.name)卸載「\(mac.name)」（SSD 資料已完整保留）。因同顆硬碟仍有其他掛載中的 Mac，拔除 USB-C 硬碟前請至「設定」執行「安全退出 SSD」。"
        } else {
            ExternalDriveRegistry.shared.unregister(
                id: id,
                releaseEvenIfMounted: true,
                keepURL: nil
            )
            ExternalInstallStorage.shared.unbindDriveIfMatching(macRoot, fallbackName: mac.externalDriveName)
            if let macRoot {
                ExternalDriveRegistry.shared.forceReleaseAllScopes(matching: macRoot)
            }
            if ExternalInstallStorage.shared.isConfigured && markAsExplicitlyEjected {
                var ejected = explicitlyEjectedIDs
                ejected.insert(id)
                explicitlyEjectedIDs = ejected
            } else {
                clearEjectedFlag(for: id)
            }
            statusNotice = "已安全退出「\(mac.name)」，外接 SSD 內的系統與資料皆已完整保留，現在可安心拔除硬碟。"
        }
        save()
        lastError = nil
        HengeLog.log("machines", "safely ejected external Mac \(mac.name) (\(id))")
        return true
    }

    @discardableResult
    func ejectAllExternalMacs(on driveURL: URL?, markAsExplicitlyEjected: Bool = true, keepURL: URL? = nil) -> Int {
        var matchedIDs: [UUID] = []
        for mac in all where mac.isExternal {
            if let driveURL {
                if let root = ExternalDriveRegistry.shared.rootFolder(for: mac.id),
                   ExternalDriveRegistry.isSameVolumeOrPath(root, driveURL) {
                    matchedIDs.append(mac.id)
                }
            } else {
                matchedIDs.append(mac.id)
            }
        }
        guard !matchedIDs.isEmpty else { return 0 }
        var ejected = explicitlyEjectedIDs
        for id in matchedIDs {
            ExternalDriveRegistry.shared.unregister(id: id, releaseEvenIfMounted: true, keepURL: keepURL)
            if markAsExplicitlyEjected { ejected.insert(id) } else { ejected.remove(id) }
        }
        explicitlyEjectedIDs = ejected
        let idSet = Set(matchedIDs)
        all.removeAll { idSet.contains($0.id) }
        save()
        return matchedIDs.count
    }

    func deleteMacAsync(_ id: UUID, deleteExternalFiles: Bool, onComplete: @escaping (Bool) -> Void = { _ in }) {
        guard !Self.isVMRunning && !isBusy else {
            lastError = "請先將執行中的 macOS 關機並等待目前作業完成，再執行刪除作業。"
            onComplete(false)
            return
        }
        guard let mac = all.first(where: { $0.id == id }) else {
            onComplete(false)
            return
        }
        if mac.isExternal && !deleteExternalFiles {
            let ok = ejectExternalMac(id)
            onComplete(ok)
            return
        }

        deleting = mac.name
        lastError = nil
        statusNotice = nil
        let isExternal = mac.isExternal
        let dir = isExternal ? mac.directory : Self.directory(for: id)
        let allowRemoveDir = !isExternal || (mac.externalRelativePath != ".")
        let available = !isExternal || mac.isAvailable

        Task.detached(priority: .userInitiated) {
            var freedBytes: Int64 = 0
            var deleteError: Error?
            if available {
                do {
                    freedBytes = try Self.safelyDeleteMachineFiles(in: dir, allowRemovingDirectory: allowRemoveDir)
                } catch {
                    deleteError = error
                }
            }
            let finalFreed = freedBytes
            let finalError = deleteError
            await MainActor.run {
                self.deleting = nil
                if let finalError {
                    self.lastError = "刪除「\(mac.name)」失敗：\(finalError.localizedDescription)"
                    HengeLog.log("machines", "delete of \(mac.name) failed: \(finalError.localizedDescription)")
                    onComplete(false)
                    return
                }
                if isExternal {
                    ExternalDriveRegistry.shared.unregister(
                        id: id,
                        releaseEvenIfMounted: true,
                        keepURL: ExternalInstallStorage.shared.folderURL
                    )
                    self.clearEjectedFlag(for: id)
                }
                self.all.removeAll { $0.id == id }
                self.save()
                if isExternal {
                    self.statusNotice = "已從外接 SSD 永久刪除「\(mac.name)」（釋放 \(ByteText.string(UInt64(max(finalFreed, 0))))），SSD 內其他個人檔案已保留。"
                } else {
                    self.statusNotice = "已刪除「\(mac.name)」，釋放 \(ByteText.string(UInt64(max(finalFreed, 0))))。"
                }
                HengeLog.log("machines", "deleted Mac \(mac.name) (external=\(isExternal), freed=\(finalFreed))")
                onComplete(true)
            }
        }
    }

    func delete(_ id: UUID, deleteExternalFiles: Bool = false) {
        guard !Self.isVMRunning && !isBusy else {
            lastError = "請先將執行中的 macOS 關機並等待目前作業完成，再執行移除或刪除。"
            return
        }
        if let mac = all.first(where: { $0.id == id }), mac.isExternal {
            if !deleteExternalFiles {
                _ = ejectExternalMac(id)
                return
            }
            if mac.isAvailable {
                let dir = mac.directory
                let allowRemoveDir = mac.externalRelativePath != "."
                _ = try? Self.safelyDeleteMachineFiles(in: dir, allowRemovingDirectory: allowRemoveDir)
            }
            ExternalDriveRegistry.shared.unregister(
                id: id,
                releaseEvenIfMounted: true,
                keepURL: ExternalInstallStorage.shared.folderURL
            )
            clearEjectedFlag(for: id)
        } else {
            _ = try? Self.safelyDeleteMachineFiles(in: Self.directory(for: id), allowRemovingDirectory: true)
        }
        all.removeAll { $0.id == id }
        save()
    }

    @discardableResult
    func ensureExternalAccess(for mac: VirtualMac) -> Bool {
        guard mac.isExternal, let bookmark = mac.externalFolderBookmark else {
            return FileManager.default.fileExists(atPath: mac.disk.path)
        }
        guard let resolved = ExternalDriveRegistry.shared.resolveAndRegister(
            id: mac.id,
            bookmark: bookmark,
            relativePath: mac.externalRelativePath
        ) else {
            objectWillChange.send()
            return false
        }
        if let refreshed = resolved.refreshedBookmark,
           let idx = all.firstIndex(where: { $0.id == mac.id }) {
            all[idx].externalFolderBookmark = refreshed
            all[idx].externalDriveName = ExternalInstallStorage.volumeName(at: resolved.folder)
            save()
        }
        let fm = FileManager.default
        let dir = mac.directory
        let ok = fm.fileExists(atPath: dir.appendingPathComponent("disk.img").path)
            && fm.fileExists(atPath: dir.appendingPathComponent("AVPBooter.vmapple2.bin").path)
            && fm.fileExists(atPath: dir.appendingPathComponent("auxiliary.bin").path)
        objectWillChange.send()
        return ok
    }

    @discardableResult
    func reconnectExternal(_ mac: VirtualMac, to pickedURL: URL) -> Bool {
        _ = ExternalDriveRegistry.shared.retainScope(for: pickedURL)
        let fm = FileManager.default
        let resolvedDir = ExternalDriveRegistry.resolveMachineDirectory(in: pickedURL, for: mac.id, relativePath: mac.externalRelativePath)
        var candidateDir: URL?
        if fm.fileExists(atPath: resolvedDir.appendingPathComponent("disk.img").path) {
            candidateDir = resolvedDir
        } else if fm.fileExists(atPath: pickedURL.appendingPathComponent("disk.img").path) {
            candidateDir = pickedURL
        } else {
            let searchDirs = [pickedURL.appendingPathComponent("HengeMachines", isDirectory: true), pickedURL]
            for root in searchDirs where candidateDir == nil {
                guard let children = try? fm.contentsOfDirectory(at: root, includingPropertiesForKeys: nil) else { continue }
                for child in children where Self.isValidPortableFolder(child) {
                    if let data = try? Data(contentsOf: child.appendingPathComponent("machine.json")),
                       let info = try? JSONDecoder().decode(MachineFile.self, from: data),
                       (info.id == mac.id || info.ecid == mac.ecid) {
                        candidateDir = child
                        break
                    }
                }
            }
        }
        guard let matchedDir = candidateDir else {
            ExternalDriveRegistry.shared.releaseScopeIfUnused(for: pickedURL, keepURL: ExternalInstallStorage.shared.folderURL)
            lastError = "在該資料夾中找不到「\(mac.name)」的磁碟檔案（disk.img）。"
            return false
        }
        // Keep the security-scoped bookmark on pickedURL: iPadOS never grants sandbox scope to ancestors of pickedURL.
        let bookmarkTarget = pickedURL
        let pickedCanon = ExternalDriveRegistry.canonicalPath(pickedURL)
        let matchedCanon = ExternalDriveRegistry.canonicalPath(matchedDir)
        let matchedParentCanon = ExternalDriveRegistry.canonicalPath(matchedDir.deletingLastPathComponent())
        let hmCanon = ExternalDriveRegistry.canonicalPath(pickedURL.appendingPathComponent("HengeMachines", isDirectory: true))
        let newRelativePath: String?
        if matchedCanon == pickedCanon {
            newRelativePath = "."
        } else if matchedParentCanon == hmCanon {
            newRelativePath = (matchedDir.lastPathComponent == mac.id.uuidString)
                ? nil
                : "HengeMachines/\(matchedDir.lastPathComponent)"
        } else if pickedURL.lastPathComponent == "HengeMachines",
                  matchedDir.lastPathComponent == mac.id.uuidString {
            newRelativePath = nil
        } else {
            newRelativePath = matchedDir.lastPathComponent
        }
        do {
            let bookmark = try bookmarkTarget.bookmarkData(options: [], includingResourceValuesForKeys: nil, relativeTo: nil)
            let name = ExternalInstallStorage.volumeName(at: bookmarkTarget)
            ExternalDriveRegistry.shared.register(id: mac.id, folderURL: bookmarkTarget, relativePath: newRelativePath)
            clearEjectedFlag(for: mac.id)
            if let idx = all.firstIndex(where: { $0.id == mac.id }) {
                all[idx].externalFolderBookmark = bookmark
                all[idx].externalDriveName = name
                all[idx].externalRelativePath = newRelativePath
                save()
            }
            lastError = nil
            statusNotice = nil
            objectWillChange.send()
            HengeLog.log("machines", "reconnected external Mac \(mac.name) to \(name)")
            return true
        } catch {
            ExternalDriveRegistry.shared.releaseScopeIfUnused(for: pickedURL, keepURL: ExternalInstallStorage.shared.folderURL)
            lastError = error.localizedDescription
            return false
        }
    }

    /// Moves an installed Mac between this iPad's internal storage and the connected external drive.
    func moveStorage(_ mac: VirtualMac, toExternal: Bool, onComplete: @escaping (VirtualMac) -> Void = { _ in }) {
        guard !Self.isVMRunning && !isBusy else { return }
        moving = mac.name
        moved = 0
        lastError = nil
        statusNotice = nil
        UIApplication.shared.isIdleTimerDisabled = true
        Task {
            defer {
                moving = nil
                UIApplication.shared.isIdleTimerDisabled = false
            }
            do {
                let updated = try await performMoveStorage(mac, toExternal: toExternal)
                onComplete(updated)
            } catch {
                lastError = error.localizedDescription
                HengeLog.log("machines", "move of \(mac.name) failed: \(error.localizedDescription)")
            }
        }
    }

    private func performMoveStorage(_ mac: VirtualMac, toExternal: Bool) async throws -> VirtualMac {
        let fm = FileManager.default
        if toExternal {
            ExternalInstallStorage.shared.refreshConnection()
            guard ExternalInstallStorage.shared.isConfigured,
                  ExternalInstallStorage.shared.isConnected,
                  let extFolder = ExternalInstallStorage.shared.folderURL,
                  let bookmark = ExternalInstallStorage.shared.bookmarkData else {
                throw message("請先到「安裝」或「設定」連接並選擇外接 SSD 資料夾。")
            }
            let driveName = ExternalInstallStorage.shared.configuredName ?? "外接 SSD"
            let needed = ExternalInstallStorage.shared.supportsSparseFiles ? (mac.bytesUsed + (512 << 20)) : (mac.diskBytes + (512 << 20))
            let free = ExternalInstallStorage.shared.freeBytes
            if free > 0 && free < needed {
                throw message("將「\(mac.name)」搬移至「\(driveName)」需要約 \(ByteText.string(UInt64(needed))) 可用空間，目前僅剩 \(ByteText.string(UInt64(free)))。")
            }
            let sourceDir = Self.directory(for: mac.id)
            let targetDir = ExternalDriveRegistry.resolveMachineDirectory(in: extFolder, for: mac.id)
            let partialDir = targetDir.deletingLastPathComponent().appendingPathComponent(mac.id.uuidString + ".moving", isDirectory: true)
            try? fm.removeItem(at: partialDir)
            try fm.createDirectory(at: partialDir, withIntermediateDirectories: true)
            do {
                try await Self.copyMachineFiles(from: sourceDir, to: partialDir, sparseTarget: ExternalInstallStorage.shared.supportsSparseFiles) { p in
                    Task { @MainActor in Machines.shared.moved = p }
                }
                if fm.fileExists(atPath: targetDir.path) {
                    _ = try? Self.safelyDeleteMachineFiles(in: targetDir, allowRemovingDirectory: true)
                    if fm.fileExists(atPath: targetDir.path) {
                        try fm.removeItem(at: targetDir)
                    }
                }
                try fm.moveItem(at: partialDir, to: targetDir)
            } catch {
                try? fm.removeItem(at: partialDir)
                throw error
            }
            ExternalDriveRegistry.shared.register(id: mac.id, folderURL: extFolder, relativePath: nil)
            clearEjectedFlag(for: mac.id)
            var updated = mac
            updated.externalFolderBookmark = bookmark
            updated.externalDriveName = driveName
            updated.externalRelativePath = nil
            updated.autoAdaptToHost = updated.autoAdaptToHost ?? true
            Self.writePortableManifest(for: updated, in: targetDir)
            update(updated)
            if fm.fileExists(atPath: targetDir.appendingPathComponent("disk.img").path) {
                try? fm.removeItem(at: sourceDir)
            }
            statusNotice = "已將「\(mac.name)」搬移至外接 SSD「\(driveName)」。"
            HengeLog.log("machines", "moved \(mac.name) to external drive \(driveName)")
            return updated
        } else {
            guard ensureExternalAccess(for: mac) else {
                throw message("請先連接「\(mac.externalDriveName ?? "外接 SSD")」。")
            }
            let needed = mac.bytesUsed + (1 << 30)
            let free = ExternalInstallStorage.volumeFreeBytes(at: Self.root)
            if free > 0 && free < needed {
                throw message("將「\(mac.name)」搬回此\(Device.name)需要約 \(ByteText.string(UInt64(needed))) 可用空間，目前僅剩 \(ByteText.string(UInt64(free)))。")
            }
            let sourceDir = mac.directory
            let targetDir = Self.directory(for: mac.id)
            let partialDir = Self.root.appendingPathComponent(mac.id.uuidString + ".moving", isDirectory: true)
            try? fm.removeItem(at: partialDir)
            try fm.createDirectory(at: partialDir, withIntermediateDirectories: true)
            excludeFromBackup()
            do {
                try await Self.copyMachineFiles(from: sourceDir, to: partialDir, sparseTarget: true) { p in
                    Task { @MainActor in Machines.shared.moved = p }
                }
                if fm.fileExists(atPath: targetDir.path) {
                    _ = try? Self.safelyDeleteMachineFiles(in: targetDir, allowRemovingDirectory: true)
                    if fm.fileExists(atPath: targetDir.path) {
                        try fm.removeItem(at: targetDir)
                    }
                }
                try fm.moveItem(at: partialDir, to: targetDir)
            } catch {
                try? fm.removeItem(at: partialDir)
                throw error
            }
            var updated = mac
            updated.externalFolderBookmark = nil
            updated.externalDriveName = nil
            updated.externalRelativePath = nil
            updated.autoAdaptToHost = false
            if updated.screenWidth == nil || updated.screenHeight == nil {
                (updated.screenWidth, updated.screenHeight) = Device.fittingScreen
            }
            update(updated)
            if fm.fileExists(atPath: targetDir.appendingPathComponent("disk.img").path) {
                _ = try? Self.safelyDeleteMachineFiles(in: sourceDir, allowRemovingDirectory: mac.externalRelativePath != ".")
            }
            ExternalDriveRegistry.shared.unregister(
                id: mac.id,
                releaseEvenIfMounted: true,
                keepURL: ExternalInstallStorage.shared.folderURL
            )
            statusNotice = "已將「\(mac.name)」搬回此\(Device.name)本機空間。"
            HengeLog.log("machines", "moved \(mac.name) to internal storage on this \(Device.name)")
            return updated
        }
    }

    nonisolated private static func copyMachineFiles(
        from sourceDir: URL,
        to targetDir: URL,
        sparseTarget: Bool,
        progress: @escaping @Sendable (Double) -> Void
    ) async throws {
        try await Task.detached(priority: .userInitiated) {
            let fm = FileManager.default
            for name in ["AVPBooter.vmapple2.bin", "auxiliary.bin", "machine.json", installedMarker, "preview.jpg"] {
                let src = sourceDir.appendingPathComponent(name)
                if fm.fileExists(atPath: src.path) {
                    try fm.copyItem(at: src, to: targetDir.appendingPathComponent(name))
                }
            }
            let srcDisk = sourceDir.appendingPathComponent("disk.img").path
            let dstDisk = targetDir.appendingPathComponent("disk.img").path
            let inFD = open(srcDisk, O_RDONLY)
            guard inFD >= 0 else {
                throw NSError(domain: "Henge", code: 1, userInfo: [NSLocalizedDescriptionKey: "無法讀取來源 disk.img。"])
            }
            defer { close(inFD) }
            var st = stat()
            guard fstat(inFD, &st) == 0, st.st_size > 0 else {
                throw NSError(domain: "Henge", code: 1, userInfo: [NSLocalizedDescriptionKey: "無法讀取磁碟大小。"])
            }
            let total = st.st_size
            let outFD = open(dstDisk, O_CREAT | O_TRUNC | O_RDWR, 0o600)
            guard outFD >= 0 else {
                throw NSError(domain: "Henge", code: 1, userInfo: [NSLocalizedDescriptionKey: "無法在目的路徑建立 disk.img。"])
            }
            defer { close(outFD) }
            guard ftruncate(outFD, total) == 0 else {
                throw NSError(domain: "Henge", code: 1, userInfo: [NSLocalizedDescriptionKey: "剩餘空間不足，無法配置 disk.img。"])
            }
            let chunkSize = 4 << 20
            let buf = UnsafeMutableRawPointer.allocate(byteCount: chunkSize, alignment: 16384)
            defer { buf.deallocate() }
            var offset: off_t = 0
            var lastReported = -1
            while offset < total {
                let toRead = min(Int(total - offset), chunkSize)
                let r = pread(inFD, buf, toRead, offset)
                if r < 0 && errno == EINTR { continue }
                guard r > 0 else {
                    throw NSError(domain: "Henge", code: 1, userInfo: [NSLocalizedDescriptionKey: "搬移時讀取磁碟失敗。"])
                }
                var allZero = false
                if sparseTarget && r % 8 == 0 {
                    allZero = true
                    let words = buf.bindMemory(to: UInt64.self, capacity: r / 8)
                    for i in 0..<(r / 8) where words[i] != 0 {
                        allZero = false
                        break
                    }
                }
                if !allZero {
                    var written = 0
                    while written < r {
                        let w = pwrite(outFD, buf.advanced(by: written), r - written, offset + off_t(written))
                        if w < 0 && errno == EINTR { continue }
                        guard w > 0 else {
                            throw NSError(domain: "Henge", code: 1, userInfo: [NSLocalizedDescriptionKey: "寫入磁碟失敗（請確認剩餘空間是否足夠）。"])
                        }
                        written += w
                    }
                }
                offset += off_t(r)
                let pct = Int((Double(offset) / Double(total)) * 100)
                if pct != lastReported {
                    lastReported = pct
                    progress(Double(offset) / Double(total))
                }
            }
            _ = fsync(outFD)
        }.value
    }

    /// Registers or refreshes a portable external Mac from `folder` under a bookmarked drive URL `baseURL`.
    @discardableResult
    private func upsertExternalMac(
        folder: URL,
        baseURL: URL,
        relativePath: String?,
        bookmark: Data,
        driveName: String,
        allowUpdateExisting: Bool
    ) -> VirtualMac? {
        let fm = FileManager.default
        guard Self.isValidPortableFolder(folder),
              let data = try? Data(contentsOf: folder.appendingPathComponent("machine.json")),
              let info = try? JSONDecoder().decode(MachineFile.self, from: data) else {
            return nil
        }
        let macID = info.id ?? UUID(uuidString: folder.lastPathComponent) ?? UUID()
        if !allowUpdateExisting && explicitlyEjectedIDs.contains(macID) {
            return nil
        }
        clearEjectedFlag(for: macID)
        let marker = folder.appendingPathComponent(Self.installedMarker)
        let markerOS = (try? String(contentsOf: marker, encoding: .utf8))?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let resolvedOS = (info.osName?.isEmpty == false) ? info.osName : (markerOS.isEmpty ? nil : markerOS)
        let diskSize = info.diskBytes
            ?? ((try? folder.appendingPathComponent("disk.img").resourceValues(forKeys: [.fileSizeKey]))?.fileSize.map(Int64.init))
            ?? (64 << 30)

        let storedRelPath: String?
        if let rel = relativePath,
           rel.lowercased() == "hengemachines/\(macID.uuidString.lowercased())" && folder.lastPathComponent == macID.uuidString {
            storedRelPath = nil
        } else {
            storedRelPath = relativePath
        }

        if let idx = all.firstIndex(where: { $0.id == macID || ($0.isExternal && $0.ecid == info.ecid) }) {
            guard allowUpdateExisting || !all[idx].isAvailable else { return nil }
            let resolvedID = all[idx].id
            let effectiveRel: String? = (resolvedID == macID) ? storedRelPath : (relativePath ?? ".")
            all[idx].externalFolderBookmark = bookmark
            all[idx].externalDriveName = driveName
            all[idx].externalRelativePath = effectiveRel
            if let name = info.name, !name.isEmpty { all[idx].name = name }
            if let resolvedOS { all[idx].osName = resolvedOS }
            all[idx].diskBytes = diskSize
            if let remoteUsed = info.lastUsed {
                if let localUsed = all[idx].lastUsed {
                    all[idx].lastUsed = max(localUsed, remoteUsed)
                } else {
                    all[idx].lastUsed = remoteUsed
                }
            }
            ExternalDriveRegistry.shared.register(id: resolvedID, folderURL: baseURL, relativePath: effectiveRel)
            return all[idx]
        }

        var mac = VirtualMac(
            id: macID,
            name: info.name ?? folder.lastPathComponent,
            ecid: info.ecid,
            seed: info.seed ?? 0,
            ramMB: info.ramMB ?? Device.suggestedRAMGB * 1024,
            diskBytes: diskSize,
            osName: resolvedOS,
            lastUsed: info.lastUsed,
            reportHostIdentity: info.reportHostIdentity ?? true,
            externalFolderBookmark: bookmark,
            externalDriveName: driveName,
            autoAdaptToHost: info.portableAutoAdapt ?? true,
            externalRelativePath: storedRelPath,
            cpuCount: info.cpuCount
        )
        (mac.screenWidth, mac.screenHeight) = Device.fittingScreen
        ExternalDriveRegistry.shared.register(id: mac.id, folderURL: baseURL, relativePath: storedRelPath)
        all.append(mac)
        try? fm.removeItem(at: folder.appendingPathComponent("restore"))
        Self.writePortableManifest(for: mac, in: folder)
        return mac
    }

    /// Attaches one or more portable Macs located on an external USB-C drive folder (SSD root, `HengeMachines`,
    /// or an individual Mac directory) without copying the disk image onto this device.
    @discardableResult
    func attachExternalDrive(_ pickedURL: URL) -> Int {
        _ = ExternalDriveRegistry.shared.retainScope(for: pickedURL)
        let fm = FileManager.default
        let probe = pickedURL.appendingPathComponent(".henge_probe_\(UUID().uuidString)")
        do {
            try Data().write(to: probe)
            try? fm.removeItem(at: probe)
        } catch {
            ExternalDriveRegistry.shared.releaseScopeIfUnused(for: pickedURL, keepURL: ExternalInstallStorage.shared.folderURL)
            lastError = "這個外接硬碟無法寫入（例如唯讀 NTFS 格式）。請格式化為 APFS 或 exFAT 後再使用。"
            HengeLog.log("machines", "external drive not writable (\(pickedURL.path)): \(error.localizedDescription)")
            return 0
        }

        var candidates: [(folder: URL, relativePath: String)] = []
        if Self.isValidPortableFolder(pickedURL) {
            candidates.append((pickedURL, "."))
        } else {
            let hmDir = pickedURL.appendingPathComponent("HengeMachines", isDirectory: true)
            var isDir: ObjCBool = false
            if fm.fileExists(atPath: hmDir.path, isDirectory: &isDir), isDir.boolValue,
               let children = try? fm.contentsOfDirectory(at: hmDir, includingPropertiesForKeys: nil) {
                for child in children where Self.isValidPortableFolder(child) {
                    candidates.append((child, "HengeMachines/\(child.lastPathComponent)"))
                }
            }
            if candidates.isEmpty,
               let children = try? fm.contentsOfDirectory(at: pickedURL, includingPropertiesForKeys: nil) {
                for child in children where Self.isValidPortableFolder(child) {
                    candidates.append((child, child.lastPathComponent))
                }
            }
        }

        guard !candidates.isEmpty else {
            ExternalDriveRegistry.shared.releaseScopeIfUnused(for: pickedURL, keepURL: ExternalInstallStorage.shared.folderURL)
            lastError = "在該資料夾找不到可攜式 Mac。請選擇外接 SSD 根目錄、HengeMachines 資料夾，或內含 disk.img、auxiliary.bin、AVPBooter.vmapple2.bin 與 machine.json 的 Mac 資料夾。"
            return 0
        }

        guard let bookmark = try? pickedURL.bookmarkData(options: [], includingResourceValuesForKeys: nil, relativeTo: nil) else {
            ExternalDriveRegistry.shared.releaseScopeIfUnused(for: pickedURL, keepURL: ExternalInstallStorage.shared.folderURL)
            lastError = "無法儲存此外接硬碟資料夾的存取權限。"
            return 0
        }
        let driveName = ExternalInstallStorage.volumeName(at: pickedURL)
        var attachedCount = 0
        for candidate in candidates {
            if upsertExternalMac(
                folder: candidate.folder,
                baseURL: pickedURL,
                relativePath: candidate.relativePath,
                bookmark: bookmark,
                driveName: driveName,
                allowUpdateExisting: true
            ) != nil {
                attachedCount += 1
            }
        }
        guard attachedCount > 0 else {
            ExternalDriveRegistry.shared.releaseScopeIfUnused(for: pickedURL, keepURL: ExternalInstallStorage.shared.folderURL)
            lastError = "找到 Mac 檔案但無法讀取 machine.json。"
            return 0
        }
        lastError = nil
        statusNotice = "已從「\(driveName)」掛載 \(attachedCount) 台隨身 Mac（資料保留在外接 SSD，不佔用本機空間）。"
        save()
        objectWillChange.send()
        HengeLog.log("machines", "attached \(attachedCount) portable Mac(s) from \(driveName)")
        return attachedCount
    }

    func refreshExternalMachines(clearEjectedOnConfiguredDrive: Bool = false) {
        var changed = false
        for i in all.indices where all[i].isExternal {
            let wasAvailable = all[i].isAvailable
            if let bookmark = all[i].externalFolderBookmark,
               let resolved = ExternalDriveRegistry.shared.resolveAndRegister(
                   id: all[i].id,
                   bookmark: bookmark,
                   relativePath: all[i].externalRelativePath
               ) {
                let name = ExternalInstallStorage.volumeName(at: resolved.folder)
                if all[i].externalDriveName != name {
                    all[i].externalDriveName = name
                    changed = true
                }
                if let refreshed = resolved.refreshedBookmark {
                    all[i].externalFolderBookmark = refreshed
                    changed = true
                }
            }
            if all[i].isAvailable != wasAvailable {
                changed = true
            }
        }

        if let baseURL = ExternalInstallStorage.shared.folderURL,
           let extRoot = ExternalInstallStorage.shared.externalMachinesRoot,
           let bookmark = ExternalInstallStorage.shared.bookmarkData {
            if clearEjectedOnConfiguredDrive {
                clearAllEjectedFlags()
            }
            let driveName = ExternalInstallStorage.shared.configuredName ?? "外接硬碟"
            let fm = FileManager.default
            let items = (try? fm.contentsOfDirectory(at: extRoot, includingPropertiesForKeys: nil)) ?? []
            for item in items {
                let relPath = (baseURL.lastPathComponent == "HengeMachines") ? item.lastPathComponent : "HengeMachines/\(item.lastPathComponent)"
                if Self.isValidPortableFolder(item) {
                    if let added = upsertExternalMac(
                        folder: item,
                        baseURL: baseURL,
                        relativePath: relPath,
                        bookmark: bookmark,
                        driveName: driveName,
                        allowUpdateExisting: false
                    ) {
                        changed = true
                        HengeLog.log("machines", "re-listed external Mac \(added.name) on \(driveName)")
                    }
                } else if !Installer.shared.busy,
                          fm.fileExists(atPath: item.appendingPathComponent(Self.installingMarker).path),
                          !fm.fileExists(atPath: item.appendingPathComponent(Self.installedMarker).path) {
                    HengeLog.log("machines", "removing unfinished external machine \(item.lastPathComponent)")
                    try? fm.removeItem(at: item)
                }
            }
        }

        if changed {
            save()
            objectWillChange.send()
        }
    }

    private var listURL: URL { Self.root.appendingPathComponent("machines.json") }

    /// Disk images are tens of gigabytes: keep them out of iCloud and computer backups.
    private func excludeFromBackup() { Self.excludeFromBackup(Self.root) }

    nonisolated static func excludeFromBackup(_ dir: URL) {
        var url = dir
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        try? url.setResourceValues(values)
    }

    /// machines.json is there but did not decode (damaged, or written by a newer Henge).
    private var listUnreadable = false

    private func load() {
        guard let data = try? Data(contentsOf: listURL) else { return }
        guard let list = try? JSONDecoder().decode([VirtualMac].self, from: data) else {
            listUnreadable = true
            HengeLog.log("machines", "machines.json (\(data.count) bytes) could not be read")
            return
        }
        var kept: [VirtualMac] = []
        var refreshedAny = false
        for var mac in list {
            if let bookmark = mac.externalFolderBookmark {
                if let resolved = ExternalDriveRegistry.shared.resolveAndRegister(
                    id: mac.id,
                    bookmark: bookmark,
                    relativePath: mac.externalRelativePath
                ) {
                    mac.externalDriveName = ExternalInstallStorage.volumeName(at: resolved.folder)
                    if let refreshed = resolved.refreshedBookmark {
                        mac.externalFolderBookmark = refreshed
                        refreshedAny = true
                    }
                }
                // Keep external Macs even when their USB-C drive is currently unplugged.
                kept.append(mac)
            } else if FileManager.default.fileExists(atPath: mac.disk.path) {
                kept.append(mac)
            }
        }
        all = kept
        if refreshedAny {
            save()
        }
    }

    private func save() {
        try? FileManager.default.createDirectory(at: Self.root, withIntermediateDirectories: true)
        excludeFromBackup()
        if let data = try? JSONEncoder().encode(all) { try? data.write(to: listURL, options: .atomic) }
    }

    private func message(_ text: String) -> NSError {
        NSError(domain: "Henge", code: 1, userInfo: [NSLocalizedDescriptionKey: text])
    }
}
