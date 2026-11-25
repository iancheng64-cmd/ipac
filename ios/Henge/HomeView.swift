import SwiftUI
import UniformTypeIdentifiers

/// Your Mac as you left it, and one big button.
struct HomeView: View {
    @Environment(\.locale) private var interfaceLocale
    @ObservedObject private var machines = Machines.shared
    @ObservedObject private var jit = JITCoordinator.shared
    @ObservedObject private var installer = Installer.shared
    @ObservedObject private var extStorage = ExternalInstallStorage.shared
    @ObservedObject private var moreRam = MoreRamCoordinator.shared
    @Environment(\.openURL) private var openURL
    private enum FolderPicker { case attachExternal, importCopy }

    @Binding var running: VirtualMac?
    @Binding var tab: RootView.Tab
    @State private var folderPicker: FolderPicker?
    @State private var jitReady = JITBootstrap.ready
    @State private var chosen: UUID?
    @State private var showMacApps = false
    @AppStorage(MacAppsFeature.key) private var macApps = false

    /// The Mac on show: the one picked, or the one used last.
    private var mac: VirtualMac? {
        if let chosen, let mac = machines.all.first(where: { $0.id == chosen }) { return mac }
        return machines.all.max { ($0.lastUsed ?? $0.added) < ($1.lastUsed ?? $1.added) }
    }

    var body: some View {
        let _ = interfaceLocale
        NavigationStack {
            ScrollView {
                VStack(spacing: 14) {
                    notices
                    if let mac {
                        MacHero(
                            mac: mac,
                            jitReady: jitReady,
                            start: { running = machines.all.first(where: { $0.id == mac.id }) ?? mac },
                            turnOnJIT: { jit.enable() },
                            refreshDrive: {
                                extStorage.refreshConnection()
                                machines.refreshExternalMachines()
                            },
                            jitNote: jitReady ? nil : (JITBootstrap.lastFailure ?? jit.automaticDescription)
                        )
                        HStack(spacing: 10) {
                            FactTile(title: L10n.text("磁碟用量"), value: mac.isAvailable ? ByteText.string(UInt64(max(mac.bytesUsed, 0))) : L10n.text("未連接"))
                            FactTile(title: L10n.text("儲存位置"), value: mac.isExternal ? (mac.externalDriveName ?? L10n.text("外接硬碟")) : L10n.format("此 %@", String(describing: Device.name)))
                            FactTile(title: L10n.text("上次使用"), value: mac.lastUsedText)
                        }
                        others(besides: mac)
                    } else {
                        firstMac
                    }
                }
                .padding(.horizontal, 16)
                .padding(.bottom, 24)
                .deskColumn()
            }
            .background(Desk.page)
            .navigationTitle("iPac")
            .navigationDestination(for: VirtualMac.self) { MacSettingsView(mac: $0) }
            .toolbar {
                ToolbarItem(placement: .primaryAction) {
                    Menu {
                        Button(L10n.text("安裝 macOS…")) { tab = .install }
                        Button(L10n.text("從外接硬碟開啟隨身 Mac…")) { folderPicker = .attachExternal }
                        Button(L10n.text("從電腦匯入 Mac（複製到本機）…")) { folderPicker = .importCopy }
                        if macApps { Button(L10n.text("Mac App（實驗性）…")) { showMacApps = true } }
                    } label: {
                        Image(systemName: "plus")
                    }
                    .accessibilityLabel(L10n.text("新增或開啟 Mac"))
                }
            }
            .fileImporter(
                isPresented: Binding(get: { folderPicker != nil }, set: { if !$0 { folderPicker = nil } }),
                allowedContentTypes: [.folder]
            ) { result in
                let activePicker = folderPicker
                folderPicker = nil
                if case let .success(url) = result {
                    switch activePicker {
                    case .attachExternal:
                        if machines.attachExternalDrive(url) > 0,
                           let ext = machines.all.last(where: { $0.isExternal && $0.isAvailable }) {
                            chosen = ext.id
                        }
                    case .importCopy, .none:
                        machines.importFolder(url)
                    }
                }
            }
            .sheet(isPresented: $showMacApps) { MacAppsView() }
            .task {
                var ticks = 0
                while !Task.isCancelled { // the region may be claimed after a hand-off to StikDebug
                    jitReady = JITBootstrap.ready
                    ticks += 1
                    if ticks % 3 == 0, machines.all.contains(where: { $0.isExternal && !$0.isAvailable }) {
                        extStorage.refreshConnection()
                        machines.refreshExternalMachines()
                    }
                    try? await Task.sleep(nanoseconds: 1_000_000_000)
                }
            }
            .onAppear {
                extStorage.refreshConnection()
                machines.refreshExternalMachines()
            }
            .onChange(of: machines.all) { _, list in
                if let chosen, !list.contains(where: { $0.id == chosen }) {
                    self.chosen = nil
                }
            }
        }
    }

    @ViewBuilder private var notices: some View {
        if Device.chipTooOld {
            NoticeRow(symbol: "exclamationmark.triangle.fill", text: Device.chipTooOldText, tint: Desk.bad)
        }
        if moreRam.shouldShowHomeNotice {
            switch moreRam.autoState {
            case .checking:
                NoticeRow(symbol: "memorychip", text: L10n.text("正在自動啟用 iPac 最大記憶體權限…"), tint: Desk.accentLight)
            case .unlockedPendingRefresh:
                Button {
                    if let signer = moreRam.installedSignerApp {
                        openURL(signer.url)
                    } else {
                        moreRam.showSheet = true
                    }
                } label: {
                    NoticeRow(
                        symbol: "checkmark.seal.fill",
                        text: L10n.text("已自動向 Apple 開通大記憶體，點此打開簽名工具 Refresh 生效"),
                        trailing: moreRam.installedSignerApp.map { L10n.format("開啟 %@", String(describing: $0.name)) } ?? L10n.text("查看"),
                        tint: Desk.good
                    )
                }
            case .needsTwoFactor:
                Button { moreRam.showSheet = true } label: {
                    NoticeRow(symbol: "lock.shield", text: L10n.text("自動啟用大記憶體需要 Apple 雙重驗證"), trailing: L10n.text("輸入驗證碼"), tint: Desk.warn)
                }
            case .needsSetup:
                Button { moreRam.showSheet = true } label: {
                    NoticeRow(symbol: "memorychip", text: L10n.text("此簽名尚未包含 Apple 大記憶體權限"), trailing: L10n.text("一鍵啟用"), tint: Desk.accentLight)
                }
            case .failed:
                Button { moreRam.showSheet = true } label: {
                    NoticeRow(symbol: "exclamationmark.triangle.fill", text: L10n.text("自動啟用大記憶體未完成，點此重試"), trailing: L10n.text("開啟"), tint: Desk.warn)
                }
            case .idle, .alreadyActive:
                EmptyView()
            }
        }
        if installer.busy {
            Button { tab = .install } label: {
                NoticeRow(symbol: "arrow.down.circle.fill", text: L10n.format("正在安裝「%@」…", String(describing: installer.machineName)), trailing: L10n.text("查看進度"))
            }
        }
        if let name = machines.importing {
            NoticeRow(symbol: "square.and.arrow.down.fill",
                      text: machines.unpacked > 0 ? L10n.format("正在解包「%@」磁碟… %.0f%%", name, machines.unpacked * 100) : L10n.format("正在匯入「%@」…", String(describing: name)))
        }
        if let name = machines.moving {
            NoticeRow(symbol: "externaldrive.fill",
                      text: L10n.format("正在搬移「%@」… %.0f%%", name, machines.moved * 100))
        }
        if let name = machines.deleting {
            NoticeRow(symbol: "trash.fill", text: L10n.format("正在安全清除「%@」…", String(describing: name)), tint: Desk.warn)
        }
        if let notice = machines.statusNotice {
            Button { machines.statusNotice = nil } label: {
                NoticeRow(symbol: "checkmark.circle.fill", text: notice, trailing: L10n.text("知道了"), tint: Desk.good)
            }
        }
        if let error = machines.lastError {
            Button { machines.lastError = nil } label: {
                NoticeRow(symbol: "exclamationmark.triangle.fill", text: error, trailing: L10n.text("關閉"), tint: Desk.bad)
            }
        }
    }

    private var firstMac: some View {
        VStack(spacing: 14) {
            Image(systemName: "macwindow.on.rectangle")
                .font(.system(size: 54, weight: .light))
                .foregroundStyle(Desk.accentLight)
                .frame(maxWidth: .infinity)
                .frame(height: 190)
                .background(Desk.raised.opacity(0.5), in: RoundedRectangle(cornerRadius: 18, style: .continuous))
            Text(L10n.text("尚未有虛擬 Mac")).font(.system(size: 24, weight: .bold))
            Text(L10n.format("可直接在此 %@（或外接 USB-C SSD）安裝 macOS，或是掛載別台外接 SSD 裡的隨身系統。", String(describing: Device.name)))
                .font(.system(size: 15)).foregroundStyle(Desk.dim).multilineTextAlignment(.center)
            Button(L10n.text("安裝 macOS")) { tab = .install }.buttonStyle(DeskButtonStyle())
            Button(L10n.text("從外接硬碟開啟隨身 Mac")) { folderPicker = .attachExternal }
                .font(.system(size: 15, weight: .semibold)).foregroundStyle(Desk.accentLight)
            Button(L10n.text("從電腦匯入 Mac（複製到本機）")) { folderPicker = .importCopy }
                .font(.system(size: 14, weight: .medium)).foregroundStyle(Desk.dim)
        }
        .padding(14)
        .deskCard(radius: 30)
    }

    @ViewBuilder private func others(besides shown: VirtualMac) -> some View {
        let rest = machines.all.filter { $0.id != shown.id }
        if !rest.isEmpty {
            DeskHeading(L10n.text("其他 Mac"))
            VStack(spacing: 0) {
                ForEach(rest) { other in
                    Button { chosen = other.id } label: {
                        HStack {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(other.name).font(.system(size: 16, weight: .medium)).foregroundStyle(Desk.text)
                                Text(L10n.format("%@ · %@ 核心", String(describing: other.summary), String(describing: other.effectiveCPUs)))
                                    .font(.system(size: 13))
                                    .foregroundStyle(other.isExternal && !other.isAvailable ? Desk.bad : Desk.dim)
                            }
                            Spacer()
                            Image(systemName: "chevron.right").font(.system(size: 13, weight: .semibold)).foregroundStyle(Desk.faint)
                        }
                        .padding(.horizontal, 17)
                        .padding(.vertical, 12)
                        .contentShape(Rectangle())
                    }
                    if other.id != rest.last?.id { Rectangle().fill(Desk.hairline).frame(height: 0.5) }
                }
            }
            .deskCard()
        }
    }
}

extension VirtualMac {
    var bytesUsed: Int64 {
        guard isAvailable else { return 0 }
        let values = try? disk.resourceValues(forKeys: [.totalFileAllocatedSizeKey, .fileSizeKey])
        if let allocated = values?.totalFileAllocatedSize, allocated > 0 {
            return Int64(allocated)
        }
        if let size = values?.fileSize, size > 0 {
            return Int64(size)
        }
        return 0
    }

    var lastUsedText: String {
        guard let lastUsed else { return L10n.text("從未使用") }
        if Calendar.current.isDateInToday(lastUsed) { return L10n.text("今天") }
        if Calendar.current.isDateInYesterday(lastUsed) { return L10n.text("昨天") }
        return lastUsed.formatted(.dateTime.month(.abbreviated).day().locale(AppLanguage.current.locale))
    }

    var summary: String {
        var parts: [String] = []
        if let osName { parts.append(osName) }
        parts.append(adaptsToHost ? L10n.format("自動 %@", String(describing: GuestRAMBudget.text(effectiveRAMMB))) : GuestRAMBudget.text(ramMB))
        if isExternal {
            parts.append(isAvailable ? L10n.format("外接（%@）", String(describing: externalDriveName ?? L10n.text("硬碟"))) : L10n.text("硬碟未連接"))
        }
        return parts.joined(separator: " · ")
    }
}

/// The picture of the Mac, its name, and Start.
private struct MacHero: View {
    @Environment(\.locale) private var interfaceLocale
    let mac: VirtualMac
    let jitReady: Bool
    let start: () -> Void
    let turnOnJIT: () -> Void
    let refreshDrive: () -> Void
    let jitNote: String?

    var body: some View {
        let _ = interfaceLocale
        VStack(spacing: 0) {
            NavigationLink(value: mac) {
                VStack(spacing: 0) {
                    preview
                    HStack {
                        Text(mac.name).font(.system(size: 24, weight: .bold)).foregroundStyle(Desk.text).lineLimit(1)
                        Spacer()
                        if mac.isExternal {
                            Text(mac.isAvailable ? L10n.text("外接 SSD") : L10n.text("未連接"))
                                .font(.system(size: 13, weight: .semibold))
                                .foregroundStyle(mac.isAvailable ? Desk.accentLight : Desk.bad)
                                .padding(.horizontal, 11)
                                .padding(.vertical, 5)
                                .background((mac.isAvailable ? Desk.accentLight : Desk.bad).opacity(0.13), in: Capsule())
                        }
                        Text(jitReady ? L10n.text("JIT 已開啟") : L10n.text("JIT 未開啟"))
                            .font(.system(size: 13, weight: .semibold))
                            .foregroundStyle(jitReady ? Desk.good : Desk.warn)
                            .padding(.horizontal, 11)
                            .padding(.vertical, 5)
                            .background((jitReady ? Desk.good : Desk.warn).opacity(0.13), in: Capsule())
                        Image(systemName: "chevron.right").font(.system(size: 13, weight: .semibold)).foregroundStyle(Desk.faint)
                    }
                    .padding(.top, 15)
                    .padding(.horizontal, 5)
                    Text(L10n.format("%@ · %@ 核心", String(describing: mac.summary), String(describing: mac.effectiveCPUs)))
                        .font(.system(size: 15))
                        .foregroundStyle(mac.isExternal && !mac.isAvailable ? Desk.bad : Desk.dim)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.horizontal, 5)
                        .padding(.top, 3)
                }
            }
            .buttonStyle(.plain)
            if jitReady {
                if mac.isExternal && !mac.isAvailable {
                    Text(L10n.format("請插上「%@」以啟動這台 Mac，或點選上方資訊欄重新連接資料夾。", String(describing: mac.externalDriveName ?? L10n.text("外接硬碟"))))
                        .font(.system(size: 13))
                        .foregroundStyle(Desk.bad)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.horizontal, 5)
                        .padding(.top, 10)
                    Button(action: refreshDrive) {
                        Label(L10n.format("重新偵測「%@」", String(describing: mac.externalDriveName ?? L10n.text("外接硬碟"))), systemImage: "externaldrive.badge.exclamationmark")
                    }
                    .buttonStyle(DeskButtonStyle(enabled: false))
                    .padding(.top, 12)
                } else {
                    if let notice = Device.memoryBudget.notice(for: mac.effectiveRAMMB), notice.isHighRisk {
                        Label(L10n.text(notice.text), systemImage: "exclamationmark.triangle.fill")
                            .font(.system(size: 13))
                            .foregroundStyle(Desk.bad)
                            .fixedSize(horizontal: false, vertical: true)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(.horizontal, 5)
                            .padding(.top, 10)
                    }
                    Button(action: start) {
                        if InstantResume.enabled && InstantResume.hasSave(for: mac) {
                            Label(L10n.text("繼續執行"), systemImage: "play.fill")
                        } else {
                            Label(L10n.text("啟動"), systemImage: "play.fill")
                        }
                    }
                    .buttonStyle(DeskButtonStyle())
                    .padding(.top, 15)
                }
            } else {
                if let jitNote {
                    Text(L10n.text(jitNote)).font(.system(size: 13)).foregroundStyle(Desk.dim)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.horizontal, 5)
                        .padding(.top, 10)
                }
                Button(L10n.text("開啟 JIT"), action: turnOnJIT)
                    .buttonStyle(DeskButtonStyle())
                    .padding(.top, 15)
            }
        }
        .padding(14)
        .deskCard(radius: 30)
    }

    @ViewBuilder private var preview: some View {
        ZStack {
            Desk.raised.opacity(0.5)
            if mac.isAvailable, let image = UIImage(contentsOfFile: MacPreview.file(for: mac).path) {
                Image(uiImage: image).resizable().aspectRatio(contentMode: .fill)
            } else {
                Image(systemName: mac.isExternal && !mac.isAvailable ? "externaldrive.badge.exclamationmark" : "macwindow.on.rectangle")
                    .font(.system(size: 46, weight: .light))
                    .foregroundStyle(mac.isExternal && !mac.isAvailable ? Desk.bad : Desk.faint)
            }
        }
        .aspectRatio(mac.aspect, contentMode: .fit)
        .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 18, style: .continuous).stroke(Desk.hairline, lineWidth: 0.5))
        .accessibilityHidden(true)
    }
}

private struct FactTile: View {
    @Environment(\.locale) private var interfaceLocale
    let title: String
    let value: String
    var body: some View {
        let _ = interfaceLocale
        VStack(alignment: .leading, spacing: 3) {
            Text(L10n.text(title)).font(.system(size: 13)).foregroundStyle(Desk.dim)
            Text(value).font(.system(size: 21, weight: .bold)).foregroundStyle(Desk.text).lineLimit(1).minimumScaleFactor(0.7)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(15)
        .deskCard()
    }
}

struct NoticeRow: View {
    @Environment(\.locale) private var interfaceLocale
    let symbol: String
    let text: String
    var trailing: String?
    var tint: Color = Desk.accentLight

    var body: some View {
        let _ = interfaceLocale
        HStack(spacing: 11) {
            Image(systemName: symbol).foregroundStyle(tint)
            Text(L10n.text(text)).font(.system(size: 15)).foregroundStyle(Desk.text).multilineTextAlignment(.leading)
            Spacer(minLength: 4)
            if let trailing { Text(L10n.text(trailing)).font(.system(size: 15, weight: .semibold)).foregroundStyle(Desk.accentLight) }
        }
        .padding(14)
        .deskCard()
    }
}
