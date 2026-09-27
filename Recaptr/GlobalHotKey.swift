//
//  GlobalHotKey.swift
//  Recaptr
//
//  System-wide shortcut, so a clip marker can be dropped while another
//  app (the game, a browser) is in front. ⌘B only works while Recaptr
//  is the active app, and a global ⌘B would steal Bold everywhere and
//  Blade in Final Cut, so the global combo is ⌃⌥⌘B.
//
//  Carbon's RegisterEventHotKey: works in the sandbox and needs no
//  Accessibility or Input Monitoring permission, because the system
//  delivers only this exact combo to us.
//

import Carbon.HIToolbox
import Foundation

@MainActor
final class GlobalHotKey {

    private var hotKeyRef: EventHotKeyRef?
    private var handlerRef: EventHandlerRef?
    private let action: () -> Void

    /// Registers `keyCode` + `modifiers` (Carbon constants) and calls
    /// `action` on the main actor each time it's pressed.
    init?(keyCode: UInt32, modifiers: UInt32, action: @escaping () -> Void) {
        self.action = action
        var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        let context = Unmanaged.passUnretained(self).toOpaque()
        let installed = InstallEventHandler(GetApplicationEventTarget(), { _, _, userData in
            guard let userData else { return noErr }
            let hotKey = Unmanaged<GlobalHotKey>.fromOpaque(userData).takeUnretainedValue()
            MainActor.assumeIsolated { hotKey.action() }
            return noErr
        }, 1, &spec, context, &handlerRef)
        guard installed == noErr else { return nil }

        let id = EventHotKeyID(signature: OSType(0x52435054), id: 1)  // 'RCPT'
        let registered = RegisterEventHotKey(keyCode, modifiers, id, GetApplicationEventTarget(), 0, &hotKeyRef)
        guard registered == noErr else {
            if let handlerRef { RemoveEventHandler(handlerRef) }
            return nil
        }
    }

    /// ⌃⌥⌘B.
    static func marker(action: @escaping () -> Void) -> GlobalHotKey? {
        GlobalHotKey(keyCode: UInt32(kVK_ANSI_B),
                     modifiers: UInt32(controlKey | optionKey | cmdKey),
                     action: action)
    }

    func unregister() {
        if let hotKeyRef { UnregisterEventHotKey(hotKeyRef) }
        if let handlerRef { RemoveEventHandler(handlerRef) }
        hotKeyRef = nil
        handlerRef = nil
    }
}
