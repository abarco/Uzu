import XCTest

/// Layer-2 smoke tests (see CLAUDE.md § Testing strategy): these exist to catch
/// "the app crashes / the flow broke", not audio quality. Keep them few and stable.
final class UzuUITests: XCTestCase {

    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    @MainActor
    func testAddAPartFullFlowCreatesTrackRow() throws {
        let app = XCUIApplication()
        app.launch()

        let addPart = app.buttons["Add a part"]
        XCTAssertTrue(addPart.waitForExistence(timeout: 10), "Add a part button should be on screen")
        addPart.tap()

        // Part-name preset picker.
        let guitar = app.buttons["Guitar"]
        XCTAssertTrue(guitar.waitForExistence(timeout: 5), "Name picker should appear")
        guitar.tap()

        // Mic permission alert (first run on a fresh device/clone).
        let springboard = XCUIApplication(bundleIdentifier: "com.apple.springboard")
        let allowButton = springboard.buttons["Allow"]
        if allowButton.waitForExistence(timeout: 3) {
            allowButton.tap()
        }

        // Speaker notice (only appears when existing tracks would be muted —
        // not on the first part, but kept for robustness on re-runs).
        let recordOnSpeaker = app.alerts.buttons["Record"]
        if recordOnSpeaker.waitForExistence(timeout: 3) {
            recordOnSpeaker.tap()
        }
        // Permission alert may come after the warning depending on timing.
        if allowButton.waitForExistence(timeout: 3) {
            allowButton.tap()
        }

        // Count-in (~2.4 s) runs, then the Stop button appears.
        let stopButton = app.buttons["Stop"]
        XCTAssertTrue(
            stopButton.waitForExistence(timeout: 15),
            "App should reach the recording stage (and not have crashed)")

        // Record ~3 seconds of (simulator host mic) audio.
        Thread.sleep(forTimeInterval: 3)
        stopButton.tap()

        // Review stage: Keep the take.
        let keepButton = app.buttons["Keep"]
        XCTAssertTrue(keepButton.waitForExistence(timeout: 10), "Review (Keep/Redo) should appear")
        keepButton.tap()

        let trackRow = app.staticTexts["Guitar"]
        XCTAssertTrue(trackRow.waitForExistence(timeout: 10), "A track row should appear after keeping")

        XCTAssertTrue(app.state == .runningForeground, "App should still be running")
    }
}
