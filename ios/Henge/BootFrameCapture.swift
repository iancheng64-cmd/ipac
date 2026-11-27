import Foundation
import CoreGraphics

enum BootFrameCapture {
    // The boot-args scan may fault in file-backed guest pages; never run it on the UI thread.
    private static let queue = DispatchQueue(label: "com.henge.boot-frame", qos: .utility)

    static func frame(for generation: UInt64) async -> CGImage? {
        await withCheckedContinuation { continuation in
            queue.async {
                guard henge_vm_generation() == generation, henge_vm_state() == 1 else {
                    continuation.resume(returning: nil)
                    return
                }
                continuation.resume(returning: capture())
            }
        }
    }

    private static func capture() -> CGImage? {
        var address: UnsafePointer<UInt8>?
        var w: Int32 = 0, h: Int32 = 0, stride: Int32 = 0
        guard henge_vm_boot_display(&address, &w, &h, &stride) == 0, let address else { return nil }
        // The native bridge already copied out of guest RAM. Transfer that copy to Core Graphics.
        guard w > 0, h > 0, Int(stride) >= Int(w) * 4,
              let provider = CGDataProvider(dataInfo: nil, data: address, size: Int(stride) * Int(h),
                                            releaseData: { _, data, _ in
                                                henge_vm_free_display(data.assumingMemoryBound(to: UInt8.self))
                                            }) else {
            henge_vm_free_display(address)
            return nil
        }
        let info = CGBitmapInfo(rawValue: CGImageAlphaInfo.noneSkipFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue)
        return CGImage(width: Int(w), height: Int(h), bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: Int(stride),
                       space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: info, provider: provider, decode: nil,
                       shouldInterpolate: true, intent: .defaultIntent)
    }
}
