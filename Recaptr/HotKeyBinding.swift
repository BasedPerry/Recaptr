//
//  HotKeyBinding.swift
//  Recaptr
//
//  A global key combo and where the user's choices are saved.
//

import Foundation
import AppKit
import Carbon.HIToolbox

nonisolated struct HotKeyBinding: Equatable, Hashable, Codable, Sendable {
    /// Carbon virtual key code (kVK_*).
    var keyCode: UInt32
    /// Carbon modifier mask (cmdKey, optionKey, controlKey, shiftKey).
    var modifiers: UInt32

    static let controlOptionCommand = UInt32(controlKey | optionKey | cmdKey)

    /// Needs ⌃, ⌥ or ⌘: Shift alone would swallow capital letters in every app.
    var isValid: Bool {
        modifiers & UInt32(controlKey | optionKey | cmdKey) != 0
    }

    /// "⌃⌥⌘R", in the standard modifier order.
    var display: String {
        var s = ""
        if modifiers & UInt32(controlKey) != 0 { s += "⌃" }
        if modifiers & UInt32(optionKey) != 0 { s += "⌥" }
        if modifiers & UInt32(shiftKey) != 0 { s += "⇧" }
        if modifiers & UInt32(cmdKey) != 0 { s += "⌘" }
        return s + Self.keyName(keyCode)
    }

    /// From a key-down event, for the shortcut recorder.
    init?(event: NSEvent) {
        guard event.type == .keyDown else { return nil }
        self.init(keyCode: UInt32(event.keyCode), modifierFlags: event.modifierFlags)
    }

    init(keyCode: UInt32, modifiers: UInt32) {
        self.keyCode = keyCode
        self.modifiers = modifiers
    }

    init(keyCode: UInt32, modifierFlags flags: NSEvent.ModifierFlags) {
        var m: UInt32 = 0
        if flags.contains(.command) { m |= UInt32(cmdKey) }
        if flags.contains(.option) { m |= UInt32(optionKey) }
        if flags.contains(.control) { m |= UInt32(controlKey) }
        if flags.contains(.shift) { m |= UInt32(shiftKey) }
        self.init(keyCode: keyCode, modifiers: m)
    }

    private static let names: [Int: String] = {
        var n: [Int: String] = [
            kVK_ANSI_A: "A", kVK_ANSI_B: "B", kVK_ANSI_C: "C", kVK_ANSI_D: "D", kVK_ANSI_E: "E",
            kVK_ANSI_F: "F", kVK_ANSI_G: "G", kVK_ANSI_H: "H", kVK_ANSI_I: "I", kVK_ANSI_J: "J",
            kVK_ANSI_K: "K", kVK_ANSI_L: "L", kVK_ANSI_M: "M", kVK_ANSI_N: "N", kVK_ANSI_O: "O",
            kVK_ANSI_P: "P", kVK_ANSI_Q: "Q", kVK_ANSI_R: "R", kVK_ANSI_S: "S", kVK_ANSI_T: "T",
            kVK_ANSI_U: "U", kVK_ANSI_V: "V", kVK_ANSI_W: "W", kVK_ANSI_X: "X", kVK_ANSI_Y: "Y",
            kVK_ANSI_Z: "Z",
            kVK_ANSI_0: "0", kVK_ANSI_1: "1", kVK_ANSI_2: "2", kVK_ANSI_3: "3", kVK_ANSI_4: "4",
            kVK_ANSI_5: "5", kVK_ANSI_6: "6", kVK_ANSI_7: "7", kVK_ANSI_8: "8", kVK_ANSI_9: "9",
            kVK_ANSI_Minus: "-", kVK_ANSI_Equal: "=", kVK_ANSI_LeftBracket: "[", kVK_ANSI_RightBracket: "]",
            kVK_ANSI_Semicolon: ";", kVK_ANSI_Quote: "'", kVK_ANSI_Comma: ",", kVK_ANSI_Period: ".",
            kVK_ANSI_Slash: "/", kVK_ANSI_Backslash: "\\", kVK_ANSI_Grave: "`",
            kVK_Space: "Space", kVK_Return: "↩", kVK_Tab: "⇥", kVK_Escape: "⎋", kVK_Delete: "⌫",
            kVK_LeftArrow: "←", kVK_RightArrow: "→", kVK_UpArrow: "↑", kVK_DownArrow: "↓",
            kVK_Home: "↖", kVK_End: "↘", kVK_PageUp: "⇞", kVK_PageDown: "⇟",
        ]
        let fKeys = [kVK_F1, kVK_F2, kVK_F3, kVK_F4, kVK_F5, kVK_F6, kVK_F7, kVK_F8, kVK_F9, kVK_F10,
                     kVK_F11, kVK_F12, kVK_F13, kVK_F14, kVK_F15, kVK_F16, kVK_F17, kVK_F18, kVK_F19, kVK_F20]
        for (i, code) in fKeys.enumerated() { n[code] = "F\(i + 1)" }
        return n
    }()

    static func keyName(_ code: UInt32) -> String {
        names[Int(code)] ?? "Key \(code)"
    }
}

/// The user's global keys, one per action. Unset actions use their
/// default; an action the user cleared stays cleared.
nonisolated struct HotKeySettings: Equatable, Sendable {

    static let storageKey = "RecaptrHotKeys"

    /// Only actions the user changed. nil value = cleared.
    private(set) var overrides: [RecaptrAction: HotKeyBinding?] = [:]

    func binding(for action: RecaptrAction) -> HotKeyBinding? {
        if let override = overrides[action] { return override }
        return action.defaultHotKey
    }

    var all: [RecaptrAction: HotKeyBinding] {
        var out: [RecaptrAction: HotKeyBinding] = [:]
        for action in RecaptrAction.allCases {
            if let b = binding(for: action) { out[action] = b }
        }
        return out
    }

    enum Problem: Equatable {
        case needsModifier
        case usedBy(RecaptrAction)
        /// Another app holds the combo.
        case takenElsewhere

        var message: String {
            switch self {
            case .needsModifier:       return "Use at least one of ⌃, ⌥ or ⌘."
            case .usedBy(let action):  return "Already used for \(action.label)."
            case .takenElsewhere:      return "Another app is using that shortcut."
            }
        }
    }

    /// Why `binding` can't go on `action`, or nil when it can.
    func problem(setting binding: HotKeyBinding, on action: RecaptrAction) -> Problem? {
        guard binding.isValid else { return .needsModifier }
        if let other = all.first(where: { $0.key != action && $0.value == binding })?.key {
            return .usedBy(other)
        }
        return nil
    }

    /// Sets or clears `action`'s key. Refuses (and changes nothing) when
    /// the combo has a problem.
    @discardableResult
    mutating func set(_ binding: HotKeyBinding?, for action: RecaptrAction) -> Problem? {
        if let binding, let problem = problem(setting: binding, on: action) { return problem }
        overrides[action] = .some(binding)
        if binding == action.defaultHotKey { overrides[action] = nil }
        return nil
    }

    mutating func restoreDefaults() {
        overrides = [:]
    }

    // MARK: - Storage

    /// Saved as ["action": "keyCode:modifiers"], "" for a cleared key.
    static func load(from defaults: UserDefaults = .standard) -> HotKeySettings {
        var settings = HotKeySettings()
        let stored = defaults.dictionary(forKey: storageKey) as? [String: String] ?? [:]
        for (key, value) in stored {
            guard let action = RecaptrAction(rawValue: key) else { continue }
            if value.isEmpty { settings.overrides[action] = .some(nil); continue }
            let parts = value.split(separator: ":").compactMap { UInt32($0) }
            guard parts.count == 2 else { continue }
            let binding = HotKeyBinding(keyCode: parts[0], modifiers: parts[1])
            if binding.isValid { settings.overrides[action] = .some(binding) }
        }
        return settings
    }

    func save(to defaults: UserDefaults = .standard) {
        var out: [String: String] = [:]
        for (action, binding) in overrides {
            out[action.rawValue] = binding.map { "\($0.keyCode):\($0.modifiers)" } ?? ""
        }
        defaults.set(out, forKey: Self.storageKey)
    }
}
