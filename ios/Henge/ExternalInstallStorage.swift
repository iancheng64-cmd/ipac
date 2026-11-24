import Darwin
import Foundation

/// The three ways Henge can use storage when installing and running macOS:
/// 1. `internalOnly`: Stock behavior — installer files and the virtual Mac both stay on this iPad.
/// 2. `externalStaging`: Installer downloads (.ipsw) and temporary restore cache use the external USB-C drive
///    and are automatically cleaned up after install; the installed Mac lives on this iPad and runs without the drive.
/// 3. `externalFull`: Installer files AND the entire virtual Mac (disk.img, NVRAM, ROM) live on the external USB-C
///    drive, taking almost zero internal iPad space; requires the drive plugged in whenever running that Mac.
enum InstallStorageMode: String, CaseIterable, Identifiable, Codable {
    case internalOnly
    case externalStaging
    case externalFull

    var id: String { rawValue }

    var title: String {
        switch self {
        case .internalOnly:
            return "本機儲存（原始模式）"
        case .externalStaging:
            return "外接安裝 → 存回本機"
        case .externalFull:
            return "完整外接 SSD（隨身模式）"
        }
    }

    var shortTitle: String {
        switch self {
        case .internalOnly:
            return "此 \(Device.name)"
        case .externalStaging:
            return "外接安裝 → \(Device.name)"
        case .externalFull:
            return "完整外接 SSD"
        }
    }

    var subtitle: String {
        switch self {
        case .internalOnly:
            return "原始模式：直接在此 \(Device.name) 內部空間下載並安裝 macOS。"
        case .externalStaging:
            return "適合 64 GB \(Device.name)：將 12–24 GB 安裝檔與暫存檔放在外接硬碟，安裝完成後自動清除，最後成品留在 \(Device.name) 內可拔除硬碟使用。"
        case .externalFull:
            return "將安裝檔與整個 Mac 系統（64 GB disk.img）都放在外接 SSD，幾乎不佔 \(Device.name) 本機空間，插上別台 iPad 也能直接開機執行。"
        }
    }

    var needsExternalDrive: Bool {
        self != .internalOnly
    }
}

/// Thread-safe registry of resolved security-scoped external drive folders for individual VirtualMacs
/// and `ExternalInstallStorage`. Centralizing security-scoped URL retention by canonical path prevents
/// one subsystem (or one VM) from revoking the process-wide iOS sandbox extension while another VM or
/// the installer is still accessing the same external USB drive.
final class ExternalDriveRegistry: @unchecked Sendable {
    static let shared = ExternalDriveRegistry()

    private let lock = NSLock()
    private var folders: [UUID: URL] = [:]
    private var relativePaths: [UUID: String] = [:]
    private var activeScopesByPath: [String: URL] = [:]

    private init() {}

    nonisolated static func canonicalPath(_ url: URL) -> String {
        url.resolvingSymlinksInPath().standardizedFileURL.path
    }

    nonisolated static func isSameVolumeOrPath(_ a: URL, _ b: URL) -> Bool {
        let pa = canonicalPath(a)
        let pb = canonicalPath(b)
        if pa == pb || pa.hasPrefix(pb + "/") || pb.hasPrefix(pa + "/") {
            return true
        }
        if let va = (try? a.resourceValues(forKeys: [.volumeUUIDStringKey]))?.volumeUUIDString,
           let vb = (try? b.resourceValues(forKeys: [.volumeUUIDStringKey]))?.volumeUUIDString,
           !va.isEmpty && va == vb {
            return true
        }
        if let volA = (try? a.resourceValues(forKeys: [.volumeURLKey]))?.volume,
           let volB = (try? b.resourceValues(forKeys: [.volumeURLKey]))?.volume,
           canonicalPath(volA) == canonicalPath(volB) {
            return true
        }
        var sa = statfs()
        var sb = statfs()
        if statfs(a.path, &sa) == 0 && statfs(b.path, &sb) == 0 {
            let mntA = withUnsafeBytes(of: sa.f_mntonname) {
                String(cString: $0.bindMemory(to: CChar.self).baseAddress!)
            }
            let mntB = withUnsafeBytes(of: sb.f_mntonname) {
                String(cString: $0.bindMemory(to: CChar.self).baseAddress!)
            }
            if !mntA.isEmpty && mntA != "/" && mntA == mntB {
                return true
            }
        }
        return false
    }

    /// Ensures security-scoped access is active for `url` without revoking existing access on the same path.
    @discardableResult
    func retainScope(for url: URL) -> Bool {
        let key = Self.canonicalPath(url)
        lock.lock()
        if activeScopesByPath[key] != nil {
            lock.unlock()
            return true
        }
        lock.unlock()

        let granted = url.startAccessingSecurityScopedResource()
        if granted {
            lock.lock()
            if activeScopesByPath[key] == nil {
                activeScopesByPath[key] = url
                lock.unlock()
            } else {
                lock.unlock()
                url.stopAccessingSecurityScopedResource()
            }
        }
        return granted
    }

    /// Releases a cached security scope only when its path is no longer mounted/reachable.
    func releaseScopeIfUnmounted(for url: URL) {
        let key = Self.canonicalPath(url)
        var isDir: ObjCBool = false
        let mounted = FileManager.default.fileExists(atPath: url.path, isDirectory: &isDir)
            && isDir.boolValue
            && FileManager.default.isWritableFile(atPath: url.path)
        guard !mounted else { return }
        lock.lock()
        let old = activeScopesByPath.removeValue(forKey: key)
        lock.unlock()
        old?.stopAccessingSecurityScopedResource()
    }

    /// Releases a cached security scope if no remaining Mac (nor `keepURL`) uses the same canonical path.
    func releaseScopeIfUnused(for url: URL, keepURL: URL? = nil) {
        let key = Self.canonicalPath(url)
        let keepKey = keepURL.map { Self.canonicalPath($0) }
        lock.lock()
        let stillUsedByFolder = folders.values.contains { Self.canonicalPath($0) == key }
        let stillUsedByKeep = (keepKey == key)
        let old = (!stillUsedByFolder && !stillUsedByKeep) ? activeScopesByPath.removeValue(forKey: key) : nil
        lock.unlock()
        old?.stopAccessingSecurityScopedResource()
    }

    /// Releases all security scopes belonging to the ejected/removed drive volume or path.
    func forceReleaseAllScopes(matching driveURL: URL) {
        lock.lock()
        var toStop: [URL] = []
        for (key, url) in activeScopesByPath where Self.isSameVolumeOrPath(url, driveURL) {
            toStop.append(url)
            activeScopesByPath.removeValue(forKey: key)
        }
        lock.unlock()
        for url in toStop {
            url.stopAccessingSecurityScopedResource()
        }
    }

    /// Releases every active security scope held by Henge.
    func forceReleaseAllScopes() {
        lock.lock()
        let toStop = Array(activeScopesByPath.values)
        activeScopesByPath.removeAll()
        lock.unlock()
        for url in toStop {
            url.stopAccessingSecurityScopedResource()
        }
    }

    func register(id: UUID, folderURL: URL, relativePath: String? = nil) {
        _ = retainScope(for: folderURL)
        lock.lock()
        let previous = folders[id]
        folders[id] = folderURL
        if let relativePath {
            relativePaths[id] = relativePath
        } else {
            relativePaths.removeValue(forKey: id)
        }
        lock.unlock()
        if let previous, Self.canonicalPath(previous) != Self.canonicalPath(folderURL) {
            releaseScopeIfUnused(for: previous, keepURL: nil)
        }
    }

    func unregister(id: UUID, releaseEvenIfMounted: Bool = false, keepURL: URL? = nil) {
        lock.lock()
        let old = folders.removeValue(forKey: id)
        relativePaths.removeValue(forKey: id)
        lock.unlock()
        if let old {
            if releaseEvenIfMounted {
                releaseScopeIfUnused(for: old, keepURL: keepURL)
            } else {
                releaseScopeIfUnmounted(for: old)
            }
        }
    }

    func rootFolder(for id: UUID) -> URL? {
        lock.lock()
        defer { lock.unlock() }
        return folders[id]
    }

    /// Resolves the machine directory for `id` using an optional stored `relativePath`, or by probing
    /// `<Drive>/HengeMachines/<id>`, `<Drive>/<id>`, `<Drive>` itself, or `<Drive>/HengeMachines`.
    nonisolated static func resolveMachineDirectory(in base: URL, for id: UUID, relativePath: String? = nil) -> URL {
        if let rel = relativePath {
            if rel.isEmpty || rel == "." {
                return base
            }
            return base.appendingPathComponent(rel, isDirectory: true)
        }
        if base.lastPathComponent.lowercased() == id.uuidString.lowercased() {
            return base
        }
        if base.lastPathComponent == "HengeMachines" {
            return base.appendingPathComponent(id.uuidString, isDirectory: true)
        }
        let fm = FileManager.default
        if fm.fileExists(atPath: base.appendingPathComponent("disk.img").path),
           fm.fileExists(atPath: base.appendingPathComponent("machine.json").path) {
            return base
        }
        let standard = base
            .appendingPathComponent("HengeMachines", isDirectory: true)
            .appendingPathComponent(id.uuidString, isDirectory: true)
        if fm.fileExists(atPath: standard.path) {
            return standard
        }
        let directChild = base.appendingPathComponent(id.uuidString, isDirectory: true)
        if fm.fileExists(atPath: directChild.appendingPathComponent("disk.img").path) {
            return directChild
        }
        return standard
    }

    func machineDirectory(for id: UUID) -> URL? {
        lock.lock()
        let base = folders[id]
        let rel = relativePaths[id]
        lock.unlock()
        guard let base else { return nil }
        return Self.resolveMachineDirectory(in: base, for: id, relativePath: rel)
    }

    @discardableResult
    func resolveAndRegister(id: UUID, bookmark: Data, relativePath: String? = nil) -> (folder: URL, refreshedBookmark: Data?)? {
        lock.lock()
        let existing = folders[id]
        lock.unlock()

        let fm = FileManager.default
        if let existing {
            var isDir: ObjCBool = false
            if fm.fileExists(atPath: existing.path, isDirectory: &isDir),
               isDir.boolValue,
               fm.isWritableFile(atPath: existing.path) {
                lock.lock()
                if let relativePath {
                    relativePaths[id] = relativePath
                } else {
                    relativePaths.removeValue(forKey: id)
                }
                lock.unlock()
                return (existing, nil)
            }
            releaseScopeIfUnmounted(for: existing)
        }

        do {
            var stale = false
            let url = try URL(resolvingBookmarkData: bookmark, options: [], relativeTo: nil, bookmarkDataIsStale: &stale)
            _ = retainScope(for: url)
            var isDir: ObjCBool = false
            let reachable = fm.fileExists(atPath: url.path, isDirectory: &isDir)
                && isDir.boolValue
                && fm.isWritableFile(atPath: url.path)

            guard reachable else {
                releaseScopeIfUnmounted(for: url)
                unregister(id: id)
                return nil
            }

            register(id: id, folderURL: url, relativePath: relativePath)
            var refreshed: Data?
            if stale {
                refreshed = try? url.bookmarkData(options: [], includingResourceValuesForKeys: nil, relativeTo: nil)
            }
            return (url, refreshed)
        } catch {
            unregister(id: id)
            return nil
        }
    }
}

struct ExternalDriveHengeSummary: Equatable {
    var driveName: String
    var machineCount: Int
    var hasInstallFiles: Bool
    var totalBytes: Int64
    var isEmpty: Bool { machineCount == 0 && !hasInstallFiles && totalBytes == 0 }
}

/// Manages the user-selected external drive folder and active `InstallStorageMode`.
@MainActor
final class ExternalInstallStorage: ObservableObject {
    static let shared = ExternalInstallStorage()

    private static let modeKey = "henge.installStorageMode"
    private static let bookmarkKey = "henge.externalInstallBookmark"
    private static let nameKey = "henge.externalInstallName"

    @Published var mode: InstallStorageMode {
        didSet {
            UserDefaults.standard.set(mode.rawValue, forKey: Self.modeKey)
            HengeLog.log("storage", "install storage mode set to \(mode.rawValue)")
        }
    }

    @Published private(set) var folderURL: URL?
    @Published private(set) var configuredName: String?
    @Published private(set) var isConnected = false
    @Published private(set) var supportsSparseFiles = true
    @Published private(set) var filesystemType: String?
    @Published private(set) var isClearing = false
    @Published var lastError: String?
    @Published var statusMessage: String?

    private init() {
        if let raw = UserDefaults.standard.string(forKey: Self.modeKey),
           let saved = InstallStorageMode(rawValue: raw) {
            self.mode = saved
        } else {
            self.mode = .internalOnly
        }
        refreshConnection()
    }

    var bookmarkData: Data? {
        UserDefaults.standard.data(forKey: Self.bookmarkKey)
    }

    var isConfigured: Bool {
        bookmarkData != nil
    }

    var effectiveDriveURL: URL? {
        if isConnected, let folderURL {
            return folderURL
        }
        let fm = FileManager.default
        for mac in Machines.shared.all where mac.isExternal && mac.isAvailable {
            if let root = ExternalDriveRegistry.shared.rootFolder(for: mac.id) {
                var isDir: ObjCBool = false
                if fm.fileExists(atPath: root.path, isDirectory: &isDir),
                   isDir.boolValue,
                   fm.isWritableFile(atPath: root.path) {
                    return root
                }
            }
        }
        return nil
    }

    var effectiveDriveName: String {
        if let configuredName, !configuredName.isEmpty {
            return configuredName
        }
        return Machines.shared.all.first(where: \.isExternal)?.externalDriveName ?? "外接 SSD"
    }

    var canClearDrive: Bool {
        effectiveDriveURL != nil
    }

    func unbindDriveIfMatching(_ driveURL: URL?, fallbackName: String? = nil) {
        let matchesByURL: Bool = {
            guard let current = folderURL, let driveURL else { return false }
            return ExternalDriveRegistry.isSameVolumeOrPath(current, driveURL)
        }()
        let matchesByName = !isConnected && isConfigured && fallbackName != nil && configuredName == fallbackName
        guard matchesByURL || matchesByName else { return }

        UserDefaults.standard.removeObject(forKey: Self.bookmarkKey)
        UserDefaults.standard.removeObject(forKey: Self.nameKey)
        folderURL = nil
        configuredName = nil
        isConnected = false
        filesystemType = nil
        supportsSparseFiles = true
        if mode.needsExternalDrive {
            mode = .internalOnly
        }
    }

    var stagingRoot: URL? {
        folderURL?.appendingPathComponent("HengeInstall", isDirectory: true)
    }

    var externalRestoreImagesDir: URL? {
        stagingRoot?.appendingPathComponent("Restore images", isDirectory: true)
    }

    var externalMachinesRoot: URL? {
        guard let folderURL else { return nil }
        if folderURL.lastPathComponent == "HengeMachines" {
            return folderURL
        }
        return folderURL.appendingPathComponent("HengeMachines", isDirectory: true)
    }

    var freeBytes: Int64 {
        folderURL.map { Self.volumeFreeBytes(at: $0) } ?? 0
    }

    nonisolated static func volumeFreeBytes(at url: URL) -> Int64 {
        if let values = try? url.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey, .volumeAvailableCapacityKey]) {
            if let important = values.volumeAvailableCapacityForImportantUsage, important > 0 {
                return important
            }
            if let regular = values.volumeAvailableCapacity, regular > 0 {
                return Int64(regular)
            }
        }
        var st = statvfs()
        if statvfs(url.path, &st) == 0 {
            let (bytes, overflow) = UInt64(st.f_bavail).multipliedReportingOverflow(by: UInt64(st.f_frsize))
            return overflow ? Int64.max : Int64(min(bytes, UInt64(Int64.max)))
        }
        return 0
    }

    nonisolated static func volumeTotalBytes(at url: URL) -> Int64 {
        if let total = (try? url.resourceValues(forKeys: [.volumeTotalCapacityKey]))?.volumeTotalCapacity, total > 0 {
            return Int64(total)
        }
        var st = statvfs()
        if statvfs(url.path, &st) == 0 {
            let (bytes, overflow) = UInt64(st.f_blocks).multipliedReportingOverflow(by: UInt64(st.f_frsize))
            return overflow ? Int64.max : Int64(min(bytes, UInt64(Int64.max)))
        }
        return 0
    }

    nonisolated static func filesystemInfo(at url: URL) -> (name: String?, supportsSparse: Bool) {
        let resourceSparse = (try? url.resourceValues(forKeys: [.volumeSupportsSparseFilesKey]))?.volumeSupportsSparseFiles
        var st = statfs()
        var rawFS: String?
        if statfs(url.path, &st) == 0 {
            rawFS = withUnsafePointer(to: &st.f_fstypename) {
                $0.withMemoryRebound(to: CChar.self, capacity: Int(MFSTYPENAMELEN)) {
                    String(cString: $0)
                }
            }.lowercased()
        }
        let prettyName: String? = {
            guard let rawFS, !rawFS.isEmpty else { return nil }
            switch rawFS {
            case "apfs": return "APFS"
            case "exfat": return "exFAT"
            case "msdos", "fat32": return "FAT32"
            case "hfs": return "HFS+"
            case "ntfs": return "NTFS"
            default: return rawFS.uppercased()
            }
        }()
        let sparse: Bool
        if let resourceSparse {
            sparse = resourceSparse
        } else if let rawFS {
            sparse = (rawFS == "apfs")
        } else {
            sparse = true
        }
        return (prettyName, sparse)
    }

    nonisolated static func volumeName(at url: URL) -> String {
        let vol = ((try? url.resourceValues(forKeys: [.volumeNameKey]))?.volumeName ?? "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let last = url.lastPathComponent
        if !vol.isEmpty && !last.isEmpty && last != "/" && last != vol {
            return "\(vol) / \(last)"
        }
        if !vol.isEmpty { return vol }
        return last.isEmpty ? "外接硬碟" : last
    }

    nonisolated static func directoryBytes(_ dir: URL) -> Int64 {
        let fm = FileManager.default
        guard let e = fm.enumerator(at: dir, includingPropertiesForKeys: [.isRegularFileKey, .totalFileAllocatedSizeKey, .fileSizeKey]) else {
            return 0
        }
        var total: Int64 = 0
        for case let url as URL in e {
            let vals = try? url.resourceValues(forKeys: [.isRegularFileKey, .totalFileAllocatedSizeKey, .fileSizeKey])
            guard vals?.isRegularFile == true else { continue }
            if let allocated = vals?.totalFileAllocatedSize, allocated > 0 {
                total += Int64(allocated)
            } else if let size = vals?.fileSize, size > 0 {
                total += Int64(size)
            }
        }
        return total
    }

    @discardableResult
    func selectFolder(_ pickedURL: URL) -> Bool {
        lastError = nil
        statusMessage = nil
        _ = ExternalDriveRegistry.shared.retainScope(for: pickedURL)

        let probe = pickedURL.appendingPathComponent(".henge_probe_\(UUID().uuidString)")
        do {
            try Data().write(to: probe)
            try? FileManager.default.removeItem(at: probe)
        } catch {
            ExternalDriveRegistry.shared.releaseScopeIfUnused(for: pickedURL, keepURL: folderURL)
            lastError = "這個資料夾無法寫入（例如唯讀 NTFS 格式）。請將外接 SSD 格式化為 APFS 或 exFAT 後再選擇。"
            HengeLog.log("storage", "selected folder not writable (\(pickedURL.path)): \(error.localizedDescription)")
            return false
        }

        do {
            let previousURL = folderURL
            let data = try pickedURL.bookmarkData(options: [], includingResourceValuesForKeys: nil, relativeTo: nil)
            let name = Self.volumeName(at: pickedURL)
            let fsInfo = Self.filesystemInfo(at: pickedURL)
            UserDefaults.standard.set(data, forKey: Self.bookmarkKey)
            UserDefaults.standard.set(name, forKey: Self.nameKey)
            folderURL = pickedURL
            configuredName = name
            isConnected = true
            filesystemType = fsInfo.name
            supportsSparseFiles = fsInfo.supportsSparse
            if let previousURL, ExternalDriveRegistry.canonicalPath(previousURL) != ExternalDriveRegistry.canonicalPath(pickedURL) {
                ExternalDriveRegistry.shared.releaseScopeIfUnused(for: previousURL, keepURL: pickedURL)
            }
            if mode == .internalOnly {
                mode = .externalStaging
            }
            cleanupStaleRestoreDirs()
            Machines.shared.refreshExternalMachines(clearEjectedOnConfiguredDrive: true)
            HengeLog.log("storage", "selected external folder \(name) (fs=\(fsInfo.name ?? "?"), sparse=\(fsInfo.supportsSparse), free=\(ByteText.string(UInt64(max(freeBytes, 0)))))")
            return true
        } catch {
            ExternalDriveRegistry.shared.releaseScopeIfUnused(for: pickedURL, keepURL: folderURL)
            lastError = "無法儲存該資料夾的存取權限（\(error.localizedDescription)）。"
            HengeLog.log("storage", "bookmark creation failed: \(error.localizedDescription)")
            return false
        }
    }

    func refreshConnection() {
        if Installer.shared.busy, let url = folderURL {
            var isDir: ObjCBool = false
            let alive = FileManager.default.fileExists(atPath: url.path, isDirectory: &isDir)
                && isDir.boolValue
                && FileManager.default.isWritableFile(atPath: url.path)
            if alive {
                isConnected = true
                return
            }
        }

        guard let data = UserDefaults.standard.data(forKey: Self.bookmarkKey) else {
            folderURL = nil
            configuredName = nil
            isConnected = false
            filesystemType = nil
            supportsSparseFiles = true
            return
        }

        do {
            var stale = false
            let url = try URL(resolvingBookmarkData: data, options: [], relativeTo: nil, bookmarkDataIsStale: &stale)
            _ = ExternalDriveRegistry.shared.retainScope(for: url)

            var isDir: ObjCBool = false
            let exists = FileManager.default.fileExists(atPath: url.path, isDirectory: &isDir)
                && isDir.boolValue
                && FileManager.default.isWritableFile(atPath: url.path)

            if exists {
                folderURL = url
                isConnected = true
                let name = Self.volumeName(at: url)
                let fsInfo = Self.filesystemInfo(at: url)
                configuredName = name
                filesystemType = fsInfo.name
                supportsSparseFiles = fsInfo.supportsSparse
                UserDefaults.standard.set(name, forKey: Self.nameKey)
                if stale, let refreshed = try? url.bookmarkData(options: [], includingResourceValuesForKeys: nil, relativeTo: nil) {
                    UserDefaults.standard.set(refreshed, forKey: Self.bookmarkKey)
                }
            } else {
                ExternalDriveRegistry.shared.releaseScopeIfUnmounted(for: url)
                folderURL = nil
                isConnected = false
                configuredName = UserDefaults.standard.string(forKey: Self.nameKey)
            }
        } catch {
            folderURL = nil
            isConnected = false
            configuredName = UserDefaults.standard.string(forKey: Self.nameKey)
        }
    }

    func clearFolder() {
        _ = safeEjectDrive()
    }

    func inspectHengeDataOnDrive() -> ExternalDriveHengeSummary? {
        refreshConnection()
        guard let root = effectiveDriveURL else {
            lastError = "外接 SSD 尚未連接或無法讀取，請確認硬碟已插上後重試。"
            return nil
        }
        let fm = FileManager.default
        let driveName = effectiveDriveName
        let rootIsPortableMac = Machines.isValidPortableFolder(root)
        let machinesRoot: URL? = {
            if rootIsPortableMac { return nil }
            if root.lastPathComponent == "HengeMachines" { return root }
            return root.appendingPathComponent("HengeMachines", isDirectory: true)
        }()
        let stagingDir: URL? = {
            if rootIsPortableMac || root.lastPathComponent == "HengeMachines" { return nil }
            return root.appendingPathComponent("HengeInstall", isDirectory: true)
        }()

        var seenPaths = Set<String>()
        var machineCount = 0
        var totalBytes: Int64 = 0

        for mac in Machines.shared.all where mac.isExternal && mac.isAvailable {
            let dir = mac.directory
            if let rootFolder = ExternalDriveRegistry.shared.rootFolder(for: mac.id),
               ExternalDriveRegistry.isSameVolumeOrPath(rootFolder, root) {
                let canon = ExternalDriveRegistry.canonicalPath(dir)
                if seenPaths.insert(canon).inserted {
                    machineCount += 1
                    totalBytes += Machines.knownMachineBytes(in: dir)
                }
            }
        }

        let canonRoot = ExternalDriveRegistry.canonicalPath(root)
        if !seenPaths.contains(canonRoot) &&
            (rootIsPortableMac || fm.fileExists(atPath: root.appendingPathComponent(Machines.installingMarker).path)) {
            let bytes = Machines.knownMachineBytes(in: root)
            if bytes > 0 || rootIsPortableMac {
                seenPaths.insert(canonRoot)
                machineCount += 1
                totalBytes += bytes
            }
        }

        if let machinesRoot,
           let children = try? fm.contentsOfDirectory(at: machinesRoot, includingPropertiesForKeys: nil) {
            for child in children {
                let canon = ExternalDriveRegistry.canonicalPath(child)
                guard !seenPaths.contains(canon) else { continue }
                let hasUnfinished = fm.fileExists(atPath: child.appendingPathComponent(Machines.installingMarker).path)
                let bytes = Machines.knownMachineBytes(in: child)
                if bytes > 0 || Machines.isValidPortableFolder(child) || hasUnfinished {
                    seenPaths.insert(canon)
                    machineCount += 1
                    totalBytes += bytes
                }
            }
        }

        var hasInstallFiles = false
        if let stagingDir, fm.fileExists(atPath: stagingDir.path) {
            hasInstallFiles = true
            totalBytes += Self.directoryBytes(stagingDir)
        }

        return ExternalDriveHengeSummary(
            driveName: driveName,
            machineCount: machineCount,
            hasInstallFiles: hasInstallFiles,
            totalBytes: totalBytes
        )
    }

    @discardableResult
    func safeEjectDrive() -> Bool {
        guard !Machines.isVMRunning && !Machines.shared.isBusy && !isClearing else {
            lastError = "請先將執行中的 macOS 關機並等待目前作業完成，再執行安全退出。"
            return false
        }
        let driveName = effectiveDriveName
        let currentURL = folderURL
        let targetURL = currentURL ?? effectiveDriveURL
        _ = Machines.shared.ejectAllExternalMacs(on: targetURL, markAsExplicitlyEjected: false, keepURL: nil)
        if let targetURL {
            ExternalDriveRegistry.shared.forceReleaseAllScopes(matching: targetURL)
        }
        if currentURL == nil {
            ExternalDriveRegistry.shared.forceReleaseAllScopes()
        }
        UserDefaults.standard.removeObject(forKey: Self.bookmarkKey)
        UserDefaults.standard.removeObject(forKey: Self.nameKey)
        folderURL = nil
        configuredName = nil
        isConnected = false
        filesystemType = nil
        supportsSparseFiles = true
        lastError = nil
        mode = .internalOnly
        statusMessage = "已安全退出「\(driveName)」，SSD 內所有資料皆已完整保留。現在可以安心拔除 USB-C 硬碟。"
        HengeLog.log("storage", "safely ejected external drive \(driveName)")
        return true
    }

    func clearAllHengeDataOnDrive(onComplete: @escaping (Bool) -> Void = { _ in }) {
        guard !isClearing else { onComplete(false); return }
        guard !Machines.isVMRunning && !Machines.shared.isBusy else {
            lastError = "請先將執行中的 macOS 關機並等待目前作業完成，再清除外接 SSD 上的 Henge 資料。"
            onComplete(false)
            return
        }
        refreshConnection()
        guard let root = effectiveDriveURL else {
            lastError = "外接 SSD 尚未連接或無法寫入，請重新插上後再試。"
            onComplete(false)
            return
        }

        let fm = FileManager.default
        let driveName = effectiveDriveName
        let rootIsPortableMac = Machines.isValidPortableFolder(root)
        let machinesRoot: URL? = {
            if rootIsPortableMac { return nil }
            if root.lastPathComponent == "HengeMachines" { return root }
            return root.appendingPathComponent("HengeMachines", isDirectory: true)
        }()
        let stagingDir: URL? = {
            if rootIsPortableMac || root.lastPathComponent == "HengeMachines" { return nil }
            return root.appendingPathComponent("HengeInstall", isDirectory: true)
        }()

        var seen = Set<String>()
        var targets: [(dir: URL, allowRemoveDir: Bool)] = []
        let canonRoot = ExternalDriveRegistry.canonicalPath(root)
        for mac in Machines.shared.all where mac.isExternal && mac.isAvailable {
            if let rootFolder = ExternalDriveRegistry.shared.rootFolder(for: mac.id),
               ExternalDriveRegistry.isSameVolumeOrPath(rootFolder, root) {
                let dir = mac.directory
                let canon = ExternalDriveRegistry.canonicalPath(dir)
                if seen.insert(canon).inserted {
                    let allowRemove = mac.externalRelativePath != "." && canon != canonRoot
                    targets.append((dir: dir, allowRemoveDir: allowRemove))
                }
            }
        }

        if !seen.contains(canonRoot) &&
            (rootIsPortableMac || fm.fileExists(atPath: root.appendingPathComponent(Machines.installingMarker).path)) {
            seen.insert(canonRoot)
            targets.append((dir: root, allowRemoveDir: false))
        }

        isClearing = true
        lastError = nil
        statusMessage = nil

        Task.detached(priority: .userInitiated) {
            let fm = FileManager.default
            var freedBytes: Int64 = 0
            var errs: [String] = []
            var handledPaths = Set<String>()

            for target in targets {
                let canon = ExternalDriveRegistry.canonicalPath(target.dir)
                handledPaths.insert(canon)
                do {
                    freedBytes += try Machines.safelyDeleteMachineFiles(in: target.dir, allowRemovingDirectory: target.allowRemoveDir)
                } catch {
                    errs.append("\(target.dir.lastPathComponent)：\(error.localizedDescription)")
                }
            }

            if let machinesRoot,
               let children = try? fm.contentsOfDirectory(at: machinesRoot, includingPropertiesForKeys: nil) {
                for child in children {
                    let canon = ExternalDriveRegistry.canonicalPath(child)
                    guard !handledPaths.contains(canon) else { continue }
                    let hasKnownHengeData = Machines.knownMachineEntries.contains {
                        fm.fileExists(atPath: child.appendingPathComponent($0).path)
                    }
                    guard hasKnownHengeData else { continue }
                    handledPaths.insert(canon)
                    do {
                        freedBytes += try Machines.safelyDeleteMachineFiles(in: child, allowRemovingDirectory: true)
                    } catch {
                        errs.append("\(child.lastPathComponent)：\(error.localizedDescription)")
                    }
                }
                let isVol = (try? machinesRoot.resourceValues(forKeys: [.isVolumeKey]))?.isVolume ?? false
                if !isVol,
                   let rem = try? fm.contentsOfDirectory(atPath: machinesRoot.path),
                   rem.filter({ $0 != ".DS_Store" }).isEmpty {
                    try? fm.removeItem(at: machinesRoot)
                }
            }

            var removedStaging = false
            if let stagingDir, fm.fileExists(atPath: stagingDir.path) {
                let bytes = Self.directoryBytes(stagingDir)
                do {
                    try fm.removeItem(at: stagingDir)
                    freedBytes += bytes
                    removedStaging = true
                } catch {
                    errs.append("HengeInstall：\(error.localizedDescription)")
                }
            }

            let finalFreed = freedBytes
            let finalErrors = errs
            let finalRemovedStaging = removedStaging
            let nothingHandled = handledPaths.isEmpty && !finalRemovedStaging

            await MainActor.run {
                self.isClearing = false
                _ = Machines.shared.ejectAllExternalMacs(on: root, markAsExplicitlyEjected: false, keepURL: self.folderURL)
                Machines.shared.clearAllEjectedFlags()
                self.refreshConnection()
                if !finalErrors.isEmpty {
                    self.lastError = "清除過程發生部分錯誤：\(finalErrors.joined(separator: "；"))"
                    HengeLog.log("storage", "clear external drive partial error: \(finalErrors.joined(separator: "; "))")
                    onComplete(false)
                } else if finalFreed == 0 && nothingHandled {
                    self.statusMessage = "「\(driveName)」上目前沒有可清除的 Henge 系統或安裝檔（您的其他個人檔案未受影響）。"
                    HengeLog.log("storage", "cleared external drive \(driveName): nothing to remove")
                    onComplete(true)
                } else {
                    self.statusMessage = "已清除「\(driveName)」上的 Henge 資料，共釋放 \(ByteText.string(UInt64(max(finalFreed, 0))))。SSD 內其他個人檔案均已完整保留。"
                    HengeLog.log("storage", "cleared external drive \(driveName): freed \(finalFreed) bytes")
                    onComplete(true)
                }
            }
        }
    }

    func preexistingImage(for r: MacOSRelease) -> URL? {
        guard let root = folderURL else { return nil }
        let candidates = [
            root.appendingPathComponent(r.url.lastPathComponent),
            root.appendingPathComponent("\(r.id).ipsw")
        ]
        for candidate in candidates {
            let size = (try? candidate.resourceValues(forKeys: [.fileSizeKey]))?.fileSize ?? 0
            if Int64(size) > r.bytes / 2 {
                return candidate
            }
        }
        return nil
    }

    func cleanupStaleRestoreDirs(force: Bool = false) {
        guard force || !Installer.shared.busy, let root = stagingRoot else { return }
        let fm = FileManager.default
        guard let items = try? fm.contentsOfDirectory(at: root, includingPropertiesForKeys: nil) else { return }
        for item in items where item.lastPathComponent.hasPrefix("restore-") {
            try? fm.removeItem(at: item)
        }
    }

    func cleanupEmptyStagingIfUnused(force: Bool = false) {
        guard force || !Installer.shared.busy, let root = stagingRoot else { return }
        cleanupStaleRestoreDirs(force: force)
        let fm = FileManager.default
        if let imagesDir = externalRestoreImagesDir,
           let items = try? fm.contentsOfDirectory(atPath: imagesDir.path),
           items.isEmpty {
            try? fm.removeItem(at: imagesDir)
        }
        if let items = try? fm.contentsOfDirectory(atPath: root.path),
           items.isEmpty {
            try? fm.removeItem(at: root)
        }
    }
}
