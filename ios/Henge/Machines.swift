import Foundation
import UIKit

/// machine.json in a machine or exported folder. Optional portable fields stay backward compatible with older manifests.
private typealias MachineFile = PortableMachineManifest

@MainActor
final class Machines: ObservableObject {
    static let shared = Machines()

    @Published private(set) var all: [VirtualMac] = []
    @Published private(set) var importing: String?
    @Published var lastError: String?
    @Published var statusNotice: String?

    /// The files an exported machine folder holds; its disk is disk.img, or disk.img.hvsparse (tools/export_ios.sh packs it).
    nonisolated static let required = MachineStorageSafety.requiredFiles
    nonisolated static let packedDisk = "disk.img.hvsparse"
    nonisolated static let knownMachineEntries = MachineStorageSafety.knownMachineEntries

    nonisolated static var isVMRunning: Bool {
        let s = henge_vm_state()
        return s == 1 || s == 3 || s == 4
    }

    nonisolated static func hasDisk(_ folder: URL) -> Bool {
        MachineStorageSafety.isRegularFile(folder.appendingPathComponent("disk.img"), within: folder)
            || MachineStorageSafety.isRegularFile(folder.appendingPathComponent(packedDisk), within: folder)
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
        MachineStorageSafety.isPortableMachineDirectory(folder)
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
    nonisolated static func safelyDeleteMachineFiles(
        in dir: URL,
        allowRemovingDirectory: Bool,
        approvedRoot: URL? = nil,
        validating target: ExternalDriveTarget? = nil
    ) throws -> Int64 {
        try MachineStorageSafety.deleteMachineFiles(
            in: dir,
            approvedRoot: approvedRoot ?? Self.root,
            allowRemovingDirectory: allowRemovingDirectory,
            validating: target
        )
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
            guard let id = UUID(uuidString: item.lastPathComponent), !known.contains(id),
                  MachineStorageSafety.isSafeDirectory(item, within: Self.root) else { continue }
            let marker = item.appendingPathComponent(Self.installedMarker)
            if MachineStorageSafety.isRegularFile(marker, within: Self.root) {
                guard Self.isValidPortableFolder(item),
                      let data = try? Data(contentsOf: item.appendingPathComponent("machine.json")),
                      let info = try? JSONDecoder().decode(MachineFile.self, from: data),
                      info.hasValidRAM else {
                    HengeLog.log("machines", "preserving installed machine \(id): its files or RAM configuration could not be validated")
                    continue
                }
                var mac = VirtualMac(id: id, name: info.name ?? "Mac", ecid: info.ecid, seed: info.seed ?? 0,
                                     ramMB: info.ramMB ?? Device.adaptiveGuestRAMMB, diskBytes: 64 << 30,
                                     cpuCount: info.cpuCount)
                let os = (try? String(contentsOf: marker, encoding: .utf8))?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                mac.osName = os.isEmpty ? nil : os
                (mac.screenWidth, mac.screenHeight) = Device.fittingScreen
                all.append(mac)
                save()
                _ = try? MachineStorageSafety.removeManagedDirectory(item.appendingPathComponent("restore"), approvedRoot: Self.root)
                HengeLog.log("machines", "\(mac.name) finished installing but was not listed: listed again")
                continue
            }
            if MachineStorageSafety.isRegularFile(item.appendingPathComponent(Self.installingMarker), within: Self.root) {
                HengeLog.log("machines", "removing the unfinished machine \(id)")
                _ = try? Self.safelyDeleteMachineFiles(in: item, allowRemovingDirectory: true, approvedRoot: Self.root)
            }
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
            guard let dir = ExternalDriveRegistry.shared.machineDirectory(for: mac.id),
                  let approvedRoot = ExternalDriveRegistry.shared.rootFolder(for: mac.id) else { return false }
            return MachineStorageSafety.isRegularFile(dir.appendingPathComponent("disk.img"), within: approvedRoot)
        }
        return MachineStorageSafety.isRegularFile(directory(for: mac.id).appendingPathComponent("disk.img"), within: Self.root)
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
        var createdDirectory: URL?
        do {
            let approvedSource = move ? Self.inbox : folder
            guard MachineStorageSafety.isSafeDirectory(folder, within: approvedSource) else {
                throw message("資料夾包含不安全的符號連結，無法匯入。")
            }
            let missing = Self.required.filter {
                !MachineStorageSafety.isRegularFile(folder.appendingPathComponent($0), within: approvedSource)
            }
            let rawDisk = folder.appendingPathComponent("disk.img")
            let packedDisk = folder.appendingPathComponent(Self.packedDisk)
            let hasRawDisk = MachineStorageSafety.isRegularFile(rawDisk, within: approvedSource)
            let hasPackedDisk = MachineStorageSafety.isRegularFile(packedDisk, within: approvedSource)
            guard missing.isEmpty, hasRawDisk || hasPackedDisk else {
                throw message("資料夾缺少必要的一般檔案：\((missing + ((hasRawDisk || hasPackedDisk) ? [] : ["disk.img"])).joined(separator: ", "))。")
            }
            let data = try Data(contentsOf: folder.appendingPathComponent("machine.json"))
            let info = try JSONDecoder().decode(MachineFile.self, from: data)
            guard info.hasValidRAM else { throw message("machine.json 的記憶體設定無效，必須介於 1024 至 16384 MB。") }
            var mac = VirtualMac(name: info.name ?? folder.lastPathComponent, ecid: info.ecid, seed: info.seed ?? 0,
                                 ramMB: info.ramMB ?? 2048, diskBytes: 0, cpuCount: info.cpuCount)
            importing = mac.name
            unpacked = 0
            let dest = mac.directory
            let fm = FileManager.default
            try fm.createDirectory(at: dest, withIntermediateDirectories: true)
            createdDirectory = dest
            try Data().write(to: dest.appendingPathComponent(Self.installingMarker))
            excludeFromBackup()
            for name in Self.required {
                let from = folder.appendingPathComponent(name)
                try fm.copyItem(at: from, to: dest.appendingPathComponent(name))
            }
            if hasRawDisk {
                if move { try fm.moveItem(at: rawDisk, to: mac.disk) }
                else { try fm.copyItem(at: rawDisk, to: mac.disk) }
            } else {
                // Off the main thread: unpacking tens of gigabytes takes minutes.
                let target = mac.disk.path, source = packedDisk.path
                let ok = await Task.detached { () -> Bool in
                    hv_sparse_unpack(source, target, { done, total, _ in
                        let fraction = Double(done) / Double(max(total, 1))
                        Task { @MainActor in Machines.shared.unpacked = fraction }
                    }, nil) == 0
                }.value
                guard ok else { throw message("無法解開壓縮磁碟映像（可能是剩餘空間不足）。") }
            }
            _ = try? MachineStorageSafety.removeRegularFile(dest.appendingPathComponent(Self.installingMarker), approvedRoot: Self.root)
            Self.writePortableManifest(for: mac, in: dest)
            if move {
                for name in Self.required {
                    _ = try? MachineStorageSafety.removeRegularFile(folder.appendingPathComponent(name), approvedRoot: approvedSource)
                }
                if !hasRawDisk {
                    _ = try? MachineStorageSafety.removeRegularFile(packedDisk, approvedRoot: approvedSource)
                }
                MachineStorageSafety.removeEmptyDirectory(folder, within: approvedSource)
            }
            mac.diskBytes = (try? fm.attributesOfItem(atPath: mac.disk.path)[.size] as? Int64) ?? 0
            all.append(mac)
            save()
            HengeLog.log("machines", "imported \(mac.name) (ECID \(mac.ecid), \(mac.diskBytes >> 30) GB disk)")
        } catch {
            if let createdDirectory {
                _ = try? Self.safelyDeleteMachineFiles(in: createdDirectory, allowRemovingDirectory: true, approvedRoot: Self.root)
            }
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
        try fm.createDirectory(at: exports, withIntermediateDirectories: true)
        guard MachineStorageSafety.isSafeDirectory(exports, within: Self.inbox) else {
            throw message("匯出資料夾包含不安全的符號連結，未執行匯出。")
        }
        let safeName = MachineStorageSafety.exportFolderName(mac.name, fallbackID: mac.id)
        let final = exports.appendingPathComponent(safeName, isDirectory: true)
        // Each attempt keeps a unique staging folder, including complete exports from a failed commit.
        let partial = exports.appendingPathComponent(UUID().uuidString + ".moving", isDirectory: true)
        if fm.fileExists(atPath: final.path) {
            guard MachineStorageSafety.isOwnedMachineDirectory(
                final, within: Self.inbox, matchingECID: mac.ecid
            ),
                  MachineStorageSafety.containsOnlyMachineEntries(final, within: Self.inbox) else {
                throw message("匯出目的資料夾含有未知檔案，未覆寫或刪除既有資料。")
            }
        }
        let used = Int(mac.bytesUsed)
        let free = ExternalInstallStorage.volumeFreeBytes(at: Self.inbox)
        let needed = Int64(used) + (256 << 20)
        if free > 0 && free < needed {
            throw message("匯出「\(mac.name)」需要約 \(ByteText.string(UInt64(needed))) 可用空間，這台\(Device.name)目前剩餘 \(ByteText.string(UInt64(free)))。刪除已下載的 macOS 安裝檔可釋放約 16 GB。")
        }
        try fm.createDirectory(at: partial, withIntermediateDirectories: true)
        var packed = false
        var backupIdentity: MachineStorageSafety.DirectoryIdentity?
        do {
            let marker = try MachineStorageSafety.openRegularFile(
                partial.appendingPathComponent(Self.installingMarker), approvedRoot: Self.inbox,
                flags: O_WRONLY | O_CREAT | O_EXCL
            )
            close(marker)
            Self.writePortableManifest(for: mac, in: partial)
            try fm.copyItem(at: mac.rom, to: partial.appendingPathComponent("AVPBooter.vmapple2.bin"))
            try fm.copyItem(at: mac.aux, to: partial.appendingPathComponent("auxiliary.bin"))
            let source = mac.disk.path, target = partial.appendingPathComponent(Self.packedDisk).path
            let ok = await Task.detached { () -> Bool in
                hv_sparse_pack_progress(source, target, { done, total, _ in
                    let fraction = Double(done) / Double(max(total, 1))
                    Task { @MainActor in Machines.shared.exported = fraction }
                }, nil) == 0
            }.value
            guard ok else { throw message("磁碟無法寫入（可能是剩餘空間不足）。") }
            packed = true
            _ = try MachineStorageSafety.removeRegularFile(partial.appendingPathComponent(Self.installingMarker), approvedRoot: Self.inbox)
            Self.writePortableManifest(for: mac, in: partial)
            backupIdentity = try MachineStorageSafety.commitMachineExport(
                from: partial, to: final, approvedRoot: Self.inbox, matchingECID: mac.ecid
            )
        } catch {
            if !packed {
                _ = try? Self.safelyDeleteMachineFiles(in: partial, allowRemovingDirectory: true, approvedRoot: Self.inbox)
            }
            throw error
        }
        if let backupIdentity {
            do {
                _ = try MachineStorageSafety.deleteMachineFiles(
                    in: partial, approvedRoot: Self.inbox, allowRemovingDirectory: true,
                    matchingIdentity: backupIdentity
                )
            } catch {
                HengeLog.log("machines", "export committed; preserving previous backup at \(partial.path): \(error.localizedDescription)")
            }
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
    func ejectAllExternalMacs(
        on driveURL: URL?,
        markAsExplicitlyEjected: Bool = true,
        keepURL: URL? = nil,
        onlyDirectories: Set<String>? = nil
    ) -> Int {
        var matchedIDs: [UUID] = []
        for mac in all where mac.isExternal {
            if let onlyDirectories, !onlyDirectories.contains(ExternalDriveRegistry.canonicalPath(mac.directory)) {
                continue
            }
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
        let approvedRoot = isExternal ? ExternalDriveRegistry.shared.rootFolder(for: id) : Self.root
        let target = isExternal ? ExternalDriveRegistry.shared.driveTarget(for: id) : nil

        Task.detached(priority: .userInitiated) {
            var freedBytes: Int64 = 0
            var deleteError: Error?
            if available, let approvedRoot, !isExternal || target != nil {
                do {
                    freedBytes = try Self.safelyDeleteMachineFiles(
                        in: dir, allowRemovingDirectory: allowRemoveDir,
                        approvedRoot: approvedRoot, validating: target
                    )
                } catch {
                    deleteError = error
                }
            } else {
                deleteError = NSError(domain: "Henge", code: 1, userInfo: [NSLocalizedDescriptionKey: "外接 SSD 無法存取，未刪除系統或移除清單項目。"])
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
        deleteMacAsync(id, deleteExternalFiles: deleteExternalFiles)
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
        let dir = mac.directory
        let ok = MachineStorageSafety.isSafeDirectory(dir, within: resolved.folder)
            && Self.isValidPortableFolder(dir)
            && ((try? Data(contentsOf: dir.appendingPathComponent("machine.json")))
                .flatMap { try? JSONDecoder().decode(MachineFile.self, from: $0) }
                .map { $0.hasValidRAM && $0.ecid == mac.ecid } ?? false)
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
        guard MachineStorageSafety.isSafeDirectory(matchedDir, within: pickedURL),
              Self.isValidPortableFolder(matchedDir),
              let manifestData = try? Data(contentsOf: matchedDir.appendingPathComponent("machine.json")),
              let manifest = try? JSONDecoder().decode(MachineFile.self, from: manifestData),
              manifest.hasValidRAM, manifest.ecid == mac.ecid else {
            ExternalDriveRegistry.shared.releaseScopeIfUnused(for: pickedURL, keepURL: ExternalInstallStorage.shared.folderURL)
            lastError = "該資料夾不是「\(mac.name)」的完整系統，或記憶體設定無效，未重新掛載。"
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
        guard mac.isExternal != toExternal else { return mac }
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
            guard let target = ExternalInstallStorage.shared.currentDriveTarget(),
                  MachineStorageSafety.isOwnedMachineDirectory(sourceDir, within: Self.root, matchingECID: mac.ecid),
                  let machinesRoot = ExternalInstallStorage.shared.externalMachinesRoot else {
                throw message("無法確認來源系統或外接 SSD 的存取範圍，未搬移資料。")
            }
            let targetDir = machinesRoot.appendingPathComponent(mac.id.uuidString, isDirectory: true)
            try fm.createDirectory(at: machinesRoot, withIntermediateDirectories: true)
            guard MachineStorageSafety.isSafeDirectory(machinesRoot, within: extFolder) else {
                throw message("目的資料夾包含不安全的符號連結，未搬移資料。")
            }
            if fm.fileExists(atPath: targetDir.path) {
                guard MachineStorageSafety.isOwnedMachineDirectory(targetDir, within: extFolder, matchingECID: mac.ecid),
                      MachineStorageSafety.containsOnlyMachineEntries(targetDir, within: extFolder) else {
                    throw message("目的資料夾含有未知檔案或其他系統，未覆寫或刪除既有資料。")
                }
            }
            let partialDir = targetDir.deletingLastPathComponent().appendingPathComponent(mac.id.uuidString + ".moving", isDirectory: true)
            if fm.fileExists(atPath: partialDir.path) {
                guard MachineStorageSafety.containsOnlyMachineEntries(partialDir, within: extFolder) else {
                    throw message("暫存搬移資料夾含有未知檔案，未刪除既有資料。")
                }
                _ = try Self.safelyDeleteMachineFiles(in: partialDir, allowRemovingDirectory: true, approvedRoot: extFolder, validating: target)
            }
            try fm.createDirectory(at: partialDir, withIntermediateDirectories: true)
            let marker = try MachineStorageSafety.openRegularFile(
                partialDir.appendingPathComponent(Self.installingMarker), approvedRoot: extFolder,
                flags: O_WRONLY | O_CREAT | O_EXCL, validating: target
            )
            close(marker)
            do {
                try await Self.copyMachineFiles(
                    from: sourceDir, to: partialDir, sourceRoot: Self.root, targetRoot: extFolder,
                    targetAccess: target, sparseTarget: ExternalInstallStorage.shared.supportsSparseFiles
                ) { p in
                    Task { @MainActor in Machines.shared.moved = p }
                }
                if fm.fileExists(atPath: targetDir.path) {
                    guard MachineStorageSafety.containsOnlyMachineEntries(targetDir, within: extFolder) else {
                        throw message("目的資料夾出現未知檔案，已停止搬移並保留資料。")
                    }
                    _ = try Self.safelyDeleteMachineFiles(in: targetDir, allowRemovingDirectory: true, approvedRoot: extFolder, validating: target)
                }
                try MachineStorageSafety.promoteMachineDirectory(from: partialDir, to: targetDir, approvedRoot: extFolder, validating: target)
                _ = try? MachineStorageSafety.removeRegularFile(targetDir.appendingPathComponent(Self.installingMarker), approvedRoot: extFolder, validating: target)
            } catch {
                _ = try? Self.safelyDeleteMachineFiles(in: partialDir, allowRemovingDirectory: true, approvedRoot: extFolder, validating: target)
                throw error
            }
            let relativePath = extFolder.lastPathComponent == "HengeMachines" ? mac.id.uuidString : "HengeMachines/\(mac.id.uuidString)"
            ExternalDriveRegistry.shared.register(id: mac.id, folderURL: extFolder, relativePath: relativePath)
            clearEjectedFlag(for: mac.id)
            var updated = mac
            updated.externalFolderBookmark = bookmark
            updated.externalDriveName = driveName
            updated.externalRelativePath = relativePath
            updated.autoAdaptToHost = updated.autoAdaptToHost ?? true
            Self.writePortableManifest(for: updated, in: targetDir)
            update(updated)
            if fm.fileExists(atPath: targetDir.appendingPathComponent("disk.img").path) {
                _ = try? Self.safelyDeleteMachineFiles(in: sourceDir, allowRemovingDirectory: true, approvedRoot: Self.root)
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
            guard let sourceRoot = ExternalDriveRegistry.shared.rootFolder(for: mac.id),
                  let sourceAccess = ExternalDriveRegistry.shared.driveTarget(for: mac.id) else {
                throw message("外接 SSD 已中斷連線，未搬移資料。")
            }
            let targetDir = Self.directory(for: mac.id)
            if fm.fileExists(atPath: targetDir.path) {
                guard MachineStorageSafety.isOwnedMachineDirectory(targetDir, within: Self.root, matchingECID: mac.ecid),
                      MachineStorageSafety.containsOnlyMachineEntries(targetDir, within: Self.root) else {
                    throw message("本機目的資料夾含有未知檔案或其他系統，未覆寫既有資料。")
                }
            }
            let partialDir = Self.root.appendingPathComponent(mac.id.uuidString + ".moving", isDirectory: true)
            if fm.fileExists(atPath: partialDir.path) {
                guard MachineStorageSafety.containsOnlyMachineEntries(partialDir, within: Self.root) else {
                    throw message("本機暫存資料夾含有未知檔案，未刪除既有資料。")
                }
                _ = try Self.safelyDeleteMachineFiles(in: partialDir, allowRemovingDirectory: true, approvedRoot: Self.root)
            }
            try fm.createDirectory(at: partialDir, withIntermediateDirectories: true)
            let marker = try MachineStorageSafety.openRegularFile(
                partialDir.appendingPathComponent(Self.installingMarker), approvedRoot: Self.root,
                flags: O_WRONLY | O_CREAT | O_EXCL
            )
            close(marker)
            excludeFromBackup()
            do {
                try await Self.copyMachineFiles(
                    from: sourceDir, to: partialDir, sourceRoot: sourceRoot, targetRoot: Self.root,
                    sourceAccess: sourceAccess, sparseTarget: true
                ) { p in
                    Task { @MainActor in Machines.shared.moved = p }
                }
                if fm.fileExists(atPath: targetDir.path) {
                    guard MachineStorageSafety.containsOnlyMachineEntries(targetDir, within: Self.root) else {
                        throw message("本機目的資料夾出現未知檔案，已停止搬移並保留資料。")
                    }
                    _ = try Self.safelyDeleteMachineFiles(in: targetDir, allowRemovingDirectory: true, approvedRoot: Self.root)
                }
                try MachineStorageSafety.promoteMachineDirectory(from: partialDir, to: targetDir, approvedRoot: Self.root)
                _ = try? MachineStorageSafety.removeRegularFile(targetDir.appendingPathComponent(Self.installingMarker), approvedRoot: Self.root)
            } catch {
                _ = try? Self.safelyDeleteMachineFiles(in: partialDir, allowRemovingDirectory: true, approvedRoot: Self.root)
                throw error
            }
            var updated = mac
            updated.overrideRAMMB(updated.effectiveRAMMB)
            updated.externalFolderBookmark = nil
            updated.externalDriveName = nil
            updated.externalRelativePath = nil
            updated.autoAdaptToHost = false
            if updated.screenWidth == nil || updated.screenHeight == nil {
                (updated.screenWidth, updated.screenHeight) = Device.fittingScreen
            }
            update(updated)
            if fm.fileExists(atPath: targetDir.appendingPathComponent("disk.img").path) {
                _ = try? Self.safelyDeleteMachineFiles(
                    in: sourceDir, allowRemovingDirectory: mac.externalRelativePath != ".",
                    approvedRoot: sourceRoot, validating: sourceAccess
                )
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
        sourceRoot: URL,
        targetRoot: URL,
        sourceAccess: ExternalDriveTarget? = nil,
        targetAccess: ExternalDriveTarget? = nil,
        sparseTarget: Bool,
        progress: @escaping @Sendable (Double) -> Void
    ) async throws {
        try await Task.detached(priority: .userInitiated) {
            let fm = FileManager.default
            for name in ["AVPBooter.vmapple2.bin", "auxiliary.bin", "machine.json", installedMarker, "preview.jpg"] {
                let src = sourceDir.appendingPathComponent(name)
                if fm.fileExists(atPath: src.path) {
                    let input = try MachineStorageSafety.openRegularFile(src, approvedRoot: sourceRoot, validating: sourceAccess)
                    defer { close(input) }
                    let output = try MachineStorageSafety.openRegularFile(
                        targetDir.appendingPathComponent(name), approvedRoot: targetRoot,
                        flags: O_WRONLY | O_CREAT | O_EXCL, validating: targetAccess
                    )
                    defer { close(output) }
                    guard fcopyfile(input, output, nil, copyfile_flags_t(COPYFILE_DATA)) == 0 else {
                        throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno))
                    }
                }
            }
            let srcDisk = sourceDir.appendingPathComponent("disk.img").path
            let dstDisk = targetDir.appendingPathComponent("disk.img").path
            let inFD = try MachineStorageSafety.openRegularFile(URL(fileURLWithPath: srcDisk), approvedRoot: sourceRoot, validating: sourceAccess)
            defer { close(inFD) }
            var st = stat()
            guard fstat(inFD, &st) == 0, st.st_size > 0 else {
                throw NSError(domain: "Henge", code: 1, userInfo: [NSLocalizedDescriptionKey: "無法讀取磁碟大小。"])
            }
            let total = st.st_size
            let outFD = try MachineStorageSafety.openRegularFile(
                URL(fileURLWithPath: dstDisk), approvedRoot: targetRoot,
                flags: O_CREAT | O_EXCL | O_RDWR, validating: targetAccess
            )
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
            guard fsync(outFD) == 0 else { throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno)) }
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
        guard MachineStorageSafety.isSafeDirectory(folder, within: baseURL),
              Self.isValidPortableFolder(folder),
              let data = try? Data(contentsOf: folder.appendingPathComponent("machine.json")),
              let info = try? JSONDecoder().decode(MachineFile.self, from: data),
              info.hasValidRAM else {
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
        let diskSize = (try? folder.appendingPathComponent("disk.img").resourceValues(forKeys: [.fileSizeKey]))?.fileSize.map(Int64.init)
            ?? info.diskBytes.flatMap { $0 > 0 ? $0 : nil }
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
            ramMB: info.ramMB ?? Device.adaptiveGuestRAMMB,
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
        _ = try? MachineStorageSafety.removeManagedDirectory(
            folder.appendingPathComponent("restore"), approvedRoot: baseURL,
            validating: ExternalDriveRegistry.shared.driveTarget(for: mac.id)
        )
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
                          MachineStorageSafety.isRegularFile(item.appendingPathComponent(Self.installingMarker), within: baseURL),
                          !MachineStorageSafety.isRegularFile(item.appendingPathComponent(Self.installedMarker), within: baseURL) {
                    HengeLog.log("machines", "removing unfinished external machine \(item.lastPathComponent)")
                    _ = try? Self.safelyDeleteMachineFiles(
                        in: item, allowRemovingDirectory: true, approvedRoot: baseURL,
                        validating: ExternalInstallStorage.shared.currentDriveTarget()
                    )
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
