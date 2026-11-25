import Foundation
import Darwin

/// Downloads `url` into the file `part`, appending: a download that stops for any reason (no network, Henge
/// closed or killed) goes on from where the file ends the next time, with an HTTP range request (#58).
/// Apple's CDN answers ranges; a server that ignores one (200) starts the file again.
final class RangedDownload: NSObject, URLSessionDataDelegate, @unchecked Sendable {
    enum Failure: LocalizedError {
        case invalidContentRange
        case rejectedRange(have: Int64, total: Int64?)
        case unexpectedStatus(Int)
        case endedEarly(have: Int64, total: Int64)
        case alreadyStarted

        var shouldRestartPartialDownload: Bool {
            if case let .rejectedRange(have, total?) = self { return total > 0 && have > total }
            return false
        }

        var errorDescription: String? {
            switch self {
            case .invalidContentRange: return "下載伺服器回傳了無效或錯誤的檔案範圍。"
            case .rejectedRange: return "下載伺服器拒絕續傳，無法確認暫存檔是否完整。"
            case let .unexpectedStatus(status): return "下載伺服器回傳 HTTP \(status)。"
            case let .endedEarly(have, total): return "下載提前結束（已取得 \(have)／\(total) 位元組）。"
            case .alreadyStarted: return "這次下載作業已經啟動。"
            }
        }
    }

    struct ContentRange: Equatable {
        let start: Int64?
        let end: Int64?
        let total: Int64?

        static func parse(_ header: String?) -> ContentRange? {
            guard let header else { return nil }
            let value = header.trimmingCharacters(in: .whitespacesAndNewlines)
            let regex = try! NSRegularExpression(pattern: #"^bytes (?:(\d+)-(\d+)|\*)/(\d+|\*)$"#,
                                                options: .caseInsensitive)
            guard let match = regex.firstMatch(in: value, range: NSRange(value.startIndex..., in: value)) else { return nil }
            func number(_ index: Int) -> Int64? {
                guard let range = Range(match.range(at: index), in: value) else { return nil }
                return Int64(value[range])
            }
            let totalToken = Range(match.range(at: 3), in: value).map { String(value[$0]) }
            let total = number(3)
            if totalToken != "*" && total == nil { return nil }
            let start = number(1), end = number(2)
            if match.range(at: 1).location != NSNotFound {
                guard let start, let end, end >= start, total.map({ end < $0 }) ?? true else { return nil }
            } else if total == nil {
                return nil
            }
            return ContentRange(start: start, end: end, total: total)
        }
    }

    let url: URL
    let part: URL
    /// Bytes in `part` and the whole file's size once known, on the delegate's queue.
    private let progress: (Int64, Int64) -> Void
    private var handle: FileHandle?
    private var have: Int64 = 0
    private var total: Int64 = 0
    private var failure: Error?
    private var continuation: CheckedContinuation<Void, Error>?
    private var task: URLSessionDataTask?
    private var session: URLSession?
    private let stateLock = NSLock()
    private var cancellationRequested = false
    private var started = false
    private var responseEnd: Int64?
    private let configuration: URLSessionConfiguration?
    private let approvedRoot: URL?
    private let driveTarget: ExternalDriveTarget?

    init(url: URL, part: URL, approvedRoot: URL? = nil, validating driveTarget: ExternalDriveTarget? = nil,
         configuration: URLSessionConfiguration? = nil,
         progress: @escaping (Int64, Int64) -> Void) {
        self.url = url
        self.part = part
        self.approvedRoot = approvedRoot
        self.driveTarget = driveTarget
        self.configuration = configuration
        self.progress = progress
    }

    /// Bytes already in a part file, or 0.
    static func size(of part: URL) -> Int64 {
        ((try? FileManager.default.attributesOfItem(atPath: part.path)[.size]) as? NSNumber)?.int64Value ?? 0
    }

    /// One attempt: fetches the rest of the file. Returns once `part` holds all of it; throws when this attempt
    /// stops early (what it wrote stays, for the next one).
    func run() async throws {
        try Task.checkCancellation()
        let canStart = stateLock.withLock {
            if started { return false }
            started = true
            return true
        }
        guard canStart else { throw Failure.alreadyStarted }
        if stateLock.withLock({ cancellationRequested }) { throw CancellationError() }
        let fd: Int32
        if let approvedRoot {
            fd = try MachineStorageSafety.openRegularFile(part, approvedRoot: approvedRoot, flags: O_RDWR | O_CREAT,
                                                        validating: driveTarget)
        } else {
            fd = open(part.path, O_RDWR | O_CREAT | O_NOFOLLOW, 0o600)
        }
        guard fd >= 0 else { throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno)) }
        var st = stat()
        guard fstat(fd, &st) == 0, st.st_mode & S_IFMT == S_IFREG else {
            close(fd)
            throw NSError(domain: "Henge", code: 4, userInfo: [NSLocalizedDescriptionKey: "下載目的地不是一般檔案。"])
        }
        have = st.st_size
        handle = FileHandle(fileDescriptor: fd, closeOnDealloc: true)
        defer {
            try? handle?.close()
            handle = nil
        }
        var request = URLRequest(url: url)
        if have > 0 { request.setValue("bytes=\(have)-", forHTTPHeaderField: "Range") }
        let downloadRequest = request
        let cfg = configuration ?? URLSessionConfiguration.default
        cfg.timeoutIntervalForRequest = 120
        cfg.timeoutIntervalForResource = 48 * 3600
        cfg.requestCachePolicy = .reloadIgnoringLocalCacheData
        cfg.urlCache = nil
        let queue = OperationQueue()
        queue.maxConcurrentOperationCount = 1
        let s = URLSession(configuration: cfg, delegate: self, delegateQueue: queue)
        session = s
        defer { s.finishTasksAndInvalidate() }
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (c: CheckedContinuation<Void, Error>) in
                queue.addOperation {
                    self.continuation = c
                    if self.stateLock.withLock({ self.cancellationRequested }) {
                        self.finish(CancellationError())
                        return
                    }
                    let t = s.dataTask(with: downloadRequest)
                    let cancelled = self.stateLock.withLock {
                        self.task = t
                        return self.cancellationRequested
                    }
                    if cancelled { t.cancel() } else { t.resume() }
                }
            }
        } onCancel: {
            self.cancel()
        }
        try Task.checkCancellation()
        if stateLock.withLock({ cancellationRequested }) { throw CancellationError() }
    }

    /// Stops the attempt in progress (what was written stays).
    func cancel() {
        let activeTask = stateLock.withLock {
            cancellationRequested = true
            return task
        }
        activeTask?.cancel()
    }

    private func finish(_ error: Error?) {
        var result = error
        do {
            try handle?.synchronize()
            try handle?.close()
        } catch {
            if result == nil { result = error }
        }
        handle = nil
        guard let c = continuation else { return }
        continuation = nil
        let cancelled = stateLock.withLock {
            task = nil
            return cancellationRequested
        }
        if cancelled && result == nil { result = CancellationError() }
        if let result { c.resume(throwing: result) } else { c.resume() }
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive response: URLResponse,
                    completionHandler: @escaping (URLSession.ResponseDisposition) -> Void) {
        let http = response as? HTTPURLResponse
        let status = http?.statusCode ?? 0
        do {
            switch status {
            case 206: // the rest, from where the file ends: "bytes start-end/total"
                guard let range = ContentRange.parse(http?.value(forHTTPHeaderField: "Content-Range")),
                      range.start == have, let end = range.end, let length = range.total, length > 0,
                      response.expectedContentLength < 0 || response.expectedContentLength == end - have + 1 else {
                    throw Failure.invalidContentRange
                }
                total = length
                responseEnd = end
            case 200: // the whole file: start again
                total = response.expectedContentLength
                have = 0
            case 416: // Only a known exact size establishes that the HTTP response is complete.
                let range = ContentRange.parse(http?.value(forHTTPHeaderField: "Content-Range"))
                guard range?.start == nil, let length = range?.total, length > 0, have == length else {
                    throw Failure.rejectedRange(have: have, total: range?.start == nil ? range?.total : nil)
                }
                total = length
                completionHandler(.cancel)
                progress(have, total)
                finish(nil)
                return
            default:
                throw Failure.unexpectedStatus(status)
            }
            guard let h = handle else { throw CancellationError() }
            try h.truncate(atOffset: UInt64(have))
            try h.seekToEnd()
            handle = h
            progress(have, total)
            completionHandler(.allow)
        } catch {
            failure = error
            completionHandler(.cancel)
        }
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        guard let h = handle else { return }
        do {
            let next = have.addingReportingOverflow(Int64(data.count))
            guard !next.overflow, total < 0 || next.partialValue <= total,
                  responseEnd.map({ next.partialValue <= $0 + 1 }) ?? true else {
                throw Failure.invalidContentRange
            }
            try h.write(contentsOf: data)
            have = next.partialValue
            progress(have, total)
        } catch {
            failure = error
            dataTask.cancel()
        }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        if continuation == nil { return } // already finished (416 with a complete file)
        if let failure { finish(failure); return }
        if let error { finish(error); return }
        if total > 0 && have != total {
            finish(Failure.endedEarly(have: have, total: total))
            return
        }
        finish(nil)
    }
}
