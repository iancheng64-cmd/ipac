import SwiftUI
import UniformTypeIdentifiers

/// Download macOS (or use a copy already on this device) and install it on a new Mac.
struct InstallView: View {
    private enum InstallDialog {
        case deleteDownload(MacOSRelease)
        case ejectSSD
        case clearSSD(ExternalDriveHengeSummary)
    }

    @ObservedObject private var installer = Installer.shared
    @ObservedObject private var jit = JITCoordinator.shared
    @ObservedObject private var extStorage = ExternalInstallStorage.shared
    @ObservedObject private var machines = Machines.shared
    @State private var jitReady = JITBootstrap.ready
    @StateObject private var display = DisplayRouter()
    @State private var release = MacOSRelease.all.first(where: Installer.haveImage) ?? MacOSRelease.recommended
    @State private var name = "Mac"
    @State private var ramGB = Device.suggestedRAMGB
    @State private var deleteAfter = ExternalInstallStorage.shared.mode.needsExternalDrive
    @State private var refresh = 0 // redraws the list when a download is deleted
    @State private var details = false
    @State private var stageStarted = Date()
    @State private var stageSeen = -1
    @State private var activeDialog: InstallDialog?
    @State private var pickingExternalFolder = false
    @AppStorage("henge.cpus") private var cpus = 4

    private var dialogTitle: String {
        switch activeDialog {
        case .deleteDownload:
            return "確定刪除這個安裝映像檔嗎？"
        case .ejectSSD:
            return "確定要安全退出外接 SSD 嗎？"
        case .clearSSD(let summary):
            return "確定清除「\(summary.driveName)」上的 Henge 資料？"
        case .none:
            return ""
        }
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 0) {
                    switch installer.phase {
                    case .idle: chooser
                    case .checking:
                        ProgressView("正在準備安裝 macOS…")
                            .padding(20)
                    case .downloading, .preparing, .installing: progress
                    case .done(let text): finished(text)
                    case .failed(let text): failed(text)
                    }
                }
                .padding(.horizontal, 16)
                .padding(.bottom, 24)
                .deskColumn()
            }
            .background(Desk.page)
            .navigationTitle(installer.busy ? "安裝中" : "安裝 macOS")
            .task {
                while !Task.isCancelled { // the region may be claimed after a hand-off to StikDebug
                    jitReady = JITBootstrap.ready
                    try? await Task.sleep(nanoseconds: 1_000_000_000)
                }
            }
            .fileImporter(isPresented: $pickingExternalFolder, allowedContentTypes: [.folder]) { result in
                if case let .success(url) = result {
                    if extStorage.selectFolder(url) {
                        deleteAfter = true
                        if !Installer.haveImage(release), let found = MacOSRelease.all.first(where: Installer.haveImage) {
                            release = found
                        }
                    }
                    refresh += 1
                }
            }
            .confirmationDialog(
                dialogTitle,
                isPresented: Binding(get: { activeDialog != nil }, set: { if !$0 { activeDialog = nil } }),
                titleVisibility: .visible,
                presenting: activeDialog
            ) { dialog in
                switch dialog {
                case .deleteDownload(let r):
                    Button("刪除下載檔", role: .destructive) {
                        Installer.deleteImage(r)
                        refresh += 1
                    }
                case .ejectSSD:
                    Button("安全退出 SSD（保留資料）") {
                        _ = extStorage.safeEjectDrive()
                        refresh += 1
                    }
                case .clearSSD(let summary):
                    Button(
                        summary.totalBytes > 0
                            ? "只清除 Henge 資料（釋放 \(ByteText.string(UInt64(summary.totalBytes)))）"
                            : "確認清除 Henge 資料",
                        role: .destructive
                    ) {
                        extStorage.clearAllHengeDataOnDrive { _ in
                            refresh += 1
                        }
                    }
                }
            } message: { dialog in
                switch dialog {
                case .deleteDownload:
                    Text("將刪除已下載的 macOS 回復映像檔，之後可隨時重新下載。")
                case .ejectSSD:
                    Text("會確認目前無執行中的虛擬機或安裝作業，釋放 Henge 對「\(extStorage.effectiveDriveName)」的存取權限與紀錄，完整保留 SSD 內的系統與所有個人資料。")
                case .clearSSD(let summary):
                    if summary.isEmpty {
                        Text("目前在「\(summary.driveName)」找不到 Henge 系統或安裝暫存檔；SSD 內您的其他個人檔案皆不受影響。")
                    } else {
                        Text("只會刪除「\(summary.driveName)」上的 Henge 資料（共 \(summary.machineCount) 台 Mac\(summary.hasInstallFiles ? "、含安裝暫存檔 HengeInstall" : "")，約釋放 \(ByteText.string(UInt64(summary.totalBytes)))）。您的其他個人檔案皆會完整保留。此動作無法復原。")
                    }
                }
            }
            .onAppear {
                extStorage.refreshConnection()
                refresh += 1
            }
        }
    }

    // MARK: Choosing

    @ViewBuilder private var chooser: some View {
        DeskHeading("選擇版本")
        VStack(spacing: 0) {
            ForEach(MacOSRelease.all) { r in
                HStack(spacing: 0) {
                    Button { release = r } label: { versionRow(r) }
                        .buttonStyle(.plain)
                    if ((Installer.haveImage(r) && Installer.isManagedImage(Installer.imagePath(r))) || Installer.partSize(r) != nil) && !installer.busy {
                        Button { activeDialog = .deleteDownload(r) } label: {
                            Image(systemName: "trash")
                                .font(.system(size: 15, weight: .medium))
                                .foregroundStyle(Desk.dim)
                                .frame(width: 44, height: 44)
                                .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel("刪除 \(r.name) 安裝檔")
                        .padding(.trailing, 6)
                    }
                }
                    .contextMenu {
                        if (Installer.haveImage(r) && Installer.isManagedImage(Installer.imagePath(r))) || Installer.partSize(r) != nil {
                            Button("刪除下載檔", role: .destructive) { activeDialog = .deleteDownload(r) }
                        }
                    }
                if r.id != MacOSRelease.all.last?.id { Rectangle().fill(Desk.hairline).frame(height: 0.5) }
            }
        }
        .deskCard()
        .id(refresh)

        DeskHeading("安裝儲存位置")
        VStack(spacing: 0) {
            ForEach(InstallStorageMode.allCases) { mode in
                Button {
                    extStorage.mode = mode
                    if mode.needsExternalDrive {
                        deleteAfter = true
                        if !extStorage.isConfigured {
                            pickingExternalFolder = true
                        }
                    }
                    refresh += 1
                } label: {
                    HStack(alignment: .center, spacing: 12) {
                        VStack(alignment: .leading, spacing: 3) {
                            Text(mode.title)
                                .font(.system(size: 16, weight: .medium))
                                .foregroundStyle(Desk.text)
                            Text(mode.subtitle)
                                .font(.system(size: 13))
                                .foregroundStyle(Desk.dim)
                                .multilineTextAlignment(.leading)
                        }
                        Spacer()
                        if extStorage.mode == mode {
                            Image(systemName: "checkmark")
                                .font(.system(size: 15, weight: .bold))
                                .foregroundStyle(Desk.accentLight)
                        }
                    }
                    .padding(.horizontal, 17)
                    .padding(.vertical, 12)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                if mode != InstallStorageMode.allCases.last {
                    Rectangle().fill(Desk.hairline).frame(height: 0.5)
                }
            }

            if extStorage.mode.needsExternalDrive || extStorage.isConfigured {
                Rectangle().fill(Desk.hairline).frame(height: 0.5)
                VStack(alignment: .leading, spacing: 8) {
                    HStack(alignment: .firstTextBaseline) {
                        Label(
                            extStorage.isConfigured ? (extStorage.configuredName ?? "外接 SSD") : "尚未選擇外接硬碟資料夾",
                            systemImage: "externaldrive.fill"
                        )
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundStyle(Desk.text)
                        Spacer()
                        if extStorage.isConfigured {
                            if extStorage.isConnected {
                                Text("已連接\(extStorage.filesystemType.map { "（\($0)）" } ?? "") • 剩餘 \(ByteText.string(UInt64(max(extStorage.freeBytes, 0))))")
                                    .font(.system(size: 13, weight: .medium))
                                    .foregroundStyle(Desk.good)
                            } else {
                                Text("未連接")
                                    .font(.system(size: 13, weight: .medium))
                                    .foregroundStyle(Desk.bad)
                            }
                        } else {
                            Text("必選")
                                .font(.system(size: 13, weight: .medium))
                                .foregroundStyle(Desk.bad)
                        }
                    }

                    if extStorage.mode == .externalFull && extStorage.isConnected && !extStorage.supportsSparseFiles {
                        Text("提醒：此硬碟為 \(extStorage.filesystemType ?? "exFAT") 格式，不支援稀疏檔案（Sparse File）。完整外接模式下系統映像會直接佔滿 64 GB 且建立時需等待數分鐘；外接 SSD 建議優先格式化為 APFS。")
                            .font(.system(size: 12))
                            .foregroundStyle(Desk.warn)
                    }

                    if extStorage.isClearing {
                        HStack(spacing: 8) {
                            ProgressView().controlSize(.small)
                            Text("正在清除 SSD 上的 Henge 資料…")
                                .font(.system(size: 13))
                                .foregroundStyle(Desk.dim)
                        }
                    }
                    if let msg = extStorage.statusMessage {
                        Text(msg)
                            .font(.system(size: 13))
                            .foregroundStyle(Desk.good)
                    }
                    if let err = extStorage.lastError {
                        Text(err)
                            .font(.system(size: 13))
                            .foregroundStyle(Desk.bad)
                    }

                    HStack(spacing: 14) {
                        Button(extStorage.isConfigured ? "變更外接資料夾…" : "選擇外接 SSD 資料夾…") {
                            pickingExternalFolder = true
                        }
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundStyle(Desk.accentLight)
                        .disabled(extStorage.isClearing || machines.isBusy || Machines.isVMRunning)
                        Spacer()
                        if extStorage.isConfigured && !extStorage.isConnected {
                            Button("重新偵測") {
                                extStorage.refreshConnection()
                                refresh += 1
                            }
                            .font(.system(size: 14, weight: .medium))
                            .foregroundStyle(Desk.accentLight)
                        }
                    }

                    if extStorage.isConfigured {
                        HStack(spacing: 16) {
                            Button {
                                activeDialog = .ejectSSD
                            } label: {
                                Label("安全退出 SSD（保留資料）", systemImage: "eject")
                                    .font(.system(size: 14, weight: .medium))
                            }
                            .foregroundStyle(Desk.dim)
                            .disabled(extStorage.isClearing || machines.isBusy || Machines.isVMRunning)

                            Spacer()

                            if extStorage.canClearDrive {
                                Button(role: .destructive) {
                                    if let summary = extStorage.inspectHengeDataOnDrive() {
                                        activeDialog = .clearSSD(summary)
                                    }
                                } label: {
                                    Label("清除 SSD 資料…", systemImage: "trash")
                                        .font(.system(size: 14, weight: .medium))
                                }
                                .foregroundStyle(Desk.bad)
                                .disabled(extStorage.isClearing || machines.isBusy || Machines.isVMRunning)
                            }
                        }
                        .padding(.top, 4)
                    }
                }
                .padding(.horizontal, 17)
                .padding(.vertical, 13)
            }
        }
        .deskCard()

        DeskHeading("新增 Mac")
        VStack(spacing: 0) {
            TextField("名稱", text: $name)
                .font(.system(size: 16))
                .padding(.horizontal, 17)
                .padding(.vertical, 14)
            Rectangle().fill(Desk.hairline).frame(height: 0.5)
            Stepper(value: $ramGB, in: Device.memoryChoices) {
                HStack {
                    Text("記憶體").font(.system(size: 16))
                    Spacer()
                    Text("\(ramGB) GB").font(.system(size: 16, weight: .semibold))
                }
            }
            .padding(.horizontal, 17)
            .padding(.vertical, 10)
            if let note = Device.memoryNote(ramGB) {
                Text(note)
                    .font(.system(size: 13))
                    .foregroundStyle(Desk.dim)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 17)
                    .padding(.bottom, 10)
            }
            Rectangle().fill(Desk.hairline).frame(height: 0.5)
            Toggle(extStorage.mode.needsExternalDrive ? "安裝後自動清除安裝暫存檔" : "安裝後刪除下載映像檔", isOn: $deleteAfter)
                .font(.system(size: 16))
                .padding(.horizontal, 17)
                .padding(.vertical, 10)
        }
        .deskCard()

        Button(Installer.haveImage(release) ? "立即安裝" : "下載並安裝") {
            installer.start(release, name: name.isEmpty ? "Mac" : name, ramMB: ramGB * 1024, cpus: cpus, keepImage: !deleteAfter)
        }
        .buttonStyle(DeskButtonStyle(enabled: canInstall))
        .disabled(!canInstall)
        .padding(.top, 20)
        Text(spaceCaption)
            .font(.system(size: 13))
            .foregroundStyle((extStorage.mode.needsExternalDrive && (!extStorage.isConfigured || !extStorage.isConnected)) ? Desk.bad : Desk.dim)
            .multilineTextAlignment(.center)
            .padding(.top, 10)
        if !jitReady && !Device.chipTooOld {
            // Before any Mac exists, this is the only place to ask for JIT (#23).
            Button("開啟 JIT") { jit.enable() }
                .buttonStyle(DeskButtonStyle())
                .padding(.top, 12)
        }
    }

    private var canInstall: Bool {
        guard jitReady && !Device.chipTooOld && !extStorage.isClearing else { return false }
        if extStorage.mode.needsExternalDrive {
            return extStorage.isConfigured && extStorage.isConnected
        }
        return true
    }

    private var spaceCaption: String {
        if Device.chipTooOld { return Device.chipTooOldText }
        if !jitReady { return JITBootstrap.lastFailure ?? "請先開啟 JIT。\(jit.automaticDescription)" }
        if extStorage.mode.needsExternalDrive {
            if !extStorage.isConfigured {
                return "請先選擇外接 USB-C SSD 資料夾，或將安裝位置切回「本機儲存（原始模式）」。"
            }
            if !extStorage.isConnected {
                return "請先插上「\(extStorage.configuredName ?? "外接硬碟")」，或切回「本機儲存」。"
            }
        }
        let internalNeed = ByteText.string(UInt64(Installer.internalSpaceNeeded(release)))
        let extNeed = ByteText.string(UInt64(Installer.externalSpaceNeeded(release)))
        let drive = extStorage.configuredName ?? "外接 SSD"
        switch extStorage.mode {
        case .internalOnly:
            return "安裝期間請保持 Henge 開啟。需要這台 \(Device.name) 至少 \(internalNeed) 本機可用空間。"
        case .externalStaging:
            return "安裝期間請保持連線。這台 \(Device.name) 需要約 \(internalNeed)（存放完成後的系統），「\(drive)」需約 \(extNeed)（安裝完自動清除）。"
        case .externalFull:
            return "安裝期間請保持 Henge 開啟並維持「\(drive)」連線。外接碟需約 \(extNeed)，這台 \(Device.name) 只需約 \(internalNeed) 緩衝空間；完成後可帶到別台 iPad 隨插即用。"
        }
    }

    private func versionRow(_ r: MacOSRelease) -> some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text(r.name).font(.system(size: 16, weight: .medium)).foregroundStyle(Desk.text)
                if let size = Installer.imageSize(r) {
                    Text("已下載完成，\(ByteText.string(UInt64(size)))").font(.system(size: 13)).foregroundStyle(Desk.good)
                } else if let part = Installer.partSize(r) {
                    Text("已下載 \(ByteText.string(UInt64(part)))／共 \(ByteText.string(UInt64(r.bytes)))（支援續傳）")
                        .font(.system(size: 13)).foregroundStyle(Desk.dim)
                } else {
                    Text("需下載 \(ByteText.string(UInt64(r.bytes)))").font(.system(size: 13)).foregroundStyle(Desk.dim)
                }
                Text(r.note).font(.system(size: 13)).foregroundStyle(Desk.dim)
            }
            Spacer()
            if release == r { Image(systemName: "checkmark").font(.system(size: 15, weight: .bold)).foregroundStyle(Desk.accentLight) }
        }
        .padding(.horizontal, 17)
        .padding(.vertical, 12)
        .contentShape(Rectangle())
    }

    // MARK: Going

    private static let stages = ["下載系統", "啟動安裝程式", "寫入 macOS", "驗證系統", "完成收尾"]

    private var stage: Int {
        switch installer.phase {
        case .downloading: return 0
        case .preparing: return 1
        default:
            switch installer.step {
            case 0, 1: return 1
            case 2: return 2
            case 3: return 3
            default: return 4
            }
        }
    }

    private var fraction: Double {
        if case .downloading = installer.phase {
            return installer.expected > 0 ? Double(installer.received) / Double(installer.expected) : 0
        }
        return installer.stepProgress
    }

    /// From how this step has gone so far; nothing until there is enough to go on.
    private var timeLeft: String? {
        let elapsed = Date().timeIntervalSince(stageStarted)
        guard stageSeen == stage, fraction > 0.03, fraction < 1, elapsed > 10 else { return nil }
        let minutes = Int((elapsed / fraction * (1 - fraction) / 60).rounded(.up))
        return minutes <= 1 ? "此步驟預估還需約 1 分鐘" : "此步驟預估還需約 \(minutes) 分鐘"
    }

    @ViewBuilder private var progress: some View {
        let activeRelease = installer.installingReleaseName.isEmpty ? release.name : installer.installingReleaseName
        let activeTarget = installer.installingTargetLabel.isEmpty ? "這台 \(Device.name)" : installer.installingTargetLabel
        Text("正在安裝 \(activeRelease) 至\(activeTarget)，請保持 Henge 開啟於前景。")
            .font(.system(size: 16))
            .foregroundStyle(Desk.dim)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 4)
            .padding(.bottom, 16)

        TimelineView(.periodic(from: .now, by: 1)) { _ in
            VStack(alignment: .leading, spacing: 0) {
                Text("\(Int(fraction * 100))%")
                    .font(.system(size: 66, weight: .bold))
                    .monospacedDigit()
                Text(timeLeft ?? "步驟 \(stage + 1)／\(Self.stages.count)")
                    .font(.system(size: 15))
                    .foregroundStyle(Desk.dim)
                    .padding(.top, 2)
                    .padding(.bottom, 16)
                DeskBar(fraction: fraction, height: 11)
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 24)
            .frame(maxWidth: .infinity, alignment: .leading)
            .deskCard(radius: 30)
        }
        .onChange(of: stage) { value in
            stageSeen = value
            stageStarted = Date()
        }
        .onAppear {
            stageSeen = stage
            stageStarted = Date()
        }

        DeskHeading("安裝進度")
        VStack(spacing: 0) {
            ForEach(Array(Self.stages.enumerated()), id: \.offset) { i, title in
                HStack {
                    Text(title)
                        .font(.system(size: 16, weight: i == stage ? .semibold : .regular))
                        .foregroundStyle(i > stage ? Desk.faint : Desk.text)
                    Spacer()
                    if i < stage {
                        Image(systemName: "checkmark").font(.system(size: 15, weight: .bold)).foregroundStyle(Desk.good)
                    } else if i == stage {
                        ProgressView().controlSize(.small)
                    }
                }
                .padding(.horizontal, 17)
                .padding(.vertical, 13)
                if i < Self.stages.count - 1 { Rectangle().fill(Desk.hairline).frame(height: 0.5) }
            }
        }
        .deskCard()

        Button(details ? "隱藏詳細資訊" : "顯示詳細資訊") { withAnimation { details.toggle() } }
            .font(.system(size: 15, weight: .semibold))
            .foregroundStyle(Desk.accentLight)
            .padding(.top, 14)
        if details {
            VStack(spacing: 12) {
                if case .installing = installer.phase {
                    BootDisplay(display: display, role: .device)
                        .aspectRatio(16.0 / 10.0, contentMode: .fit)
                        .clipShape(RoundedRectangle(cornerRadius: 15, style: .continuous))
                }
                LogTail()
            }
            .padding(14)
            .deskCard()
            .padding(.top, 10)
        }
    }

    private func finished(_ text: String) -> some View {
        VStack(spacing: 14) {
            Image(systemName: "checkmark.circle.fill").font(.system(size: 54)).foregroundStyle(Desk.good).padding(.top, 8)
            Text("安裝完成").font(.system(size: 24, weight: .bold))
            Text(text).font(.system(size: 15)).foregroundStyle(Desk.dim).multilineTextAlignment(.center)
        }
        .padding(20)
        .frame(maxWidth: .infinity)
        .deskCard(radius: 30)
        .padding(.top, 8)
    }

    @ViewBuilder private func failed(_ text: String) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("安裝未完成").font(.system(size: 22, weight: .bold))
            Text(text).font(.system(size: 15))
            Text("請從多工上滑完全關閉 Henge 再重開後重試（每次開啟僅能初始化一次安裝）。")
                .font(.system(size: 13)).foregroundStyle(Desk.dim)
            Button("返回") { installer.reset() }.buttonStyle(DeskButtonStyle()).padding(.top, 6)
        }
        .padding(18)
        .deskCard(radius: 30)
        .padding(.top, 8)
        DeskHeading("日誌")
        LogTail().padding(14).frame(maxWidth: .infinity, alignment: .leading).deskCard()
    }
}

/// The last lines of Henge's log.
private struct LogTail: View {
    @State private var lines: [String] = []

    var body: some View {
        VStack(alignment: .leading, spacing: 1) {
            ForEach(Array(lines.enumerated()), id: \.offset) { _, line in
                Text(line).font(.system(size: 9, design: .monospaced)).foregroundStyle(.secondary).lineLimit(2)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .task {
            while !Task.isCancelled {
                lines = Array(HengeLog.recentLines(14))
                try? await Task.sleep(nanoseconds: 1_000_000_000)
            }
        }
    }
}
