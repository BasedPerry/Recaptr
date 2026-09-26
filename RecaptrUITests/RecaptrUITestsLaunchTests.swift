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
        for tab in ["Recording", "Permissions"] {
            settings.toolbars.buttons[tab].click()
            Thread.sleep(forTimeInterval: 0.5)
            let attachment = XCTAttachment(screenshot: settings.screenshot())
            attachment.name = "Launch, Settings \(tab)"
            attachment.lifetime = .keepAlways
            add(attachment)
        }
    }

    /// Audio pill with a mic armed, resting and hovered (numbers
    /// only appear on hover).
    @MainActor
    func testAudioPillScreenshot() throws {
        let app = XCUIApplication()
        app.launchArguments += ["-ApplePersistenceIgnoreState", "YES",
                                "-RecaptrKeepChromeVisible", "YES",
                                "-RecaptrUITesting", "YES",
                                "-RecaptrUITestMicInput", "Jump Desktop Microphone"]
        app.launch()
        let pill = app.descendants(matching: .any)["audioPill"].firstMatch
        XCTAssertTrue(pill.waitForExistence(timeout: 10))
        Thread.sleep(forTimeInterval: 4)
        XCTAssertTrue(app.descendants(matching: .any)["micLevel"].exists, "Mic meter missing with a mic armed")
        for (name, hover) in [("resting", false), ("hover", true)] {
            if hover { pill.hover(); Thread.sleep(forTimeInterval: 0.5) }
            let shot = XCTAttachment(screenshot: pill.screenshot())
            shot.name = "Launch, Pill \(name)"
            shot.lifetime = .keepAlways
            add(shot)
        }
    }

    /// Main window with the source sidebar open (Elgato selected,
    /// camera tuning showing).
    @MainActor
    func testSidebarScreenshot() throws {
        let app = XCUIApplication()
        app.launchArguments += ["-ApplePersistenceIgnoreState", "YES",
                                "-RecaptrKeepChromeVisible", "YES",
                                "-RecaptrUITesting", "YES"]
        app.launch()
        let toggle = app.buttons["sidebarToggle"]
        XCTAssertTrue(toggle.waitForExistence(timeout: 10))
        Thread.sleep(forTimeInterval: 3)
        func capture(_ name: String) {
            let shot = XCTAttachment(screenshot: app.windows.firstMatch.screenshot())
            shot.name = "Launch, Sidebar \(name)"
            shot.lifetime = .keepAlways
            add(shot)
        }
        // Before / open / closed again: the preview must survive the
        // sidebar moving it around.
        capture("1 before")
        toggle.click()
        XCTAssertTrue(app.descendants(matching: .any)["sourceSidebar"].waitForExistence(timeout: 5))
        Thread.sleep(forTimeInterval: 1.5)
        capture("2 open")
        // Switch type from the sidebar's own switcher.
        app.buttons["mode-screen"].click()
        Thread.sleep(forTimeInterval: 2)
        capture("2b screen")
        app.buttons["mode-camera"].click()
        Thread.sleep(forTimeInterval: 2)
        toggle.click()
        Thread.sleep(forTimeInterval: 1.5)
        capture("3 closed")
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
