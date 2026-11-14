import Foundation
import XCTest
@testable import ResearchCore

final class VisualStudyStateTests: XCTestCase {
    private let moments = ["customer", "profit", "cash"]

    func testAdvanceAndBackRestoreEachScenesOwnFocus() {
        var state = VisualStudyState(momentIDs: moments)
        XCTAssertEqual(state.currentID, "customer")
        XCTAssertFalse(state.isOverview)
        state.selectFocus("service")
        state.advance()
        XCTAssertEqual(state.currentID, "profit")
        XCTAssertNil(state.focus)
        state.selectFocus("quarter")
        state.advance()
        XCTAssertEqual(state.history, ["customer", "profit"])
        state.back()
        XCTAssertEqual(state.currentID, "profit")
        XCTAssertEqual(state.focus, "quarter")
        state.back()
        XCTAssertEqual(state.currentID, "customer")
        XCTAssertEqual(state.focus, "service")
        XCTAssertEqual(state.history, [])
    }

    func testOverviewAndReturningToSameScenePreserveExactPosition() {
        var state = VisualStudyState(momentIDs: moments)
        state.advance()
        state.selectFocus("fees")
        let original = state
        state.overview()
        XCTAssertTrue(state.isOverview)
        XCTAssertEqual(state.currentID, original.currentID)
        XCTAssertEqual(state.focus, original.focus)
        XCTAssertEqual(state.history, original.history)
        state.enter("profit")
        XCTAssertEqual(state, original)
        state.overview()
        state.back()
        XCTAssertEqual(state, original)
        state.overview()
        state.advance()
        XCTAssertEqual(state, original)
    }

    func testJumpFromOverviewRecordsPriorSceneAndClearsFocus() {
        var state = VisualStudyState(momentIDs: moments)
        state.selectFocus("service")
        state.overview()
        state.enter("cash")
        XCTAssertEqual(state.currentID, "cash")
        XCTAssertNil(state.focus)
        XCTAssertFalse(state.isOverview)
        XCTAssertEqual(state.history, ["customer"])
        state.back()
        XCTAssertEqual(state.currentID, "customer")
        XCTAssertEqual(state.focus, "service")
    }

    func testInvalidInputsAndRepeatedEntryDoNotChangeState() {
        var state = VisualStudyState(momentIDs: moments)
        state.selectFocus("service")
        let original = state
        for id in ["", " ", "unknown"] { state.enter(id) }
        state.selectFocus("\n ")
        state.enter("customer")
        XCTAssertEqual(state, original)
        state.overview()
        let covered = state
        state.selectFocus("other-detail")
        XCTAssertEqual(state, covered)
        state.enter("customer")
        state.selectFocus(nil)
        XCTAssertNil(state.focus)
    }

    func testEndAndBeginningDoNotWrapOrInventHistory() {
        var state = VisualStudyState(momentIDs: moments)
        state.back()
        XCTAssertTrue(state.isOverview)
        XCTAssertEqual(state.history, [])
        state.enter("cash")
        state.selectFocus("loans")
        let end = state
        state.advance()
        XCTAssertEqual(state, end)
    }

    func testBookmarkRestoresOverviewAndFocusOfBackStack() throws {
        var state = VisualStudyState(momentIDs: moments)
        state.selectFocus("service")
        state.advance()
        state.selectFocus("quarter")
        state.advance()
        state.selectFocus("loans")
        state.overview()
        let saved = try XCTUnwrap(state.encodedBookmark())
        var restored = VisualStudyState(momentIDs: moments, saved: saved)
        XCTAssertEqual(restored, state)
        XCTAssertEqual(try JSONDecoder().decode(VisualStudyState.self, from: saved), state)
        restored.back()
        XCTAssertEqual(restored.focus, "loans")
        restored.back()
        XCTAssertEqual(restored.currentID, "profit")
        XCTAssertEqual(restored.focus, "quarter")
        restored.back()
        XCTAssertEqual(restored.focus, "service")
    }

    func testCorruptObsoleteAndUnknownPositionsResetSafely() throws {
        var state = VisualStudyState(momentIDs: moments)
        state.advance()
        state.selectFocus("quarter")
        let saved = try XCTUnwrap(state.encodedBookmark())
        let base = try XCTUnwrap(JSONSerialization.jsonObject(with: saved) as? [String: Any])
        let mutations: [[String: Any]] = [
            ["schemaVersion": 999], ["currentID": "retired"],
            ["history": [["id": "retired", "focus": "service"]]],
            ["history": [["id": "profit"]]], ["focus": " "],
            ["momentIDs": ["customer", "customer", "cash"]]
        ]
        for mutation in mutations {
            var changed = base
            changed.merge(mutation) { _, new in new }
            let data = try JSONSerialization.data(withJSONObject: changed)
            XCTAssertEqual(VisualStudyState(momentIDs: moments, saved: data),
                           VisualStudyState(momentIDs: moments), "Rejected \(mutation)")
            XCTAssertThrowsError(try JSONDecoder().decode(VisualStudyState.self, from: data))
        }
        XCTAssertEqual(VisualStudyState(momentIDs: moments, saved: Data("broken".utf8)),
                       VisualStudyState(momentIDs: moments))
        let changedCatalogue = ["customer", "profit", "new-scene"]
        XCTAssertEqual(VisualStudyState(momentIDs: changedCatalogue, saved: saved),
                       VisualStudyState(momentIDs: changedCatalogue))
    }

    func testEmptyAndDuplicateCatalogueNeverCreatesInvalidNavigation() throws {
        var empty = VisualStudyState(momentIDs: ["", "\n"])
        let original = empty
        empty.enter("cash")
        empty.advance()
        empty.back()
        empty.selectFocus("detail")
        XCTAssertEqual(empty, original)
        XCTAssertEqual(empty.currentID, "")
        XCTAssertTrue(empty.isOverview)
        let data = try XCTUnwrap(empty.encodedBookmark())
        XCTAssertEqual(VisualStudyState(momentIDs: [], saved: data), empty)
        var unique = VisualStudyState(momentIDs: ["customer", "profit", "customer", "cash", ""])
        unique.advance()
        XCTAssertEqual(unique.currentID, "profit")
        unique.advance()
        XCTAssertEqual(unique.currentID, "cash")
    }
}
