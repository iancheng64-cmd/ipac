import Foundation

/// Memory advice only. Valid configurations are never capped by the host's RAM.
struct GuestRAMBudget {
    static let portableRAMRange = 1024...16384
    static let stepMB = 512

    struct Notice: Equatable {
        let text: String
        let isHighRisk: Bool
    }

    let physicalRAMMB: Int
    let jitCacheMB: Int

    init(physicalMemoryBytes: UInt64, jitCacheMB: Int) {
        physicalRAMMB = Int(physicalMemoryBytes >> 20)
        self.jitCacheMB = max(0, min(jitCacheMB, Self.portableRAMRange.upperBound))
    }

    static func isValidPortableRAMMB(_ ramMB: Int) -> Bool {
        portableRAMRange.contains(ramMB)
    }

    var allPhysicalRAMMB: Int {
        min(max(Self.portableRAMRange.lowerBound, physicalRAMMB), Self.portableRAMRange.upperBound)
    }

    var estimatedJITFootprintMB: Int {
        jitCacheMB + jitCacheMB * 3 / 4
    }

    func notice(for ramMB: Int) -> Notice? {
        guard Self.isValidPortableRAMMB(ramMB) else {
            return Notice(text: L10n.text("記憶體設定無效；目前可設定 1–16 GB。"), isHighRisk: true)
        }
        if ramMB >= physicalRAMMB {
            return Notice(
                text: L10n.text("已配置全部或超過實體 RAM。iPadOS、iPac 與 GPU 仍需記憶體，可能導致系統記憶體不足、App 被終止或未儲存資料遺失；此設定仍可啟動。"),
                isHighRisk: true
            )
        }
        let remaining = physicalRAMMB - ramMB
        // This threshold informs the warning, not allocation or boot eligibility.
        if remaining < max(2048, physicalRAMMB / 4) + estimatedJITFootprintMB + 512 {
            return Notice(
                text: L10n.format("剩餘實體 RAM 約 %@，仍須負擔 iPadOS、JIT、iPac 與 GPU。高負載可能耗盡記憶體；此設定仍可啟動。", String(describing: Self.text(remaining))),
                isHighRisk: true
            )
        }
        if ramMB < 4096 {
            return Notice(text: L10n.text("macOS 配置低於 4 GB，較容易使用交換空間，效能可能降低。"), isHighRisk: false)
        }
        return nil
    }

    static func text(_ ramMB: Int) -> String {
        if ramMB < 1024 { return "\(max(0, ramMB)) MB" }
        if ramMB % 1024 == 0 { return "\(ramMB / 1024) GB" }
        if ramMB % 512 == 0 { return String(format: "%.1f GB", Double(ramMB) / 1024) }
        return String(format: "%.2f GB", Double(ramMB) / 1024)
    }
}
