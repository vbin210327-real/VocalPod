import CoreGraphics
import XCTest

final class NowPlayingUITests: XCTestCase {
    private var app: XCUIApplication!
    private var hasLaunched = false

    override func setUpWithError() throws {
        continueAfterFailure = false
        app = XCUIApplication()
        hasLaunched = false
    }

    override func tearDownWithError() throws {
        guard hasLaunched else { return }
        XCUIDevice.shared.press(.home)
        app.terminate()
        app.launchArguments = ["--ui-testing", "--reset-library"]
        app.launch()
        app.terminate()
    }

    func testControlCenterNextAndPreviousChangeThePlayingTrack() throws {
        #if targetEnvironment(simulator)
        app.launchArguments = ["--ui-testing", "--reset-library", "--seed-audio", "--seed-playlist"]
        hasLaunched = true
        app.launch()
        let rows = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@ AND identifier != %@", "clip.", "clip.menu"))
        let prepared = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in rows.count == 3 }, object: nil)
        XCTAssertEqual(XCTWaiter.wait(for: [prepared], timeout: 10), .completed)
        rows.element(boundBy: 1).tap()
        let title = app.staticTexts["player.title"]
        XCTAssertTrue(title.waitForExistence(timeout: 5))
        XCTAssertEqual(title.label, "测试声音 2")

        try pressControlCenterTrackButton(labels: ["下一首", "下一曲", "Next Track", "Next track"])
        XCTAssertTrue(title.waitForExistence(timeout: 5))
        XCTAssertEqual(title.label, "测试声音 1")

        try pressControlCenterTrackButton(labels: ["上一首", "上一曲", "Previous Track", "Previous track"])
        XCTAssertTrue(title.waitForExistence(timeout: 5))
        XCTAssertEqual(title.label, "测试声音 2")
        #else
        throw XCTSkip("System Now Playing acceptance runs on the simulator only.")
        #endif
    }

    private func pressControlCenterTrackButton(labels: [String]) throws {
        XCUIDevice.shared.press(.home)
        let system = XCUIApplication(bundleIdentifier: "com.apple.springboard")
        let start = system.coordinate(withNormalizedOffset: CGVector(dx: 0.95, dy: 0.01))
        let end = system.coordinate(withNormalizedOffset: CGVector(dx: 0.95, dy: 0.60))
        start.press(forDuration: 0.1, thenDragTo: end)
        let button = system.buttons.matching(NSPredicate(format: "label IN %@", labels)).firstMatch
        if !button.waitForExistence(timeout: 2), system.otherElements["cc-root-folder-view"].exists {
            let controls = Set(system.buttons.allElementsBoundByIndex.map(\.label))
            if !controls.isEmpty, controls.isSubset(of: ["添加控制", "电源", "服务使用中"]) {
                throw XCTSkip("This simulator's Control Center has no media controls. Command registration and actual track playback are covered by TrackNavigationTests.")
            }
        }
        XCTAssertTrue(button.waitForExistence(timeout: 5), "Expected system track command.\n\(system.debugDescription)")
        XCTAssertTrue(button.isEnabled)
        button.tap()
        XCUIDevice.shared.press(.home)
        app.activate()
    }
}
