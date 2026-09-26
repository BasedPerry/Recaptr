//
//  RecaptrUITestsLaunchTests.swift
//  RecaptrUITests
//
//  Launch screenshots in Light and Dark so glass and color
//  regressions show up in test reports. The chrome idle fade is
//  disabled with `-RecaptrKeepChromeVisible YES` so the pills are in
//  the shot.
//

import XCTest

final class RecaptrUITestsLaunchTests: XCTestCase {

    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    @MainActor
    func testLaunchDark() throws {
        try captureLaunch(style: "Dark")
    }

    @MainActor
    func testLaunchLight() throws {
        // Any value other than "Dark" resolves to the light appearance.
        try captureLaunch(style: "Light")
    }

    /// Settings window, opened from the gear, one screenshot per tab
    /// (the window only, not the desktop).
    @MainActor
    func testSettingsScreenshot() throws {
        let app = XCUIApplication()
        app.launchArguments += ["-ApplePersistenceIgnoreState", "YES",
                                "-RecaptrKeepChromeVisible", "YES",
                                "-RecaptrUITesting", "YES"]
        app.launch()
        let gear = app.buttons["settingsButton"]
        XCTAssertTrue(gear.waitForExistence(timeout: 10))
        // Let preview and audio start, as a real session would.
        Thread.sleep(forTimeInterval: 3)
        gear.click()

        let settings = Self.settingsWindow(in: app)
        XCTAssertTrue(settings.waitForExistence(timeout: 5), "Settings window did not open")
        for tab in ["Audio", "Video", "Recording", "Permissions"] {
            settings.toolbars.buttons[tab].click()
            Thread.sleep(forTimeInterval: 0.5)
            let attachment = XCTAttachment(screenshot: settings.screenshot())
            attachment.name = "Launch, Settings \(tab)"
            attachment.lifetime = .keepAlways
            add(attachment)
        }
    }

    static func settingsWindow(in app: XCUIApplication) -> XCUIElement {
        app.windows.matching(NSPredicate(format: "identifier CONTAINS 'Settings'")).firstMatch
    }

    @MainActor
    private func captureLaunch(style: String) throws {
        let app = XCUIApplication()
        // Ignore saved window state so every run starts with the
        // capture window open.
        app.launchArguments += ["-ApplePersistenceIgnoreState", "YES"]
        app.launchArguments += [
            "-AppleInterfaceStyle", style,
            "-RecaptrKeepChromeVisible", "YES",
        ]
        app.launch()

        let window = app.windows.firstMatch
        XCTAssertTrue(window.waitForExistence(timeout: 10))
        XCTAssertTrue(app.buttons["recordButton"].waitForExistence(timeout: 10))

        let attachment = XCTAttachment(screenshot: window.screenshot())
        attachment.name = "Launch, \(style)"
        attachment.lifetime = .keepAlways
        add(attachment)
    }
}
