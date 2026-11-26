import Foundation

/// Validates only the archive directory and small manifest; unchanged images reuse the result.
final class RestoreImageValidation: @unchecked Sendable {
    static let shared = RestoreImageValidation { url, build in
        if let build {
            return build.withCString { hv_ipsw_validate(url.path, $0) == 0 }
        }
        return hv_ipsw_validate(url.path, nil) == 0
    }

    private struct Fingerprint: Hashable {
        let path: String
        let bytes: Int64
        let modified: Date
        let fileNumber: UInt64
        let build: String?
    }

    private let lock = NSLock()
    private let validateArchive: (URL, String?) -> Bool
    private var cache: [Fingerprint: Bool] = [:]

    init(validateArchive: @escaping (URL, String?) -> Bool) {
        self.validateArchive = validateArchive
    }

    static func isManagedFile(_ url: URL, in directory: URL) -> Bool {
        let root = directory.standardizedFileURL
        return url.standardizedFileURL.deletingLastPathComponent() == root &&
            MachineStorageSafety.isRegularFile(url, within: root)
    }

    /// Older versions wrote <build>.part. Resume that file in place; new downloads
    /// use the .ipsw.part name also understood by the staging cleanup.
    static func partialImage(in directory: URL, build: String) -> URL {
        let previous = directory.appendingPathComponent("\(build).part")
        if isManagedFile(previous, in: directory) { return previous }
        return directory.appendingPathComponent("\(build).ipsw.part")
    }

    enum RestoreShutdown { case clean, diskError, unconfirmed }

    @MainActor
    static func finishRestoreShutdown(vmState: () -> Int32, requestStop: () -> Void,
                                      outcome: () -> RestoreShutdown, maxWaits: Int = 300,
                                      wait: () async throws -> Void = { try await Task.sleep(nanoseconds: 200_000_000) })
        async throws -> RestoreShutdown {
        let state = vmState()
        if state == 1 || state == 4 { requestStop() }
        for _ in 0..<maxWaits {
            if vmState() == 2 { return outcome() }
            try await wait()
        }
        return vmState() == 2 ? outcome() : .unconfirmed
    }

    static func canCleanRestoreWork(step: Int32, vmState: Int32, canStart: Bool) -> Bool {
        (vmState == 0 || vmState == 2) && (canStart || step == 100 || step == 101)
    }

    func validatedSize(of url: URL, expectedBuild: String? = nil) -> Int64? {
        lock.lock()
        defer { lock.unlock() }
        guard let key = fingerprint(of: url, build: expectedBuild) else { return nil }
        if let valid = cache[key] { return valid ? key.bytes : nil }
        let valid = hasZIPHeader(url) && validateArchive(url, expectedBuild)
        guard fingerprint(of: url, build: expectedBuild) == key else { return nil }
        if cache.count >= 128 { cache.removeAll(keepingCapacity: true) }
        cache[key] = valid
        return valid ? key.bytes : nil
    }

    private func fingerprint(of url: URL, build: String?) -> Fingerprint? {
        guard url.isFileURL,
              let attrs = try? FileManager.default.attributesOfItem(atPath: url.path),
              attrs[.type] as? FileAttributeType == .typeRegular,
              let bytes = (attrs[.size] as? NSNumber)?.int64Value, bytes >= 32,
              let modified = attrs[.modificationDate] as? Date else { return nil }
        return Fingerprint(
            path: url.standardizedFileURL.path,
            bytes: bytes,
            modified: modified,
            fileNumber: (attrs[.systemFileNumber] as? NSNumber)?.uint64Value ?? 0,
            build: build
        )
    }

    private func hasZIPHeader(_ url: URL) -> Bool {
        guard let file = try? FileHandle(forReadingFrom: url) else { return false }
        defer { try? file.close() }
        return (try? file.read(upToCount: 4)) == Data([0x50, 0x4b, 0x03, 0x04])
    }
}
