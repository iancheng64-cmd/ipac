import Foundation
import CoreGraphics

@main
struct SillControlsTests {
    static func main() {
        var checks = 0
        func expect(_ condition: @autoclosure () -> Bool, _ message: String) {
            precondition(condition(), message)
            checks += 1
        }

        // 1. Sill keyboard layout completeness & Linux keycode bounds (xhci linux_to_hid size = 256).
        expect(SillKeyboardLayout.rows.count == 5, "Sill keyboard has 5 main rows")
        for row in SillKeyboardLayout.rows {
            expect(!row.isEmpty, "Every keyboard row is non-empty")
            for key in row {
                expect(key.code > 0 && key.code < 256, "Keycode \(key.code) must map in xhci linux_to_hid")
                expect(key.weight > 0, "Key width weight must be positive")
            }
        }
        for arrow in [SillKeyboardLayout.arrowLeft, SillKeyboardLayout.arrowUp, SillKeyboardLayout.arrowDown, SillKeyboardLayout.arrowRight] {
            expect(arrow.code >= 103 && arrow.code <= 108, "Arrow keycode valid")
        }
        expect(SillKeyboardLayout.shortcuts.count == 10, "All 10 Sill shortcut pills exist")
        for sc in SillKeyboardLayout.shortcuts {
            expect(!sc.codes.isEmpty, "Shortcut \(sc.id) must emit at least one key")
            for code in sc.codes {
                expect(code > 0 && code < 256, "Shortcut code \(code) valid")
            }
        }

        // 2. Sticky modifiers, Caps Lock, hold-repeat, shortcut isolation, and releaseAll.
        var keyEvents: [(UInt16, Bool)] = []
        let kbd = SillKeyboardStateMachine { code, down in
            keyEvents.append((code, down))
        }
        expect(!kbd.displaysUppercaseLetters, "Lowercase by default")
        kbd.toggleModifier(SillLinuxKey.leftCmd)
        kbd.toggleModifier(SillLinuxKey.leftShift)
        expect(kbd.isShifted && kbd.displaysUppercaseLetters, "Shift shows uppercase letters")
        kbd.pressKey(SillLinuxKey.c)
        kbd.pressKey(SillLinuxKey.c) // duplicate press is ignored
        kbd.releaseKey(SillLinuxKey.c)
        expect(kbd.activeModifiers.isEmpty, "Sticky modifiers auto-release after standard key release")
        let expectedSeq: [(UInt16, Bool)] = [
            (SillLinuxKey.leftCmd, true),
            (SillLinuxKey.leftShift, true),
            (SillLinuxKey.c, true),
            (SillLinuxKey.c, false),
            (SillLinuxKey.leftShift, false),
            (SillLinuxKey.leftCmd, false),
        ]
        expect(keyEvents.count == expectedSeq.count, "Exact sticky chord event count")
        for (idx, pair) in expectedSeq.enumerated() {
            expect(keyEvents[idx].0 == pair.0 && keyEvents[idx].1 == pair.1, "Sequence step \(idx) matches")
        }

        // Caps Lock + Shift XOR capitalization.
        kbd.tapCapsLock()
        expect(kbd.capsLockOn && kbd.displaysUppercaseLetters, "Caps Lock enables uppercase display")
        kbd.toggleModifier(SillLinuxKey.leftShift)
        expect(!kbd.displaysUppercaseLetters, "Shift + Caps Lock shows lowercase")

        // Shortcut releases any sticky Shift/Cmd first and runs cleanly.
        keyEvents.removeAll()
        kbd.triggerShortcut([SillLinuxKey.leftCmd, SillLinuxKey.space])
        expect(kbd.activeModifiers.isEmpty, "Triggering shortcut clears stale sticky modifiers")
        expect(keyEvents.map(\.0) == [SillLinuxKey.leftShift, SillLinuxKey.leftCmd, SillLinuxKey.space, SillLinuxKey.space, SillLinuxKey.leftCmd],
               "Shortcut releases stale modifier before pressing Spotlight chord")
        expect(keyEvents.map(\.1) == [false, true, true, false, false], "Shortcut edges are properly paired")

        // releaseAll cleans up pressed keys and sticky modifiers.
        keyEvents.removeAll()
        kbd.toggleModifier(SillLinuxKey.leftCtrl)
        kbd.pressKey(SillLinuxKey.up)
        kbd.releaseAll()
        expect(kbd.pressedKeys.isEmpty && kbd.activeModifiers.isEmpty, "releaseAll clears held & sticky keys")
        expect(keyEvents.filter { !$0.1 }.count == 2, "releaseAll sends key-up for both Ctrl and Up")

        // 3. Touch mode persistence & SillTouchEngine in Trackpad mode.
        let suiteName = "com.henge.tests.sill.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }
        expect(TrackpadTouchMode.read(from: defaults) == .trackpad, "Default Sill touch mode is trackpad")
        TrackpadTouchMode.directPointer.save(to: defaults)
        expect(TrackpadTouchMode.read(from: defaults) == .directPointer, "Touch mode persists to UserDefaults")

        let viewSize = CGSize(width: 1000, height: 700)
        let clampedLow = SillTouchEngine.sensorPoint(location: CGPoint(x: -500, y: -500), in: viewSize)
        let clampedHigh = SillTouchEngine.sensorPoint(location: CGPoint(x: 5000, y: 5000), in: viewSize)
        expect(clampedLow.x == 0 && clampedLow.y == 0, "Sensor low bounds clamp to 0")
        expect(clampedHigh.x == SillTouchEngine.sensorW && clampedHigh.y == SillTouchEngine.sensorH, "Sensor high bounds clamp")

        let engine = SillTouchEngine(mode: .trackpad)
        // 1-finger quick tap -> left click.
        let b1 = engine.touchesBegan(
            [SillTouchSample(token: 1, location: CGPoint(x: 300, y: 300), previousLocation: CGPoint(x: 300, y: 300), timestamp: 1.0)],
            viewSize: viewSize, tapsClick: true, now: 1.0
        )
        expect(b1.armHoldTimer && !b1.cancelHoldTimer, "1-finger down arms hold drag timer")
        let e1 = engine.touchesEnded([1], tapsClick: true, tsMs: 1120, now: 1.12)
        expect(e1.cancelHoldTimer && e1.actions.contains(.mouseButton(button: 0, down: true)) && e1.actions.contains(.mouseButton(button: 0, down: false)),
               "Quick 1-finger tap clicks left button")

        // 2-finger quick tap -> right click.
        _ = engine.touchesBegan(
            [
                SillTouchSample(token: 1, location: CGPoint(x: 200, y: 200), previousLocation: CGPoint(x: 200, y: 200), timestamp: 2.0),
                SillTouchSample(token: 2, location: CGPoint(x: 240, y: 200), previousLocation: CGPoint(x: 240, y: 200), timestamp: 2.0),
            ],
            viewSize: viewSize, tapsClick: true, now: 2.0
        )
        let e2 = engine.touchesEnded([1, 2], tapsClick: true, tsMs: 2150, now: 2.15)
        expect(e2.actions.contains(.mouseButton(button: 1, down: true)) && e2.actions.contains(.mouseButton(button: 1, down: false)),
               "Quick 2-finger tap clicks right button")

        // 1-finger hold-drag + 2nd finger multi-touch handoff cancels drag safely.
        _ = engine.touchesBegan(
            [SillTouchSample(token: 10, location: CGPoint(x: 400, y: 300), previousLocation: CGPoint(x: 400, y: 300), timestamp: 3.0)],
            viewSize: viewSize, tapsClick: true, now: 3.0
        )
        let holdActs = engine.fireHoldTimer()
        expect(engine.holdingDrag && holdActs == [.mouseButton(button: 0, down: true), .hapticMedium], "Hold timer starts drag with haptic")
        let addSecond = engine.touchesBegan(
            [SillTouchSample(token: 11, location: CGPoint(x: 430, y: 300), previousLocation: CGPoint(x: 430, y: 300), timestamp: 3.5)],
            viewSize: viewSize, tapsClick: true, now: 3.5
        )
        expect(!engine.holdingDrag && addSecond.actions.contains(.mouseButton(button: 0, down: false)), "Second finger cancels hold drag cleanly")
        _ = engine.touchesEnded([10, 11], tapsClick: true, tsMs: 3600, now: 3.6)

        // 4-finger quick tap -> toggles HUD cleanly with ZERO stray mouse clicks (even if tapsClick is false).
        let fourDown = engine.touchesBegan(
            [
                SillTouchSample(token: 21, location: CGPoint(x: 100, y: 200), previousLocation: CGPoint(x: 100, y: 200), timestamp: 4.0),
                SillTouchSample(token: 22, location: CGPoint(x: 160, y: 200), previousLocation: CGPoint(x: 160, y: 200), timestamp: 4.0),
                SillTouchSample(token: 23, location: CGPoint(x: 220, y: 200), previousLocation: CGPoint(x: 220, y: 200), timestamp: 4.0),
                SillTouchSample(token: 24, location: CGPoint(x: 280, y: 200), previousLocation: CGPoint(x: 280, y: 200), timestamp: 4.0),
            ],
            viewSize: viewSize, tapsClick: false, now: 4.0
        )
        expect(fourDown.cancelHoldTimer, "4-finger tap cancels hold")
        let fourUp = engine.touchesEnded([21, 22, 23, 24], tapsClick: false, tsMs: 4200, now: 4.2)
        expect(fourUp.actions.contains(.toggleHud), "4-finger quick tap emits toggleHud")
        expect(!fourUp.actions.contains(where: { if case .mouseButton = $0 { return true }; return false }),
               "4-finger tap never emits stray mouse button events")

        // 4. Direct Touch Pointer mode: relative move accumulation, 2-finger scroll, mode switch cleanup.
        let direct = SillTouchEngine(mode: .directPointer)
        let db = direct.touchesBegan(
            [SillTouchSample(token: 31, location: CGPoint(x: 500, y: 300), previousLocation: CGPoint(x: 500, y: 300), timestamp: 5.0)],
            viewSize: viewSize, tapsClick: true, now: 5.0
        )
        expect(!db.actions.contains(where: { if case .hidTouch = $0 { return true }; return false }),
               "Direct Pointer mode does not emit USB trackpad HID touches")
        let dm1 = direct.touchesMoved(
            [SillTouchSample(token: 31, location: CGPoint(x: 500.4, y: 300.2), previousLocation: CGPoint(x: 500.0, y: 300.0), timestamp: 5.02)],
            viewSize: viewSize, tapsClick: true, pointerSpeed: 1.0, scrollSpeed: 0.5, reverseScrolling: false, frameTimestamp: 5.02
        )
        let dm2 = direct.touchesMoved(
            [SillTouchSample(token: 31, location: CGPoint(x: 501.2, y: 300.9), previousLocation: CGPoint(x: 500.4, y: 300.2), timestamp: 5.04)],
            viewSize: viewSize, tapsClick: true, pointerSpeed: 1.0, scrollSpeed: 0.5, reverseScrolling: false, frameTimestamp: 5.04
        )
        expect(dm1.actions.isEmpty, "Sub-pixel delta under 0.5 waits for next move")
        expect(dm2.actions == [.mouseMove(dx: 1, dy: 1)], "Sub-pixel remainders accumulate cleanly across moves")
        _ = direct.touchesEnded([31], tapsClick: true, tsMs: 5500, now: 5.5)

        // 2-finger scroll in direct pointer mode (including reverse scrolling).
        _ = direct.touchesBegan(
            [
                SillTouchSample(token: 41, location: CGPoint(x: 300, y: 300), previousLocation: CGPoint(x: 300, y: 300), timestamp: 6.0),
                SillTouchSample(token: 42, location: CGPoint(x: 360, y: 300), previousLocation: CGPoint(x: 360, y: 300), timestamp: 6.0),
            ],
            viewSize: viewSize, tapsClick: true, now: 6.0
        )
        let scMove = direct.touchesMoved(
            [
                SillTouchSample(token: 41, location: CGPoint(x: 300, y: 320), previousLocation: CGPoint(x: 300, y: 300), timestamp: 6.02),
                SillTouchSample(token: 42, location: CGPoint(x: 360, y: 320), previousLocation: CGPoint(x: 360, y: 300), timestamp: 6.02),
            ],
            viewSize: viewSize, tapsClick: true, pointerSpeed: 1.0, scrollSpeed: 1.0, reverseScrolling: false, frameTimestamp: 6.02
        )
        expect(scMove.actions == [.mouseScroll(dx: 0, dy: 11)], "2-finger direct scroll emits scaled mouseScroll")
        let revMove = direct.touchesMoved(
            [
                SillTouchSample(token: 41, location: CGPoint(x: 320, y: 320), previousLocation: CGPoint(x: 300, y: 320), timestamp: 6.04),
                SillTouchSample(token: 42, location: CGPoint(x: 380, y: 320), previousLocation: CGPoint(x: 360, y: 320), timestamp: 6.04),
            ],
            viewSize: viewSize, tapsClick: true, pointerSpeed: 1.0, scrollSpeed: 1.0, reverseScrolling: true, frameTimestamp: 6.04
        )
        expect(revMove.actions == [.mouseScroll(dx: -11, dy: 0)], "reverseScrolling flips horizontal/vertical scroll sign")

        // 5. SessionHUDPolicy auto-hide and 4-finger toggle rules.
        expect(SessionHUDPolicy.shouldAutoHide(vmRunning: true, fillsPhone: true, controlsHidden: false, keyboard: .none, showDetails: false, confirmStop: false),
               "Auto-hides after 5s while running full-screen without overlays")
        expect(!SessionHUDPolicy.shouldAutoHide(vmRunning: true, fillsPhone: true, controlsHidden: false, keyboard: .sill, showDetails: false, confirmStop: false),
               "Does not auto-hide while Sill keyboard is open")
        expect(!SessionHUDPolicy.shouldAutoHide(vmRunning: false, fillsPhone: true, controlsHidden: false, keyboard: .none, showDetails: false, confirmStop: false),
               "Does not auto-hide before VM reaches running state")
        expect(!SessionHUDPolicy.shouldAutoHide(vmRunning: true, fillsPhone: false, controlsHidden: false, keyboard: .none, showDetails: false, confirmStop: false),
               "Does not auto-hide in portrait upright split mode")

        var hidden = false
        var kb: SessionHUDPolicy.KeyboardPresentation = .sill
        let becameHidden = SessionHUDPolicy.onFourFingerTap(controlsHidden: &hidden, keyboard: &kb)
        expect(becameHidden && kb == .none, "4-finger hide also dismisses active Sill keyboard")
        let stillHidden = SessionHUDPolicy.onFourFingerTap(controlsHidden: &hidden, keyboard: &kb)
        expect(!stillHidden, "Second 4-finger tap reveals HUD")

        print("Sill controls: \(checks) checks passed")
    }
}
