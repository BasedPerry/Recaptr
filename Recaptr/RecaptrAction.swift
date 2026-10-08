//
//  RecaptrAction.swift
//  Recaptr
//
//  Every action another app, key or button can trigger. Menus, global
//  hotkeys, Shortcuts and recaptr:// URLs all come through this list.
//

import Foundation
import Carbon.HIToolbox

nonisolated enum RecaptrAction: String, CaseIterable, Identifiable, Codable, Sendable {
    case toggleRecording
    case startRecording
    case stopRecording
    case dropMarker
    case sourceCaptureCard
    case sourceScreen
    case sourceWindow
    case toggleGameMonitor
    case toggleMicMonitor
    case toggleWindow
    case openLastTake

    var id: Self { self }

    var label: String {
        switch self {
        case .toggleRecording:   return "Start or Stop Recording"
        case .startRecording:    return "Start Recording"
        case .stopRecording:     return "Stop Recording"
        case .dropMarker:        return "Drop Marker"
        case .sourceCaptureCard: return "Switch to Capture Card"
        case .sourceScreen:      return "Switch to Screen"
        case .sourceWindow:      return "Switch to Window"
        case .toggleGameMonitor: return "Game Monitor On or Off"
        case .toggleMicMonitor:  return "Mic Monitor On or Off"
        case .toggleWindow:      return "Show or Hide Recaptr"
        case .openLastTake:      return "Open Last Take"
        }
    }

    /// Path after `recaptr://`.
    var urlPath: String {
        switch self {
        case .toggleRecording:   return "record/toggle"
        case .startRecording:    return "record/start"
        case .stopRecording:     return "record/stop"
        case .dropMarker:        return "marker"
        case .sourceCaptureCard: return "source/capture-card"
        case .sourceScreen:      return "source/screen"
        case .sourceWindow:      return "source/window"
        case .toggleGameMonitor: return "monitor/game"
        case .toggleMicMonitor:  return "monitor/mic"
        case .toggleWindow:      return "window/toggle"
        case .openLastTake:      return "last-take"
        }
    }

    static let urlScheme = "recaptr"

    var url: URL { URL(string: "\(Self.urlScheme)://\(urlPath)")! }

    /// The action a `recaptr://` URL names. Anything else is nil: URLs can
    /// only run listed actions, never change settings or touch files.
    init?(url: URL) {
        guard url.scheme?.lowercased() == Self.urlScheme else { return nil }
        let path = ([url.host ?? ""] + url.pathComponents.filter { $0 != "/" })
            .filter { !$0.isEmpty }
            .joined(separator: "/")
            .lowercased()
        guard let match = Self.allCases.first(where: { $0.urlPath == path }) else { return nil }
        self = match
    }

    /// Ships with a global key. The rest start blank for people to set.
    var defaultHotKey: HotKeyBinding? {
        switch self {
        case .toggleRecording: return HotKeyBinding(keyCode: UInt32(kVK_ANSI_R), modifiers: HotKeyBinding.controlOptionCommand)
        case .dropMarker:      return HotKeyBinding(keyCode: UInt32(kVK_ANSI_B), modifiers: HotKeyBinding.controlOptionCommand)
        default:               return nil
        }
    }

    /// The marker key is registered only while recording, so the combo is
    /// free the rest of the time. The others are live whenever Recaptr runs.
    var hotKeyOnlyWhileRecording: Bool { self == .dropMarker }
}
