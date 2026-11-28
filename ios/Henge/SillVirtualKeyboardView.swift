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

/// Docked dark frosted-glass macOS keyboard inspired by iPac Android's Sill panel,
/// featuring sticky ⌃/⌥/⌘/⇧ modifiers, Caps Lock, 5-row QWERTY + arrow cluster,
/// and a scrollable Sill shortcut toolbar with system IME handoff.
struct SillVirtualKeyboardView: View {
    @ObservedObject var controller: SillKeyboardController
    let onSwitchToIME: () -> Void
    let onDismiss: () -> Void

    private let haptic = UIImpactFeedbackGenerator(style: .light)

    var body: some View {
        GeometryReader { geo in
            let compactHeight = geo.size.height < 460
            let keyHeight: CGFloat = compactHeight ? 33 : (Device.isPad ? 42 : 36)
            let rowSpacing: CGFloat = compactHeight ? 4 : (Device.isPad ? 6 : 5)
            let keyGap: CGFloat = Device.isPad ? 5 : 4
            let sidePad: CGFloat = Device.isPad ? 10 : 6
            let availWidth = max(geo.size.width - sidePad * 2, 240)

            VStack(spacing: rowSpacing) {
                toolbar
                    .padding(.bottom, 2)

                ForEach(Array(SillKeyboardLayout.rows.enumerated()), id: \.offset) { index, row in
                    if index == 4 {
                        bottomRow(
                            row,
                            totalWidth: availWidth,
                            keyGap: keyGap,
                            keyHeight: keyHeight
                        )
                    } else {
                        standardRow(
                            row,
                            totalWidth: availWidth,
                            keyGap: keyGap,
                            keyHeight: keyHeight
                        )
                    }
                }
            }
            .padding(.horizontal, sidePad)
            .padding(.top, 9)
            .padding(.bottom, max(geo.safeAreaInsets.bottom, 8) + 2)
            .frame(maxWidth: .infinity)
            .background {
                TopRoundedShape(radius: 22)
                    .fill(.ultraThinMaterial)
                    .overlay(
                        TopRoundedShape(radius: 22)
                            .fill(Color(red: 19 / 255, green: 21 / 255, blue: 28 / 255).opacity(0.84))
                    )
                    .overlay(
                        TopRoundedShape(radius: 22)
                            .stroke(Color.white.opacity(0.20), lineWidth: 0.75)
                    )
                    .shadow(color: .black.opacity(0.45), radius: 18, y: -4)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottom)
        }
        .frame(height: Device.isPad ? 296 : 254)
        .onAppear { haptic.prepare() }
        .onDisappear { controller.releaseAll() }
    }

    private var toolbar: some View {
        HStack(spacing: 6) {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 6) {
                    ForEach(SillKeyboardLayout.shortcuts) { shortcut in
                        Button {
                            haptic.impactOccurred()
                            controller.triggerShortcut(shortcut.codes)
                        } label: {
                            Text(shortcut.label)
                                .font(.system(size: 12.5, weight: .semibold))
                                .foregroundStyle(.white)
                                .padding(.horizontal, 11)
                                .frame(height: 30)
                                .background(
                                    Capsule()
                                        .fill(Color.white.opacity(0.11))
                                )
                                .overlay(
                                    Capsule()
                                        .stroke(Color.white.opacity(0.16), lineWidth: 0.5)
                                )
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(.vertical, 1)
            }

            Button {
                haptic.impactOccurred()
                controller.releaseAll()
                onSwitchToIME()
            } label: {
                Text(L10n.text("中/英 IME"))
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(.white.opacity(0.92))
                    .padding(.horizontal, 10)
                    .frame(height: 30)
                    .background(Capsule().fill(Color.white.opacity(0.13)))
                    .overlay(Capsule().stroke(Color.white.opacity(0.18), lineWidth: 0.5))
            }
            .buttonStyle(.plain)
            .accessibilityLabel(L10n.text("切換系統輸入法"))

            Button {
                haptic.impactOccurred()
                controller.releaseAll()
                onDismiss()
            } label: {
                HStack(spacing: 3) {
                    Text(L10n.text("收起"))
                    Image(systemName: "chevron.down")
                        .font(.system(size: 10, weight: .bold))
                }
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(.white)
                .padding(.horizontal, 11)
                .frame(height: 30)
                .background(Capsule().fill(Desk.accent))
            }
            .buttonStyle(.plain)
            .accessibilityLabel(L10n.text("隱藏鍵盤"))
        }
    }

    private func standardRow(
        _ row: [SillKeySpec],
        totalWidth: CGFloat,
        keyGap: CGFloat,
        keyHeight: CGFloat
    ) -> some View {
        let totalWeight = row.reduce(0.0) { $0 + $1.weight }
        let usable = max(totalWidth - keyGap * CGFloat(max(row.count - 1, 0)), 120)
        return HStack(spacing: keyGap) {
            ForEach(row) { spec in
                let width = usable * CGFloat(spec.weight / totalWeight)
                keyView(spec, width: width, height: keyHeight)
            }
        }
    }

    private func bottomRow(
        _ row: [SillKeySpec],
        totalWidth: CGFloat,
        keyGap: CGFloat,
        keyHeight: CGFloat
    ) -> some View {
        let arrowClusterWeight = 3.15
        let mainWeight = row.reduce(0.0) { $0 + $1.weight }
        let totalWeight = mainWeight + arrowClusterWeight
        let itemCount = row.count + 3 // main keys + (left, up/down stack, right)
        let usable = max(totalWidth - keyGap * CGFloat(itemCount - 1), 120)
        let unit = usable / CGFloat(totalWeight)
        let arrowW = unit * CGFloat(arrowClusterWeight / 3.0)
        let halfH = max((keyHeight - 3) / 2, 14)

        return HStack(spacing: keyGap) {
            ForEach(row) { spec in
                keyView(spec, width: unit * CGFloat(spec.weight), height: keyHeight)
            }
            keyView(SillKeyboardLayout.arrowLeft, width: arrowW, height: keyHeight, compactFont: true)
            VStack(spacing: 3) {
                keyView(SillKeyboardLayout.arrowUp, width: arrowW, height: halfH, compactFont: true)
                keyView(SillKeyboardLayout.arrowDown, width: arrowW, height: halfH, compactFont: true)
            }
            keyView(SillKeyboardLayout.arrowRight, width: arrowW, height: keyHeight, compactFont: true)
        }
    }

    private func keyView(
        _ spec: SillKeySpec,
        width: CGFloat,
        height: CGFloat,
        compactFont: Bool = false
    ) -> some View {
        let active = (spec.kind == .modifier && controller.activeModifiers.contains(spec.code))
            || (spec.kind == .capsLock && controller.capsLockOn)
        let pressed = controller.pressedKeys.contains(spec.code)
        let displayLabel: String = {
            if spec.isLetter {
                return controller.displaysUppercaseLetters ? spec.label.uppercased() : spec.label.lowercased()
            }
            if spec.code == SillLinuxKey.space {
                return L10n.text("空白")
            }
            return spec.label
        }()

        return SillKeycapView(
            label: displayLabel,
            shiftedLabel: spec.shiftedLabel,
            showSecondary: width >= 34 && height >= 30 && spec.shiftedLabel != nil,
            isActive: active,
            isPressed: pressed,
            kind: spec.kind,
            width: width,
            height: height,
            compactFont: compactFont,
            onTapToggle: {
                haptic.impactOccurred()
                if spec.kind == .modifier {
                    controller.toggleModifier(spec.code)
                } else if spec.kind == .capsLock {
                    controller.tapCapsLock()
                }
            },
            onPressChanged: { isDown in
                if isDown {
                    haptic.impactOccurred()
                    controller.pressKey(spec.code)
                } else {
                    controller.releaseKey(spec.code)
                }
            }
        )
    }
}

private struct SillKeycapView: View {
    let label: String
    let shiftedLabel: String?
    let showSecondary: Bool
    let isActive: Bool
    let isPressed: Bool
    let kind: SillKeyKind
    let width: CGFloat
    let height: CGFloat
    let compactFont: Bool
    let onTapToggle: () -> Void
    let onPressChanged: (Bool) -> Void

    @State private var touching = false

    private var fillColor: Color {
        if isActive { return Desk.accent }
        if isPressed || touching { return Desk.accent.opacity(0.85) }
        switch kind {
        case .standard: return Color.white.opacity(0.145)
        case .function, .modifier, .capsLock: return Color.white.opacity(0.085)
        case .accent: return Desk.accent.opacity(0.42)
        }
    }

    var body: some View {
        let corner: CGFloat = height < 24 ? 6 : 8
        let fontSize: CGFloat = compactFont ? 10 : (kind == .standard && label.count == 1 ? 15 : 13)

        ZStack {
            if showSecondary, let shiftedLabel {
                VStack(spacing: 0) {
                    Text(shiftedLabel)
                        .font(.system(size: 9.5, weight: .medium))
                        .foregroundStyle(.white.opacity(isActive ? 0.85 : 0.48))
                    Text(label)
                        .font(.system(size: 13.5, weight: .semibold))
                        .foregroundStyle(.white)
                }
            } else {
                Text(label)
                    .font(.system(size: fontSize, weight: kind == .standard ? .medium : .semibold))
                    .foregroundStyle(.white.opacity(isActive || kind == .standard ? 1.0 : 0.92))
                    .lineLimit(1)
                    .minimumScaleFactor(0.75)
            }

            if kind == .capsLock {
                Circle()
                    .fill(isActive ? Color(red: 57 / 255, green: 217 / 255, blue: 138 / 255) : Color.white.opacity(0.24))
                    .frame(width: 4.5, height: 4.5)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topTrailing)
                    .padding(4.5)
            }
        }
        .frame(width: max(width, 16), height: height)
        .background(
            RoundedRectangle(cornerRadius: corner, style: .continuous)
                .fill(fillColor)
        )
        .overlay(
            RoundedRectangle(cornerRadius: corner, style: .continuous)
                .stroke(Color.white.opacity(isActive ? 0.38 : 0.14), lineWidth: 0.5)
        )
        .scaleEffect((touching || isPressed) ? 0.95 : 1.0)
        .animation(.easeOut(duration: 0.08), value: touching)
        .contentShape(Rectangle())
        .gesture(
            DragGesture(minimumDistance: 0)
                .onChanged { _ in
                    guard !touching else { return }
                    touching = true
                    if kind != .modifier && kind != .capsLock {
                        onPressChanged(true)
                    }
                }
                .onEnded { _ in
                    let wasTouching = touching
                    touching = false
                    guard wasTouching else { return }
                    if kind == .modifier || kind == .capsLock {
                        onTapToggle()
                    } else {
                        onPressChanged(false)
                    }
                }
        )
    }
}

private struct TopRoundedShape: Shape {
    let radius: CGFloat

    func path(in rect: CGRect) -> Path {
        let p = UIBezierPath(
            roundedRect: rect,
            byRoundingCorners: [.topLeft, .topRight],
            cornerRadii: CGSize(width: radius, height: radius)
        )
        return Path(p.cgPath)
    }
}
