import SwiftUI
import GameController

/// A running Mac. Upright, its screen sits above a trackpad; on its side the screen fills the device
/// and is its own trackpad. Zoomed in, the screen fills the device either way and follows the pointer.
/// A keyboard, trackpad or mouse attached to an iPad works throughout.
struct SessionView: View {
    let mac: VirtualMac
    let close: () -> Void

    @StateObject private var display = DisplayRouter()
    @State private var error: String?
    @State private var state: Int32 = 0
    @State private var bootAttempt = 0
    @State private var cpusOn: Int32 = 0
    @State private var userCode = false
    @State private var blocksPerSecond: Double = 0
    @State private var framesOut: UInt64 = 0
    @State private var framesIn: UInt64 = 0
    @State private var log: [String] = []
    @State private var started = Date()
    @State private var thermalState = ProcessInfo.processInfo.thermalState
    @State private var bootRAM: UInt64 = 0 /* what the Mac was started with, which a save is for */
    @State private var bootCPUs: Int = 4
    @State private var ramMode: Int32 = 0
    @State private var runningMac: VirtualMac?
    @AppStorage("henge.matchScreenColors") private var matchScreenColors = true
    @AppStorage("henge.display.brightness") private var screenBrightness = 1.0
    @AppStorage("henge.cursor.scale") private var cursorScale = Device.isPad ? 1 : 3
    @AppStorage("henge.cursor.sharp") private var sharpCursor = true
    @AppStorage(HardwareMouse.scrollSpeedKey) private var scrollSpeed = 0.3

    @State private var typing = false
    @State private var zoomed = false
    @State private var showDetails = false
    @State private var controlsHidden = false
    @State private var showRevealHint = false
    @State private var pointerRefused = false
    @AppStorage("henge.controls.hintsShown") private var revealHintsShown = 0
    @AppStorage(VolumeClicks.inputModeKey) private var inputMode = VolumeClicks.InputMode.touchscreen
    @AppStorage(VolumeClicks.modeKey) private var volumeMode = VolumeClicks.Mode.delayHold
    /// Once per install: macOS's moving wallpapers and aerial screen saver are video, decoded by the emulated
    /// CPUs (a phone ran about 30% faster with a still one).
    @AppStorage("henge.tips.stillWallpaperShown") private var stillWallpaperTipShown = false
    @State private var showWallpaperTip = false
    @State private var confirmStop = false
    @State private var zoomCentre = CGPoint(x: 0.5, y: 0.5) // where the zoomed view is, 0...1 of the Mac's screen
    @State private var map: UIImage?
    @State private var zoomFollowing: Task<Void, Never>?
    @State private var helperRunning = false
    @State private var shown = CGSize(width: 0.5, height: 0.5) // how much of the Mac's screen the zoomed view shows
    @Environment(\.scenePhase) private var scenePhase


    var body: some View {
        GeometryReader { geo in
            let insets = geo.safeAreaInsets
            let full = CGSize(width: geo.size.width + insets.leading + insets.trailing,
                              height: geo.size.height + insets.top + insets.bottom)
            let landscape = full.width > full.height
            let layout = Layout(full: full, insets: insets, landscape: landscape, zoomed: zoomed, typing: typing, centre: zoomCentre, aspect: mac.aspect)
            ZStack(alignment: .topLeading) {
                (landscape || zoomed ? Color.black : Desk.page)
                // One view in every layout: it holds the layer the engine draws into.
                BootDisplay(display: display, role: .device)
                    .opacity(display.isExternal ? 0 : 1)
                    .overlay {
                        if display.isExternal && state != 2 {
                            VStack(spacing: 8) {
                                Image(systemName: "display").font(.largeTitle)
                                Text("Mac 畫面已輸出至外接螢幕").font(.headline)
                                Text("請使用觸控螢幕、鍵盤或外接滑鼠操作。")
                                    .font(.subheadline)
                            }
                            .foregroundStyle(.white)
                            .multilineTextAlignment(.center)
                            .padding()
                            .accessibilityElement(children: .combine)
                        }
                    }
                    .frame(width: layout.screen.width, height: layout.screen.height)
                    .clipShape(RoundedRectangle(cornerRadius: layout.fillsPhone ? 0 : 15, style: .continuous))
                    .overlay {
                        if !layout.fillsPhone {
                            RoundedRectangle(cornerRadius: 15, style: .continuous).stroke(Color.white.opacity(0.16), lineWidth: 0.5)
                        }
                    }
                    .position(x: layout.screen.midX, y: layout.screen.midY)
                if state != 2 {
                    Trackpad()
                        .frame(width: layout.touch.width, height: layout.touch.height)
                        .position(x: layout.touch.midX, y: layout.touch.midY)
                    if inputMode == .volumeButtons && volumeMode == .intercept {
                        // The capture interaction must live in the SwiftUI hierarchy to receive
                        // the volume-button events; it passes touches through to the trackpad.
                        CaptureInteractionView()
                            .frame(maxWidth: .infinity, maxHeight: .infinity)
                            .allowsHitTesting(false)
                    }
                    if !layout.fillsPhone {
                        uprightControls(layout)
                    } else {
                        floatingControls(layout)
                    }
                    if pointerRefused && !showRevealHint {
                        Label("請將 Henge 設為全螢幕，才能將觸控板或滑鼠交給虛擬 Mac 使用", systemImage: "cursorarrow.rays")
                            .font(.system(size: 15, weight: .medium))
                            .foregroundStyle(.white)
                            .padding(.horizontal, 18).padding(.vertical, 12)
                            .deskGlass(in: Capsule())
                            .position(x: full.width / 2, y: insets.top + 40)
                            .transition(.opacity)
                            .allowsHitTesting(false)
                    }
                    if showRevealHint {
                        Label("四指同時輕點螢幕即可顯示控制列", systemImage: "hand.tap")
                            .font(.system(size: 15, weight: .medium))
                            .foregroundStyle(.white)
                            .padding(.horizontal, 18).padding(.vertical, 12)
                            .deskGlass(in: Capsule())
                            .position(x: full.width / 2, y: insets.top + 40)
                            .transition(.opacity)
                            .allowsHitTesting(false)
                    }
                    if showWallpaperTip && !showRevealHint && !pointerRefused {
                        Label("提示：在 Mac「系統設定」改用靜態純色桌布並將螢幕保護程式設為「永不」，可大幅提升流暢度。", systemImage: "speedometer")
                            .font(.system(size: 15, weight: .medium))
                            .foregroundStyle(.white)
                            .multilineTextAlignment(.leading)
                            .frame(maxWidth: min(full.width - 40, 520))
                            .padding(.horizontal, 18).padding(.vertical, 12)
                            .deskGlass(in: RoundedRectangle(cornerRadius: 22, style: .continuous))
                            .position(x: full.width / 2, y: insets.top + 56)
                            .transition(.opacity)
                            .allowsHitTesting(false)
                    }
                }
                if state == 2 {
                    StoppedMacView(outcome: henge_vm_exit_outcome(), reason: String(cString: henge_vm_exit_reason()),
                                   start: { bootAttempt += 1 }, close: close)
                        .frame(width: min(layout.touch.width - 32, 360))
                        .position(x: layout.touch.midX, y: layout.fillsPhone ? layout.touch.midY : layout.pad.midY)
                }
                if let error { errorCard(error, layout) }
                KeyboardCatcher(active: $typing).frame(width: 0, height: 0)
            }
            .frame(width: full.width, height: full.height)
            .ignoresSafeArea()
            .animation(.easeInOut(duration: 0.25), value: zoomed)
            .animation(.easeInOut(duration: 0.25), value: typing)
            .animation(.easeInOut(duration: 0.25), value: controlsHidden)
            .animation(.easeInOut(duration: 0.25), value: showRevealHint)
            .animation(.easeInOut(duration: 0.25), value: showWallpaperTip)
            .onReceive(NotificationCenter.default.publisher(for: UIPointerLockState.didChangeNotification)) { _ in
                pointerRefused = PointerLock.refused
            }
            .onReceive(NotificationCenter.default.publisher(for: .GCMouseDidConnect)) { _ in
                DispatchQueue.main.asyncAfter(deadline: .now() + 1) { pointerRefused = PointerLock.refused }
            }
            .onReceive(NotificationCenter.default.publisher(for: Trackpad.revealTap)) { _ in
                controlsHidden = false
                showRevealHint = false
            }
            .onAppear { shown = layout.shown }
            .onChange(of: layout.shown) { shown = $0 }
        }
        .statusBarHidden(zoomed || Device.isPad)
        .persistentSystemOverlays(.hidden)
        .sheet(isPresented: $showDetails) { details }
        .confirmationDialog("確定要強制關閉「\(mac.name)」嗎？", isPresented: $confirmStop, titleVisibility: .visible) {
            Button("強制關機", role: .destructive) { finish() }
        } message: {
            Text("這會立即切斷虛擬 Mac 電源，任何尚未儲存的檔案或進度將會遺失。")
        }
        .onChange(of: zoomed) { on in
            zoomFollowing?.cancel()
            zoomFollowing = on ? Task { await followPointer() } : nil
        }
        .onChange(of: pointerNeeded) { PointerLock.set(!$0) }
        .onChange(of: scenePhase) { phase in
            let currentMac = runningMac ?? mac
            guard phase != .active else {
                display.refresh()
                InstantResume.cameBack(currentMac)
                return
            }
            HardwareKeys.releaseAll()
            HardwareMouse.shared.releaseButtons()
            VolumeClicks.shared.releaseButtons()
            if phase == .inactive { InstantResume.pause() }
            if phase == .background && bootRAM > 0 { InstantResume.suspend(currentMac, ramMB: bootRAM, cpus: bootCPUs) }
        }
        .onChange(of: showDetails) { showing in
            if showing { HardwareKeys.releaseAll(); StickyKeys.shared.releaseAll() }
        }
        .onChange(of: confirmStop) { showing in
            if showing { HardwareKeys.releaseAll(); StickyKeys.shared.releaseAll() }
        }
        .onAppear {
            UIApplication.shared.isIdleTimerDisabled = true
            HardwareMouse.shared.start()
            VolumeClicks.shared.start()
        }
        .onDisappear {
            UIApplication.shared.isIdleTimerDisabled = false
            zoomFollowing?.cancel()
            StickyKeys.shared.releaseAll()
            HardwareKeys.releaseAll()
            HardwareMouse.shared.stop()
            VolumeClicks.shared.stop()
        }
        .modifier(ExternalMacDisplayModifier(presentation: MacPresentation(display: display, aspect: mac.aspect)))
        .task(id: bootAttempt) { await run() }
        .task { await Sharing.followMacClipboard() }
    }

    /// When there is something of the app's to point at, iPadOS gets its own pointer back.
    private var pointerNeeded: Bool { state == 2 || showDetails || confirmStop || error != nil }

    // MARK: Layout

    /// Where everything goes, in points from the device's top left corner.
    private struct Layout {
        let screen: CGRect
        let touch: CGRect     // what is a trackpad besides the pad itself
        let fillsPhone: Bool
        let toolsY: CGFloat
        let pad: CGRect
        let insets: EdgeInsets
        var barY: CGFloat?    // where the controls go in the space beside the screen, if it has room for them

        var shown: CGSize {
            CGSize(width: min(touch.width / max(screen.width, 1), 1), height: min(touch.height / max(screen.height, 1), 1))
        }

        init(full: CGSize, insets: EdgeInsets, landscape: Bool, zoomed: Bool, typing: Bool, centre: CGPoint, aspect: CGFloat) {
            self.insets = insets
            let big = full.height >= 600 // an iPad on its side, or a window on one
            if zoomed {
                // Upright, as tall as the device. On its side, bigger than it fits: a big screen needs less.
                let height = landscape ? full.height * (big ? 1.5 : 2) : max(full.height - insets.bottom, full.width / aspect)
                let width = height * aspect
                let x = min(0, max(full.width - width, full.width / 2 - centre.x * width))
                let y = min(0, max(full.height - height, full.height / 2 - centre.y * height))
                screen = CGRect(x: x, y: y, width: width, height: height)
                touch = CGRect(origin: .zero, size: full)
                fillsPhone = true
                toolsY = 0
                pad = .zero
            } else if landscape, big {
                // Room to keep the controls off the Mac's menu bar, and the Mac above the on-screen keyboard.
                let bar: CGFloat = 62
                let room = typing ? full.height - insets.bottom - insets.top - bar - 8 : full.height
                // An iPad keeps clear of its side insets; a big iPhone (iPhone Duo) fills edge to edge.
                let side = Device.isPad ? 2 * max(insets.leading, insets.trailing) : 0
                let height = max(min(room, (full.width - side) / aspect), 200)
                let width = height * aspect
                let y = typing ? insets.top + bar : (full.height - height) / 2
                screen = CGRect(x: (full.width - width) / 2, y: y, width: width, height: height)
                touch = CGRect(origin: .zero, size: full)
                fillsPhone = true
                toolsY = 0
                pad = .zero
                if y - insets.top >= 54 { barY = insets.top + (y - insets.top) / 2 }
            } else if landscape {
                // Edge to edge. Phones wider than the Mac fill the height with room to spare beside the
                // Dynamic Island; a squarer phone (iPhone Duo) fills all of it, island and corners included.
                let height = min(full.height, full.width / aspect)
                let width = height * aspect
                screen = CGRect(x: (full.width - width) / 2, y: (full.height - height) / 2, width: width, height: height)
                touch = CGRect(origin: .zero, size: full)
                fillsPhone = true
                toolsY = 0
                pad = .zero
            } else {
                let width = full.width - 16
                let height = width / aspect
                screen = CGRect(x: 8, y: insets.top + 6, width: width, height: height)
                touch = screen
                fillsPhone = false
                toolsY = screen.maxY + 10
                let top = typing ? screen.maxY + 8 : toolsY + 54 + 10
                let bottom = full.height - insets.bottom - (typing ? 8 : 0)
                pad = CGRect(x: 8, y: top, width: width, height: max(bottom - top, 60))
            }
        }
    }

    // MARK: Upright

    @ViewBuilder private func uprightControls(_ layout: Layout) -> some View {
        if !typing && !controlsHidden {
            HStack {
                tool("eye.slash", "隱藏控制列") { hideControls() }
                Spacer()
                tool("keyboard", "鍵盤") { typing = true }
                Spacer()
                pasteTool
                Spacer()
                tool("plus.magnifyingglass", "放大檢視") { zoomed = true }
                Spacer()
                tool("info.circle", "詳細資訊") { showDetails = true }
                Spacer()
                tool("power", "關機", tint: Desk.bad) { stopTapped() }
            }
            .padding(.horizontal, 22)
            .frame(width: layout.pad.width, height: 54)
            .background(Desk.card, in: Capsule())
            .overlay(Capsule().stroke(Desk.hairline, lineWidth: 0.5))
            .position(x: layout.pad.midX, y: layout.toolsY + 27)
            .transition(.opacity)
        }
        trackpadPanel(layout)
    }

    private func trackpadPanel(_ layout: Layout) -> some View {
        let compact = layout.pad.height < 260
        return VStack(spacing: 0) {
            ZStack {
                Trackpad()
                if compact {
                    Text("觸控板").font(.system(size: 14)).foregroundStyle(Desk.faint).allowsHitTesting(false)
                } else {
                    VStack(spacing: 6) {
                        hint("滑動", "移動游標")
                        hint("輕點", "左鍵點擊")
                        hint("按住再滑動", "拖曳視窗或選取")
                        hint("雙指滑動", "捲動頁面")
                    }
                    .allowsHitTesting(false)
                }
            }
            Rectangle().fill(Desk.hairline).frame(height: 0.5)
            HStack(spacing: 0) {
                MouseButton(title: "左鍵點擊", button: 0)
                Rectangle().fill(Desk.hairline).frame(width: 0.5)
                MouseButton(title: "右鍵點擊", button: 1)
            }
            .frame(height: compact ? 50 : 70)
        }
        .background(Desk.card)
        .clipShape(RoundedRectangle(cornerRadius: 30, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 30, style: .continuous).stroke(Desk.hairline, lineWidth: 0.5))
        .frame(width: layout.pad.width, height: layout.pad.height)
        .position(x: layout.pad.midX, y: layout.pad.midY)
    }

    private func hint(_ strong: String, _ rest: String) -> some View {
        (Text(strong).foregroundColor(Desk.dim).fontWeight(.semibold) + Text(" \(rest)").foregroundColor(Desk.faint))
            .font(.system(size: 15))
    }

    /// The system's paste button: iOS asks no permission for it, as it would if the app read the clipboard itself.
    private var pasteTool: some View {
        PasteButton(payloadType: String.self) { texts in
            if let text = texts.first { Sharing.paste(text) }
        }
        .labelStyle(.iconOnly)
        .buttonBorderShape(.circle)
        .tint(Desk.raised)
    }

    /// Hides the session's controls; four fingers on the screen bring them back. The first few times say so.
    private func hideControls() {
        controlsHidden = true
        typing = false
        guard revealHintsShown < 3 else { return }
        revealHintsShown += 1
        showRevealHint = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 3) { showRevealHint = false }
    }

    private func tool(_ symbol: String, _ label: String, tint: Color = Desk.text, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 19, weight: .medium))
                .foregroundStyle(tint)
                .frame(width: 44, height: 44)
                .contentShape(Rectangle())
        }
        .accessibilityLabel(label)
    }

    // MARK: Filling the phone

    @ViewBuilder private func floatingControls(_ layout: Layout) -> some View {
        let landscape = layout.touch.width > layout.touch.height
        let top = layout.insets.top + (landscape ? 8 : 6)
        let pill = HStack(spacing: 4) {
            tool("eye.slash", "隱藏控制列", tint: .white) { hideControls() }
            tool("keyboard", "鍵盤", tint: .white) { typing.toggle() }
            pasteTool
            tool(zoomed ? "minus.magnifyingglass" : "plus.magnifyingglass", zoomed ? "恢復檢視" : "放大檢視", tint: zoomed ? Desk.accentLight : .white) { zoomed.toggle() }
            tool("info.circle", "詳細資訊", tint: .white) { showDetails = true }
            Rectangle().fill(Color.white.opacity(0.3)).frame(width: 1, height: 22).padding(.horizontal, 4)
            tool("power", "關機", tint: Desk.bad) { stopTapped() }
        }
        .padding(.horizontal, 8)
        .frame(height: 50)
        .deskGlass(in: Capsule())
        if controlsHidden {
            EmptyView()
        } else if let barY = layout.barY {
            pill.position(x: layout.touch.midX, y: barY)
        } else if landscape || typing {
            pill.position(x: layout.touch.midX, y: top + 25)
        } else {
            pill.position(x: layout.touch.midX, y: layout.touch.height - layout.insets.bottom - 34)
        }
        if zoomed { zoomMap(layout) }
    }

    /// The whole screen, small, with where the zoomed view is on it.
    private func zoomMap(_ layout: Layout) -> some View {
        let width: CGFloat = 112, height = width / mac.aspect
        let viewW = min(layout.touch.width / layout.screen.width, 1) * width
        let viewH = min(layout.touch.height / layout.screen.height, 1) * height
        let left = (-layout.screen.minX / layout.screen.width) * width
        let top = (-layout.screen.minY / layout.screen.height) * height
        return ZStack(alignment: .topLeading) {
            Color.black
            if let map { Image(uiImage: map).resizable() }
            RoundedRectangle(cornerRadius: 3).stroke(Color.white, lineWidth: 1.5)
                .frame(width: viewW, height: viewH)
                .offset(x: left, y: top)
        }
        .frame(width: width, height: height)
        .clipShape(RoundedRectangle(cornerRadius: 9, style: .continuous))
        .padding(3)
        .deskGlass(in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .position(x: layout.touch.width - width / 2 - 15, y: layout.insets.top + height / 2 + 20)
        .allowsHitTesting(false)
    }

    /// Keeps the pointer in view: the view moves when the pointer nears its edge.
    private func followPointer() async {
        var tick = 0
        while !Task.isCancelled {
            var x: Int32 = 0, y: Int32 = 0
            if henge_vm_pointer(&x, &y) == 0 {
                moveZoom(toward: CGPoint(x: CGFloat(x) / CGFloat(mac.screen.width), y: CGFloat(y) / CGFloat(mac.screen.height)))
            }
            if tick % 60 == 0, let image = MacPreview.capture(width: 224, height: Int(224 / mac.aspect)) { map = UIImage(cgImage: image) }
            tick += 1
            try? await Task.sleep(nanoseconds: 33_000_000)
        }
    }

    private func moveZoom(toward p: CGPoint) {
        // How much of the screen the view shows, and a margin inside that.
        let shownX = shown.width, shownY = shown.height
        let reachX = shownX * 0.3, reachY = shownY * 0.3
        var c = zoomCentre
        if p.x < c.x - reachX { c.x = p.x + reachX } else if p.x > c.x + reachX { c.x = p.x - reachX }
        if p.y < c.y - reachY { c.y = p.y + reachY } else if p.y > c.y + reachY { c.y = p.y - reachY }
        c.x = min(max(c.x, shownX / 2), 1 - shownX / 2)
        c.y = min(max(c.y, shownY / 2), 1 - shownY / 2)
        guard c != zoomCentre else { return }
        withAnimation(.linear(duration: 0.08)) { zoomCentre = c }
    }

    // MARK: Status

    private func errorCard(_ text: String, _ layout: Layout) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("這台 Mac 無法啟動").font(.system(size: 17, weight: .semibold))
            Text(text).font(.system(size: 14)).foregroundStyle(Desk.dim)
            Button("關閉") { close() }.font(.system(size: 15, weight: .semibold)).foregroundStyle(Desk.accentLight)
        }
        .padding(18)
        .frame(width: min(layout.touch.width, 390) - 32, alignment: .leading)
        .background(Desk.raised, in: RoundedRectangle(cornerRadius: 22, style: .continuous))
        .position(x: (layout.fillsPhone ? layout.touch.midX : layout.pad.midX), y: layout.fillsPhone ? layout.touch.midY : layout.pad.midY)
    }

    private var phase: String {
        switch state {
        case 0: return error == nil ? "正在啟動…" : "尚未啟動"
        case 1: return userCode ? "macOS 執行中" : "正在開機"
        case 3: return "正在完成關機…"
        default: return "已停止（\(String(cString: henge_vm_exit_reason()))）"
        }
    }

    private var ramModeLabel: String {
        switch ramMode {
        case 1: return "免計入上限 No Footprint"
        case 2: return "檔案映射"
        case 3: return "匿名記憶體"
        default: return "配置中"
        }
    }

    private var details: some View {
        NavigationStack {
            List {
                Section(phase) {
                    let ramText = bootRAM % 1024 == 0
                        ? "\(bootRAM / 1024) GB"
                        : String(format: "%.1f GB", Double(bootRAM) / 1024.0)
                    LabeledContent("儲存位置", value: mac.isExternal ? "外接 SSD（\(mac.externalDriveName ?? "外接硬碟")）" : "此 \(Device.name)")
                    LabeledContent("記憶體配置", value: bootRAM > 0 ? "\(ramText)（\(ramModeLabel)）" : ramModeLabel)
                    LabeledContent("運行中 CPU", value: "\(cpusOn)／\(bootCPUs)")
                    LabeledContent("裝置溫度", value: Self.thermalLabel(thermalState))
                    LabeledContent("指令轉譯率", value: String(format: "%.1f M/s", blocksPerSecond / 1e6))
                    LabeledContent("網路封包", value: "送出 \(framesOut)，接收 \(framesIn)")
                    LabeledContent("已運行時間", value: "\(Int(Date().timeIntervalSince(started))) 秒")
                }
                Section("顯示器") {
                    Toggle("螢幕色彩同步", isOn: $matchScreenColors)
                    LabeledContent("畫面亮度", value: "\(Int(screenBrightness * 100))%")
                    Slider(value: $screenBrightness, in: 0.4...1)
                    Text("只調整虛擬 Mac 畫面的顯示亮度。")
                        .font(.footnote).foregroundStyle(.secondary)
                }
                Section("指標") {
                    Picker("指標大小", selection: $cursorScale) {
                        Text("1×").tag(1)
                        Text("2×").tag(2)
                        Text("3×").tag(3)
                    }
                    .pickerStyle(.segmented)
                    Toggle("銳利邊緣", isOn: $sharpCursor)
                    LabeledContent("捲動速度", value: String(format: "%.1f×", scrollSpeed))
                    Slider(value: $scrollSpeed, in: 0.1...1.5)
                    Text("macOS 提供的指標影像較小，在 iPad 上設為 1× 最銳利；捲動速度會立即生效。")
                        .font(.footnote).foregroundStyle(.secondary)
                }
                Section("剪貼簿與資料夾共享") {
                    LabeledContent("狀態", value: helperRunning ? "已啟用" : "尚未設定")
                    if !helperRunning {
                        Button("自動輸入設定指令") {
                            showDetails = false
                            Task {
                                try? await Task.sleep(nanoseconds: 600_000_000)
                                await Sharing.typeSetUpCommand()
                            }
                        }
                    }
                    Text(helperRunning
                         ? "將檔案放到「檔案 › Henge › Shared」即可在 Mac 家目錄的「Henge」資料夾存取。在 Mac 複製純文字會自動同步至此，iPad 複製後請點上方第三顆貼上鈕傳給 Mac。"
                         : "每台 Mac 只需設定一次：先開啟 Mac 裡的終端機，點按上方按鈕後按 Return 執行；若彈出區域網路權限詢問請選允許（輸入時 Mac 輸入法需為英文）。")
                        .font(.footnote).foregroundStyle(.secondary)
                }
                Section("輕量化 macOS") {
                    Button("輸入輕量化設定指令") {
                        showDetails = false
                        Task {
                            try? await Task.sleep(nanoseconds: 600_000_000)
                            await Keys.typeSlowly(Sharing.lightenCommand)
                        }
                    }
                    Button("輸入還原指令") {
                        showDetails = false
                        Task {
                            try? await Task.sleep(nanoseconds: 600_000_000)
                            await Keys.typeSlowly(Sharing.unlightenCommand)
                        }
                    }
                    Text("減少模擬 CPU 的繪圖負荷：關閉視窗動畫、Dock 動畫、桌面小工具與動態桌布。請先開啟 Mac 終端機，點按按鈕後按 Return 執行，並登出再登入即可生效（建議另於系統設定開啟「減少動態效果」與「減少透明度」）。")
                        .font(.footnote).foregroundStyle(.secondary)
                }
                Section("日誌") {
                    VStack(alignment: .leading, spacing: 1) {
                        ForEach(Array(log.suffix(30).enumerated()), id: \.offset) { _, line in
                            Text(line).font(.system(size: 10, design: .monospaced)).foregroundStyle(.secondary)
                        }
                    }
                }
            }
            .navigationTitle("詳細資訊")
            .navigationBarTitleDisplayMode(.inline)
        }
    }

    // MARK: Running

    private static func thermalLabel(_ state: ProcessInfo.ThermalState) -> String {
        switch state {
        case .nominal: return "正常"
        case .fair: return "微溫"
        case .serious: return "過熱 — 已自動降頻"
        case .critical: return "嚴重過熱"
        @unknown default: return "未知"
        }
    }

    private func run() async {
        error = nil
        state = 0
        userCode = false
        cpusOn = 0
        bootRAM = 0
        ramMode = 0
        blocksPerSecond = 0
        framesOut = 0
        framesIn = 0
        zoomed = false
        controlsHidden = false
        showRevealHint = false
        zoomCentre = CGPoint(x: 0.5, y: 0.5)
        map = nil
        showWallpaperTip = false
        while henge_vm_state() == 3 && !Task.isCancelled {
            try? await Task.sleep(nanoseconds: 100_000_000)
        }
        guard !Task.isCancelled else { return }
        let liveMac = Machines.shared.all.first(where: { $0.id == mac.id }) ?? mac
        runningMac = liveMac
        if liveMac.isExternal && !Machines.shared.ensureExternalAccess(for: liveMac) {
            error = "外接 SSD（\(liveMac.externalDriveName ?? "外接硬碟")）未連接，請插上後再試。"
            return
        }
        UIApplication.shared.isIdleTimerDisabled = true
        HardwareMouse.shared.start()
        let ram = GuestMemory.prepare(liveMac)
        HengeLog.log("session", "available memory \(henge_available_memory() >> 20) MB")
        guard ram >= 1024 else {
            error = "此 \(Device.name) 本機可用空間不足，無法配置虛擬 Mac 記憶體（請至少保留數 GB 空間）。"
            return
        }
        var buffer = [CChar](repeating: 0, count: 256)
        JITBootstrap.releaseLingeringDebugger()
        Sharing.prepare()
        EngineTuning.apply()
        henge_vm_set_display(UInt32(liveMac.screen.width), UInt32(liveMac.screen.height))
        if liveMac.isRetina {
            henge_vm_set_display_mm(UInt32(Device.retinaMM.width), UInt32(Device.retinaMM.height))
        } else {
            henge_vm_set_display_mm(0, 0)
        }
        HengeLog.log("session", "screen \(liveMac.screen.width)x\(liveMac.screen.height) retina \(liveMac.isRetina)")
        if liveMac.reportHostIdentity == true {
            let modelID = Device.snappedModelIdentifier(forOS: liveMac.osName)
            henge_vm_set_identity(Device.chipName, Device.marketingName,
                                  liveMac.reportHostModelID == true ? modelID : nil)
            HengeLog.log("session", "About This Mac reports \(Device.marketingName) (model \(modelID))")
        } else {
            henge_vm_set_identity(nil, nil, nil)
        }
        let activeCPUs = liveMac.effectiveCPUs
        if activeCPUs != liveMac.configuredCPUs {
            HengeLog.log("session", "adaptive CPU count: \(activeCPUs) of configured \(liveMac.configuredCPUs) for host")
        }
        var rc: Int32 = -1
        if InstantResume.enabled, let at = InstantResume.saved(for: liveMac, ramMB: ram, cpus: activeCPUs) {
            HengeLog.log("resume", "picking up the Mac saved \(Int(Date().timeIntervalSince(at))) s ago")
            let t0 = Date()
            rc = henge_vm_resume(liveMac.rom.path, liveMac.disk.path, liveMac.aux.path, liveMac.ecid, liveMac.seed, ram, Int32(activeCPUs),
                                 InstantResume.file(for: liveMac).path, InstantResume.ident(for: liveMac, ramMB: ram, cpus: activeCPUs), &buffer, buffer.count)
            if rc == 0 {
                HengeLog.log("resume", String(format: "resumed in %.1f s", Date().timeIntervalSince(t0)))
            } else {
                HengeLog.log("resume", "could not resume (\(String(cString: buffer))); starting it from cold")
                buffer = [CChar](repeating: 0, count: 256)
            }
        }
        InstantResume.discard(for: liveMac) /* used or out of date: the disk moves on from here */
        if rc != 0 {
            rc = henge_vm_boot(liveMac.rom.path, liveMac.disk.path, liveMac.aux.path, liveMac.ecid, liveMac.seed, ram, Int32(activeCPUs), &buffer, buffer.count)
        }
        if rc != 0 {
            error = String(cString: buffer)
            return
        }
        bootRAM = ram
        bootCPUs = activeCPUs
        ramMode = henge_vm_ram_mode()
        HengeLog.log("session", "active RAM \(ram) MB, CPUs \(activeCPUs), backing mode \(ramMode)")
        started = Date()
        var used = liveMac
        used.lastUsed = started
        Machines.shared.update(used)
        var lastBlocks = henge_vm_blocks()
        var lastTime = Date()
        var lastGPUFrames = henge_vm_gpu_frames()
        var tick = 0
        while !Task.isCancelled {
            state = henge_vm_state()
            if state == 3 || state == 4 { /* starting, stopping, or paused while Henge is in the background */
                try? await Task.sleep(nanoseconds: 100_000_000)
                continue
            }
            cpusOn = henge_vm_cpus_on()
            userCode = userCode || henge_vm_guest_el0() != 0
            let now = Date(), blocks = henge_vm_blocks()
            blocksPerSecond = Double(blocks &- lastBlocks) / max(now.timeIntervalSince(lastTime), 0.001)
            lastBlocks = blocks
            lastTime = now
            framesOut = henge_vm_net_frames(1)
            framesIn = henge_vm_net_frames(0)
            helperRunning = Sharing.helperRunning
            log = Array(HengeLog.recentLines(200))
            let heat = ProcessInfo.processInfo.thermalState
            if heat.rawValue != thermalState.rawValue {
                thermalState = heat
                HengeLog.log("session", "thermal state: \(Self.thermalLabel(heat))")
            }
            if state == 2 {
                typing = false
                showDetails = false
                confirmStop = false
                zoomFollowing?.cancel()
                StickyKeys.shared.releaseAll()
                HardwareKeys.releaseAll()
                HardwareMouse.shared.stop()
                InstantResume.discard(for: mac)
                UIApplication.shared.isIdleTimerDisabled = false
                HengeLog.log("session", "showing stopped Mac: \(String(cString: henge_vm_exit_reason()))")
                if henge_vm_exit_outcome() == Int32(HENGE_VM_OUTCOME_RESTART.rawValue) && henge_vm_can_start() != 0 {
                    bootAttempt += 1
                }
                break
            }
            tick += 1
            if tick % 10 == 0 {
                let gpuFrames = henge_vm_gpu_frames()
                HengeLog.log("perf", "blocks/s \(String(format: "%.0f", blocksPerSecond)), GPU frames/10s \(gpuFrames &- lastGPUFrames), "
                             + "network tx \(framesOut), rx \(framesIn), dns \(henge_vm_dns(0)) answered \(henge_vm_dns(2)) unanswered, "
                             + "thermal \(Self.thermalLabel(heat))")
                lastGPUFrames = gpuFrames
                JITBootstrap.releaseLingeringDebugger()
            }
            if tick == 60 && !stillWallpaperTipShown { // about when the desktop is up after a login
                stillWallpaperTipShown = true
                showWallpaperTip = true
                DispatchQueue.main.asyncAfter(deadline: .now() + 10) { showWallpaperTip = false }
            }
            if tick % 30 == 0 { HengeLog.logFootprint("session") } // how close to the limit, for a memory kill leaves no crash report
            if tick % 60 == 0 { MacPreview.save(for: mac) }
            try? await Task.sleep(nanoseconds: 1_000_000_000)
        }
    }

    private func stopTapped() {
        if state == 1 { confirmStop = true } else { close() }
    }

    private func finish() {
        if state == 1 || state == 4 {
            MacPreview.saveNow(for: mac)
            henge_vm_stop()
        }
        InstantResume.discard(for: mac) /* turned off: nothing to pick up */
        close()
    }
}
