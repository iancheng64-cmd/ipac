import Foundation
import Darwin

/// Mirrors the native log without polling. The caller keeps fd open for the crash handler.
final class NativeLogTail {
    private let fd: Int32
    private let source: DispatchSourceFileSystemObject
    private let onLine: (String) -> Void
    private var partial = Data()
    private var truncated = false
    private static let recordLimit = 64 * 1024
    private var buffer = [UInt8](repeating: 0, count: 16 * 1024)
    private let onDrain: (() -> Void)?

    init(fd: Int32, onDrain: (() -> Void)? = nil, onLine: @escaping (String) -> Void) {
        self.fd = fd
        self.onDrain = onDrain
        self.onLine = onLine
        let queue = DispatchQueue(label: "com.henge.log.reader", qos: .utility)
        source = DispatchSource.makeFileSystemObjectSource(fileDescriptor: fd, eventMask: [.write, .extend], queue: queue)
        // Drain after registration: data written before the source became active cannot be lost.
        source.setRegistrationHandler { [weak self] in self?.drain() }
        source.setEventHandler { [weak self] in self?.drain() }
        source.activate()
    }

    deinit { source.cancel() }

    private func drain() {
        defer { onDrain?() }
        while true {
            let count = read(fd, &buffer, buffer.count)
            if count < 0 && errno == EINTR { continue }
            guard count > 0 else { return }
            var start = 0
            for i in 0..<count where buffer[i] == 10 {
                appendBytes(start..<i)
                if truncated {
                    onLine(String(decoding: partial, as: UTF8.self) + " [truncated in viewer]")
                } else if let line = String(data: partial, encoding: .utf8) { onLine(line) }
                partial.removeAll(keepingCapacity: true)
                truncated = false
                start = i + 1
            }
            appendBytes(start..<count)
        }
    }

    // The original is already on disk; a missing newline must not consume guest headroom.
    private func appendBytes(_ range: Range<Int>) {
        guard !truncated, !range.isEmpty else { return }
        let n = min(Self.recordLimit - partial.count, range.count)
        partial.append(contentsOf: buffer[range.lowerBound..<(range.lowerBound + n)])
        truncated = n < range.count
    }

    static func previousLines(at url: URL) -> [Substring] {
        guard let file = try? FileHandle(forReadingFrom: url) else { return [] }
        defer { try? file.close() }
        do {
            let end = try file.seekToEnd()
            let limit: UInt64 = 8192
            try file.seek(toOffset: end > limit ? end - limit : 0)
            guard let bytes = try file.read(upToCount: Int(limit)) else { return [] }
            return Array(String(decoding: bytes, as: UTF8.self).split(separator: "\n").suffix(40))
        } catch { return [] }
    }
}

struct RecentLogLines {
    private var slots: [String] = []
    private var next = 0
    private let capacity: Int
    init(capacity: Int) {
        precondition(capacity > 0)
        self.capacity = capacity
        slots.reserveCapacity(capacity)
    }
    mutating func append(_ line: String) {
        if slots.count < capacity { slots.append(line) } else { slots[next] = line }
        next += 1
        if next == capacity { next = 0 }
    }
    func suffix(_ limit: Int) -> [String] {
        let count = min(max(0, limit), slots.count)
        guard count > 0 else { return [] }
        let start = (capacity + next - count) % capacity
        if start + count <= slots.count { return Array(slots[start..<(start + count)]) }
        return Array(slots[start...]) + slots.prefix(count - (slots.count - start))
    }
}
