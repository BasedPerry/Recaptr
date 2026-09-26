//
//  RecaptrRecordingSmokeTests.swift
//  RecaptrUITests
//
//  End-to-end record tests: pick a source, record a few seconds,
//  stop, and check what actually landed in the file using the app's
//  own file probe (exposed to accessibility under -RecaptrUITesting).
//  Files go to the sandbox container, never the user's footage folder.
//
//  These need real hardware and permissions: Screen Recording for the
//  screen test, a connected camera or capture card for the camera
//  test. A test skips rather than fails when its source is missing.
//

import XCTest

final class RecaptrRecordingSmokeTests: XCTestCase {

    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    @MainActor
    func testScreenRecording() throws {
        // Monitor on, so system-audio playback runs alongside the
        // recorder for the whole take.
        let probe = try record(modeKey: "2", seconds: 6, monitor: true)
        XCTAssertEqual(probe.videoTracks, 1)
        XCTAssertGreaterThan(probe.duration, 4)
        // SCStream only delivers frames when the screen changes, so a
        // static desktop can legitimately land well under 60.
        XCTAssertGreaterThan(probe.fps, 0)
        XCTAssertTrue(probe.hasAudio, "Screen capture should carry the system audio track")
    }

    @MainActor
    func testCameraRecording() throws {
        let probe = try record(modeKey: "3", seconds: 6)
        XCTAssertEqual(probe.videoTracks, 1)
        XCTAssertGreaterThan(probe.duration, 4)
        // Capture cards and webcams run 30 or 60; anything lower means
        // the format lock regressed.
        XCTAssertGreaterThanOrEqual(probe.fps, 29)
        XCTAssertEqual(probe.audioTracks, 1, "Single source should write one audio track")
        XCTAssertEqual(probe.markerRanges, 0, "No markers, so no marker ranges")
        // An audio track full of zero-fill is a silent recording. The
        // channel must actually have pushed captured audio.
        if probe.status.contains("push=") {
            XCTAssertGreaterThan(number(in: probe.status, after: "push=", until: " ") ?? 0, 0,
                                 "Audio channel captured nothing: \(probe.status)")
        }
    }

    /// Two clip markers become three marker ranges (Start, Marker 1,
    /// Marker 2) in the file's marker track, without costing frames.
    @MainActor
    func testCameraRecordingWithMarkers() throws {
        let probe = try record(modeKey: "3", seconds: 6, markers: 2)
        XCTAssertGreaterThanOrEqual(probe.fps, 29)
        XCTAssertEqual(probe.markerRanges, 3, "Expected Start + 2 marker ranges: \(probe.raw)")
    }

    /// macOS 27 constant-quality encoding records a valid file at
    /// full frame rate.
    @MainActor
    func testCameraRecordingConstantQuality() throws {
        let probe = try record(modeKey: "3", seconds: 6,
                               extraArgs: ["-RecaptrVideoQuality", "constantQuality"])
        XCTAssertEqual(probe.videoTracks, 1)
        XCTAssertGreaterThan(probe.duration, 4)
        XCTAssertGreaterThanOrEqual(probe.fps, 29)
        XCTAssertTrue(probe.status.contains("Saved") || probe.status.contains("Probe"),
                      "Recording did not complete: \(probe.status)")
    }

    /// The Settings device picker really changes the recorded audio:
    /// pick a mic in Settings while previewing, record, and the mic
    /// channel must capture and get its own track. (The old popover
    /// picker was disabled whenever preview was running.)
    @MainActor
    func testMicChosenInSettingsIsRecorded() throws {
        let probe = try record(modeKey: "3", seconds: 6) { app in
            Thread.sleep(forTimeInterval: 2)
            app.buttons["settingsButton"].click()
            let settings = app.windows.matching(NSPredicate(format: "identifier CONTAINS 'Settings'")).firstMatch
            XCTAssertTrue(settings.waitForExistence(timeout: 5))
            settings.toolbars.buttons["Audio"].click()
            let picker = settings.popUpButtons["micDevicePicker"]
            XCTAssertTrue(picker.waitForExistence(timeout: 5))
            XCTAssertTrue(picker.isEnabled, "Mic picker is disabled during preview")
            picker.click()
            let item = settings.menuItems["Jump Desktop Microphone"]
            guard item.waitForExistence(timeout: 3) else {
                settings.typeKey(.escape, modifierFlags: [])
                throw XCTSkip("Test mic input not available on this Mac")
            }
            item.click()
            settings.typeKey("w", modifierFlags: .command)
        }
        try assertChannelsCaptured(["Audio:", "Mic:"], in: probe)
        assertSourceTracks(probe)
    }

    /// Capture card plus a second input on the mic channel. Uses the
    /// Jump Desktop virtual microphone so the test runs without a
    /// physical second mic; it delivers silence, which still proves
    /// both channels capture and mix.
    @MainActor
    func testCameraRecordingWithMic() throws {
        let probe = try record(modeKey: "3", seconds: 6,
                               extraArgs: ["-RecaptrUITestMicInput", "Jump Desktop Microphone"])
        XCTAssertGreaterThanOrEqual(probe.fps, 29)
        try assertChannelsCaptured(["Audio:", "Mic:"], in: probe)
        assertSourceTracks(probe)
    }

    /// Narration over a screen capture: SCStream system audio and the
    /// mic are mixed into the file.
    @MainActor
    func testScreenRecordingWithMic() throws {
        let probe = try record(modeKey: "2", seconds: 6,
                               extraArgs: ["-RecaptrUITestMicInput", "Jump Desktop Microphone"])
        XCTAssertEqual(probe.videoTracks, 1)
        XCTAssertTrue(probe.hasAudio)
        try assertChannelsCaptured(["System:", "Mic:"], in: probe)
        assertSourceTracks(probe)
    }

    /// Two sources: the mix plus one track per source, with only the
    /// mix enabled so players don't double the audio.
    private func assertSourceTracks(_ probe: Probe) {
        XCTAssertEqual(probe.audioTracks, 3, "Expected mix + 2 source tracks: \(probe.raw)")
        XCTAssertEqual(probe.enabledAudioTracks, 1, "Only the mix should be enabled: \(probe.raw)")
    }

    /// Every named mixer channel is running and pushed real audio.
    private func assertChannelsCaptured(_ channels: [String], in probe: Probe) throws {
        guard probe.status.contains("Mic:[") else {
            throw XCTSkip("Test mic input not available on this Mac")
        }
        for channel in channels {
            let part = probe.status.components(separatedBy: " · ")
                .first { $0.hasPrefix(channel) } ?? ""
            XCTAssertTrue(part.contains("ON"), "\(channel) channel not running: \(part)")
            XCTAssertGreaterThan(number(in: part, after: "push=", until: " ") ?? 0, 0,
                                 "\(channel) channel captured nothing: \(part)")
        }
    }

    /// Instant replay: with the option on, previewing a screen source
    /// for a while and pressing Shift-Cmd-R saves a clip of the last
    /// few seconds, without recording.
    @MainActor
    func testScreenInstantReplay() throws {
        let app = XCUIApplication()
        app.launchArguments += ["-ApplePersistenceIgnoreState", "YES",
                                "-RecaptrUITesting", "YES",
                                "-RecaptrKeepChromeVisible", "YES",
                                "-RecaptrInstantReplay", "YES"]
        app.launch()
        let window = app.windows.firstMatch
        XCTAssertTrue(window.waitForExistence(timeout: 10))
        window.typeKey("2", modifierFlags: .command)
        // Let the buffer fill.
        Thread.sleep(forTimeInterval: 8)
        window.typeKey("r", modifierFlags: [.command, .shift])

        let probeText = app.staticTexts["lastProbe"]
        let statusText = app.staticTexts["statusLine"]
        XCTAssertTrue(probeText.waitForExistence(timeout: 5))
        let gotProbe = waitUntil(timeout: 20, { text(of: probeText).hasPrefix("Probe →") })
        let raw = text(of: probeText)
        let attachment = XCTAttachment(string: raw + "\n" + text(of: statusText))
        attachment.name = "Probe, Replay"
        attachment.lifetime = .keepAlways
        add(attachment)
        XCTAssertTrue(gotProbe, "No replay probe. Status: \(text(of: statusText))")
        XCTAssertEqual(Int(number(in: raw, after: "video tracks=", until: " ") ?? 0), 1)
        XCTAssertGreaterThan(number(in: raw, after: "Probe → ", until: "s") ?? 0, 4,
                             "Replay should hold several seconds: \(raw)")
    }

    // MARK: - Helpers

    struct Probe {
        var raw: String
        var status: String
        var duration: Double
        var videoTracks: Int
        var fps: Double
        var hasAudio: Bool
        var audioTracks: Int
        var enabledAudioTracks: Int
        var markerRanges: Int
    }

    @MainActor
    private func record(modeKey: String, seconds: TimeInterval, monitor: Bool = false,
                        markers: Int = 0, extraArgs: [String] = [],
                        beforeRecording: ((XCUIApplication) throws -> Void)? = nil) throws -> Probe {
        let app = XCUIApplication()
        // Ignore saved window state so every run starts with the
        // capture window open.
        app.launchArguments += ["-ApplePersistenceIgnoreState", "YES"]
        app.launchArguments += ["-RecaptrUITesting", "YES",
                                "-RecaptrKeepChromeVisible", "YES"] + extraArgs
        app.launch()
        let window = app.windows.firstMatch
        XCTAssertTrue(window.waitForExistence(timeout: 10))

        // Cmd+2 / Cmd+3 switch mode and auto-pick the first source.
        window.typeKey(modeKey, modifierFlags: .command)
        let record = app.buttons["recordButton"]
        XCTAssertTrue(record.waitForExistence(timeout: 5))
        guard waitUntil(timeout: 8, { record.isEnabled }) else {
            throw XCTSkip("No source available for mode Cmd+\(modeKey)")
        }
        try beforeRecording?(app)
        // Let the preview settle so the format lock and audio are live.
        Thread.sleep(forTimeInterval: 3)
        if monitor {
            window.typeKey("k", modifierFlags: .command)
            let toggle = app.buttons["monitorToggle"]
            XCTAssertTrue(waitUntil(timeout: 3, { (toggle.value as? String) == "On" }),
                          "Monitor did not switch on")
        }

        window.typeKey("r", modifierFlags: .command)
        // Spread any markers evenly through the take (Cmd+B).
        let slice = seconds / Double(markers + 1)
        for _ in 0..<markers {
            Thread.sleep(forTimeInterval: slice)
            window.typeKey("b", modifierFlags: .command)
        }
        Thread.sleep(forTimeInterval: slice)
        window.typeKey("r", modifierFlags: .command)

        let probeText = app.staticTexts["lastProbe"]
        let statusText = app.staticTexts["statusLine"]
        XCTAssertTrue(probeText.waitForExistence(timeout: 5))
        let gotProbe = waitUntil(timeout: 20, { text(of: probeText).hasPrefix("Probe →") })
        let status = XCTAttachment(string: text(of: statusText))
        status.name = "Status, Cmd+\(modeKey)"
        status.lifetime = .keepAlways
        add(status)
        XCTAssertTrue(gotProbe, "No file probe. Status: \(text(of: statusText))")
        let raw = text(of: probeText)

        let attachment = XCTAttachment(string: raw)
        attachment.name = "Probe, Cmd+\(modeKey)"
        attachment.lifetime = .keepAlways
        add(attachment)

        return Probe(
            raw: raw,
            status: text(of: statusText),
            duration: number(in: raw, after: "Probe → ", until: "s") ?? 0,
            videoTracks: Int(number(in: raw, after: "video tracks=", until: " ") ?? 0),
            fps: number(in: raw, after: "fps=", until: " ") ?? 0,
            hasAudio: !raw.contains("audio: NONE"),
            audioTracks: Int(number(in: raw, after: "audio tracks=", until: " ") ?? 0),
            enabledAudioTracks: Int(number(in: raw, after: "(enabled ", until: ")") ?? 0),
            markerRanges: Int(number(in: raw, after: "marker ranges=", until: " ") ?? 0)
        )
    }

    /// SwiftUI Text on macOS exposes its string as the element value;
    /// fall back to the label.
    private func text(of element: XCUIElement) -> String {
        if let v = element.value as? String, !v.isEmpty { return v }
        return element.label
    }

    private func waitUntil(timeout: TimeInterval, _ condition: () -> Bool) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if condition() { return true }
            RunLoop.current.run(until: Date().addingTimeInterval(0.25))
        }
        return condition()
    }

    private func number(in text: String, after prefix: String, until terminator: Character) -> Double? {
        guard let start = text.range(of: prefix)?.upperBound else { return nil }
        let tail = text[start...]
        let digits = tail.prefix { $0 != terminator }
        return Double(digits.trimmingCharacters(in: .whitespaces))
    }
}
