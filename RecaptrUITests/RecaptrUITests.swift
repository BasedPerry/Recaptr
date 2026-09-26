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

    /// Monitor volume reports as a slider (the accessibility role
    /// that carries increment / decrement for VoiceOver) with a
    /// readable value. XCUITest's drag-based `adjust` cannot drive a
    /// represented slider, so the adjustment itself is covered by the
    /// manual VoiceOver pass.
    @MainActor
    func testMonitorVolumeIsAdjustable() throws {
        let app = launchApp()
        let volume = app.sliders["monitorVolume"]
        XCTAssertTrue(volume.waitForExistence(timeout: 5))
        XCTAssertTrue(volume.isEnabled)
        XCTAssertNotNil(volume.value)
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
        app.launchArguments += ["-RecaptrKeepChromeVisible", "YES"]
        app.launch()
        return app
    }

    @MainActor
    private func element(_ id: String, in app: XCUIApplication) -> XCUIElement {
        app.descendants(matching: .any)[id].firstMatch
    }
}
