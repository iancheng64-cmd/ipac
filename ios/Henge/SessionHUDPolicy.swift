import Foundation

/// Policy for floating capsule HUD visibility, 5-second auto-hide, and 4-finger quick tap toggles.
enum SessionHUDPolicy {
    static let autoHideDelay: TimeInterval = 5.0
    static let toastDuration: TimeInterval = 2.6

    enum KeyboardPresentation: Equatable {
        case none
        case sill
        case systemIME
    }

    static func shouldAutoHide(
        vmRunning: Bool,
        fillsPhone: Bool,
        controlsHidden: Bool,
        keyboard: KeyboardPresentation,
        showDetails: Bool,
        confirmStop: Bool
    ) -> Bool {
        vmRunning && fillsPhone && !controlsHidden && keyboard == .none && !showDetails && !confirmStop
    }

    /// Toggles HUD visibility and closes any open virtual keyboard when hiding the HUD.
    /// Returns the updated `controlsHidden` flag.
    @discardableResult
    static func onFourFingerTap(
        controlsHidden: inout Bool,
        keyboard: inout KeyboardPresentation
    ) -> Bool {
        controlsHidden.toggle()
        if controlsHidden {
            keyboard = .none
        }
        return controlsHidden
    }
}
