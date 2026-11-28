import Foundation

/// Policy for floating capsule HUD visibility and 4-finger reveal gesture.
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

    /// Reveals the HUD from the 4-finger tap gesture and clears the one-shot hint banner.
    static func revealControls(
        controlsHidden: inout Bool,
        showRevealHint: inout Bool
    ) {
        controlsHidden = false
        showRevealHint = false
    }
}
