import Foundation
import Darwin

@main
struct LogTests {
    static func main() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appendingPathComponent("native.log")
        try Data("before\nhel".utf8).write(to: url)
        let fd = open(url.path, O_RDONLY)
        precondition(fd >= 0)
        defer { close(fd) }
        let writer = try FileHandle(forWritingTo: url)
        defer { try? writer.close() }
        _ = try writer.seekToEnd()
        let done = DispatchSemaphore(value: 0), lock = NSLock()
        var lines: [String] = [], calls = 0
        let tail = NativeLogTail(fd: fd, onDrain: {
            lock.lock(); calls += 1; lock.unlock(); done.signal()
        }) { line in lock.lock(); lines.append(line); lock.unlock() }
        try withExtendedLifetime(tail) {
            precondition(done.wait(timeout: .now() + 3) == .success)
            precondition(lock.withLock { lines == ["before"] })
            // Allow any queued registration/event coalescing to finish before the idle interval.
            Thread.sleep(forTimeInterval: 0.1)
            let idle = lock.withLock { calls }
            Thread.sleep(forTimeInterval: 0.5)
            precondition(lock.withLock { calls == idle })
            let long = String(repeating: "x", count: 17_001)
            let emoji = Array("🖱".utf8)
            try writer.write(contentsOf: Data("lo\n\n".utf8) + Data(emoji.prefix(2)))
            try writer.write(contentsOf: Data(emoji.dropFirst(2)) + Data(("\n" + long + "\n").utf8))
            for _ in 0..<20 {
                if lock.withLock({ lines.count == 5 }) { break }
                _ = done.wait(timeout: .now() + 0.1)
            }
            precondition(lock.withLock { lines == ["before", "hello", "", "🖱", long] })
            let oversized = Data(repeating: 120, count: 1024 * 1024)
            try writer.write(contentsOf: oversized + Data("\nafter\n".utf8))
            for _ in 0..<50 {
                if lock.withLock({ lines.count == 7 }) { break }
                _ = done.wait(timeout: .now() + 0.1)
            }
            precondition(lock.withLock {
                lines.count == 7 && lines[5] == String(repeating: "x", count: 64 * 1024) + " [truncated in viewer]"
                    && lines[6] == "after"
            })
        }
        var ring = RecentLogLines(capacity: 7)
        var ref: [String] = []
        for i in 0..<40 {
            for n in -1...11 { precondition(ring.suffix(n) == Array(ref.suffix(max(0,n)))) }
            let str = String(i)
            ring.append(str); ref.append(str)
            if ref.count > 7 { ref.removeFirst() }
        }
        let prev = dir.appendingPathComponent("previous")
        try Data().write(to: prev)
        let sparse = try FileHandle(forWritingTo: prev)
        try sparse.truncate(atOffset: 256 * 1024 * 1024)
        _ = try sparse.seekToEnd()
        try sparse.write(contentsOf: Data((String(repeating: "a", count: 9000) + "\n" +
            (1...50).map(String.init).joined(separator: "\n") + "\n").utf8))
        try sparse.close()
        precondition(NativeLogTail.previousLines(at: prev).map(String.init) == (11...50).map(String.init))
        print("Native log: startup, partial UTF-8, 17 KB line, bounded 1 MiB line, 0 idle callback / 0.5s, ring wrap and 256 MiB sparse replay pass")
    }
}
