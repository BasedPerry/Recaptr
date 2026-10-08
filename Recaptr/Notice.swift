//
//  Notice.swift
//  Recaptr
//
//  Plain-language messages for when Recaptr ends a take itself or can't
//  start one. The detail still goes to Diagnostics.
//

import Foundation
import UserNotifications

nonisolated struct Notice: Equatable, Identifiable, Sendable {

    enum Fix: Equatable, Sendable {
        case openScreenRecordingSettings
        case openMicrophoneSettings
        case openCameraSettings
        case pickSource
        case pickSaveFolder

        var label: String {
            switch self {
            case .openScreenRecordingSettings, .openMicrophoneSettings, .openCameraSettings:
                return "Open System Settings"
            case .pickSource:     return "Pick Another Source"
            case .pickSaveFolder: return "Choose Folder"
            }
        }
    }

    let id = UUID()
    /// One sentence: what happened.
    var message: String
    /// One sentence: what to do next.
    var next: String?
    var fix: Fix?
    /// True when a recording ended early (worth a notification if Recaptr
    /// is in the background).
    var endedTake = false

    static func == (a: Notice, b: Notice) -> Bool {
        a.message == b.message && a.next == b.next && a.fix == b.fix && a.endedTake == b.endedTake
    }

    // MARK: - Takes that ended early

    static func diskFull(gigabytesLeft: Double) -> Notice {
        Notice(message: "Recording stopped because the save drive is almost full. Your recording is saved.",
               next: String(format: "Free up space (%.1f GB left) or choose another folder.", gigabytesLeft),
               fix: .pickSaveFolder, endedTake: true)
    }

    static func writerFailed() -> Notice {
        Notice(message: "Recording stopped because the file couldn't be written. What was recorded is saved.",
               next: "Check the save drive is still connected, then record again.",
               endedTake: true)
    }

    static func deviceUnplugged(_ name: String, wasRecording: Bool) -> Notice {
        Notice(message: wasRecording ? "\(name) was disconnected, so recording stopped. Your recording is saved."
                                     : "\(name) was disconnected.",
               next: "Plug it back in or pick another source.",
               fix: .pickSource, endedTake: wasRecording)
    }

    static func screenStopped(wasRecording: Bool) -> Notice {
        Notice(message: wasRecording ? "Screen capture stopped, so recording stopped. Your recording is saved."
                                     : "Screen capture stopped.",
               next: "The window may have closed or the display was disconnected. Pick another source.",
               fix: .pickSource, endedTake: wasRecording)
    }

    static func permissionRevoked(_ kind: Fix, wasRecording: Bool) -> Notice {
        let what = kind == .openScreenRecordingSettings ? "Screen Recording" : "Microphone"
        return Notice(message: wasRecording ? "\(what) access was turned off, so recording stopped. Your recording is saved."
                                            : "\(what) access was turned off.",
                      next: "Turn it back on for Recaptr in System Settings.",
                      fix: kind, endedTake: wasRecording)
    }

    // MARK: - Couldn't start

    static let screenPermissionMissing = Notice(
        message: "Recaptr needs Screen Recording access to capture your screen.",
        next: "Turn it on for Recaptr in System Settings, then quit and reopen Recaptr.",
        fix: .openScreenRecordingSettings)

    static func notEnoughSpace(gigabytesFree: Double) -> Notice {
        Notice(message: String(format: "There isn't enough space to record: %.1f GB free.", gigabytesFree),
               next: "Free up at least 2 GB or choose another folder.",
               fix: .pickSaveFolder)
    }

    static let saveFolderUnavailable = Notice(
        message: "Recaptr can't save to the chosen folder.",
        next: "Check the drive is connected, or choose another folder.",
        fix: .pickSaveFolder)

    static let sourceBusy = Notice(
        message: "Recaptr couldn't start this source. Another app may be using it.",
        next: "Close other capture apps, or pick another source.",
        fix: .pickSource)

    static let recorderFailed = Notice(
        message: "Recaptr couldn't start recording.",
        next: "Try again. If it keeps happening, lower the resolution or encoding preset.")
}

/// Posts a notification when a take ends early and Recaptr isn't in front.
/// Asks for permission the first time it's needed, not at launch.
enum NoticeNotifier {
    static func post(_ notice: Notice) {
        guard notice.endedTake else { return }
        let center = UNUserNotificationCenter.current()
        Task {
            let granted = (try? await center.requestAuthorization(options: [.alert, .sound])) ?? false
            guard granted else { return }
            let content = UNMutableNotificationContent()
            content.title = "Recording stopped"
            content.body = notice.message
            try? await center.add(UNNotificationRequest(identifier: notice.id.uuidString, content: content, trigger: nil))
        }
    }
}
