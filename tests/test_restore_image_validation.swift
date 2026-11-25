import Foundation

@_cdecl("hv_ipsw_validate")
func testNativeIPSWValidation(_ path: UnsafePointer<CChar>?, _ build: UnsafePointer<CChar>?) -> Int32 { -1 }

@main
struct RestoreImageValidationTests {
    static func main() throws {
        let fm = FileManager.default
        let root = fm.temporaryDirectory.appendingPathComponent("henge-image-cache-\(UUID().uuidString)", isDirectory: true)
        try fm.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: root) }
        var checks = 0
        func check(_ condition: Bool, _ label: String) {
            checks += 1
            precondition(condition, label)
        }
        let managed = root.appendingPathComponent("managed/Restore images", isDirectory: true)
        let personal = root.appendingPathComponent("personal/Restore images", isDirectory: true)
        try fm.createDirectory(at: managed, withIntermediateDirectories: true)
        try fm.createDirectory(at: personal, withIntermediateDirectories: true)
        let image = managed.appendingPathComponent("24G90.ipsw")
        let userImage = personal.appendingPathComponent("24G90.ipsw")
        var data = Data([0x50, 0x4b, 0x03, 0x04])
        data.append(Data(repeating: 0x11, count: 60))
        try data.write(to: image)
        try data.write(to: userImage)
        var calls = 0
        let validation = RestoreImageValidation { _, _ in calls += 1; return true }
        check(validation.validatedSize(of: image, expectedBuild: "24G90") == 64, "validated size")
        check(validation.validatedSize(of: image, expectedBuild: "24G90") == 64 && calls == 1, "unchanged image cached")
        check(validation.validatedSize(of: image, expectedBuild: "23G93") == 64 && calls == 2, "build is part of cache key")
        let modified = Date(timeIntervalSince1970: 1_000_000)
        try fm.setAttributes([.modificationDate: modified], ofItemAtPath: image.path)
        check(validation.validatedSize(of: image, expectedBuild: "24G90") == 64 && calls == 3, "mtime invalidates cache")
        data.append(0x12)
        try data.write(to: image)
        check(validation.validatedSize(of: image, expectedBuild: "24G90") == 65 && calls == 4, "size invalidates cache")
        let oldDate = (try fm.attributesOfItem(atPath: image.path)[.modificationDate]) as! Date
        try data.write(to: image, options: .atomic)
        try fm.setAttributes([.modificationDate: oldDate], ofItemAtPath: image.path)
        check(validation.validatedSize(of: image, expectedBuild: "24G90") == 65 && calls == 5, "replacement inode invalidates cache")
        check(validation.validatedSize(of: root.appendingPathComponent("missing")) == nil, "missing image rejected")
        check(validation.validatedSize(of: managed) == nil, "directory rejected")
        let text = managed.appendingPathComponent("invalid.ipsw")
        try Data(repeating: 0x11, count: 64).write(to: text)
        check(validation.validatedSize(of: text) == nil && calls == 5, "non-ZIP rejected before native parser")
        let link = managed.appendingPathComponent("linked.ipsw")
        try fm.createSymbolicLink(at: link, withDestinationURL: userImage)
        check(validation.validatedSize(of: link) == nil, "leaf symlink rejected")
        check(RestoreImageValidation.isManagedFile(image, in: managed), "actual managed directory owns image")
        check(!RestoreImageValidation.isManagedFile(userImage, in: managed), "same parent basename does not grant ownership")
        check(!RestoreImageValidation.isManagedFile(link, in: managed), "managed leaf symlink rejected")
        check(fm.fileExists(atPath: userImage.path), "personal source preserved")
        check(RestoreImageValidation.canCleanRestoreWork(step: 100, vmState: 0, canStart: false), "finished restore with idle VM can clean")
        check(RestoreImageValidation.canCleanRestoreWork(step: 100, vmState: 2, canStart: false), "finished restore with stopped VM can clean")
        check(RestoreImageValidation.canCleanRestoreWork(step: 101, vmState: 0, canStart: false), "failed restore with idle VM can clean")
        check(RestoreImageValidation.canCleanRestoreWork(step: 101, vmState: 2, canStart: false), "failed restore with stopped VM can clean")
        check(!RestoreImageValidation.canCleanRestoreWork(step: 100, vmState: 3, canStart: false), "finished restore while stopping retains work")
        check(!RestoreImageValidation.canCleanRestoreWork(step: 100, vmState: 4, canStart: false), "finished restore while starting retains work")
        check(!RestoreImageValidation.canCleanRestoreWork(step: 101, vmState: 1, canStart: false), "failed restore while running retains work")
        check(!RestoreImageValidation.canCleanRestoreWork(step: 4, vmState: 2, canStart: false), "attached nonterminal restore with stopped VM retains work")
        check(!RestoreImageValidation.canCleanRestoreWork(step: 0, vmState: 0, canStart: false), "attached nonterminal restore with idle VM retains work")
        check(RestoreImageValidation.canCleanRestoreWork(step: 0, vmState: 0, canStart: true), "no native installer permits cleaning owned preparation")
        check(RestoreImageValidation.canCleanRestoreWork(step: 4, vmState: 2, canStart: true), "detached native installer permits cleaning retained work")
        check(!RestoreImageValidation.canCleanRestoreWork(step: 0, vmState: 3, canStart: true), "transitioning VM always retains work")
        print("Restore image cache/ownership: \(checks) checks, 0 failures")
    }
}
