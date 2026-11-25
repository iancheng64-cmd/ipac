import SwiftUI

@MainActor
final class GuestMemoryMonitor: ObservableObject {
    static let shared = GuestMemoryMonitor()

    enum Pressure {
        case unknown, normal, warning, critical

        var text: String {
            switch self {
            case .unknown: return L10n.text("尚未回報")
            case .normal: return L10n.text("正常")
            case .warning: return L10n.text("偏高")
            case .critical: return L10n.text("嚴重")
            }
        }
    }

    @Published private(set) var availableAppRAMMB = 0
    @Published private(set) var pressure = Pressure.unknown
    private let source: DispatchSourceMemoryPressure

    private init() {
        source = DispatchSource.makeMemoryPressureSource(eventMask: [.normal, .warning, .critical], queue: .main)
        source.setEventHandler { [weak self] in
            guard let self else { return }
            let event = self.source.data
            self.pressure = event.contains(.critical) ? .critical : event.contains(.warning) ? .warning : .normal
            self.refresh()
        }
        source.resume()
        refresh()
    }

    func refresh() {
        availableAppRAMMB = Int(henge_available_memory() >> 20)
    }
}

/// Unframed rows reused by configuration and session diagnostics.
struct MemoryStatusView: View {
    @Environment(\.locale) private var interfaceLocale
    let ramMB: Int
    @ObservedObject private var monitor = GuestMemoryMonitor.shared

    var body: some View {
        let _ = interfaceLocale
        VStack(alignment: .leading, spacing: 8) {
            LabeledContent(L10n.text("偵測到的實體 RAM"), value: "\(GuestRAMBudget.text(Device.memoryBudget.physicalRAMMB))（\(Device.memoryBudget.physicalRAMMB) MB）")
            LabeledContent(L10n.text("本次 JIT 快取"), value: GuestRAMBudget.text(Device.memoryBudget.jitCacheMB))
            LabeledContent(L10n.text("目前 App 配額餘量"), value: GuestRAMBudget.text(monitor.availableAppRAMMB))
            LabeledContent(L10n.text("系統記憶體壓力"), value: monitor.pressure.text)
                .foregroundStyle(monitor.pressure == .warning || monitor.pressure == .critical ? Desk.bad : Desk.dim)
            if let notice = Device.memoryBudget.notice(for: ramMB) {
                Label(L10n.text(notice.text), systemImage: notice.isHighRisk ? "exclamationmark.triangle.fill" : "info.circle")
                    .foregroundStyle(notice.isHighRisk ? Desk.bad : Desk.warn)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Text(L10n.text("App 配額餘量不是全機空閒 RAM。大記憶體權限與 No Footprint 不會增加實體記憶體；配置只警示，不強制預留。"))
                .foregroundStyle(Desk.dim)
                .fixedSize(horizontal: false, vertical: true)
        }
        .font(.system(size: 13))
        .task {
            while !Task.isCancelled {
                monitor.refresh()
                do { try await Task.sleep(nanoseconds: 2_000_000_000) }
                catch { break }
            }
        }
    }
}
