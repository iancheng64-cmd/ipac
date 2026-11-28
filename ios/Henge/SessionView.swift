import SwiftUI
import GameController

/// A running Mac. Upright, its screen sits above a trackpad; on its side the screen fills the device
/// and is its own trackpad. Zoomed in, the screen fills the device either way and follows the pointer.
/// A keyboard, trackpad or mouse attached to an iPad works throughout.
struct SessionView: View {
    @Environment(\.locale) private var interfaceLocale
    let mac: VirtualMac
    let close: () -> Void

    @StateObject private var display = DisplayRouter()
    @State private var error: String?
    @State private var state: Int32 = 0
    @State private var bootAttempt = 0
    @State private var retainedSnapshot = false
    @State private var confirmDiscard = false
    @State private var cpusOn: Int32 = 0
    @State private var userCode = false
    @State private var blocksPerSecond: Double = 0
    @State private var framesOut: UInt64 = 0
    @State private var framesIn: UInt64 = 0
    @State private var log: [String] = []
    @State private var started = Date()
    @State private var thermalState = ProcessInfo.processInfo.thermalState
    @State private var bootRAM: UInt64 = 0 /* what the Mac was started with, which a save is for */
    @State private var requestedRAMMB = 0
    @State private var bootCPUs: Int = 4
    @State private var ramMode: Int32 = 0
    @State private var runningMac: VirtualMac?
    @AppStorage("henge.matchScreenColors") private var matchScreenColors = true
    @AppStorage("henge.display.brightness") private var screenBrightness = 1.0
    @AppStorage("henge.cursor.scale") private var cursorScale = Device.isPad ? 1 : 3
    @AppStorage("henge.cursor.sharp") private var sharpCursor = true
    @AppStorage(HardwareMouse.speedKey) private var mouseSpeed = 1.0
    @AppStorage(HardwareMouse.reverseKey) private var reverseScrolling = false
    @AppStorage(HardwareMouse.scrollSpeedKey) private var scrollSpeed = 0.3
    @AppStorage(TrackpadTouchMode.storageKey) private var touchModeRaw = TrackpadTouchMode.trackpad.rawValue

    @State private var keyboard: SessionHUDPolicy.KeyboardPresentation = .none
    @StateObject private var sillKeyboard = SillKeyboardController()
    @State private var zoomed = false
    @State private var showDetails = false
    @State private var controlsHidden = false
    @State private var showRevealHint = false
    @AppStorage("henge.controls.hintsShown") private var revealHintsShown = 0
    @State private var pointerRefused = false
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


    private var touchMode: TrackpadTouchMode {
        TrackpadTouchMode(rawValue: touchModeRaw) ?? .trackpad
    }

    private var systemIMEBinding: Binding<Bool> {
        Binding(
            get: { keyboard == .systemIME },
            set: { on in keyboard = on ? .systemIME : (keyboard == .systemIME ? .none : keyboard) }
        )
    }

    private func toggleControlsFromGesture() {
        var hidden = controlsHidden
        var kb = keyboard
        var hint = showRevealHint
        SessionHUDPolicy.toggleControls(controlsHidden: &hidden, keyboard: &kb, showRevealHint: &hint)
        controlsHidden = hidden
        keyboard = kb
        showRevealHint = hint
        if hidden {
            sillKeyboard.releaseAll()
        }
    }

    private func toggleSillKeyboard() {
        UIImpactFeedbackGenerator(style: .light).impactOccurred()
        if keyboard == .none {
            controlsHidden = false
            keyboard = .sill
        } else {
            sillKeyboard.releaseAll()
            keyboard = .none
        }
    }

    var body: some View {
        let _ = interfaceLocale
        GeometryReader { geo in
            let insets = geo.safeAreaInsets
            let full = CGSize(width: geo.size.width + insets.leading + insets.trailing,
                              height: geo.size.height + insets.top + insets.bottom)
            let landscape = full.width > full.height
            let layout = Layout(
                full: full,
                insets: insets,
                landscape: landscape,
                zoomed: zoomed,
                typing: keyboard == .systemIME,
                sillKeyboardOpen: false,
                centre: zoomCentre,
                aspect: mac.aspect
            )
            ZStack(alignment: .topLeading) {
                (landscape || zoomed ? Color.black : Desk.page)
                // One view in every layout: it holds the layer the engine draws into.
                BootDisplay(display: display, role: .device)
                    .opacity(display.isExternal ? 0 : 1)
                    .overlay {
                        if display.isExternal && state != 2 {
                            VStack(spacing: 8) {
                                Image(systemName: "display").font(.largeTitle)
                                Text(L10n.text("Mac 畫面已輸出至外接螢幕")).font(.headline)
                                Text(L10n.text("請使用觸控螢幕、鍵盤或外接滑鼠操作。"))
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
                    Trackpad(
                        touchMode: touchMode,
                        screenRect: layout.screen.offsetBy(dx: -layout.touch.minX, dy: -layout.touch.minY),
                        pointerSpeed: mouseSpeed,
                        scrollSpeed: scrollSpeed,
                        reverseScrolling: reverseScrolling,
                        onToggleHud: toggleControlsFromGesture
                    )
                    .frame(width: layout.touch.width, height: layout.touch.height)
                    .position(x: layout.touch.midX, y: layout.touch.midY)
                    if inputMode == .volumeButtons && volumeMode == .intercept {
                        // The capture interaction must live in the SwiftUI hierarchy to receive
                        // the volume-button events; it passes touches through to the trackpad.
                        CaptureInteractionView()
                            .frame(maxWidth: .infinity, maxHeight: .infinity)
                            .allowsHitTesting(false)
                    }
                    if keyboard == .sill {
                        SillVirtualKeyboardView(
                            controller: sillKeyboard,
                            onSwitchToIME: {
                                sillKeyboard.releaseAll()
                                keyboard = .systemIME
                            },
                            onDismiss: {
                                sillKeyboard.releaseAll()
                                keyboard = .none
                            }
                        )
                        .frame(width: full.width, height: full.height)
                        .zIndex(5)
                    }
                    if !layout.fillsPhone {
                        uprightControls(layout)
                            .zIndex(10)
                    } else {
                        floatingControls(layout)
                            .zIndex(10)
                    }
                    if pointerRefused && !showRevealHint {
                        Label(L10n.text("請將 Henge 設為全螢幕，才能將觸控板或滑鼠交給虛擬 Mac 使用"), systemImage: "cursorarrow.rays")
                            .font(.system(size: 15, weight: .medium))
                            .foregroundStyle(.white)
                            .padding(.horizontal, 18).padding(.vertical, 12)
                            .deskGlass(in: Capsule())
                            .position(x: full.width / 2, y: insets.top + 40)
                            .transition(.opacity)
                            .allowsHitTesting(false)
                    }
                    if showRevealHint {
                        Label(L10n.text("四指同時輕點螢幕即可顯示控制列"), systemImage: "hand.tap")
                            .font(.system(size: 15, weight: .medium))
                            .foregroundStyle(.white)
                            .padding(.horizontal, 18).padding(.vertical, 12)
                            .deskGlass(in: Capsule())
                            .position(x: full.width / 2, y: insets.top + 40)
                            .transition(.opacity)
                            .allowsHitTesting(false)
                    }
                    if showWallpaperTip && !showRevealHint && !pointerRefused {
                        Label(L10n.text("提示：在 Mac「系統設定」改用靜態純色桌布並將螢幕保護程式設為「永不」，可大幅提升流暢度。"), systemImage: "speedometer")
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
                KeyboardCatcher(
                    active: systemIMEBinding,
                    switchToSill: {
                        keyboard = .sill
                    }
                )
                .frame(width: 0, height: 0)
            }
            .frame(width: full.width, height: full.height)
            .ignoresSafeArea()
            .animation(.easeInOut(duration: 0.24), value: zoomed)
            .animation(.easeInOut(duration: 0.22), value: controlsHidden)
            .animation(.easeInOut(duration: 0.25), value: showRevealHint)
            .animation(.easeInOut(duration: 0.25), value: showWallpaperTip)
            .onReceive(NotificationCenter.default.publisher(for: UIPointerLockState.didChangeNotification)) { _ in
                pointerRefused = PointerLock.refused
            }
            .onReceive(NotificationCenter.default.publisher(for: .GCMouseDidConnect)) { _ in
                DispatchQueue.main.asyncAfter(deadline: .now() + 1) { pointerRefused = PointerLock.refused }
            }
            .onReceive(NotificationCenter.default.publisher(for: Trackpad.revealTap)) { _ in
                toggleControlsFromGesture()
            }
            .onAppear { shown = layout.shown }
            .onChange(of: layout.shown) { shown = $0 }
        }
        .statusBarHidden(zoomed || Device.isPad)
        .persistentSystemOverlays(.hidden)
        .sheet(isPresented: $showDetails) { details }
        .confirmationDialog(L10n.format("確定要強制關閉「%@」嗎？", String(describing: mac.name)), isPresented: $confirmStop, titleVisibility: .visible) {
            Button(L10n.text("強制關機"), role: .destructive) { finish() }
        } message: {
            Text(L10n.text("這會立即切斷虛擬 Mac 電源，任何尚未儲存的檔案或進度將會遺失。"))
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
            sillKeyboard.releaseAll()
            HardwareMouse.shared.releaseButtons()
            henge_vm_absolute_cancel()
            VolumeClicks.shared.releaseButtons()
            if phase == .inactive { InstantResume.pause() }
            if phase == .background && bootRAM > 0 { InstantResume.suspend(currentMac, ramMB: bootRAM, cpus: bootCPUs) }
        }
        .onChange(of: showDetails) { showing in
            if showing { HardwareKeys.releaseAll(); StickyKeys.shared.releaseAll(); sillKeyboard.releaseAll() }
        }
        .onChange(of: confirmStop) { showing in
            if showing { HardwareKeys.releaseAll(); StickyKeys.shared.releaseAll(); sillKeyboard.releaseAll() }
        }
        .onChange(of: scrollSpeed) { value in HardwareMouse.shared.updateScrollSpeed(value) }
        .onChange(of: cursorScale) { value in henge_vm_set_cursor_style(Int32(value), sharpCursor ? 1 : 0) }
        .onChange(of: sharpCursor) { value in henge_vm_set_cursor_style(Int32(cursorScale), value ? 1 : 0) }
        .onAppear {
            UIApplication.shared.isIdleTimerDisabled = true
            henge_vm_set_cursor_style(Int32(cursorScale), sharpCursor ? 1 : 0)
            HardwareMouse.shared.start(scrollSpeed: scrollSpeed)
            VolumeClicks.shared.start()
        }
        .onDisappear {
            UIApplication.shared.isIdleTimerDisabled = false
            zoomFollowing?.cancel()
            StickyKeys.shared.releaseAll()
            HardwareKeys.releaseAll()
            sillKeyboard.releaseAll()
            HardwareMouse.shared.stop()
            henge_vm_absolute_cancel()
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
        let full: CGSize
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

        init(full: CGSize, insets: EdgeInsets, landscape: Bool, zoomed: Bool, typing: Bool, sillKeyboardOpen: Bool = false, centre: CGPoint, aspect: CGFloat) {
            self.full = full
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
                let kbHeight: CGFloat = sillKeyboardOpen ? 296 : 0
                let room = sillKeyboardOpen
                    ? max(full.height - insets.top - bar - kbHeight - 8, 220)
                    : (typing ? full.height - insets.bottom - insets.top - bar - 8 : full.height)
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
                let kbHeight: CGFloat = sillKeyboardOpen ? 254 : 0
                let topBar: CGFloat = sillKeyboardOpen ? insets.top + 56 : 0
                let availH = max(full.height - kbHeight - topBar, 140)
                let height = min(availH, full.width / aspect)
                let width = height * aspect
                let y = sillKeyboardOpen ? topBar + max((availH - height) / 2, 0) : (full.height - height) / 2
                screen = CGRect(x: (full.width - width) / 2, y: y, width: width, height: height)
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
        if keyboard == .none && !controlsHidden {
            HStack {
                tool("eye.slash", L10n.text("隱藏控制列")) { hideControls() }
                Spacer()
                tool("keyboard", L10n.text("鍵盤"), tint: Desk.text) { toggleSillKeyboard() }
                Spacer()
                pasteTool
                Spacer()
                touchModeSwitch(onGlass: false)
                Spacer()
                tool("plus.magnifyingglass", L10n.text("放大檢視")) { zoomed = true }
                Spacer()
                tool("info.circle", L10n.text("詳細資訊")) { showDetails = true }
                Spacer()
                tool("power", L10n.text("關機"), tint: Desk.bad) { stopTapped() }
            }
            .padding(.horizontal, 14)
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
                Trackpad(
                    touchMode: touchMode,
                    pointerSpeed: mouseSpeed,
                    scrollSpeed: scrollSpeed,
                    reverseScrolling: reverseScrolling,
                    onToggleHud: toggleControlsFromGesture
                )
                if compact {
                    Text(touchMode == .trackpad ? L10n.text("Sill 觸控板") : L10n.text("直接觸控"))
                        .font(.system(size: 14)).foregroundStyle(Desk.faint).allowsHitTesting(false)
                } else {
                    VStack(spacing: 6) {
                        hint(L10n.text("滑動"), L10n.text("移動游標"))
                        hint(L10n.text("輕點"), L10n.text("左鍵點擊"))
                        hint(L10n.text("按住再滑動"), L10n.text("拖曳視窗或選取"))
                        hint(L10n.text("雙指滑動"), L10n.text("捲動頁面"))
                    }
                    .allowsHitTesting(false)
                }
            }
            Rectangle().fill(Desk.hairline).frame(height: 0.5)
            HStack(spacing: 0) {
                MouseButton(title: L10n.text("左鍵點擊"), button: 0)
                Rectangle().fill(Desk.hairline).frame(width: 0.5)
                MouseButton(title: L10n.text("右鍵點擊"), button: 1)
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
        (Text(L10n.text(strong)).foregroundColor(Desk.dim).fontWeight(.semibold) + Text(" \(rest)").foregroundColor(Desk.faint))
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

    /// Hides the session's controls; four fingers bring them back.
    private func hideControls() {
        var hidden = controlsHidden
        var kb = keyboard
        SessionHUDPolicy.hideControls(controlsHidden: &hidden, keyboard: &kb)
        controlsHidden = hidden
        keyboard = kb
        sillKeyboard.releaseAll()
        guard revealHintsShown < 3 else { return }
        revealHintsShown += 1
        showRevealHint = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 3) { showRevealHint = false }
    }

    private func selectTouchMode(_ mode: TrackpadTouchMode) {
        guard touchMode != mode else { return }
        touchModeRaw = mode.rawValue
        UIImpactFeedbackGenerator(style: .light).impactOccurred()
    }

    private func touchModeSwitch(onGlass: Bool) -> some View {
        HStack(spacing: 2) {
            modeSegment(
                mode: .trackpad,
                symbol: "rectangle.and.hand.point.up.left",
                label: "Sill 多指觸控板",
                onGlass: onGlass
            )
            modeSegment(
                mode: .directPointer,
                symbol: "hand.point.up.left",
                label: "直接觸控指標",
                onGlass: onGlass
            )
        }
        .padding(3)
        .background(onGlass ? Color.white.opacity(0.12) : Desk.raised, in: Capsule())
        .overlay(Capsule().stroke(onGlass ? Color.white.opacity(0.16) : Desk.hairline, lineWidth: 0.5))
        .animation(.spring(response: 0.24, dampingFraction: 0.9), value: touchMode)
    }

    private func modeSegment(mode: TrackpadTouchMode, symbol: String, label: String, onGlass: Bool) -> some View {
        let active = touchMode == mode
        return Button {
            selectTouchMode(mode)
        } label: {
            Image(systemName: symbol)
                .font(.system(size: 15, weight: .medium))
                .foregroundStyle(active ? Color.white : (onGlass ? Color.white.opacity(0.65) : Desk.dim))
                .frame(width: 34, height: 34)
                .background(active ? Desk.accent : Color.clear, in: Capsule())
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(L10n.text(label))
        .accessibilityAddTraits(active ? .isSelected : [])
    }

    private func tool(_ symbol: String, _ label: String, tint: Color = Desk.text, highlighted: Bool = false, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 18, weight: .medium))
                .foregroundStyle(tint)
                .frame(width: 40, height: 40)
                .background(highlighted ? Desk.accent : Color.clear, in: Capsule())
                .contentShape(Rectangle())
        }
        .accessibilityLabel(L10n.text(label))
    }

    // MARK: Filling the phone

    @ViewBuilder private func floatingControls(_ layout: Layout) -> some View {
        let landscape = layout.touch.width > layout.touch.height
        let top = layout.insets.top + (landscape ? 8 : 6)
        let pill = HStack(spacing: 2) {
            tool("eye.slash", L10n.text("隱藏控制列"), tint: .white) { hideControls() }
            tool("keyboard", L10n.text("鍵盤"), tint: .white, highlighted: keyboard != .none) {
                toggleSillKeyboard()
            }
            pasteTool
            touchModeSwitch(onGlass: true)
            tool(zoomed ? "minus.magnifyingglass" : "plus.magnifyingglass", zoomed ? L10n.text("恢復檢視") : L10n.text("放大檢視"), tint: zoomed ? Desk.accentLight : .white) {
                zoomed.toggle()
            }
            tool("info.circle", L10n.text("詳細資訊"), tint: .white) { showDetails = true }
            Rectangle().fill(Color.white.opacity(0.3)).frame(width: 1, height: 22).padding(.horizontal, 4)
            tool("power", L10n.text("關機"), tint: Desk.bad) { stopTapped() }
        }
        .padding(.horizontal, 8)
        .frame(height: 50)
        .deskGlass(in: Capsule())
        if !controlsHidden {
            if let barY = layout.barY {
                pill.position(x: layout.touch.midX, y: barY)
                    .transition(.opacity)
            } else if landscape || keyboard != .none {
                pill.position(x: layout.touch.midX, y: top + 25)
                    .transition(.opacity)
            } else {
                pill.position(x: layout.touch.midX, y: layout.touch.height - layout.insets.bottom - 34)
                    .transition(.opacity)
            }
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
            Text(L10n.text("這台 Mac 無法啟動")).font(.system(size: 17, weight: .semibold))
            Text(L10n.text(text)).font(.system(size: 14)).foregroundStyle(Desk.dim)
            if retainedSnapshot {
                Button(L10n.text("捨棄快照並冷開機"), role: .destructive) { confirmDiscard = true }
                    .confirmationDialog(L10n.text("捨棄快照並冷開機"), isPresented: $confirmDiscard, titleVisibility: .visible) {
                        Button(L10n.text("捨棄快照並冷開機"), role: .destructive) {
                            do {
                                try InstantResume.discard(for: runningMac ?? mac)
                                bootAttempt += 1
                            } catch {
                                self.error = L10n.format("無法捨棄快照：%@", error.localizedDescription)
                            }
                        }
                    } message: {
                        Text(L10n.text("虛擬磁碟會保留，但只存在快照中、尚未存檔的進度將無法復原。"))
                    }
            }
            Button(L10n.text("關閉")) { close() }.font(.system(size: 15, weight: .semibold)).foregroundStyle(Desk.accentLight)
        }
        .padding(18)
        .frame(width: min(layout.touch.width, 390) - 32, alignment: .leading)
        .background(Desk.raised, in: RoundedRectangle(cornerRadius: 22, style: .continuous))
        .position(x: (layout.fillsPhone ? layout.touch.midX : layout.pad.midX), y: layout.fillsPhone ? layout.touch.midY : layout.pad.midY)
    }

    private var phase: String {
        switch state {
        case 0: return error == nil ? L10n.text("正在啟動…") : L10n.text("尚未啟動")
        case 1: return userCode ? L10n.text("macOS 執行中") : L10n.text("正在開機")
        case 3: return L10n.text("正在完成關機…")
        case 4: return L10n.text("已暫停")
        default: return L10n.format("已停止（%@）", String(describing: String(cString: henge_vm_exit_reason())))
        }
    }

    private var ramModeLabel: String {
        switch ramMode {
        case 1: return L10n.text("免計入上限 No Footprint")
        case 2: return L10n.text("檔案映射")
        case 3: return L10n.text("匿名記憶體")
        default: return L10n.text("配置中")
        }
    }

    private var details: some View {
        NavigationStack {
            List {
                Section(phase) {
                    let ramText = bootRAM % 1024 == 0
                        ? "\(bootRAM / 1024) GB"
                        : String(format: "%.1f GB", Double(bootRAM) / 1024.0)
                    LabeledContent(L10n.text("儲存位置"), value: mac.isExternal ? L10n.format("外接 SSD（%@）", String(describing: mac.externalDriveName ?? L10n.text("外接硬碟"))) : L10n.format("此 %@", String(describing: Device.name)))
                    LabeledContent(L10n.text("記憶體配置"), value: bootRAM > 0 ? "\(ramText)（\(ramModeLabel)）" : ramModeLabel)
                    LabeledContent(L10n.text("要求的記憶體"), value: GuestRAMBudget.text(requestedRAMMB))
                    LabeledContent(L10n.text("運行中 CPU"), value: "\(cpusOn)／\(bootCPUs)")
                    LabeledContent(L10n.text("系統熱狀態"), value: L10n.text(Self.thermalLabel(thermalState)))
                    LabeledContent(L10n.text("指令轉譯率"), value: String(format: "%.1f M/s", blocksPerSecond / 1e6))
                    LabeledContent(L10n.text("網路封包"), value: L10n.format("送出 %@，接收 %@", String(describing: framesOut), String(describing: framesIn)))
                    LabeledContent(L10n.text("已運行時間"), value: L10n.format("%@ 秒", String(describing: Int(Date().timeIntervalSince(started)))))
                }
                Section(L10n.text("記憶體狀態")) {
                    MemoryStatusView(ramMB: requestedRAMMB)
                }
                Section(L10n.text("顯示器")) {
                    Toggle(L10n.text("螢幕色彩同步"), isOn: $matchScreenColors)
                    LabeledContent(L10n.text("畫面亮度"), value: "\(Int(screenBrightness * 100))%")
                    Slider(value: $screenBrightness, in: 0.4...1)
                    Text(L10n.text("只調整虛擬 Mac 畫面的顯示亮度。"))
                        .font(.footnote).foregroundStyle(.secondary)
                }
                Section(L10n.text("指標")) {
                    Picker(L10n.text("指標大小"), selection: $cursorScale) {
                        Text("1×").tag(1)
                        Text("2×").tag(2)
                        Text("3×").tag(3)
                    }
                    .pickerStyle(.segmented)
                    Toggle(L10n.text("銳利邊緣"), isOn: $sharpCursor)
                    LabeledContent(L10n.text("捲動速度"), value: String(format: "%.1f×", scrollSpeed))
                    Slider(value: $scrollSpeed, in: 0.1...1.5)
                    Text(L10n.text("macOS 提供的指標影像較小，在 iPad 上設為 1× 最銳利；捲動速度會立即生效。"))
                        .font(.footnote).foregroundStyle(.secondary)
                }
                Section(L10n.text("剪貼簿與資料夾共享")) {
                    LabeledContent(L10n.text("狀態"), value: helperRunning ? L10n.text("已啟用") : L10n.text("尚未設定"))
                    if !helperRunning {
                        Button(L10n.text("自動輸入設定指令")) {
                            showDetails = false
                            Task {
                                try? await Task.sleep(nanoseconds: 600_000_000)
                                await Sharing.typeSetUpCommand()
                            }
                        }
                    }
                    Text(helperRunning
                         ? L10n.text("將檔案放到「檔案 › Henge › Shared」即可在 Mac 家目錄的「Henge」資料夾存取。在 Mac 複製純文字會自動同步至此，iPad 複製後請點上方第三顆貼上鈕傳給 Mac。")
                         : L10n.text("每台 Mac 只需設定一次：先開啟 Mac 裡的終端機，點按上方按鈕後按 Return 執行；若彈出區域網路權限詢問請選允許（輸入時 Mac 輸入法需為英文）。"))
                        .font(.footnote).foregroundStyle(.secondary)
                }
                Section(L10n.text("輕量化 macOS")) {
                    Button(L10n.text("輸入輕量化設定指令")) {
                        showDetails = false
                        Task {
                            try? await Task.sleep(nanoseconds: 600_000_000)
                            await Keys.typeSlowly(Sharing.lightenCommand)
                        }
                    }
                    Button(L10n.text("輸入還原指令")) {
                        showDetails = false
                        Task {
                            try? await Task.sleep(nanoseconds: 600_000_000)
                            await Keys.typeSlowly(Sharing.unlightenCommand)
                        }
                    }
                    Text(L10n.text("減少模擬 CPU 的繪圖負荷：關閉視窗動畫、Dock 動畫、桌面小工具與動態桌布。請先開啟 Mac 終端機，點按按鈕後按 Return 執行，並登出再登入即可生效（建議另於系統設定開啟「減少動態效果」與「減少透明度」）。"))
                        .font(.footnote).foregroundStyle(.secondary)
                }
                Section(L10n.text("日誌")) {
                    VStack(alignment: .leading, spacing: 1) {
                        ForEach(Array(log.enumerated()), id: \.offset) { _, line in
                            Text(line).font(.system(size: 10, design: .monospaced)).foregroundStyle(.secondary)
                        }
                    }
                }
            }
            .navigationTitle(L10n.text("詳細資訊"))
            .navigationBarTitleDisplayMode(.inline)
        }
    }

    // MARK: Running

    private static func thermalLabel(_ state: ProcessInfo.ThermalState) -> String {
        switch state {
        case .nominal: return "正常"
        case .fair: return "微溫"
        case .serious: return "高熱壓力"
        case .critical: return "嚴重過熱"
        @unknown default: return "未知"
        }
    }

    private func applyHostHeat(_ state: ProcessInfo.ThermalState) {
        let high = state != .nominal
        henge_vm_set_host_thermal_pressure(high ? 1 : 0)
        thermalState = state
        HengeLog.log("session", "thermal state: \(Self.thermalLabel(state))")
    }

    private func run() async {
        error = nil
        retainedSnapshot = false
        confirmDiscard = false
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
        keyboard = .none
        sillKeyboard.releaseAll()
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
        requestedRAMMB = liveMac.effectiveRAMMB
        if liveMac.isExternal && !Machines.shared.ensureExternalAccess(for: liveMac) {
            error = L10n.format("外接 SSD（%@）未連接，請插上後再試。", String(describing: liveMac.externalDriveName ?? L10n.text("外接硬碟")))
            return
        }
        UIApplication.shared.isIdleTimerDisabled = true
        HardwareMouse.shared.start(scrollSpeed: scrollSpeed)
        InstantResume.clearInterruptedWrite(for: liveMac)
        let ram = GuestMemory.prepare(liveMac)
        HengeLog.log("session", "available memory \(henge_available_memory() >> 20) MB")
        guard ram >= 1024 else {
            error = GuestMemory.lastFailure ?? L10n.format("無法建立要求的 %@ 記憶體映射，請檢查本機儲存空間後重試。", String(describing: GuestRAMBudget.text(requestedRAMMB)))
            return
        }
        var buffer = [CChar](repeating: 0, count: 256)
        JITBootstrap.releaseLingeringDebugger()
        Sharing.prepare()
        EngineTuning.apply()
        applyHostHeat(ProcessInfo.processInfo.thermalState)
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
        let hasSnapshot: Bool
        do { hasSnapshot = try InstantResume.snapshotExists(for: liveMac) }
        catch {
            self.error = L10n.format("無法檢查快照，未啟動虛擬機：%@", error.localizedDescription)
            return
        }
        let rc: Int32
        if hasSnapshot {
            guard InstantResume.enabled else {
                retainedSnapshot = true
                error = L10n.text("已關閉「離開時自動保存執行狀態」。快照已保留；重新開啟此設定後即可重試。")
                return
            }
            guard let at = InstantResume.saved(for: liveMac, ramMB: ram, cpus: activeCPUs) else {
                retainedSnapshot = true
                error = L10n.text("無法讀取快照，或版本與設定不符。快照已保留；請確認 App 版本、記憶體和 CPU 設定後再試。")
                return
            }
            HengeLog.log("resume", "picking up the Mac saved \(Int(Date().timeIntervalSince(at))) s ago")
            let t0 = Date()
            rc = henge_vm_resume(liveMac.rom.path, liveMac.disk.path, liveMac.aux.path, liveMac.ecid, liveMac.seed, ram, Int32(activeCPUs),
                                 InstantResume.file(for: liveMac).path, InstantResume.ident(for: liveMac, ramMB: ram, cpus: activeCPUs), &buffer, buffer.count)
            if rc == 0 {
                HengeLog.log("resume", String(format: "resumed in %.1f s", Date().timeIntervalSince(t0)))
            } else {
                let reason = String(cString: buffer)
                HengeLog.log("resume", "could not resume (\(reason)); snapshot retained")
                retainedSnapshot = true
                error = L10n.format("快照已保留。還原失敗：%@", reason)
                return
            }
        } else {
            let bootCPUCount: Int
            if Device.physicalMemoryGB <= 8,
               ProcessInfo.processInfo.environment["HV_ALLOW_ALL_CPUS"] == nil,
               activeCPUs > 4 {
                bootCPUCount = 4
                HengeLog.log("session", "balancing vCPUs \(activeCPUs) -> 4 P-cores for smoother GPU & I/O on \(Device.physicalMemoryGB) GB host")
            } else {
                bootCPUCount = activeCPUs
            }
            rc = henge_vm_boot(liveMac.rom.path, liveMac.disk.path, liveMac.aux.path, liveMac.ecid, liveMac.seed, ram, Int32(bootCPUCount), &buffer, buffer.count)
            if rc == 0 {
                bootCPUs = bootCPUCount
            }
        }
        if rc != 0 {
            error = String(cString: buffer)
            return
        }
        bootRAM = ram
        if hasSnapshot { bootCPUs = activeCPUs }
        ramMode = henge_vm_ram_mode()
        henge_vm_set_cursor_style(Int32(cursorScale), sharpCursor ? 1 : 0)
        HengeLog.log("session", "active RAM \(ram) MB, CPUs \(bootCPUs), backing mode \(ramMode)")
        started = Date()
        var used = liveMac
        used.lastUsed = started
        Machines.shared.update(used)
        var lastBlocks = henge_vm_blocks()
        var lastTime = ProcessInfo.processInfo.systemUptime
        var lastGPUSample = lastTime
        var lastGPUFrames = henge_vm_gpu_frames()
        var tick = 0
        while !Task.isCancelled {
            state = henge_vm_state()
            if state == 3 || state == 4 { /* starting, stopping, or paused while Henge is in the background */
                try? await Task.sleep(nanoseconds: 100_000_000)
                continue
            }
            let heat = ProcessInfo.processInfo.thermalState
            if heat.rawValue != thermalState.rawValue {
                applyHostHeat(heat)
            }
            if state == 2 {
                keyboard = .none
                showDetails = false
                confirmStop = false
                zoomFollowing?.cancel()
                StickyKeys.shared.releaseAll()
                sillKeyboard.releaseAll()
                HardwareKeys.releaseAll()
                HardwareMouse.shared.stop()
                henge_vm_absolute_cancel()
                UIApplication.shared.isIdleTimerDisabled = false
                HengeLog.log("session", "showing stopped Mac: \(String(cString: henge_vm_exit_reason()))")
                if henge_vm_exit_outcome() == Int32(HENGE_VM_OUTCOME_RESTART.rawValue) && henge_vm_can_start() != 0 {
                    bootAttempt += 1
                }
                break
            }
            tick += 1
            let report = tick % 10 == 0
            if showDetails || report {
                let now = ProcessInfo.processInfo.systemUptime, blocks = henge_vm_blocks()
                let rate = Double(blocks &- lastBlocks) / max(now - lastTime, 0.001)
                lastBlocks = blocks
                lastTime = now
                let tx = henge_vm_net_frames(1), rx = henge_vm_net_frames(0)
                if showDetails {
                    cpusOn = henge_vm_cpus_on()
                    if !userCode { userCode = henge_vm_guest_el0() != 0 }
                    blocksPerSecond = rate
                    framesOut = tx
                    framesIn = rx
                    helperRunning = Sharing.helperRunning
                    log = HengeLog.recentLines(30)
                }
                if report {
                    let gpuFrames = henge_vm_gpu_frames()
                    HengeLog.log("perf", "blocks/s \(String(format: "%.0f", rate)), GPU frame updates \(gpuFrames &- lastGPUFrames) in \(String(format: "%.2f", now - lastGPUSample))s, "
                                 + "network tx \(tx), rx \(rx), dns \(henge_vm_dns(0)) answered \(henge_vm_dns(2)) unanswered, "
                                 + "thermal \(Self.thermalLabel(heat))")
                    lastGPUFrames = gpuFrames
                    lastGPUSample = now
                    JITBootstrap.releaseLingeringDebugger()
                }
            }
            if tick == 60 && !stillWallpaperTipShown { // about when the desktop is up after a login
                stillWallpaperTipShown = true
                showWallpaperTip = true
                DispatchQueue.main.asyncAfter(deadline: .now() + 10) { showWallpaperTip = false }
            }
            if tick % 30 == 0 { HengeLog.logFootprint("session") } // how close to the limit, for a memory kill leaves no crash report
            try? await Task.sleep(nanoseconds: 1_000_000_000)
        }
    }

    private func stopTapped() {
        switch SessionPowerAction.onTap(nativeState: henge_vm_state(), displayedState: state) {
        case .confirm: confirmStop = true
        case .wait: break
        case .close: close()
        }
    }

    private func finish() {
        let currentMac = runningMac ?? mac
        MacPreview.saveNow(for: currentMac)
        InstantResume.forceStop(currentMac)
    }
}
