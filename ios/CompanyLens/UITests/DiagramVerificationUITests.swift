import XCTest
import UIKit

/// Verifies the controls exposed by the complete native diagram reader.
final class DiagramVerificationUITests: XCTestCase {
    func testDiagramVerificationActionsOpenTheirDetailsAndReturnToTheSelectedSource() throws {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launch()
        let open = app.buttons.matching(identifier: "library-open-current").firstMatch
        if open.waitForExistence(timeout: 3) { open.tap() }

        let diagram = app.tabBars.buttons["workspace-tab-diagram"]
        XCTAssertTrue(diagram.waitForExistence(timeout: 10))
        diagram.tap()
        let selected = XCTNSPredicateExpectation(predicate: NSPredicate(format: "selected == true"), object: diagram)
        XCTAssertEqual(XCTWaiter.wait(for: [selected], timeout: 5), .completed)
        XCTAssertEqual(app.staticTexts["workspace-company-title"].label, "格力电器")

        let overview = app.buttons["study-overview"]
        if overview.waitForExistence(timeout: 3) { overview.tap() }
        let scene = app.buttons["study-map-cash-recent"]
        reveal(scene, in: app)
        scene.tap()
        let sceneTitle = app.staticTexts["study-scene-title"]
        XCTAssertTrue(sceneTitle.waitForExistence(timeout: 5))
        XCTAssertEqual(sceneTitle.label, "销售收款减少，贷款回收补了一部分。")

        let evidenceActions = app.buttons.matching(identifier: "study-evidence")
        let calculationActions = app.buttons.matching(identifier: "study-calculation")
        XCTAssertEqual(evidenceActions.count, 1, "The evidence action has its own accessible identity")
        XCTAssertEqual(calculationActions.count, 1, "The calculation action has its own accessible identity")
        let evidence = evidenceActions.element
        let calculation = calculationActions.element
        XCTAssertEqual(evidence.label, "看原页依据")
        XCTAssertEqual(calculation.label, "数字怎么算")

        reveal(evidence, in: app)
        let evidenceSourceY = evidence.frame.minY
        evidence.tap()
        let closeEvidence = app.buttons["study-close-evidence"]
        XCTAssertTrue(closeEvidence.waitForExistence(timeout: 5))
        XCTAssertTrue(app.staticTexts["核对依据"].exists)
        XCTAssertTrue(app.buttons.matching(identifier: "study-open-pdf").firstMatch.exists)
        closeEvidence.tap()
        assertSource(evidence, restoredTo: evidenceSourceY, in: app)

        reveal(calculation, in: app)
        let calculationSourceY = calculation.frame.minY
        calculation.tap()
        let closeCalculation = app.buttons["study-close-calculation"]
        XCTAssertTrue(closeCalculation.waitForExistence(timeout: 5))
        XCTAssertTrue(app.staticTexts["核对计算"].exists)
        XCTAssertTrue(app.staticTexts["2026前三季经营现金同比变化"].exists)
        closeCalculation.tap()
        assertSource(calculation, restoredTo: calculationSourceY, in: app)
    }

    private func assertSource(_ action: XCUIElement, restoredTo sourceY: CGFloat, in app: XCUIApplication) {
        let restored = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in
            action.exists && action.isHittable && abs(action.frame.minY - sourceY) <= 24
        }, object: action)
        XCTAssertEqual(XCTWaiter.wait(for: [restored], timeout: 5), .completed)
        XCTAssertEqual(app.staticTexts["study-scene-title"].label, "销售收款减少，贷款回收补了一部分。")
        XCTAssertEqual(app.staticTexts["study-explanation"].label, "少收的钱，来自哪里？")
        XCTAssertTrue(app.tabBars.buttons["workspace-tab-diagram"].isSelected)
    }

    private func reveal(_ element: XCUIElement, in app: XCUIApplication) {
        XCTAssertTrue(element.waitForExistence(timeout: 5))
        let scroll = app.scrollViews.firstMatch
        for _ in 0..<18 {
            if element.isHittable { return }
            let down = element.frame.midY < scroll.frame.midY
            let start = scroll.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: down ? 0.35 : 0.7))
            let end = scroll.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: down ? 0.7 : 0.35))
            start.press(forDuration: 0.05, thenDragTo: end,
                        withVelocity: XCUIGestureVelocity(rawValue: 300), thenHoldForDuration: 0.1)
        }
        XCTAssertTrue(element.isHittable, "The reader can scroll to the published action")
    }
}
