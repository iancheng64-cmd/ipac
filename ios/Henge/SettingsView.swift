import SwiftUI
import UniformTypeIdentifiers

struct SettingsView: View {
    private enum SSDDialog {
        case confirmEject
        case confirmClear(ExternalDriveHengeSummary)
    }

    @ObservedObject private var jit = JITCoordinator.shared
    @ObservedObject private var extStorage = ExternalInstallStorage.shared
    @ObservedObject private var machines = Machines.shared
    @AppStorage(JITCoordinator.autoEnableKey) private var jitAtLaunch = false
    @AppStorage(HardwareMouse.speedKey) private var mouseSpeed = 1.0
    @AppStorage(HardwareMouse.reverseKey) private var reverseScrolling = false
    @AppStorage(HardwareMouse.scrollSpeedKey) private var scrollSpeed = 0.3
    @AppStorage(VolumeClicks.inputModeKey) private var inputMode = VolumeClicks.InputMode.touchscreen
    @AppStorage(VolumeClicks.modeKey) private var volumeMode = VolumeClicks.Mode.delayHold
    @AppStorage(VolumeClicks.swapKey) private var swapButtons = false
    @AppStorage(PhysicalMouseButtons.swapKey) private var swapMouseButtons = false
    @AppStorage(EngineTuning.refreshKey) private var refreshRate = 60
    @AppStorage(EngineTuning.fastFlushKey) private var fastFlush = true
    @AppStorage(EngineTuning.pCoreQosKey) private var pCoreQos = true
    @AppStorage(EngineTuning.wfiSpinKey) private var wfiSpin = false
    @AppStorage(EngineTuning.superblocksKey) private var superblocks = false
    @AppStorage(JITBootstrap.codeCacheKey) private var codeCacheMB = JITBootstrap.defaultCodeCacheMB
    @AppStorage(DeskAppearance.key) private var appearance = DeskAppearance.system
    @AppStorage(InstantResume.key) private var instantResume = false
    @AppStorage(MacAppsFeature.key) private var macApps = false
    @State private var pickingExternalFolder = false
    @State private var ssdDialog: SSDDialog?

    private var inputDescription: String {
        if inputMode == .touchscreen {
            return "單指輕點為左鍵點擊；輕點後按住即可開始拖曳；兩指快速輕點為右鍵點擊。"
        }
        switch volumeMode {
        case .delayHold:
            return "「延遲長按」會偵測您是短按或長按音量鍵，所有點擊約為 0.5 秒。"
        case .tapThenDrag:
            return "「先點後拖」可縮短一般點擊反應時間，但開始按住拖曳前會先送出一次單擊。"
        case .intercept:
            return "透過啟用相機管線完整攔截音量鍵事件，行為最接近真實滑鼠按鍵，但機身溫度會略為上升。"
        }
    }

    private var ssdDialogTitle: String {
        switch ssdDialog {
        case .confirmEject:
            return "確定要安全退出外接 SSD 嗎？"
        case .confirmClear(let summary):
            return "確定清除「\(summary.driveName)」上的 Henge 資料？"
        case .none:
            return ""
        }
    }

    var body: some View {
        NavigationStack {
            Form {
                Section("JIT 加速引擎") {
                    LabeledContent("狀態", value: JITBootstrap.ready ? "已開啟" : "未開啟")
                    Picker("啟用方式", selection: $jit.method) {
                        ForEach(JITMethod.allCases) { Text($0.title).tag($0) }
                    }
                    Text(jit.method == .automatic ? jit.automaticDescription : "Henge 將使用「\(jit.method.title)」。")
                        .font(.footnote).foregroundStyle(.secondary)
                    Button("設定 JIT") { jit.showSetup = true }
                    Toggle("開啟 Henge 時自動啟用 JIT", isOn: $jitAtLaunch)
                    if jitAtLaunch {
                        Text("若 LocalDevVPN 尚未連線，Henge 會自動開啟 VPN 連線後返回。")
                            .font(.footnote).foregroundStyle(.secondary)
                    }
                    LabeledContent("程式碼快取保留區", value: "\(JITBootstrap.jitBytes >> 20) MB（每次啟動配給）")
                }
                .listRowBackground(Desk.card)
                Section("記憶體配額") {
                    LabeledContent("額外記憶體擴充", value: Entitlements.increasedMemory ? "已啟用" : "未啟用")
                    LabeledContent("App 上限", value: ByteText.string(UInt64(Entitlements.memoryLimitAtLaunch)))
                    LabeledContent("可用記憶體空間", value: ByteText.string(UInt64(henge_available_memory())))
                    Text(Entitlements.increasedMemory
                         ? "開啟 JIT 後，虛擬 Mac 記憶體可獨立於 App 記憶體上限之外配置；若遭系統拒絕則改由儲存空間緩衝。"
                         : "目前憑證未包含額外記憶體權限（Increased Memory Limit），建議使用支援此權限的憑證重新簽署安裝。")
                        .font(.footnote).foregroundStyle(.secondary)
                }
                .listRowBackground(Desk.card)
                if Device.isPad {
                    Section("滑鼠與觸控板") {
                        VStack(alignment: .leading, spacing: 4) {
                            Text("游標移動速度")
                            Slider(value: $mouseSpeed, in: 0.5...3)
                        }
                        Toggle("自然捲動方向（反轉捲動）", isOn: $reverseScrolling)
                        VStack(alignment: .leading, spacing: 4) {
                            Text("滾輪捲動速度")
                            Slider(value: $scrollSpeed, in: 0.1...1.5)
                        }
                        Toggle("對調實體滑鼠右鍵與中鍵", isOn: $swapMouseButtons)
                        Text("僅在部分第三方滑鼠右鍵與中鍵功能相反時開啟（觸控螢幕手勢不受影響）。需重新啟動 Mac 生效。")
                            .font(.footnote).foregroundStyle(.secondary)
                        Text("外接巧控鍵盤或藍牙滑鼠可直接移動 Mac 游標。游標速度於下次啟動生效，捲動速度立即生效。")
                            .font(.footnote).foregroundStyle(.secondary)
                    }
                    .listRowBackground(Desk.card)
                }
                if !Device.isPad {
                    Section("觸控板操作") {
                        Picker("點擊方式", selection: $inputMode) {
                            Text("觸控螢幕").tag(VolumeClicks.InputMode.touchscreen)
                            Text("音量鍵控制").tag(VolumeClicks.InputMode.volumeButtons)
                        }
                        .pickerStyle(.menu)
                        if inputMode == .volumeButtons {
                            Picker("按鍵模式", selection: $volumeMode) {
                                Text("延遲長按").tag(VolumeClicks.Mode.delayHold)
                                Text("先點後拖").tag(VolumeClicks.Mode.tapThenDrag)
                                Text("相機攔截模式").tag(VolumeClicks.Mode.intercept)
                            }
                            .pickerStyle(.menu)
                            Toggle("對調音量鍵左右功能", isOn: $swapButtons)
                        }
                        Text("Henge 可將螢幕模擬為 Magic Trackpad 支援原生 macOS 多指手勢。\n\n\(inputDescription)")
                            .font(.footnote).foregroundStyle(.secondary)
                    }
                    .listRowBackground(Desk.card)
                }
                Section("效能與引擎調整") {
                    Picker("Mac 更新率", selection: $refreshRate) {
                        Text("30 Hz").tag(30)
                        Text("60 Hz").tag(60)
                        Text("120 Hz").tag(120)
                    }
                    .pickerStyle(.segmented)
                    Toggle("優先排程至 Apple M 系列效能核心", isOn: $pCoreQos)
                    Toggle("加快虛擬磁碟寫入速度", isOn: $fastFlush)
                    Toggle("更快從閒置狀態喚醒（微幅增加耗電）", isOn: $wfiSpin)
                    Toggle("Superblocks 轉譯最佳化（實驗性）", isOn: $superblocks)
                    Picker("JIT 指令快取大小", selection: $codeCacheMB) {
                        Text("512 MB").tag(512)
                        Text("1 GB").tag(1024)
                        Text("1.5 GB").tag(1536)
                    }
                    Text("較大的指令快取可減少重譯次數並提升流暢度，需重開 Henge 生效；若較小記憶體機型無法啟用 JIT 請調低此值。")
                        .font(.footnote).foregroundStyle(.secondary)
                    Text("30 Hz 最省效能、60 Hz 最流暢（非 120 Hz 機型會自動限制於 60 Hz）。以上設定將於下次啟動 Mac 時套用。")
                        .font(.footnote).foregroundStyle(.secondary)
                }
                .listRowBackground(Desk.card)
                Section("即時續玩（背景凍結儲存）") {
                    Toggle("離開時自動保存執行狀態", isOn: $instantResume)
                    Text("切換至背景時會自動把目前 Mac 狀態壓縮寫入儲存空間，即使 iOS 回收 Henge 也可於幾秒內接續剛剛的畫面（實驗性）。")
                        .font(.footnote).foregroundStyle(.secondary)
                }
                .listRowBackground(Desk.card)
                Section("Mac App 獨立執行（實驗性）") {
                    Toggle("啟用免開 macOS 直接執行功能", isOn: $macApps)
                    Text("開啟後可在首頁右上角「＋」直接匯入 .dmg 或 .app，目前支援命令列工具（視窗軟體仍在開發中）。")
                        .font(.footnote).foregroundStyle(.secondary)
                }
                .listRowBackground(Desk.card)
                Section("外觀") {
                    Picker("主題外觀", selection: $appearance) {
                        ForEach(DeskAppearance.allCases) { Text($0.title).tag($0) }
                    }
                    .pickerStyle(.segmented)
                    Text("「跟隨系統」會隨 \(Device.name) 的淺色／深色設定切換；執行 Mac 畫面期間固定為深色。")
                        .font(.footnote).foregroundStyle(.secondary)
                }
                .listRowBackground(Desk.card)
                Section("外接 SSD 管理與硬體設定") {
                    LabeledContent("安裝儲存模式", value: extStorage.mode.shortTitle)
                    if extStorage.isConfigured {
                        LabeledContent("已綁定外接資料夾", value: extStorage.configuredName ?? "外接 SSD")
                        LabeledContent("連線狀態", value: extStorage.isConnected ? "已連接\(extStorage.filesystemType.map { "（\($0)）" } ?? "")" : "未連接")
                        if extStorage.isConnected {
                            LabeledContent("SSD 可用空間", value: ByteText.string(UInt64(max(extStorage.freeBytes, 0))))
                        }
                    } else if let mountedExt = machines.all.first(where: \.isExternal) {
                        LabeledContent("已掛載隨身硬碟", value: mountedExt.externalDriveName ?? "外接 SSD")
                        LabeledContent("連線狀態", value: mountedExt.isAvailable ? "已連接" : "未連接")
                    }
                    Button("選擇／變更外接 SSD 資料夾…") {
                        pickingExternalFolder = true
                    }
                    .disabled(extStorage.isClearing || machines.isBusy || Machines.isVMRunning)

                    if extStorage.isConfigured || machines.all.contains(where: \.isExternal) {
                        Button {
                            ssdDialog = .confirmEject
                        } label: {
                            Label("安全退出 SSD（保留所有資料）", systemImage: "eject")
                        }
                        .disabled(extStorage.isClearing || machines.isBusy || Machines.isVMRunning)
                    }

                    if extStorage.canClearDrive {
                        Button(role: .destructive) {
                            if let summary = extStorage.inspectHengeDataOnDrive() {
                                ssdDialog = .confirmClear(summary)
                            }
                        } label: {
                            Label("清除 SSD 上的 Henge 資料…", systemImage: "trash")
                        }
                        .disabled(extStorage.isClearing || machines.isBusy || Machines.isVMRunning)
                    }

                    if extStorage.isClearing {
                        HStack(spacing: 10) {
                            ProgressView().controlSize(.small)
                            Text("正在清除 SSD 上的 Henge 資料…").font(.footnote).foregroundStyle(.secondary)
                        }
                    }
                    if let msg = extStorage.statusMessage {
                        Text(msg).font(.footnote).foregroundStyle(Desk.good)
                    }
                    if let err = extStorage.lastError {
                        Text(err).font(.footnote).foregroundStyle(Desk.bad)
                    }
                    LabeledContent("硬體識別規格", value: "\(Device.marketingName) (\(Device.chipName ?? "arm64"))")
                    LabeledContent("版本", value: "0.3.0 (Build 106 • iPac 繁體中文・可攜式 SSD)")
                }
                .listRowBackground(Desk.card)
                Section("診斷日誌") {
                    ShareLink(item: HengeLog.logFileURL) { Label("分享 henge.log 紀錄檔", systemImage: "square.and.arrow.up") }
                }
                .listRowBackground(Desk.card)
            }
            .scrollContentBackground(.hidden)
            .background(Desk.page)
            .navigationTitle("設定")
            .fileImporter(isPresented: $pickingExternalFolder, allowedContentTypes: [.folder]) { result in
                if case let .success(url) = result {
                    _ = extStorage.selectFolder(url)
                }
            }
            .confirmationDialog(
                ssdDialogTitle,
                isPresented: Binding(get: { ssdDialog != nil }, set: { if !$0 { ssdDialog = nil } }),
                titleVisibility: .visible,
                presenting: ssdDialog
            ) { dialog in
                switch dialog {
                case .confirmEject:
                    Button("安全退出 SSD（保留所有資料）") {
                        _ = extStorage.safeEjectDrive()
                    }
                case .confirmClear(let summary):
                    Button(
                        summary.totalBytes > 0
                            ? "只清除 Henge 資料（釋放 \(ByteText.string(UInt64(summary.totalBytes)))）"
                            : "確認清除 Henge 資料",
                        role: .destructive
                    ) {
                        extStorage.clearAllHengeDataOnDrive()
                    }
                }
            } message: { dialog in
                switch dialog {
                case .confirmEject:
                    Text("會確認目前無執行中的虛擬機或檔案傳輸，釋放 Henge 對「\(extStorage.effectiveDriveName)」的存取權限與掛載紀錄。外接 SSD 內的系統與所有個人資料都會完整保留，之後插到這台或別台 iPad 皆可隨時重新開啟。")
                case .confirmClear(let summary):
                    if summary.isEmpty {
                        Text("目前在「\(summary.driveName)」找不到 Henge 虛擬機或暫存安裝檔；您 SSD 內的其他個人檔案皆不受影響。")
                    } else {
                        Text("只會刪除「\(summary.driveName)」上的 Henge 資料（共 \(summary.machineCount) 台 Mac\(summary.hasInstallFiles ? "、含安裝暫存檔 HengeInstall" : "")，約釋放 \(ByteText.string(UInt64(summary.totalBytes)))）。您 SSD 內的其他個人檔案皆會完整保留。此動作無法復原。")
                    }
                }
            }
        }
    }
}
