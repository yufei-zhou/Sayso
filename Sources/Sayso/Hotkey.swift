import AppKit
import Carbon.HIToolbox

/// The global shortcut: a key with modifiers, pressed once (⌥Space) or twice in a row (⌃X X, ⌘C C), or a modifier
/// key tapped twice on its own (⌘ ⌘).
struct Hotkey: Codable, Equatable {
    var keyCode: UInt16
    /// Device-independent modifier flags (command, control, option, shift).
    var modifiers: UInt
    var doubleTap: Bool
    /// The key's label as typed, e.g. "X", "Space".
    var key: String

    /// Stands for "no key": the shortcut is a modifier key on its own.
    static let noKey = UInt16.max

    static let `default` = Hotkey(keyCode: noKey, modifiers: NSEvent.ModifierFlags.command.rawValue, doubleTap: true, key: "")
    /// The default until 1.0.0. Anyone still on it is moved to the new default once.
    static let previousDefault = Hotkey(keyCode: UInt16(kVK_ANSI_X), modifiers: NSEvent.ModifierFlags.control.rawValue,
                                        doubleTap: true, key: "X")

    /// A modifier key tapped twice on its own.
    static func modifierTap(_ flag: NSEvent.ModifierFlags) -> Hotkey {
        Hotkey(keyCode: noKey, modifiers: flag.rawValue, doubleTap: true, key: "")
    }

    var isModifierOnly: Bool { keyCode == Self.noKey }

    var flags: NSEvent.ModifierFlags { NSEvent.ModifierFlags(rawValue: modifiers).intersection(Self.relevant) }
    static let relevant: NSEvent.ModifierFlags = [.control, .option, .shift, .command]

    /// Modifier symbols in the standard macOS order.
    var modifierSymbols: [String] {
        var symbols: [String] = []
        if flags.contains(.control) { symbols.append("⌃") }
        if flags.contains(.option) { symbols.append("⌥") }
        if flags.contains(.shift) { symbols.append("⇧") }
        if flags.contains(.command) { symbols.append("⌘") }
        return symbols
    }

    /// e.g. "⌃X X", "⌥Space" or "⌘ ⌘".
    var display: String {
        if isModifierOnly { return modifierSymbols.joined() + " " + modifierSymbols.joined() }
        return modifierSymbols.joined() + key + (doubleTap ? " " + key : "")
    }

    /// The same combination as a single press (what the first of two presses does in other apps).
    var single: Hotkey { Hotkey(keyCode: keyCode, modifiers: modifiers, doubleTap: false, key: key) }

    var cgFlags: CGEventFlags {
        var result: CGEventFlags = []
        if flags.contains(.control) { result.insert(.maskControl) }
        if flags.contains(.option) { result.insert(.maskAlternate) }
        if flags.contains(.shift) { result.insert(.maskShift) }
        if flags.contains(.command) { result.insert(.maskCommand) }
        return result
    }

    var carbonModifiers: UInt32 {
        var result: UInt32 = 0
        if flags.contains(.control) { result |= UInt32(controlKey) }
        if flags.contains(.option) { result |= UInt32(optionKey) }
        if flags.contains(.shift) { result |= UInt32(shiftKey) }
        if flags.contains(.command) { result |= UInt32(cmdKey) }
        return result
    }

    static func keyName(for event: NSEvent) -> String {
        switch Int(event.keyCode) {
        case kVK_Space: return "Space"
        case kVK_Return: return "↩"
        case kVK_Tab: return "⇥"
        case kVK_Delete: return "⌫"
        case kVK_ForwardDelete: return "⌦"
        case kVK_Escape: return "Esc"
        case kVK_LeftArrow: return "←"
        case kVK_RightArrow: return "→"
        case kVK_UpArrow: return "↑"
        case kVK_DownArrow: return "↓"
        case kVK_F1: return "F1"
        case kVK_F2: return "F2"
        case kVK_F3: return "F3"
        case kVK_F4: return "F4"
        case kVK_F5: return "F5"
        case kVK_F6: return "F6"
        case kVK_F7: return "F7"
        case kVK_F8: return "F8"
        case kVK_F9: return "F9"
        case kVK_F10: return "F10"
        case kVK_F11: return "F11"
        case kVK_F12: return "F12"
        default:
            return (event.charactersIgnoringModifiers ?? "?").uppercased()
        }
    }

    static func isFunctionKey(_ keyCode: UInt16) -> Bool {
        [kVK_F1, kVK_F2, kVK_F3, kVK_F4, kVK_F5, kVK_F6, kVK_F7, kVK_F8, kVK_F9, kVK_F10, kVK_F11, kVK_F12]
            .contains(Int(keyCode))
    }
}

// MARK: - Conflicts

struct HotkeyConflict: Equatable {
    enum Level { case info, warning, error }
    let level: Level
    let message: String
}

@MainActor
enum HotkeyConflicts {
    /// Common shortcuts inside apps. For a double-press shortcut the first press still reaches the app.
    private static let common: [String: String] = [
        "⌘C": "Copy", "⌘V": "Paste", "⌘X": "Cut", "⌘Z": "Undo", "⌘A": "Select All", "⌘S": "Save",
        "⌘W": "Close Window", "⌘Q": "Quit", "⌘T": "New Tab", "⌘N": "New Window", "⌘F": "Find", "⌘P": "Print",
        "⌘O": "Open", "⌘H": "Hide", "⌘M": "Minimize", "⌘R": "Reload", "⌘L": "Address Bar", "⌘B": "Bold",
        "⌘I": "Italic", "⌘U": "Underline", "⌘E": "Use Selection for Find", "⌘G": "Find Next", "⌘K": "Insert Link",
        "⌘,": "Settings", "⌘⇧Z": "Redo", "⌘⇧T": "Reopen Tab", "⌘⇧N": "New Folder / Private Window",
        "⌃A": "Line Start", "⌃E": "Line End", "⌃K": "Delete to Line End", "⌃D": "Forward Delete",
        "⌃F": "Cursor Right", "⌃B": "Cursor Left", "⌃N": "Next Line", "⌃P": "Previous Line", "⌃H": "Backspace",
        "⌃T": "Transpose", "⌃O": "Insert Line", "⌃Y": "Yank", "⌃C": "Interrupt (Terminal)", "⌃Z": "Suspend (Terminal)",
        "⌃X": "nano / Emacs prefix", "⌃R": "Shell History Search", "⌃L": "Clear Screen (Terminal)", "⌃W": "Delete Word (Terminal)",
        "⌃U": "Delete Line (Terminal)",
    ]
    /// Single presses that do something hard to undo when they slip through as the first of two presses.
    private static let risky: Set<String> = ["⌘Q", "⌘W", "⌘V", "⌘X", "⌘Z", "⌘⇧Z", "⌘P", "⌘N", "⌘T", "⌘R", "⌘H", "⌘M",
                                             "⌃C", "⌃Z", "⌃D", "⌃K", "⌃U", "⌃W", "⌃H", "⌃T"]

    static func check(_ hotkey: Hotkey) -> [HotkeyConflict] {
        if hotkey.isModifierOnly {
            // Only a quick tap with nothing pressed in between counts, so normal shortcuts (⌘C, ⇧A…) never trigger it.
            if hotkey.flags == .shift {
                return [HotkeyConflict(level: .info, message: "Tapping ⇧ twice can happen while typing; another key may be safer.")]
            }
            return []
        }
        var result: [HotkeyConflict] = []
        let combo = hotkey.single.display

        if hotkey.flags.intersection([.command, .control, .option]).isEmpty, !Hotkey.isFunctionKey(hotkey.keyCode) {
            return [HotkeyConflict(level: .error, message: "Include ⌘ ⌃ or ⌥ so normal typing can't trigger it.")]
        }
        if let name = systemShortcut(hotkey.single) {
            result.append(HotkeyConflict(level: hotkey.doubleTap ? .warning : .error,
                                         message: hotkey.doubleTap
                                            ? "\(combo) is a system shortcut (\(name)); the first press will trigger it."
                                            : "\(combo) is already a system shortcut (\(name))."))
        }
        if hotkey.doubleTap {
            if let action = common[combo] {
                let level: HotkeyConflict.Level = risky.contains(combo) ? .warning : .info
                result.append(HotkeyConflict(level: level, message: "The first press still reaches the app: \(action)."))
            }
            if hotkey == Hotkey(keyCode: UInt16(kVK_ANSI_C), modifiers: NSEvent.ModifierFlags.command.rawValue, doubleTap: true, key: "C"),
               NSWorkspace.shared.urlForApplication(withBundleIdentifier: "local.nano.ClaudeTranslate") != nil {
                result.append(HotkeyConflict(level: .warning, message: "Claude Translate also uses ⌘C C."))
            }
        } else {
            if let action = common[combo] {
                result.append(HotkeyConflict(level: .warning, message: "Overrides \(action) in every app."))
            }
            if hotkey != AppSettings.shared.hotkey, !CarbonHotkey.isAvailable(hotkey) {
                result.append(HotkeyConflict(level: .error, message: "Another app has already registered \(combo)."))
            }
        }
        return result
    }

    /// Enabled shortcuts from System Settings › Keyboard Shortcuts (Spotlight, input sources, screenshots…).
    private static func systemShortcut(_ hotkey: Hotkey) -> String? {
        var unmanaged: Unmanaged<CFArray>?
        guard CopySymbolicHotKeys(&unmanaged) == noErr, let array = unmanaged?.takeRetainedValue() as? [[String: Any]] else { return nil }
        for entry in array {
            guard (entry[kHISymbolicHotKeyEnabled as String] as? Bool) == true,
                  let code = (entry[kHISymbolicHotKeyCode as String] as? NSNumber)?.intValue,
                  let mods = (entry[kHISymbolicHotKeyModifiers as String] as? NSNumber)?.uint32Value,
                  code == Int(hotkey.keyCode),
                  mods & UInt32(cmdKey | optionKey | controlKey | shiftKey) == hotkey.carbonModifiers else { continue }
            return knownSystemName(code: code, modifiers: mods) ?? "System Settings › Keyboard Shortcuts"
        }
        return nil
    }

    private static func knownSystemName(code: Int, modifiers: UInt32) -> String? {
        switch (code, modifiers) {
        case (kVK_Space, UInt32(cmdKey)): "Spotlight"
        case (kVK_Space, UInt32(controlKey)): "Input Source"
        case (kVK_Space, UInt32(controlKey | cmdKey)): "Emoji & Symbols"
        case (kVK_ANSI_3, UInt32(cmdKey | shiftKey)), (kVK_ANSI_4, UInt32(cmdKey | shiftKey)), (kVK_ANSI_5, UInt32(cmdKey | shiftKey)): "Screenshot"
        case (kVK_ANSI_Q, UInt32(controlKey | cmdKey)): "Lock Screen"
        default: nil
        }
    }
}

// MARK: - Single-press shortcuts (registered with the system, so the key doesn't reach other apps)

final class CarbonHotkey {
    private var ref: EventHotKeyRef?
    private var handler: EventHandlerRef?
    var onPress: (() -> Void)?
    private static let signature: OSType = 0x5359_5353 // "SYSS"

    /// Tries registering the combination briefly to see whether another app holds it.
    static func isAvailable(_ hotkey: Hotkey) -> Bool {
        var ref: EventHotKeyRef?
        let status = RegisterEventHotKey(UInt32(hotkey.keyCode), hotkey.carbonModifiers, EventHotKeyID(signature: signature, id: 99),
                                         GetApplicationEventTarget(), 0, &ref)
        if let ref { UnregisterEventHotKey(ref) }
        return status == noErr
    }

    @discardableResult
    func register(_ hotkey: Hotkey) -> Bool {
        unregister()
        if handler == nil {
            var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
            InstallEventHandler(GetApplicationEventTarget(), { _, _, userData in
                guard let userData else { return noErr }
                let me = Unmanaged<CarbonHotkey>.fromOpaque(userData).takeUnretainedValue()
                DispatchQueue.main.async { me.onPress?() }
                return noErr
            }, 1, &spec, Unmanaged.passUnretained(self).toOpaque(), &handler)
        }
        return RegisterEventHotKey(UInt32(hotkey.keyCode), hotkey.carbonModifiers, EventHotKeyID(signature: Self.signature, id: 1),
                                   GetApplicationEventTarget(), 0, &ref) == noErr
    }

    func unregister() {
        if let ref { UnregisterEventHotKey(ref) }
        ref = nil
    }
}
