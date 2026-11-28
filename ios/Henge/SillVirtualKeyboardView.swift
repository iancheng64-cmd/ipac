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

/// Apple iPadOS Magic Keyboard + Liquid Glass virtual macOS keyboard for Henge sessions.
struct SillVirtualKeyboardView: View {
    @ObservedObject var controller: SillKeyboardController
    let onSwitchToIME: () -> Void
    let onDismiss: () -> Void

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency

    private var isPad: Bool { Device.isPad }
    private var keyHeight: CGFloat { isPad ? 46 : 36 }
    private var rowSpacing: CGFloat { isPad ? 6 : 4.5 }
    private var keySpacing: CGFloat { isPad ? 5.5 : 3.5 }
    private var keyRadius: CGFloat { isPad ? 8 : 6 }
    private var deckRadius: CGFloat { isPad ? 24 : 20 }

    var body: some View {
        GeometryReader { geo in
            let horizontalInset: CGFloat = isPad ? 12 : 6
            let deckWidth = min(geo.size.width - horizontalInset * 2, isPad ? 980 : geo.size.width - horizontalInset * 2)
            let innerWidth = max(deckWidth - (isPad ? 20 : 12), 200)

            VStack(spacing: isPad ? 8 : 6) {
                utilityStrip
                    .frame(width: innerWidth)

                VStack(spacing: rowSpacing) {
                    ForEach(0..<4, id: \.self) { rowIndex in
                        standardRow(SillKeyboardLayout.rows[rowIndex], width: innerWidth)
                    }
                    bottomRow(SillKeyboardLayout.rows[4], width: innerWidth)
                }
                .frame(width: innerWidth)
            }
            .padding(.horizontal, isPad ? 10 : 6)
            .padding(.top, isPad ? 10 : 8)
            .padding(.bottom, isPad ? 12 : 9)
            .frame(width: deckWidth)
            .background { deckBackground }
            .overlay {
                RoundedRectangle(cornerRadius: deckRadius, style: .continuous)
                    .strokeBorder(
                        LinearGradient(
                            colors: [Color.white.opacity(0.26), Color.white.opacity(0.08)],
                            startPoint: .top,
                            endPoint: .bottom
                        ),
                        lineWidth: 0.75
                    )
            }
            .shadow(color: Color.black.opacity(0.45), radius: 22, y: -4)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottom)
            .padding(.bottom, isPad ? 12 : 14)
        }
        .onDisappear {
            controller.releaseAll()
        }
    }

    @ViewBuilder
    private var deckBackground: some View {
        let shape = RoundedRectangle(cornerRadius: deckRadius, style: .continuous)
        if reduceTransparency {
            shape.fill(Color(red: 24 / 255, green: 24 / 255, blue: 26 / 255))
        } else {
            ZStack {
                shape.fill(Color.black.opacity(0.28))
                Color.clear.deskGlass(in: shape)
            }
        }
    }

    private var utilityStrip: some View {
        HStack(spacing: isPad ? 8 : 6) {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: isPad ? 6 : 5) {
                    ForEach(SillKeyboardLayout.shortcuts) { shortcut in
                        ShortcutChipView(
                            shortcut: shortcut,
                            symbol: shortcutSymbol(for: shortcut.id),
                            isPad: isPad,
                            reduceMotion: reduceMotion
                        ) {
                            UIImpactFeedbackGenerator(style: .light).impactOccurred()
                            controller.triggerShortcut(shortcut.codes)
                        }
                    }
                }
                .padding(.vertical, 2)
            }

            Rectangle()
                .fill(Color.white.opacity(0.16))
                .frame(width: 1, height: 18)

            HStack(spacing: isPad ? 6 : 4) {
                UtilityIconButton(
                    systemName: "globe",
                    label: L10n.text("中/英 IME"),
                    accessibilityLabel: L10n.text("切換系統輸入法"),
                    isPad: isPad,
                    reduceMotion: reduceMotion
                ) {
                    UIImpactFeedbackGenerator(style: .light).impactOccurred()
                    onSwitchToIME()
                }

                UtilityIconButton(
                    systemName: "keyboard.chevron.compact.down",
                    label: nil,
                    accessibilityLabel: L10n.text("隱藏鍵盤"),
                    isPad: isPad,
                    reduceMotion: reduceMotion
                ) {
                    UIImpactFeedbackGenerator(style: .light).impactOccurred()
                    onDismiss()
                }
            }
        }
    }

    private func standardRow(_ keys: [SillKeySpec], width: CGFloat) -> some View {
        let totalWeight = keys.reduce(0.0) { $0 + $1.weight }
        let usableWidth = max(width - keySpacing * CGFloat(max(keys.count - 1, 0)), 1)

        return HStack(spacing: keySpacing) {
            ForEach(keys) { spec in
                let keyWidth = usableWidth * CGFloat(spec.weight / totalWeight)
                keycap(spec, width: keyWidth, height: keyHeight)
            }
        }
    }

    private func bottomRow(_ keys: [SillKeySpec], width: CGFloat) -> some View {
        let arrowSpacing: CGFloat = isPad ? 4 : 3
        let arrowClusterWidth = min(width * (isPad ? 0.21 : 0.25), isPad ? 168 : 112)
        let leftWidth = max(width - arrowClusterWidth - keySpacing, 120)
        let totalWeight = keys.reduce(0.0) { $0 + $1.weight }
        let usableLeftWidth = max(leftWidth - keySpacing * CGFloat(max(keys.count - 1, 0)), 1)
        let arrowKeyWidth = max((arrowClusterWidth - arrowSpacing * 2) / 3, 22)
        let halfArrowHeight = max((keyHeight - 3) / 2, 14)

        return HStack(spacing: keySpacing) {
            HStack(spacing: keySpacing) {
                ForEach(keys) { spec in
                    let keyWidth = usableLeftWidth * CGFloat(spec.weight / totalWeight)
                    keycap(spec, width: keyWidth, height: keyHeight)
                }
            }

            HStack(alignment: .bottom, spacing: arrowSpacing) {
                keycap(SillKeyboardLayout.arrowLeft, width: arrowKeyWidth, height: keyHeight)
                VStack(spacing: 3) {
                    keycap(SillKeyboardLayout.arrowUp, width: arrowKeyWidth, height: halfArrowHeight, compact: true)
                    keycap(SillKeyboardLayout.arrowDown, width: arrowKeyWidth, height: halfArrowHeight, compact: true)
                }
                keycap(SillKeyboardLayout.arrowRight, width: arrowKeyWidth, height: keyHeight)
            }
            .frame(width: arrowClusterWidth, height: keyHeight)
        }
    }

    private func keycap(_ spec: SillKeySpec, width: CGFloat, height: CGFloat, compact: Bool = false) -> some View {
        AppleKeycapButton(
            spec: spec,
            controller: controller,
            width: width,
            height: height,
            cornerRadius: compact ? max(keyRadius - 2, 4) : keyRadius,
            isPad: isPad,
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

private struct ShortcutChipView: View {
    let shortcut: SillShortcutSpec
    let symbol: String?
    let isPad: Bool
    let reduceMotion: Bool
    let action: () -> Void

    @State private var isPressed = false

    var body: some View {
        HStack(spacing: 4) {
            if let symbol {
                Image(systemName: symbol)
                    .font(.system(size: isPad ? 11 : 10, weight: .semibold))
            }
            Text(shortcut.label)
                .font(.system(size: isPad ? 12 : 11, weight: .medium, design: .rounded))
                .lineLimit(1)
        }
        .foregroundStyle(Color.white.opacity(isPressed ? 1.0 : 0.92))
        .padding(.horizontal, isPad ? 11 : 8)
        .frame(height: isPad ? 30 : 26)
        .background(Color.white.opacity(isPressed ? 0.24 : 0.11), in: Capsule())
        .overlay(Capsule().stroke(Color.white.opacity(isPressed ? 0.30 : 0.15), lineWidth: 0.5))
        .scaleEffect(isPressed && !reduceMotion ? 0.95 : 1.0)
        .animation(reduceMotion ? nil : .spring(response: 0.16, dampingFraction: 0.9), value: isPressed)
        .contentShape(Capsule())
        .gesture(
            DragGesture(minimumDistance: 0)
                .onChanged { _ in
                    if !isPressed { isPressed = true }
                }
                .onEnded { _ in
                    isPressed = false
                    action()
                }
        )
    }
}

private struct UtilityIconButton: View {
    let systemName: String
    let label: String?
    let accessibilityLabel: String
    let isPad: Bool
    let reduceMotion: Bool
    let action: () -> Void

    @State private var isPressed = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 4) {
                Image(systemName: systemName)
                    .font(.system(size: isPad ? 14 : 12.5, weight: .medium))
                if let label {
                    Text(label)
                        .font(.system(size: isPad ? 11.5 : 10.5, weight: .medium, design: .rounded))
                        .lineLimit(1)
                }
            }
            .foregroundStyle(Color.white.opacity(0.92))
            .padding(.horizontal, label != nil ? (isPad ? 10 : 8) : (isPad ? 11 : 9))
            .frame(height: isPad ? 30 : 26)
            .background(Color.white.opacity(isPressed ? 0.24 : 0.13), in: Capsule())
            .overlay(Capsule().stroke(Color.white.opacity(0.18), lineWidth: 0.5))
        }
        .buttonStyle(.plain)
        .scaleEffect(isPressed && !reduceMotion ? 0.95 : 1.0)
        .simultaneousGesture(
            DragGesture(minimumDistance: 0)
                .onChanged { _ in if !isPressed { isPressed = true } }
                .onEnded { _ in isPressed = false }
        )
        .accessibilityLabel(accessibilityLabel)
    }
}

private struct AppleKeycapButton: View {
    let spec: SillKeySpec
    @ObservedObject var controller: SillKeyboardController
    let width: CGFloat
    let height: CGFloat
    let cornerRadius: CGFloat
    let isPad: Bool
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
                    .frame(width: 4.5, height: 4.5)
                    .shadow(color: controller.capsLockOn
                            ? Color(red: 48 / 255, green: 209 / 255, blue: 88 / 255).opacity(0.7)
                            : .clear,
                            radius: 3)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                    .padding(.top, isPad ? 6 : 4.5)
                    .padding(.leading, isPad ? 7 : 5)
            }
        }
        .frame(width: width, height: height)
        .clipShape(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                .strokeBorder(
                    LinearGradient(
                        colors: [
                            Color.white.opacity(isInverted ? 0.55 : (isReturnKey ? 0.28 : 0.16)),
                            Color.white.opacity(0.03)
                        ],
                        startPoint: .top,
                        endPoint: .bottom
                    ),
                    lineWidth: 0.5
                )
        }
        .shadow(color: Color.black.opacity(isPressed ? 0.15 : 0.50), radius: 0.6, x: 0, y: 1.2)
        .scaleEffect(isPressed && !reduceMotion ? 0.955 : 1.0)
        .animation(reduceMotion ? nil : .spring(response: 0.16, dampingFraction: 0.9), value: isPressed)
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
                LinearGradient(
                    colors: isPressed
                    ? [Color(red: 0 / 255, green: 102 / 255, blue: 214 / 255), Color(red: 0 / 255, green: 88 / 255, blue: 186 / 255)]
                    : [Color(red: 18 / 255, green: 140 / 255, blue: 255 / 255), Color(red: 10 / 255, green: 122 / 255, blue: 245 / 255)],
                    startPoint: .top,
                    endPoint: .bottom
                )
            )
        } else if spec.kind == .standard {
            shape.fill(
                LinearGradient(
                    colors: isPressed
                    ? [Color(red: 94 / 255, green: 94 / 255, blue: 98 / 255), Color(red: 82 / 255, green: 82 / 255, blue: 86 / 255)]
                    : [Color(red: 68 / 255, green: 68 / 255, blue: 72 / 255), Color(red: 56 / 255, green: 56 / 255, blue: 59 / 255)],
                    startPoint: .top,
                    endPoint: .bottom
                )
            )
        } else {
            shape.fill(
                LinearGradient(
                    colors: isPressed
                    ? [Color(red: 74 / 255, green: 74 / 255, blue: 78 / 255), Color(red: 64 / 255, green: 64 / 255, blue: 68 / 255)]
                    : [Color(red: 46 / 255, green: 46 / 255, blue: 49 / 255), Color(red: 36 / 255, green: 36 / 255, blue: 39 / 255)],
                    startPoint: .top,
                    endPoint: .bottom
                )
            )
        }
    }

    private var foregroundColor: Color {
        if isInverted {
            return Color(red: 28 / 255, green: 28 / 255, blue: 30 / 255)
        }
        return .white
    }

    @ViewBuilder
    private var keycapLabel: some View {
        let shiftDown = controller.activeModifiers.contains(SillLinuxKey.leftShift)
            || controller.activeModifiers.contains(SillLinuxKey.rightShift)

        if spec.code == SillLinuxKey.space {
            Text(L10n.text("空白"))
                .font(.system(size: isPad ? 12 : 11, weight: .regular))
                .foregroundStyle(Color.white.opacity(0.36))
        } else if let symbol = sfSymbol(for: spec.code, active: isInverted, pressed: isPressed) {
            if isPad && spec.kind == .modifier && !spec.label.isEmpty && spec.label != "⇧" {
                VStack(spacing: 1) {
                    Image(systemName: symbol)
                        .font(.system(size: 12, weight: .medium))
                    Text(spec.label)
                        .font(.system(size: 9.5, weight: .regular, design: .rounded))
                        .opacity(0.85)
                }
                .foregroundStyle(foregroundColor)
            } else {
                Image(systemName: symbol)
                    .font(.system(size: compact ? (isPad ? 10.5 : 9.5) : (isPad ? 15.5 : 13.5), weight: .medium))
                    .foregroundStyle(foregroundColor)
            }
        } else if let shifted = spec.shiftedLabel {
            if isPad {
                VStack(spacing: 1) {
                    Text(shifted)
                        .font(.system(size: 10, weight: shiftDown ? .semibold : .regular))
                        .foregroundStyle(foregroundColor.opacity(shiftDown ? 0.96 : 0.48))
                    Text(spec.label)
                        .font(.system(size: 15.5, weight: shiftDown ? .regular : .regular))
                        .foregroundStyle(foregroundColor.opacity(shiftDown ? 0.56 : 0.96))
                }
            } else {
                Text(shiftDown ? shifted : spec.label)
                    .font(.system(size: 15, weight: .regular))
                    .foregroundStyle(foregroundColor)
            }
        } else if spec.isLetter {
            let text = controller.displaysUppercaseLetters ? spec.label.uppercased() : spec.label.lowercased()
            Text(text)
                .font(.system(size: isPad ? 18 : 15.5, weight: .regular))
                .foregroundStyle(foregroundColor)
        } else {
            Text(spec.label)
                .font(.system(size: isPad ? 13 : 11.5, weight: .medium, design: .rounded))
                .foregroundStyle(foregroundColor)
                .minimumScaleFactor(0.75)
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
