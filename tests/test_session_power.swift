@main
struct SessionPowerTests {
    static func main() {
        for shown: Int32 in 0...4 {
            precondition(SessionPowerAction.onTap(nativeState: 0, displayedState: shown) == .close)
            for live: Int32 in [1, 4] {
                precondition(SessionPowerAction.onTap(nativeState: live, displayedState: shown) == .confirm)
            }
            for live: Int32 in [3, 99] {
                precondition(SessionPowerAction.onTap(nativeState: live, displayedState: shown) == .wait)
            }
            precondition(SessionPowerAction.onTap(nativeState: 2, displayedState: shown) == (shown == 2 ? .close : .wait))
        }
        print("Session power actions: all state combinations passed")
    }
}
