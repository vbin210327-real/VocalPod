import XCTest

final class SilenceUITests: XCTestCase {
    private var app: XCUIApplication!
    private var hasLaunched = false

    override func setUpWithError() throws {
        continueAfterFailure = false
        app = XCUIApplication()
        hasLaunched = false
    }

    override func tearDownWithError() throws {
        guard hasLaunched else { app = nil; return }
        app.terminate()
        app.launchArguments = ["--ui-testing", "--reset-library"]
        app.launch()
        app.terminate()
        app = nil
    }

    func testHiddenAutoTrimUsesEffectiveDurationAfterImportAndRelaunch() throws {
        #if targetEnvironment(simulator)
        app.launchArguments = ["--ui-testing", "--reset-library", "--seed-audio"]
        hasLaunched = true
        app.launch()
        openSavedClip()
        try verifyTrimmedPlayback()

        app.terminate()
        app.launchArguments = ["--ui-testing"]
        app.launch()
        openSavedClip()
        try verifyTrimmedPlayback()
        #else
        throw XCTSkip("Silence feature acceptance runs on simulator only.")
        #endif
    }

    private func openSavedClip() {
        let row = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@ AND identifier != %@", "clip.", "clip.menu")).firstMatch
        XCTAssertTrue(row.waitForExistence(timeout: 10))
        row.tap()
        XCTAssertTrue(app.staticTexts["player.title"].waitForExistence(timeout: 5))
    }

    private func verifyTrimmedPlayback() throws {
        expectValue("playing", on: app.buttons["player.play"])
        let durationElement = app.staticTexts["player.duration"]
        XCTAssertTrue(durationElement.waitForExistence(timeout: 3))
        let duration = try XCTUnwrap(Double(durationElement.value as? String ?? ""))
        XCTAssertGreaterThan(duration, 9.5, "Keep the ten-second tone and conservative boundary padding.")
        XCTAssertLessThan(duration, 11, "The one-second silent lead and tail of the twelve-second fixture must be skipped by default.")
        XCTAssertFalse(app.switches["player.autotrim"].exists)
        XCTAssertFalse(app.staticTexts["player.autotrim.status"].exists)
        let progress = app.descendants(matching: .any).matching(identifier: "player.progress").firstMatch
        let advancing = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in
            (Double(progress.value as? String ?? "") ?? 0) > 0.1
        }, object: nil)
        XCTAssertEqual(XCTWaiter.wait(for: [advancing], timeout: 4), .completed)
    }

    private func expectValue(_ value: String, on element: XCUIElement) {
        let expectation = XCTNSPredicateExpectation(predicate: NSPredicate(format: "value == %@", value), object: element)
        XCTAssertEqual(XCTWaiter.wait(for: [expectation], timeout: 5), .completed)
    }
}
