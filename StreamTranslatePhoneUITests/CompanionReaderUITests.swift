import XCTest

/// Offline UI regressions. No microphone, audio capture, model or real Mac
/// pairing. Reset support is compiled only into simulator Debug builds.
@MainActor final class CompanionReaderUITests: XCTestCase {
    private var app: XCUIApplication!

    private func launchCleanApp() {
        continueAfterFailure = false
        app = XCUIApplication()
        app.launchArguments = ["--ui-testing-reset"]
        XCUIDevice.shared.orientation = .portrait
        app.launch()
        XCTAssertTrue(app.staticTexts["pairing-title"].waitForExistence(timeout: 15))
    }

    private func finish() {
        XCUIDevice.shared.orientation = .portrait
        app.terminate()
    }

    func testFirstLaunchDoesNotPretendToBeConnected() {
        launchCleanApp()
        defer { finish() }
        XCTAssertTrue(app.buttons["reader-settings"].exists)
        XCTAssertFalse(app.buttons["pairing-connect"].isEnabled)
        XCTAssertFalse(app.scrollViews["caption-feed"].exists)
        XCTAssertTrue(app.staticTexts["connection-status"].label.contains("配对"))
    }

    func testInvalidLinkStaysUnpairedAndShowsError() {
        launchCleanApp()
        defer { finish() }
        let field = app.textFields["pairing-link"].exists
            ? app.textFields["pairing-link"] : app.textViews["pairing-link"]
        field.tap()
        field.typeText("not-a-valid-pairing-link")
        app.buttons["pairing-connect"].tap()
        XCTAssertTrue(app.staticTexts["pairing-error"].waitForExistence(timeout: 3))
        XCTAssertTrue(app.staticTexts["pairing-title"].exists)
        XCTAssertFalse(app.scrollViews["caption-feed"].exists)
    }

    func testReadingPreferencesPersistAcrossAppRelaunch() {
        launchCleanApp()
        defer { finish() }
        app.buttons["reader-settings"].tap()
        let original = app.switches["reader-show-original"]
        XCTAssertTrue(original.waitForExistence(timeout: 3))
        // SwiftUI exposes the entire labeled row as a Switch. Its center is
        // the label/empty area; tap the actual trailing control instead.
        original.coordinate(withNormalizedOffset: CGVector(dx: 0.92, dy: 0.5)).tap()
        XCTAssertEqual(original.value as? String, "0", "Original toggle must change before testing persistence")
        let awake = app.switches["reader-keep-awake"]
        awake.coordinate(withNormalizedOffset: CGVector(dx: 0.92, dy: 0.5)).tap()
        XCTAssertEqual(awake.value as? String, "0", "Awake toggle must change before testing persistence")
        app.sliders["reader-font-size"].adjust(toNormalizedSliderPosition: 0.8)
        let fontLabel = app.staticTexts["reader-font-label"].label
        XCTAssertNotEqual(fontLabel, "字幕字号：27")
        app.buttons["reader-settings-done"].tap()
        app.terminate()
        app.launchArguments = [] // Preserve this test's preferences on restart.
        app.launch()
        XCTAssertTrue(app.buttons["reader-settings"].waitForExistence(timeout: 10))
        app.buttons["reader-settings"].tap()
        XCTAssertTrue(original.waitForExistence(timeout: 3))
        XCTAssertEqual(original.value as? String, "0")
        XCTAssertEqual(awake.value as? String, "0")
        XCTAssertEqual(app.staticTexts["reader-font-label"].label, fontLabel)
    }

    func testLandscapeKeepsPairingAndSettingsAccessible() {
        launchCleanApp()
        defer { finish() }
        XCUIDevice.shared.orientation = .landscapeLeft
        XCTAssertTrue(app.staticTexts["pairing-title"].waitForExistence(timeout: 3))
        XCTAssertTrue(app.buttons["reader-settings"].isHittable)
        app.buttons["reader-settings"].tap()
        XCTAssertTrue(app.buttons["reader-settings-done"].waitForExistence(timeout: 3))
        app.buttons["reader-settings-done"].tap()
        XCUIDevice.shared.orientation = .portrait
        XCTAssertTrue(app.buttons["reader-settings"].isHittable)
    }

    func testForegroundRestoresInteractiveUnpairedScreen() {
        launchCleanApp()
        defer { finish() }
        XCUIDevice.shared.press(.home)
        app.activate()
        XCTAssertTrue(app.staticTexts["pairing-title"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.buttons["reader-settings"].isHittable)
        XCTAssertFalse(app.otherElements["privacy-cover"].exists)
    }
}
