import XCTest

/// Exercises the same controls used by a reader, including the native PDF host.
final class StudyReadingUITests: XCTestCase {
    func testReportContentsCanOpenAJudgmentOutsideTheHeadlines() throws {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launch()
        let mode = app.buttons["reader-mode-report"]
        XCTAssertTrue(mode.waitForExistence(timeout: 10))
        if mode.isEnabled { mode.tap() }
        let contents = app.buttons["report-contents"]
        XCTAssertTrue(contents.waitForExistence(timeout: 3))
        contents.tap()
        let profit = app.buttons["先分清利息记在哪里，再看产品生意赚了多少"]
        XCTAssertTrue(profit.waitForExistence(timeout: 4))
        profit.tap()
        let heading = app.staticTexts["report-heading-gree-profit"]
        let visible = XCTNSPredicateExpectation(predicate: NSPredicate(format: "hittable == true"), object: heading)
        XCTAssertEqual(XCTWaiter.wait(for: [visible], timeout: 5), .completed)
    }

    func testOrdinaryModeSwitchResumesTheReportsOwnPosition() throws {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launch()
        let reportMode = app.buttons["reader-mode-report"]
        XCTAssertTrue(reportMode.waitForExistence(timeout: 10))
        if reportMode.isEnabled { reportMode.tap() }
        let quarter = app.buttons["report-link-gree-latest-quarter"]
        reveal(quarter, in: app)
        quarter.tap()
        let heading = app.staticTexts["report-heading-gree-latest-quarter"]
        XCTAssertTrue(heading.waitForExistence(timeout: 5))
        let visible = XCTNSPredicateExpectation(predicate: NSPredicate(format: "hittable == true"), object: heading)
        let visibility = XCTWaiter.wait(for: [visible], timeout: 5)
        XCTAssertEqual(visibility, .completed)
        app.buttons["reader-mode-diagram"].tap()
        app.buttons["reader-mode-report"].tap()
        XCTAssertTrue(heading.waitForExistence(timeout: 5))
        XCTAssertTrue(heading.isHittable)
    }

    func testMainlineEndsWithoutSendingTheReaderAway() throws {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launch()
        selectDiagram(in: app)
        let overview = app.buttons["study-overview"]
        if overview.waitForExistence(timeout: 3) { overview.tap() }
        let firstScene = app.buttons["study-map-business-delivery"]
        XCTAssertTrue(firstScene.waitForExistence(timeout: 10))
        firstScene.tap()
        for _ in 0..<10 { app.buttons["study-next"].tap() }
        XCTAssertTrue(app.staticTexts["study-mainline-end"].waitForExistence(timeout: 3))
        XCTAssertFalse(app.buttons["study-next"].isEnabled)
        XCTAssertTrue(app.buttons["study-overview"].exists)
    }

    func testReaderCanCheckOriginalPDFAndReturnToTheDiagram() throws {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launch()
        selectDiagram(in: app)

        let overview = app.buttons["study-overview"]
        if overview.waitForExistence(timeout: 3) { overview.tap() }
        let begin = app.buttons["study-begin"]
        XCTAssertTrue(begin.waitForExistence(timeout: 10))
        begin.tap()

        let evidence = app.buttons["study-evidence"]
        XCTAssertTrue(evidence.waitForExistence(timeout: 5))
        evidence.tap()
        let original = app.buttons.matching(identifier: "study-open-pdf").firstMatch
        XCTAssertTrue(original.waitForExistence(timeout: 5))
        original.tap()

        let position = app.staticTexts["study-pdf-position"]
        let ready = NSPredicate(format: "value == %@", "原文已打开")
        expectation(for: ready, evaluatedWith: position)
        waitForExpectations(timeout: 15)
        app.buttons["study-close-pdf"].tap()
        XCTAssertTrue(app.buttons["study-close-evidence"].waitForExistence(timeout: 5))
        app.buttons["study-close-evidence"].tap()
        XCTAssertTrue(app.buttons["study-evidence"].waitForExistence(timeout: 5))
    }

    private func reveal(_ element: XCUIElement, in app: XCUIApplication) {
        XCTAssertTrue(element.waitForExistence(timeout: 8))
        let scroll = app.scrollViews.firstMatch
        for _ in 0..<12 {
            if element.isHittable { return }
            if element.frame.minY < scroll.frame.minY { scroll.swipeDown() }
            else { scroll.swipeUp() }
        }
        XCTAssertTrue(element.isHittable)
    }

    private func selectDiagram(in app: XCUIApplication) {
        let mode = app.buttons["reader-mode-diagram"]
        if mode.waitForExistence(timeout: 3), mode.isEnabled { mode.tap() }
    }
}
