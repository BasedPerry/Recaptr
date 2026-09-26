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
        // An audio track full of zero-fill is a silent recording. The
        // channel must actually have pushed captured audio.
        if probe.status.contains("push=") {
            XCTAssertGreaterThan(number(in: probe.status, after: "push=", until: " ") ?? 0, 0,
                                 "Audio channel captured nothing: \(probe.status)")
        }
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
        guard probe.status.contains("Mic:[") else {
            throw XCTSkip("Test mic input not available on this Mac")
        }
        for channel in ["Audio:", "Mic:"] {
            let part = probe.status.components(separatedBy: " · ")
                .first { $0.hasPrefix(channel) } ?? ""
            XCTAssertTrue(part.contains("ON"), "\(channel) channel not running: \(part)")
            XCTAssertGreaterThan(number(in: part, after: "push=", until: " ") ?? 0, 0,
                                 "\(channel) channel captured nothing: \(part)")
        }
    }

    // MARK: - Helpers

    struct Probe {
        var raw: String
        var status: String
        var duration: Double
        var videoTracks: Int
        var fps: Double
        var hasAudio: Bool
    }

    @MainActor
    private func record(modeKey: String, seconds: TimeInterval, monitor: Bool = false,
                        extraArgs: [String] = []) throws -> Probe {
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
        // Let the preview settle so the format lock and audio are live.
        Thread.sleep(forTimeInterval: 3)
        if monitor {
            window.typeKey("k", modifierFlags: .command)
            let toggle = app.buttons["monitorToggle"]
            XCTAssertTrue(waitUntil(timeout: 3, { (toggle.value as? String) == "On" }),
                          "Monitor did not switch on")
        }

        window.typeKey("r", modifierFlags: .command)
        Thread.sleep(forTimeInterval: seconds)
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
            hasAudio: !raw.contains("audio: NONE")
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
