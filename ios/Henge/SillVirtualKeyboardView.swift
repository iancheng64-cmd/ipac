import SwiftUI
import UIKit

final class SillKeyboardController: ObservableObject {
    @Published private(set) var activeModifiers: Set<UInt16> = []
    @Published private(set) var pressedKeys: Set<UInt16> = []
    @Published private(set) var capsLockOn: Bool = false

    private let machine = SillKeyboardStateMachine { code, down in
        henge_vm_key(code, down ? 1 : 0)
    }

    var isShifted: Bool { machine.isShifted }
    var displaysUppercaseLetters: Bool { machine.displaysUppercaseLetters }

    private func sync() {
        activeModifiers = machine.activeModifiers
        pressedKeys = machine.pressedKeys
        capsLockOn = machine.capsLockOn
    }

    func toggleModifier(_ code: UInt16) {
        machine.toggleModifier(code)
        sync()
    }

    func tapCapsLock() {
        machine.tapCapsLock()
        sync()
    }

    func pressKey(_ code: UInt16) {
        machine.pressKey(code)
        sync()
    }

    func releaseKey(_ code: UInt16) {
        machine.releaseKey(code)
        StickyKeys.shared.releaseAll()
        sync()
    }

    func triggerShortcut(_ codes: [UInt16]) {
        StickyKeys.shared.releaseAll()
        machine.triggerShortcut(codes)
        sync()
    }

    func releaseAll() {
        machine.releaseAll()
        sync()
    }
}

/// Apple iPadOS Floating Keyboard + Taiwan Magic Keyboard (English + 注音 ㄅㄆㄇ + inline iPadOS Chinese compose).
struct SillVirtualKeyboardView: View {
    @ObservedObject var controller: SillKeyboardController
    let onSwitchToIME: () -> Void
    let onDismiss: () -> Void

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency

    @AppStorage("henge.sillKeyboard.scale") private var savedScale: Double = 0.88
    @AppStorage("henge.sillKeyboard.normX") private var normX: Double = 0.50
    @AppStorage("henge.sillKeyboard.normY") private var normY: Double = 0.83
    @AppStorage("henge.sillKeyboard.inputMode") private var inputModeRaw: String = SillKeyboardInputMode.zhuyin.rawValue

    @GestureState private var dragDelta: CGSize = .zero
    @GestureState private var pinchScale: CGFloat = 1.0
    @State private var resizeStartScale: Double?
    @State private var showChineseCompose = false
    @State private var imeDraft = ""
    @FocusState private var composeFocused: Bool

    private var isPad: Bool { Device.isPad }

    private var inputMode: SillKeyboardInputMode {
        SillKeyboardInputMode(rawValue: inputModeRaw) ?? .zhuyin
    }

    private func clampedScale(_ raw: Double) -> Double {
        min(max(raw, 0.65), 1.35)
    }

    var body: some View {
        GeometryReader { geo in
            let container = geo.size
            let liveScale = clampedScale(savedScale * Double(pinchScale))
            let baseDeckWidth: CGFloat = isPad ? 580 : min(max(container.width - 14, 300), 430)
            let deckWidth = min(max(baseDeckWidth * CGFloat(liveScale), isPad ? 375 : 300), max(container.width - 12, 320))
            let s = deckWidth / (isPad ? 580 : 420)
            let keyHeight: CGFloat = (isPad ? 40 : 34) * s
            let rowSpacing: CGFloat = max((isPad ? 5.5 : 4) * s, 3.5)
            let keySpacing: CGFloat = max((isPad ? 5 : 3.5) * s, 2.5)
            let keyRadius: CGFloat = max((isPad ? 7.5 : 6) * s, 5)
            let deckPaddingH: CGFloat = max((isPad ? 10 : 7) * s, 6)
            let innerWidth = max(deckWidth - deckPaddingH * 2, 220)
            let deckRadius: CGFloat = isPad ? 22 : 18

            let estimatedDeckHeight: CGFloat = (showChineseCompose ? 42 : 0) + 36 + keyHeight * 5 + rowSpacing * 4 + 34
            let halfW = deckWidth / 2
            let halfH = estimatedDeckHeight / 2
            let minX = min(container.width / 2, halfW + 8)
            let maxX = max(container.width / 2, container.width - halfW - 8)
            let minY = min(container.height / 2, halfH + 56)
            let maxY = max(container.height / 2, container.height - halfH - 10)
            let centerX = min(max(normX * container.width + dragDelta.width, minX), maxX)
            let centerY = min(max(normY * container.height + dragDelta.height, minY), maxY)

            VStack(spacing: max(6 * s, 4)) {
                headerAndShortcutsBar(
                    scale: s,
                    innerWidth: innerWidth,
                    containerSize: container
                )

                if showChineseCompose {
                    chineseComposeBar(scale: s)
                        .frame(width: innerWidth)
                        .transition(.opacity.combined(with: .move(edge: .top)))
                }

                VStack(spacing: rowSpacing) {
                    ForEach(0..<4, id: \.self) { rowIndex in
                        standardRow(
                            SillKeyboardLayout.rows[rowIndex],
                            width: innerWidth,
                            keyHeight: keyHeight,
                            keySpacing: keySpacing,
                            keyRadius: keyRadius,
                            uiScale: s
                        )
                    }
                    bottomRow(
                        SillKeyboardLayout.rows[4],
                        width: innerWidth,
                        keyHeight: keyHeight,
                        keySpacing: keySpacing,
                        keyRadius: keyRadius,
                        uiScale: s
                    )
                }
                .frame(width: innerWidth)
            }
            .padding(.horizontal, deckPaddingH)
            .padding(.top, 7)
            .padding(.bottom, max(10 * s, 8))
            .frame(width: deckWidth)
            .background { deckSurface(radius: deckRadius) }
            .overlay(alignment: .bottomTrailing) {
                cornerResizeHandle(baseDeckWidth: baseDeckWidth)
            }
            .overlay {
                RoundedRectangle(cornerRadius: deckRadius, style: .continuous)
                    .strokeBorder(
                        LinearGradient(
                            colors: [Color.white.opacity(0.24), Color.white.opacity(0.06)],
                            startPoint: .top,
                            endPoint: .bottom
                        ),
                        lineWidth: 0.5
                    )
                    .allowsHitTesting(false)
            }
            .shadow(color: Color.black.opacity(0.42), radius: 26, y: 10)
            .environment(\.colorScheme, .dark)
            .position(x: centerX, y: centerY)
            .gesture(
                MagnificationGesture()
                    .updating($pinchScale) { value, state, _ in
                        state = value
                    }
                    .onEnded { value in
                        savedScale = clampedScale(savedScale * Double(value))
                    }
            )
        }
        .onDisappear {
            controller.releaseAll()
        }
    }

    @ViewBuilder
    private func deckSurface(radius: CGFloat) -> some View {
        let shape = RoundedRectangle(cornerRadius: radius, style: .continuous)
        if reduceTransparency {
            shape.fill(Color(red: 28 / 255, green: 28 / 255, blue: 30 / 255))
        } else {
            shape.fill(.ultraThinMaterial)
        }
    }

    private func headerAndShortcutsBar(
        scale s: CGFloat,
        innerWidth: CGFloat,
        containerSize: CGSize
    ) -> some View {
        VStack(spacing: 4) {
            // Top bar: Grabber handle (drag to move, double-tap to reset), resize pills, Chinese compose & Hide
            HStack(spacing: 6) {
                // Drag handle region occupies left/center grabber space
                HStack(spacing: 6) {
                    Capsule()
                        .fill(Color.white.opacity(0.36))
                        .frame(width: 36, height: 4.5)
                        .padding(.vertical, 6)
                }
                .frame(maxWidth: .infinity, minHeight: 28)
                .contentShape(Rectangle())
                .gesture(
                    DragGesture(minimumDistance: 2)
                        .updating($dragDelta) { value, state, _ in
                            state = value.translation
                        }
                        .onEnded { value in
                            normX = min(max((normX * containerSize.width + value.translation.width) / max(containerSize.width, 1), 0.1), 0.9)
                            normY = min(max((normY * containerSize.height + value.translation.height) / max(containerSize.height, 1), 0.15), 0.94)
                        }
                )
                .onTapGesture(count: 2) {
                    UIImpactFeedbackGenerator(style: .light).impactOccurred()
                    withAnimation(reduceMotion ? nil : .spring(response: 0.28, dampingFraction: 0.88)) {
                        normX = 0.50
                        normY = 0.83
                        savedScale = 0.88
                    }
                }

                // Chinese compose toggle pill
                Button {
                    UIImpactFeedbackGenerator(style: .light).impactOccurred()
                    withAnimation(reduceMotion ? nil : .spring(response: 0.22, dampingFraction: 0.9)) {
                        showChineseCompose.toggle()
                    }
                    if showChineseCompose {
                        DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
                            composeFocused = true
                        }
                    } else {
                        composeFocused = false
                    }
                } label: {
                    HStack(spacing: 3) {
                        Image(systemName: "character.bubble")
                            .font(.system(size: 11, weight: .semibold))
                        Text(L10n.text("中文組字"))
                            .font(.system(size: 11, weight: .medium, design: .rounded))
                    }
                    .foregroundStyle(showChineseCompose ? .white : .white.opacity(0.88))
                    .padding(.horizontal, 9)
                    .frame(height: 24)
                    .background(showChineseCompose ? Color.accentColor : Color.white.opacity(0.12), in: Capsule())
                }
                .buttonStyle(ApplePressButtonStyle(reduceMotion: reduceMotion))

                // Size steppers A- / A+
                HStack(spacing: 2) {
                    Button {
                        UIImpactFeedbackGenerator(style: .light).impactOccurred()
                        savedScale = clampedScale(savedScale - 0.10)
                    } label: {
                        Text("A-")
                            .font(.system(size: 11, weight: .semibold, design: .rounded))
                            .foregroundStyle(.white.opacity(0.85))
                            .frame(width: 26, height: 24)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(ApplePressButtonStyle(reduceMotion: reduceMotion))

                    Rectangle().fill(Color.white.opacity(0.18)).frame(width: 0.5, height: 12)

                    Button {
                        UIImpactFeedbackGenerator(style: .light).impactOccurred()
                        savedScale = clampedScale(savedScale + 0.10)
                    } label: {
                        Text("A+")
                            .font(.system(size: 11, weight: .semibold, design: .rounded))
                            .foregroundStyle(.white.opacity(0.85))
                            .frame(width: 26, height: 24)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(ApplePressButtonStyle(reduceMotion: reduceMotion))
                }
                .background(Color.white.opacity(0.10), in: Capsule())

                // System full IME handoff button
                Button {
                    UIImpactFeedbackGenerator(style: .light).impactOccurred()
                    composeFocused = false
                    onSwitchToIME()
                } label: {
                    Image(systemName: "keyboard")
                        .font(.system(size: 11.5, weight: .medium))
                        .foregroundStyle(.white.opacity(0.88))
                        .frame(width: 28, height: 24)
                        .background(Color.white.opacity(0.12), in: Capsule())
                }
                .buttonStyle(ApplePressButtonStyle(reduceMotion: reduceMotion))
                .accessibilityLabel(L10n.text("切換系統輸入法"))

                // Pure SwiftUI Hide Button (never blocked by gesture recognizers)
                Button {
                    UIImpactFeedbackGenerator(style: .light).impactOccurred()
                    composeFocused = false
                    controller.releaseAll()
                    onDismiss()
                } label: {
                    Image(systemName: "keyboard.chevron.compact.down")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(.white.opacity(0.95))
                        .frame(width: 34, height: 26)
                        .background(Color.white.opacity(0.16), in: Capsule())
                }
                .buttonStyle(ApplePressButtonStyle(reduceMotion: reduceMotion))
                .accessibilityLabel(L10n.text("隱藏鍵盤"))
            }
            .frame(width: innerWidth)

            // Scrollable Mac shortcuts strip (including Zhuyin candidate down + Mac input source toggle)
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: max(5 * s, 4)) {
                    FloatingShortcutPill(
                        label: inputMode == .zhuyin ? "注音／英" : "ABC／注音",
                        symbol: "globe",
                        scale: s,
                        reduceMotion: reduceMotion,
                        highlighted: inputMode == .zhuyin
                    ) {
                        toggleBilingualMode(switchMacSource: true)
                    }

                    FloatingShortcutPill(
                        label: "選字 ↓",
                        symbol: nil,
                        scale: s,
                        reduceMotion: reduceMotion
                    ) {
                        controller.triggerShortcut([SillLinuxKey.down])
                    }

                    ForEach(SillKeyboardLayout.shortcuts) { shortcut in
                        FloatingShortcutPill(
                            label: shortcut.label,
                            symbol: shortcutSymbol(for: shortcut.id),
                            scale: s,
                            reduceMotion: reduceMotion
                        ) {
                            controller.triggerShortcut(shortcut.codes)
                        }
                    }
                }
                .padding(.vertical, 1)
            }
            .frame(width: innerWidth)
        }
    }

    private func chineseComposeBar(scale s: CGFloat) -> some View {
        HStack(spacing: 6) {
            TextField(L10n.text("用 iPad 注音／手寫輸入中文…"), text: $imeDraft)
                .textFieldStyle(.plain)
                .font(.system(size: 13.5))
                .foregroundStyle(.white)
                .focused($composeFocused)
                .submitLabel(.send)
                .onSubmit { sendChineseDraft() }
                .padding(.horizontal, 10)
                .frame(height: 30)
                .background(Color.white.opacity(0.12), in: RoundedRectangle(cornerRadius: 9, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: 9, style: .continuous).stroke(Color.white.opacity(0.16), lineWidth: 0.5))

            Button {
                sendChineseDraft()
            } label: {
                Text(L10n.text("送出"))
                    .font(.system(size: 12.5, weight: .semibold))
                    .foregroundStyle(.white)
                    .padding(.horizontal, 12)
                    .frame(height: 30)
                    .background(imeDraft.isEmpty ? Color.white.opacity(0.14) : Color(red: 10 / 255, green: 132 / 255, blue: 255 / 255), in: Capsule())
            }
            .disabled(imeDraft.isEmpty)
            .buttonStyle(ApplePressButtonStyle(reduceMotion: reduceMotion))
        }
    }

    private func sendChineseDraft() {
        let text = imeDraft
        guard !text.isEmpty else { return }
        UIImpactFeedbackGenerator(style: .light).impactOccurred()
        Sharing.paste(text)
        imeDraft = ""
    }

    private func toggleBilingualMode(switchMacSource: Bool) {
        UIImpactFeedbackGenerator(style: .light).impactOccurred()
        inputModeRaw = (inputMode == .zhuyin ? SillKeyboardInputMode.english : .zhuyin).rawValue
        if switchMacSource {
            controller.triggerShortcut([SillLinuxKey.leftCtrl, SillLinuxKey.space])
        }
    }

    private func cornerResizeHandle(baseDeckWidth: CGFloat) -> some View {
        ZStack(alignment: .bottomTrailing) {
            Color.clear.frame(width: 28, height: 28)
            Image(systemName: "arrow.up.left.and.arrow.down.right")
                .font(.system(size: 9, weight: .bold))
                .foregroundStyle(Color.white.opacity(0.45))
                .padding(7)
        }
        .contentShape(Rectangle())
        .gesture(
            DragGesture(minimumDistance: 1)
                .onChanged { value in
                    if resizeStartScale == nil {
                        resizeStartScale = savedScale
                    }
                    let delta = (value.translation.width + value.translation.height) * 0.65 / max(baseDeckWidth, 300)
                    savedScale = clampedScale((resizeStartScale ?? savedScale) + Double(delta))
                }
                .onEnded { _ in
                    resizeStartScale = nil
                }
        )
    }

    private func standardRow(
        _ keys: [SillKeySpec],
        width: CGFloat,
        keyHeight: CGFloat,
        keySpacing: CGFloat,
        keyRadius: CGFloat,
        uiScale: CGFloat
    ) -> some View {
        let totalWeight = keys.reduce(0.0) { $0 + $1.weight }
        let usableWidth = max(width - keySpacing * CGFloat(max(keys.count - 1, 0)), 1)

        return HStack(spacing: keySpacing) {
            ForEach(keys) { spec in
                let keyWidth = usableWidth * CGFloat(spec.weight / totalWeight)
                keycap(spec, width: keyWidth, height: keyHeight, radius: keyRadius, uiScale: uiScale)
            }
        }
    }

    private func bottomRow(
        _ keys: [SillKeySpec],
        width: CGFloat,
        keyHeight: CGFloat,
        keySpacing: CGFloat,
        keyRadius: CGFloat,
        uiScale: CGFloat
    ) -> some View {
        let arrowSpacing: CGFloat = max(3 * uiScale, 2)
        let arrowClusterWidth = min(width * 0.21, 138 * uiScale)
        let globeWidth = max(28 * uiScale, 24)
        let leftWidth = max(width - arrowClusterWidth - globeWidth - keySpacing * 2, 100)
        let totalWeight = keys.reduce(0.0) { $0 + $1.weight }
        let usableLeftWidth = max(leftWidth - keySpacing * CGFloat(max(keys.count - 1, 0)), 1)
        let arrowKeyWidth = max((arrowClusterWidth - arrowSpacing * 2) / 3, 18)
        let halfArrowHeight = max((keyHeight - 2.5) / 2, 12)

        return HStack(spacing: keySpacing) {
            // Apple bottom-left Globe key: toggles 注音 <-> ABC keycaps + Mac ⌃Space
            Button {
                toggleBilingualMode(switchMacSource: true)
            } label: {
                VStack(spacing: 1) {
                    Image(systemName: "globe")
                        .font(.system(size: max(12.5 * uiScale, 10.5), weight: .medium))
                    Text(inputMode == .zhuyin ? "注" : "EN")
                        .font(.system(size: max(8 * uiScale, 7), weight: .semibold, design: .rounded))
                }
                .foregroundStyle(Color.white.opacity(0.92))
                .frame(width: globeWidth, height: keyHeight)
                .background(Color.white.opacity(0.09), in: RoundedRectangle(cornerRadius: keyRadius, style: .continuous))
                .overlay(
                    RoundedRectangle(cornerRadius: keyRadius, style: .continuous)
                        .strokeBorder(Color.white.opacity(0.14), lineWidth: 0.5)
                )
            }
            .buttonStyle(ApplePressButtonStyle(reduceMotion: reduceMotion))

            HStack(spacing: keySpacing) {
                ForEach(keys) { spec in
                    let keyWidth = usableLeftWidth * CGFloat(spec.weight / totalWeight)
                    keycap(spec, width: keyWidth, height: keyHeight, radius: keyRadius, uiScale: uiScale)
                }
            }

            HStack(alignment: .bottom, spacing: arrowSpacing) {
                keycap(SillKeyboardLayout.arrowLeft, width: arrowKeyWidth, height: keyHeight, radius: keyRadius, uiScale: uiScale)
                VStack(spacing: 2.5) {
                    keycap(SillKeyboardLayout.arrowUp, width: arrowKeyWidth, height: halfArrowHeight, radius: max(keyRadius - 2, 3), compact: true, uiScale: uiScale)
                    keycap(SillKeyboardLayout.arrowDown, width: arrowKeyWidth, height: halfArrowHeight, radius: max(keyRadius - 2, 3), compact: true, uiScale: uiScale)
                }
                keycap(SillKeyboardLayout.arrowRight, width: arrowKeyWidth, height: keyHeight, radius: keyRadius, uiScale: uiScale)
            }
            .frame(width: arrowClusterWidth, height: keyHeight)
        }
    }

    private func keycap(
        _ spec: SillKeySpec,
        width: CGFloat,
        height: CGFloat,
        radius: CGFloat,
        compact: Bool = false,
        uiScale: CGFloat
    ) -> some View {
        AppleFloatingKeycap(
            spec: spec,
            controller: controller,
            inputMode: inputMode,
            width: width,
            height: height,
            cornerRadius: radius,
            uiScale: uiScale,
            compact: compact,
            reduceMotion: reduceMotion
        )
    }

    private func shortcutSymbol(for id: String) -> String? {
        switch id {
        case "spotlight": return "magnifyingglass"
        case "mission": return "rectangle.3.group"
        case "prev-space": return "chevron.left"
        case "next-space": return "chevron.right"
        case "copy": return "doc.on.doc"
        case "paste": return "doc.on.clipboard"
        case "undo": return "arrow.uturn.backward"
        case "close": return "xmark.circle"
        case "quit": return "power"
        default: return nil
        }
    }
}

private struct ApplePressButtonStyle: ButtonStyle {
    let reduceMotion: Bool

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed && !reduceMotion ? 0.94 : 1.0)
            .opacity(configuration.isPressed ? 0.82 : 1.0)
            .animation(reduceMotion ? nil : .spring(response: 0.14, dampingFraction: 0.9), value: configuration.isPressed)
    }
}

private struct FloatingShortcutPill: View {
    let label: String
    let symbol: String?
    let scale: CGFloat
    let reduceMotion: Bool
    var highlighted: Bool = false
    let action: () -> Void

    var body: some View {
        Button {
            UIImpactFeedbackGenerator(style: .light).impactOccurred()
            action()
        } label: {
            HStack(spacing: 3.5) {
                if let symbol {
                    Image(systemName: symbol)
                        .font(.system(size: max(10 * scale, 9), weight: .semibold))
                }
                Text(label)
                    .font(.system(size: max(11 * scale, 9.5), weight: .medium, design: .rounded))
                    .lineLimit(1)
            }
            .foregroundStyle(Color.white.opacity(0.92))
            .padding(.horizontal, max(9 * scale, 7))
            .frame(height: max(24 * scale, 22))
            .background(
                highlighted ? Color(red: 10 / 255, green: 132 / 255, blue: 255 / 255).opacity(0.65) : Color.white.opacity(0.11),
                in: Capsule()
            )
            .overlay(Capsule().stroke(Color.white.opacity(0.15), lineWidth: 0.5))
        }
        .buttonStyle(ApplePressButtonStyle(reduceMotion: reduceMotion))
    }
}

private struct AppleFloatingKeycap: View {
    let spec: SillKeySpec
    @ObservedObject var controller: SillKeyboardController
    let inputMode: SillKeyboardInputMode
    let width: CGFloat
    let height: CGFloat
    let cornerRadius: CGFloat
    let uiScale: CGFloat
    let compact: Bool
    let reduceMotion: Bool

    @State private var isTouchDown = false

    private var isActiveModifier: Bool {
        controller.activeModifiers.contains(spec.code)
    }

    private var isCapsLockActive: Bool {
        spec.kind == .capsLock && controller.capsLockOn
    }

    private var isInverted: Bool {
        isActiveModifier || isCapsLockActive
    }

    private var isReturnKey: Bool {
        spec.code == SillLinuxKey.enter
    }

    private var isPressed: Bool {
        isTouchDown || controller.pressedKeys.contains(spec.code)
    }

    var body: some View {
        ZStack {
            keycapFill
            keycapLabel
            if spec.kind == .capsLock {
                Circle()
                    .fill(controller.capsLockOn
                          ? Color(red: 48 / 255, green: 209 / 255, blue: 88 / 255)
                          : Color.white.opacity(0.24))
                    .frame(width: 4, height: 4)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                    .padding(.top, 5)
                    .padding(.leading, 6)
            }
        }
        .frame(width: width, height: height)
        .clipShape(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                .strokeBorder(
                    Color.white.opacity(isInverted ? 0.5 : (isReturnKey ? 0.25 : 0.12)),
                    lineWidth: 0.5
                )
        }
        .shadow(color: Color.black.opacity(isPressed ? 0.10 : 0.30), radius: 0, x: 0, y: 1)
        .scaleEffect(isPressed && !reduceMotion ? 0.96 : 1.0)
        .animation(reduceMotion ? nil : .spring(response: 0.14, dampingFraction: 0.9), value: isPressed)
        .contentShape(Rectangle())
        .gesture(
            DragGesture(minimumDistance: 0)
                .onChanged { _ in
                    guard !isTouchDown else { return }
                    isTouchDown = true
                    UIImpactFeedbackGenerator(style: .light).impactOccurred()
                    switch spec.kind {
                    case .capsLock:
                        controller.tapCapsLock()
                    case .modifier:
                        controller.toggleModifier(spec.code)
                    case .standard, .function, .accent:
                        controller.pressKey(spec.code)
                    }
                }
                .onEnded { _ in
                    isTouchDown = false
                    switch spec.kind {
                    case .standard, .function, .accent:
                        controller.releaseKey(spec.code)
                    case .capsLock, .modifier:
                        break
                    }
                }
        )
        .accessibilityLabel(spec.label)
    }

    @ViewBuilder
    private var keycapFill: some View {
        let shape = RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
        if isInverted {
            shape.fill(Color.white.opacity(isPressed ? 0.85 : 0.95))
        } else if isReturnKey {
            shape.fill(
                isPressed
                ? Color(red: 0 / 255, green: 102 / 255, blue: 214 / 255)
                : Color(red: 10 / 255, green: 132 / 255, blue: 255 / 255)
            )
        } else if spec.kind == .standard {
            shape.fill(Color.white.opacity(isPressed ? 0.32 : 0.17))
        } else {
            shape.fill(Color.white.opacity(isPressed ? 0.24 : 0.09))
        }
    }

    private var foregroundColor: Color {
        isInverted ? Color(red: 28 / 255, green: 28 / 255, blue: 30 / 255) : .white
    }

    @ViewBuilder
    private var keycapLabel: some View {
        let shiftDown = controller.activeModifiers.contains(SillLinuxKey.leftShift)
            || controller.activeModifiers.contains(SillLinuxKey.rightShift)

        if spec.code == SillLinuxKey.space {
            Text(L10n.text("空白"))
                .font(.system(size: max(11 * uiScale, 9.5), weight: .regular))
                .foregroundStyle(Color.white.opacity(0.42))
        } else if let symbol = sfSymbol(for: spec.code, active: isInverted, pressed: isPressed) {
            Image(systemName: symbol)
                .font(.system(size: compact ? max(9.5 * uiScale, 8) : max(13.5 * uiScale, 11), weight: .medium))
                .foregroundStyle(foregroundColor)
        } else if inputMode == .zhuyin, let bopomofo = SillKeyboardLayout.zhuyinLegend(for: spec.code) {
            ZStack {
                Text(bopomofo)
                    .font(.system(size: max(14.5 * uiScale, 11.5), weight: .regular))
                    .foregroundStyle(foregroundColor)
                    .offset(y: 2 * uiScale)
                Text(spec.label.uppercased())
                    .font(.system(size: max(8 * uiScale, 6.5), weight: .medium, design: .rounded))
                    .foregroundStyle(foregroundColor.opacity(0.42))
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                    .padding(.top, max(2.5 * uiScale, 2))
                    .padding(.leading, max(4 * uiScale, 3))
            }
        } else if let shifted = spec.shiftedLabel {
            VStack(spacing: 0.5) {
                Text(shifted)
                    .font(.system(size: max(9 * uiScale, 7.5), weight: shiftDown ? .semibold : .regular))
                    .foregroundStyle(foregroundColor.opacity(shiftDown ? 0.96 : 0.45))
                Text(spec.label)
                    .font(.system(size: max(13 * uiScale, 10.5), weight: .regular))
                    .foregroundStyle(foregroundColor.opacity(shiftDown ? 0.55 : 0.96))
            }
        } else if spec.isLetter {
            let text = controller.displaysUppercaseLetters ? spec.label.uppercased() : spec.label.lowercased()
            Text(text)
                .font(.system(size: max(15.5 * uiScale, 12.5), weight: .regular))
                .foregroundStyle(foregroundColor)
        } else {
            Text(spec.label)
                .font(.system(size: max(12 * uiScale, 10), weight: .medium, design: .rounded))
                .foregroundStyle(foregroundColor)
                .minimumScaleFactor(0.7)
                .lineLimit(1)
        }
    }

    private func sfSymbol(for code: UInt16, active: Bool, pressed: Bool) -> String? {
        switch code {
        case SillLinuxKey.backspace: return pressed ? "delete.left.fill" : "delete.left"
        case SillLinuxKey.tab: return "arrow.right.to.line"
        case SillLinuxKey.capsLock: return active ? "capslock.fill" : "capslock"
        case SillLinuxKey.leftShift, SillLinuxKey.rightShift: return active ? "shift.fill" : "shift"
        case SillLinuxKey.leftCtrl: return "control"
        case SillLinuxKey.leftOpt, SillLinuxKey.rightOpt: return "option"
        case SillLinuxKey.leftCmd, SillLinuxKey.rightCmd: return "command"
        case SillLinuxKey.enter: return "return"
        case SillLinuxKey.up: return "chevron.up"
        case SillLinuxKey.down: return "chevron.down"
        case SillLinuxKey.left: return "chevron.left"
        case SillLinuxKey.right: return "chevron.right"
        default: return nil
        }
    }
}
