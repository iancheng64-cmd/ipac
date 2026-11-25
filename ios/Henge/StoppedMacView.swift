import SwiftUI

/// Terminal state after the engine has released the previous guest.
struct StoppedMacView: View {
    @Environment(\.locale) private var interfaceLocale
    let outcome: Int32
    let reason: String
    var start: (() -> Void)? = nil
    let close: () -> Void

    private var title: String {
        switch outcome {
        case Int32(HENGE_VM_OUTCOME_SHUTDOWN.rawValue): return L10n.text("Mac 已關機")
        case Int32(HENGE_VM_OUTCOME_RESTART.rawValue): return L10n.text("Mac 要求重新開機")
        case Int32(HENGE_VM_OUTCOME_HOST_STOP.rawValue): return L10n.text("Mac 已停止")
        default: return L10n.text("Mac 意外停止")
        }
    }

    private var detail: String {
        let next = L10n.text("您可以重新啟動這台 Mac 或返回首頁。")
        switch outcome {
        case Int32(HENGE_VM_OUTCOME_SHUTDOWN.rawValue), Int32(HENGE_VM_OUTCOME_HOST_STOP.rawValue): return next
        case Int32(HENGE_VM_OUTCOME_RESTART.rawValue): return L10n.text("這台 Mac 已準備好重新開機。")
        default: return L10n.format("Mac 已停止：%@。", String(describing: reason)) + next
        }
    }

    var body: some View {
        let _ = interfaceLocale
        VStack(spacing: 14) {
            Image(systemName: "power").font(.system(size: 30))
            Text(L10n.text(title)).font(.headline)
            Text(L10n.text(detail)).font(.subheadline).foregroundStyle(.white.opacity(0.7))
                .multilineTextAlignment(.center)
            if let start { Button(L10n.text("啟動 Mac"), action: start).buttonStyle(.borderedProminent) }
            Button(L10n.text("關閉"), action: close).buttonStyle(.bordered)
        }
        .foregroundStyle(.white)
        .padding(24)
        .frame(maxWidth: 360)
        .background(Color(white: 0.10), in: RoundedRectangle(cornerRadius: 22))
        .accessibilityIdentifier("stopped-mac")
    }
}
