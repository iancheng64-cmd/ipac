import Foundation
import CoreGraphics
import Darwin

private let lock = NSLock()
private var invalid = false, running: Int32 = 1, calls = 0, releases = 0

@_cdecl("henge_vm_state") func fixtureState() -> Int32 { lock.withLock { running } }
@_cdecl("henge_vm_generation") func fixtureGeneration() -> UInt64 { 7 }
@_cdecl("henge_vm_boot_display")
func fixtureDisplay(_ pixels: UnsafeMutablePointer<UnsafePointer<UInt8>?>, _ w: UnsafeMutablePointer<Int32>,
                    _ h: UnsafeMutablePointer<Int32>, _ stride: UnsafeMutablePointer<Int32>) -> Int32 {
    precondition(pthread_main_np() == 0)
    let p = malloc(16)!.assumingMemoryBound(to: UInt8.self)
    memset(p, 0x3b, 16)
    pixels.pointee = UnsafePointer(p)
    let bad = lock.withLock { calls += 1; return invalid }
    w.pointee = 2; h.pointee = 2; stride.pointee = bad ? 1 : 8
    return 0
}
@_cdecl("henge_vm_free_display") func fixtureRelease(_ p: UnsafePointer<UInt8>) {
    free(UnsafeMutableRawPointer(mutating: p))
    lock.withLock { releases += 1 }
}

@main struct Test {
    static func main() async {
        var frame = await BootFrameCapture.frame(for: 7)
        precondition(frame?.width == 2 && frame?.height == 2)
        precondition(lock.withLock { calls == 1 && releases == 0 })
        precondition((frame!.dataProvider!.data! as Data) == Data(repeating: 0x3b, count: 16))
        frame = nil
        lock.withLock { invalid = true }
        let bad = await BootFrameCapture.frame(for: 7)
        let stale = await BootFrameCapture.frame(for: 6)
        lock.withLock { running = 2 }
        let stopped = await BootFrameCapture.frame(for: 7)
        precondition(bad == nil && stale == nil && stopped == nil)
        precondition(lock.withLock { calls == 2 && releases == 2 })
        print("Boot frame: background capture, pixels, ownership, invalid stride, stale generation and stopped VM pass")
    }
}
