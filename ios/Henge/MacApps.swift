import SwiftUI
import UniformTypeIdentifiers

/// Mac apps without macOS (experimental): apps and programs brought in from a .dmg or an .app and run through
/// Henge's translation layer (tl/), inside Henge, with no Mac started. Today that is command-line programs; an app
/// that draws with AppKit, SwiftUI or Mac Catalyst is listed with what it would need.
enum MacAppsFeature {
    static let key = "henge.macApps"
}

struct MacApp: Identifiable, Hashable {
    let url: URL
    let name: String
    let identifier: String
    let minMacOS: String
    let executable: String
    let arm64: Bool
    let intel: Bool
    let kind: Int32
    var id: String { url.path }

    init?(url: URL) {
        var info = HengeTlInfo()
        var err = [CChar](repeating: 0, count: 256)
        guard henge_tl_info(url.path, &info, &err, err.count) == 0 else { return nil }
        self.url = url
        name = withUnsafeBytes(of: info.name) { String(cString: $0.bindMemory(to: CChar.self).baseAddress!) }
        identifier = withUnsafeBytes(of: info.identifier) { String(cString: $0.bindMemory(to: CChar.self).baseAddress!) }
        minMacOS = withUnsafeBytes(of: info.min_macos) { String(cString: $0.bindMemory(to: CChar.self).baseAddress!) }
        executable = withUnsafeBytes(of: info.executable) { String(cString: $0.bindMemory(to: CChar.self).baseAddress!) }
        arm64 = info.arm64 != 0
        intel = info.x86_64 != 0
        kind = info.kind
    }

    var canRun: Bool { kind == Int32(HENGE_TL_PROGRAM.rawValue) }
    /// An AppKit app opens against Henge's own AppKit (experimental: browsers built on Chromium are what it is made for).
    var canOpenWindowed: Bool { kind == Int32(HENGE_TL_APPKIT.rawValue) && arm64 }

    var verdict: (title: String, detail: String) {
        switch UInt32(kind) {
        case HENGE_TL_PROGRAM.rawValue:
            return ("免開 macOS 直接執行（實驗性）",
                    "無視窗命令列程式：Henge 可不啟動虛擬機直接載入並執行。")
        case HENGE_TL_SWIFTUI.rawValue:
            return ("尚未支援：SwiftUI App",
                    "此程式呼叫的 SwiftUI 元件尚未完成獨立執行支援，請先於虛擬 Mac 內開啟。")
        case HENGE_TL_CATALYST.rawValue:
            return ("尚未支援：Mac Catalyst App",
                    "獨立視窗轉譯仍在開發中，請先於虛擬 Mac 內開啟。")
        case HENGE_TL_APPKIT.rawValue:
            return ("實驗性：AppKit 視窗 App",
                    "由 Henge 模擬 AppKit 繪製視窗，主要針對 Chromium / Electron / CEF 瀏覽器與工具測試，其他程式可能會提前停止。")
        default:
            return ("僅支援 Intel (x86_64)",
                    "缺少 Apple Silicon (arm64) 原生程式碼，請在虛擬 Mac 透過 Rosetta 執行。")
        }
    }

    var kindSymbol: String {
        switch UInt32(kind) {
        case HENGE_TL_PROGRAM.rawValue: return "terminal"
        case HENGE_TL_INTEL.rawValue: return "cpu"
        default: return "macwindow"
        }
    }
}

@MainActor
final class MacAppsStore: ObservableObject {
    static let shared = MacAppsStore()
    @Published private(set) var apps: [MacApp] = []
    @Published var busy: String?
    @Published var problem: String?

    static var folder: URL {
        let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        return docs.appendingPathComponent("Mac Apps", isDirectory: true)
    }

    func reload() {
        let folder = Self.folder
        Task.detached(priority: .userInitiated) {
            try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            let items = (try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)) ?? []
            let found = items.filter { !$0.lastPathComponent.hasPrefix(".") && $0.pathExtension != "txt" }
                .compactMap(MacApp.init(url:))
                .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
            await MainActor.run { self.apps = found }
        }
    }

    /// A .dmg (its apps and programs are copied out), an .app, or a lone program.
    func bring(in url: URL) {
        let scoped = url.startAccessingSecurityScopedResource()
        busy = L10n.format("正在匯入 %@…", url.lastPathComponent)
        problem = nil
        let folder = Self.folder
        Task.detached(priority: .userInitiated) {
            defer { if scoped { url.stopAccessingSecurityScopedResource() } }
            try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            var trouble: String?
            if url.pathExtension.lowercased() == "dmg" {
                var err = [CChar](repeating: 0, count: 512)
                let copied = henge_tl_import_dmg(url.path, folder.path, &err, err.count)
                if copied <= 0 { trouble = String(cString: err) }
                HengeLog.log("macapps", "\(url.lastPathComponent): \(copied) items copied\(copied <= 0 ? " (\(String(cString: err)))" : "")")
            } else {
                let to = folder.appendingPathComponent(url.lastPathComponent)
                try? FileManager.default.removeItem(at: to)
                do { try FileManager.default.copyItem(at: url, to: to) } catch { trouble = error.localizedDescription }
                if trouble == nil, MacApp(url: to) == nil {
                    try? FileManager.default.removeItem(at: to)
                    trouble = L10n.format("%@ 不是有效的 Mac App 或可執行檔。", url.lastPathComponent)
                }
            }
            let found = trouble
            await MainActor.run {
                self.busy = nil
                self.problem = found
                self.reload()
            }
        }
    }

    func addSamples() {
        guard let samples = Bundle.main.url(forResource: "tl-samples", withExtension: "dmg") else {
            problem = "此版本未包含範例程式。"
            return
        }
        bring(in: samples)
    }

    func delete(_ app: MacApp) {
        try? FileManager.default.removeItem(at: app.url)
        try? FileManager.default.removeItem(at: Self.output(for: app))
        reload()
    }

    /// What a program printed, beside it (visible in Files, for a run that ended Henge).
    static func output(for app: MacApp) -> URL {
        folder.appendingPathComponent("\(app.url.lastPathComponent) output.txt")
    }
}

/// The list: what was brought in, and a way to bring in more.
struct MacAppsView: View {
    @ObservedObject private var store = MacAppsStore.shared
    @Environment(\.dismiss) private var dismiss
    @Environment(\.locale) private var interfaceLocale
    @State private var picking = false

    var body: some View {
        let _ = interfaceLocale
        NavigationStack {
            ScrollView {
                VStack(spacing: 0) {
                    Text(L10n.text("透過 Henge 內建轉譯層不需啟動虛擬 Mac 即可執行部分 Mac 程式。目前支援無視窗命令列工具，視窗應用屬實驗階段。"))
                        .font(.system(size: 14)).foregroundStyle(Desk.dim)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.horizontal, 4).padding(.bottom, 12)
                    if let busy = store.busy { NoticeRow(symbol: "arrow.down.circle.fill", text: busy) }
                    if let problem = store.problem { NoticeRow(symbol: "exclamationmark.triangle.fill", text: problem, tint: Desk.warn) }
                    if store.apps.isEmpty && store.busy == nil {
                        VStack(spacing: 10) {
                            Image(systemName: "shippingbox").font(.system(size: 34)).foregroundStyle(Desk.faint)
                            Text(L10n.text("尚無匯入的程式")).font(.system(size: 17, weight: .semibold))
                            Text(L10n.text("可從「檔案」App 匯入 .dmg 或 .app，或先加入內建範例程式測試。"))
                                .font(.system(size: 14)).foregroundStyle(Desk.dim).multilineTextAlignment(.center)
                        }
                        .padding(28).frame(maxWidth: .infinity).deskCard()
                    }
                    ForEach(store.apps) { app in
                        NavigationLink(value: app) { MacAppRow(app: app) }.buttonStyle(.plain).padding(.bottom, 10)
                    }
                    Button(L10n.text("加入範例程式")) { store.addSamples() }
                        .buttonStyle(DeskButtonStyle()).padding(.top, 8)
                }
                .padding(.horizontal, 16).padding(.vertical, 12).deskColumn()
            }
            .background(Desk.page)
            .navigationTitle("Mac App")
            .navigationDestination(for: MacApp.self) { MacAppRunView(app: $0) }
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button(L10n.text("完成")) { dismiss() } }
                ToolbarItem(placement: .primaryAction) {
                    Button { picking = true } label: { Image(systemName: "plus") }.accessibilityLabel(L10n.text("匯入 Mac App"))
                }
            }
            .fileImporter(isPresented: $picking, allowedContentTypes: [.diskImage, .applicationBundle, .folder, .unixExecutable, .data]) { result in
                if case let .success(url) = result { store.bring(in: url) }
            }
            .onAppear { store.reload() }
        }
    }
}

private struct MacAppRow: View {
    let app: MacApp
    @Environment(\.locale) private var interfaceLocale
    var body: some View {
        let _ = interfaceLocale
        HStack(spacing: 14) {
            Image(systemName: app.kindSymbol).font(.system(size: 22)).foregroundStyle(app.canRun ? Desk.accent : Desk.faint).frame(width: 34)
            VStack(alignment: .leading, spacing: 3) {
                Text(app.name).font(.system(size: 17, weight: .semibold)).foregroundStyle(Desk.text).lineLimit(1)
                Text(L10n.text(app.verdict.title)).font(.system(size: 13)).foregroundStyle(app.canRun ? Desk.good : Desk.dim).lineLimit(1)
            }
            Spacer()
            Image(systemName: "chevron.right").font(.system(size: 13, weight: .semibold)).foregroundStyle(Desk.faint)
        }
        .padding(16).deskCard()
    }
}

/// One app or program: what it is, and Run for a program, with what it printed.
struct MacAppRunView: View {
    private enum RunResult {
        case failed(String)
        case finished(Int)

        var text: String {
            switch self {
            case .failed(let reason):
                return L10n.format("無法執行：%@", reason)
            case .finished(let code):
                return L10n.format("已結束（結束碼 %@）。", String(describing: code))
            }
        }
    }

    let app: MacApp
    @ObservedObject private var store = MacAppsStore.shared
    @Environment(\.dismiss) private var dismiss
    @Environment(\.locale) private var interfaceLocale
    @State private var running = false
    @State private var output = ""
    @State private var result: RunResult?
    @State private var confirmDelete = false
    @State private var showScreen = false

    var body: some View {
        let _ = interfaceLocale
        ScrollView {
            VStack(spacing: 0) {
                VStack(alignment: .leading, spacing: 8) {
                    Text(L10n.text(app.verdict.title)).font(.system(size: 17, weight: .semibold)).foregroundStyle(app.canRun ? Desk.good : Desk.text)
                    Text(L10n.text(app.verdict.detail)).font(.system(size: 14)).foregroundStyle(Desk.dim)
                }
                .frame(maxWidth: .infinity, alignment: .leading).padding(17).deskCard()

                DeskHeading(L10n.text("關於"))
                VStack(alignment: .leading, spacing: 6) {
                    if !app.identifier.isEmpty { LabeledContent(L10n.text("識別碼"), value: app.identifier) }
                    LabeledContent(L10n.text("架構"), value: [app.arm64 ? "Apple Silicon" : nil, app.intel ? "Intel" : nil].compactMap { $0 }.joined(separator: L10n.text(" 與 ")))
                    if !app.minMacOS.isEmpty { LabeledContent(L10n.text("最低 macOS"), value: L10n.format("%@ 或更新版本", app.minMacOS)) }
                }
                .font(.system(size: 15)).padding(17).deskCard()

                if app.canRun {
                    Button(running ? L10n.text("執行中…") : L10n.text("執行")) { run() }
                        .buttonStyle(DeskButtonStyle()).disabled(running || (result == nil && henge_tl_ran_program() != 0)).padding(.top, 16)
                    Text(L10n.text("每次啟動 Henge 僅能執行一個獨立程式。執行完畢後請關閉重開 Henge 再執行下一個或啟動虛擬 Mac。"))
                        .font(.system(size: 13)).foregroundStyle(Desk.dim).frame(maxWidth: .infinity, alignment: .leading).padding(.top, 8)
                    if result != nil || !output.isEmpty {
                        DeskHeading(L10n.text("輸出結果"))
                        VStack(alignment: .leading, spacing: 8) {
                            Text(output.isEmpty ? L10n.text("（無輸出內容）") : output)
                                .font(.system(size: 12, design: .monospaced)).textSelection(.enabled)
                                .frame(maxWidth: .infinity, alignment: .leading)
                            if let result { Text(result.text).font(.system(size: 13, weight: .semibold)).foregroundStyle(Desk.dim) }
                        }
                        .padding(17).deskCard()
                    }
                }
                if app.canOpenWindowed {
                    Button(L10n.text("開啟視窗（實驗性）")) { showScreen = true }
                        .buttonStyle(DeskButtonStyle()).disabled(henge_tl_ran_program() != 0).padding(.top, 16)
                    Text(L10n.text("每次啟動 Henge 僅能執行一個應用程式。輕點為左鍵、單指捲動、雙指拖曳、長按為右鍵；鍵盤按鈕可叫出輸入。結束後請上滑關閉 Henge。"))
                        .font(.system(size: 13)).foregroundStyle(Desk.dim).frame(maxWidth: .infinity, alignment: .leading).padding(.top, 8)
                }
                Button(L10n.text("刪除"), role: .destructive) { confirmDelete = true }.padding(.top, 24)
            }
            .padding(.horizontal, 16).padding(.vertical, 12).deskColumn()
        }
        .background(Desk.page)
        .navigationTitle(app.name)
        .fullScreenCover(isPresented: $showScreen) { MacAppScreen(app: app) }
        .confirmationDialog(L10n.format("確定刪除「%@」嗎？", app.name), isPresented: $confirmDelete, titleVisibility: .visible) {
            Button(L10n.text("刪除"), role: .destructive) { store.delete(app); dismiss() }
        }
    }

    private func run() {
        running = true
        result = nil
        output = ""
        let exe = app.executable, out = MacAppsStore.output(for: app)
        HengeLog.log("macapps", "running \(app.name) (\(exe))")
        Task.detached(priority: .userInitiated) {
            var err = [CChar](repeating: 0, count: 512)
            let rc = henge_tl_run(exe, out.path, &err, err.count)
            let text = (try? String(contentsOf: out, encoding: .utf8)) ?? ""
            let why = String(cString: err)
            HengeLog.log("macapps", "\(exe) returned \(rc)\(why.isEmpty ? "" : ": \(why)")")
            await MainActor.run {
                output = String(text.suffix(20000))
                result = rc == -1 && !why.isEmpty ? .failed(why) : .finished(Int(rc))
                running = false
            }
        }
    }
}
