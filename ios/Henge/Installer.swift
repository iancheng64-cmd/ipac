import Foundation
import UIKit

/// A macOS restore image Apple publishes for virtual Macs (VirtualMac2,1).
struct MacOSRelease: Identifiable, Hashable {
    let id: String        // build
    let name: String
    let url: URL
    let bytes: Int64
    let note: String
    /// Room the new Mac takes once installed and set up, with a margin for its first updates and caches
    /// (installed and set up on the Mac in phone mode: Sonoma 21 GB, Ventura 19 GB).
    var macBytes: Int64 = 24 << 30

    /// The builds offered, oldest first. Apple's catalog (mesu.apple.com) only lists the newest;
    /// these are the same images from Apple's CDN, and Apple still signs them for virtual Macs.
    static let all: [MacOSRelease] = [
        /* macOS Monterey 12.6 (21G115, 2022FallFCS/fullrestores/012-40537/0EC7C669-13E9-49FB-BD64-9EECC1D174B2) installs and boots,
           but its GPU driver (protocol 0x1f) never starts WindowServer's GPU work under Henge yet: not offered until it does. */
        MacOSRelease(id: "22G120", name: "macOS Ventura 13.6",
                     url: URL(string: "https://updates.cdn-apple.com/2023FallFCS/fullrestores/042-55833/C0830847-A2F8-458F-B680-967991820931/UniversalMac_13.6_22G120_Restore.ipsw")!,
                     bytes: 12_297 << 20, note: "下載體積最小（總計約 35 GB），適合可用容量較緊張的裝置。", macBytes: 23 << 30),
        MacOSRelease(id: "23G93", name: "macOS Sonoma 14.6.1",
                     url: URL(string: "https://updates.cdn-apple.com/2024SummerFCS/fullrestores/062-52859/932E0A8F-6644-4759-82DA-F8FA8DEA806A/UniversalMac_14.6.1_23G93_Restore.ipsw")!,
                     bytes: 14_106 << 20, note: "下載檔案比 Sequoia 小（總計約 40 GB）。", macBytes: 26 << 30),
        MacOSRelease(id: "24G90", name: "macOS Sequoia 15.6.1",
                     url: URL(string: "https://updates.cdn-apple.com/2025SummerFCS/fullrestores/093-10809/CFD6DD38-DAF0-40DA-854F-31AAD1294C6F/UniversalMac_15.6.1_24G90_Restore.ipsw")!,
                     bytes: 16_035 << 20, note: "推薦：Henge 完整實測相容性最佳的版本。"),
        MacOSRelease(id: "25G83", name: "macOS Tahoe 26.6.2",
                     url: URL(string: "https://updates.cdn-apple.com/2026SummerFCS/fullrestores/140-75212/A2A24B94-1FC1-45A3-93F7-C51B02AF1F4D/UniversalMac_26.6.2_25G83_Restore.ipsw")!,
                     bytes: 18_856 << 20, note: "可安裝並運作，但首次建立帳號較慢（可能需約 10 分鐘）。"),
        MacOSRelease(id: "26B123", name: "macOS 27.2",
                     url: URL(string: "https://updates.cdn-apple.com/2026FallFCS/c9671975-52db-4fb5-9af2-00217169ba8d/UniversalMac_27.2_26B123_Restore.ipsw")!,
                     bytes: 24_409 << 20, note: "最新版本，目前執行速度較慢且 Safari 頁面可能顯示空白。"),
    ]

    /// Selected in the Install tab when nothing is downloaded yet: the one Henge is tested with most.
    static let recommended = all.first { $0.id == "24G90" } ?? all[0]
}

/// Downloads a restore image and installs it on a new virtual Mac, on the
/// iPhone/iPad: the machine boots its ROM in DFU mode and the restore runs over its
/// USB port, as Virtualization.framework's installer does on a Mac.
@MainActor
final class Installer: NSObject, ObservableObject {
    static let shared = Installer()

    enum Phase: Equatable {
        case idle
        case checking
        case downloading
        case preparing
        case installing
        case done(String)
        case failed(String)
    }

    @Published private(set) var phase: Phase = .idle
    @Published private(set) var received: Int64 = 0
    @Published private(set) var expected: Int64 = 0
    @Published private(set) var step: Int = 0
    @Published private(set) var stepProgress: Double = 0
    @Published private(set) var machineName = ""
    @Published private(set) var installingReleaseName = ""
    @Published private(set) var installingTargetLabel = ""

    /* Background time, so a moment out of the foreground (a notification, iPhone Mirroring reconnecting)
       does not suspend the restore at once; iOS gives about 30 s. */
    private var grace = UIBackgroundTaskIdentifier.invalid

    var busy: Bool {
        switch phase {
        case .checking, .downloading, .preparing, .installing: return true
        default: return false
        }
    }

    static var activeMode: InstallStorageMode {
        ExternalInstallStorage.shared.mode
    }

    static var usingExternalInstallFiles: Bool {
        activeMode.needsExternalDrive && ExternalInstallStorage.shared.isConfigured && ExternalInstallStorage.shared.isConnected
    }

    static var installingVMOnExternal: Bool {
        activeMode == .externalFull && ExternalInstallStorage.shared.isConfigured && ExternalInstallStorage.shared.isConnected
    }

    static var imageDirectory: URL {
        if usingExternalInstallFiles, let extDir = ExternalInstallStorage.shared.externalRestoreImagesDir {
            return extDir
        }
        return Machines.root.appendingPathComponent("Restore images", isDirectory: true)
    }

    static func managedImagePath(_ r: MacOSRelease) -> URL {
        imageDirectory.appendingPathComponent("\(r.id).ipsw")
    }

    static func imagePath(_ r: MacOSRelease) -> URL {
        let managed = managedImagePath(r)
        let values = try? managed.resourceValues(forKeys: [.fileSizeKey])
        if let size = values?.fileSize, Int64(size) > r.bytes / 2 {
            return managed
        }
        if usingExternalInstallFiles, let preexisting = ExternalInstallStorage.shared.preexistingImage(for: r) {
            return preexisting
        }
        return managed
    }

    static func isManagedImage(_ url: URL) -> Bool {
        url.deletingLastPathComponent().lastPathComponent == "Restore images"
    }

    /// The size of the image ready for install, if a whole one is there (the listed sizes are rounded).
    static func imageSize(_ r: MacOSRelease) -> Int64? {
        let values = try? imagePath(r).resourceValues(forKeys: [.fileSizeKey])
        guard let size = values?.fileSize, Int64(size) > r.bytes / 2 else { return nil }
        return Int64(size)
    }

    static func haveImage(_ r: MacOSRelease) -> Bool { imageSize(r) != nil }

    static func deleteImage(_ r: MacOSRelease) {
        try? FileManager.default.removeItem(at: managedImagePath(r))
        try? FileManager.default.removeItem(at: partPath(r))
        ExternalInstallStorage.shared.cleanupEmptyStagingIfUnused()
    }
    /// Where a download in progress (or stopped partway) is kept.
    static func partPath(_ r: MacOSRelease) -> URL { imageDirectory.appendingPathComponent("\(r.id).ipsw.part") }
    /// Bytes of a download that stopped partway, or nil.
    static func partSize(_ r: MacOSRelease) -> Int64? {
        let n = RangedDownload.size(of: partPath(r))
        return n > 0 ? n : nil
    }

    static func downloadSpaceNeeded(_ r: MacOSRelease) -> Int64 {
        haveImage(r) ? 0 : max(r.bytes - (partSize(r) ?? 0), 0)
    }

    static func vmDiskSpaceNeeded(_ r: MacOSRelease) -> Int64 {
        if activeMode == .externalFull && ExternalInstallStorage.shared.isConnected && !ExternalInstallStorage.shared.supportsSparseFiles {
            return 64 << 30
        }
        return r.macBytes
    }

    static func externalSpaceNeeded(_ r: MacOSRelease) -> Int64 {
        switch activeMode {
        case .internalOnly:
            return 0
        case .externalStaging:
            return downloadSpaceNeeded(r) + (1 << 30)
        case .externalFull:
            return downloadSpaceNeeded(r) + vmDiskSpaceNeeded(r) + (1 << 30)
        }
    }

    static func internalSpaceNeeded(_ r: MacOSRelease) -> Int64 {
        switch activeMode {
        case .internalOnly:
            return downloadSpaceNeeded(r) + r.macBytes
        case .externalStaging:
            return r.macBytes
        case .externalFull:
            return 2 << 30
        }
    }

    /// Free space an install takes on this device.
    static func spaceNeeded(_ r: MacOSRelease) -> Int64 { internalSpaceNeeded(r) }

    func reset() { if !busy { phase = .idle } }

    private func endGrace() {
        guard grace != .invalid else { return }
        UIApplication.shared.endBackgroundTask(grace)
        grace = .invalid
    }

    private static func cleanupSystemTemporaryDownloads() {
        let tmp = URL(fileURLWithPath: NSTemporaryDirectory())
        guard let names = try? FileManager.default.contentsOfDirectory(atPath: tmp.path) else { return }
        for name in names where name.hasPrefix("CFNetworkDownload_") && name.hasSuffix(".tmp") {
            try? FileManager.default.removeItem(at: tmp.appendingPathComponent(name))
        }
    }

    func start(_ release: MacOSRelease, name: String, ramMB: Int, cpus: Int, keepImage: Bool) {
        guard !busy else { return }
        phase = .checking
        machineName = name
        installingReleaseName = release.name
        installingTargetLabel = Self.installingVMOnExternal
            ? "外接 SSD「\(ExternalInstallStorage.shared.configuredName ?? "外接 SSD")」"
            : "這台 \(Device.name)"
        UIApplication.shared.isIdleTimerDisabled = true // the screen locking would suspend the download and the restore
        grace = UIApplication.shared.beginBackgroundTask(withName: "Henge install") {
            MainActor.assumeIsolated { Installer.shared.endGrace() }
        }
        Task {
            defer { UIApplication.shared.isIdleTimerDisabled = false; endGrace() }
            var made: VirtualMac?
            var mode = Self.activeMode
            var usedExternalFiles = false
            var vmOnExternal = false
            var driveName = "外接 SSD"
            do {
                try checkSpace(release)
                mode = Self.activeMode
                usedExternalFiles = Self.usingExternalInstallFiles
                vmOnExternal = Self.installingVMOnExternal
                driveName = ExternalInstallStorage.shared.configuredName ?? "外接 SSD"
                installingTargetLabel = vmOnExternal ? "外接 SSD「\(driveName)」" : "這台 \(Device.name)"
                let rom = try await BootROM.file() // before the long download, so a problem shows up at once
                HengeLog.log("install", "boot ROM ready (mode=\(mode.rawValue))")
                let ipsw = try await download(release)
                phase = .preparing
                var mac = try await prepare(name: name, ramMB: ramMB, cpus: cpus, rom: rom, onExternal: vmOnExternal)
                mac.osName = release.name
                made = mac
                phase = .installing
                try await install(mac, ipsw: ipsw, cpus: cpus, useExternalWorkdir: usedExternalFiles)
                if !keepImage && Self.isManagedImage(ipsw) {
                    try? FileManager.default.removeItem(at: ipsw)
                    try? FileManager.default.removeItem(at: Self.partPath(release))
                }
                Self.cleanupSystemTemporaryDownloads()
                if usedExternalFiles {
                    ExternalInstallStorage.shared.cleanupEmptyStagingIfUnused(force: true)
                }
                HengeLog.log("install", "\(name): installed \(release.name) (mode=\(mode.rawValue))")
                switch mode {
                case .internalOnly:
                    phase = .done("已將 \(release.name) 安裝至「\(name)」。請從多工上滑完全關閉 Henge 後重新開啟，即可點按「啟動」。")
                case .externalStaging:
                    phase = .done("已將 \(release.name) 安裝至「\(name)」（本機空間），並已自動清除 \(driveName) 上的暫存安裝檔，現在可以拔除硬碟。請從多工上滑完全關閉 Henge 後重新開啟，即可點按「啟動」。")
                case .externalFull:
                    phase = .done("已將 \(release.name) 完整安裝於「\(name)」（外接 SSD：\(driveName)），暫存安裝檔已自動清除。未來啟動或拔除前請務必注意連接狀態。請從多工上滑完全關閉 Henge 後重新開啟，即可點按「啟動」。")
                }
            } catch {
                HengeLog.log("install", "failed: \(error.localizedDescription)")
                // A half-installed Mac is no use, and its disk can be many gigabytes. The download stays.
                if let made {
                    if henge_vm_state() == 1 {
                        henge_vm_stop()
                        for _ in 0..<50 where henge_vm_state() == 3 {
                            try? await Task.sleep(nanoseconds: 100_000_000)
                        }
                    }
                    if henge_vm_state() != 1 {
                        _ = try? Machines.safelyDeleteMachineFiles(in: made.directory, allowRemovingDirectory: true)
                        if made.isExternal {
                            ExternalDriveRegistry.shared.unregister(
                                id: made.id,
                                releaseEvenIfMounted: false,
                                keepURL: ExternalInstallStorage.shared.folderURL
                            )
                        }
                    }
                }
                if usedExternalFiles {
                    ExternalInstallStorage.shared.cleanupEmptyStagingIfUnused(force: true)
                }
                phase = .failed(error.localizedDescription)
            }
        }
    }

    private func checkSpace(_ r: MacOSRelease) throws {
        ExternalInstallStorage.shared.refreshConnection()
        if Self.activeMode.needsExternalDrive {
            guard ExternalInstallStorage.shared.isConfigured else {
                throw message("請先選擇外接 SSD 資料夾，或將安裝位置切回「本機儲存」。")
            }
            guard ExternalInstallStorage.shared.isConnected else {
                let drive = ExternalInstallStorage.shared.configuredName ?? "外接 SSD"
                throw message("外接 SSD（\(drive)）未連接。請插上硬碟或切回「本機儲存」。")
            }
        }
        let free = ExternalInstallStorage.volumeFreeBytes(at: URL(fileURLWithPath: NSHomeDirectory()))
        let needed = Self.internalSpaceNeeded(r)
        if free > 0 && free < needed {
            throw message("此\(Device.name)需要約 \(ByteText.string(UInt64(needed))) 本機可用空間，目前剩餘 \(ByteText.string(UInt64(free)))。")
        }
        if Self.activeMode.needsExternalDrive {
            let extFree = ExternalInstallStorage.shared.freeBytes
            let extNeeded = Self.externalSpaceNeeded(r)
            if extFree > 0 && extFree < extNeeded {
                let drive = ExternalInstallStorage.shared.configuredName ?? "外接 SSD"
                throw message("「\(drive)」需要約 \(ByteText.string(UInt64(extNeeded))) 可用空間，目前僅剩 \(ByteText.string(UInt64(extFree)))。")
            }
        }
    }

    // MARK: Download

    private func download(_ r: MacOSRelease) async throws -> URL {
        if Self.haveImage(r) {
            HengeLog.log("install", "using the downloaded \(r.name)")
            return Self.imagePath(r)
        }
        let dest = Self.managedImagePath(r)
        try FileManager.default.createDirectory(at: Self.imageDirectory, withIntermediateDirectories: true)
        Machines.excludeFromBackup(Self.imageDirectory)
        phase = .downloading
        // Into a .part file next to where it ends up: an interrupted download (no network, Henge closed or killed)
        // goes on from where it stopped next time, and Install's trash button deletes a partial one too (#58).
        let part = Self.partPath(r)
        received = RangedDownload.size(of: part)
        expected = r.bytes
        if received > 0 { HengeLog.log("install", "going on with \(r.name)'s download from \(ByteText.string(UInt64(received)))") }
        HengeLog.log("install", "downloading \(r.url.absoluteString)")
        for attempt in 1...20 {
            let d = RangedDownload(url: r.url, part: part) { have, total in
                Task { @MainActor in
                    Installer.shared.received = have
                    if total > 0 { Installer.shared.expected = total }
                }
            }
            do {
                try await d.run()
                try? FileManager.default.removeItem(at: dest)
                try FileManager.default.moveItem(at: part, to: dest)
                return dest
            } catch {
                if Task.isCancelled || attempt == 20 { throw error }
                HengeLog.log("install", "download interrupted (\(error.localizedDescription)) at \(ByteText.string(UInt64(RangedDownload.size(of: part)))); going on")
                try await Task.sleep(nanoseconds: 3_000_000_000)
            }
        }
        throw message("下載持續失敗，請稍後再試。")
    }


    // MARK: The new machine

    private func prepare(name: String, ramMB: Int, cpus: Int, rom: URL, onExternal: Bool) async throws -> VirtualMac {
        // A new machine identity, as VZMacMachineIdentifier makes one: a random ECID.
        let ecid = UInt64.random(in: 1 << 40 ..< 1 << 62)
        var mac = VirtualMac(
            name: name,
            ecid: ecid,
            seed: 0,
            ramMB: ramMB,
            diskBytes: 64 << 30,
            reportHostIdentity: true,
            autoAdaptToHost: onExternal ? true : false,
            cpuCount: cpus
        )
        if onExternal {
            guard let bookmark = ExternalInstallStorage.shared.bookmarkData else {
                throw message("外接硬碟權限遺失，請重新選擇外接硬碟資料夾。")
            }
            let driveName = ExternalInstallStorage.shared.configuredName ?? "外接 SSD"
            mac.externalFolderBookmark = bookmark
            mac.externalDriveName = driveName
            guard ExternalDriveRegistry.shared.resolveAndRegister(id: mac.id, bookmark: bookmark) != nil else {
                throw message("無法存取「\(driveName)」，請確認外接硬碟已連接且可寫入。")
            }
        }
        (mac.screenWidth, mac.screenHeight) = Device.fittingScreen
        let fm = FileManager.default
        let dir = mac.directory
        let romDest = mac.rom
        let diskDest = mac.disk
        let auxDest = mac.aux
        try fm.createDirectory(at: dir, withIntermediateDirectories: true)
        if !onExternal {
            Machines.excludeFromBackup(Machines.root)
        }
        try? Data().write(to: dir.appendingPathComponent(Machines.installingMarker), options: .atomic)
        try? fm.removeItem(at: romDest)
        try fm.copyItem(at: rom, to: romDest)
        // Run disk allocation off the main thread so non-sparse volumes (exFAT) never stall the UI or trip the watchdog.
        try await Task.detached(priority: .userInitiated) {
            guard FileManager.default.createFile(atPath: diskDest.path, contents: nil) else {
                throw NSError(domain: "Henge", code: 2, userInfo: [NSLocalizedDescriptionKey: "無法建立虛擬磁碟檔 disk.img。"])
            }
            let h = try FileHandle(forWritingTo: diskDest)
            try h.truncate(atOffset: UInt64(64) << 30)
            try h.close()
        }.value
        guard henge_make_aux(auxDest.path) == 0 else { throw message("無法建立輔助儲存區 auxiliary.bin。") }
        Machines.writePortableManifest(for: mac, in: dir)
        mac.diskBytes = 64 << 30
        HengeLog.log("install", "new machine \(name): ECID \(ecid), 64 GB disk (\(onExternal ? "external" : "internal"))")
        return mac
    }

    // MARK: The restore

    private func install(_ mac: VirtualMac, ipsw: URL, cpus: Int, useExternalWorkdir: Bool) async throws {
        guard JITBootstrap.ready else { throw message("請先開啟 JIT：安裝程式需要 JIT 才能執行 macOS 回復環境。") }
        // The restore needs 2 GB, whatever the Mac is set to use afterwards, and gets at most 4 GB: the restore system
        // caches the ~15 GB it writes, so it fills all the memory it is given, and 10 GB of a 12 GB iPhone's RAM in use
        // (it is outside Henge's footprint, so iOS does not stop it) stalls the whole phone two thirds of the way through.
        var restoring = mac
        restoring.ramMB = min(max(mac.ramMB, 2048), 4096)
        let ram = GuestMemory.prepare(restoring, requestedRAMMB: restoring.ramMB)
        guard ram >= 2048 else { throw message("安裝需要至少 2 GB 的本機可用空間做為虛擬記憶體緩衝。") }
        setenv("HV_WRITE_CACHE", "0", 1) // the ~15 GB the restore writes goes straight to storage (host/disk.c); this process runs no other Mac
        let work: URL
        if useExternalWorkdir, let staging = ExternalInstallStorage.shared.stagingRoot {
            work = staging.appendingPathComponent("restore-\(mac.id.uuidString)", isDirectory: true)
        } else {
            work = mac.directory.appendingPathComponent("restore", isDirectory: true)
        }
        try FileManager.default.createDirectory(at: work, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: work) }
        var buffer = [CChar](repeating: 0, count: 256)
        let rc = henge_vm_install(mac.rom.path, mac.disk.path, mac.aux.path, mac.ecid, ipsw.path, work.path, ram, Int32(cpus),
                                  &buffer, buffer.count)
        if rc != 0 { throw message(String(cString: buffer)) }
        while true {
            try await Task.sleep(nanoseconds: 1_000_000_000)
            step = Int(henge_install_step())
            stepProgress = henge_install_progress()
            if step == 100 { break }
            if step == 101 { throw message("系統還原安裝失敗，詳細原因請檢視日誌（設定 → 分享 henge.log）。") }
            if henge_vm_state() == 2 && step < 100 {
                // The restore ends with the machine restarting, and idevicerestore finishes a
                // little after; a stop with no result after that is a failure.
                for _ in 0..<90 where henge_install_step() < 100 { try await Task.sleep(nanoseconds: 1_000_000_000) }
                if henge_install_step() == 100 { break }
                throw message("安裝過程中虛擬機提前停止（\(String(cString: henge_vm_exit_reason()))）。")
            }
        }
        // In the list before anything else: stopping the restore system can take a while, and if Henge is
        // stopped meanwhile (the phone locked) a finished Mac must not be left on the disk unlisted.
        try? (mac.osName ?? "").write(to: mac.directory.appendingPathComponent(Machines.installedMarker), atomically: true, encoding: .utf8)
        try? FileManager.default.removeItem(at: mac.directory.appendingPathComponent(Machines.installingMarker))
        Machines.writePortableManifest(for: mac, in: mac.directory)
        Machines.shared.add(mac)
        HengeLog.log("install", "\(mac.name): restore finished, added to the Macs")
        if henge_vm_state() == 1 { henge_vm_stop() }
    }

    static func stepName(_ step: Int) -> String {
        switch step {
        case 0: return "正在尋找虛擬 Mac"
        case 1: return "正在啟動安裝程式"
        case 2: return "正在寫入 macOS 系統"
        case 3: return "正在驗證 macOS"
        case 4: return "正在安裝韌體"
        case 6, 7: return "正在安裝系統檔案"
        default: return "安裝中"
        }
    }

    private func message(_ text: String) -> NSError {
        NSError(domain: "Henge", code: 2, userInfo: [NSLocalizedDescriptionKey: text])
    }
}
