import Foundation

/// Policy for floating capsule HUD visibility and 4-finger toggle gestures.
enum SessionHUDPolicy {
    enum KeyboardPresentation: Equatable {
        case none
        case sill
        case systemIME
    }

    /// Hides the HUD and dismisses any active virtual keyboard cleanly.
    static func hideControls(
        controlsHidden: inout Bool,
        keyboard: inout KeyboardPresentation
    ) {
        controlsHidden = true
        keyboard = .none
    }

    /// Reveals the HUD from a reveal gesture and clears the one-shot hint banner.
    static func revealControls(
        controlsHidden: inout Bool,
        showRevealHint: inout Bool
    ) {
        controlsHidden = false
        showRevealHint = false
    }

    /// Toggles HUD visibility (4-finger tap or 4-finger long press), dismissing any active virtual keyboard when hiding.
    /// Returns the updated `controlsHidden` flag.
    @discardableResult
    static func toggleControls(
        controlsHidden: inout Bool,
        keyboard: inout KeyboardPresentation,
        showRevealHint: inout Bool
    ) -> Bool {
        controlsHidden.toggle()
        showRevealHint = false
        if controlsHidden {
            keyboard = .none
        }
        return controlsHidden
    }
}
