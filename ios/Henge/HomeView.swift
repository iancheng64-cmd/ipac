import SwiftUI
import UniformTypeIdentifiers

/// Your Mac as you left it, and one big button.
struct HomeView: View {
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
                            FactTile(title: "磁碟用量", value: mac.isAvailable ? ByteText.string(UInt64(max(mac.bytesUsed, 0))) : "未連接")
                            FactTile(title: "儲存位置", value: mac.isExternal ? (mac.externalDriveName ?? "外接硬碟") : "此 \(Device.name)")
                            FactTile(title: "上次使用", value: mac.lastUsedText)
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
                        Button("安裝 macOS…") { tab = .install }
                        Button("從外接硬碟開啟隨身 Mac…") { folderPicker = .attachExternal }
                        Button("從電腦匯入 Mac（複製到本機）…") { folderPicker = .importCopy }
                        if macApps { Button("Mac App（實驗性）…") { showMacApps = true } }
                    } label: {
                        Image(systemName: "plus")
                    }
                    .accessibilityLabel("新增或開啟 Mac")
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
                NoticeRow(symbol: "memorychip", text: "正在自動啟用 iPac 最大記憶體權限…", tint: Desk.accentLight)
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
                        text: "已自動向 Apple 開通大記憶體，點此打開簽名工具 Refresh 生效",
                        trailing: moreRam.installedSignerApp.map { "開啟 \($0.name)" } ?? "查看",
                        tint: Desk.good
                    )
                }
            case .needsTwoFactor:
                Button { moreRam.showSheet = true } label: {
                    NoticeRow(symbol: "lock.shield", text: "自動啟用大記憶體需要 Apple 雙重驗證", trailing: "輸入驗證碼", tint: Desk.warn)
                }
            case .needsSetup:
                Button { moreRam.showSheet = true } label: {
                    NoticeRow(symbol: "memorychip", text: "此簽名尚未包含 Apple 大記憶體權限", trailing: "一鍵啟用", tint: Desk.accentLight)
                }
            case .failed:
                Button { moreRam.showSheet = true } label: {
                    NoticeRow(symbol: "exclamationmark.triangle.fill", text: "自動啟用大記憶體未完成，點此重試", trailing: "開啟", tint: Desk.warn)
                }
            case .idle, .alreadyActive:
                EmptyView()
            }
        }
        if installer.busy {
            Button { tab = .install } label: {
                NoticeRow(symbol: "arrow.down.circle.fill", text: "正在安裝「\(installer.machineName)」…", trailing: "查看進度")
            }
        }
        if let name = machines.importing {
            NoticeRow(symbol: "square.and.arrow.down.fill",
                      text: machines.unpacked > 0 ? String(format: "正在解包「%@」磁碟… %.0f%%", name, machines.unpacked * 100) : "正在匯入「\(name)」…")
        }
        if let name = machines.moving {
            NoticeRow(symbol: "externaldrive.fill",
                      text: String(format: "正在搬移「%@」… %.0f%%", name, machines.moved * 100))
        }
        if let name = machines.deleting {
            NoticeRow(symbol: "trash.fill", text: "正在安全清除「\(name)」…", tint: Desk.warn)
        }
        if let notice = machines.statusNotice {
            Button { machines.statusNotice = nil } label: {
                NoticeRow(symbol: "checkmark.circle.fill", text: notice, trailing: "知道了", tint: Desk.good)
            }
        }
        if let error = machines.lastError {
            Button { machines.lastError = nil } label: {
                NoticeRow(symbol: "exclamationmark.triangle.fill", text: error, trailing: "關閉", tint: Desk.bad)
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
            Text("尚未有虛擬 Mac").font(.system(size: 24, weight: .bold))
            Text("可直接在此 \(Device.name)（或外接 USB-C SSD）安裝 macOS，或是掛載別台外接 SSD 裡的隨身系統。")
                .font(.system(size: 15)).foregroundStyle(Desk.dim).multilineTextAlignment(.center)
            Button("安裝 macOS") { tab = .install }.buttonStyle(DeskButtonStyle())
            Button("從外接硬碟開啟隨身 Mac") { folderPicker = .attachExternal }
                .font(.system(size: 15, weight: .semibold)).foregroundStyle(Desk.accentLight)
            Button("從電腦匯入 Mac（複製到本機）") { folderPicker = .importCopy }
                .font(.system(size: 14, weight: .medium)).foregroundStyle(Desk.dim)
        }
        .padding(14)
        .deskCard(radius: 30)
    }

    @ViewBuilder private func others(besides shown: VirtualMac) -> some View {
        let rest = machines.all.filter { $0.id != shown.id }
        if !rest.isEmpty {
            DeskHeading("其他 Mac")
            VStack(spacing: 0) {
                ForEach(rest) { other in
                    Button { chosen = other.id } label: {
                        HStack {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(other.name).font(.system(size: 16, weight: .medium)).foregroundStyle(Desk.text)
                                Text("\(other.summary) · \(other.effectiveCPUs) 核心")
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
        guard let lastUsed else { return "從未使用" }
        if Calendar.current.isDateInToday(lastUsed) { return "今天" }
        if Calendar.current.isDateInYesterday(lastUsed) { return "昨天" }
        return lastUsed.formatted(.dateTime.month(.abbreviated).day())
    }

    var summary: String {
        var parts: [String] = []
        if let osName { parts.append(osName) }
        parts.append(adaptsToHost ? "自動 \(effectiveRAMMB / 1024) GB" : "\(ramMB / 1024) GB")
        if isExternal {
            parts.append(isAvailable ? "外接（\(externalDriveName ?? "硬碟")）" : "硬碟未連接")
        }
        return parts.joined(separator: " · ")
    }
}

/// The picture of the Mac, its name, and Start.
private struct MacHero: View {
    let mac: VirtualMac
    let jitReady: Bool
    let start: () -> Void
    let turnOnJIT: () -> Void
    let refreshDrive: () -> Void
    let jitNote: String?

    var body: some View {
        VStack(spacing: 0) {
            NavigationLink(value: mac) {
                VStack(spacing: 0) {
                    preview
                    HStack {
                        Text(mac.name).font(.system(size: 24, weight: .bold)).foregroundStyle(Desk.text).lineLimit(1)
                        Spacer()
                        if mac.isExternal {
                            Text(mac.isAvailable ? "外接 SSD" : "未連接")
                                .font(.system(size: 13, weight: .semibold))
                                .foregroundStyle(mac.isAvailable ? Desk.accentLight : Desk.bad)
                                .padding(.horizontal, 11)
                                .padding(.vertical, 5)
                                .background((mac.isAvailable ? Desk.accentLight : Desk.bad).opacity(0.13), in: Capsule())
                        }
                        Text(jitReady ? "JIT 已開啟" : "JIT 未開啟")
                            .font(.system(size: 13, weight: .semibold))
                            .foregroundStyle(jitReady ? Desk.good : Desk.warn)
                            .padding(.horizontal, 11)
                            .padding(.vertical, 5)
                            .background((jitReady ? Desk.good : Desk.warn).opacity(0.13), in: Capsule())
                        Image(systemName: "chevron.right").font(.system(size: 13, weight: .semibold)).foregroundStyle(Desk.faint)
                    }
                    .padding(.top, 15)
                    .padding(.horizontal, 5)
                    Text("\(mac.summary) · \(mac.effectiveCPUs) 核心")
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
                    Text("請插上「\(mac.externalDriveName ?? "外接硬碟")」以啟動這台 Mac，或點選上方資訊欄重新連接資料夾。")
                        .font(.system(size: 13))
                        .foregroundStyle(Desk.bad)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.horizontal, 5)
                        .padding(.top, 10)
                    Button(action: refreshDrive) {
                        Label("重新偵測「\(mac.externalDriveName ?? "外接硬碟")」", systemImage: "externaldrive.badge.exclamationmark")
                    }
                    .buttonStyle(DeskButtonStyle(enabled: false))
                    .padding(.top, 12)
                } else {
                    Button(action: start) {
                        if InstantResume.enabled && InstantResume.hasSave(for: mac) {
                            Label("繼續執行", systemImage: "play.fill")
                        } else {
                            Label("啟動", systemImage: "play.fill")
                        }
                    }
                    .buttonStyle(DeskButtonStyle())
                    .padding(.top, 15)
                }
            } else {
                if let jitNote {
                    Text(jitNote).font(.system(size: 13)).foregroundStyle(Desk.dim)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.horizontal, 5)
                        .padding(.top, 10)
                }
                Button("開啟 JIT", action: turnOnJIT)
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
    let title: String
    let value: String
    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(title).font(.system(size: 13)).foregroundStyle(Desk.dim)
            Text(value).font(.system(size: 21, weight: .bold)).foregroundStyle(Desk.text).lineLimit(1).minimumScaleFactor(0.7)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(15)
        .deskCard()
    }
}

struct NoticeRow: View {
    let symbol: String
    let text: String
    var trailing: String?
    var tint: Color = Desk.accentLight

    var body: some View {
        HStack(spacing: 11) {
            Image(systemName: symbol).foregroundStyle(tint)
            Text(text).font(.system(size: 15)).foregroundStyle(Desk.text).multilineTextAlignment(.leading)
            Spacer(minLength: 4)
            if let trailing { Text(trailing).font(.system(size: 15, weight: .semibold)).foregroundStyle(Desk.accentLight) }
        }
        .padding(14)
        .deskCard()
    }
}
