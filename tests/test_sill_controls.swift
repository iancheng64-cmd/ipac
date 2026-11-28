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
        expect(SillKeyboardLayout.zhuyinMap.count == 41, "All 41 standard Taiwan Zhuyin keys mapped")
        expect(SillKeyboardLayout.zhuyinLegend(for: SillLinuxKey.q) == "ㄆ"
               && SillKeyboardLayout.zhuyinLegend(for: SillLinuxKey.one) == "ㄅ"
               && SillKeyboardLayout.zhuyinLegend(for: SillLinuxKey.slash) == "ㄥ",
               "Zhuyin legends match standard Apple Taiwan keyboard")
        expect(SillKeyboardInputMode.zhuyin != SillKeyboardInputMode.english, "Input modes distinguish Zhuyin and English")

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
        expect(fourDown.cancelHoldTimer && fourDown.armFourFingerHoldTimer, "4-finger tap cancels 1-finger hold and arms 4-finger hold")
        let fourUp = engine.touchesEnded([21, 22, 23, 24], tapsClick: false, tsMs: 4200, now: 4.2)
        expect(fourUp.actions.contains(.toggleHud), "4-finger quick tap emits toggleHud")
        expect(!fourUp.actions.contains(where: { if case .mouseButton = $0 { return true }; return false }),
               "4-finger tap never emits stray mouse button events")

        // 4-finger long press -> toggles HUD immediately when hold timer fires, and lift does NOT double-toggle.
        let fourHoldDown = engine.touchesBegan(
            [
                SillTouchSample(token: 25, location: CGPoint(x: 100, y: 200), previousLocation: CGPoint(x: 100, y: 200), timestamp: 4.4),
                SillTouchSample(token: 26, location: CGPoint(x: 160, y: 200), previousLocation: CGPoint(x: 160, y: 200), timestamp: 4.4),
                SillTouchSample(token: 27, location: CGPoint(x: 220, y: 200), previousLocation: CGPoint(x: 220, y: 200), timestamp: 4.4),
                SillTouchSample(token: 28, location: CGPoint(x: 280, y: 200), previousLocation: CGPoint(x: 280, y: 200), timestamp: 4.4),
            ],
            viewSize: viewSize, tapsClick: true, now: 4.4
        )
        expect(fourHoldDown.armFourFingerHoldTimer, "4-finger hold arms long-press HUD toggle")
        let fourHoldActs = engine.fireFourFingerHoldTimer()
        expect(fourHoldActs == [.hapticMedium, .toggleHud], "4-finger long press toggles HUD immediately with medium haptic")
        let fourHoldUp = engine.touchesEnded([25, 26, 27, 28], tapsClick: true, tsMs: 5100, now: 5.1)
        expect(!fourHoldUp.actions.contains(.toggleHud), "Lifting after 4-finger long press never double-toggles HUD")

        // 3-finger Mac-native drag in Trackpad mode: lifts HID touches, starts left drag after 5pt slop, survives early single-finger lift, releases on all up.
        let threeDown = engine.touchesBegan(
            [
                SillTouchSample(token: 61, location: CGPoint(x: 300, y: 300), previousLocation: CGPoint(x: 300, y: 300), timestamp: 6.0),
                SillTouchSample(token: 62, location: CGPoint(x: 340, y: 300), previousLocation: CGPoint(x: 340, y: 300), timestamp: 6.0),
                SillTouchSample(token: 63, location: CGPoint(x: 380, y: 300), previousLocation: CGPoint(x: 380, y: 300), timestamp: 6.0),
            ],
            viewSize: viewSize, tapsClick: false, now: 6.0
        )
        expect(engine.threeFingerTracking && !engine.threeFingerDragActive && !threeDown.actions.contains(where: { if case .hidTouch = $0 { return true }; return false }),
               "3 fingers enter tracking without emitting HID Mission Control contacts")
        let threeSmallMove = engine.touchesMoved(
            [
                SillTouchSample(token: 61, location: CGPoint(x: 302, y: 300), previousLocation: CGPoint(x: 300, y: 300), timestamp: 6.02),
                SillTouchSample(token: 62, location: CGPoint(x: 342, y: 300), previousLocation: CGPoint(x: 340, y: 300), timestamp: 6.02),
                SillTouchSample(token: 63, location: CGPoint(x: 382, y: 300), previousLocation: CGPoint(x: 380, y: 300), timestamp: 6.02),
            ],
            viewSize: viewSize, tapsClick: false, pointerSpeed: 1.0, scrollSpeed: 0.3, reverseScrolling: false, frameTimestamp: 6.02
        )
        expect(!engine.threeFingerDragActive && threeSmallMove.actions.isEmpty, "Micro jitter below 5pt slop does not grab yet")
        let threeDragMove = engine.touchesMoved(
            [
                SillTouchSample(token: 61, location: CGPoint(x: 312, y: 306), previousLocation: CGPoint(x: 302, y: 300), timestamp: 6.04),
                SillTouchSample(token: 62, location: CGPoint(x: 352, y: 306), previousLocation: CGPoint(x: 342, y: 300), timestamp: 6.04),
                SillTouchSample(token: 63, location: CGPoint(x: 392, y: 306), previousLocation: CGPoint(x: 382, y: 300), timestamp: 6.04),
            ],
            viewSize: viewSize, tapsClick: false, pointerSpeed: 1.0, scrollSpeed: 0.3, reverseScrolling: false, frameTimestamp: 6.04
        )
        expect(engine.threeFingerDragActive && threeDragMove.actions.contains(.mouseButton(button: 0, down: true)) && threeDragMove.actions.contains(.mouseMove(dx: 14, dy: 8)),
               "3-finger move past slop starts left drag and moves cursor smoothly")
        let partialLift = engine.touchesEnded([63], tapsClick: false, tsMs: 6080, now: 6.08)
        expect(!partialLift.actions.contains(.mouseButton(button: 0, down: false)) && engine.threeFingerDragActive,
               "Lifting 1 of 3 fingers keeps drag alive until gesture finishes")
        let threeEnd = engine.touchesEnded([61, 62], tapsClick: false, tsMs: 6120, now: 6.12)
        expect(!engine.threeFingerDragActive && threeEnd.actions.contains(.mouseButton(button: 0, down: false)),
               "3-finger drag releases left button cleanly when all fingers lift")

        // 4. Direct Touch Pointer mode (Sill full-screen style): Port 3 USB absolute pointer + synthetic MT2 scroll.
        let screenRect = CGRect(x: 100, y: 50, width: 800, height: 600)
        let mappedMid = SillTouchEngine.absolutePoint(location: CGPoint(x: 500, y: 350), in: screenRect, fallbackSize: viewSize)
        expect(mappedMid.x == 16384 && mappedMid.y == 16384, "screenRect center maps accurately to 0...32767 midpoint")

        let direct = SillTouchEngine(mode: .directPointer)
        // 1-finger tap -> left click at touched absolute position.
        let db = direct.touchesBegan(
            [SillTouchSample(token: 31, location: CGPoint(x: 500, y: 350), previousLocation: CGPoint(x: 500, y: 350), timestamp: 7.0)],
            viewSize: viewSize, screenRect: screenRect, tapsClick: true, now: 7.0
        )
        expect(db.armHoldTimer && db.actions == [.absolutePointer(x: 16384, y: 16384, buttons: 0)],
               "Direct touch moves Port 3 absolute pointer on finger down")
        let de = direct.touchesEnded([31], tapsClick: true, tsMs: 7120, now: 7.12)
        expect(de.actions.contains(.absolutePointer(x: 16384, y: 16384, buttons: 1)) && de.actions.contains(.absolutePointer(x: 16384, y: 16384, buttons: 0)),
               "Direct touch quick tap left-clicks at touched macOS pixel")

        // 1-finger long-press without move -> right-click upon release.
        _ = direct.touchesBegan(
            [SillTouchSample(token: 32, location: CGPoint(x: 500, y: 350), previousLocation: CGPoint(x: 500, y: 350), timestamp: 8.0)],
            viewSize: viewSize, screenRect: screenRect, tapsClick: true, now: 8.0
        )
        let holdDirect = direct.fireHoldTimer()
        expect(direct.directHeld && holdDirect == [.hapticMedium], "Direct long press arms right-click / drag with medium haptic")
        let rightClickEnd = direct.touchesEnded([32], tapsClick: true, tsMs: 8500, now: 8.5)
        expect(rightClickEnd.actions.contains(.absolutePointer(x: 16384, y: 16384, buttons: 2)) && rightClickEnd.actions.contains(.absolutePointer(x: 16384, y: 16384, buttons: 0)),
               "Lifting stationary long press sends right-click at anchor point")

        // 1-finger long-press + move -> 1:1 absolute drag.
        _ = direct.touchesBegan(
            [SillTouchSample(token: 33, location: CGPoint(x: 500, y: 350), previousLocation: CGPoint(x: 500, y: 350), timestamp: 9.0)],
            viewSize: viewSize, screenRect: screenRect, tapsClick: true, now: 9.0
        )
        _ = direct.fireHoldTimer()
        let dragMove = direct.touchesMoved(
            [SillTouchSample(token: 33, location: CGPoint(x: 900, y: 350), previousLocation: CGPoint(x: 500, y: 350), timestamp: 9.45)],
            viewSize: viewSize, screenRect: screenRect, tapsClick: true, pointerSpeed: 1.0, scrollSpeed: 0.3, reverseScrolling: false, frameTimestamp: 9.45
        )
        expect(direct.directDragging && dragMove.actions == [.absolutePointer(x: 16384, y: 16384, buttons: 1), .absolutePointer(x: 32767, y: 16384, buttons: 1)],
               "Moving after long press presses left button at anchor and drags 1:1 to destination")
        let dragEnd = direct.touchesEnded([33], tapsClick: true, tsMs: 9600, now: 9.6)
        expect(!direct.directDragging && dragEnd.actions.contains(.absolutePointer(x: 32767, y: 16384, buttons: 0)),
               "Lifting direct drag releases left button at final position")

        // 1-finger swipe past slop without long press -> synthetic 2-finger Magic Trackpad 2 scroll + lift (never clicks).
        _ = direct.touchesBegan(
            [SillTouchSample(token: 34, location: CGPoint(x: 500, y: 350), previousLocation: CGPoint(x: 500, y: 350), timestamp: 10.0)],
            viewSize: viewSize, screenRect: screenRect, tapsClick: true, now: 10.0
        )
        let scrollSwipe = direct.touchesMoved(
            [SillTouchSample(token: 34, location: CGPoint(x: 500, y: 320), previousLocation: CGPoint(x: 500, y: 350), timestamp: 10.04)],
            viewSize: viewSize, screenRect: screenRect, tapsClick: true, pointerSpeed: 1.0, scrollSpeed: 0.3, reverseScrolling: false, frameTimestamp: 10.04
        )
        expect(direct.directScrolling
               && scrollSwipe.actions.contains(where: { if case .hidTouch(id: 9, phase: 0, x: _, y: _, tsMs: _) = $0 { return true }; return false })
               && scrollSwipe.actions.contains(where: { if case .hidTouch(id: 10, phase: 1, x: _, y: _, tsMs: _) = $0 { return true }; return false }),
               "1-finger swipe in direct mode drives smooth synthetic 2-finger Magic Trackpad 2 scrolling")
        let swipeUp = direct.touchesEnded([34], tapsClick: true, tsMs: 10200, now: 10.2)
        expect(!direct.directScrolling
               && swipeUp.actions.contains(.hidTouch(id: 9, phase: 2, x: 0, y: 0, tsMs: 10200))
               && swipeUp.actions.contains(.hidTouch(id: 10, phase: 2, x: 0, y: 0, tsMs: 10200))
               && !swipeUp.actions.contains(where: { if case .absolutePointer(_, _, buttons: 1) = $0 { return true }; return false }),
               "Ending swipe lifts synthetic scroll contacts cleanly without stray click")

        // 2-finger quick tap -> right-click at midpoint.
        _ = direct.touchesBegan(
            [
                SillTouchSample(token: 41, location: CGPoint(x: 100, y: 50), previousLocation: CGPoint(x: 100, y: 50), timestamp: 11.0),
                SillTouchSample(token: 42, location: CGPoint(x: 900, y: 650), previousLocation: CGPoint(x: 900, y: 650), timestamp: 11.0),
            ],
            viewSize: viewSize, screenRect: screenRect, tapsClick: true, now: 11.0
        )
        let twoTapDirect = direct.touchesEnded([41, 42], tapsClick: true, tsMs: 11120, now: 11.12)
        expect(twoTapDirect.actions.contains(.absolutePointer(x: 16384, y: 16384, buttons: 2)) && twoTapDirect.actions.contains(.absolutePointer(x: 16384, y: 16384, buttons: 0)),
               "2-finger tap in direct mode right-clicks at midpoint")

        // 5. SessionHUDPolicy hide, reveal, and 4-finger toggle rules.
        var hidden = false
        var kb: SessionHUDPolicy.KeyboardPresentation = .sill
        SessionHUDPolicy.hideControls(controlsHidden: &hidden, keyboard: &kb)
        expect(hidden && kb == .none, "Hiding controls dismisses active Sill keyboard")

        var revealHint = true
        SessionHUDPolicy.revealControls(controlsHidden: &hidden, showRevealHint: &revealHint)
        expect(!hidden && !revealHint, "Reveal shows HUD and clears the reveal hint banner")

        kb = .sill
        revealHint = true
        let hidByToggle = SessionHUDPolicy.toggleControls(controlsHidden: &hidden, keyboard: &kb, showRevealHint: &revealHint)
        expect(hidByToggle && kb == .none && !revealHint, "4-finger toggle hides visible HUD and dismisses keyboard")
        let shownByToggle = SessionHUDPolicy.toggleControls(controlsHidden: &hidden, keyboard: &kb, showRevealHint: &revealHint)
        expect(!shownByToggle && !hidden, "Second 4-finger toggle reveals hidden HUD")

        print("Sill controls: \(checks) checks passed")
    }
}
