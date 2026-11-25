import SwiftUI
import UniformTypeIdentifiers

struct MoreRamView: View {
    @Environment(\.dismiss) private var dismiss
    @StateObject private var coordinator = MoreRamCoordinator()
    @State private var showJSONImporter = false
    @State private var showAnisetteEditor = false

    private var canNoFootprint: Bool { henge_vm_can_no_footprint() != 0 }

    var body: some View {
        NavigationStack {
            Form {
                statusSection
                howItWorksSection
                if !coordinator.isSignedIn {
                    signInSection
                } else {
                    teamAndAppIDsSection
                }
                if !coordinator.statusLogs.isEmpty {
                    logSection
                }
            }
            .navigationTitle("內建 GetMoreRam")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("關閉") { dismiss() }
                }
                if coordinator.isSignedIn {
                    ToolbarItem(placement: .topBarTrailing) {
                        Button("登出") {
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
            .alert("輸入 Apple 雙重認證碼", isPresented: $coordinator.needsTwoFactor) {
                TextField("6 位數驗證碼", text: $coordinator.twoFactorCode)
                    .keyboardType(.numberPad)
                Button("送出") { coordinator.submitTwoFactorCode() }
                    .disabled(coordinator.twoFactorCode.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                Button("取消", role: .cancel) { coordinator.cancelTwoFactor() }
            } message: {
                Text("請輸入 Apple 傳送到您受信任裝置的 6 位數驗證碼。")
            }
            .onChange(of: coordinator.needsTwoFactor) {
                coordinator.handleTwoFactorDismissedIfNeeded()
            }
        }
    }

    private var statusSection: some View {
        Section {
            LabeledContent("裝置實體記憶體", value: "\(Device.physicalMemoryGB) GB")
            LabeledContent("大記憶體 Entitlement") {
                Text(Entitlements.increasedMemory ? "已啟用" : "未啟用")
                    .foregroundStyle(Entitlements.increasedMemory ? .green : .orange)
                    .fontWeight(.semibold)
            }
            LabeledContent("啟動時系統配額上限", value: "\(Entitlements.memoryLimitAtLaunch >> 20) MB")
            LabeledContent("JIT 免計入上限（No Footprint）") {
                Text(canNoFootprint ? "支援並可使用" : "未附加 JIT 時不適用")
                    .foregroundStyle(canNoFootprint ? .green : .secondary)
            }
        } header: {
            Text("目前 iPac 記憶體解鎖狀態")
        } footer: {
            if Entitlements.increasedMemory {
                Text("您目前安裝的 iPac 已具備 Apple 大記憶體權限，開機並掛載 JIT 後系統核心會自動略過 App 上限計數（LEDGER_NO_FOOTPRINT）。")
            } else {
                Text("未開通前，iPadOS 會在記憶體達 ~2–3 GB 時強制終止 App。透過下方內建 GetMoreRam 工具可向 Apple 帳號開啟權限。")
            }
        }
    }

    private var howItWorksSection: some View {
        Section("運作原理與兩步驟流程") {
            VStack(alignment: .leading, spacing: 6) {
                Label("1. 向 Apple 帳號開啟 INCREASED_MEMORY_LIMIT 權限", systemImage: "1.circle.fill")
                    .font(.subheadline.weight(.medium))
                Text("直接在下方登入 Apple ID 或匯入 SideStore 帳號 JSON，點選列表中的 iPac / Henge Bundle ID 即可寫入 Apple 伺服器設定。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Label("2. 重新 Refresh / 重簽一次 App", systemImage: "2.circle.fill")
                    .font(.subheadline.weight(.medium))
                    .padding(.top, 4)
                Text("由於權限紀錄在簽名 Provisioning Profile 內，送出成功後請回到 SideStore / AltStore 或 Xcode 重新簽名（Refresh）一次，新開啟的權限就會永久套用。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .padding(.vertical, 2)
        }
    }

    private var signInSection: some View {
        Section {
            TextField("Apple ID 電子郵件", text: $coordinator.appleID)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .keyboardType(.emailAddress)
            SecureField("Apple ID 密碼", text: $coordinator.password)
            Toggle("在裝置 Keychain 記住帳號密碼", isOn: $coordinator.rememberCredentials)

            DisclosureGroup("進階 Anisette v3 設定", isExpanded: $showAnisetteEditor) {
                TextField("Anisette 伺服器網址", text: $coordinator.anisetteServerURL)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .keyboardType(.URL)
                Button("重設 Anisette 快取與重置為預設伺服器") {
                    coordinator.anisetteServerURL = MoreRamAnisette.defaultServerURL
                    coordinator.resetAnisetteCache()
                }
                .foregroundStyle(.secondary)
            }

            if let error = coordinator.errorMessage {
                Text(error)
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
                    Text(coordinator.isAuthenticating ? "驗證中…" : "登入 Apple 帳號")
                        .fontWeight(.semibold)
                }
                .frame(maxWidth: .infinity)
            }
            .disabled(coordinator.isAuthenticating)

            Button {
                showJSONImporter = true
            } label: {
                Label("匯入 SideStore 帳號 JSON 並登入", systemImage: "doc.badge.plus")
            }
            .disabled(coordinator.isAuthenticating)

            if coordinator.hasStoredCredentials || coordinator.hasStoredAnisette {
                Button("清除已儲存的帳密與 Anisette", role: .destructive) {
                    coordinator.signOut(clearSavedCredentials: true)
                    coordinator.resetAnisetteCache()
                }
            }
        } header: {
            Text("Apple 開發者帳號驗證")
        } footer: {
            Text("帳號密碼只會儲存在本機 iPad Keychain 並直接送往 Apple AuthKit 與您指定的 Anisette v3 伺服器，不會上傳任何第三方統計伺服器。")
        }
    }

    @ViewBuilder
    private var teamAndAppIDsSection: some View {
        Section("開發者團隊與進階選項") {
            if coordinator.teams.count > 1 {
                Picker("團隊", selection: $coordinator.selectedTeamID) {
                    ForEach(coordinator.teams, id: \.identifier) { team in
                        Text("\(team.name) (\(team.identifier))").tag(team.identifier)
                    }
                }
                .onChange(of: coordinator.selectedTeamID) {
                    Task { await coordinator.loadAppIDs() }
                }
            } else if let team = coordinator.selectedTeam {
                LabeledContent("團隊", value: "\(team.name) (\(team.identifier))")
            }

            Toggle("同時請求 Extended Virtual Addressing", isOn: $coordinator.includeExtendedVirtualAddressing)
            Text("僅限付費 Apple Developer 帳號使用；免費個人開發者帳號請維持關閉，否則 Apple 會拒絕套用。")
                .font(.caption)
                .foregroundStyle(.secondary)

            Button {
                Task { await coordinator.loadAppIDs() }
            } label: {
                Label("重新整理 App ID 清單", systemImage: "arrow.clockwise")
            }
            .disabled(coordinator.isLoadingAppIDs)
        }

        if let banner = coordinator.successBanner {
            Section {
                Label {
                    Text(banner).font(.subheadline)
                } icon: {
                    Image(systemName: "checkmark.seal.fill").foregroundStyle(.green)
                }
            }
        }

        if let error = coordinator.errorMessage {
            Section {
                Text(error)
                    .font(.caption)
                    .foregroundStyle(.red)
            }
        }

        Section("選擇要解鎖大記憶體的 App ID") {
            if coordinator.isLoadingAppIDs && coordinator.appIDs.isEmpty {
                HStack {
                    ProgressView().padding(.trailing, 6)
                    Text("載入中…").foregroundStyle(.secondary)
                }
            } else if coordinator.appIDs.isEmpty {
                Text("找不到已註冊的 App ID。請先用 SideStore / AltStore 安裝一次 iPac 讓系統自動註冊 Bundle ID。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else {
                ForEach(coordinator.appIDs) { item in
                    HStack(spacing: 12) {
                        VStack(alignment: .leading, spacing: 3) {
                            HStack(spacing: 6) {
                                Text(item.name)
                                    .font(.headline)
                                if item.isCurrentApp {
                                    Text("目前 App")
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
                            HStack(spacing: 8) {
                                Label(
                                    item.hasIncreasedMemoryLimit ? "大記憶體：已啟用" : "大記憶體：未啟用",
                                    systemImage: item.hasIncreasedMemoryLimit ? "checkmark.circle.fill" : "exclamationmark.circle"
                                )
                                .font(.caption2)
                                .foregroundStyle(item.hasIncreasedMemoryLimit ? .green : .orange)
                            }
                        }

                        Spacer()

                        if coordinator.updatingAppID == item.id {
                            ProgressView()
                        } else {
                            Button(item.hasIncreasedMemoryLimit ? "重新套用" : "啟用大記憶體") {
                                Task { await coordinator.enableIncreasedMemory(for: item) }
                            }
                            .buttonStyle(.borderedProminent)
                            .controlSize(.small)
                            .disabled(coordinator.updatingAppID != nil)
                        }
                    }
                    .padding(.vertical, 4)
                }
            }
        }
    }

    private var logSection: some View {
        Section("執行紀錄") {
            ForEach(Array(coordinator.statusLogs.enumerated()), id: \.offset) { _, line in
                Text(line)
                    .font(.caption.monospaced())
                    .foregroundStyle(.secondary)
            }
        }
    }
}
