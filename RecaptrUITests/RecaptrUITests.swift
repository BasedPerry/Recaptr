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
                   "settingsButton", "monitorToggle", "monitorVolume",
                   "mode-window", "mode-screen", "mode-camera"] {
            XCTAssertTrue(element(id, in: app).waitForExistence(timeout: 5),
                          "Missing accessibility identifier \(id)")
        }
    }

    /// Monitor volume is a slider with a value. XCUITest's `adjust` can't drive
    /// a represented slider, so adjusting is checked by hand with VoiceOver.
    @MainActor
    func testMonitorVolumeIsAdjustable() throws {
        let app = launchApp()
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

    // MARK: - Helpers

    @MainActor
    private func launchApp() -> XCUIApplication {
        let app = XCUIApplication()
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
}
