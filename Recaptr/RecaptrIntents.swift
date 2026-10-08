//
//  RecaptrIntents.swift
//  Recaptr
//
//  Recaptr's actions in Shortcuts, Spotlight and Siri.
//

import AppIntents

extension RecaptrAction: AppEnum {
    static var typeDisplayRepresentation: TypeDisplayRepresentation { "Recaptr Action" }

    static var caseDisplayRepresentations: [RecaptrAction: DisplayRepresentation] {
        [
            .toggleRecording:   "Start or Stop Recording",
            .startRecording:    "Start Recording",
            .stopRecording:     "Stop Recording",
            .dropMarker:        "Drop Marker",
            .sourceCaptureCard: "Switch to Capture Card",
            .sourceScreen:      "Switch to Screen",
            .sourceWindow:      "Switch to Window",
            .toggleGameMonitor: "Game Monitor On or Off",
            .toggleMicMonitor:  "Mic Monitor On or Off",
            .toggleWindow:      "Show or Hide Recaptr",
            .openLastTake:      "Open Last Take",
        ]
    }
}

enum RecaptrIntentError: Error, CustomLocalizedStringResourceConvertible {
    case notRunning

    var localizedStringResource: LocalizedStringResource {
        "Recaptr isn't ready yet. Open it and try again."
    }
}

@MainActor
private func runningModel() throws -> MainViewModel {
    guard let vm = MainViewModel.current else { throw RecaptrIntentError.notRunning }
    return vm
}

/// Any action from the list.
struct RunRecaptrActionIntent: AppIntent {
    static let title: LocalizedStringResource = "Run Recaptr Action"
    static let description = IntentDescription("Runs one of Recaptr's actions, like starting a recording or dropping a marker.")

    @Parameter(title: "Action")
    var action: RecaptrAction

    static var parameterSummary: some ParameterSummary {
        Summary("Run \(\.$action) in Recaptr")
    }

    @MainActor
    func perform() async throws -> some IntentResult {
        try runningModel().perform(action)
        return .result()
    }
}

struct ToggleRecordingIntent: AppIntent {
    static let title: LocalizedStringResource = "Start or Stop Recording"
    static let description = IntentDescription("Starts recording with Recaptr's current source and settings, or stops the recording.")

    @MainActor
    func perform() async throws -> some IntentResult {
        try runningModel().perform(.toggleRecording)
        return .result()
    }
}

struct DropMarkerIntent: AppIntent {
    static let title: LocalizedStringResource = "Drop Marker"
    static let description = IntentDescription("Adds a marker to the recording in progress.")

    @MainActor
    func perform() async throws -> some IntentResult {
        try runningModel().perform(.dropMarker)
        return .result()
    }
}

struct IsRecordingIntent: AppIntent {
    static let title: LocalizedStringResource = "Is Recaptr Recording?"
    static let description = IntentDescription("Returns true while Recaptr is recording.")

    @MainActor
    func perform() async throws -> some IntentResult & ReturnsValue<Bool> {
        .result(value: try runningModel().isRecording)
    }
}

struct RecaptrShortcuts: AppShortcutsProvider {
    static var appShortcuts: [AppShortcut] {
        AppShortcut(intent: ToggleRecordingIntent(),
                    phrases: ["Start or stop recording in \(.applicationName)",
                              "Toggle \(.applicationName) recording"],
                    shortTitle: "Record",
                    systemImageName: "record.circle")
        AppShortcut(intent: DropMarkerIntent(),
                    phrases: ["Drop a marker in \(.applicationName)",
                              "Mark this in \(.applicationName)"],
                    shortTitle: "Drop Marker",
                    systemImageName: "bookmark.fill")
        AppShortcut(intent: IsRecordingIntent(),
                    phrases: ["Is \(.applicationName) recording"],
                    shortTitle: "Is Recording?",
                    systemImageName: "questionmark.circle")
        AppShortcut(intent: RunRecaptrActionIntent(),
                    phrases: ["Run a \(.applicationName) action"],
                    shortTitle: "Run Action",
                    systemImageName: "bolt.fill")
    }
}
