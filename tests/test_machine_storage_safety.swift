import Darwin
import Foundation

private struct CheckFailure: Error, CustomStringConvertible {
    let description: String
}

@main
struct MachineStorageSafetyTests {
    private static var checks = 0
    private static let fm = FileManager.default

    private static func check(_ condition: @autoclosure () throws -> Bool, _ text: String) throws {
        checks += 1
        if try !condition() { throw CheckFailure(description: text) }
    }

    private static func rejects(_ text: String, _ action: () throws -> Void) throws {
        do {
            try action()
        } catch {
            checks += 1
            return
        }
        throw CheckFailure(description: text)
    }

    private static func write(_ file: URL, _ text: String = "owned fixture") throws {
        try Data(text.utf8).write(to: file)
    }

    private static func machine(in parent: URL, name: String = UUID().uuidString) throws -> URL {
        let dir = parent.appendingPathComponent(name, isDirectory: true)
        try fm.createDirectory(at: dir, withIntermediateDirectories: true)
        for file in ["disk.img", "AVPBooter.vmapple2.bin", "auxiliary.bin"] {
            try write(dir.appendingPathComponent(file))
        }
        try write(dir.appendingPathComponent("machine.json"), "{\"ecid\":123}")
        return dir
    }

    private static func readyExport(in parent: URL, name: String, ecid: UInt64 = 123, payload: String) throws -> URL {
        let dir = try machine(in: parent, name: name)
        try write(dir.appendingPathComponent("machine.json"), "{\"ecid\":\(ecid)}")
        try write(dir.appendingPathComponent("disk.img"), payload)
        try write(dir.appendingPathComponent("installed"), "macOS")
        return dir
    }

    static func main() throws {
        let root = fm.temporaryDirectory.appendingPathComponent("henge-storage-regression-\(UUID().uuidString)", isDirectory: true)
        try fm.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: root) }

        let drive = root.appendingPathComponent("SSD-A", isDirectory: true)
        let originalVM = try machine(in: drive)
        guard let originalTarget = ExternalDriveTarget.capture(rootURL: drive, displayName: "SSD-A") else {
            throw CheckFailure(description: "Cannot capture fixture drive")
        }
        try check(originalTarget.isAvailable, "Initial drive is available")
        let detached = root.appendingPathComponent("detached-SSD-A", isDirectory: true)
        try fm.moveItem(at: drive, to: detached)
        let replacementVM = try machine(in: drive, name: originalVM.lastPathComponent)
        try check(!originalTarget.isAvailable, "An old target must reject same-path replacement")
        try rejects("A confirmed old drive must not delete the replacement SSD") {
            _ = try MachineStorageSafety.deleteMachineFiles(
                in: replacementVM, approvedRoot: drive, allowRemovingDirectory: true, validating: originalTarget
            )
        }
        try check(fm.fileExists(atPath: replacementVM.appendingPathComponent("disk.img").path), "Replacement disk remains")
        try check(fm.fileExists(atPath: detached.appendingPathComponent(originalVM.lastPathComponent).appendingPathComponent("disk.img").path), "Detached original disk remains")
        guard let replacementTarget = ExternalDriveTarget.capture(rootURL: drive, displayName: "SSD-B") else {
            throw CheckFailure(description: "Cannot capture replacement drive")
        }
        try check(replacementTarget != originalTarget, "Each confirmation target has a distinct token")
        try rejects("A target must not authorize a sibling bookmark root") {
            _ = try MachineStorageSafety.deleteMachineFiles(
                in: detached.appendingPathComponent(originalVM.lastPathComponent),
                approvedRoot: detached, allowRemovingDirectory: true, validating: replacementTarget
            )
        }

        let personal = try machine(in: root, name: "Personal")
        let linkRoot = root.appendingPathComponent("symbolic-root", isDirectory: true)
        try fm.createSymbolicLink(at: linkRoot, withDestinationURL: personal)
        try check(ExternalDriveTarget.capture(rootURL: linkRoot, displayName: "invalid") == nil, "A symbolic bookmark root is rejected")
        let symbolicVM = drive.appendingPathComponent("symbolic-machine", isDirectory: true)
        try fm.createSymbolicLink(at: symbolicVM, withDestinationURL: personal)
        try check(!MachineStorageSafety.isOwnedMachineDirectory(symbolicVM, within: drive), "A VM directory symlink is not ownership")
        try rejects("Deleting a symbolic machine must fail") {
            _ = try MachineStorageSafety.deleteMachineFiles(in: symbolicVM, approvedRoot: drive, allowRemovingDirectory: true)
        }
        try check(fm.fileExists(atPath: personal.appendingPathComponent("disk.img").path), "Personal disk through directory link remains")

        let linkedParent = drive.appendingPathComponent("HengeMachines", isDirectory: true)
        try fm.createSymbolicLink(at: linkedParent, withDestinationURL: detached)
        let linkedChild = linkedParent.appendingPathComponent(originalVM.lastPathComponent, isDirectory: true)
        try check(!MachineStorageSafety.isSafeDirectory(linkedChild, within: drive), "Intermediate symlinks are rejected")
        try rejects("Clearing an intermediate symlink must fail") {
            _ = try MachineStorageSafety.deleteMachineFiles(in: linkedChild, approvedRoot: drive, allowRemovingDirectory: true)
        }

        let linkedDiskVM = try machine(in: drive)
        try fm.removeItem(at: linkedDiskVM.appendingPathComponent("disk.img"))
        try write(linkedDiskVM.appendingPathComponent("disk.img.hvsparse"))
        try fm.createSymbolicLink(at: linkedDiskVM.appendingPathComponent("disk.img"), withDestinationURL: personal.appendingPathComponent("disk.img"))
        try rejects("A leaf disk link must fail before any known file is removed") {
            _ = try MachineStorageSafety.deleteMachineFiles(in: linkedDiskVM, approvedRoot: drive, allowRemovingDirectory: true)
        }
        try check(fm.fileExists(atPath: linkedDiskVM.appendingPathComponent("AVPBooter.vmapple2.bin").path), "Preflight preserves core files on leaf-link failure")
        try check(fm.fileExists(atPath: personal.appendingPathComponent("disk.img").path), "Personal disk through leaf link remains")

        let deepVM = try machine(in: drive)
        let deepRestore = deepVM.appendingPathComponent("restore/subdirectory", isDirectory: true)
        try fm.createDirectory(at: deepRestore, withIntermediateDirectories: true)
        try write(deepVM.appendingPathComponent("restore/first-file"))
        try fm.createSymbolicLink(at: deepRestore.appendingPathComponent("private-disk"), withDestinationURL: personal.appendingPathComponent("disk.img"))
        try rejects("A deep restore symlink must fail before deleting the VM") {
            _ = try MachineStorageSafety.deleteMachineFiles(in: deepVM, approvedRoot: drive, allowRemovingDirectory: true)
        }
        try check(fm.fileExists(atPath: deepVM.appendingPathComponent("disk.img").path), "Deep preflight preserves the VM disk")
        try check(fm.fileExists(atPath: deepVM.appendingPathComponent("restore/first-file").path), "Deep preflight preserves earlier restore files")
        try rejects("A managed directory must preflight all children") {
            _ = try MachineStorageSafety.removeManagedDirectory(deepVM.appendingPathComponent("restore"), approvedRoot: drive)
        }
        try check(fm.fileExists(atPath: deepVM.appendingPathComponent("restore/first-file").path), "Managed directory preflight makes no partial deletion")

        let wrongTypeVM = try machine(in: drive)
        let wrongType = wrongTypeVM.appendingPathComponent("preview.jpg", isDirectory: true)
        try fm.createDirectory(at: wrongType, withIntermediateDirectories: true)
        try write(wrongType.appendingPathComponent("personal.txt"))
        try rejects("A directory named like a whitelisted file must not be recursively deleted") {
            _ = try MachineStorageSafety.deleteMachineFiles(in: wrongTypeVM, approvedRoot: drive, allowRemovingDirectory: true)
        }
        try check(fm.fileExists(atPath: wrongType.appendingPathComponent("personal.txt").path), "Unknown same-name directory contents remain")
        try check(fm.fileExists(atPath: wrongTypeVM.appendingPathComponent("disk.img").path), "Type mismatch is found before disk removal")

        let unknown = drive.appendingPathComponent("Unknown", isDirectory: true)
        try fm.createDirectory(at: unknown, withIntermediateDirectories: true)
        try write(unknown.appendingPathComponent("disk.img"), "personal image")
        try rejects("A same-name disk without VM identity must not be deleted") {
            _ = try MachineStorageSafety.deleteMachineFiles(in: unknown, approvedRoot: drive, allowRemovingDirectory: true)
        }
        try check(fm.fileExists(atPath: unknown.appendingPathComponent("disk.img").path), "Unowned disk remains")

        let fifoVM = try machine(in: drive)
        let fifoManifest = fifoVM.appendingPathComponent("machine.json")
        try fm.removeItem(at: fifoManifest)
        guard mkfifo(fifoManifest.path, 0o600) == 0 else {
            throw CheckFailure(description: "Cannot create FIFO fixture")
        }
        try check(!MachineStorageSafety.isOwnedMachineDirectory(fifoVM, within: drive), "A FIFO manifest is rejected without waiting for a writer")
        try rejects("Opening a non-regular FIFO must fail without hanging") {
            let fd = try MachineStorageSafety.openRegularFile(fifoManifest, approvedRoot: drive)
            close(fd)
        }

        let mixedVM = try machine(in: drive)
        let keep = mixedVM.appendingPathComponent("Keep.txt")
        try write(keep, "personal file")
        try check(!MachineStorageSafety.containsOnlyMachineEntries(mixedVM, within: drive), "Move replacement is refused when unknown files exist")
        try check(!MachineStorageSafety.isOwnedMachineDirectory(mixedVM, within: drive, matchingECID: 456), "A different ECID is not a replaceable copy")
        _ = try MachineStorageSafety.deleteMachineFiles(in: mixedVM, approvedRoot: drive, allowRemovingDirectory: true, validating: replacementTarget)
        try check(fm.fileExists(atPath: keep.path), "Known-file cleanup preserves unknown files")
        try check(fm.fileExists(atPath: mixedVM.path), "A VM directory containing unknown files remains")
        try check(!fm.fileExists(atPath: mixedVM.appendingPathComponent("disk.img").path), "Known VM disk is cleaned")

        let selectedMachineRoot = try machine(in: root)
        _ = try MachineStorageSafety.deleteMachineFiles(
            in: selectedMachineRoot, approvedRoot: selectedMachineRoot, allowRemovingDirectory: true
        )
        try check(fm.fileExists(atPath: selectedMachineRoot.path), "The approved bookmark root itself is never removed")

        let staging = drive.appendingPathComponent("HengeInstall", isDirectory: true)
        let work = staging.appendingPathComponent("restore-\(UUID().uuidString)", isDirectory: true)
        let images = staging.appendingPathComponent("Restore images", isDirectory: true)
        try fm.createDirectory(at: work, withIntermediateDirectories: true)
        try fm.createDirectory(at: images, withIntermediateDirectories: true)
        try write(work.appendingPathComponent("payload"))
        try write(images.appendingPathComponent("owned.ipsw"))
        try write(images.appendingPathComponent("owned.ipsw.part"))
        try write(images.appendingPathComponent("photo.jpg"), "personal photo")
        try write(staging.appendingPathComponent("restore-personal"), "personal file")
        try fm.createSymbolicLink(at: images.appendingPathComponent("linked.ipsw"), withDestinationURL: personal.appendingPathComponent("disk.img"))
        _ = try MachineStorageSafety.clearInstallStaging(staging, approvedRoot: drive, validating: replacementTarget)
        try check(!fm.fileExists(atPath: work.path), "Owned UUID restore work is cleaned")
        try check(!fm.fileExists(atPath: images.appendingPathComponent("owned.ipsw").path), "Managed restore image is cleaned")
        try check(!fm.fileExists(atPath: images.appendingPathComponent("owned.ipsw.part").path), "Managed partial image is cleaned")
        try check(fm.fileExists(atPath: images.appendingPathComponent("photo.jpg").path), "Other staging files remain")
        try check(fm.fileExists(atPath: staging.appendingPathComponent("restore-personal").path), "Non-UUID restore names remain")
        try check(fm.fileExists(atPath: personal.appendingPathComponent("disk.img").path), "A restore image link does not delete its destination")

        let unsafeStaging = drive.appendingPathComponent("unsafe-staging", isDirectory: true)
        let unsafeWork = unsafeStaging.appendingPathComponent("restore-\(UUID().uuidString)", isDirectory: true)
        try fm.createDirectory(at: unsafeWork, withIntermediateDirectories: true)
        try write(unsafeWork.appendingPathComponent("first-file"))
        try fm.createSymbolicLink(at: unsafeWork.appendingPathComponent("linked"), withDestinationURL: personal.appendingPathComponent("disk.img"))
        try rejects("Staging must preflight its entire managed work tree before removing files") {
            _ = try MachineStorageSafety.clearInstallStaging(unsafeStaging, approvedRoot: drive, validating: replacementTarget)
        }
        try check(fm.fileExists(atPath: unsafeWork.appendingPathComponent("first-file").path), "Unsafe staging failure makes no partial deletion")

        let writable = drive.appendingPathComponent("write-tests", isDirectory: true)
        try fm.createDirectory(at: writable, withIntermediateDirectories: true)
        let source = writable.appendingPathComponent("download.ipsw.part")
        let destination = writable.appendingPathComponent("download.ipsw")
        try write(source, "download")
        try write(destination, "existing data")
        try rejects("Promoting a download must not overwrite an existing destination") {
            try MachineStorageSafety.promoteRegularFile(from: source, to: destination, approvedRoot: drive, validating: replacementTarget)
        }
        try check(try String(contentsOf: destination, encoding: .utf8) == "existing data", "Existing promotion destination remains unchanged")
        try fm.removeItem(at: destination)
        try MachineStorageSafety.promoteRegularFile(from: source, to: destination, approvedRoot: drive, validating: replacementTarget)
        try check(fm.fileExists(atPath: destination.path) && !fm.fileExists(atPath: source.path), "Valid same-directory promotion succeeds")
        try rejects("Writing through an intermediate directory link must fail") {
            let fd = try MachineStorageSafety.openRegularFile(linkedChild.appendingPathComponent("disk.img"), approvedRoot: drive, flags: O_RDWR, validating: replacementTarget)
            close(fd)
        }
        try rejects("Writing through a leaf link must fail") {
            let fd = try MachineStorageSafety.openRegularFile(linkedDiskVM.appendingPathComponent("disk.img"), approvedRoot: drive, flags: O_RDWR | O_TRUNC, validating: replacementTarget)
            close(fd)
        }
        let hardLink = writable.appendingPathComponent("hardlinked.part")
        try fm.linkItem(at: personal.appendingPathComponent("disk.img"), to: hardLink)
        try rejects("A write/truncate must reject hard-linked personal data") {
            let fd = try MachineStorageSafety.openRegularFile(hardLink, approvedRoot: drive, flags: O_WRONLY | O_TRUNC, validating: replacementTarget)
            close(fd)
        }
        try check(try String(contentsOf: personal.appendingPathComponent("disk.img"), encoding: .utf8) == "owned fixture", "Hard-linked personal bytes were not truncated")
        try rejects("A stale target must not open a replacement-drive output") {
            let fd = try MachineStorageSafety.openRegularFile(writable.appendingPathComponent("should-not-exist"), approvedRoot: drive, flags: O_WRONLY | O_CREAT, validating: originalTarget)
            close(fd)
        }
        try check(!fm.fileExists(atPath: writable.appendingPathComponent("should-not-exist").path), "Replacement-drive output was not created")

        let moving = try machine(in: drive, name: UUID().uuidString + ".moving")
        let moved = drive.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try MachineStorageSafety.promoteMachineDirectory(from: moving, to: moved, approvedRoot: drive, validating: replacementTarget)
        try check(fm.fileExists(atPath: moved.appendingPathComponent("disk.img").path), "Machine directory promotion succeeds")
        let collision = try machine(in: drive, name: UUID().uuidString + ".moving")
        try rejects("Machine promotion must not replace another folder") {
            try MachineStorageSafety.promoteMachineDirectory(from: collision, to: moved, approvedRoot: drive, validating: replacementTarget)
        }
        try check(fm.fileExists(atPath: collision.appendingPathComponent("disk.img").path), "Refused promotion preserves the source")

        let exports = drive.appendingPathComponent("export-transactions", isDirectory: true)
        let oldExport = try readyExport(in: exports, name: "Mac", payload: "previous complete backup")
        let newExport = try readyExport(in: exports, name: UUID().uuidString + ".moving", payload: "new complete backup")
        guard let backup = try MachineStorageSafety.commitMachineExport(
            from: newExport, to: oldExport, approvedRoot: drive, matchingECID: 123, validating: replacementTarget
        ) else { throw CheckFailure(description: "Replacing an export must return its backup identity") }
        try check(try String(contentsOf: oldExport.appendingPathComponent("disk.img"), encoding: .utf8) == "new complete backup", "Atomic replacement promotes the new complete export")
        try check(try String(contentsOf: newExport.appendingPathComponent("disk.img"), encoding: .utf8) == "previous complete backup", "Atomic replacement retains the old complete export at staging")
        _ = try MachineStorageSafety.deleteMachineFiles(
            in: newExport, approvedRoot: drive, allowRemovingDirectory: true, validating: replacementTarget, matchingIdentity: backup
        )
        try check(!fm.fileExists(atPath: newExport.path), "A matched old export can be cleaned after successful commit")
        try check(fm.fileExists(atPath: oldExport.appendingPathComponent("installed").path), "Post-commit cleanup leaves the new complete export intact")

        let initialExport = try readyExport(in: exports, name: UUID().uuidString + ".moving", payload: "first backup")
        let initialFinal = exports.appendingPathComponent("First Mac", isDirectory: true)
        let noBackup = try MachineStorageSafety.commitMachineExport(
            from: initialExport, to: initialFinal, approvedRoot: drive, matchingECID: 123, validating: replacementTarget
        )
        try check(noBackup == nil && !fm.fileExists(atPath: initialExport.path), "First export uses exclusive promotion without a backup")
        try check(try String(contentsOf: initialFinal.appendingPathComponent("disk.img"), encoding: .utf8) == "first backup", "First export is complete under its final name")

        let packedExport = try readyExport(in: exports, name: UUID().uuidString + ".moving", payload: "packed disk payload")
        try fm.moveItem(at: packedExport.appendingPathComponent("disk.img"), to: packedExport.appendingPathComponent("disk.img.hvsparse"))
        let packedFinal = exports.appendingPathComponent("Packed Mac", isDirectory: true)
        _ = try MachineStorageSafety.commitMachineExport(
            from: packedExport, to: packedFinal, approvedRoot: drive, matchingECID: 123, validating: replacementTarget
        )
        try check(try String(contentsOf: packedFinal.appendingPathComponent("disk.img.hvsparse"), encoding: .utf8) == "packed disk payload", "The production packed-only export format commits successfully")
        try check(fm.fileExists(atPath: packedFinal.appendingPathComponent("installed").path) && !fm.fileExists(atPath: packedExport.path), "Packed-only promotion keeps its completed marker")

        let retryExport = try readyExport(in: exports, name: UUID().uuidString + ".moving", payload: "retry backup")
        for renameFailure in [ENOSPC, EIO, ENOTSUP] {
            var observedFlags: UInt32 = 0
            do {
                _ = try MachineStorageSafety.commitMachineExport(
                    from: retryExport, to: oldExport, approvedRoot: drive, matchingECID: 123, validating: replacementTarget,
                    renameOperation: { _, _, _, _, flags in
                        observedFlags = flags
                        errno = renameFailure
                        return -1
                    }
                )
                throw CheckFailure(description: "A failed atomic swap must throw")
            } catch let error as NSError {
                try check(error.localizedDescription.contains("既有備份未刪除"), "A failed swap explains that the previous backup remains")
            }
            try check(observedFlags == UInt32(RENAME_SWAP), "Existing exports only use atomic swap")
            try check(try String(contentsOf: oldExport.appendingPathComponent("disk.img"), encoding: .utf8) == "new complete backup", "Swap failure preserves the previous complete final")
            try check(try String(contentsOf: retryExport.appendingPathComponent("disk.img"), encoding: .utf8) == "retry backup", "Swap failure preserves the new complete partial")
        }
        let failedInitial = exports.appendingPathComponent("Failed first export", isDirectory: true)
        var initialFlags: UInt32 = 0
        try rejects("Unsupported exclusive rename must not fall back to overwrite") {
            _ = try MachineStorageSafety.commitMachineExport(
                from: retryExport, to: failedInitial, approvedRoot: drive, matchingECID: 123, validating: replacementTarget,
                renameOperation: { _, _, _, _, flags in
                    initialFlags = flags
                    errno = ENOTSUP
                    return -1
                }
            )
        }
        try check(initialFlags == UInt32(RENAME_EXCL), "First export requires exclusive rename")
        try check(!fm.fileExists(atPath: failedInitial.path) && fm.fileExists(atPath: retryExport.appendingPathComponent("disk.img").path), "Exclusive failure leaves the complete partial untouched")

        let collidingFinal = exports.appendingPathComponent("Concurrent destination", isDirectory: true)
        try rejects("A destination appearing during exclusive rename must not be overwritten") {
            _ = try MachineStorageSafety.commitMachineExport(
                from: retryExport, to: collidingFinal, approvedRoot: drive, matchingECID: 123, validating: replacementTarget,
                renameOperation: { sourceFD, sourceName, destinationFD, destinationName, flags in
                    try? fm.createDirectory(at: collidingFinal, withIntermediateDirectories: true)
                    try? write(collidingFinal.appendingPathComponent("photo.jpg"), "concurrent personal data")
                    return renameatx_np(sourceFD, sourceName, destinationFD, destinationName, flags)
                }
            )
        }
        try check(try String(contentsOf: collidingFinal.appendingPathComponent("photo.jpg"), encoding: .utf8) == "concurrent personal data", "Exclusive collision preserves another folder")
        try check(fm.fileExists(atPath: retryExport.appendingPathComponent("disk.img").path), "Exclusive collision also preserves the new partial")

        try rejects("An export cannot replace itself") {
            _ = try MachineStorageSafety.commitMachineExport(from: oldExport, to: oldExport, approvedRoot: drive, matchingECID: 123)
        }
        let caseAlias = exports.appendingPathComponent("MAC", isDirectory: true)
        if fm.fileExists(atPath: caseAlias.path) {
            try rejects("Case aliases to one inode cannot be swapped and cleaned") {
                _ = try MachineStorageSafety.commitMachineExport(from: oldExport, to: caseAlias, approvedRoot: drive, matchingECID: 123)
            }
        }
        try check(try String(contentsOf: oldExport.appendingPathComponent("disk.img"), encoding: .utf8) == "new complete backup", "Same-inode refusal preserves the only final export")

        let wrongECID = try readyExport(in: exports, name: UUID().uuidString + ".moving", ecid: 456, payload: "another machine")
        try rejects("A mismatched source ECID cannot replace an export") {
            _ = try MachineStorageSafety.commitMachineExport(from: wrongECID, to: oldExport, approvedRoot: drive, matchingECID: 123)
        }
        let otherFinal = try readyExport(in: exports, name: "Another Mac", ecid: 456, payload: "other machine backup")
        try rejects("A mismatched destination ECID cannot be overwritten") {
            _ = try MachineStorageSafety.commitMachineExport(from: retryExport, to: otherFinal, approvedRoot: drive, matchingECID: 123)
        }
        try check(try String(contentsOf: otherFinal.appendingPathComponent("disk.img"), encoding: .utf8) == "other machine backup", "The other machine's backup remains unchanged")

        let incomplete = try readyExport(in: exports, name: UUID().uuidString + ".moving", payload: "incomplete backup")
        try fm.removeItem(at: incomplete.appendingPathComponent("auxiliary.bin"))
        try rejects("Missing core files cannot commit over a complete backup") {
            _ = try MachineStorageSafety.commitMachineExport(from: incomplete, to: oldExport, approvedRoot: drive, matchingECID: 123)
        }
        try write(retryExport.appendingPathComponent(".installing"))
        try rejects("A staging marker prevents committing an unfinished export") {
            _ = try MachineStorageSafety.commitMachineExport(from: retryExport, to: oldExport, approvedRoot: drive, matchingECID: 123)
        }
        try fm.removeItem(at: retryExport.appendingPathComponent(".installing"))
        try write(retryExport.appendingPathComponent("photo.jpg"), "personal source data")
        try rejects("Unknown source files are never promoted for later deletion") {
            _ = try MachineStorageSafety.commitMachineExport(from: retryExport, to: oldExport, approvedRoot: drive, matchingECID: 123)
        }
        try check(fm.fileExists(atPath: retryExport.appendingPathComponent("photo.jpg").path), "Refused source preserves unknown data")
        try fm.removeItem(at: retryExport.appendingPathComponent("photo.jpg"))
        try write(oldExport.appendingPathComponent("photo.jpg"), "personal final data")
        try rejects("Unknown destination files prevent export replacement") {
            _ = try MachineStorageSafety.commitMachineExport(from: retryExport, to: oldExport, approvedRoot: drive, matchingECID: 123)
        }
        try check(try String(contentsOf: oldExport.appendingPathComponent("photo.jpg"), encoding: .utf8) == "personal final data", "Refused replacement preserves unknown destination data")
        try fm.removeItem(at: oldExport.appendingPathComponent("photo.jpg"))

        let linkedExport = exports.appendingPathComponent("Linked destination", isDirectory: true)
        try fm.createSymbolicLink(at: linkedExport, withDestinationURL: personal)
        try rejects("A destination symlink must not replace its target") {
            _ = try MachineStorageSafety.commitMachineExport(from: retryExport, to: linkedExport, approvedRoot: drive, matchingECID: 123)
        }
        let linkedExportParent = drive.appendingPathComponent("linked-export-parent", isDirectory: true)
        try fm.createSymbolicLink(at: linkedExportParent, withDestinationURL: exports)
        try rejects("An intermediate symlink cannot authorize an export transaction") {
            _ = try MachineStorageSafety.commitMachineExport(
                from: linkedExportParent.appendingPathComponent(retryExport.lastPathComponent),
                to: linkedExportParent.appendingPathComponent(oldExport.lastPathComponent),
                approvedRoot: drive, matchingECID: 123
            )
        }
        try rejects("A stale drive target cannot commit onto a replacement SSD") {
            _ = try MachineStorageSafety.commitMachineExport(
                from: retryExport, to: oldExport, approvedRoot: drive, matchingECID: 123, validating: originalTarget
            )
        }
        try check(try String(contentsOf: personal.appendingPathComponent("disk.img"), encoding: .utf8) == "owned fixture", "Export symlink failures preserve personal bytes")
        try check(try String(contentsOf: oldExport.appendingPathComponent("disk.img"), encoding: .utf8) == "new complete backup", "All failed preflights preserve the complete final backup")

        guard let retainedIdentity = try MachineStorageSafety.commitMachineExport(
            from: retryExport, to: oldExport, approvedRoot: drive, matchingECID: 123, validating: replacementTarget
        ) else { throw CheckFailure(description: "Second replacement must retain a backup identity") }
        try write(retryExport.appendingPathComponent("photo.jpg"), "added after commit")
        try rejects("Unknown files appearing after commit retain the entire previous backup") {
            _ = try MachineStorageSafety.deleteMachineFiles(
                in: retryExport, approvedRoot: drive, allowRemovingDirectory: true, matchingIdentity: retainedIdentity
            )
        }
        try check(try String(contentsOf: retryExport.appendingPathComponent("disk.img"), encoding: .utf8) == "new complete backup", "A failed cleanup leaves the previous complete disk")
        try check(try String(contentsOf: retryExport.appendingPathComponent("photo.jpg"), encoding: .utf8) == "added after commit", "A failed cleanup leaves added personal data")
        let retainedBackup = exports.appendingPathComponent("retained previous export", isDirectory: true)
        try fm.moveItem(at: retryExport, to: retainedBackup)
        let replacementBackupPath = try readyExport(in: exports, name: retryExport.lastPathComponent, payload: "replacement personal disk")
        try rejects("Backup cleanup must match the original directory inode") {
            _ = try MachineStorageSafety.deleteMachineFiles(
                in: replacementBackupPath, approvedRoot: drive, allowRemovingDirectory: true, matchingIdentity: retainedIdentity
            )
        }
        try check(try String(contentsOf: replacementBackupPath.appendingPathComponent("disk.img"), encoding: .utf8) == "replacement personal disk", "An inode-changed backup path is not cleaned")
        try check(try String(contentsOf: retainedBackup.appendingPathComponent("disk.img"), encoding: .utf8) == "new complete backup", "The original moved backup remains complete")
        try check(try String(contentsOf: oldExport.appendingPathComponent("disk.img"), encoding: .utf8) == "retry backup", "Cleanup failures do not undo or damage the committed new export")

        let racingSource = try readyExport(in: exports, name: UUID().uuidString + ".moving", payload: "verified source")
        let displacedSource = exports.appendingPathComponent("displaced verified source", isDirectory: true)
        try rejects("A source inode changed during rename must stop post-commit cleanup") {
            _ = try MachineStorageSafety.commitMachineExport(
                from: racingSource, to: oldExport, approvedRoot: drive, matchingECID: 123,
                renameOperation: { sourceFD, sourceName, destinationFD, destinationName, flags in
                    try? fm.moveItem(at: racingSource, to: displacedSource)
                    _ = try? readyExport(in: exports, name: racingSource.lastPathComponent, payload: "concurrently replaced source")
                    return renameatx_np(sourceFD, sourceName, destinationFD, destinationName, flags)
                }
            )
        }
        try check(try String(contentsOf: racingSource.appendingPathComponent("disk.img"), encoding: .utf8) == "retry backup", "A post-rename mismatch retains the previous complete backup")
        try check(try String(contentsOf: displacedSource.appendingPathComponent("disk.img"), encoding: .utf8) == "verified source", "A post-rename mismatch retains the verified new source")
        try check(try String(contentsOf: oldExport.appendingPathComponent("disk.img"), encoding: .utf8) == "concurrently replaced source", "A post-rename mismatch does not delete concurrently introduced data")

        for path in ["", ".", "HengeMachines/\(UUID().uuidString)", "Mac Name/child"] {
            try check(MachineStorageSafety.validRelativePath(path), "Valid relative path: \(path)")
        }
        for path in ["/", "/Personal", "../Personal", "./Personal", "HengeMachines/../Personal", "a//b", "a/"] {
            try check(!MachineStorageSafety.validRelativePath(path), "Invalid relative path: \(path)")
        }
        let fallback = UUID()
        for name in ["", ".", ".."] {
            try check(MachineStorageSafety.exportFolderName(name, fallbackID: fallback) == fallback.uuidString, "Unsafe export name uses a UUID")
        }
        try check(MachineStorageSafety.exportFolderName("Mac/Work", fallbackID: fallback) == "Mac-Work", "Export names are single path components")
        print("Machine storage safety: \(checks) checks passed")
    }
}
