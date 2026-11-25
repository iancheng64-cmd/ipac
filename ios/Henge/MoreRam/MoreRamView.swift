import SwiftUI
import UniformTypeIdentifiers

struct MoreRamView: View {
    @Environment(\.locale) private var interfaceLocale
    @Environment(\.dismiss) private var dismiss
    @Environment(\.openURL) private var openURL
    @ObservedObject private var coordinator = MoreRamCoordinator.shared
    @ObservedObject private var jit = JITCoordinator.shared
    @State private var showJSONImporter = false
    @State private var showAnisetteEditor = false
    @State private var showAdvancedSignIn = false
    @State private var showManualAppIDs = false

    private var canNoFootprint: Bool { henge_vm_can_no_footprint() != 0 }

    var body: some View {
        let _ = interfaceLocale
        let _ = jit.attachGeneration
        NavigationStack {
            Form {
                statusSection
                autoBehaviorSection

                if case .unlockedPendingRefresh(let bundleID) = coordinator.autoState,
                   !Entitlements.increasedMemory {
                    pendingRefreshSection(bundleID: bundleID)
                }

                if let banner = coordinator.successBanner {
                    Section {
                        Label {
                            Text(L10n.text(banner)).font(.subheadline)
                        } icon: {
                            Image(systemName: "checkmark.seal.fill").foregroundStyle(.green)
                        }
                    }
                }

                if Entitlements.increasedMemory && !coordinator.isSignedIn {
                    DisclosureGroup(L10n.text("進階：重新登入或手動管理 Apple App ID"), isExpanded: $showAdvancedSignIn) {
                        signInControls
                    }
                } else if !coordinator.isSignedIn {
                    signInSection
                } else {
                    teamAndAppIDsSection
                }

                if !coordinator.statusLogs.isEmpty {
                    logSection
                }
            }
            .navigationTitle(L10n.text("大記憶體與 GetMoreRam"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(L10n.text("關閉")) { dismiss() }
                }
                if coordinator.isSignedIn {
                    ToolbarItem(placement: .topBarTrailing) {
                        Button(L10n.text("登出")) {
                            coordinator.signOut(clearSavedCredentials: false)
                        }
                    }
                }
            }
            .fileImporter(
                isPresented: $showJSONImporter,
                allowedContentTypes: [.json],
                allowsMultipleSelection: false
            ) { result in
                if case .success(let urls) = result, let first = urls.first {
                    coordinator.importSideStoreJSON(url: first)
                } else if case .failure(let error) = result {
                    coordinator.errorMessage = error.localizedDescription
                }
            }
            .alert(L10n.text("輸入 Apple 雙重認證碼"), isPresented: $coordinator.needsTwoFactor) {
                TextField(L10n.text("6 位數驗證碼"), text: $coordinator.twoFactorCode)
                    .keyboardType(.numberPad)
                Button(L10n.text("送出")) { coordinator.submitTwoFactorCode() }
                    .disabled(coordinator.twoFactorCode.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                Button(L10n.text("取消"), role: .cancel) { coordinator.cancelTwoFactor() }
            } message: {
                Text(L10n.text("請輸入 Apple 傳送到您受信任裝置的 6 位數驗證碼。"))
            }
            .onChange(of: coordinator.needsTwoFactor) {
                coordinator.handleTwoFactorDismissedIfNeeded()
            }
            .onChange(of: coordinator.requiresManualAppIDSelection, initial: true) {
                if coordinator.requiresManualAppIDSelection {
                    showManualAppIDs = true
                }
            }
        }
    }

    private var statusSection: some View {
        Section {
            LabeledContent(L10n.text("大記憶體 Entitlement")) {
                Text(Entitlements.increasedMemory ? L10n.text("已自動啟用") : L10n.text("尚未啟用"))
                    .foregroundStyle(Entitlements.increasedMemory ? .green : .orange)
                    .fontWeight(.semibold)
            }
            LabeledContent(L10n.text("裝置實體記憶體"), value: "\(Device.physicalMemoryGB) GB")
            LabeledContent(L10n.text("啟動時系統配額上限"), value: "\(Entitlements.memoryLimitAtLaunch >> 20) MB")
            LabeledContent(L10n.text("JIT 免計入上限（No Footprint）")) {
                Text(canNoFootprint ? L10n.text("支援並可使用") : L10n.text("待機（開機附加 JIT 後自動啟用）"))
                    .foregroundStyle(canNoFootprint ? .green : .secondary)
            }
        } header: {
            Text(L10n.text("目前 iPac 記憶體解鎖狀態"))
        } footer: {
            if Entitlements.increasedMemory {
                Text(L10n.text("這份 iPac 已具備 Apple 大記憶體權限，完全不需任何額外設定。開機並掛載 JIT 後，虛擬機記憶體將以 No Footprint 直接配置至最大可用空間。"))
            } else {
                Text(L10n.text("只需在下方登入一次 Apple ID（或匯入 SideStore 帳號 JSON），iPac 就會自動找到目前 Bundle ID 並開啟 Apple 大記憶體權限，之後每次開啟 App 也會自動背景檢查。"))
            }
        }
    }

    private var autoBehaviorSection: some View {
        Section {
            Toggle(L10n.text("開啟 iPac 時自動檢查並啟用大記憶體"), isOn: $coordinator.autoEnableOnLaunch)
            if !Entitlements.increasedMemory && coordinator.dismissedHomePromptBuild != coordinator.currentBuildTag {
                Button(L10n.text("暫時隱藏首頁大記憶體提醒")) {
                    coordinator.dismissHomePromptForThisBuild()
                    dismiss()
                }
                .foregroundStyle(.secondary)
            }
        } footer: {
            Text(L10n.text("若已啟用大記憶體權限則直接略過連線；若使用免費簽名重新安裝且尚未刷新權限，會自動於背景代為向 Apple 申請。"))
        }
    }

    private func pendingRefreshSection(bundleID: String) -> some View {
        Section(L10n.text("最後一步：重整簽名即可生效")) {
            Label {
                Text(L10n.format("已自動在 Apple 帳號端為 %@ 開啟 `INCREASED_MEMORY_LIMIT` 權限。", String(describing: bundleID)))
                    .font(.subheadline)
            } icon: {
                Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
            }
            if let signer = coordinator.installedSignerApp {
                Button {
                    openURL(signer.url)
                } label: {
                    Label(L10n.format("立即打開 %@ 重新簽名（Refresh）", String(describing: signer.name)), systemImage: "arrow.up.forward.app.fill")
                        .fontWeight(.semibold)
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
            }
            Text(L10n.text("因為 Apple 將權限寫入描述檔（Provisioning Profile），回到您的簽名工具對 iPac 點一次「Refresh / 重新簽名」後重開 App，上方狀態就會顯示「已自動啟用」。"))
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    private var signInSection: some View {
        Section {
            signInControls
        } header: {
            Text(L10n.text("一鍵自動啟用（登入一次即可）"))
        } footer: {
            Text(L10n.text("登入成功後系統會自動搜尋並為目前 iPac 開啟大記憶體，無須手動挑選清單。帳號密碼僅儲存於本機 Keychain。"))
        }
    }

    @ViewBuilder
    private var signInControls: some View {
        TextField(L10n.text("Apple ID 電子郵件"), text: $coordinator.appleID)
            .textInputAutocapitalization(.never)
            .autocorrectionDisabled()
            .keyboardType(.emailAddress)
            .disabled(coordinator.isAuthenticating)
        SecureField(L10n.text("Apple ID 密碼"), text: $coordinator.password)
            .disabled(coordinator.isAuthenticating)
        Toggle(L10n.text("在裝置 Keychain 記住帳號（供開機自動啟用）"), isOn: $coordinator.rememberCredentials)
            .disabled(coordinator.isAuthenticating)

        DisclosureGroup(L10n.text("進階 Anisette v3 設定"), isExpanded: $showAnisetteEditor) {
            TextField(L10n.text("Anisette 伺服器網址"), text: $coordinator.anisetteServerURL)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .keyboardType(.URL)
                .disabled(coordinator.isAuthenticating)
            Button(L10n.text("重設 Anisette 快取與恢復預設網址")) {
                coordinator.anisetteServerURL = MoreRamAnisette.defaultServerURL
                coordinator.resetAnisetteCache()
            }
            .foregroundStyle(.secondary)
            .disabled(coordinator.isAuthenticating)
        }

        if let error = coordinator.errorMessage {
            Text(L10n.text(error))
                .font(.caption)
                .foregroundStyle(.red)
        }

        Button {
            Task { await coordinator.signIn() }
        } label: {
            HStack {
                if coordinator.isAuthenticating {
                    ProgressView().padding(.trailing, 4)
                }
                Text(coordinator.isAuthenticating ? L10n.text("自動登入與開通中…") : L10n.text("一鍵登入並自動啟用最大記憶體"))
                    .fontWeight(.semibold)
            }
            .frame(maxWidth: .infinity)
        }
        .buttonStyle(.borderedProminent)
        .disabled(coordinator.isAuthenticating)

        Button {
            showJSONImporter = true
        } label: {
            Label(L10n.text("匯入 SideStore 帳號 JSON 一鍵啟用"), systemImage: "doc.badge.plus")
        }
        .disabled(coordinator.isAuthenticating)

        if coordinator.hasStoredCredentials || coordinator.hasStoredAnisette {
            Button(L10n.text("清除已儲存的帳密與 Anisette"), role: .destructive) {
                coordinator.signOut(clearSavedCredentials: true)
                coordinator.resetAnisetteCache()
            }
        }
    }

    @ViewBuilder
    private var teamAndAppIDsSection: some View {
        Section {
            if coordinator.teams.count > 1 {
                Picker(L10n.text("開發者團隊"), selection: $coordinator.selectedTeamID) {
                    ForEach(coordinator.teams, id: \.identifier) { team in
                        Text("\(team.name) (\(team.identifier))").tag(team.identifier)
                    }
                }
                .disabled(coordinator.isAuthenticating || coordinator.updatingAppID != nil)
                .onChange(of: coordinator.selectedTeamID) {
                    Task { await coordinator.loadAppIDs() }
                }
            } else if let team = coordinator.selectedTeam {
                LabeledContent(L10n.text("開發者團隊"), value: "\(team.name) (\(team.identifier))")
            }

            DisclosureGroup(L10n.format("進階：手動管理全部 App ID（%@）", String(describing: coordinator.appIDs.count)), isExpanded: $showManualAppIDs) {
                Toggle(L10n.text("同時請求 Extended Virtual Addressing（僅限付費帳號）"), isOn: $coordinator.includeExtendedVirtualAddressing)
                    .disabled(coordinator.isAuthenticating || coordinator.updatingAppID != nil)
                Button {
                    Task { await coordinator.loadAppIDs() }
                } label: {
                    Label(L10n.text("重新整理清單"), systemImage: "arrow.clockwise")
                }
                .disabled(coordinator.isLoadingAppIDs || coordinator.isAuthenticating || coordinator.updatingAppID != nil)

                if let error = coordinator.errorMessage {
                    Text(L10n.text(error)).font(.caption).foregroundStyle(.red)
                }

                if coordinator.isLoadingAppIDs && coordinator.appIDs.isEmpty {
                    HStack {
                        ProgressView().padding(.trailing, 6)
                        Text(L10n.text("載入中…")).foregroundStyle(.secondary)
                    }
                } else {
                    ForEach(coordinator.appIDs) { item in
                        let enabled = item.isEffectivelyEnabled(unlockedBundleIDs: coordinator.unlockedBundleIDs)
                        HStack(spacing: 12) {
                            VStack(alignment: .leading, spacing: 3) {
                                HStack(spacing: 6) {
                                    Text(item.name).font(.headline)
                                    if item.isCurrentApp {
                                        Text(L10n.text("目前 App"))
                                            .font(.caption2.weight(.semibold))
                                            .padding(.horizontal, 6)
                                            .padding(.vertical, 2)
                                            .background(Color.accentColor.opacity(0.15))
                                            .foregroundStyle(Color.accentColor)
                                            .clipShape(Capsule())
                                    }
                                }
                                Text(item.bundleIdentifier)
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                Label(
                                    enabled ? L10n.text("大記憶體：已啟用") : L10n.text("大記憶體：未啟用"),
                                    systemImage: enabled ? "checkmark.circle.fill" : "exclamationmark.circle"
                                )
                                .font(.caption2)
                                .foregroundStyle(enabled ? .green : .orange)
                            }
                            Spacer()
                            if coordinator.updatingAppID == item.id {
                                ProgressView()
                            } else {
                                Button(enabled ? L10n.text("重新套用") : L10n.text("啟用大記憶體")) {
                                    Task { await coordinator.enableIncreasedMemory(for: item) }
                                }
                                .buttonStyle(.borderedProminent)
                                .controlSize(.small)
                                .disabled(coordinator.updatingAppID != nil || coordinator.isLoadingAppIDs || coordinator.isAuthenticating)
                            }
                        }
                        .padding(.vertical, 4)
                    }
                }
            }
        }
    }

    private var logSection: some View {
        Section(L10n.text("執行紀錄")) {
            ForEach(Array(coordinator.statusLogs.enumerated()), id: \.offset) { _, line in
                Text(line)
                    .font(.caption.monospaced())
                    .foregroundStyle(.secondary)
            }
        }
    }
}
