import XCTest

// Regression tests for list over-scroll: scrolling hard past the end of the
// reading list / Home list must settle with the last rows still on screen.
// Launches with -uitest-seed-reading-list (hermetic in-memory store, no network).
final class ReadingListScrollTests: XCTestCase {

    @MainActor
    func testReadingListScrollStopsAtBottom() throws {
        let app = XCUIApplication()
        app.launchArguments += ["-uitest-seed-reading-list"]
        app.launch()

        attachShot(app, name: "0-home")

        // Two elements carry the "Reading list" label (nav-bar button and the
        // offscreen side-menu row) — tap the one that's actually hittable.
        let anyReadingList = app.buttons.matching(identifier: "Reading list").firstMatch
        XCTAssertTrue(anyReadingList.waitForExistence(timeout: 15), "Reading list button should exist")
        let candidates = app.buttons.matching(identifier: "Reading list").allElementsBoundByIndex
        guard let readingListButton = candidates.first(where: { $0.isHittable }) else {
            XCTFail("No hittable Reading list button")
            return
        }
        readingListButton.tap()

        // Wait for the seeded rows to appear.
        let firstRow = app.staticTexts.matching(NSPredicate(format: "label CONTAINS 'Seeded Paper'")).firstMatch
        XCTAssertTrue(firstRow.waitForExistence(timeout: 10), "Seeded rows should appear")
        sleep(1)
        attachShot(app, name: "1-reading-list-top")

        // Scroll hard toward the bottom, well past the content.
        for _ in 0..<10 {
            app.swipeUp(velocity: .fast)
        }
        sleep(3) // let any deceleration/settling finish
        attachShot(app, name: "2-after-hard-scroll")

        // Log visible seeded-row frames + window frame for diagnosis.
        let window = app.windows.firstMatch
        print("DIAG window frame: \(window.frame)")
        let rows = app.staticTexts.matching(NSPredicate(format: "label CONTAINS 'Seeded Paper'"))
        for i in 0..<min(rows.count, 12) {
            let el = rows.element(boundBy: i)
            if el.exists {
                print("DIAG row[\(i)] '\(el.label.prefix(20))' frame: \(el.frame)")
            }
        }

        // After settling, at least one seeded row should still be on screen.
        var anyRowVisible = false
        for i in 0..<rows.count {
            let el = rows.element(boundBy: i)
            if el.exists && el.frame.intersects(window.frame) && el.frame.minY < window.frame.maxY && el.frame.maxY > window.frame.minY {
                anyRowVisible = true
                break
            }
        }
        XCTAssertTrue(anyRowVisible, "After scrolling to the bottom and settling, the last rows should remain visible — blank space means over-scroll")
    }

    @MainActor
    func testHomeScrollStopsAtBottom() throws {
        let app = XCUIApplication()
        app.launchArguments += ["-uitest-seed-reading-list"]
        app.launch()

        // All seeded papers are dated today, so Home shows both sets; rows below
        // the fold don't exist yet in a lazy List, so match any seeded row.
        let firstRow = app.staticTexts.matching(NSPredicate(format: "label CONTAINS 'Seeded'")).firstMatch
        XCTAssertTrue(firstRow.waitForExistence(timeout: 15), "Seeded Home rows should appear")
        sleep(1)
        attachShot(app, name: "home-1-top")

        for _ in 0..<12 {
            app.swipeUp(velocity: .fast)
        }
        sleep(3)
        attachShot(app, name: "home-2-after-hard-scroll")

        let window = app.windows.firstMatch
        let rows = app.staticTexts.matching(NSPredicate(format: "label CONTAINS 'Seeded'"))
        var anyRowVisible = false
        for i in 0..<rows.count {
            let el = rows.element(boundBy: i)
            if el.exists && el.frame.minY < window.frame.maxY && el.frame.maxY > window.frame.minY {
                anyRowVisible = true
                break
            }
        }
        XCTAssertTrue(anyRowVisible, "Home list should not scroll past its content")
    }

    @MainActor
    private func attachShot(_ app: XCUIApplication, name: String) {
        let shot = XCTAttachment(screenshot: app.screenshot())
        shot.name = name
        shot.lifetime = .keepAlways
        add(shot)
    }
}
