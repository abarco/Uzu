import XCTest

/// Layer-2 smoke tests (see CLAUDE.md § Testing strategy): these exist to catch
/// "the app crashes / the flow broke", not audio quality. Keep them few and stable.
final class UzuUITests: XCTestCase {

    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    @MainActor
    func testRecordAPartCreatesTrackRow() throws {
        let app = XCUIApplication()
        app.launch()

        let recordButton = app.buttons["Record a part"]
        XCTAssertTrue(recordButton.waitForExistence(timeout: 10), "Record button should be on screen")
        recordButton.tap()

        // First run triggers the mic permission alert; accept it.
        let springboard = XCUIApplication(bundleIdentifier: "com.apple.springboard")
        let allowButton = springboard.buttons["Allow"]
        if allowButton.waitForExistence(timeout: 5) {
            allowButton.tap()
        }

        // If the app survived engine start, the button flips to "Stop".
        let stopButton = app.buttons["Stop"]
        XCTAssertTrue(stopButton.waitForExistence(timeout: 10), "App should be recording (and not have crashed)")

        // Record ~3 seconds of (simulator host mic) audio.
        Thread.sleep(forTimeInterval: 3)
        stopButton.tap()

        let trackRow = app.staticTexts["Part 1"]
        XCTAssertTrue(trackRow.waitForExistence(timeout: 10), "A track row should appear after stopping")

        XCTAssertTrue(app.state == .runningForeground, "App should still be running")
    }
}
