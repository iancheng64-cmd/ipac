import Foundation

final class DownloadTestProtocol: URLProtocol, @unchecked Sendable {
    struct Reply {
        let status: Int
        let headers: [String: String]
        let data: Data
        var beforeResponse: (() -> Void)?
        var beforeFinish: (() -> Void)?
    }
    final class State: @unchecked Sendable {
        let lock = NSLock()
        var reply = Reply(status: 200, headers: [:], data: Data())
        var seenRange: String?
    }
    static let state = State()

    static func setReply(_ reply: Reply) {
        state.lock.withLock {
            state.reply = reply
            state.seenRange = nil
        }
    }
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        let reply = Self.state.lock.withLock {
            Self.state.seenRange = request.value(forHTTPHeaderField: "Range")
            return Self.state.reply
        }
        reply.beforeResponse?()
        let response = HTTPURLResponse(url: request.url!, statusCode: reply.status,
                                       httpVersion: "HTTP/1.1", headerFields: reply.headers)!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        if !reply.data.isEmpty { client?.urlProtocol(self, didLoad: reply.data) }
        reply.beforeFinish?()
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}

@main
struct RangedDownloadTests {
    static func main() async throws {
        let fm = FileManager.default
        let root = fm.temporaryDirectory.appendingPathComponent("henge-ranged-download-\(UUID().uuidString)", isDirectory: true)
        try fm.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: root) }
        var checks = 0
        func check(_ condition: Bool, _ name: String) {
            checks += 1
            precondition(condition, name)
        }
        func download(_ name: String, initial: String, reply: DownloadTestProtocol.Reply) async throws -> (Result<Void, Error>, URL) {
            let part = root.appendingPathComponent("\(name).part")
            try Data(initial.utf8).write(to: part)
            DownloadTestProtocol.setReply(reply)
            let config = URLSessionConfiguration.ephemeral
            config.protocolClasses = [DownloadTestProtocol.self]
            let operation = RangedDownload(url: URL(string: "https://download.test/image.ipsw")!, part: part,
                                           configuration: config) { _, _ in }
            do {
                try await operation.run()
                return (.success(()), part)
            } catch {
                return (.failure(error), part)
            }
        }
        func succeeded(_ result: Result<Void, Error>) -> Bool {
            if case .success = result { return true }
            return false
        }

        check(RangedDownload.ContentRange.parse("bytes 2-3/4") == .init(start: 2, end: 3, total: 4), "parse satisfied range")
        check(RangedDownload.ContentRange.parse("bytes */4") == .init(start: nil, end: nil, total: 4), "parse unsatisfied range")
        check(RangedDownload.ContentRange.parse("bytes 3-2/4") == nil, "reversed range rejected")
        check(RangedDownload.ContentRange.parse("bytes 0-4/4") == nil, "range past total rejected")
        check(RangedDownload.ContentRange.parse("bytes */*") == nil, "unknown unsatisfied size rejected")
        check(RangedDownload.ContentRange.parse("bytes 9223372036854775808-9223372036854775809/9223372036854775810") == nil,
              "overflowing range rejected")

        let (whole, wholePart) = try await download("whole", initial: "old", reply: .init(
            status: 200, headers: ["Content-Length": "4"], data: Data("abcd".utf8)))
        let wholeData = try Data(contentsOf: wholePart)
        check(succeeded(whole) && wholeData == Data("abcd".utf8), "200 restarts old partial file")
        let (resume, resumePart) = try await download("resume", initial: "ab", reply: .init(
            status: 206, headers: ["Content-Range": "bytes 2-3/4", "Content-Length": "2"], data: Data("cd".utf8)))
        let resumeData = try Data(contentsOf: resumePart)
        check(succeeded(resume) && resumeData == Data("abcd".utf8), "206 resumes correctly")
        check(DownloadTestProtocol.state.lock.withLock { DownloadTestProtocol.state.seenRange } == "bytes=2-", "resume request header")

        let (wrongRange, wrongPart) = try await download("wrong-range", initial: "ab", reply: .init(
            status: 206, headers: ["Content-Range": "bytes 0-1/4", "Content-Length": "2"], data: Data("xy".utf8)))
        let wrongData = try Data(contentsOf: wrongPart)
        check(!succeeded(wrongRange) && wrongData == Data("ab".utf8), "wrong range preserves existing part")
        let (short, _) = try await download("short", initial: "ab", reply: .init(
            status: 206, headers: ["Content-Range": "bytes 2-3/4", "Content-Length": "2"], data: Data("c".utf8)))
        check(!succeeded(short), "successful HTTP callback cannot hide short body")
        let (badLength, _) = try await download("bad-length", initial: "ab", reply: .init(
            status: 206, headers: ["Content-Range": "bytes 2-3/4", "Content-Length": "3"], data: Data("cd".utf8)))
        check(!succeeded(badLength), "range and content length must agree")

        let (noTotal, noTotalPart) = try await download("416-no-total", initial: "ab", reply: .init(
            status: 416, headers: [:], data: Data()))
        let noTotalData = try Data(contentsOf: noTotalPart)
        check(!succeeded(noTotal) && noTotalData == Data("ab".utf8), "416 without size is not completion")
        let (incomplete, _) = try await download("416-incomplete", initial: "ab", reply: .init(
            status: 416, headers: ["Content-Range": "bytes */4"], data: Data()))
        check(!succeeded(incomplete), "416 with a smaller local file is not completion")
        let (complete, completePart) = try await download("416-complete", initial: "abcd", reply: .init(
            status: 416, headers: ["Content-Range": "bytes */4"], data: Data()))
        let completeData = try Data(contentsOf: completePart)
        check(succeeded(complete) && completeData == Data("abcd".utf8), "known exact 416 size completes HTTP only")
        let (oversized, oversizedPart) = try await download("416-oversized", initial: "abcde", reply: .init(
            status: 416, headers: ["Content-Range": "bytes */4"], data: Data()))
        let oversizedData = try Data(contentsOf: oversizedPart)
        check(!succeeded(oversized) && oversizedData == Data("abcde".utf8), "oversized 416 is not silently truncated")
        if case let .failure(error) = oversized {
            check((error as? RangedDownload.Failure)?.shouldRestartPartialDownload == true, "oversized managed part may restart")
        }
        let (malformed, _) = try await download("416-malformed", initial: "abcde", reply: .init(
            status: 416, headers: ["Content-Range": "bytes 0-3/4"], data: Data()))
        check(!succeeded(malformed), "satisfied range on 416 rejected")
        if case let .failure(error) = malformed {
            check((error as? RangedDownload.Failure)?.shouldRestartPartialDownload == false, "malformed 416 does not justify deleting partial data")
        }

        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [DownloadTestProtocol.self]
        let cancelledPart = root.appendingPathComponent("cancelled.part")
        let cancelled = RangedDownload(url: URL(string: "https://download.test/image.ipsw")!, part: cancelledPart,
                                       configuration: config) { _, _ in }
        cancelled.cancel()
        do {
            try await cancelled.run()
            check(false, "pre-cancelled operation must throw")
        } catch {
            check(error is CancellationError && !fm.fileExists(atPath: cancelledPart.path), "pre-cancelled operation does no filesystem work")
        }

        let latePart = root.appendingPathComponent("late-cancel.part")
        try Data("abcd".utf8).write(to: latePart)
        let lateCancelled = RangedDownload(url: URL(string: "https://download.test/image.ipsw")!, part: latePart,
                                           configuration: config) { _, _ in }
        DownloadTestProtocol.setReply(.init(status: 416, headers: ["Content-Range": "bytes */4"], data: Data(),
                                           beforeResponse: { lateCancelled.cancel() }))
        do {
            try await lateCancelled.run()
            check(false, "cancelled 416 operation must throw")
        } catch {
            check((error is CancellationError) || (error as NSError).code == NSURLErrorCancelled, "cancellation cannot turn into 416 success")
        }

        let personal = root.appendingPathComponent("personal.ipsw")
        let symlink = root.appendingPathComponent("symlink.part")
        try Data("personal".utf8).write(to: personal)
        try fm.createSymbolicLink(at: symlink, withDestinationURL: personal)
        let unsafe = RangedDownload(url: URL(string: "https://download.test/image.ipsw")!, part: symlink,
                                    configuration: config) { _, _ in }
        do {
            try await unsafe.run()
            check(false, "symlink download must throw")
        } catch {
            check((try Data(contentsOf: personal)) == Data("personal".utf8), "download cannot overwrite symlink target")
        }

        let managed = root.appendingPathComponent("managed", isDirectory: true)
        let outside = root.appendingPathComponent("outside", isDirectory: true)
        try fm.createDirectory(at: managed, withIntermediateDirectories: true)
        try fm.createDirectory(at: outside, withIntermediateDirectories: true)
        let outsideFile = outside.appendingPathComponent("image.part")
        try Data("personal".utf8).write(to: outsideFile)
        let parentLink = managed.appendingPathComponent("redirect", isDirectory: true)
        try fm.createSymbolicLink(at: parentLink, withDestinationURL: outside)
        let redirected = RangedDownload(url: URL(string: "https://download.test/image.ipsw")!,
                                         part: parentLink.appendingPathComponent("image.part"), approvedRoot: managed,
                                         configuration: config) { _, _ in }
        do {
            try await redirected.run()
            check(false, "symlink parent download must throw")
        } catch {
            check((try Data(contentsOf: outsideFile)) == Data("personal".utf8),
                  "anchored download cannot follow a parent symlink")
        }

        let hardLink = managed.appendingPathComponent("hard-link.part")
        try fm.linkItem(at: outsideFile, to: hardLink)
        let linked = RangedDownload(url: URL(string: "https://download.test/image.ipsw")!, part: hardLink,
                                    approvedRoot: managed, configuration: config) { _, _ in }
        do {
            try await linked.run()
            check(false, "hard-linked download must throw")
        } catch {
            check((try Data(contentsOf: outsideFile)) == Data("personal".utf8),
                  "anchored download cannot mutate a hard-link target")
        }

        let drive = root.appendingPathComponent("drive", isDirectory: true)
        let detached = root.appendingPathComponent("detached-drive", isDirectory: true)
        try fm.createDirectory(at: drive, withIntermediateDirectories: true)
        let drivePart = drive.appendingPathComponent("image.part")
        try Data("ab".utf8).write(to: drivePart)
        guard let target = ExternalDriveTarget.capture(rootURL: drive, displayName: "test drive") else {
            preconditionFailure("test drive identity capture failed")
        }
        try fm.moveItem(at: drive, to: detached)
        try fm.createDirectory(at: drive, withIntermediateDirectories: true)
        try Data("personal".utf8).write(to: drivePart)
        let replaced = RangedDownload(url: URL(string: "https://download.test/image.ipsw")!, part: drivePart,
                                      approvedRoot: drive, validating: target, configuration: config) { _, _ in }
        do {
            try await replaced.run()
            check(false, "reused drive path must throw")
        } catch {
            check((try Data(contentsOf: drivePart)) == Data("personal".utf8),
                  "anchored download cannot write into a replacement drive")
            check((try Data(contentsOf: detached.appendingPathComponent("image.part"))) == Data("ab".utf8),
                  "unavailable original drive also remains unchanged")
        }
        print("Ranged download: \(checks) checks, 0 failures")
    }
}
