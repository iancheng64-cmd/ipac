enum SessionPowerAction {
    case confirm, wait, close

    static func onTap(nativeState: Int32, displayedState: Int32) -> Self {
        switch nativeState {
        case 0: return .close
        case 1, 4: return .confirm
        case 2: return displayedState == 2 ? .close : .wait
        default: return .wait
        }
    }
}
