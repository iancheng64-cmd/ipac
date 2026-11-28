import SwiftUI
import UIKit

/// A surface backed by `SillTouchEngine`:
/// - Sill Multi-Finger Trackpad mode: presents fingers to macOS via the emulated USB Magic Trackpad 2
///   (2-finger scroll/pinch, 3-finger Spaces & Mission Control), plus optional tap-to-click / hold-to-drag.
/// - Direct Touch Pointer mode: 1-finger relative cursor drag, 2-finger scroll, tap click, hold-to-drag.
/// - Both modes: 4-finger quick tap anywhere toggles the floating HUD capsule cleanly without stray clicks.
struct Trackpad: UIViewRepresentable {
    /// Four fingers tapped together: the session toggles its floating controls.
    static let revealTap = Notification.Name("henge.trackpad.revealTap")

    var touchMode: TrackpadTouchMode = .trackpad
    var pointerSpeed: Double = 1.0
    var scrollSpeed: Double = 0.3
    var reverseScrolling: Bool = false
    var onToggleHud: (() -> Void)? = nil

    func makeUIView(context: Context) -> Surface {
        let view = Surface()
        applyConfig(to: view)
        return view
    }

    func updateUIView(_ view: Surface, context: Context) {
        applyConfig(to: view)
    }

    private func applyConfig(to view: Surface) {
        view.pointerSpeed = pointerSpeed
        view.scrollSpeed = scrollSpeed
        view.reverseScrolling = reverseScrolling
        view.onToggleHud = onToggleHud
        view.setTouchMode(touchMode)
    }

    final class Surface: UIView, UIPointerInteractionDelegate {
        private let engine = SillTouchEngine(mode: .trackpad)
        private var holdTimer: Timer?
        private let lightBuzz = UIImpactFeedbackGenerator(style: .light)
        private let mediumBuzz = UIImpactFeedbackGenerator(style: .medium)
        private var touchesLogged = 0

        var pointerSpeed: Double = 1.0
        var scrollSpeed: Double = 0.3
        var reverseScrolling: Bool = false
        var onToggleHud: (() -> Void)?

        private var tapsClick: Bool { VolumeClicks.inputMode == .touchscreen }

        override init(frame: CGRect) {
            super.init(frame: frame)
            isMultipleTouchEnabled = true
            backgroundColor = .clear
            addInteraction(UIPointerInteraction(delegate: self))
        }

        /// Over the Mac there is only the Mac's pointer, if iPadOS hasn't locked its own away.
        func pointerInteraction(_ interaction: UIPointerInteraction, styleFor region: UIPointerRegion) -> UIPointerStyle? { .hidden() }

        required init?(coder: NSCoder) { fatalError("made in code") }

        func setTouchMode(_ mode: TrackpadTouchMode) {
            let result = engine.switchMode(to: mode, tsMs: SillTouchEngine.ms(ProcessInfo.processInfo.systemUptime))
            if result.cancelHoldTimer { cancelHold() }
            execute(result.actions)
        }

        private func makeSamples(_ touches: Set<UITouch>) -> [SillTouchSample] {
            touches.compactMap { touch in
                guard touch.type != .indirectPointer else { return nil }
                return SillTouchSample(
                    token: ObjectIdentifier(touch).hashValue,
                    location: touch.location(in: self),
                    previousLocation: touch.previousLocation(in: self),
                    timestamp: touch.timestamp
                )
            }
        }

        override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent?) {
            let samples = makeSamples(touches)
            guard !samples.isEmpty else { return }
            if engine.activeFingerCount == 0 && tapsClick {
                lightBuzz.prepare()
                mediumBuzz.prepare()
            }
            let result = engine.touchesBegan(
                samples,
                viewSize: bounds.size,
                tapsClick: tapsClick,
                now: ProcessInfo.processInfo.systemUptime
            )
            if result.cancelHoldTimer { cancelHold() }
            execute(result.actions)
            if result.armHoldTimer { armHold() }
        }

        override func touchesMoved(_ touches: Set<UITouch>, with event: UIEvent?) {
            let samples = makeSamples(touches)
            guard !samples.isEmpty else { return }
            let ts = event?.timestamp ?? samples[0].timestamp
            let result = engine.touchesMoved(
                samples,
                viewSize: bounds.size,
                tapsClick: tapsClick,
                pointerSpeed: pointerSpeed,
                scrollSpeed: scrollSpeed,
                reverseScrolling: reverseScrolling,
                frameTimestamp: ts
            )
            if result.cancelHoldTimer { cancelHold() }
            execute(result.actions)
        }

        override func touchesEnded(_ touches: Set<UITouch>, with event: UIEvent?) {
            endTouches(touches)
        }

        override func touchesCancelled(_ touches: Set<UITouch>, with event: UIEvent?) {
            endTouches(touches)
        }

        private func endTouches(_ touches: Set<UITouch>) {
            let tokens = touches.compactMap { touch -> Int? in
                guard touch.type != .indirectPointer else { return nil }
                return ObjectIdentifier(touch).hashValue
            }
            guard !tokens.isEmpty else { return }
            let tsMs = SillTouchEngine.ms(touches.map(\.timestamp).max() ?? ProcessInfo.processInfo.systemUptime)
            let result = engine.touchesEnded(
                tokens,
                tapsClick: tapsClick,
                tsMs: tsMs,
                now: ProcessInfo.processInfo.systemUptime
            )
            if result.cancelHoldTimer { cancelHold() }
            execute(result.actions)
        }

        private func execute(_ actions: [SillTouchAction]) {
            for action in actions {
                switch action {
                case let .hidTouch(id, phase, x, y, tsMs):
                    henge_vm_touch(id, phase, x, y, tsMs)
                    if phase == 0 && HardwareMouse.traceInput && touchesLogged < 12 {
                        touchesLogged += 1
                        HengeLog.log("input", "trackpad: finger \(id) down at \(x),\(y)")
                    }
                case let .hidTouchFrame(tsMs):
                    henge_vm_touch_frame(tsMs)
                case let .mouseMove(dx, dy):
                    henge_vm_mouse_move(dx, dy)
                case let .mouseButton(button, down):
                    henge_vm_mouse_button(button, down ? 1 : 0)
                case let .mouseScroll(dx, dy):
                    henge_vm_mouse_scroll(dx, dy)
                case .hapticLight:
                    lightBuzz.impactOccurred()
                case .hapticMedium:
                    mediumBuzz.impactOccurred()
                case .toggleHud:
                    if let onToggleHud {
                        onToggleHud()
                    } else {
                        NotificationCenter.default.post(name: Trackpad.revealTap, object: nil)
                    }
                case .releaseStickyKeys:
                    StickyKeys.shared.releaseAll()
                }
            }
        }

        private func armHold() {
            cancelHold()
            let timer = Timer(timeInterval: SillTouchEngine.holdDelay, repeats: false) { [weak self] _ in
                guard let self else { return }
                self.execute(self.engine.fireHoldTimer())
            }
            RunLoop.main.add(timer, forMode: .common)
            holdTimer = timer
        }

        private func cancelHold() {
            holdTimer?.invalidate()
            holdTimer = nil
        }
    }
}

/// One mouse button you can hold: down when touched, up when let go.
struct MouseButton: View {
    let title: String
    let button: Int32
    @State private var down = false

    var body: some View {
        Text(title)
            .font(.system(size: 15))
            .foregroundStyle(down ? Desk.text : Desk.dim)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(down ? Desk.raised : Color.clear)
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { _ in
                        guard !down else { return }
                        down = true
                        henge_vm_mouse_button(button, 1)
                        UIImpactFeedbackGenerator(style: .light).impactOccurred()
                    }
                    .onEnded { _ in
                        down = false
                        henge_vm_mouse_button(button, 0)
                        StickyKeys.shared.releaseAll()
                    }
            )
            .accessibilityLabel(title)
    }
}
