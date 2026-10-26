import CoreGraphics
import XCTest

final class VocalPodUITests: XCTestCase {
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
        // Test audio lives in its own DEBUG-only library; leave that library empty.
        app.launchArguments = ["--ui-testing", "--reset-library"]
        app.launch()
        app.terminate()
        app = nil
    }

    func testEmptyLibraryOffersPhotosAndFilesImport() {
        launch(seed: false)
        XCTAssertTrue(app.staticTexts["library.empty"].waitForExistence(timeout: 5))
        let importButton = app.buttons["import.button"]
        XCTAssertEqual(importButton.frame.midY, app.staticTexts["声音库"].frame.midY, accuracy: 6)
        XCTAssertLessThanOrEqual(importButton.frame.width, 100)
        XCTAssertEqual(app.buttons.matching(identifier: "import.button").count, 1)
        importButton.tap()
        XCTAssertTrue(app.buttons["import.photos"].waitForExistence(timeout: 3))
        XCTAssertTrue(app.buttons["import.files"].exists)
    }

    /// Prepare the generated 1.5-second movie in simulator Photos before this integration check.
    func testPhotosPickerImportsVideo() throws {
        #if targetEnvironment(simulator)
        guard FileManager.default.fileExists(atPath: "/private/tmp/VocalPod-verification.mov") else {
            throw XCTSkip("Prepare 1.5s generated movie in simulator Photos first.")
        }
        launch(seed: false)
        XCTAssertTrue(app.staticTexts["library.empty"].waitForExistence(timeout: 5))
        app.buttons["import.button"].tap()
        app.buttons["import.photos"].tap()

        let videoLabel = NSPredicate(format: "label BEGINSWITH[c] %@ OR label BEGINSWITH %@", "Video", "视频")
        let videoImage = app.images.matching(identifier: "PXGGridLayout-Info").matching(videoLabel).firstMatch
        XCTAssertTrue(videoImage.waitForExistence(timeout: 10),
                      "The system picker must show the generated verification video.\n\(app.debugDescription)")
        // Photos exposes virtual thumbnail images without a native hit point.
        // Tap the center of the verified asset's accessibility frame.
        videoImage.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).tap()

        let title = app.staticTexts["player.title"]
        XCTAssertTrue(title.waitForExistence(timeout: 15), "A selected video must finish extraction and open the player.")
        XCTAssertTrue(title.label.hasPrefix("录屏"))
        let importedTitle = title.label
        let importedLayout = XCTAttachment(screenshot: app.screenshot())
        importedLayout.name = "Player-AfterPhotosImport"
        importedLayout.lifetime = .keepAlways
        add(importedLayout)
        let close = app.buttons["player.close"]
        XCTAssertTrue(close.waitForExistence(timeout: 3))
        XCTAssertGreaterThanOrEqual(close.frame.minY, app.windows.firstMatch.frame.minY + 54,
                                    "Imported player controls must stay below the status bar and Dynamic Island.")
        XCTAssertLessThanOrEqual(close.frame.minY, app.windows.firstMatch.frame.minY + 80,
                                 "Safe-area recovery must not add a second top inset.")
        XCTAssertGreaterThanOrEqual(title.frame.minY, close.frame.maxY + 8)
        let importedCloseY = close.frame.minY
        expectValue("playing", on: app.buttons["player.play"])
        app.buttons["player.close"].tap()
        XCTAssertTrue(seedRow.waitForExistence(timeout: 5))
        XCTAssertTrue(seedRow.label.contains("0:01"), "The saved clip must retain the generated 1.5-second movie's duration.")
        XCTAssertEqual(app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@ AND identifier != %@", "clip.", "clip.menu")).count, 1)

        app.terminate()
        app.launchArguments = ["--ui-testing"]
        app.launch()
        XCTAssertTrue(seedRow.waitForExistence(timeout: 5))
        seedRow.tap()
        XCTAssertTrue(title.waitForExistence(timeout: 5))
        XCTAssertEqual(title.label, importedTitle)
        XCTAssertGreaterThanOrEqual(app.buttons["player.close"].frame.minY, app.windows.firstMatch.frame.minY + 54,
                                    "Reopening imported audio must retain the same safe-area layout.")
        XCTAssertEqual(app.buttons["player.close"].frame.minY, importedCloseY, accuracy: 1,
                       "Import and ordinary reopen must use identical top spacing.")
        expectValue("playing", on: app.buttons["player.play"])
        let progress = playerProgress
        let audioAdvances = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in
            (Double(progress.value as? String ?? "") ?? 0) > 0.1
        }, object: nil)
        XCTAssertEqual(XCTWaiter.wait(for: [audioAdvances], timeout: 5), .completed,
                       "The audio saved by the Photos import must play again after relaunch.")
        #else
        throw XCTSkip("Fixture import workflow verified on simulator only.")
        #endif
    }

    func testPlayerPauseCustomSpeedAndLoopControls() {
        launch(seed: true)
        openSeededPlayer()
        let play = app.buttons["player.play"]
        expectValue("playing", on: play)
        reveal(play)
        play.tap()
        expectValue("paused", on: play)

        let loop = app.buttons["player.loop"]
        reveal(loop)
        expectValue("单曲循环", on: loop)
        let repeatImage = XCTAttachment(screenshot: app.screenshot())
        repeatImage.name = "Player-RepeatOne"
        repeatImage.lifetime = .keepAlways
        add(repeatImage)
        loop.tap()
        expectValue("顺序播放", on: loop)
        let sequentialImage = XCTAttachment(screenshot: app.screenshot())
        sequentialImage.name = "Player-Sequential"
        sequentialImage.lifetime = .keepAlways
        add(sequentialImage)
        loop.tap()
        expectValue("随机循环", on: loop)
        let shuffleImage = XCTAttachment(screenshot: app.screenshot())
        shuffleImage.name = "Player-Shuffle"
        shuffleImage.lifetime = .keepAlways
        add(shuffleImage)
        loop.tap()
        expectValue("单曲循环", on: loop)

        let speed = app.buttons["player.speed"]
        reveal(speed)
        speed.tap()
        let custom = app.textFields["speed.custom"]
        XCTAssertTrue(custom.waitForExistence(timeout: 3))
        custom.tap()
        custom.typeText("1.65")
        app.buttons["speed.apply"].tap()
        XCTAssertTrue(custom.waitForNonExistence(timeout: 3))
        XCTAssertTrue(speed.waitForExistence(timeout: 3))
        XCTAssertTrue((speed.value as? String ?? "").contains("1.65"))

        reveal(play)
        play.tap()
        expectValue("playing", on: play)
    }

    func testPlayerSeeksAndNavigatesNumberedLibraryWhileKeepingSpeed() throws {
        #if targetEnvironment(simulator)
        app.launchArguments = ["--ui-testing", "--reset-library", "--seed-audio", "--seed-playlist"]
        hasLaunched = true
        app.launch()
        let prepared = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in self.clipRows.count == 3 }, object: nil)
        XCTAssertEqual(XCTWaiter.wait(for: [prepared], timeout: 10), .completed)
        clipRows.element(boundBy: 1).tap()
        let title = app.staticTexts["player.title"]
        expectLabel("测试声音 2", on: title)
        let previous = app.buttons["player.previous"]
        let next = app.buttons["player.next"]
        XCTAssertTrue(previous.isEnabled)
        XCTAssertTrue(next.isEnabled)

        let play = app.buttons["player.play"]
        expectValue("playing", on: play)
        play.tap()
        expectValue("paused", on: play)
        app.buttons["player.speed"].tap()
        let custom = app.textFields["speed.custom"]
        XCTAssertTrue(custom.waitForExistence(timeout: 3))
        custom.tap()
        custom.typeText("1.65")
        app.buttons["speed.apply"].tap()
        XCTAssertTrue(custom.waitForNonExistence(timeout: 3))

        let duration = try numericValue(app.staticTexts["player.duration"])
        let ring = playerProgress
        XCTAssertTrue(ring.waitForExistence(timeout: 3))
        let beforeSeek = try numericValue(ring)
        let targetFraction = beforeSeek < duration * 0.5 ? 0.75 : 0.25
        let start = ring.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.08))
        let target = ring.coordinate(withNormalizedOffset: CGVector(dx: targetFraction == 0.75 ? 0.08 : 0.92, dy: 0.5))
        start.press(forDuration: 0.1, thenDragTo: target)
        let sought = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in
            guard let value = Double(ring.value as? String ?? "") else { return false }
            return abs(value - duration * targetFraction) < 0.8
        }, object: nil)
        XCTAssertEqual(XCTWaiter.wait(for: [sought], timeout: 4), .completed, "Dragging the ring must seek to the selected audio position.")
        expectValue("paused", on: play)

        next.tap()
        expectLabel("测试声音 1", on: title)
        expectValue("playing", on: play)
        XCTAssertFalse(next.isEnabled, "The final numbered library item has no next track.")
        XCTAssertTrue(previous.isEnabled)
        XCTAssertTrue((app.buttons["player.speed"].value as? String ?? "").contains("1.65"))

        previous.tap()
        expectLabel("测试声音 2", on: title)
        expectValue("playing", on: play)
        XCTAssertTrue(previous.isEnabled)
        XCTAssertTrue(next.isEnabled)

        play.tap()
        expectValue("paused", on: play)
        app.buttons["player.close"].tap()
        XCTAssertTrue(app.staticTexts["声音库"].waitForExistence(timeout: 5))
        XCTAssertEqual(clipRows.count, 3)
        XCTAssertTrue(clipRows.firstMatch.isHittable)
        let expand = app.buttons["player.expand"]
        let miniPlay = app.buttons["mini.play"]
        XCTAssertTrue(expand.waitForExistence(timeout: 3))
        XCTAssertTrue(miniPlay.exists)
        reveal(expand)
        reveal(miniPlay)
        XCTAssertEqual(miniPlay.label, "播放")
        let importButton = app.buttons["import.button"]
        XCTAssertEqual(importButton.frame.midY, app.staticTexts["声音库"].frame.midY, accuracy: 6)
        XCTAssertLessThanOrEqual(importButton.frame.width, 100)
        XCTAssertEqual(app.buttons.matching(identifier: "import.button").count, 1)
        XCTAssertLessThan(app.windows.firstMatch.frame.maxY - expand.frame.maxY, 80,
                          "Mini player must be the bottom-most control above the home indicator.")
        let home = XCTAttachment(screenshot: app.screenshot())
        home.name = "Home-VariantB"
        home.lifetime = .keepAlways
        add(home)

        expand.tap()
        expectLabel("测试声音 2", on: title)
        expectValue("paused", on: play)
        XCTAssertTrue((app.buttons["player.speed"].value as? String ?? "").contains("1.65"))
        #else
        throw XCTSkip("Redesigned player acceptance runs on simulator only.")
        #endif
    }

    func testAudioProgressContinuesAfterAppMovesToBackground() throws {
        launch(seed: true)
        openSeededPlayer()
        let play = app.buttons["player.play"]
        expectValue("playing", on: play)
        let progress = playerProgress
        XCTAssertTrue(progress.waitForExistence(timeout: 3))
        let before = try numericValue(progress)

        XCUIDevice.shared.press(.home)
        XCTAssertTrue(app.wait(for: .runningBackground, timeout: 3))
        Thread.sleep(forTimeInterval: 2)
        app.activate()

        XCTAssertTrue(play.waitForExistence(timeout: 5))
        expectValue("playing", on: play)
        let after = try numericValue(progress)
        XCTAssertGreaterThan(after - before, 1.2, "Playback position must advance while the app is in the background.")
    }

    func testSequentialModeAutomaticallyAdvancesWhileInBackground() throws {
        #if targetEnvironment(simulator)
        app.launchArguments = ["--ui-testing", "--reset-library", "--seed-audio", "--seed-playlist"]
        hasLaunched = true
        app.launch()
        let prepared = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in self.clipRows.count == 3 }, object: nil)
        XCTAssertEqual(XCTWaiter.wait(for: [prepared], timeout: 10), .completed)
        clipRows.element(boundBy: 2).tap()
        expectLabel("测试声音 1", on: app.staticTexts["player.title"])
        let play = app.buttons["player.play"]
        expectValue("playing", on: play)
        play.tap()
        expectValue("paused", on: play)
        let mode = app.buttons["player.loop"]
        expectValue("单曲循环", on: mode)
        mode.tap()
        expectValue("顺序播放", on: mode)
        app.buttons["player.speed"].tap()
        app.buttons["speed.2.0"].tap()
        app.buttons["speed.done"].tap()
        let ring = playerProgress
        let start = ring.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.08))
        let target = ring.coordinate(withNormalizedOffset: CGVector(dx: 0.92, dy: 0.5))
        start.press(forDuration: 0.1, thenDragTo: target)
        play.tap()
        XCUIDevice.shared.press(.home)
        XCTAssertTrue(app.wait(for: .runningBackground, timeout: 3))
        Thread.sleep(forTimeInterval: 4)
        app.activate()
        expectLabel("测试声音 3", on: app.staticTexts["player.title"])
        expectValue("顺序播放", on: mode)
        XCTAssertTrue(app.buttons["player.next"].isEnabled)
        XCTAssertTrue((app.buttons["player.speed"].value as? String ?? "").contains("2"))
        #else
        throw XCTSkip("Sequential background playback acceptance runs on simulator only.")
        #endif
    }

    func testShuffleModeAutomaticallyAdvancesWhileInBackground() throws {
        app.launchArguments = ["--ui-testing", "--reset-library", "--seed-audio", "--seed-playlist"]
        hasLaunched = true
        app.launch()
        let prepared = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in self.clipRows.count == 3 }, object: nil)
        XCTAssertEqual(XCTWaiter.wait(for: [prepared], timeout: 10), .completed)
        clipRows.element(boundBy: 2).tap()
        let title = app.staticTexts["player.title"]
        expectLabel("测试声音 1", on: title)
        let play = app.buttons["player.play"]
        expectValue("playing", on: play)
        play.tap()
        let mode = app.buttons["player.loop"]
        mode.tap()
        mode.tap()
        expectValue("随机循环", on: mode)
        XCTAssertTrue(app.buttons["player.next"].isEnabled, "Shuffle can advance even from the last library row.")
        app.buttons["player.speed"].tap()
        app.buttons["speed.2.0"].tap()
        app.buttons["speed.done"].tap()
        let ring = playerProgress
        ring.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.08))
            .press(forDuration: 0.1, thenDragTo: ring.coordinate(withNormalizedOffset: CGVector(dx: 0.92, dy: 0.5)))
        play.tap()
        XCUIDevice.shared.press(.home)
        XCTAssertTrue(app.wait(for: .runningBackground, timeout: 3))
        Thread.sleep(forTimeInterval: 4)
        app.activate()
        XCTAssertTrue(title.waitForExistence(timeout: 5))
        XCTAssertNotEqual(title.label, "测试声音 1", "Shuffle must automatically change tracks in the background.")
        expectValue("playing", on: play)
        expectValue("随机循环", on: mode)
        XCTAssertTrue(app.buttons["player.previous"].isEnabled)
        XCTAssertTrue((app.buttons["player.speed"].value as? String ?? "").contains("2"))
    }

    func testLongPressDragReordersLibraryAndPersistsPlaybackQueue() throws {
        #if targetEnvironment(simulator)
        app.launchArguments = ["--ui-testing", "--reset-library", "--seed-audio", "--seed-playlist"]
        hasLaunched = true
        app.launch()
        let prepared = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in self.clipRows.count == 3 }, object: nil)
        XCTAssertEqual(XCTWaiter.wait(for: [prepared], timeout: 10), .completed)
        let first = clipRows.element(boundBy: 0)
        let last = clipRows.element(boundBy: 2)
        XCTAssertTrue(first.label.contains("测试声音 3"))
        XCTAssertTrue(last.label.contains("测试声音 1"))
        last.press(forDuration: 0.7)
        XCTAssertFalse(app.staticTexts["player.title"].exists,
                       "A long press released without moving must not start playback.")
        last.coordinate(withNormalizedOffset: CGVector(dx: 0.45, dy: 0.5))
            .press(forDuration: 1.0, thenDragTo: first.coordinate(withNormalizedOffset: CGVector(dx: 0.45, dy: 0.1)), withVelocity: .slow, thenHoldForDuration: 0.4)
        let dragImage = XCTAttachment(screenshot: app.screenshot())
        dragImage.name = "Home-AfterDrag"
        dragImage.lifetime = .keepAlways
        add(dragImage)
        let reordered = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in
            self.clipRows.firstMatch.label.contains("测试声音 1")
        }, object: nil)
        XCTAssertEqual(XCTWaiter.wait(for: [reordered], timeout: 5), .completed,
                       "Long-press dragging must move the sound to the selected position.")
        for index in 0..<3 {
            expectValue(String(index + 1), on: clipRows.element(boundBy: index))
            XCTAssertTrue(clipRows.element(boundBy: index).label.hasPrefix(String(format: "%02d", index + 1)),
                          "Visible row numbers must follow current positions immediately after dropping.")
        }
        let homeImage = XCTAttachment(screenshot: app.screenshot())
        homeImage.name = "Home-Reordered"
        homeImage.lifetime = .keepAlways
        add(homeImage)
        app.terminate()
        app.launchArguments = ["--ui-testing"]
        app.launch()
        XCTAssertTrue(clipRows.firstMatch.waitForExistence(timeout: 5))
        XCTAssertTrue(clipRows.firstMatch.label.contains("测试声音 1"))
        clipRows.firstMatch.tap()
        expectLabel("测试声音 1", on: app.staticTexts["player.title"])
        app.buttons["player.next"].tap()
        expectLabel("测试声音 3", on: app.staticTexts["player.title"])
        app.buttons["player.close"].tap()
        let playing = clipRows.element(boundBy: 1)
        XCTAssertTrue(playing.waitForExistence(timeout: 5))
        playing.coordinate(withNormalizedOffset: CGVector(dx: 0.45, dy: 0.5))
            .press(forDuration: 1.0, thenDragTo: clipRows.firstMatch.coordinate(withNormalizedOffset: CGVector(dx: 0.45, dy: 0.1)), withVelocity: .slow, thenHoldForDuration: 2.0)
        let movedPlaying = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in
            self.clipRows.firstMatch.label.contains("测试声音 3")
        }, object: nil)
        XCTAssertEqual(XCTWaiter.wait(for: [movedPlaying], timeout: 5), .completed)
        for index in 0..<3 {
            expectValue(String(index + 1), on: clipRows.element(boundBy: index))
            XCTAssertTrue(clipRows.element(boundBy: index).label.hasPrefix(String(format: "%02d", index + 1)))
        }
        XCTAssertTrue(app.buttons["player.expand"].label.contains("测试声音 3"))
        let ordinary = clipRows.element(boundBy: 2)
        ordinary.coordinate(withNormalizedOffset: CGVector(dx: 0.45, dy: 0.5))
            .press(forDuration: 1.0, thenDragTo: clipRows.firstMatch.coordinate(withNormalizedOffset: CGVector(dx: 0.45, dy: 0.1)), withVelocity: .slow, thenHoldForDuration: 0.4)
        let movedOverPlaying = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in
            self.clipRows.firstMatch.label.contains("测试声音 2")
        }, object: nil)
        XCTAssertEqual(XCTWaiter.wait(for: [movedOverPlaying], timeout: 5), .completed)
        for index in 0..<3 {
            expectValue(String(index + 1), on: clipRows.element(boundBy: index))
            XCTAssertTrue(clipRows.element(boundBy: index).label.hasPrefix(String(format: "%02d", index + 1)))
        }
        let finalHome = XCTAttachment(screenshot: app.screenshot())
        finalHome.name = "Home-PlayingReordered"
        finalHome.lifetime = .keepAlways
        add(finalHome)
        app.buttons["player.expand"].tap()
        expectLabel("测试声音 3", on: app.staticTexts["player.title"])
        app.buttons["player.next"].tap()
        expectLabel("测试声音 1", on: app.staticTexts["player.title"])

        #else
        throw XCTSkip("Library drag acceptance runs on simulator only.")
        #endif
    }

    func testLibraryRenameSurvivesRelaunchAndDeleteRemovesClip() {
        launch(seed: true)
        XCTAssertTrue(seedRow.waitForExistence(timeout: 10))
        app.buttons["clip.menu"].tap()
        app.buttons["重命名"].tap()
        let name = app.alerts["重命名"].textFields.firstMatch
        XCTAssertTrue(name.waitForExistence(timeout: 3))
        name.tap()
        let existing = name.value as? String ?? ""
        name.typeText(String(repeating: XCUIKeyboardKey.delete.rawValue, count: existing.count))
        name.typeText("Practice")
        app.alerts.buttons["保存"].tap()
        XCTAssertTrue(renamedRow.waitForExistence(timeout: 3))

        app.terminate()
        app.launchArguments = ["--ui-testing"]
        app.launch()
        XCTAssertTrue(renamedRow.waitForExistence(timeout: 5))
        app.buttons["clip.menu"].tap()
        app.buttons["删除"].tap()
        app.buttons["删除声音"].tap()
        XCTAssertTrue(app.staticTexts["library.empty"].waitForExistence(timeout: 5))
        XCTAssertFalse(renamedRow.exists)
    }

    private var seedRow: XCUIElement {
        clipRows.firstMatch
    }

    private var clipRows: XCUIElementQuery {
        app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@ AND identifier != %@", "clip.", "clip.menu"))
    }

    private var playerProgress: XCUIElement {
        app.descendants(matching: .any).matching(identifier: "player.progress").firstMatch
    }

    private var renamedRow: XCUIElement {
        app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@ AND identifier != %@ AND label CONTAINS %@", "clip.", "clip.menu", "Practice")).firstMatch
    }

    private func launch(seed: Bool) {
        app.launchArguments = ["--ui-testing", "--reset-library"] + (seed ? ["--seed-audio"] : [])
        hasLaunched = true
        app.launch()
    }

    private func openSeededPlayer() {
        XCTAssertTrue(seedRow.waitForExistence(timeout: 10))
        seedRow.tap()
        XCTAssertTrue(app.staticTexts["player.title"].waitForExistence(timeout: 5))
        XCTAssertEqual(app.staticTexts["player.title"].label, "测试声音")
    }

    private func reveal(_ element: XCUIElement) {
        for _ in 0..<3 where !element.isHittable && app.scrollViews.firstMatch.exists {
            if element.frame.minY < app.windows.firstMatch.frame.minY + 100 {
                app.scrollViews.firstMatch.swipeDown()
            } else {
                app.scrollViews.firstMatch.swipeUp()
            }
        }
        let visible = XCTNSPredicateExpectation(predicate: NSPredicate(format: "hittable == true"), object: element)
        XCTAssertEqual(XCTWaiter.wait(for: [visible], timeout: 3), .completed)
    }

    private func expectValue(_ value: String, on element: XCUIElement, timeout: TimeInterval = 5) {
        let expectation = XCTNSPredicateExpectation(predicate: NSPredicate(format: "value == %@", value), object: element)
        XCTAssertEqual(XCTWaiter.wait(for: [expectation], timeout: timeout), .completed)
    }

    private func numericValue(_ element: XCUIElement) throws -> Double {
        try XCTUnwrap(Double(element.value as? String ?? ""), "Progress must expose its position in seconds.")
    }

    private func expectLabel(_ label: String, on element: XCUIElement) {
        let expectation = XCTNSPredicateExpectation(predicate: NSPredicate(format: "label == %@", label), object: element)
        XCTAssertEqual(XCTWaiter.wait(for: [expectation], timeout: 5), .completed)
    }
}
