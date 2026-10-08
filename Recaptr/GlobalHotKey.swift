//
//  GlobalHotKey.swift
//  Recaptr
//
//  System-wide keys for Recaptr's actions while another app is in front.
//  Carbon's hot key API works in the sandbox and needs no Accessibility or
//  Input Monitoring permission. Defaults avoid ⌘B and ⌘R, which would
//  steal Bold, Final Cut's Blade and Record.
//

import Carbon.HIToolbox
import Foundation

@MainActor
final class GlobalHotKeys {

    /// Called on the main actor when a registered key is pressed.
    var onPress: ((RecaptrAction) -> Void)?

    private var handlerRef: EventHandlerRef?
    private var registered: [RecaptrAction: (ref: EventHotKeyRef, binding: HotKeyBinding)] = [:]
    private static let signature = OSType(0x52435054)  // 'RCPT'

    init() {
        var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        let context = Unmanaged.passUnretained(self).toOpaque()
        InstallEventHandler(GetApplicationEventTarget(), { _, event, userData in
            guard let event, let userData else { return noErr }
            var id = EventHotKeyID()
            let status = GetEventParameter(event, EventParamName(kEventParamDirectObject), EventParamType(typeEventHotKeyID),
                                           nil, MemoryLayout<EventHotKeyID>.size, nil, &id)
            guard status == noErr, id.signature == GlobalHotKeys.signature else { return OSStatus(eventNotHandledErr) }
            let keys = Unmanaged<GlobalHotKeys>.fromOpaque(userData).takeUnretainedValue()
            MainActor.assumeIsolated { keys.pressed(id: id.id) }
            return noErr
        }, 1, &spec, context, &handlerRef)
    }

    isolated deinit {
        for entry in registered.values { UnregisterEventHotKey(entry.ref) }
        if let handlerRef { RemoveEventHandler(handlerRef) }
    }

    /// Registers exactly `wanted`, leaving keys that didn't change alone.
    /// Returns the actions whose combo another app already holds.
    @discardableResult
    func update(_ wanted: [RecaptrAction: HotKeyBinding]) -> Set<RecaptrAction> {
        for (action, entry) in registered where wanted[action] != entry.binding {
            UnregisterEventHotKey(entry.ref)
            registered[action] = nil
        }
        var failed = Set<RecaptrAction>()
        for (action, binding) in wanted where registered[action] == nil {
            var ref: EventHotKeyRef?
            let id = EventHotKeyID(signature: Self.signature, id: Self.number(for: action))
            let status = RegisterEventHotKey(binding.keyCode, binding.modifiers, id, GetApplicationEventTarget(), 0, &ref)
            if status == noErr, let ref {
                registered[action] = (ref, binding)
            } else {
                failed.insert(action)
            }
        }
        return failed
    }

    func unregisterAll() {
        update([:])
    }

    private func pressed(id: UInt32) {
        guard let action = RecaptrAction.allCases.first(where: { Self.number(for: $0) == id }) else { return }
        onPress?(action)
    }

    /// Stable id per action (1-based position in the list).
    private static func number(for action: RecaptrAction) -> UInt32 {
        UInt32((RecaptrAction.allCases.firstIndex(of: action) ?? 0) + 1)
    }
}
