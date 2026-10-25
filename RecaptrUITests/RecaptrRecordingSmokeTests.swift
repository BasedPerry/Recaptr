//
//  RecaptrRecordingSmokeTests.swift
//  RecaptrUITests
//
//  End-to-end recording tests, checked with the app's file probe.
//  They need real sources and permissions, and skip when a source is missing.
//

import XCTest

final class RecaptrRecordingSmokeTests: XCTestCase {

    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    @MainActor
    func testScreenRecording() throws {
        // 1440p: 4K60 drops a few frames under the test harness's own load.
        let probe = try record(modeKey: "2", seconds: 6, extraArgs: ["-RecaptrScreenResolution", "qhd"])
        XCTAssertEqual(probe.videoTracks, 1)
        XCTAssertGreaterThan(probe.duration, 4)
        // Constant frame rate even on a still desktop.
        XCTAssertGreaterThanOrEqual(probe.fps, 59, "Screen capture isn't a steady 60: \(probe.raw)")
        XCTAssertTrue(probe.raw.contains("transfer=709"), "Screen capture should be Rec. 709: \(probe.raw)")
        XCTAssertTrue(probe.hasAudio, "Screen capture should carry the system audio track")
    }

    @MainActor
    func testWindowRecording() throws {
        let probe = try record(modeKey: "1", seconds: 6)
        XCTAssertEqual(probe.videoTracks, 1)
        XCTAssertGreaterThanOrEqual(probe.fps, 59, "Window capture isn't a steady 60: \(probe.raw)")
        XCTAssertTrue(probe.raw.contains("transfer=709"), "Window capture should be Rec. 709: \(probe.raw)")
    }

    /// Screen capture without a mic has nothing to monitor.
    @MainActor
    func testScreenMonitorNeedsAMic() throws {
        let app = XCUIApplication()
        app.launchArguments += ["-ApplePersistenceIgnoreState", "YES", "-RecaptrUITesting", "YES",
                                "-RecaptrKeepChromeVisible", "YES", "-RecaptrUITestMicInput", "NoSuchMic"]
        app.launch()
        let window = app.windows.firstMatch
        XCTAssertTrue(window.waitForExistence(timeout: 10))
        window.typeKey("2", modifierFlags: .command)
        let record = app.buttons["recordButton"]
        guard waitUntil(timeout: 8, { record.isEnabled }) else { throw XCTSkip("No screen source") }
        let monitor = app.buttons["monitorToggle"]
        XCTAssertTrue(monitor.waitForExistence(timeout: 5))
        XCTAssertTrue(waitUntil(timeout: 5, { !monitor.isEnabled }), "Monitor should be disabled for screen without a mic")
    }

    /// Edit Names in the after-take card renames the take, and a new
    /// series moves it into that series' folder.
    @MainActor
    func testRenameLastTake() throws {
        let probe = try record(modeKey: "3", seconds: 5, markers: 1,
                               extraArgs: ["-RecaptrUITestSeries", "UITest Series",
                                           "-RecaptrUITestEpisode", "Before"],
                               waitForFiling: true)
        XCTAssertTrue(probe.status.contains("UITest Series – Before"), probe.status)
        let app = XCUIApplication()
        let edit = app.buttons["afterTakeEdit"]
        XCTAssertTrue(edit.waitForExistence(timeout: 10), "No after-take card")
        edit.click()
        for (id, text) in [("afterTakeSeriesField", "UITest Moved"), ("afterTakeEpisodeField", "After")] {
            let field = app.textFields[id]
            XCTAssertTrue(field.waitForExistence(timeout: 5), "No \(id)")
            field.click()
            field.typeKey("a", modifierFlags: .command)
            field.typeText(text)
        }
        app.buttons["afterTakeSave"].click()
        let status = app.staticTexts["statusLine"]
        XCTAssertTrue(waitUntil(timeout: 10, { self.text(of: status).contains("Renamed to UITest Moved – After") }),
                      "Rename didn't happen: \(text(of: status))")
    }

    /// Saving a take brings up the after-take card with its markers;
    /// Edit Names shows a field per marker, and Esc closes the card.
    @MainActor
    func testAfterTakeCardAppears() throws {
        _ = try record(modeKey: "3", seconds: 5, markers: 2,
                       extraArgs: ["-RecaptrUITestSeries", "UITest Series"],
                       waitForFiling: true)
        let app = XCUIApplication()
        let card = app.descendants(matching: .any)["afterTakeCard"].firstMatch
        XCTAssertTrue(card.waitForExistence(timeout: 10), "No after-take card after the take was saved")
        for id in ["afterTakeOpenFinalCut", "afterTakeShowInFinder", "afterTakeEdit", "afterTakeClose"] {
            XCTAssertTrue(app.buttons[id].exists, "Missing \(id)")
        }
        XCTAssertTrue(app.buttons["afterTakeOpenFinalCut"].isEnabled, "A take with markers should open in Final Cut")
        app.buttons["afterTakeEdit"].click()
        XCTAssertTrue(app.textFields["afterTakeMarker1"].waitForExistence(timeout: 3), "No field for the second marker")
        app.buttons["afterTakeCancel"].click()
        app.typeKey(.escape, modifierFlags: [])
        XCTAssertTrue(waitUntil(timeout: 5, { !card.exists }), "Esc didn't close the card")
    }

    /// A take with a series and episode is filed in the series folder.
    @MainActor
    func testSeriesRecordingIsFiled() throws {
        let probe = try record(modeKey: "3", seconds: 6, markers: 1,
                               extraArgs: ["-RecaptrUITestSeries", "UITest Series",
                                           "-RecaptrUITestEpisode", "Smoke"],
                               waitForFiling: true)
        XCTAssertTrue(probe.status.contains("Saved as UITest Series/UITest Series – Smoke"),
                      "Not filed under the series: \(probe.status)")
        XCTAssertEqual(probe.markers, 1)
    }

    @MainActor
    func testCameraRecording() throws {
        let probe = try record(modeKey: "3", seconds: 6)
        XCTAssertEqual(probe.videoTracks, 1)
        XCTAssertGreaterThan(probe.duration, 4)
        // Below 30 means the format lock regressed.
        XCTAssertGreaterThanOrEqual(probe.fps, 29)
        XCTAssertEqual(probe.audioTracks, 1, "Single source should write one audio track")
        XCTAssertEqual(probe.markers, 0, "No markers dropped")
        XCTAssertTrue(probe.raw.contains("transfer=709"), "Video should be tagged Rec. 709: \(probe.raw)")
        // A track of zero-fill is silent, so check audio was actually pushed.
        if probe.status.contains("push=") {
            XCTAssertGreaterThan(number(in: probe.status, after: "push=", until: " ") ?? 0, 0,
                                 "Audio channel captured nothing: \(probe.status)")
        }
    }

    /// Two markers land in the .fcpxml without costing frames.
    @MainActor
    func testCameraRecordingWithMarkers() throws {
        let probe = try record(modeKey: "3", seconds: 6, markers: 2)
        XCTAssertGreaterThanOrEqual(probe.fps, 29)
        XCTAssertEqual(probe.markers, 2, "Expected 2 markers: \(probe.raw)")
        XCTAssertTrue(probe.raw.contains(".fcpxml"), "Expected a Final Cut marker file: \(probe.raw)")
    }

    /// Each encoding preset records 60 fps in the right codec.
    @MainActor
    func testCameraRecordingPresets() throws {
        for (preset, codec) in [("high", "hevc"), ("compatible", "h264")] {
            let probe = try record(modeKey: "3", seconds: 6,
                                   extraArgs: ["-RecaptrVideoQuality", preset])
            XCTAssertGreaterThanOrEqual(probe.fps, 59, "\(preset): \(probe.raw)")
            XCTAssertTrue(probe.raw.contains("video \(codec)"), "\(preset) should be \(codec): \(probe.raw)")
            XCTAssertTrue(probe.raw.contains("transfer=709"), "\(preset) should be Rec. 709: \(probe.raw)")
        }
    }

    /// A mic picked in the sidebar during preview gets recorded on its own track.
    @MainActor
    func testMicChosenInSidebarIsRecorded() throws {
        let probe = try record(modeKey: "3", seconds: 6) { app in
            Thread.sleep(forTimeInterval: 2)
            let toggle = app.buttons["sidebarToggle"]
            toggle.click()
            // Outside a Form the picker may not be a pop-up button.
            let picker = app.descendants(matching: .any)["micDevicePicker"].firstMatch
            XCTAssertTrue(picker.waitForExistence(timeout: 5))
            XCTAssertTrue(picker.isEnabled, "Mic picker is disabled during preview")
            picker.click()
            let item = app.menuItems["Jump Desktop Microphone"]
            guard item.waitForExistence(timeout: 3) else {
                app.typeKey(.escape, modifierFlags: [])
                throw XCTSkip("Test mic input not available on this Mac")
            }
            item.click()
            toggle.click()
        }
        try assertChannelsCaptured(["Audio:", "Mic:"], in: probe)
        assertSourceTracks(probe)
    }

    /// Capture recovers when macOS stops the engine and posts a configuration change.
    @MainActor
    func testAudioRecoversFromHardwareChange() throws {
        try assertAudioRecovers(mode: "notify")
    }

    /// The watchdog recovers when the engine stops with no notification.
    @MainActor
    func testAudioRecoversFromSilentStall() throws {
        try assertAudioRecovers(mode: "silent")
    }

    @MainActor
    private func assertAudioRecovers(mode: String) throws {
        let probe = try record(modeKey: "3", seconds: 8,
                               extraArgs: ["-RecaptrUITestSimulateAudioReset", mode])
        let part = probe.status.components(separatedBy: " · ").first { $0.hasPrefix("Audio:") } ?? ""
        XCTAssertTrue(part.contains("recovered="), "No recovery happened: \(part)")
        // A dead channel would stop pushing at the 6 s mark.
        let pushed = number(in: part, after: "push=", until: " ") ?? 0
        let pulled = number(in: part, after: "pull=", until: " ") ?? 1
        XCTAssertGreaterThan(pushed / pulled, 0.85, "Audio stopped after the reset: \(part)")
    }

    /// Camera plus mic. The Jump Desktop virtual mic delivers silence,
    /// which is enough to prove both channels capture.
    @MainActor
    func testCameraRecordingWithMic() throws {
        let probe = try record(modeKey: "3", seconds: 6,
                               extraArgs: ["-RecaptrUITestMicInput", "Jump Desktop Microphone"])
        XCTAssertGreaterThanOrEqual(probe.fps, 29)
        try assertChannelsCaptured(["Audio:", "Mic:"], in: probe)
        assertSourceTracks(probe)
    }

    /// Screen capture with system audio and a mic.
    @MainActor
    func testScreenRecordingWithMic() throws {
        let probe = try record(modeKey: "2", seconds: 6,
                               extraArgs: ["-RecaptrUITestMicInput", "Jump Desktop Microphone"])
        XCTAssertEqual(probe.videoTracks, 1)
        XCTAssertTrue(probe.hasAudio)
        try assertChannelsCaptured(["System:", "Mic:"], in: probe)
        assertSourceTracks(probe)
    }

    /// One enabled track per source and no mix track; players sum them.
    private func assertSourceTracks(_ probe: Probe) {
        XCTAssertEqual(probe.audioTracks, 2, "Expected one track per source: \(probe.raw)")
        XCTAssertEqual(probe.enabledAudioTracks, 2, "Every source track should be enabled: \(probe.raw)")
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

    /// Shift-Cmd-R during preview saves the last few seconds.
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

    /// Mid-take, once the controls hide, the pill shows; clicking it
    /// brings the controls back. Dragging it to an edge is checked by hand:
    /// XCUITest's synthesized drags don't reach SwiftUI drag gestures here.
    @MainActor
    func testPillBringsBackTheControls() throws {
        let app = XCUIApplication()
        // No KeepChromeVisible: the pill only shows once the controls hide.
        app.launchArguments += ["-ApplePersistenceIgnoreState", "YES", "-RecaptrUITesting", "YES",
                                "-RecaptrVideoQuality", "standard"]
        app.launch()
        let window = app.windows.firstMatch
        XCTAssertTrue(window.waitForExistence(timeout: 10))
        window.typeKey("3", modifierFlags: .command)
        let record = app.buttons["recordButton"]
        guard waitUntil(timeout: 8, { record.isEnabled }) else { throw XCTSkip("No capture card") }
        Thread.sleep(forTimeInterval: 3)
        window.typeKey("r", modifierFlags: .command)

        let pill = app.descendants(matching: .any)["telemetryPill"].firstMatch
        XCTAssertTrue(pill.waitForExistence(timeout: 12), "No recording pill once the controls hid")
        attachScreenshot(app, "Pill")
        XCTAssertFalse(record.isHittable, "Controls still showing with the pill")
        pill.click()
        XCTAssertTrue(waitUntil(timeout: 5, { record.isHittable }), "Clicking the pill didn't bring the controls back")
        window.typeKey("r", modifierFlags: .command)
    }

    /// "I'll name them": ⌘B in the window opens a title field; the typed
    /// title becomes the marker's name in the saved take.
    @MainActor
    func testTitleMarkerAsItDrops() throws {
        let app = XCUIApplication()
        app.launchArguments += ["-ApplePersistenceIgnoreState", "YES", "-RecaptrUITesting", "YES",
                                "-RecaptrKeepChromeVisible", "YES", "-RecaptrVideoQuality", "standard",
                                "-RecaptrMarkerNaming", "manual",
                                "-RecaptrUITestSeries", "UITest Series", "-RecaptrUITestEpisode", "Titled"]
        app.launch()
        let window = app.windows.firstMatch
        XCTAssertTrue(window.waitForExistence(timeout: 10))
        window.typeKey("3", modifierFlags: .command)
        let record = app.buttons["recordButton"]
        guard waitUntil(timeout: 8, { record.isEnabled }) else { throw XCTSkip("No capture card") }
        Thread.sleep(forTimeInterval: 3)
        window.typeKey("r", modifierFlags: .command)
        Thread.sleep(forTimeInterval: 2)
        window.typeKey("b", modifierFlags: .command)

        let field = app.textFields["markerTitleField"]
        XCTAssertTrue(field.waitForExistence(timeout: 3), "No title field after ⌘B")
        field.typeText("Boss fight\r")
        XCTAssertTrue(waitUntil(timeout: 3, { !field.exists }), "Return didn't close the field")
        Thread.sleep(forTimeInterval: 2)
        window.typeKey("r", modifierFlags: .command)

        // The card opens ready to edit in this mode, with the title filled in.
        let first = app.textFields["afterTakeMarker0"]
        XCTAssertTrue(first.waitForExistence(timeout: 20), "No after-take card with the marker")
        XCTAssertEqual(first.value as? String, "Boss fight")
    }

    /// A take that can't start shows a banner with what to do and a fix
    /// button, and records nothing.
    @MainActor
    func testNotEnoughSpaceBanner() throws {
        let app = XCUIApplication()
        app.launchArguments += ["-ApplePersistenceIgnoreState", "YES", "-RecaptrUITesting", "YES",
                                "-RecaptrKeepChromeVisible", "YES", "-RecaptrUITestStartBelowGB", "1000000"]
        app.launch()
        let window = app.windows.firstMatch
        XCTAssertTrue(window.waitForExistence(timeout: 10))
        window.typeKey("3", modifierFlags: .command)
        let record = app.buttons["recordButton"]
        guard waitUntil(timeout: 8, { record.isEnabled }) else { throw XCTSkip("No capture card") }
        window.typeKey("r", modifierFlags: .command)

        let banner = app.descendants(matching: .any)["noticeBanner"].firstMatch
        XCTAssertTrue(banner.waitForExistence(timeout: 5), "No banner when the take can't start")
        let message = app.staticTexts.containing(NSPredicate(format: "value CONTAINS %@ OR label CONTAINS %@",
                                                             "isn't enough space", "isn't enough space")).firstMatch
        XCTAssertTrue(message.exists, "Banner doesn't say why")
        XCTAssertEqual(app.buttons["noticeFix"].label, "Choose Folder")
        XCTAssertEqual(record.label, "Start Recording", "A take started anyway")
        app.buttons["noticeClose"].click()
        XCTAssertTrue(waitUntil(timeout: 3, { !banner.exists }), "Close didn't dismiss the banner")
    }

    /// Switching the after-take card from a take with markers to one with
    /// fewer, while its name fields are showing ("I'll name them"), used to
    /// crash on an out-of-range marker title.
    @MainActor
    func testSwitchingCardToTakeWithFewerMarkers() throws {
        let app = XCUIApplication()
        app.launchArguments += ["-ApplePersistenceIgnoreState", "YES", "-RecaptrUITesting", "YES",
                                "-RecaptrKeepChromeVisible", "YES", "-RecaptrVideoQuality", "standard",
                                "-RecaptrCaptureResolution", "fhd", "-RecaptrMarkerNaming", "manual",
                                "-RecaptrUITestSeries", "UITest Cards"]
        app.launch()
        let window = app.windows.firstMatch
        XCTAssertTrue(window.waitForExistence(timeout: 10))
        window.typeKey("3", modifierFlags: .command)
        let record = app.buttons["recordButton"]
        guard waitUntil(timeout: 8, { record.isEnabled }) else { throw XCTSkip("No capture card") }
        Thread.sleep(forTimeInterval: 3)

        // Older take: no markers.
        window.typeKey("r", modifierFlags: .command)
        Thread.sleep(forTimeInterval: 3)
        window.typeKey("r", modifierFlags: .command)
        let card = app.descendants(matching: .any)["afterTakeCard"].firstMatch
        XCTAssertTrue(card.waitForExistence(timeout: 20), "No card for the older take")

        // Newest take: two markers, dropped from the menu so no title field
        // opens mid-take. Its card opens with a name field per marker.
        window.typeKey("r", modifierFlags: .command)
        for _ in 0..<2 {
            Thread.sleep(forTimeInterval: 2)
            app.menuBars.menuBarItems["Recording"].click()
            app.menuBars.menuItems["Drop Marker"].click()
        }
        Thread.sleep(forTimeInterval: 2)
        window.typeKey("r", modifierFlags: .command)
        XCTAssertTrue(app.textFields["afterTakeMarker1"].waitForExistence(timeout: 20),
                      "The newest take's card didn't open with its name fields")

        // With those fields showing, open the older take (second in the list).
        app.menuBars.menuBarItems["File"].click()
        app.menuBars.menuItems["Recent Recordings"].click()
        let entries = app.menuBars.menuItems.matching(NSPredicate(format: "title BEGINSWITH %@", "UITest Cards"))
        XCTAssertGreaterThan(entries.count, 1, "Recent Recordings is missing the older take")
        entries.element(boundBy: 1).click()
        Thread.sleep(forTimeInterval: 1.5)
        XCTAssertEqual(app.state, .runningForeground, "Recaptr quit opening the older take")
        XCTAssertTrue(card.exists, "Card gone after switching takes")
        XCTAssertFalse(app.textFields["afterTakeMarker1"].exists, "Take A's second field is still showing on take B")
    }

    /// Closing the window when not recording quits, so the capture card
    /// isn't held with nothing on screen.
    @MainActor
    func testClosingWindowQuits() throws {
        let app = XCUIApplication()
        app.launchArguments += ["-ApplePersistenceIgnoreState", "YES", "-RecaptrUITesting", "YES",
                                "-RecaptrKeepChromeVisible", "YES"]
        app.launch()
        let window = app.windows.firstMatch
        XCTAssertTrue(window.waitForExistence(timeout: 10))
        Thread.sleep(forTimeInterval: 3)
        window.buttons[XCUIIdentifierCloseWindow].click()
        XCTAssertTrue(app.wait(for: .notRunning, timeout: 15), "Recaptr kept running after its window closed")
    }

    /// Closing the capture window quits even with Settings still open.
    @MainActor
    func testClosingWindowWithSettingsOpenQuits() throws {
        let app = XCUIApplication()
        app.launchArguments += ["-ApplePersistenceIgnoreState", "YES", "-RecaptrUITesting", "YES",
                                "-RecaptrKeepChromeVisible", "YES"]
        app.launch()
        let window = app.windows.matching(NSPredicate(format: "identifier BEGINSWITH 'main'")).firstMatch
        XCTAssertTrue(window.waitForExistence(timeout: 10))
        Thread.sleep(forTimeInterval: 2)
        app.typeKey(",", modifierFlags: .command)
        XCTAssertTrue(waitUntil(timeout: 5, { app.windows.count >= 2 }), "Settings didn't open")
        window.buttons[XCUIIdentifierCloseWindow].click()
        XCTAssertTrue(app.wait(for: .notRunning, timeout: 15), "Recaptr kept running with only Settings open")
    }

    /// Closing the window mid-take keeps the take going; stopping it brings
    /// the window back with the after-take card.
    @MainActor
    func testClosingWindowMidTakeKeepsRecording() throws {
        let app = XCUIApplication()
        app.launchArguments += ["-ApplePersistenceIgnoreState", "YES", "-RecaptrUITesting", "YES",
                                "-RecaptrKeepChromeVisible", "YES", "-RecaptrVideoQuality", "standard",
                                "-RecaptrCaptureResolution", "fhd"]
        app.launch()
        let window = app.windows.firstMatch
        XCTAssertTrue(window.waitForExistence(timeout: 10))
        window.typeKey("3", modifierFlags: .command)
        let record = app.buttons["recordButton"]
        guard waitUntil(timeout: 8, { record.isEnabled }) else { throw XCTSkip("No capture card") }
        Thread.sleep(forTimeInterval: 3)
        window.typeKey("r", modifierFlags: .command)
        Thread.sleep(forTimeInterval: 3)

        window.buttons[XCUIIdentifierCloseWindow].click()
        Thread.sleep(forTimeInterval: 4)
        XCTAssertEqual(app.state, .runningForeground, "Closing the window mid-take quit Recaptr")
        XCTAssertEqual(app.menuBars.menuItems["Stop Recording"].exists, true, "The take didn't keep going")

        app.menuBars.menuBarItems["Recording"].click()
        app.menuBars.menuItems["Stop Recording"].click()
        let card = app.descendants(matching: .any)["afterTakeCard"].firstMatch
        XCTAssertTrue(card.waitForExistence(timeout: 20), "The window didn't come back with the card")
        let probe = app.staticTexts["lastProbe"]
        XCTAssertTrue(waitUntil(timeout: 20, { self.text(of: probe).hasPrefix("Probe →") }))
        let seconds = number(in: text(of: probe), after: "Probe → ", until: "s") ?? 0
        XCTAssertGreaterThan(seconds, 6, "The take stopped when the window closed: \(text(of: probe))")
    }

    private func attachScreenshot(_ app: XCUIApplication, _ name: String) {
        let shot = XCTAttachment(screenshot: app.windows.firstMatch.screenshot())
        shot.name = name
        shot.lifetime = .keepAlways
        add(shot)
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
        var markers: Int
    }

    @MainActor
    private func record(modeKey: String, seconds: TimeInterval, monitor: Bool = false,
                        markers: Int = 0, extraArgs: [String] = [], waitForFiling: Bool = false,
                        beforeRecording: ((XCUIApplication) throws -> Void)? = nil) throws -> Probe {
        let app = XCUIApplication()
        // Start with the capture window open, not restored state.
        app.launchArguments += ["-ApplePersistenceIgnoreState", "YES"]
        app.launchArguments += ["-RecaptrUITesting", "YES",
                                "-RecaptrKeepChromeVisible", "YES"] + extraArgs
        // TEST_RUNNER_RECAPTR_EXTRA_ARGS on the xcodebuild line adds launch arguments.
        if let extra = ProcessInfo.processInfo.environment["RECAPTR_EXTRA_ARGS"] {
            app.launchArguments += extra.split(separator: " ").map(String.init)
        }
        // Don't inherit the user's saved quality or marker naming (in "I'll
        // name them" the card opens ready to edit, without its buttons).
        if !app.launchArguments.contains("-RecaptrVideoQuality") {
            app.launchArguments += ["-RecaptrVideoQuality", "standard"]
        }
        if !app.launchArguments.contains("-RecaptrMarkerNaming") {
            app.launchArguments += ["-RecaptrMarkerNaming", "numbered"]
        }
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
        // Spread markers evenly through the take.
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
        if markers > 0 || waitForFiling {
            // The .fcpxml appears after marker naming, which can be slow.
            _ = waitUntil(timeout: 60, { text(of: probeText).contains(".fcpxml") })
        }
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
            markers: Int(number(in: raw, after: "markers=", until: " ") ?? 0)
        )
    }

    /// SwiftUI Text on macOS puts its string in the value, not the label.
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
