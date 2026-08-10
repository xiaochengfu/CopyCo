import AppKit
import Carbon.HIToolbox
import Combine
import Foundation

struct HotKeyConfiguration: Codable, Equatable, Sendable {
    let keyCode: UInt32
    let modifiers: UInt32

    static let `default` = HotKeyConfiguration(
        keyCode: 8, // C
        modifiers: UInt32(optionKey | cmdKey)
    )

    var displayName: String {
        var result = ""
        if modifiers & UInt32(controlKey) != 0 { result += "⌃" }
        if modifiers & UInt32(optionKey) != 0 { result += "⌥" }
        if modifiers & UInt32(shiftKey) != 0 { result += "⇧" }
        if modifiers & UInt32(cmdKey) != 0 { result += "⌘" }
        return result + Self.keyName(for: keyCode)
    }

    init(keyCode: UInt32, modifiers: UInt32) {
        self.keyCode = keyCode
        self.modifiers = modifiers
    }

    init?(event: NSEvent) {
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        var modifiers: UInt32 = 0
        if flags.contains(.control) { modifiers |= UInt32(controlKey) }
        if flags.contains(.option) { modifiers |= UInt32(optionKey) }
        if flags.contains(.shift) { modifiers |= UInt32(shiftKey) }
        if flags.contains(.command) { modifiers |= UInt32(cmdKey) }
        guard modifiers != 0, !Self.isModifierKey(event.keyCode) else { return nil }
        self.init(keyCode: UInt32(event.keyCode), modifiers: modifiers)
    }

    static func keyName(for keyCode: UInt32) -> String {
        switch keyCode {
        case 0: return "A"
        case 1: return "S"
        case 2: return "D"
        case 3: return "F"
        case 4: return "H"
        case 5: return "G"
        case 6: return "Z"
        case 7: return "X"
        case 8: return "C"
        case 9: return "V"
        case 11: return "B"
        case 12: return "Q"
        case 13: return "W"
        case 14: return "E"
        case 15: return "R"
        case 16: return "Y"
        case 17: return "T"
        case 31: return "O"
        case 32: return "U"
        case 34: return "I"
        case 35: return "P"
        case 37: return "L"
        case 38: return "J"
        case 40: return "K"
        case 45: return "N"
        case 46: return "M"
        case 36: return "↩"
        case 48: return "⇥"
        case 49: return "Space"
        case 51: return "⌫"
        case 53: return "Esc"
        case 76: return "⌤"
        case 123: return "←"
        case 124: return "→"
        case 125: return "↓"
        case 126: return "↑"
        default: return "Key \(keyCode)"
        }
    }

    private static func isModifierKey(_ keyCode: UInt16) -> Bool {
        [54, 55, 56, 58, 59, 60, 61, 62].contains(keyCode)
    }
}

@MainActor
final class ShortcutRecorderModel: ObservableObject {
    @Published private(set) var isRecording = false
    var onCapture: ((HotKeyConfiguration) -> Void)?
    private var monitor: Any?

    func start() {
        stop()
        isRecording = true
        monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self, let configuration = HotKeyConfiguration(event: event) else { return event }
            self.onCapture?(configuration)
            self.stop()
            return nil
        }
    }

    func stop() {
        if let monitor {
            NSEvent.removeMonitor(monitor)
            self.monitor = nil
        }
        isRecording = false
    }

}
