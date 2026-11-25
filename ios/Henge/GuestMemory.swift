import Darwin
import Foundation

enum GuestMemory {
    static var lastFailure: String?

    static func prepare(_ mac: VirtualMac, requestedRAMMB: Int? = nil) -> UInt64 {
        lastFailure = nil
        let rawTarget = requestedRAMMB ?? mac.effectiveRAMMB
        guard GuestRAMBudget.isValidPortableRAMMB(rawTarget),
              let targetMB = UInt64(exactly: rawTarget) else {
            lastFailure = "記憶體設定必須介於 1024 至 16384 MB，請調整設定後再開機。"
            HengeLog.log("session", "invalid guest RAM \(rawTarget) MB: not starting")
            return 0
        }
        henge_ios_release_high_hold()
        try? FileManager.default.createDirectory(at: Machines.root, withIntermediateDirectories: true)
        let file = Machines.root.appendingPathComponent("ram.tmp")
        setenv("HV_RAM_FILE", file.path, 1)
        let noFootprint = henge_vm_can_no_footprint() != 0
        let free = ExternalInstallStorage.volumeFreeBytes(at: Machines.root)
        let room: UInt64 = noFootprint
            ? UInt64.max
            : (free > 0 ? UInt64(max(free - (2 << 30), 0)) >> 20 : UInt64.max)
        let reach = henge_largest_mapping_mb()
        let headroom = reach > 512 ? reach - 512 : reach
        guard targetMB <= room else {
            lastFailure = "本機剩餘空間不足以建立 \(targetMB) MB 的記憶體備援檔，請釋放空間或調整記憶體設定。"
            HengeLog.log("session", "guest RAM \(targetMB) MB exceeds memory backing file room \(room) MB: not starting")
            return 0
        }
        guard targetMB <= headroom else {
            lastFailure = "目前無法建立 \(targetMB) MB 的連續記憶體映射，請調整記憶體設定或重新啟動 App。"
            HengeLog.log("session", "guest RAM \(targetMB) MB exceeds mapping room \(headroom) MB: not starting")
            return 0
        }
        let roomNote = noFootprint ? "no-footprint" : "\(room) MB"
        HengeLog.log("session", "guest RAM \(targetMB) MB (physical \(Device.physicalMemoryGB) GB, noFootprint \(noFootprint), autoAdapt \(mac.adaptsToHost), internal room \(roomNote), largest mapping \(reach))")
        return targetMB
    }
}
