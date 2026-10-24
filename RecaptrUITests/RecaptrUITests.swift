//
//  RecaptrUITests.swift
//  RecaptrUITests
//

import XCTest

final class RecaptrUITests: XCTestCase {

    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    /// Every floating control is reachable by accessibility identifier.
    @MainActor
    func testChromeControlsAreReachable() throws {
        let app = launchApp()
        for id in ["recordButton", "screenshotButton", "markerButton",
                   "settingsButton", "monitorToggle", "gameChannel", "micChannel",
                   "mode-window", "mode-screen", "mode-camera"] {
            XCTAssertTrue(element(id, in: app).waitForExistence(timeout: 5),
                          "Missing accessibility identifier \(id)")
        }
    }

    /// Headphone volume lives in a channel's popover in the bottom bar.
    @MainActor
    func testMonitorVolumeIsAdjustable() throws {
        let app = launchApp()
        let channel = element("gameChannel", in: app)
        XCTAssertTrue(channel.waitForExistence(timeout: 5))
        channel.click()
        let volume = app.sliders["monitorVolume"]
        XCTAssertTrue(volume.waitForExistence(timeout: 5))
        XCTAssertTrue(volume.isEnabled)
        XCTAssertNotNil(volume.value)
    }

    /// Typing a series shows the next recording's save name.
    @MainActor
    func testSeriesFieldShowsSaveName() throws {
        let app = launchApp()
        element("sidebarToggle", in: app).click()
        let series = app.textFields["seriesField"]
        XCTAssertTrue(series.waitForExistence(timeout: 5))
        series.click()
        // Clear the user's saved series first.
        series.typeKey("a", modifierFlags: .command)
        series.typeText("UITest Series")
        let episode = app.textFields["episodeField"]
        XCTAssertTrue(episode.isEnabled, "Episode stays disabled with a series set")
        episode.click()
        episode.typeText("Pilot")
        let note = app.staticTexts.containing(NSPredicate(format: "value CONTAINS %@ OR label CONTAINS %@",
                                                          "UITest Series – Pilot.mov", "UITest Series – Pilot.mov")).firstMatch
        XCTAssertTrue(note.waitForExistence(timeout: 3), "Save-name note didn't update")
    }

    @MainActor
    func testLaunchPerformance() throws {
        measure(metrics: [XCTApplicationLaunchMetric()]) {
            XCUIApplication().launch()
        }
    }

    /// Onboarding walks four steps and can't finish until a naming mode
    /// is picked. Test copies never save the choice.
    @MainActor
    func testOnboardingSteps() throws {
        let app = launchApp(["-RecaptrUITestShowWelcome", "YES", "-RecaptrMarkerNaming", ""])
        let sheet = element("welcomeSheet", in: app)
        XCTAssertTrue(sheet.waitForExistence(timeout: 5), "No onboarding")
        element("welcomeSource-screen", in: app).click()
        for _ in 0..<3 { app.buttons["welcomeContinue"].click() }
        let done = app.buttons["welcomeDone"]
        XCTAssertTrue(done.waitForExistence(timeout: 3))
        XCTAssertFalse(done.isEnabled, "Done should wait for a naming choice")
        element("naming-numbered", in: app).click()
        XCTAssertTrue(waitUntil(timeout: 2, { done.isEnabled }))
        done.click()
        XCTAssertTrue(waitUntil(timeout: 5, { !sheet.exists }), "Onboarding didn't close")
    }

    /// People coming from 1.0 see What's new with naming already filled in.
    @MainActor
    func testWhatsNewSheet() throws {
        let app = launchApp(["-RecaptrUITestShowWhatsNew", "YES"])
        let sheet = element("whatsNewSheet", in: app)
        XCTAssertTrue(sheet.waitForExistence(timeout: 5), "No What's new sheet")
        let done = app.buttons["whatsNewDone"]
        XCTAssertTrue(done.isEnabled, "Naming should be pre-filled")
        done.click()
        XCTAssertTrue(waitUntil(timeout: 5, { !sheet.exists }))
    }

    // MARK: - Helpers

    @MainActor
    private func launchApp(_ extra: [String] = []) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments += extra
        // Start with the capture window open, not restored state.
        app.launchArguments += ["-ApplePersistenceIgnoreState", "YES"]
        // Testing mode keeps typed names out of the user's settings.
        app.launchArguments += ["-RecaptrUITesting", "YES", "-RecaptrKeepChromeVisible", "YES"]
        app.launch()
        return app
    }

    @MainActor
    private func element(_ id: String, in app: XCUIApplication) -> XCUIElement {
        app.descendants(matching: .any)[id].firstMatch
    }

    private func waitUntil(timeout: TimeInterval, _ condition: () -> Bool) -> Bool {
        let end = Date().addingTimeInterval(timeout)
        while Date() < end {
            if condition() { return true }
            RunLoop.current.run(until: Date().addingTimeInterval(0.1))
        }
        return condition()
    }
}
