import SwiftUI
import UniformTypeIdentifiers

/// One Mac: what it has, and what can be done with it.
struct MacSettingsView: View {
    private enum ManageDialog {
        case confirmEject
        case confirmDelete
    }

    @ObservedObject private var machines = Machines.shared
    @Environment(\.dismiss) private var dismiss
    @State private var mac: VirtualMac
    @State private var activeDialog: ManageDialog?
    @State private var movingExport = false
    @State private var pickingReconnect = false
    @State private var removed = false

    init(mac: VirtualMac) { _mac = State(initialValue: mac) }

    private var hardwareLocked: Bool {
        machines.deleting != nil || machines.moving != nil || Machines.isVMRunning
    }

    private var dialogTitle: String {
        switch activeDialog {
        case .confirmEject:
            return "確定要安全退出「\(mac.name)」嗎？"
        case .confirmDelete:
            return mac.isExternal ? "永久刪除 SSD 中的「\(mac.name)」？" : "確定要刪除「\(mac.name)」嗎？"
        case .none:
            return ""
        }
    }

    var body: some View {
        ScrollView {
            VStack(spacing: 0) {
                if let err = machines.lastError {
                    Button { machines.lastError = nil } label: {
                        NoticeRow(symbol: "exclamationmark.triangle.fill", text: err, trailing: "關閉", tint: Desk.bad)
                    }
                    .padding(.top, 12)
                }

                if Machines.isVMRunning {
                    NoticeRow(symbol: "info.circle.fill", text: "虛擬機目前執行中，請先關機後再調整記憶體、CPU 與磁碟設定。", trailing: nil, tint: Desk.warn)
                        .padding(.top, 12)
                }

                DeskHeading("名稱")
                TextField("名稱", text: $mac.name)
                    .font(.system(size: 16))
                    .submitLabel(.done)
                    .disabled(machines.deleting != nil || machines.moving != nil)
                    .padding(.horizontal, 17)
                    .padding(.vertical, 14)
                    .deskCard()
                    .onSubmit(save)

                if mac.isExternal {
                    DeskHeading("隨身 SSD 自動適配")
                    VStack(alignment: .leading, spacing: 10) {
                        Toggle("自動依此 \(Device.name) 調整 RAM 與螢幕", isOn: Binding(
                            get: { mac.adaptsToHost },
                            set: {
                                mac.autoAdaptToHost = $0
                                save()
                            }
                        ))
                        .font(.system(size: 16))
                        .disabled(hardwareLocked)
                        Text("開啟時，插到不同機型 iPad 會自動以安全上限（這台 \(Device.name) 為 \(Device.suggestedRAMGB) GB、\(Device.maxSafeCPUs) 核心）與滿版螢幕啟動；隨時可關閉或在下方手動覆寫。")
                            .font(.system(size: 13)).foregroundStyle(Desk.dim)
                    }
                    .padding(17)
                    .deskCard()
                }

                DeskHeading("記憶體")
                VStack(alignment: .leading, spacing: 12) {
                    let currentRAMGB = min(
                        max(Device.memoryChoices.lowerBound, (mac.adaptsToHost ? mac.effectiveRAMMB : mac.ramMB) / 1024),
                        Device.memoryChoices.upperBound
                    )
                    HStack(alignment: .firstTextBaseline) {
                        Text(mac.adaptsToHost ? "自動 · \(currentRAMGB) GB" : "\(currentRAMGB) GB")
                            .font(.system(size: 26, weight: .bold))
                        Spacer()
                        Text(Entitlements.increasedMemory ? "開啟 JIT 後不受 App 記憶體上限限制" : "尚未解鎖 Apple 大記憶體權限")
                            .font(.system(size: 13))
                            .foregroundStyle(Entitlements.increasedMemory ? Desk.dim : Desk.warn)
                            .multilineTextAlignment(.trailing)
                    }
                    Stepper(
                        "記憶體容量",
                        value: Binding(
                            get: { currentRAMGB },
                            set: { newGB in
                                mac.autoAdaptToHost = false
                                mac.ramMB = newGB * 1024
                                save()
                            }
                        ),
                        in: Device.memoryChoices
                    )
                    .font(.system(size: 16))
                    .disabled(hardwareLocked)

                    HStack(spacing: 8) {
                        ForEach(Device.quickRAMChoicesGB, id: \.self) { gb in
                            let selected = !mac.adaptsToHost && (mac.ramMB / 1024 == gb)
                            Button("\(gb) GB") {
                                mac.autoAdaptToHost = false
                                mac.ramMB = gb * 1024
                                save()
                            }
                            .font(.system(size: 13, weight: .semibold))
                            .padding(.horizontal, 12)
                            .padding(.vertical, 6)
                            .background(selected ? Desk.accent : Desk.raised.opacity(0.6), in: Capsule())
                            .foregroundStyle(selected ? Color.white : Desk.text)
                            .disabled(hardwareLocked)
                        }
                    }

                    if let note = Device.memoryNote(currentRAMGB) {
                        Text(note).font(.system(size: 13)).foregroundStyle(Desk.dim)
                    } else {
                        Text("調整後會自動儲存，下次開機立即套用（這台 \(Device.name) 實體記憶體共 \(Device.physicalMemoryGB) GB）。")
                            .font(.system(size: 13)).foregroundStyle(Desk.dim)
                    }

                    Button {
                        MoreRamCoordinator.shared.showSheet = true
                    } label: {
                        Label(
                            Entitlements.increasedMemory ? "最大記憶體已自動啟用 · 查看狀態" : "一鍵自動解鎖最大記憶體…",
                            systemImage: "memorychip"
                        )
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundStyle(Entitlements.increasedMemory ? Desk.accentLight : Desk.warn)
                    }
                }
                .padding(17)
                .deskCard()

                DeskHeading("處理器")
                VStack(alignment: .leading, spacing: 12) {
                    let currentCPUs = mac.effectiveCPUs
                    Stepper(
                        value: Binding(
                            get: { currentCPUs },
                            set: { newCPUs in
                                mac.autoAdaptToHost = false
                                mac.cpuCount = max(1, min(Device.maxCPUCount, newCPUs))
                                save()
                            }
                        ),
                        in: 1...Device.maxCPUCount
                    ) {
                        HStack {
                            Text("CPU 核心數").font(.system(size: 16))
                            Spacer()
                            Text(mac.adaptsToHost ? "自動 · \(currentCPUs) 核心" : "\(currentCPUs) 核心")
                                .font(.system(size: 16, weight: .semibold))
                        }
                    }
                    .disabled(hardwareLocked)

                    HStack(spacing: 8) {
                        ForEach(Device.quickCPUChoices, id: \.self) { count in
                            let selected = !mac.adaptsToHost && currentCPUs == count
                            Button("\(count) 核心") {
                                mac.autoAdaptToHost = false
                                mac.cpuCount = count
                                save()
                            }
                            .font(.system(size: 13, weight: .semibold))
                            .padding(.horizontal, 12)
                            .padding(.vertical, 6)
                            .background(selected ? Desk.accent : Desk.raised.opacity(0.6), in: Capsule())
                            .foregroundStyle(selected ? Color.white : Desk.text)
                            .disabled(hardwareLocked)
                        }
                    }

                    Text("專屬此 Mac 的設定（此 \(Device.name) 最高支援 \(Device.maxCPUCount) 核心），在關機狀態下調整後將於下次開機自動套用。")
                        .font(.system(size: 13)).foregroundStyle(Desk.dim)
                }
                .padding(17)
                .deskCard()

                DeskHeading("關於這台 Mac")
                VStack(alignment: .leading, spacing: 12) {
                    Toggle(isOn: Binding(get: { mac.reportHostIdentity ?? false }, set: {
                        mac.reportHostIdentity = $0
                        if !$0 { mac.reportHostModelID = false }
                        save()
                    })) {
                        Text("回報此 \(Device.name) 裝置名稱").font(.system(size: 16))
                    }
                    .disabled(machines.deleting != nil || machines.moving != nil)
                    Text("macOS 內會顯示為 \(Device.marketingName)\(Device.chipName.map { "（\($0) 晶片）" } ?? "")。於下次開機生效。")
                        .font(.system(size: 13)).foregroundStyle(Desk.dim)
                    if mac.reportHostIdentity == true {
                        Toggle(isOn: Binding(get: { mac.reportHostModelID ?? false }, set: { mac.reportHostModelID = $0; save() })) {
                            Text("同時回報機型識別碼").font(.system(size: 16))
                        }
                        .disabled(machines.deleting != nil || machines.moving != nil)
                        Text("傳送 \(Device.snappedModelIdentifier(forOS: mac.osName)) 以顯示對應裝置圖示，名稱仍為 \(Device.marketingName)。實驗性選項：部分系統功能會依據機型判斷。")
                            .font(.system(size: 13)).foregroundStyle(Desk.dim)
                    }
                }
                .padding(17)
                .deskCard()

                if Device.fittingScreen.height != 1080 {
                    DeskHeading("螢幕")
                    VStack(alignment: .leading, spacing: 12) {
                        if mac.adaptsToHost {
                            if Device.isPad {
                                Toggle("Retina 高解析度", isOn: Binding(get: { mac.isRetina }, set: { mac.retina = $0; save() }))
                                    .font(.system(size: 16))
                                    .disabled(machines.deleting != nil || machines.moving != nil)
                            }
                            Text("目前依此 \(Device.name) 自動設定為 \(mac.screen.width) × \(mac.screen.height)。關閉上方「隨身 SSD 自動適配」可改為手動鎖定解析度。下次開機生效。")
                                .font(.system(size: 13)).foregroundStyle(Desk.dim)
                        } else {
                            Picker("螢幕解析度", selection: Binding(get: {
                                if mac.isRetina { return "retina" }
                                if mac.screen.width == Device.performanceScreen.width,
                                   mac.screen.height == Device.performanceScreen.height { return "performance" }
                                if mac.screen.width == 1920, mac.screen.height == 1080 { return "wide" }
                                return "fit"
                            }, set: { choice in
                                mac.retina = choice == "retina"
                                switch choice {
                                case "retina": break
                                case "performance": (mac.screenWidth, mac.screenHeight) = Device.performanceScreen
                                case "wide": (mac.screenWidth, mac.screenHeight) = (1920, 1080)
                                default: (mac.screenWidth, mac.screenHeight) = Device.fittingScreen
                                }
                                save()
                            })) {
                                if Device.isPad {
                                    Text("Retina").tag("retina")
                                    Text("效能模式").tag("performance")
                                }
                                Text("符合螢幕").tag("fit")
                                Text("16:9").tag("wide")
                            }
                            .pickerStyle(.segmented)
                            .disabled(machines.deleting != nil || machines.moving != nil)
                            Text("\(mac.screen.width) × \(mac.screen.height)。\(Device.isPad ? "「效能模式」可減少約 30% GPU 繪圖負荷。" : "")下次開機生效。")
                                .font(.system(size: 13)).foregroundStyle(Desk.dim)
                        }
                    }
                    .padding(17)
                    .deskCard()
                }

                DeskHeading("儲存位置")
                VStack(alignment: .leading, spacing: 11) {
                    HStack {
                        Text(mac.isExternal ? "外接 SSD（\(mac.externalDriveName ?? "外接硬碟")）" : "存放在此 \(Device.name) 本機")
                            .font(.system(size: 15, weight: .semibold))
                        Spacer()
                        if mac.isExternal {
                            Text(mac.isAvailable ? "已連接" : "未連接")
                                .font(.system(size: 13, weight: .semibold))
                                .foregroundStyle(mac.isAvailable ? Desk.good : Desk.bad)
                        }
                    }
                    if mac.isAvailable {
                        HStack {
                            Text("已使用 \(ByteText.string(UInt64(max(mac.bytesUsed, 0))))").font(.system(size: 16))
                            Spacer()
                            Text("上限 \(ByteText.string(UInt64(max(mac.diskBytes, 0))))").font(.system(size: 16)).foregroundStyle(Desk.dim)
                        }
                        DeskBar(fraction: Double(mac.bytesUsed) / Double(max(mac.diskBytes, 1)))
                        if let movingName = machines.moving {
                            VStack(alignment: .leading, spacing: 6) {
                                Text("正在搬移「\(movingName)」… \(Int(machines.moved * 100))%（請保持 Henge 開啟）")
                                    .font(.system(size: 13))
                                    .foregroundStyle(Desk.dim)
                                DeskBar(fraction: machines.moved)
                            }
                            .padding(.top, 4)
                        } else if mac.isExternal {
                            Button("搬回此 \(Device.name) 本機空間") {
                                save()
                                machines.moveStorage(mac, toExternal: false) { updated in
                                    mac = updated
                                }
                            }
                            .font(.system(size: 15, weight: .semibold))
                            .foregroundStyle(Desk.accentLight)
                            .disabled(machines.isBusy || Machines.isVMRunning)
                            .padding(.top, 4)
                        } else if ExternalInstallStorage.shared.isConfigured && ExternalInstallStorage.shared.isConnected {
                            Button("搬移至外接 SSD（\(ExternalInstallStorage.shared.configuredName ?? "外接硬碟")）") {
                                save()
                                machines.moveStorage(mac, toExternal: true) { updated in
                                    mac = updated
                                }
                            }
                            .font(.system(size: 15, weight: .semibold))
                            .foregroundStyle(Desk.accentLight)
                            .disabled(machines.isBusy || Machines.isVMRunning)
                            .padding(.top, 4)
                        }
                    } else {
                        Text("請先插上「\(mac.externalDriveName ?? "外接硬碟")」來讀取磁碟，或點選下方重新指定資料夾。")
                            .font(.system(size: 13))
                            .foregroundStyle(Desk.bad)
                        Button("重新連接外接 SSD 資料夾…") {
                            pickingReconnect = true
                        }
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundStyle(Desk.accentLight)
                    }
                    if mac.isExternal {
                        Text("拔除 USB-C 外接 SSD 前，請先將 macOS 關機並執行下方「安全退出」，以免磁碟損毀。")
                            .font(.system(size: 13)).foregroundStyle(Desk.dim)
                    }
                }
                .padding(17)
                .deskCard()

                DeskHeading("管理與退出")
                manage
            }
            .padding(.horizontal, 16)
            .padding(.bottom, 24)
            .deskColumn()
        }
        .background(Desk.page)
        .navigationTitle(mac.name)
        .navigationBarTitleDisplayMode(.inline)
        .onDisappear(perform: save)
        .fileImporter(isPresented: $pickingReconnect, allowedContentTypes: [.folder]) { result in
            if case let .success(url) = result {
                if machines.reconnectExternal(mac, to: url),
                   let updated = machines.all.first(where: { $0.id == mac.id }) {
                    mac = updated
                }
            }
        }
        .fileMover(isPresented: $movingExport, file: machines.lastExport) { result in
            switch result {
            case .success: machines.lastExport = nil
            case .failure(let error): machines.lastError = error.localizedDescription
            }
        }
        .confirmationDialog(
            dialogTitle,
            isPresented: Binding(get: { activeDialog != nil }, set: { if !$0 { activeDialog = nil } }),
            titleVisibility: .visible,
            presenting: activeDialog
        ) { dialog in
            switch dialog {
            case .confirmEject:
                Button("安全退出（保留 SSD 資料）") {
                    if machines.ejectExternalMac(mac.id) {
                        removed = true
                        dismiss()
                    }
                }
            case .confirmDelete:
                Button(mac.isExternal ? "從 SSD 永久刪除（\(ByteText.string(UInt64(max(mac.bytesUsed, 0))))）" : "永久刪除", role: .destructive) {
                    machines.deleteMacAsync(mac.id, deleteExternalFiles: true) { ok in
                        if ok {
                            removed = true
                            dismiss()
                        }
                    }
                }
            }
        } message: { dialog in
            switch dialog {
            case .confirmEject:
                Text("只會從這台 \(Device.name) 卸載紀錄並釋放存取權限，外接 SSD 內的 macOS 與所有資料都會完整保留，之後插上可隨時重新掛載。")
            case .confirmDelete:
                if mac.isExternal {
                    Text("只會刪除「\(mac.name)」在「\(mac.externalDriveName ?? "外接硬碟")」上的虛擬機檔案，SSD 內其他個人檔案不會受到影響。此動作無法復原。")
                } else {
                    Text("將永久移除此 \(Device.name) 上此虛擬 Mac 的所有磁碟檔案，此動作無法復原。")
                }
            }
        }
    }

    private var manage: some View {
        VStack(spacing: 0) {
            if let deletingName = machines.deleting {
                HStack(spacing: 10) {
                    ProgressView().controlSize(.small)
                    Text("正在安全清除「\(deletingName)」…").font(.system(size: 15)).foregroundStyle(Desk.dim)
                    Spacer()
                }
                .padding(17)
                divider
            }
            if let name = machines.exporting {
                VStack(alignment: .leading, spacing: 9) {
                    Text("正在匯出「\(name)」… 請保持 Henge 開啟").font(.system(size: 15))
                    DeskBar(fraction: machines.exported)
                }
                .padding(17)
            } else if !mac.isExternal || mac.isAvailable {
                row("匯出打包", symbol: "square.and.arrow.up", tint: Desk.accentLight) { machines.export(mac) }
                    .disabled(machines.isBusy || Machines.isVMRunning)
            }
            if let folder = machines.lastExport {
                divider
                VStack(alignment: .leading, spacing: 8) {
                    Text("已儲存於「檔案 › 我的 iPad/iPhone › Henge › Exports › \(folder.lastPathComponent)」。刪除 App 會一併清除該資料夾，請先移至其他位置。")
                        .font(.system(size: 13)).foregroundStyle(Desk.dim)
                    Button("移出 Henge 資料夾…") { movingExport = true }
                        .font(.system(size: 15, weight: .semibold)).foregroundStyle(Desk.accentLight)
                }
                .padding(17)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            if !mac.isExternal || mac.isAvailable || machines.exporting != nil || machines.lastExport != nil {
                divider
            }
            if mac.isExternal {
                row("安全退出（保留 SSD 資料）", symbol: "eject", tint: Desk.accentLight) {
                    activeDialog = .confirmEject
                }
                .disabled(machines.isBusy || Machines.isVMRunning)
                if mac.isAvailable {
                    divider
                    row("從 SSD 永久刪除此 Mac…", symbol: "trash", tint: Desk.bad) {
                        activeDialog = .confirmDelete
                    }
                    .disabled(machines.isBusy || Machines.isVMRunning)
                }
            } else {
                row("刪除這台 Mac…", symbol: "trash", tint: Desk.bad) {
                    activeDialog = .confirmDelete
                }
                .disabled(machines.isBusy || Machines.isVMRunning)
            }
        }
        .deskCard()
    }

    private var divider: some View { Rectangle().fill(Desk.hairline).frame(height: 0.5) }

    private func row(_ title: String, symbol: String?, tint: Color, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack {
                Text(title).font(.system(size: 16)).foregroundStyle(tint)
                Spacer()
                if let symbol { Image(systemName: symbol).foregroundStyle(tint) }
            }
            .padding(.horizontal, 17)
            .padding(.vertical, 14)
            .contentShape(Rectangle())
        }
    }

    private func save() {
        guard !removed, machines.deleting == nil, machines.moving == nil else { return }
        if mac.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { mac.name = "Mac" }
        guard let current = machines.all.first(where: { $0.id == mac.id }), current != mac else { return }
        if current.ramMB != mac.ramMB || current.cpuCount != mac.cpuCount || current.autoAdaptToHost != mac.autoAdaptToHost {
            InstantResume.discard(for: mac)
        }
        machines.update(mac)
    }
}
