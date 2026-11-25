import Darwin
import Foundation

struct ExternalDriveTarget: Equatable, Sendable {
    let rootURL: URL
    let displayName: String
    let token: UUID
    private let access: DriveDirectoryAccess

    var canonicalPath: String { access.canonicalPath }
    var isAvailable: Bool { access.isAvailable }

    static func capture(rootURL: URL, displayName: String) -> ExternalDriveTarget? {
        guard let access = DriveDirectoryAccess(rootURL) else { return nil }
        return ExternalDriveTarget(rootURL: rootURL, displayName: displayName, token: UUID(), access: access)
    }

    static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.token == rhs.token
    }

    fileprivate func openDirectory(_ directory: URL, within approvedRoot: URL) throws -> Int32 {
        _ = try MachineStorageSafety.relativeComponents(directory, within: approvedRoot)
        let components = try MachineStorageSafety.relativeComponents(directory, within: rootURL)
        return try MachineStorageSafety.openDescendant(components, from: access.duplicateDescriptor())
    }
}

private final class DriveDirectoryAccess: @unchecked Sendable {
    let canonicalPath: String
    private let descriptor: Int32
    private let device: dev_t
    private let inode: ino_t

    init?(_ url: URL) {
        var linkInfo = stat()
        guard lstat(url.path, &linkInfo) == 0,
              linkInfo.st_mode & S_IFMT == S_IFDIR else { return nil }
        canonicalPath = url.resolvingSymlinksInPath().standardizedFileURL.path
        let fd = open(canonicalPath, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard fd >= 0 else { return nil }
        var info = stat()
        guard fstat(fd, &info) == 0, info.st_dev == linkInfo.st_dev, info.st_ino == linkInfo.st_ino else {
            close(fd)
            return nil
        }
        descriptor = fd
        device = info.st_dev
        inode = info.st_ino
    }

    deinit { close(descriptor) }

    func duplicateDescriptor() throws -> Int32 {
        guard isAvailable else {
            throw MachineStorageSafety.failure("外接 SSD 已變更或中斷連線，未執行清除。")
        }
        let copy = dup(descriptor)
        guard copy >= 0 else { throw MachineStorageSafety.posixFailure() }
        return copy
    }

    var isAvailable: Bool {
        var held = stat()
        var current = stat()
        var heldVolume = statfs()
        var currentVolume = statfs()
        guard fstat(descriptor, &held) == 0,
              lstat(canonicalPath, &current) == 0,
              current.st_mode & S_IFMT == S_IFDIR,
              held.st_dev == device, held.st_ino == inode,
              current.st_dev == device, current.st_ino == inode,
              fstatfs(descriptor, &heldVolume) == 0,
              statfs(canonicalPath, &currentVolume) == 0 else { return false }
        return heldVolume.f_fsid.val.0 == currentVolume.f_fsid.val.0
            && heldVolume.f_fsid.val.1 == currentVolume.f_fsid.val.1
    }
}

enum MachineStorageSafety {
    static let requiredFiles = ["AVPBooter.vmapple2.bin", "auxiliary.bin", "machine.json"]
    static let knownMachineEntries = [
        "disk.img", "disk.img.hvsparse", "AVPBooter.vmapple2.bin", "auxiliary.bin",
        "machine.json", "installed", ".installing", "preview.jpg",
        "resume.hsnap", "resume.hsnap.part", "restore"
    ]

    private struct Identity: Decodable { let ecid: UInt64 }

    struct DirectoryIdentity: Equatable {
        fileprivate let device: dev_t
        fileprivate let inode: ino_t

        fileprivate init(_ info: stat) {
            device = info.st_dev
            inode = info.st_ino
        }
    }

    static func isSafeDirectory(_ directory: URL, within approvedRoot: URL) -> Bool {
        guard let fd = try? openDirectory(directory, within: approvedRoot) else { return false }
        close(fd)
        return true
    }

    static func isRegularFile(_ file: URL, within approvedRoot: URL) -> Bool {
        guard let fd = try? openDirectory(file.deletingLastPathComponent(), within: approvedRoot) else { return false }
        defer { close(fd) }
        return isRegularFile(file.lastPathComponent, in: fd)
    }

    static func isOwnedMachineDirectory(_ directory: URL, within approvedRoot: URL, matchingECID: UInt64? = nil) -> Bool {
        guard let fd = try? openDirectory(directory, within: approvedRoot) else { return false }
        defer { close(fd) }
        if let matchingECID, identityECID(fd) != matchingECID { return false }
        return ownsMachine(fd, directoryName: directory.lastPathComponent)
    }

    static func isPortableMachineDirectory(_ directory: URL) -> Bool {
        guard let fd = try? openDirectory(directory, within: directory) else { return false }
        defer { close(fd) }
        guard validIdentity(fd),
              requiredFiles.allSatisfy({ isRegularFile($0, in: fd) }),
              isRegularFile("disk.img", in: fd) else { return false }
        return !isRegularFile(".installing", in: fd) || isRegularFile("installed", in: fd)
    }

    static func containsOnlyMachineEntries(_ directory: URL, within approvedRoot: URL) -> Bool {
        guard let fd = try? openDirectory(directory, within: approvedRoot) else { return false }
        defer { close(fd) }
        return containsOnlyMachineEntries(fd)
    }

    private static func containsOnlyMachineEntries(_ fd: Int32) -> Bool {
        guard let entries = try? names(in: fd) else { return false }
        let allowed = Set(knownMachineEntries + [".DS_Store"])
        return entries.allSatisfy {
            guard allowed.contains($0) else { return false }
            if $0 == "restore" {
                let child = openat(fd, $0, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
                guard child >= 0 else { return false }
                defer { close(child) }
                return (try? validateTree(child)) != nil
            }
            return isRegularFile($0, in: fd)
        }
    }

    static func deleteMachineFiles(
        in directory: URL,
        approvedRoot: URL,
        allowRemovingDirectory: Bool,
        validating target: ExternalDriveTarget? = nil,
        matchingIdentity expected: DirectoryIdentity? = nil
    ) throws -> Int64 {
        let fd = try openDirectory(directory, within: approvedRoot, validating: target)
        defer { close(fd) }
        var opened = stat()
        guard fstat(fd, &opened) == 0 else { throw posixFailure() }
        let identity = DirectoryIdentity(opened)
        if let expected {
            guard identity == expected, containsOnlyMachineEntries(fd) else {
                throw failure("舊備份資料夾已變更，未執行清除。")
            }
        }
        guard target?.isAvailable != false else {
            throw failure("外接 SSD 已變更或中斷連線，未執行清除。")
        }
        guard ownsMachine(fd, directoryName: directory.lastPathComponent) else {
            throw failure("無法確認這個資料夾屬於 iPac，未刪除任何檔案。")
        }
        for name in knownMachineEntries {
            var info = stat()
            if fstatat(fd, name, &info, AT_SYMLINK_NOFOLLOW) != 0 {
                if errno == ENOENT { continue }
                throw posixFailure()
            }
            let kind = info.st_mode & S_IFMT
            guard kind == S_IFREG || (name == "restore" && kind == S_IFDIR) else {
                throw failure("「\(name)」不是預期的 iPac 檔案，未刪除任何檔案。")
            }
            if kind == S_IFDIR {
                let child = openat(fd, name, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
                guard child >= 0 else { throw posixFailure() }
                defer { close(child) }
                try validateTree(child)
            }
        }
        var bytes: Int64 = 0
        for name in knownMachineEntries {
            var info = stat()
            if fstatat(fd, name, &info, AT_SYMLINK_NOFOLLOW) != 0 {
                if errno == ENOENT { continue }
                throw posixFailure()
            }
            let kind = info.st_mode & S_IFMT
            guard kind == S_IFREG || (name == "restore" && kind == S_IFDIR) else {
                throw failure("「\(name)」不是預期的 iPac 檔案，已停止清除以保護資料。")
            }
            bytes += try removeEntry(name, from: fd, info: info)
        }

        if allowRemovingDirectory {
            let remaining = try names(in: fd)
            if remaining.allSatisfy({ $0 == ".DS_Store" }) {
                if isRegularFile(".DS_Store", in: fd) {
                    _ = unlinkat(fd, ".DS_Store", 0)
                }
                removeEmptyDirectory(directory, within: approvedRoot, validating: target, matchingIdentity: identity)
            }
        }
        return bytes
    }

    static func removeManagedDirectory(
        _ directory: URL,
        approvedRoot: URL,
        validating target: ExternalDriveTarget? = nil
    ) throws -> Int64 {
        let fd = try openDirectory(directory, within: approvedRoot, validating: target)
        defer { close(fd) }
        guard target?.isAvailable != false else {
            throw failure("外接 SSD 已變更或中斷連線，未執行清除。")
        }
        try validateTree(fd)
        var bytes: Int64 = 0
        for name in try names(in: fd) {
            var info = stat()
            guard fstatat(fd, name, &info, AT_SYMLINK_NOFOLLOW) == 0 else { throw posixFailure() }
            bytes += try removeEntry(name, from: fd, info: info)
        }
        removeEmptyDirectory(directory, within: approvedRoot, validating: target)
        return bytes
    }

    static func removeRegularFile(
        _ file: URL,
        approvedRoot: URL,
        validating target: ExternalDriveTarget? = nil
    ) throws -> Int64 {
        let fd = try openDirectory(file.deletingLastPathComponent(), within: approvedRoot, validating: target)
        defer { close(fd) }
        var info = stat()
        guard fstatat(fd, file.lastPathComponent, &info, AT_SYMLINK_NOFOLLOW) == 0 else { throw posixFailure() }
        guard info.st_mode & S_IFMT == S_IFREG else {
            throw failure("清除目標不是一般檔案，未執行刪除。")
        }
        return try removeEntry(file.lastPathComponent, from: fd, info: info)
    }

    static func openRegularFile(
        _ file: URL,
        approvedRoot: URL,
        flags: Int32 = O_RDONLY,
        mode: mode_t = 0o600,
        validating target: ExternalDriveTarget? = nil
    ) throws -> Int32 {
        let parent = try openDirectory(file.deletingLastPathComponent(), within: approvedRoot, validating: target)
        defer { close(parent) }
        let fd = openat(parent, file.lastPathComponent, (flags & ~O_TRUNC) | O_NONBLOCK | O_NOFOLLOW | O_CLOEXEC, mode)
        guard fd >= 0 else { throw posixFailure() }
        var info = stat()
        let writes = flags & O_ACCMODE != O_RDONLY
        guard fstat(fd, &info) == 0, info.st_mode & S_IFMT == S_IFREG, !writes || info.st_nlink == 1 else {
            close(fd)
            throw failure("檔案不是一般檔案或含有不安全的連結，未執行作業。")
        }
        if flags & O_TRUNC != 0, ftruncate(fd, 0) != 0 {
            close(fd)
            throw posixFailure()
        }
        if flags & O_NONBLOCK == 0 {
            let status = fcntl(fd, F_GETFL)
            guard status >= 0, fcntl(fd, F_SETFL, status & ~O_NONBLOCK) == 0 else {
                close(fd)
                throw posixFailure()
            }
        }
        return fd
    }

    static func promoteRegularFile(
        from source: URL,
        to destination: URL,
        approvedRoot: URL,
        validating target: ExternalDriveTarget? = nil
    ) throws {
        guard source.deletingLastPathComponent().standardizedFileURL == destination.deletingLastPathComponent().standardizedFileURL else {
            throw failure("下載檔案只能在同一個已授權資料夾內完成搬移。")
        }
        let parent = try openDirectory(source.deletingLastPathComponent(), within: approvedRoot, validating: target)
        defer { close(parent) }
        guard isRegularFile(source.lastPathComponent, in: parent) else {
            throw failure("下載檔案不是一般檔案，未執行搬移。")
        }
        guard renameatx_np(parent, source.lastPathComponent, parent, destination.lastPathComponent, UInt32(RENAME_EXCL)) == 0 else {
            throw posixFailure()
        }
    }

    static func exportFolderName(_ name: String, fallbackID: UUID) -> String {
        let candidate = name.replacingOccurrences(of: "/", with: "-")
        return candidate.isEmpty || candidate == "." || candidate == ".." ? fallbackID.uuidString : candidate
    }

    static func promoteMachineDirectory(
        from source: URL,
        to destination: URL,
        approvedRoot: URL,
        validating target: ExternalDriveTarget? = nil
    ) throws {
        guard source.deletingLastPathComponent().standardizedFileURL == destination.deletingLastPathComponent().standardizedFileURL else {
            throw failure("系統資料夾只能在同一個已授權目錄內完成搬移。")
        }
        let parent = try openDirectory(source.deletingLastPathComponent(), within: approvedRoot, validating: target)
        defer { close(parent) }
        let child = openat(parent, source.lastPathComponent, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard child >= 0 else { throw posixFailure() }
        defer { close(child) }
        guard ownsMachine(child, directoryName: source.lastPathComponent) else {
            throw failure("無法確認來源資料夾屬於 iPac，未執行搬移。")
        }
        guard renameatx_np(parent, source.lastPathComponent, parent, destination.lastPathComponent, UInt32(RENAME_EXCL)) == 0 else {
            throw posixFailure()
        }
    }

    /// An atomic swap retains the old export at `source` until the caller can clean that exact inode.
    @discardableResult
    static func commitMachineExport(
        from source: URL,
        to destination: URL,
        approvedRoot: URL,
        matchingECID ecid: UInt64,
        validating target: ExternalDriveTarget? = nil,
        renameOperation: (Int32, String, Int32, String, UInt32) -> Int32 = {
            renameatx_np($0, $1, $2, $3, $4)
        }
    ) throws -> DirectoryIdentity? {
        guard source.standardizedFileURL != destination.standardizedFileURL,
              source.deletingLastPathComponent().standardizedFileURL == destination.deletingLastPathComponent().standardizedFileURL else {
            throw failure("匯出來源與目的必須是同一個已授權目錄內的不同資料夾。")
        }
        let parent = try openDirectory(source.deletingLastPathComponent(), within: approvedRoot, validating: target)
        defer { close(parent) }
        let sourceName = source.lastPathComponent
        let destinationName = destination.lastPathComponent
        let child = openat(parent, sourceName, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard child >= 0 else { throw posixFailure() }
        defer { close(child) }
        var sourceInfo = stat()
        guard fstat(child, &sourceInfo) == 0 else { throw posixFailure() }
        let sourceIdentity = DirectoryIdentity(sourceInfo)
        guard identityECID(child) == ecid,
              requiredFiles.allSatisfy({ isRegularFile($0, in: child) }),
              isRegularFile("disk.img", in: child) || isRegularFile("disk.img.hvsparse", in: child),
              isRegularFile("installed", in: child),
              !(try names(in: child)).contains(".installing"),
              containsOnlyMachineEntries(child) else {
            throw failure("新匯出尚未完整或含有未知檔案，既有備份已保留。")
        }

        var destinationInfo = stat()
        var backupIdentity: DirectoryIdentity?
        var flags = UInt32(RENAME_EXCL)
        if fstatat(parent, destinationName, &destinationInfo, AT_SYMLINK_NOFOLLOW) == 0 {
            guard destinationInfo.st_mode & S_IFMT == S_IFDIR else {
                throw failure("匯出目的不是一般資料夾，未覆寫既有資料。")
            }
            let previous = openat(parent, destinationName, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
            guard previous >= 0 else { throw posixFailure() }
            defer { close(previous) }
            var previousInfo = stat()
            guard fstat(previous, &previousInfo) == 0 else { throw posixFailure() }
            let previousIdentity = DirectoryIdentity(previousInfo)
            guard previousIdentity == DirectoryIdentity(destinationInfo),
                  previousIdentity != sourceIdentity,
                  identityECID(previous) == ecid,
                  ownsMachine(previous, directoryName: destinationName),
                  containsOnlyMachineEntries(previous) else {
                throw failure("匯出目的已變更、含有未知檔案或其他系統，未覆寫既有資料。")
            }
            backupIdentity = previousIdentity
            flags = UInt32(RENAME_SWAP)
        } else if errno != ENOENT {
            throw posixFailure()
        }

        guard matchesDirectory(sourceName, in: parent, identity: sourceIdentity),
              backupIdentity.map({ matchesDirectory(destinationName, in: parent, identity: $0) }) ?? true,
              target?.isAvailable != false else {
            throw failure("匯出資料夾或外接 SSD 已變更，既有備份已保留。")
        }
        guard renameOperation(parent, sourceName, parent, destinationName, flags) == 0 else {
            let error = posixFailure()
            throw failure("無法安全完成匯出搬移（\(error.localizedDescription)）。既有備份未刪除；新匯出保留在「\(sourceName)」，可稍後重試或取出。")
        }
        guard matchesDirectory(destinationName, in: parent, identity: sourceIdentity),
              backupIdentity.map({ matchesDirectory(sourceName, in: parent, identity: $0) }) ?? true else {
            throw failure("匯出搬移後資料夾已變更，已保留所有資料，未清除備份。")
        }
        return backupIdentity
    }

    static func clearInstallStaging(
        _ directory: URL,
        approvedRoot: URL,
        validating target: ExternalDriveTarget? = nil
    ) throws -> Int64 {
        let fd = try openDirectory(directory, within: approvedRoot, validating: target)
        defer { close(fd) }
        guard target?.isAvailable != false else {
            throw failure("外接 SSD 已變更或中斷連線，未執行清除。")
        }
        let entries = try names(in: fd)
        for name in entries where name.hasPrefix("restore-") && UUID(uuidString: String(name.dropFirst(8))) != nil {
            var info = stat()
            guard fstatat(fd, name, &info, AT_SYMLINK_NOFOLLOW) == 0 else { throw posixFailure() }
            guard info.st_mode & S_IFMT == S_IFDIR else { continue }
            let child = openat(fd, name, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
            guard child >= 0 else { throw posixFailure() }
            defer { close(child) }
            try validateTree(child)
        }
        var bytes: Int64 = 0
        for name in entries {
            var info = stat()
            guard fstatat(fd, name, &info, AT_SYMLINK_NOFOLLOW) == 0 else { throw posixFailure() }
            guard info.st_mode & S_IFMT == S_IFDIR else { continue }
            if name.hasPrefix("restore-"), UUID(uuidString: String(name.dropFirst(8))) != nil {
                bytes += try removeEntry(name, from: fd, info: info)
            } else if name == "Restore images" {
                let images = openat(fd, name, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
                guard images >= 0 else { throw posixFailure() }
                defer { close(images) }
                for file in try names(in: images) where file.hasSuffix(".ipsw") || file.hasSuffix(".ipsw.part") {
                    var imageInfo = stat()
                    guard fstatat(images, file, &imageInfo, AT_SYMLINK_NOFOLLOW) == 0 else { throw posixFailure() }
                    guard imageInfo.st_mode & S_IFMT == S_IFREG else { continue }
                    bytes += try removeEntry(file, from: images, info: imageInfo)
                }
                _ = unlinkat(fd, name, AT_REMOVEDIR)
            }
        }
        removeEmptyDirectory(directory, within: approvedRoot, validating: target)
        return bytes
    }

    static func validRelativePath(_ path: String) -> Bool {
        if path.isEmpty || path == "." { return true }
        guard !path.hasPrefix("/") else { return false }
        return path.split(separator: "/", omittingEmptySubsequences: false)
            .allSatisfy { !$0.isEmpty && $0 != "." && $0 != ".." }
    }

    fileprivate static func relativeComponents(_ directory: URL, within approvedRoot: URL) throws -> [String] {
        let rootPath = approvedRoot.standardizedFileURL.path
        let directoryPath = directory.standardizedFileURL.path
        guard directoryPath == rootPath || directoryPath.hasPrefix(rootPath + "/") else {
            throw failure("資料夾已超出已授權範圍，未執行檔案作業。")
        }
        let relative = directoryPath == rootPath ? "" : String(directoryPath.dropFirst(rootPath.count + 1))
        return relative.split(separator: "/").map(String.init)
    }

    private static func openDirectory(
        _ directory: URL,
        within approvedRoot: URL,
        validating target: ExternalDriveTarget? = nil
    ) throws -> Int32 {
        if let target { return try target.openDirectory(directory, within: approvedRoot) }
        let components = try relativeComponents(directory, within: approvedRoot)
        let rootPath = approvedRoot.standardizedFileURL.path
        var rootInfo = stat()
        guard lstat(rootPath, &rootInfo) == 0, rootInfo.st_mode & S_IFMT == S_IFDIR else {
            throw failure("資料夾無法存取，或包含不安全的符號連結。")
        }
        let rootCanonical = approvedRoot.resolvingSymlinksInPath().standardizedFileURL.path
        let current = open(rootCanonical, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard current >= 0 else { throw posixFailure() }
        return try openDescendant(components, from: current)
    }

    fileprivate static func openDescendant(_ components: [String], from descriptor: Int32) throws -> Int32 {
        var current = descriptor
        var rootInfo = stat()
        guard fstat(current, &rootInfo) == 0 else {
            close(current)
            throw posixFailure()
        }
        for component in components {
            let next = openat(current, component, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
            close(current)
            guard next >= 0 else {
                throw failure("資料夾無法存取，或包含不安全的符號連結。")
            }
            current = next
            var info = stat()
            guard fstat(current, &info) == 0, info.st_dev == rootInfo.st_dev else {
                close(current)
                throw failure("資料夾已移至另一個磁碟，未執行檔案作業。")
            }
        }
        return current
    }

    private static func ownsMachine(_ fd: Int32, directoryName: String) -> Bool {
        let identityValid = validIdentity(fd)
        let corePresent = requiredFiles.allSatisfy { isRegularFile($0, in: fd) }
        let hasDisk = isRegularFile("disk.img", in: fd) || isRegularFile("disk.img.hvsparse", in: fd)
        if identityValid && corePresent && hasDisk { return true }
        let idName = directoryName.hasSuffix(".moving") ? String(directoryName.dropLast(7)) : directoryName
        return isRegularFile(".installing", in: fd)
            && (identityValid || UUID(uuidString: idName) != nil)
    }

    private static func validIdentity(_ fd: Int32) -> Bool {
        identityECID(fd) != nil
    }

    private static func identityECID(_ fd: Int32) -> UInt64? {
        let file = openat(fd, "machine.json", O_RDONLY | O_NONBLOCK | O_NOFOLLOW | O_CLOEXEC)
        guard file >= 0 else { return nil }
        defer { close(file) }
        var info = stat()
        guard fstat(file, &info) == 0, info.st_mode & S_IFMT == S_IFREG,
              info.st_size > 0, info.st_size <= 65_536 else { return nil }
        var data = Data(count: Int(info.st_size))
        let count = data.withUnsafeMutableBytes { read(file, $0.baseAddress, $0.count) }
        guard count == data.count else { return nil }
        return (try? JSONDecoder().decode(Identity.self, from: data))?.ecid
    }

    private static func isRegularFile(_ name: String, in fd: Int32) -> Bool {
        var info = stat()
        return fstatat(fd, name, &info, AT_SYMLINK_NOFOLLOW) == 0 && info.st_mode & S_IFMT == S_IFREG
    }

    private static func matchesDirectory(_ name: String, in fd: Int32, identity: DirectoryIdentity) -> Bool {
        var info = stat()
        return fstatat(fd, name, &info, AT_SYMLINK_NOFOLLOW) == 0
            && info.st_mode & S_IFMT == S_IFDIR
            && DirectoryIdentity(info) == identity
    }

    private static func names(in fd: Int32) throws -> [String] {
        let copy = dup(fd)
        guard copy >= 0 else { throw posixFailure() }
        guard let stream = fdopendir(copy) else {
            close(copy)
            throw posixFailure()
        }
        defer { closedir(stream) }
        rewinddir(stream)
        var result: [String] = []
        while let entry = readdir(stream) {
            let name = withUnsafePointer(to: &entry.pointee.d_name) {
                String(cString: UnsafeRawPointer($0).assumingMemoryBound(to: CChar.self))
            }
            if name != "." && name != ".." { result.append(name) }
        }
        return result
    }

    private static func removeEntry(_ name: String, from fd: Int32, info: stat) throws -> Int64 {
        let kind = info.st_mode & S_IFMT
        guard kind == S_IFREG || kind == S_IFDIR else {
            throw failure("清除範圍包含符號連結或未知檔案，已停止作業。")
        }
        if kind == S_IFDIR {
            let child = openat(fd, name, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
            guard child >= 0 else { throw posixFailure() }
            defer { close(child) }
            var opened = stat()
            guard fstat(child, &opened) == 0, opened.st_dev == info.st_dev, opened.st_ino == info.st_ino else {
                throw failure("清除目標已變更，已停止作業。")
            }
            var bytes: Int64 = 0
            for item in try names(in: child) {
                var childInfo = stat()
                guard fstatat(child, item, &childInfo, AT_SYMLINK_NOFOLLOW) == 0 else { throw posixFailure() }
                bytes += try removeEntry(item, from: child, info: childInfo)
            }
            var current = stat()
            guard fstatat(fd, name, &current, AT_SYMLINK_NOFOLLOW) == 0,
                  current.st_dev == opened.st_dev, current.st_ino == opened.st_ino else {
                throw failure("清除目標已變更，已停止作業。")
            }
            guard unlinkat(fd, name, AT_REMOVEDIR) == 0 else { throw posixFailure() }
            return bytes
        }
        guard unlinkat(fd, name, 0) == 0 else { throw posixFailure() }
        return Int64(max(info.st_blocks, 0)) * 512
    }

    private static func validateTree(_ fd: Int32) throws {
        var rootInfo = stat()
        guard fstat(fd, &rootInfo) == 0 else { throw posixFailure() }
        for name in try names(in: fd) {
            var info = stat()
            guard fstatat(fd, name, &info, AT_SYMLINK_NOFOLLOW) == 0 else { throw posixFailure() }
            guard info.st_dev == rootInfo.st_dev else {
                throw failure("清除範圍包含其他磁碟，未刪除任何檔案。")
            }
            let kind = info.st_mode & S_IFMT
            guard kind == S_IFREG || kind == S_IFDIR else {
                throw failure("清除範圍包含符號連結或未知檔案，未刪除任何檔案。")
            }
            if kind == S_IFDIR {
                let child = openat(fd, name, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
                guard child >= 0 else { throw posixFailure() }
                defer { close(child) }
                try validateTree(child)
            }
        }
    }

    static func removeEmptyDirectory(
        _ directory: URL,
        within approvedRoot: URL,
        validating target: ExternalDriveTarget? = nil,
        matchingIdentity identity: DirectoryIdentity? = nil
    ) {
        guard directory.standardizedFileURL.path != approvedRoot.standardizedFileURL.path,
              let parent = try? openDirectory(directory.deletingLastPathComponent(), within: approvedRoot, validating: target) else { return }
        defer { close(parent) }
        if let identity, !matchesDirectory(directory.lastPathComponent, in: parent, identity: identity) { return }
        _ = unlinkat(parent, directory.lastPathComponent, AT_REMOVEDIR)
    }

    fileprivate static func failure(_ text: String) -> NSError {
        NSError(domain: "Henge", code: 1, userInfo: [NSLocalizedDescriptionKey: text])
    }

    fileprivate static func posixFailure() -> NSError {
        NSError(domain: NSPOSIXErrorDomain, code: Int(errno))
    }
}
