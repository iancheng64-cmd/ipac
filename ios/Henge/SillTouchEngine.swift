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

/// Platform-neutral state machine for Sill multi-finger Magic Trackpad 2 gestures,
/// Direct Touch Pointer gestures, and 4-finger quick-tap HUD toggling.
final class SillTouchEngine {
    static let sensorW: Int32 = 8134
    static let sensorH: Int32 = 5206
    static let holdDelay: TimeInterval = 0.40
    static let tapMaxDuration: TimeInterval = 0.30
    static let oneFingerTapTravel: CGFloat = 10.0
    static let twoFingerTapTravel: CGFloat = 16.0
    static let fourFingerMaxDuration: TimeInterval = 0.75
    static let fourFingerMaxTravel: CGFloat = 48.0

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
    private var fourFingerSuppressed = false
    private var moveRemX: CGFloat = 0
    private var moveRemY: CGFloat = 0
    private var scrollRemX: CGFloat = 0
    private var scrollRemY: CGFloat = 0

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

    static func ms(_ timestamp: TimeInterval) -> UInt32 {
        UInt32(truncatingIfNeeded: Int64((timestamp * 1000.0).rounded(.towardZero)))
    }

    func touchesBegan(
        _ samples: [SillTouchSample],
        viewSize: CGSize,
        tapsClick: Bool,
        now: TimeInterval
    ) -> (actions: [SillTouchAction], armHoldTimer: Bool, cancelHoldTimer: Bool) {
        guard !samples.isEmpty else { return ([], false, false) }
        var actions: [SillTouchAction] = []
        if fingers.isEmpty {
            gestureStart = now
            travelled = 0
            mostFingers = 0
            holdingDrag = false
            fourFingerSuppressed = false
            moveRemX = 0
            moveRemY = 0
            scrollRemX = 0
            scrollRemY = 0
        }

        for sample in samples {
            if fingers.contains(where: { $0.token == sample.token }) { continue }
            guard let id = freeIds.min() else { break }
            freeIds.remove(id)
            let sendHid = mode == .trackpad
            fingers.append(Finger(token: sample.token, id: id, lastPoint: sample.location, hidDown: sendHid))
            if sendHid {
                let pt = Self.sensorPoint(location: sample.location, in: viewSize)
                actions.append(.hidTouch(id: id, phase: 0, x: pt.x, y: pt.y, tsMs: Self.ms(sample.timestamp)))
            }
        }
        mostFingers = max(mostFingers, fingers.count)

        var cancelHold = false
        var armHold = false

        if fingers.count >= 4 {
            fourFingerSuppressed = true
            cancelHold = true
            if holdingDrag {
                holdingDrag = false
                actions.append(.mouseButton(button: 0, down: false))
            }
            return (actions, false, true)
        }

        if tapsClick {
            if fingers.count >= 2 {
                cancelHold = true
                if holdingDrag {
                    holdingDrag = false
                    actions.append(.mouseButton(button: 0, down: false))
                }
            } else if fingers.count == 1 && !fourFingerSuppressed {
                armHold = true
            }
        }
        return (actions, armHold, cancelHold)
    }

    func touchesMoved(
        _ samples: [SillTouchSample],
        viewSize: CGSize,
        tapsClick: Bool,
        pointerSpeed: Double,
        scrollSpeed: Double,
        reverseScrolling: Bool,
        frameTimestamp: TimeInterval
    ) -> (actions: [SillTouchAction], cancelHoldTimer: Bool) {
        guard !samples.isEmpty else { return ([], false) }
        var actions: [SillTouchAction] = []
        var hidMoved = false
        var moveDx: CGFloat = 0
        var moveDy: CGFloat = 0
        var scrollDxSum: CGFloat = 0
        var scrollDySum: CGFloat = 0
        var scrollMatches = 0

        for sample in samples {
            guard let idx = fingers.firstIndex(where: { $0.token == sample.token }) else { continue }
            let dx = sample.location.x - sample.previousLocation.x
            let dy = sample.location.y - sample.previousLocation.y
            travelled += abs(dx) + abs(dy)
            fingers[idx].lastPoint = sample.location

            if mode == .trackpad && fingers[idx].hidDown {
                let pt = Self.sensorPoint(location: sample.location, in: viewSize)
                actions.append(.hidTouch(id: fingers[idx].id, phase: 1, x: pt.x, y: pt.y, tsMs: Self.ms(frameTimestamp)))
                hidMoved = true
            } else if mode == .directPointer && !fourFingerSuppressed {
                if fingers.count == 1 {
                    moveDx += dx
                    moveDy += dy
                } else if fingers.count == 2 {
                    scrollDxSum += dx
                    scrollDySum += dy
                    scrollMatches += 1
                }
            }
        }

        let cancelHold = tapsClick && travelled >= Self.oneFingerTapTravel && !holdingDrag

        if hidMoved {
            actions.append(.hidTouchFrame(tsMs: Self.ms(frameTimestamp)))
        }

        if mode == .directPointer && !fourFingerSuppressed {
            if fingers.count == 1 && (moveDx != 0 || moveDy != 0) {
                let scale = CGFloat(max(0.25, pointerSpeed))
                moveRemX += moveDx * scale
                moveRemY += moveDy * scale
                let ix = moveRemX.rounded()
                let iy = moveRemY.rounded()
                if ix != 0 || iy != 0 {
                    moveRemX -= ix
                    moveRemY -= iy
                    actions.append(.mouseMove(dx: Int32(ix), dy: Int32(iy)))
                }
            } else if fingers.count == 2 && scrollMatches > 0 {
                let avgDx = scrollDxSum / CGFloat(scrollMatches)
                let avgDy = scrollDySum / CGFloat(scrollMatches)
                let way: CGFloat = reverseScrolling ? -1.0 : 1.0
                let factor = CGFloat(max(0.1, scrollSpeed)) * 0.55
                scrollRemX += avgDx * factor * way
                scrollRemY += avgDy * factor * way
                let sx = scrollRemX.rounded(.towardZero)
                let sy = scrollRemY.rounded(.towardZero)
                if sx != 0 || sy != 0 {
                    scrollRemX -= sx
                    scrollRemY -= sy
                    actions.append(.mouseScroll(dx: Int32(sx), dy: Int32(sy)))
                }
            }
        }

        return (actions, cancelHold)
    }

    func fireHoldTimer() -> [SillTouchAction] {
        guard !fourFingerSuppressed, !holdingDrag, fingers.count == 1, travelled < Self.oneFingerTapTravel else {
            return []
        }
        holdingDrag = true
        return [.mouseButton(button: 0, down: true), .hapticMedium]
    }

    func touchesEnded(
        _ tokens: [Int],
        tapsClick: Bool,
        tsMs: UInt32,
        now: TimeInterval
    ) -> (actions: [SillTouchAction], cancelHoldTimer: Bool) {
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
        guard removedAny else { return ([], false) }

        var actions: [SillTouchAction] = []
        for id in liftedIds {
            actions.append(.hidTouch(id: id, phase: 2, x: 0, y: 0, tsMs: tsMs))
        }

        guard fingers.isEmpty else {
            return (actions, false)
        }

        let duration = now - gestureStart

        if fourFingerSuppressed {
            if holdingDrag {
                holdingDrag = false
                actions.append(.mouseButton(button: 0, down: false))
            }
            if travelled < Self.fourFingerMaxTravel && duration < Self.fourFingerMaxDuration {
                actions.append(.hapticLight)
                actions.append(.toggleHud)
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
        } else if mostFingers >= 4 && travelled < Self.fourFingerMaxTravel && duration < Self.fourFingerMaxDuration {
            actions.append(.hapticLight)
            actions.append(.toggleHud)
        }

        actions.append(.releaseStickyKeys)

        fourFingerSuppressed = false
        mostFingers = 0
        travelled = 0
        moveRemX = 0
        moveRemY = 0
        scrollRemX = 0
        scrollRemY = 0
        return (actions, true)
    }

    func switchMode(to newMode: TrackpadTouchMode, tsMs: UInt32) -> (actions: [SillTouchAction], cancelHoldTimer: Bool) {
        guard mode != newMode else { return ([], false) }
        let cleanup = cancelAll(tsMs: tsMs)
        mode = newMode
        return cleanup
    }

    func cancelAll(tsMs: UInt32) -> (actions: [SillTouchAction], cancelHoldTimer: Bool) {
        var actions: [SillTouchAction] = []
        for finger in fingers {
            if finger.hidDown {
                actions.append(.hidTouch(id: finger.id, phase: 2, x: 0, y: 0, tsMs: tsMs))
            }
            freeIds.insert(finger.id)
        }
        fingers.removeAll()
        if holdingDrag {
            holdingDrag = false
            actions.append(.mouseButton(button: 0, down: false))
        }
        if !actions.isEmpty {
            actions.append(.releaseStickyKeys)
        }
        fourFingerSuppressed = false
        mostFingers = 0
        travelled = 0
        moveRemX = 0
        moveRemY = 0
        scrollRemX = 0
        scrollRemY = 0
        return (actions, true)
    }
}
