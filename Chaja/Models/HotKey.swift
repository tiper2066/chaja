import AppKit
import Carbon.HIToolbox

nonisolated struct HotKey: Codable, Equatable, Sendable {
    var keyCode: UInt16
    var modifierFlags: UInt
    var keyLabel: String

    /// 기본값 ⌃⌥F. ⌘Space(Spotlight), ⌥⌘Space(Finder 검색), ⌃⌥Space(입력 소스 전환)는 시스템이 쓰므로 피한다.
    static let defaultValue = HotKey(keyCode: UInt16(kVK_ANSI_F),
                                     modifierFlags: NSEvent.ModifierFlags([.control, .option]).rawValue,
                                     keyLabel: "F")

    var modifiers: NSEvent.ModifierFlags {
        NSEvent.ModifierFlags(rawValue: modifierFlags).intersection([.command, .option, .control, .shift])
    }

    var displayString: String {
        var result = ""
        if modifiers.contains(.control) { result += "⌃" }
        if modifiers.contains(.option) { result += "⌥" }
        if modifiers.contains(.shift) { result += "⇧" }
        if modifiers.contains(.command) { result += "⌘" }
        return result + keyLabel
    }

    var carbonModifiers: UInt32 {
        var result = 0
        if modifiers.contains(.command) { result |= cmdKey }
        if modifiers.contains(.option) { result |= optionKey }
        if modifiers.contains(.control) { result |= controlKey }
        if modifiers.contains(.shift) { result |= shiftKey }
        return UInt32(result)
    }

    /// 단축키 기록 화면에서 받은 키 입력으로 만든다. ⌘·⌥·⌃ 중 하나는 있어야 다른 앱 입력과 겹치지 않는다.
    init?(event: NSEvent) {
        let modifiers = event.modifierFlags.intersection([.command, .option, .control, .shift])
        guard !modifiers.intersection([.command, .option, .control]).isEmpty else { return nil }
        self.keyCode = event.keyCode
        self.modifierFlags = modifiers.rawValue
        self.keyLabel = Self.label(for: event)
    }

    init(keyCode: UInt16, modifierFlags: UInt, keyLabel: String) {
        self.keyCode = keyCode
        self.modifierFlags = modifierFlags
        self.keyLabel = keyLabel
    }

    private static let functionKeys: [Int: String] = [
        kVK_F1: "F1", kVK_F2: "F2", kVK_F3: "F3", kVK_F4: "F4", kVK_F5: "F5", kVK_F6: "F6",
        kVK_F7: "F7", kVK_F8: "F8", kVK_F9: "F9", kVK_F10: "F10", kVK_F11: "F11", kVK_F12: "F12",
    ]

    private static func label(for event: NSEvent) -> String {
        switch Int(event.keyCode) {
        case kVK_Space: return "Space"
        case kVK_Return: return "↩"
        case kVK_Tab: return "⇥"
        case kVK_Delete: return "⌫"
        case kVK_Escape: return "⎋"
        case kVK_LeftArrow: return "←"
        case kVK_RightArrow: return "→"
        case kVK_UpArrow: return "↑"
        case kVK_DownArrow: return "↓"
        case let code where functionKeys[code] != nil: return functionKeys[code]!
        default:
            // ⌥를 누른 상태의 문자(예: ƒ)가 아니라 키 자체의 글자를 쓴다.
            let characters = event.charactersIgnoringModifiers ?? ""
            return characters.isEmpty ? "#\(event.keyCode)" : characters.uppercased()
        }
    }
}
