import XCTest

/// Exercises the same controls used by a reader, including the native PDF host.
final class StudyReadingUITests: XCTestCase {
    func testMainlineEndsWithoutSendingTheReaderAway() throws {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launch()
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
}
