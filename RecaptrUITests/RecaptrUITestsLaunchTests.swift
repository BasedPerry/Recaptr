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

    @MainActor
    private func captureLaunch(style: String) throws {
        let app = XCUIApplication()
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
