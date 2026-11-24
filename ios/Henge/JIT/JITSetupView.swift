// SPDX-License-Identifier: GPL-2.0-or-later
import SwiftUI
import UniformTypeIdentifiers

/// The JIT walkthrough: pick a way in, follow its numbered steps, end with JIT on.
///
/// Three ways in. Pairing on this iPhone (iOS 27) and a pairing file made on a
/// computer both lead to Built-in StikJIT and share the last two steps,
/// LocalDevVPN and enabling. StikDebug has its own short page. Presented from
/// onboarding, Settings › JIT, and whenever Start finds JIT not set up.
struct JITSetupFlow: View {
    enum Step: Hashable { case pairOnDevice, importFile, connect, enable, stikDebug, trollStore, jailbreak }

    @ObservedObject private var jit = JITCoordinator.shared
    @ObservedObject private var pairing = OnDevicePairing.shared
    @State private var path: [Step] = []
    @State private var importing = false
    @Environment(\.dismiss) private var dismiss

    private var device: String { OnDevicePairing.deviceKind }

    var body: some View {
        NavigationStack(path: $path) {
            choose
                .hengeDestination(for: Step.self) { step in
                    switch step {
                    case .pairOnDevice: pairOnDevice
                    case .importFile: importFile
                    case .connect: connect
                    case .enable: enable
                    case .stikDebug: stikDebug
                    case .trollStore: trollStore
                    case .jailbreak: jailbreak
                    }
                }
        }
        .tint(Theme.accent)
        .fileImporter(isPresented: $importing, allowedContentTypes: [.propertyList, .data]) { result in
            switch result {
            case .success(let url): jit.importPairingFile(url)
            case .failure(let failure):
                HengeLog.log("jit", "pairing import failed: \(failure.localizedDescription)")
            }
        }
        .onAppear {
            jit.refreshPairingStatus()
            pairing.reset()
            // A failed enable from the Library lands on the step that can fix it.
            if jit.error != nil, jit.hasPairing, jit.resolvedMethod == .builtIn {
                path = [.enable]
            }
            HengeLog.log("ui", "JIT walkthrough opened")
        }
        // Swiping the sheet away, or a copy shown from onboarding, must not
        // leave a request to show it again behind.
        .onDisappear { jit.showSetup = false }
    }

    private func close() {
        jit.showSetup = false
        dismiss()
    }

    // MARK: Choose

    private var choose: some View {
        page(symbol: "bolt.fill", title: "開啟 JIT 加速",
             subtitle: "macOS 需要動態執行程式碼的記憶體權限，在 iOS 上必須透過附加除錯器取得。請選擇這台 \(device) 啟用 JIT 的方式。") {
            VStack(spacing: 10) {
                let builtIn = HengeBuiltInJIT.unavailableReason
                way("在此 \(device) 上直接配對", symbol: "iphone.radiowaves.left.and.right",
                    detail: builtIn ?? (!OnDevicePairing.isSupported ? "需要 iOS / iPadOS 27 或更新版本。"
                        : jit.pairingSource == .onDevice ? "已在此 \(device) 完成配對。"
                        : "免用電腦，約 1 分鐘從「設定」完成本機配對。"),
                    done: jit.pairingSource == .onDevice,
                    enabled: builtIn == nil && OnDevicePairing.isSupported) { path.append(.pairOnDevice) }
                way("使用配對檔案（RPPairing）", symbol: "doc.badge.plus",
                    detail: builtIn ?? (jit.pairingSource == .imported ? "已匯入配對檔案。"
                        : "匯入在電腦上產生的裝置配對檔案。"),
                    done: jit.pairingSource == .imported,
                    enabled: builtIn == nil) { path.append(.importFile) }
                way("使用 StikDebug", symbol: "ant",
                    detail: JITBootstrap.isStikDebugInstalled ? "已安裝 StikDebug。"
                        : "透過 StikDebug App 啟用 JIT。",
                    done: jit.method == .stikDebug) { path.append(.stikDebug) }
                way("使用 TrollStore", symbol: "sparkles",
                    detail: JITBootstrap.isTrollStoreInstalled ? "已安裝 TrollStore。"
                        : "適用於透過 TrollStore 安裝 Henge 的裝置。",
                    done: jit.method == .trollStore) { path.append(.trollStore) }
                way("使用越獄（Dopamine）", symbol: "lock.open",
                    detail: JITBootstrap.debuggedAtLaunch ? "開啟 Henge 時即已具備 JIT 權限。"
                        : JITBootstrap.isJailbroken ? "偵測到越獄環境，請於設定開啟「Allow JIT in Apps」。"
                        : "Dopamine 越獄可在單一設定中替所有 App 啟用 JIT。",
                    done: jit.method == .jailbreak || JITBootstrap.debuggedAtLaunch) { path.append(.jailbreak) }
            }
            if jit.hasPairing && HengeBuiltInJIT.isAvailable {
                Button { path.append(.connect) } label: {
                    Label("使用目前配對繼續下一步", systemImage: "arrow.right")
                        .font(.system(size: 14, weight: .semibold))
                }
                .padding(.top, 4)
            }
        } actions: {
            Button("稍後再說") { close() }
                .font(.system(size: 15, weight: .medium))
                .foregroundStyle(Theme.textDim)
        }
    }

    private func way(_ title: String, symbol: String, detail: String, done: Bool,
                     enabled: Bool = true, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 14) {
                Image(systemName: symbol)
                    .font(.system(size: 17, weight: .semibold))
                    .foregroundStyle(Theme.accent)
                    .frame(width: 34, height: 34)
                    .background(Theme.accentSoft, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                VStack(alignment: .leading, spacing: 3) {
                    Text(title).font(.system(size: 16, weight: .semibold)).foregroundStyle(Theme.text)
                    Text(detail).font(.system(size: 13)).foregroundStyle(Theme.textDim)
                        .fixedSize(horizontal: false, vertical: true)
                        .multilineTextAlignment(.leading)
                }
                Spacer(minLength: 8)
                Image(systemName: done ? "checkmark.circle.fill" : "chevron.right")
                    .font(.system(size: done ? 18 : 13, weight: .semibold))
                    .foregroundStyle(done ? .green : Theme.textDim.opacity(0.7))
            }
            .padding(14)
            .contentShape(Rectangle())
            .hengeCard()
        }
        .buttonStyle(CardButtonStyle())
        .disabled(!enabled)
        .opacity(enabled ? 1 : 0.5)
    }

    // MARK: Pair on this device

    private var pairedOnDevice: Bool {
        if case .paired = pairing.phase { return true }
        return false
    }

    private var pairOnDevice: some View {
        page(symbol: "iphone.radiowaves.left.and.right", title: "在 \(device) 本機配對",
             subtitle: "Henge 會模擬區網內的電腦，讓你的 \(device) 像連接 Mac 一樣完成裝置配對。") {
            VStack(alignment: .leading, spacing: 14) {
                point(1, "開啟 Wi-Fi，點選下方「**開始配對**」並允許區域網路權限。",
                      done: pairing.phase != .idle)
                point(2, "前往「**設定 › 隱私權與安全性 › 開發者模式**」，滑到最下方點選「**與 \(OnDevicePairing.hostName) 配對**」。",
                      done: pairing.isShowingPin || pairedOnDevice)
                point(3, "輸入 Henge 顯示的配對碼（亦會透過通知橫幅顯示，免切換 App）。",
                      done: pairedOnDevice)
                point(4, "返回 Henge。", done: pairedOnDevice)
            }
            .padding(16).hengeCard()
            pairingStatus
        } actions: {
            switch pairing.phase {
            case .idle, .failed:
                Button { pairing.start() } label: {
                    Label("開始配對", systemImage: "dot.radiowaves.left.and.right")
                }
                .buttonStyle(PrimaryButtonStyle())
            case .waiting, .pin:
                Button("取消配對", role: .cancel) { pairing.cancel() }
                    .font(.system(size: 15, weight: .medium))
                    .foregroundStyle(Theme.textDim)
            case .paired:
                Button("繼續") { path.append(.connect) }
                    .buttonStyle(PrimaryButtonStyle())
            }
        }
    }

    @ViewBuilder private var pairingStatus: some View {
        switch pairing.phase {
        case .idle:
            EmptyView()
        case .waiting:
            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 10) {
                    ProgressView().tint(Theme.accent)
                    Text("正在等待 \(device) 回應…").font(.system(size: 15, weight: .semibold))
                        .foregroundStyle(Theme.text)
                }
                Button("開啟「設定」") {
                    if let url = URL(string: UIApplication.openSettingsURLString) { UIApplication.shared.open(url) }
                }
                .font(.system(size: 14, weight: .semibold))
                if pairing.backgroundLimited {
                    Text("目前安裝方式在背景僅能等待約 30 秒，請立即切換至「設定」配對。")
                        .font(.system(size: 13)).foregroundStyle(.orange)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(16).hengeCard()
        case .pin(let pin):
            VStack(spacing: 8) {
                Text("請於 \(device) 輸入這組配對碼").font(.system(size: 14))
                    .foregroundStyle(Theme.textDim)
                Text(pin).font(.system(size: 40, weight: .bold, design: .monospaced)).tracking(6)
                    .foregroundStyle(Theme.text)
                    .textSelection(.enabled)
                    .accessibilityLabel("配對碼 \(pin.map(String.init).joined(separator: " "))")
            }
            .frame(maxWidth: .infinity)
            .padding(18).hengeCard(high: true)
        case .paired(let name):
            outcome("已與「\(name)」完成配對", ok: true)
        case .failed(let message):
            outcome(message, ok: false)
        }
    }

    // MARK: Import a pairing file

    private var importFile: some View {
        page(symbol: "doc.badge.plus", title: "匯入配對檔案",
             subtitle: "在電腦產生這台 \(device) 的配對檔後匯入，Henge 即可與此裝置連線。") {
            VStack(alignment: .leading, spacing: 14) {
                point(1, "在電腦依照 [StikDebug 配對檔教學](https://github.com/StikDebug/StikDebug-Guide/blob/main/pairing_file.md) 製作這台 \(device) 的配對檔。",
                      done: jit.pairingSource == .imported)
                point(2, "儲存到「檔案」或透過 AirDrop 傳到此 \(device)。",
                      done: jit.pairingSource == .imported)
                point(3, "點選「**選擇配對檔案**」並挑選該檔案。", done: jit.pairingSource == .imported)
            }
            .padding(16).hengeCard()
            Label("配對檔案只會存放在 Henge 的 Documents 資料夾並僅供內建 JIT 輔助程序使用。",
                  systemImage: "lock.fill")
                .font(.system(size: 13)).foregroundStyle(Theme.textDim)
            if let error = jit.error { outcome(error, ok: false) }
        } actions: {
            if jit.pairingSource == .imported {
                Button("繼續") { path.append(.connect) }.buttonStyle(PrimaryButtonStyle())
                Button("選擇其他檔案") { importing = true }
                    .font(.system(size: 15, weight: .medium))
            } else {
                Button { importing = true } label: { Label("選擇配對檔案", systemImage: "folder") }
                    .buttonStyle(PrimaryButtonStyle())
            }
        }
    }

    // MARK: LocalDevVPN

    private var connect: some View {
        page(symbol: "network.badge.shield.half.filled", title: "連接 LocalDevVPN",
             subtitle: "Henge 需透過本機迴路 VPN 連線到此 \(device) 的除錯服務（全程不離開本機裝置）。") {
            VStack(alignment: .leading, spacing: 14) {
                point(1, "從 App Store 安裝 [LocalDevVPN](\(LocalDevVPN.appStore.absoluteString))。",
                      done: LocalDevVPN.isInstalled)
                point(2, "點選「**連接 LocalDevVPN**」，開啟 VPN 後會自動返回 Henge。")
                point(3, "開啟 JIT 前請維持 LocalDevVPN 在連線狀態。")
            }
            .padding(16).hengeCard()
        } actions: {
            Button(LocalDevVPN.actionTitle) { LocalDevVPN.open() }
                .buttonStyle(PrimaryButtonStyle())
            Button("已連線，繼續") { path.append(.enable) }
                .font(.system(size: 15, weight: .medium))
        }
    }

    // MARK: Enable

    private var attached: Bool { jit.attachGeneration > 0 || JITBootstrap.debuggedFlag }

    private var enable: some View {
        page(symbol: "bolt.badge.checkmark", title: "啟用 JIT",
             subtitle: "首次檢查會下載並掛載 Apple 開發者磁碟映像（Developer Disk Image），可能需要約 1 分鐘。") {
            VStack(alignment: .leading, spacing: 14) {
                point(1, "點選「**檢查環境**」，確認 LocalDevVPN 與開發者磁碟映像就緒。",
                      done: jit.prepared || attached)
                point(2, "點選「**啟用 JIT**」，待輔助程序附加後即可啟動 Mac。", done: attached)
            }
            .padding(16).hengeCard()

            if jit.busy {
                HStack(spacing: 11) {
                    ProgressView().tint(Theme.accent)
                    Text(jit.status ?? "處理中…").font(.system(size: 14)).foregroundStyle(Theme.text)
                    Spacer(minLength: 0)
                }
                .padding(16).hengeCard(high: true)
            } else if attached {
                outcome("JIT 已開啟，現在可以啟動 Mac。", ok: true)
            } else if let error = jit.error {
                VStack(alignment: .leading, spacing: 10) {
                    outcome(error, ok: false)
                    if jit.advice?.actions.contains(.pairAgain) == true {
                        Button(OnDevicePairing.isSupported ? "重新配對" : "重新匯入配對檔案") {
                            path = [OnDevicePairing.isSupported ? .pairOnDevice : .importFile]
                        }
                        .font(.system(size: 14, weight: .semibold))
                    }
                    if jit.advice?.actions.contains(.connectLocalDevVPN) == true {
                        Button(LocalDevVPN.actionTitle) { LocalDevVPN.open() }
                            .font(.system(size: 14, weight: .semibold))
                    }
                }
            } else if let status = jit.status {
                outcome(status, ok: true)
            }

            if !attached {
                Button("重設開發者磁碟映像（DDI）", role: .destructive) { jit.resetDDI() }
                    .font(.system(size: 13, weight: .medium))
                    .disabled(jit.busy)
                    .padding(.top, 4)
            }
        } actions: {
            if attached {
                Button("完成") { close() }.buttonStyle(PrimaryButtonStyle())
            } else if jit.prepared {
                Button { jit.enableBuiltIn() } label: { Label("啟用 JIT", systemImage: "bolt.fill") }
                    .buttonStyle(PrimaryButtonStyle(enabled: !jit.busy))
                    .disabled(jit.busy)
            } else {
                Button("檢查環境") { jit.prepareBuiltIn() }
                    .buttonStyle(PrimaryButtonStyle(enabled: !jit.busy))
                    .disabled(jit.busy)
            }
        }
    }

    // MARK: StikDebug

    private var stikDebug: some View {
        page(symbol: "ant", title: "使用 StikDebug",
             subtitle: "StikDebug 可作為外部除錯器為 Henge 啟用 JIT，Henge 會自動傳入所需的指令碼。") {
            VStack(alignment: .leading, spacing: 14) {
                point(1, "安裝 [StikDebug](https://github.com/StikDebug/StikDebug/releases/latest)。",
                      done: JITBootstrap.isStikDebugInstalled)
                point(2, "將這台 \(device) 的配對檔案匯入 StikDebug。")
                point(3, "安裝並連接 [LocalDevVPN](\(LocalDevVPN.appStore.absoluteString))。")
                point(4, "每次啟動 Mac 時，Henge 會跳轉至 StikDebug 附加後自動返回。")
            }
            .padding(16).hengeCard()
        } actions: {
            Button("使用 StikDebug") {
                jit.method = .stikDebug
                HengeLog.log("ui", "JIT method set to StikDebug")
                close()
            }
            .buttonStyle(PrimaryButtonStyle())
        }
    }

    // MARK: TrollStore

    private var trollStore: some View {
        page(symbol: "sparkles", title: "使用 TrollStore",
             subtitle: "透過 TrollStore 安裝的 App 可直接由 TrollStore 啟用 JIT，無需配對檔或 VPN。") {
            VStack(alignment: .leading, spacing: 14) {
                point(1, "在支援的 iOS / iPadOS 版本上透過 TrollStore 安裝 Henge IPA。",
                      done: JITBootstrap.isInstalledWithTrollStore)
                point(2, "在 TrollStore 的「Settings」中開啟「URL Scheme」。")
                point(3, "啟動 Mac 時，Henge 會請求 TrollStore 短暫附加以啟用 JIT。")
            }
            .padding(16).hengeCard()
            if !JITBootstrap.isTrollStoreInstalled {
                Label("在此 \(device) 找不到 TrollStore（僅支援 iOS 14.0 至 17.0）。", systemImage: "info.circle")
                    .font(.system(size: 13)).foregroundStyle(Theme.textDim)
                    .fixedSize(horizontal: false, vertical: true)
            }
        } actions: {
            Button("使用 TrollStore") {
                jit.method = .trollStore
                HengeLog.log("ui", "JIT method set to TrollStore")
                close()
            }
            .buttonStyle(PrimaryButtonStyle())
        }
    }

    // MARK: Jailbreak

    private var jailbreak: some View {
        page(symbol: "lock.open", title: "使用越獄環境",
             subtitle: "在 Dopamine 越獄環境中開啟「Allow JIT in Apps」即可在每次啟動 App 時自動賦予 JIT 權限。") {
            VStack(alignment: .leading, spacing: 14) {
                point(1, "打開 Dopamine 並進入設定（Settings）。", done: JITBootstrap.isJailbroken)
                point(2, "開啟「Allow JIT in Apps」。")
                point(3, "完全關閉 Henge 後重新開啟（設定會在啟動時生效）。",
                      done: JITBootstrap.debuggedAtLaunch)
            }
            .padding(16).hengeCard()
            if JITBootstrap.debuggedAtLaunch {
                Label("Henge 啟動時已取得除錯標記，JIT 已生效。", systemImage: "checkmark.circle.fill")
                    .font(.system(size: 13)).foregroundStyle(.green)
            } else if !JITBootstrap.isJailbroken {
                Label("在這台 \(device) 找不到越獄環境。", systemImage: "info.circle")
                    .font(.system(size: 13)).foregroundStyle(Theme.textDim)
            }
        } actions: {
            Button("使用越獄模式") {
                jit.method = .jailbreak
                HengeLog.log("ui", "JIT method set to jailbreak")
                close()
            }
            .buttonStyle(PrimaryButtonStyle())
        }
    }

    // MARK: Pieces

    private func page<Content: View, Actions: View>(
        symbol: String, title: String, subtitle: String,
        @ViewBuilder content: () -> Content,
        @ViewBuilder actions: () -> Actions) -> some View {
        ZStack {
            Theme.backdrop
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    Image(systemName: symbol)
                        .font(.system(size: 26, weight: .semibold))
                        .foregroundStyle(Theme.accent)
                        .frame(width: 56, height: 56)
                        .background(Theme.accentSoft, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
                    Text(title).font(.system(size: 28, weight: .semibold)).foregroundStyle(Theme.text)
                    Text(subtitle).font(.system(size: 15)).foregroundStyle(Theme.textDim)
                        .fixedSize(horizontal: false, vertical: true)
                    content()
                }
                .padding(.horizontal, 22).padding(.top, 8).padding(.bottom, 24)
            }
        }
        .safeAreaInset(edge: .bottom, spacing: 0) {
            VStack(spacing: 12) { actions() }
                .padding(.horizontal, 22).padding(.top, 10).padding(.bottom, 16)
                .background(Theme.backdrop)
        }
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .confirmationAction) {
                Button("關閉") { close() }
            }
        }
    }

    private func point(_ number: Int, _ text: String, done: Bool = false) -> some View {
        HStack(alignment: .top, spacing: 12) {
            ZStack {
                Circle().fill(done ? Color.green.opacity(0.18) : Theme.accentSoft)
                if done {
                    Image(systemName: "checkmark").font(.system(size: 12, weight: .bold)).foregroundStyle(.green)
                } else {
                    Text("\(number)").font(.system(size: 13, weight: .bold)).foregroundStyle(Theme.accent)
                }
            }
            .frame(width: 26, height: 26)
            Text(.init(text))
                .font(.system(size: 15))
                .foregroundStyle(Theme.text)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
        }
    }

    private func outcome(_ text: String, ok: Bool) -> some View {
        Label(text, systemImage: ok ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
            .font(.system(size: 14, weight: .medium))
            .foregroundStyle(ok ? .green : .red)
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(14).hengeCard()
    }
}
