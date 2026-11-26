import Darwin
import Foundation
import UIKit

/// Instant resume: when Henge leaves the foreground the running Mac is stopped where it is and written to storage,
/// so opening it again picks up there in a few seconds, even if iOS closed Henge in between. Coming straight back
/// just lets it run on. The engine keeps a saved Mac only for its disk exactly as it was (host/snapshot.c) and uses a
/// file once; this side decides when to save, and says which build and settings a file belongs to.
enum InstantResume {
    static let key = "henge.instantResume"
    static var enabled: Bool { UserDefaults.standard.bool(forKey: key) }

    /// Saving and running on take turns on one queue, never on the main thread: a save takes a few seconds.
    private static let queue = DispatchQueue(label: "henge.instant-resume", qos: .userInitiated)

    static func file(for mac: VirtualMac) -> URL { mac.directory.appendingPathComponent("resume.hsnap") }

    /// What a saved Mac is for: this build of Henge (a restored machine must meet the code that saved it), the Mac,
    /// and what it was started with. The engine adds the disk's own identity.
    static func ident(for mac: VirtualMac, ramMB: UInt64, cpus: Int) -> String {
        let info = Bundle.main.infoDictionary ?? [:]
        let version = info["CFBundleShortVersionString"] as? String ?? "?"
        let build = info["CFBundleVersion"] as? String ?? "?"
        let commit = info["HengeBuildCommit"] as? String ?? "unstamped"
        let stamp = info["HengeBuildDate"] as? String ?? "?"
        return "Henge \(version) (\(build)) \(commit) \(stamp) mac \(mac.id.uuidString) ram \(ramMB) cpus \(cpus) "
            + "screen \(mac.screen.width)x\(mac.screen.height) retina \(mac.isRetina) "
            + "host \(Device.modelIdentifier) phys \(ProcessInfo.processInfo.physicalMemory >> 20)"
    }

    /// A whole saved Mac for these settings, and when it was saved.
    static func saved(for mac: VirtualMac, ramMB: UInt64, cpus: Int) -> Date? {
        var at: Int64 = 0
        guard henge_vm_saved_ok(file(for: mac).path, ident(for: mac, ramMB: ramMB, cpus: cpus), nil, &at) == 0 else { return nil }
        return Date(timeIntervalSince1970: TimeInterval(at))
    }

    /// Whether a file is there at all (the Home screen's hint; the start checks it properly).
    static func hasSave(for mac: VirtualMac) -> Bool {
        guard mac.isAvailable else { return false }
        return FileManager.default.fileExists(atPath: file(for: mac).path)
    }

    private static func location(for mac: VirtualMac) throws -> (root: URL, target: ExternalDriveTarget?) {
        guard mac.isAvailable else { throw CocoaError(.fileReadNoSuchFile) }
        if mac.isExternal {
            guard let target = ExternalDriveRegistry.shared.driveTarget(for: mac.id) else { throw CocoaError(.fileReadNoSuchFile) }
            return (target.rootURL, target)
        }
        return (Machines.root, nil)
    }

    /// A disconnected drive or unreadable snapshot must not be mistaken for permission to cold boot.
    static func snapshotExists(for mac: VirtualMac) throws -> Bool {
        let location = try location(for: mac)
        do {
            let fd = try MachineStorageSafety.openRegularFile(file(for: mac), approvedRoot: location.root, validating: location.target)
            close(fd)
            return true
        } catch let error as NSError where error.domain == NSPOSIXErrorDomain && error.code == Int(ENOENT) && mac.isAvailable {
            return false
        }
    }

    static func discard(for mac: VirtualMac) throws {
        let location = try location(for: mac)
        _ = try MachineStorageSafety.removeRegularFile(file(for: mac), approvedRoot: location.root, validating: location.target)
    }

    /// A killed save may leave gigabytes of staging data. Never clean while a writer can be active.
    static func clearInterruptedWrite(for mac: VirtualMac) {
        guard henge_vm_can_start() != 0 else { return }
        queue.sync {
            guard henge_vm_can_start() != 0 else { return }
            do {
                let location = try location(for: mac)
                let path = file(for: mac).appendingPathExtension("part")
                _ = try MachineStorageSafety.removeRegularFile(path, approvedRoot: location.root, validating: location.target)
            } catch let error as NSError where error.domain == NSPOSIXErrorDomain && error.code == Int(ENOENT) { }
            catch { HengeLog.log("resume", "could not remove the interrupted save: \(error.localizedDescription)") }
        }
    }

    private static func discardConsumed(for mac: VirtualMac) {
        do { try discard(for: mac) }
        catch let error as NSError where error.domain == NSPOSIXErrorDomain && error.code == Int(ENOENT) { }
        catch { HengeLog.log("resume", "could not remove the consumed snapshot: \(error.localizedDescription)") }
    }

    /// Henge stopped being active (the app switcher, a call, Control Center, going home): stop the Mac where it is
    /// while the GPU is still Henge's, so what only the GPU holds goes back into the Mac's memory.
    static func pause() {
        guard enabled, henge_vm_state() == 1 else { return }
        let generation = henge_vm_generation()
        queue.async {
            guard henge_vm_generation() == generation else { return }
            var buffer = [CChar](repeating: 0, count: 256)
            if henge_vm_pause(&buffer, buffer.count) != 0 { HengeLog.log("resume", "not paused: \(String(cString: buffer))") }
        }
    }

    /// Henge is in the background: write the paused Mac out, in case iOS closes Henge. It stays paused.
    static func suspend(_ mac: VirtualMac, ramMB: UInt64, cpus: Int) {
        guard enabled, mac.isAvailable, henge_vm_state() == 1 || henge_vm_state() == 4 else { return }
        let path = file(for: mac).path, id = ident(for: mac, ramMB: ramMB, cpus: cpus)
        let generation = henge_vm_generation()
        var task = UIBackgroundTaskIdentifier.invalid
        task = UIApplication.shared.beginBackgroundTask(withName: "Henge save") {
            UIApplication.shared.endBackgroundTask(task)
            task = .invalid
        }
        queue.async {
            defer {
                DispatchQueue.main.async {
                    if task != .invalid { UIApplication.shared.endBackgroundTask(task) }
                    task = .invalid
                }
            }
            guard henge_vm_generation() == generation else { return }
            let t0 = Date()
            var buffer = [CChar](repeating: 0, count: 256)
            /* Paused already, unless Henge went straight to the background. */
            var rc = henge_vm_state() == 4 ? 0 : henge_vm_pause(&buffer, buffer.count)
            if rc == 0 { rc = henge_vm_save(path, id, &buffer, buffer.count) }
            let took = String(format: "%.1f", Date().timeIntervalSince(t0))
            if rc == 0 {
                let bytes = (try? FileManager.default.attributesOfItem(atPath: path)[.size] as? Int64) ?? 0
                HengeLog.log("resume", "saved the Mac in \(took) s (\(ByteText.string(UInt64(max(bytes, 0)))))")
            } else {
                HengeLog.log("resume", "not saved after \(took) s: \(String(cString: buffer))")
            }
        }
    }

    /// Back in the foreground before iOS closed Henge (or active again after a moment inactive): the saved file, if
    /// any, is out of date the moment the Mac runs on.
    static func cameBack(_ mac: VirtualMac) {
        let generation = henge_vm_generation()
        queue.async {
            guard henge_vm_generation() == generation, henge_vm_state() == 4 else { return }
            if henge_vm_continue() == 0 {
                discardConsumed(for: mac)
                HengeLog.log("resume", "back: the Mac runs on")
            } else {
                HengeLog.log("resume", "back: the Mac could not run on; saved snapshot retained")
            }
        }
    }

    static func forceStop(_ mac: VirtualMac) {
        let generation = henge_vm_generation()
        queue.async {
            let state = henge_vm_state()
            guard henge_vm_generation() == generation, state == 1 || state == 4 else { return }
            henge_vm_stop()
            // A paused stop finishes synchronously. A running Mac already consumed its snapshot.
            if state == 4, henge_vm_generation() == generation,
               henge_vm_exit_outcome() == Int32(HENGE_VM_OUTCOME_HOST_STOP.rawValue) {
                discardConsumed(for: mac)
            }
        }
    }
}
