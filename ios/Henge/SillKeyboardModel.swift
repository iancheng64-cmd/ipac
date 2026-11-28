import Foundation

/// Linux input key codes consumed by `henge_vm_key` / `hv_xhci_key_linux`.
enum SillLinuxKey {
    static let esc: UInt16 = 1
    static let one: UInt16 = 2
    static let two: UInt16 = 3
    static let three: UInt16 = 4
    static let four: UInt16 = 5
    static let five: UInt16 = 6
    static let six: UInt16 = 7
    static let seven: UInt16 = 8
    static let eight: UInt16 = 9
    static let nine: UInt16 = 10
    static let zero: UInt16 = 11
    static let minus: UInt16 = 12
    static let equal: UInt16 = 13
    static let backspace: UInt16 = 14
    static let tab: UInt16 = 15

    static let q: UInt16 = 16
    static let w: UInt16 = 17
    static let e: UInt16 = 18
    static let r: UInt16 = 19
    static let t: UInt16 = 20
    static let y: UInt16 = 21
    static let u: UInt16 = 22
    static let i: UInt16 = 23
    static let o: UInt16 = 24
    static let p: UInt16 = 25
    static let leftBracket: UInt16 = 26
    static let rightBracket: UInt16 = 27
    static let enter: UInt16 = 28
    static let leftCtrl: UInt16 = 29

    static let a: UInt16 = 30
    static let s: UInt16 = 31
    static let d: UInt16 = 32
    static let f: UInt16 = 33
    static let g: UInt16 = 34
    static let h: UInt16 = 35
    static let j: UInt16 = 36
    static let k: UInt16 = 37
    static let l: UInt16 = 38
    static let semicolon: UInt16 = 39
    static let apostrophe: UInt16 = 40
    static let grave: UInt16 = 41
    static let leftShift: UInt16 = 42
    static let backslash: UInt16 = 43

    static let z: UInt16 = 44
    static let x: UInt16 = 45
    static let c: UInt16 = 46
    static let v: UInt16 = 47
    static let b: UInt16 = 48
    static let n: UInt16 = 49
    static let m: UInt16 = 50
    static let comma: UInt16 = 51
    static let dot: UInt16 = 52
    static let slash: UInt16 = 53
    static let rightShift: UInt16 = 54
    static let leftOpt: UInt16 = 56
    static let space: UInt16 = 57
    static let capsLock: UInt16 = 58
    static let rightOpt: UInt16 = 100

    static let up: UInt16 = 103
    static let left: UInt16 = 105
    static let right: UInt16 = 106
    static let down: UInt16 = 108

    static let leftCmd: UInt16 = 125
    static let rightCmd: UInt16 = 126
}

enum SillKeyKind: Equatable {
    case standard
    case function
    case modifier
    case capsLock
    case accent
}

struct SillKeySpec: Identifiable, Equatable {
    let id: String
    let label: String
    let shiftedLabel: String?
    let code: UInt16
    let weight: Double
    let kind: SillKeyKind

    var isLetter: Bool {
        label.count == 1 && label.unicodeScalars.first.map { CharacterSet.letters.contains($0) } == true
    }

    init(id: String? = nil, _ label: String, shifted: String? = nil, code: UInt16, weight: Double = 1.0, kind: SillKeyKind = .standard) {
        self.id = id ?? "\(code)-\(label)"
        self.label = label
        self.shiftedLabel = shifted
        self.code = code
        self.weight = weight
        self.kind = kind
    }
}

struct SillShortcutSpec: Identifiable, Equatable {
    let id: String
    let label: String
    let codes: [UInt16]
}

enum SillKeyboardLayout {
    static let shortcuts: [SillShortcutSpec] = [
        SillShortcutSpec(id: "esc", label: "Esc", codes: [SillLinuxKey.esc]),
        SillShortcutSpec(id: "spotlight", label: "Spotlight", codes: [SillLinuxKey.leftCmd, SillLinuxKey.space]),
        SillShortcutSpec(id: "mission", label: "Mission", codes: [SillLinuxKey.leftCtrl, SillLinuxKey.up]),
        SillShortcutSpec(id: "prev-space", label: "◂ Space", codes: [SillLinuxKey.leftCtrl, SillLinuxKey.left]),
        SillShortcutSpec(id: "next-space", label: "Space ▸", codes: [SillLinuxKey.leftCtrl, SillLinuxKey.right]),
        SillShortcutSpec(id: "copy", label: "⌘C", codes: [SillLinuxKey.leftCmd, SillLinuxKey.c]),
        SillShortcutSpec(id: "paste", label: "⌘V", codes: [SillLinuxKey.leftCmd, SillLinuxKey.v]),
        SillShortcutSpec(id: "undo", label: "⌘Z", codes: [SillLinuxKey.leftCmd, SillLinuxKey.z]),
        SillShortcutSpec(id: "close", label: "⌘W", codes: [SillLinuxKey.leftCmd, SillLinuxKey.w]),
        SillShortcutSpec(id: "quit", label: "⌘Q", codes: [SillLinuxKey.leftCmd, SillLinuxKey.q]),
    ]

    static let rows: [[SillKeySpec]] = [
        [
            SillKeySpec("`", shifted: "~", code: SillLinuxKey.grave),
            SillKeySpec("1", shifted: "!", code: SillLinuxKey.one),
            SillKeySpec("2", shifted: "@", code: SillLinuxKey.two),
            SillKeySpec("3", shifted: "#", code: SillLinuxKey.three),
            SillKeySpec("4", shifted: "$", code: SillLinuxKey.four),
            SillKeySpec("5", shifted: "%", code: SillLinuxKey.five),
            SillKeySpec("6", shifted: "^", code: SillLinuxKey.six),
            SillKeySpec("7", shifted: "&", code: SillLinuxKey.seven),
            SillKeySpec("8", shifted: "*", code: SillLinuxKey.eight),
            SillKeySpec("9", shifted: "(", code: SillLinuxKey.nine),
            SillKeySpec("0", shifted: ")", code: SillLinuxKey.zero),
            SillKeySpec("-", shifted: "_", code: SillLinuxKey.minus),
            SillKeySpec("=", shifted: "+", code: SillLinuxKey.equal),
            SillKeySpec("⌫", code: SillLinuxKey.backspace, weight: 1.55, kind: .function),
        ],
        [
            SillKeySpec("⇥", code: SillLinuxKey.tab, weight: 1.45, kind: .function),
            SillKeySpec("q", code: SillLinuxKey.q),
            SillKeySpec("w", code: SillLinuxKey.w),
            SillKeySpec("e", code: SillLinuxKey.e),
            SillKeySpec("r", code: SillLinuxKey.r),
            SillKeySpec("t", code: SillLinuxKey.t),
            SillKeySpec("y", code: SillLinuxKey.y),
            SillKeySpec("u", code: SillLinuxKey.u),
            SillKeySpec("i", code: SillLinuxKey.i),
            SillKeySpec("o", code: SillLinuxKey.o),
            SillKeySpec("p", code: SillLinuxKey.p),
            SillKeySpec("[", shifted: "{", code: SillLinuxKey.leftBracket),
            SillKeySpec("]", shifted: "}", code: SillLinuxKey.rightBracket),
            SillKeySpec("\\", shifted: "|", code: SillLinuxKey.backslash, weight: 1.15),
        ],
        [
            SillKeySpec("⇪", code: SillLinuxKey.capsLock, weight: 1.70, kind: .capsLock),
            SillKeySpec("a", code: SillLinuxKey.a),
            SillKeySpec("s", code: SillLinuxKey.s),
            SillKeySpec("d", code: SillLinuxKey.d),
            SillKeySpec("f", code: SillLinuxKey.f),
            SillKeySpec("g", code: SillLinuxKey.g),
            SillKeySpec("h", code: SillLinuxKey.h),
            SillKeySpec("j", code: SillLinuxKey.j),
            SillKeySpec("k", code: SillLinuxKey.k),
            SillKeySpec("l", code: SillLinuxKey.l),
            SillKeySpec(";", shifted: ":", code: SillLinuxKey.semicolon),
            SillKeySpec("'", shifted: "\"", code: SillLinuxKey.apostrophe),
            SillKeySpec("⏎", code: SillLinuxKey.enter, weight: 1.80, kind: .accent),
        ],
        [
            SillKeySpec(id: "lshift", "⇧", code: SillLinuxKey.leftShift, weight: 2.15, kind: .modifier),
            SillKeySpec("z", code: SillLinuxKey.z),
            SillKeySpec("x", code: SillLinuxKey.x),
            SillKeySpec("c", code: SillLinuxKey.c),
            SillKeySpec("v", code: SillLinuxKey.v),
            SillKeySpec("b", code: SillLinuxKey.b),
            SillKeySpec("n", code: SillLinuxKey.n),
            SillKeySpec("m", code: SillLinuxKey.m),
            SillKeySpec(",", shifted: "<", code: SillLinuxKey.comma),
            SillKeySpec(".", shifted: ">", code: SillLinuxKey.dot),
            SillKeySpec("/", shifted: "?", code: SillLinuxKey.slash),
            SillKeySpec(id: "rshift", "⇧", code: SillLinuxKey.rightShift, weight: 2.15, kind: .modifier),
        ],
        [
            SillKeySpec(id: "lctrl", "⌃", code: SillLinuxKey.leftCtrl, weight: 1.15, kind: .modifier),
            SillKeySpec(id: "lopt", "⌥", code: SillLinuxKey.leftOpt, weight: 1.15, kind: .modifier),
            SillKeySpec(id: "lcmd", "⌘", code: SillLinuxKey.leftCmd, weight: 1.35, kind: .modifier),
            SillKeySpec("Space", code: SillLinuxKey.space, weight: 5.20),
            SillKeySpec(id: "rcmd", "⌘", code: SillLinuxKey.rightCmd, weight: 1.25, kind: .modifier),
            SillKeySpec(id: "ropt", "⌥", code: SillLinuxKey.rightOpt, weight: 1.15, kind: .modifier),
        ],
    ]

    static let arrowLeft = SillKeySpec("◀", code: SillLinuxKey.left, weight: 1.0, kind: .function)
    static let arrowUp = SillKeySpec("▲", code: SillLinuxKey.up, weight: 1.0, kind: .function)
    static let arrowDown = SillKeySpec("▼", code: SillLinuxKey.down, weight: 1.0, kind: .function)
    static let arrowRight = SillKeySpec("▶", code: SillLinuxKey.right, weight: 1.0, kind: .function)
}

/// Manages sticky modifiers, Caps Lock, hold-to-repeat key edges, and one-tap macOS shortcuts.
final class SillKeyboardStateMachine {
    private let sendKey: (UInt16, Bool) -> Void
    private(set) var activeModifiers: Set<UInt16> = []
    private(set) var pressedKeys: Set<UInt16> = []
    private(set) var capsLockOn: Bool = false

    init(sendKey: @escaping (UInt16, Bool) -> Void) {
        self.sendKey = sendKey
    }

    var isShifted: Bool {
        activeModifiers.contains(SillLinuxKey.leftShift) || activeModifiers.contains(SillLinuxKey.rightShift)
    }

    var displaysUppercaseLetters: Bool {
        isShifted != capsLockOn
    }

    func toggleModifier(_ code: UInt16) {
        if activeModifiers.contains(code) {
            activeModifiers.remove(code)
            sendKey(code, false)
        } else {
            activeModifiers.insert(code)
            sendKey(code, true)
        }
    }

    func tapCapsLock() {
        sendKey(SillLinuxKey.capsLock, true)
        sendKey(SillLinuxKey.capsLock, false)
        capsLockOn.toggle()
    }

    func pressKey(_ code: UInt16) {
        guard !pressedKeys.contains(code) else { return }
        pressedKeys.insert(code)
        sendKey(code, true)
    }

    func releaseKey(_ code: UInt16) {
        guard pressedKeys.remove(code) != nil else { return }
        sendKey(code, false)
        releaseStickyModifiers()
    }

    func triggerShortcut(_ codes: [UInt16]) {
        guard !codes.isEmpty else { return }
        releaseStickyModifiers()
        if codes.count == 1 {
            sendKey(codes[0], true)
            sendKey(codes[0], false)
            return
        }
        let modifiers = codes.dropLast()
        let key = codes[codes.count - 1]
        for modifier in modifiers {
            sendKey(modifier, true)
        }
        sendKey(key, true)
        sendKey(key, false)
        for modifier in modifiers.reversed() {
            sendKey(modifier, false)
        }
    }

    func releaseStickyModifiers() {
        guard !activeModifiers.isEmpty else { return }
        for code in activeModifiers.sorted() {
            sendKey(code, false)
        }
        activeModifiers.removeAll()
    }

    func releaseAll() {
        for code in pressedKeys.sorted() {
            sendKey(code, false)
        }
        pressedKeys.removeAll()
        releaseStickyModifiers()
    }
}
