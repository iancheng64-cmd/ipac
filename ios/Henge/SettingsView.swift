import SwiftUI
import UniformTypeIdentifiers

struct SettingsView: View {
    @Environment(\.locale) private var interfaceLocale
    private enum SSDDialog {
        case confirmEject
        case confirmClear(ExternalDriveHengeSummary)
    }

    @ObservedObject private var jit = JITCoordinator.shared
    @ObservedObject private var extStorage = ExternalInstallStorage.shared
    @ObservedObject private var machines = Machines.shared
    @ObservedObject private var moreRam = MoreRamCoordinator.shared
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
    @AppStorage(EngineTuning.compactJitMetadataKey) private var compactJitMetadata = false
    @AppStorage(JITBootstrap.codeCacheKey) private var codeCacheMB = JITBootstrap.defaultCodeCacheMB
    @AppStorage(DeskAppearance.key) private var appearance = DeskAppearance.system
    @AppStorage(AppLanguage.storageKey) private var interfaceLanguage = AppLanguage.current.rawValue
    @AppStorage(InstantResume.key) private var instantResume = false
    @AppStorage(MacAppsFeature.key) private var macApps = false
    @State private var pickingExternalFolder = false
    @State private var ssdDialog: SSDDialog?

    private var languageSelection: Binding<String> {
        Binding(
            get: { (AppLanguage(rawValue: interfaceLanguage) ?? .zhHant).rawValue },
            set: { interfaceLanguage = $0 }
        )
    }

    private var inputDescription: String {
        if inputMode == .touchscreen {
            return L10n.text("單指輕點為左鍵點擊；輕點後按住即可開始拖曳；兩指快速輕點為右鍵點擊。")
        }
        switch volumeMode {
        case .delayHold:
            return L10n.text("「延遲長按」會偵測您是短按或長按音量鍵，所有點擊約為 0.5 秒。")
        case .tapThenDrag:
            return L10n.text("「先點後拖」可縮短一般點擊反應時間，但開始按住拖曳前會先送出一次單擊。")
        case .intercept:
            return L10n.text("透過啟用相機管線完整攔截音量鍵事件，行為最接近真實滑鼠按鍵，但機身溫度會略為上升。")
        }
    }

    private var ssdDialogTitle: String {
        switch ssdDialog {
        case .confirmEject:
            return L10n.text("確定要安全退出外接 SSD 嗎？")
        case .confirmClear(let summary):
            return L10n.format("確定清除「%@」上的 Henge 資料？", String(describing: summary.driveName))
        case .none:
            return ""
        }
    }

    var body: some View {
        let _ = interfaceLocale
        NavigationStack {
            Form {
                Section(L10n.text("介面語言")) {
                    Picker(L10n.text("語言"), selection: languageSelection) {
                        Text(verbatim: "繁體中文").tag(AppLanguage.zhHant.rawValue)
                        Text(verbatim: "English").tag(AppLanguage.en.rawValue)
                    }
                    .pickerStyle(.segmented)
                    .accessibilityIdentifier("interface-language-picker")
                }
                .listRowBackground(Desk.card)
                Section(L10n.text("JIT 加速引擎")) {
                    LabeledContent(L10n.text("狀態"), value: JITBootstrap.ready ? L10n.text("已開啟") : L10n.text("未開啟"))
                    Picker(L10n.text("啟用方式"), selection: $jit.method) {
                        ForEach(JITMethod.allCases) { Text(L10n.text($0.title)).tag($0) }
                    }
                    // Refresh the cached selection label without replacing settings or VM state.
                    .id(interfaceLanguage)
                    Text(jit.method == .automatic ? L10n.text(jit.automaticDescription) : L10n.format("iPac 將使用「%@」。", L10n.text(jit.method.title)))
                        .font(.footnote).foregroundStyle(.secondary)
                    Button(L10n.text("設定 JIT")) { jit.showSetup = true }
                    Toggle(L10n.text("開啟 iPac 時自動啟用 JIT"), isOn: $jitAtLaunch)
                    if jitAtLaunch {
                        Text(L10n.text("若 LocalDevVPN 尚未連線，iPac 會自動開啟 VPN 連線後返回。"))
                            .font(.footnote).foregroundStyle(.secondary)
                    }
                    LabeledContent(L10n.text("程式碼快取保留區"), value: L10n.format("%@ MB（每次啟動配給）", String(describing: JITBootstrap.jitBytes >> 20)))
                }
                .listRowBackground(Desk.card)
                Section(L10n.text("記憶體配額")) {
                    LabeledContent(L10n.text("裝置實體記憶體"), value: "\(Device.physicalMemoryGB) GB")
                    LabeledContent(L10n.text("大記憶體 Entitlement"), value: Entitlements.increasedMemory ? L10n.text("已自動啟用") : L10n.text("尚未啟用"))
                    LabeledContent(L10n.text("App 上限（啟動時）"), value: ByteText.string(UInt64(Entitlements.memoryLimitAtLaunch)))
                    LabeledContent(L10n.text("可用記憶體空間"), value: ByteText.string(UInt64(henge_available_memory())))
                    LabeledContent(L10n.text("核心 No Footprint 狀態"), value: henge_vm_can_no_footprint() != 0 ? L10n.text("可使用") : L10n.text("待機（附加 JIT 後自動啟用）"))
                    Toggle(L10n.text("開啟 iPac 時自動檢查並啟用大記憶體"), isOn: $moreRam.autoEnableOnLaunch)
                    Button {
                        moreRam.showSheet = true
                    } label: {
                        Label(
                            Entitlements.increasedMemory ? L10n.text("管理大記憶體權限與 GetMoreRam／iRAM+…") : L10n.text("一鍵自動解鎖最大記憶體…"),
                            systemImage: "memorychip"
                        )
                    }
                    Text(Entitlements.increasedMemory
                         ? L10n.text("已自動具備大記憶體權限。開機並掛載 JIT 後，虛擬 Mac 記憶體由核心以 LEDGER_NO_FOOTPRINT 免計入 App 上限。")
                         : L10n.text("點上方登入一次 Apple ID 或匯入 SideStore 帳號 JSON，iPac 會自動在背景為目前 App ID 開通大記憶體；再於簽名工具點一次 Refresh 即生效。"))
                        .font(.footnote).foregroundStyle(.secondary)
                }
                .listRowBackground(Desk.card)
                if Device.isPad {
                    Section(L10n.text("滑鼠與觸控板")) {
                        VStack(alignment: .leading, spacing: 4) {
                            Text(L10n.text("游標移動速度"))
                            Slider(value: $mouseSpeed, in: 0.5...3)
                        }
                        Toggle(L10n.text("自然捲動方向（反轉捲動）"), isOn: $reverseScrolling)
                        VStack(alignment: .leading, spacing: 4) {
                            Text(L10n.text("滾輪捲動速度"))
                            Slider(value: $scrollSpeed, in: 0.1...1.5)
                        }
                        Toggle(L10n.text("對調實體滑鼠右鍵與中鍵"), isOn: $swapMouseButtons)
                        Text(L10n.text("僅在部分第三方滑鼠右鍵與中鍵功能相反時開啟（觸控螢幕手勢不受影響）。需重新啟動 Mac 生效。"))
                            .font(.footnote).foregroundStyle(.secondary)
                        Text(L10n.text("外接巧控鍵盤或藍牙滑鼠可直接移動 Mac 游標。游標速度於下次啟動生效，捲動速度立即生效。"))
                            .font(.footnote).foregroundStyle(.secondary)
                    }
                    .listRowBackground(Desk.card)
                }
                if !Device.isPad {
                    Section(L10n.text("觸控板操作")) {
                        Picker(L10n.text("點擊方式"), selection: $inputMode) {
                            Text(L10n.text("觸控螢幕")).tag(VolumeClicks.InputMode.touchscreen)
                            Text(L10n.text("音量鍵控制")).tag(VolumeClicks.InputMode.volumeButtons)
                        }
                        .pickerStyle(.menu)
                        if inputMode == .volumeButtons {
                            Picker(L10n.text("按鍵模式"), selection: $volumeMode) {
                                Text(L10n.text("延遲長按")).tag(VolumeClicks.Mode.delayHold)
                                Text(L10n.text("先點後拖")).tag(VolumeClicks.Mode.tapThenDrag)
                                Text(L10n.text("相機攔截模式")).tag(VolumeClicks.Mode.intercept)
                            }
                            .pickerStyle(.menu)
                            Toggle(L10n.text("對調音量鍵左右功能"), isOn: $swapButtons)
                        }
                        Text(L10n.format("iPac 可將螢幕模擬為 Magic Trackpad 支援原生 macOS 多指手勢。\n\n%@", String(describing: inputDescription)))
                            .font(.footnote).foregroundStyle(.secondary)
                    }
                    .listRowBackground(Desk.card)
                }
                Section(L10n.text("效能與引擎調整")) {
                    Picker(L10n.text("Mac 更新率"), selection: $refreshRate) {
                        Text("30 Hz").tag(30)
                        Text("60 Hz").tag(60)
                        Text("120 Hz").tag(120)
                    }
                    .pickerStyle(.segmented)
                    Toggle(L10n.text("優先排程至 Apple M 系列效能核心"), isOn: $pCoreQos)
                    Toggle(L10n.text("加快虛擬磁碟寫入速度"), isOn: $fastFlush)
                    Toggle(L10n.text("更快從閒置狀態喚醒（微幅增加耗電）"), isOn: $wfiSpin)
                    Toggle(L10n.text("Superblocks 轉譯最佳化（實驗性）"), isOn: $superblocks)
                    Picker(L10n.text("JIT 指令快取大小"), selection: $codeCacheMB) {
                        Text("512 MB").tag(512)
                        Text("1 GB").tag(1024)
                        Text("1.5 GB").tag(1536)
                    }
                    Text(L10n.text("較大的指令快取可減少重譯次數並提升流暢度，需重開 iPac 生效；若較小記憶體機型無法啟用 JIT 請調低此值。"))
                        .font(.footnote).foregroundStyle(.secondary)
                    Toggle(isOn: $compactJitMetadata) {
                        Label(L10n.text("JIT 中繼資料緊湊儲存（實驗性）"), systemImage: "memorychip")
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    .help(L10n.text("保留指令快取容量與有效程式碼；下次啟動 Mac 時套用。"))
                    .accessibilityIdentifier("jit-compact-metadata-toggle")
                    Text(L10n.text("30 Hz 最省效能、60 Hz 最流暢（非 120 Hz 機型會自動限制於 60 Hz）。以上設定將於下次啟動 Mac 時套用。"))
                        .font(.footnote).foregroundStyle(.secondary)
                }
                .listRowBackground(Desk.card)
                Section(L10n.text("即時續玩（背景凍結儲存）")) {
                    Toggle(L10n.text("離開時自動保存執行狀態"), isOn: $instantResume)
                    Text(L10n.text("切換至背景時會自動把目前 Mac 狀態壓縮寫入儲存空間，即使 iOS 回收 iPac 也可於幾秒內接續剛剛的畫面（實驗性）。"))
                        .font(.footnote).foregroundStyle(.secondary)
                }
                .listRowBackground(Desk.card)
                Section(L10n.text("Mac App 獨立執行（實驗性）")) {
                    Toggle(L10n.text("啟用免開 macOS 直接執行功能"), isOn: $macApps)
                    Text(L10n.text("開啟後可在首頁右上角「＋」直接匯入 .dmg 或 .app，目前支援命令列工具（視窗軟體仍在開發中）。"))
                        .font(.footnote).foregroundStyle(.secondary)
                }
                .listRowBackground(Desk.card)
                Section(L10n.text("外觀")) {
                    Picker(L10n.text("主題外觀"), selection: $appearance) {
                        ForEach(DeskAppearance.allCases) { Text($0.title).tag($0) }
                    }
                    .pickerStyle(.segmented)
                    Text(L10n.format("「跟隨系統」會隨 %@ 的淺色／深色設定切換；執行 Mac 畫面期間固定為深色。", String(describing: Device.name)))
                        .font(.footnote).foregroundStyle(.secondary)
                }
                .listRowBackground(Desk.card)
                Section(L10n.text("外接 SSD 管理與硬體設定")) {
                    LabeledContent(L10n.text("安裝儲存模式"), value: extStorage.mode.shortTitle)
                    if extStorage.isConfigured {
                        LabeledContent(L10n.text("已綁定外接資料夾"), value: extStorage.configuredName ?? L10n.text("外接 SSD"))
                        LabeledContent(L10n.text("連線狀態"), value: extStorage.isConnected ? L10n.format("已連接%@", String(describing: extStorage.filesystemType.map { "（\($0)）" } ?? "")) : L10n.text("未連接"))
                        if extStorage.isConnected {
                            LabeledContent(L10n.text("SSD 可用空間"), value: ByteText.string(UInt64(max(extStorage.freeBytes, 0))))
                        }
                    } else if let mountedExt = machines.all.first(where: \.isExternal) {
                        LabeledContent(L10n.text("已掛載隨身硬碟"), value: mountedExt.externalDriveName ?? L10n.text("外接 SSD"))
                        LabeledContent(L10n.text("連線狀態"), value: mountedExt.isAvailable ? L10n.text("已連接") : L10n.text("未連接"))
                    }
                    Button(L10n.text("選擇／變更外接 SSD 資料夾…")) {
                        pickingExternalFolder = true
                    }
                    .disabled(extStorage.isClearing || machines.isBusy || Machines.isVMRunning)

                    if extStorage.isConfigured || machines.all.contains(where: \.isExternal) {
                        Button {
                            ssdDialog = .confirmEject
                        } label: {
                            Label(L10n.text("安全退出 SSD（保留所有資料）"), systemImage: "eject")
                        }
                        .disabled(extStorage.isClearing || machines.isBusy || Machines.isVMRunning)
                    }

                    if extStorage.canClearDrive {
                        Button(role: .destructive) {
                            if let summary = extStorage.inspectHengeDataOnDrive() {
                                ssdDialog = .confirmClear(summary)
                            }
                        } label: {
                            Label(L10n.text("清除 SSD 上的 iPac／Henge 資料…"), systemImage: "trash")
                        }
                        .disabled(extStorage.isClearing || machines.isBusy || Machines.isVMRunning)
                    }

                    if extStorage.isClearing {
                        HStack(spacing: 10) {
                            ProgressView().controlSize(.small)
                            Text(L10n.text("正在清除 SSD 上的 iPac／Henge 資料…")).font(.footnote).foregroundStyle(.secondary)
                        }
                    }
                    if let msg = extStorage.statusMessage {
                        Text(L10n.text(msg)).font(.footnote).foregroundStyle(Desk.good)
                    }
                    if let err = extStorage.lastError {
                        Text(L10n.text(err)).font(.footnote).foregroundStyle(Desk.bad)
                    }
                    LabeledContent(L10n.text("硬體識別規格"), value: "\(Device.marketingName) (\(Device.chipName ?? "arm64"))")
                    LabeledContent(
                        L10n.text("版本"),
                        value: L10n.format(
                            "%@ (Build %@)",
                            Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "?",
                            Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "?"
                        )
                    )
                }
                .listRowBackground(Desk.card)
                Section(L10n.text("診斷日誌")) {
                    ShareLink(item: HengeLog.logFileURL) { Label(L10n.text("分享 henge.log 紀錄檔"), systemImage: "square.and.arrow.up") }
                }
                .listRowBackground(Desk.card)
            }
            .scrollContentBackground(.hidden)
            .background(Desk.page)
            .navigationTitle(L10n.text("設定"))
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
                    Button(L10n.text("安全退出 SSD（保留所有資料）")) {
                        _ = extStorage.safeEjectDrive()
                    }
                case .confirmClear(let summary):
                    Button(
                        summary.totalBytes > 0
                            ? L10n.format("只清除 Henge 資料（釋放 %@）", String(describing: ByteText.string(UInt64(summary.totalBytes))))
                            : L10n.text("確認清除 Henge 資料"),
                        role: .destructive
                    ) {
                        extStorage.clearAllHengeDataOnDrive(confirmed: summary)
                    }
                }
            } message: { dialog in
                switch dialog {
                case .confirmEject:
                    Text(L10n.format("會確認目前無執行中的虛擬機或檔案傳輸，釋放 Henge 對「%@」的存取權限與掛載紀錄。外接 SSD 內的系統與所有個人資料都會完整保留，之後插到這台或別台 iPad 皆可隨時重新開啟。", String(describing: extStorage.effectiveDriveName)))
                case .confirmClear(let summary):
                    if summary.isEmpty {
                        Text(L10n.format("目前在「%@」找不到 Henge 虛擬機或暫存安裝檔；您 SSD 內的其他個人檔案皆不受影響。", String(describing: summary.driveName)))
                    } else {
                        Text(L10n.format("只會刪除「%@」上的 Henge 資料（共 %@ 台 Mac%@，約釋放 %@）。您 SSD 內的其他個人檔案皆會完整保留。此動作無法復原。", String(describing: summary.driveName), String(describing: summary.machineCount), String(describing: summary.hasInstallFiles ? L10n.text("、含安裝暫存檔 HengeInstall") : ""), String(describing: ByteText.string(UInt64(summary.totalBytes)))))
                    }
                }
            }
        }
    }
}
