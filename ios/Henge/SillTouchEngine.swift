import Foundation
import CoreGraphics

enum TrackpadTouchMode: String, CaseIterable, Identifiable {
    case trackpad
    case directPointer

    static let storageKey = "henge.trackpad.sillTouchMode"
    var id: String { rawValue }

    static func read(from defaults: UserDefaults = .standard) -> TrackpadTouchMode {
        defaults.string(forKey: storageKey).flatMap(TrackpadTouchMode.init(rawValue:)) ?? .trackpad
    }

    func save(to defaults: UserDefaults = .standard) {
        defaults.set(rawValue, forKey: Self.storageKey)
    }
}

enum SillTouchAction: Equatable {
    case hidTouch(id: Int32, phase: Int32, x: Int32, y: Int32, tsMs: UInt32)
    case hidTouchFrame(tsMs: UInt32)
    case mouseMove(dx: Int32, dy: Int32)
    case mouseButton(button: Int32, down: Bool)
    case mouseScroll(dx: Int32, dy: Int32)
    case absolutePointer(x: Int32, y: Int32, buttons: Int32)
    case absoluteCancel
    case hapticLight
    case hapticMedium
    case toggleHud
    case releaseStickyKeys
}

struct SillTouchSample {
    let token: Int
    let location: CGPoint
    let previousLocation: CGPoint
    let timestamp: TimeInterval
}

/// Platform-neutral state machine for:
/// - Trackpad mode: Magic Trackpad 2 HID multi-touch, tap/right-tap/hold-drag, and Mac-native 3-finger drag.
/// - Direct Touch Pointer mode (Sill full-screen style): pixel-accurate Port 3 USB absolute pointer
///   (tap left-click, long-press right-click, long-press + move 1:1 drag, 1/2-finger swipe scroll, 2-finger tap right-click).
/// - Both modes: 4-finger quick tap OR 4-finger long press cleanly toggles the floating HUD capsule.
final class SillTouchEngine {
    static let sensorW: Int32 = 8134
    static let sensorH: Int32 = 5206
    static let holdDelay: TimeInterval = 0.40
    static let fourFingerHoldDelay: TimeInterval = 0.45
    static let tapMaxDuration: TimeInterval = 0.30
    static let oneFingerTapTravel: CGFloat = 10.0
    static let twoFingerTapTravel: CGFloat = 16.0
    static let fourFingerMaxDuration: TimeInterval = 0.75
    static let fourFingerMaxTravel: CGFloat = 64.0
    static let threeFingerDragSlop: CGFloat = 5.0
    static let directScrollSlop: CGFloat = 12.0

    struct Finger {
        let token: Int
        let id: Int32
        var lastPoint: CGPoint
        var hidDown: Bool
    }

    private(set) var mode: TrackpadTouchMode
    private var fingers: [Finger] = []
    private var freeIds = Set<Int32>(1...5)
    private var gestureStart: TimeInterval = 0
    private var travelled: CGFloat = 0
    private var mostFingers = 0
    private(set) var holdingDrag = false
    private(set) var threeFingerTracking = false
    private(set) var threeFingerDragActive = false
    private var threeFingerTravel: CGFloat = 0
    private var fourFingerSuppressed = false
    private(set) var fourFingerHoldFired = false

    private var directAnchorAbs: (x: Int32, y: Int32) = (0, 0)
    private var directLastAbs: (x: Int32, y: Int32) = (0, 0)
    private(set) var directHeld = false
    private(set) var directDragging = false
    private var directMovedPastSlop = false
    private(set) var directScrolling = false
    private var wheelX: CGFloat = 0.5
    private var wheelY: CGFloat = 0.5

    private var moveRemX: CGFloat = 0
    private var moveRemY: CGFloat = 0

    init(mode: TrackpadTouchMode = .trackpad) {
        self.mode = mode
    }

    var activeFingerCount: Int { fingers.count }

    /// Uniformly maps view points onto the Magic Trackpad 2 sensor centered in bounds.
    static func sensorPoint(location p: CGPoint, in size: CGSize) -> (x: Int32, y: Int32) {
        let w = max(Double(size.width), 1.0)
        let h = max(Double(size.height), 1.0)
        let scale = min(Double(sensorW) / w, Double(sensorH) / h)
        let x = (Double(p.x) - w / 2.0) * scale + Double(sensorW) / 2.0
        let y = (Double(p.y) - h / 2.0) * scale + Double(sensorH) / 2.0
        return (
            Int32(min(max(x, 0.0), Double(sensorW))),
            Int32(min(max(y, 0.0), Double(sensorH)))
        )
    }

    /// Maps a point in view coordinates into 0...32767 absolute pointer coordinates within `screenRect`.
    static func absolutePoint(location p: CGPoint, in screenRect: CGRect, fallbackSize: CGSize) -> (x: Int32, y: Int32) {
        let rect: CGRect
        if screenRect.width > 1.0 && screenRect.height > 1.0 {
            rect = screenRect
        } else {
            rect = CGRect(
                origin: .zero,
                size: CGSize(width: max(fallbackSize.width, 1.0), height: max(fallbackSize.height, 1.0))
            )
        }
        let nx = min(max((p.x - rect.minX) / rect.width, 0.0), 1.0)
        let ny = min(max((p.y - rect.minY) / rect.height, 0.0), 1.0)
        return (
            Int32((nx * 32767.0).rounded()),
            Int32((ny * 32767.0).rounded())
        )
    }

    static func ms(_ timestamp: TimeInterval) -> UInt32 {
        UInt32(truncatingIfNeeded: Int64((timestamp * 1000.0).rounded(.towardZero)))
    }

    func touchesBegan(
        _ samples: [SillTouchSample],
        viewSize: CGSize,
        screenRect: CGRect = .zero,
        tapsClick: Bool,
        now: TimeInterval
    ) -> (
        actions: [SillTouchAction],
        armHoldTimer: Bool,
        cancelHoldTimer: Bool,
        armFourFingerHoldTimer: Bool,
        cancelFourFingerHoldTimer: Bool
    ) {
        guard !samples.isEmpty else { return ([], false, false, false, false) }
        var actions: [SillTouchAction] = []
        if fingers.isEmpty {
            resetGestureState(now: now)
        }

        let uniqueNew = samples.filter { s in !fingers.contains(where: { $0.token == s.token }) }
        let projectedCount = min(fingers.count + uniqueNew.count, 5)
        let enteringFour = projectedCount >= 4
        let enteringThreeTrackpad = (mode == .trackpad && projectedCount == 3 && !fourFingerSuppressed)
        let emitHidDown = (mode == .trackpad && !enteringFour && !enteringThreeTrackpad && !fourFingerSuppressed && !threeFingerTracking)

        for sample in uniqueNew {
            guard let id = freeIds.min() else { break }
            freeIds.remove(id)
            fingers.append(Finger(token: sample.token, id: id, lastPoint: sample.location, hidDown: emitHidDown))
            if emitHidDown {
                let pt = Self.sensorPoint(location: sample.location, in: viewSize)
                actions.append(.hidTouch(id: id, phase: 0, x: pt.x, y: pt.y, tsMs: Self.ms(sample.timestamp)))
            }
        }
        mostFingers = max(mostFingers, fingers.count)

        let ts = Self.ms(samples[0].timestamp)
        var armHold = false
        var cancelHold = false
        var armFourHold = false
        let cancelFourHold = false

        if fingers.count >= 4 {
            fourFingerSuppressed = true
            cancelHold = true
            liftActiveHidContacts(tsMs: ts, actions: &actions)
            finishSyntheticScroll(tsMs: ts, actions: &actions)
            releaseActiveDrags(at: directLastAbs, actions: &actions)
            if !fourFingerHoldFired {
                armFourHold = true
            }
            return (actions, false, cancelHold, armFourHold, cancelFourHold)
        }

        if mode == .trackpad {
            if fingers.count == 3 && !fourFingerSuppressed {
                cancelHold = true
                if holdingDrag {
                    holdingDrag = false
                    actions.append(.mouseButton(button: 0, down: false))
                }
                if !threeFingerTracking {
                    threeFingerTracking = true
                    threeFingerDragActive = false
                    threeFingerTravel = 0
                }
                liftActiveHidContacts(tsMs: ts, actions: &actions)
            } else if tapsClick && !threeFingerTracking && !fourFingerSuppressed {
                if fingers.count >= 2 {
                    cancelHold = true
                    if holdingDrag {
                        holdingDrag = false
                        actions.append(.mouseButton(button: 0, down: false))
                    }
                } else if fingers.count == 1 {
                    armHold = true
                }
            }
        } else if !fourFingerSuppressed {
            if fingers.count == 1 {
                let absPt = Self.absolutePoint(location: fingers[0].lastPoint, in: screenRect, fallbackSize: viewSize)
                directAnchorAbs = absPt
                directLastAbs = absPt
                actions.append(.absolutePointer(x: absPt.x, y: absPt.y, buttons: 0))
                armHold = true
            } else if fingers.count >= 2 {
                cancelHold = true
                finishSyntheticScroll(tsMs: ts, actions: &actions)
                if directDragging {
                    directDragging = false
                    actions.append(.absolutePointer(x: directLastAbs.x, y: directLastAbs.y, buttons: 0))
                }
                directHeld = false
                if fingers.count == 2 {
                    let mid = CGPoint(
                        x: (fingers[0].lastPoint.x + fingers[1].lastPoint.x) * 0.5,
                        y: (fingers[0].lastPoint.y + fingers[1].lastPoint.y) * 0.5
                    )
                    directLastAbs = Self.absolutePoint(location: mid, in: screenRect, fallbackSize: viewSize)
                }
            }
        }

        return (actions, armHold, cancelHold, armFourHold, cancelFourHold)
    }

    func touchesMoved(
        _ samples: [SillTouchSample],
        viewSize: CGSize,
        screenRect: CGRect = .zero,
        tapsClick: Bool,
        pointerSpeed: Double,
        scrollSpeed: Double,
        reverseScrolling: Bool,
        frameTimestamp: TimeInterval
    ) -> (
        actions: [SillTouchAction],
        cancelHoldTimer: Bool,
        cancelFourFingerHoldTimer: Bool
    ) {
        guard !samples.isEmpty else { return ([], false, false) }
        var actions: [SillTouchAction] = []
        let tsMs = Self.ms(frameTimestamp)
        var hidMoved = false
        var moveDxSum: CGFloat = 0
        var moveDySum: CGFloat = 0
        var matchedCount = 0

        for sample in samples {
            guard let idx = fingers.firstIndex(where: { $0.token == sample.token }) else { continue }
            let dx = sample.location.x - sample.previousLocation.x
            let dy = sample.location.y - sample.previousLocation.y
            travelled += abs(dx) + abs(dy)
            fingers[idx].lastPoint = sample.location
            moveDxSum += dx
            moveDySum += dy
            matchedCount += 1

            if mode == .trackpad && fingers[idx].hidDown && !fourFingerSuppressed && !threeFingerTracking {
                let pt = Self.sensorPoint(location: sample.location, in: viewSize)
                actions.append(.hidTouch(id: fingers[idx].id, phase: 1, x: pt.x, y: pt.y, tsMs: tsMs))
                hidMoved = true
            }
        }

        if hidMoved {
            actions.append(.hidTouchFrame(tsMs: tsMs))
        }

        let cancelFourHold = fourFingerSuppressed && !fourFingerHoldFired && travelled >= Self.fourFingerMaxTravel

        if fourFingerSuppressed {
            return (actions, true, cancelFourHold)
        }

        if mode == .trackpad {
            let cancelHold = tapsClick && travelled >= Self.oneFingerTapTravel && !holdingDrag
            if threeFingerTracking && matchedCount > 0 {
                let avgDx = moveDxSum / CGFloat(matchedCount)
                let avgDy = moveDySum / CGFloat(matchedCount)
                threeFingerTravel += abs(avgDx) + abs(avgDy)
                if !threeFingerDragActive && threeFingerTravel >= Self.threeFingerDragSlop {
                    threeFingerDragActive = true
                    actions.append(.mouseButton(button: 0, down: true))
                    actions.append(.hapticLight)
                }
                if threeFingerDragActive {
                    let scale = CGFloat(max(0.25, pointerSpeed) * 1.35)
                    moveRemX += avgDx * scale
                    moveRemY += avgDy * scale
                    let ix = moveRemX.rounded()
                    let iy = moveRemY.rounded()
                    if ix != 0 || iy != 0 {
                        moveRemX -= ix
                        moveRemY -= iy
                        actions.append(.mouseMove(dx: Int32(ix), dy: Int32(iy)))
                    }
                }
            }
            return (actions, cancelHold, false)
        }

        // Direct Touch Pointer mode (Sill full-screen direct touch interaction).
        if !directMovedPastSlop && travelled >= Self.directScrollSlop {
            directMovedPastSlop = true
        }
        let cancelHold = !directHeld && travelled >= Self.directScrollSlop

        if fingers.count == 1 && mostFingers == 1 {
            let pt = fingers[0].lastPoint
            let absPt = Self.absolutePoint(location: pt, in: screenRect, fallbackSize: viewSize)
            directLastAbs = absPt
            if directHeld {
                if !directDragging {
                    directDragging = true
                    actions.append(.absolutePointer(x: directAnchorAbs.x, y: directAnchorAbs.y, buttons: 1))
                }
                actions.append(.absolutePointer(x: absPt.x, y: absPt.y, buttons: 1))
            } else if directMovedPastSlop, matchedCount > 0 {
                appendSyntheticScrollMove(
                    dx: moveDxSum / CGFloat(matchedCount),
                    dy: moveDySum / CGFloat(matchedCount),
                    scrollSpeed: scrollSpeed,
                    reverseScrolling: reverseScrolling,
                    tsMs: tsMs,
                    viewSize: viewSize,
                    actions: &actions
                )
            }
        } else if fingers.count == 2 && matchedCount > 0 {
            let mid = CGPoint(
                x: (fingers[0].lastPoint.x + fingers[1].lastPoint.x) * 0.5,
                y: (fingers[0].lastPoint.y + fingers[1].lastPoint.y) * 0.5
            )
            directLastAbs = Self.absolutePoint(location: mid, in: screenRect, fallbackSize: viewSize)
            if directMovedPastSlop {
                appendSyntheticScrollMove(
                    dx: moveDxSum / CGFloat(matchedCount),
                    dy: moveDySum / CGFloat(matchedCount),
                    scrollSpeed: scrollSpeed,
                    reverseScrolling: reverseScrolling,
                    tsMs: tsMs,
                    viewSize: viewSize,
                    actions: &actions
                )
            }
        }

        return (actions, cancelHold, false)
    }

    func fireHoldTimer() -> [SillTouchAction] {
        guard !fourFingerSuppressed, !threeFingerTracking, fingers.count == 1 else {
            return []
        }
        if mode == .directPointer {
            guard !directHeld, !directMovedPastSlop, travelled < Self.directScrollSlop else {
                return []
            }
            directHeld = true
            return [.hapticMedium]
        }
        guard !holdingDrag, travelled < Self.oneFingerTapTravel else {
            return []
        }
        holdingDrag = true
        return [.mouseButton(button: 0, down: true), .hapticMedium]
    }

    func fireFourFingerHoldTimer() -> [SillTouchAction] {
        guard fourFingerSuppressed, !fourFingerHoldFired, fingers.count >= 4, travelled < Self.fourFingerMaxTravel else {
            return []
        }
        fourFingerHoldFired = true
        return [.hapticMedium, .toggleHud]
    }

    func touchesEnded(
        _ tokens: [Int],
        tapsClick: Bool,
        tsMs: UInt32,
        now: TimeInterval
    ) -> (
        actions: [SillTouchAction],
        cancelHoldTimer: Bool,
        cancelFourFingerHoldTimer: Bool
    ) {
        let tokenSet = Set(tokens)
        var liftedIds: [Int32] = []
        var removedAny = false
        fingers.removeAll { finger in
            guard tokenSet.contains(finger.token) else { return false }
            removedAny = true
            freeIds.insert(finger.id)
            if finger.hidDown {
                liftedIds.append(finger.id)
            }
            return true
        }
        guard removedAny else { return ([], false, false) }

        var actions: [SillTouchAction] = []
        for id in liftedIds {
            actions.append(.hidTouch(id: id, phase: 2, x: 0, y: 0, tsMs: tsMs))
        }

        guard fingers.isEmpty else {
            let cancelFourHold = fourFingerSuppressed && fingers.count < 4
            return (actions, false, cancelFourHold)
        }

        let duration = now - gestureStart
        finishSyntheticScroll(tsMs: tsMs, actions: &actions)

        if fourFingerSuppressed {
            releaseActiveDrags(at: directLastAbs, actions: &actions)
            if !fourFingerHoldFired && travelled < Self.fourFingerMaxTravel && duration < Self.fourFingerMaxDuration {
                actions.append(.hapticLight)
                actions.append(.toggleHud)
            }
        } else if mode == .trackpad {
            if threeFingerTracking {
                if threeFingerDragActive {
                    threeFingerDragActive = false
                    actions.append(.mouseButton(button: 0, down: false))
                }
            } else if tapsClick {
                if holdingDrag {
                    holdingDrag = false
                    actions.append(.mouseButton(button: 0, down: false))
                } else if duration < Self.tapMaxDuration {
                    if mostFingers == 1 && travelled < Self.oneFingerTapTravel {
                        actions.append(.mouseButton(button: 0, down: true))
                        actions.append(.mouseButton(button: 0, down: false))
                        actions.append(.hapticLight)
                    } else if mostFingers == 2 && travelled < Self.twoFingerTapTravel {
                        actions.append(.mouseButton(button: 1, down: true))
                        actions.append(.mouseButton(button: 1, down: false))
                        actions.append(.hapticLight)
                    }
                }
            }
        } else {
            // Direct Touch Pointer completion.
            if directHeld {
                if directDragging {
                    directDragging = false
                    actions.append(.absolutePointer(x: directLastAbs.x, y: directLastAbs.y, buttons: 0))
                } else {
                    actions.append(.absolutePointer(x: directAnchorAbs.x, y: directAnchorAbs.y, buttons: 2))
                    actions.append(.absolutePointer(x: directAnchorAbs.x, y: directAnchorAbs.y, buttons: 0))
                }
            } else if !directMovedPastSlop && duration < Self.tapMaxDuration {
                if mostFingers == 1 {
                    actions.append(.absolutePointer(x: directLastAbs.x, y: directLastAbs.y, buttons: 1))
                    actions.append(.absolutePointer(x: directLastAbs.x, y: directLastAbs.y, buttons: 0))
                    actions.append(.hapticLight)
                } else if mostFingers == 2 && travelled < Self.twoFingerTapTravel {
                    actions.append(.absolutePointer(x: directLastAbs.x, y: directLastAbs.y, buttons: 2))
                    actions.append(.absolutePointer(x: directLastAbs.x, y: directLastAbs.y, buttons: 0))
                    actions.append(.hapticLight)
                }
            }
        }

        actions.append(.releaseStickyKeys)
        resetGestureState(now: now)
        return (actions, true, true)
    }

    func switchMode(to newMode: TrackpadTouchMode, tsMs: UInt32) -> (
        actions: [SillTouchAction],
        cancelHoldTimer: Bool,
        cancelFourFingerHoldTimer: Bool
    ) {
        guard mode != newMode else { return ([], false, false) }
        let cleanup = cancelAll(tsMs: tsMs)
        mode = newMode
        return cleanup
    }

    func cancelAll(tsMs: UInt32) -> (
        actions: [SillTouchAction],
        cancelHoldTimer: Bool,
        cancelFourFingerHoldTimer: Bool
    ) {
        var actions: [SillTouchAction] = []
        for finger in fingers {
            if finger.hidDown {
                actions.append(.hidTouch(id: finger.id, phase: 2, x: 0, y: 0, tsMs: tsMs))
            }
            freeIds.insert(finger.id)
        }
        fingers.removeAll()
        finishSyntheticScroll(tsMs: tsMs, actions: &actions)
        if directDragging {
            directDragging = false
            actions.append(.absoluteCancel)
        }
        releaseActiveDrags(at: directLastAbs, actions: &actions)
        if !actions.isEmpty {
            actions.append(.releaseStickyKeys)
        }
        resetGestureState(now: 0)
        return (actions, true, true)
    }

    private func resetGestureState(now: TimeInterval) {
        gestureStart = now
        travelled = 0
        mostFingers = 0
        holdingDrag = false
        threeFingerTracking = false
        threeFingerDragActive = false
        threeFingerTravel = 0
        fourFingerSuppressed = false
        fourFingerHoldFired = false
        directHeld = false
        directDragging = false
        directMovedPastSlop = false
        directScrolling = false
        wheelX = 0.5
        wheelY = 0.5
        moveRemX = 0
        moveRemY = 0
    }

    private func liftActiveHidContacts(tsMs: UInt32, actions: inout [SillTouchAction]) {
        for idx in fingers.indices where fingers[idx].hidDown {
            fingers[idx].hidDown = false
            actions.append(.hidTouch(id: fingers[idx].id, phase: 2, x: 0, y: 0, tsMs: tsMs))
        }
    }

    private func finishSyntheticScroll(tsMs: UInt32, actions: inout [SillTouchAction]) {
        guard directScrolling else { return }
        directScrolling = false
        actions.append(.hidTouch(id: 9, phase: 2, x: 0, y: 0, tsMs: tsMs))
        actions.append(.hidTouch(id: 10, phase: 2, x: 0, y: 0, tsMs: tsMs))
    }

    private func releaseActiveDrags(at pt: (x: Int32, y: Int32), actions: inout [SillTouchAction]) {
        if holdingDrag {
            holdingDrag = false
            actions.append(.mouseButton(button: 0, down: false))
        }
        if threeFingerDragActive {
            threeFingerDragActive = false
            actions.append(.mouseButton(button: 0, down: false))
        }
        threeFingerTracking = false
        if directDragging {
            directDragging = false
            actions.append(.absolutePointer(x: pt.x, y: pt.y, buttons: 0))
        }
        directHeld = false
    }

    private func appendSyntheticScrollMove(
        dx: CGFloat,
        dy: CGFloat,
        scrollSpeed: Double,
        reverseScrolling: Bool,
        tsMs: UInt32,
        viewSize: CGSize,
        actions: inout [SillTouchAction]
    ) {
        guard dx != 0 || dy != 0 else { return }
        let w = max(viewSize.width, 1)
        let h = max(viewSize.height, 1)
        let scale = min(CGFloat(Self.sensorW) / w, CGFloat(Self.sensorH) / h)
        let speed = CGFloat(min(max(scrollSpeed / 0.3, 0.5), 2.5))
        let way: CGFloat = reverseScrolling ? -1.0 : 1.0
        let sdx = dx * speed * way
        let sdy = dy * speed * way
        if !directScrolling {
            directScrolling = true
            wheelX = 0.5
            wheelY = 0.5
            let lx = Int32(((wheelX - 0.045) * CGFloat(Self.sensorW)).rounded())
            let rx = Int32(((wheelX + 0.045) * CGFloat(Self.sensorW)).rounded())
            let cy = Int32((wheelY * CGFloat(Self.sensorH)).rounded())
            let startTs = Self.ms(gestureStart)
            actions.append(.hidTouch(id: 9, phase: 0, x: lx, y: cy, tsMs: startTs))
            actions.append(.hidTouch(id: 10, phase: 0, x: rx, y: cy, tsMs: startTs))
        }
        wheelX = min(max(wheelX + (sdx * scale) / CGFloat(Self.sensorW), 0.055), 0.945)
        wheelY = min(max(wheelY + (sdy * scale) / CGFloat(Self.sensorH), 0.01), 0.99)
        let lx = Int32(((wheelX - 0.045) * CGFloat(Self.sensorW)).rounded())
        let rx = Int32(((wheelX + 0.045) * CGFloat(Self.sensorW)).rounded())
        let cy = Int32((wheelY * CGFloat(Self.sensorH)).rounded())
        actions.append(.hidTouch(id: 9, phase: 1, x: lx, y: cy, tsMs: tsMs))
        actions.append(.hidTouch(id: 10, phase: 1, x: rx, y: cy, tsMs: tsMs))
        actions.append(.hidTouchFrame(tsMs: tsMs))
    }
}
