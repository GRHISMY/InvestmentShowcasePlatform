import Foundation
import XCTest
import ResearchCore

final class DiagramViewingTests: XCTestCase {
    private static let publication = Result {
        try ReadableStudy(root: URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("Study"))
    }

    private func openedReader() throws -> StudyReader {
        var reader = StudyReader(study: try Self.publication.get())
        guard case .overview(let overview) = reader.page else { throw FixtureError.noOverview }
        reader.follow(overview.beginOrResume)
        return reader
    }
    private enum FixtureError: Error { case noOverview }

    func testEnlargeShowsTheSameGraphWithoutChangingTheMainReading() throws {
        var reader = try openedReader()
        guard case .diagram(let original) = reader.page else { return XCTFail() }
        reader.enlargeDiagram()
        let viewer = try XCTUnwrap(reader.fullscreenDiagram)
        XCTAssertEqual(viewer.diagram.diagram.raw.id, original.diagram.raw.id)
        XCTAssertEqual(viewer.diagram.focus.id, "delivery")
        XCTAssertEqual(viewer.diagram.visitID, original.visitID)
        XCTAssertNotEqual(viewer.observation, original.observation)
        XCTAssertFalse(viewer.isDisplayed)
        guard case .diagram(let primary) = reader.primaryPage, case .diagram = reader.page else {
            return XCTFail("Fullscreen viewing does not introduce another reading address")
        }
        XCTAssertEqual(primary.visitID, original.visitID)
        XCTAssertEqual(primary.focus.id, "delivery")
    }

    func testViewerChangesTheSharedFocusButRetainsTheMainReadingPosition() throws {
        var reader = try openedReader()
        guard case .diagram(let source) = reader.page else { return XCTFail() }
        let position = ReadingPosition(anchorID: "explanation", localOffset: 42)
        reader.reportVisiblePosition(source.observation, position: position, cause: .userBrowsing)
        reader.enlargeDiagram()
        let originalViewer = try XCTUnwrap(reader.fullscreenDiagram)
        reader.selectFocus(try XCTUnwrap(originalViewer.diagram.diagram.choice(for: "prepay")))
        reader.selectFocus(try XCTUnwrap(originalViewer.diagram.diagram.choice(for: "warranty")))
        let selected = try XCTUnwrap(reader.fullscreenDiagram)
        XCTAssertEqual(selected.diagram.focus.id, "warranty")
        XCTAssertEqual(selected.diagram.visitID, source.visitID)
        XCTAssertNotEqual(selected.observation, originalViewer.observation)
        guard case .diagram(let main) = reader.primaryPage else { return XCTFail() }
        XCTAssertEqual(main.focus.id, "warranty")
        XCTAssertEqual(main.restorePosition, ReadingPosition(anchorID: "explanation"))
    }

    func testClosingPreservesNewFocusAndSourcePositionAndConsumesOnlyItsOwnPresentation() throws {
        var reader = try openedReader()
        guard case .diagram(let original) = reader.page else { return XCTFail() }
        let position = ReadingPosition(anchorID: "limits", localOffset: 58)
        reader.reportVisiblePosition(original.observation, position: position, cause: .userBrowsing)
        reader.enlargeDiagram()
        let viewer = try XCTUnwrap(reader.fullscreenDiagram)
        reader.selectFocus(try XCTUnwrap(viewer.diagram.diagram.choice(for: "prepay")))
        reader.dismissPresentation(viewer.presentationToken)
        XCTAssertNil(reader.fullscreenDiagram)
        reader.dismissPresentation(viewer.presentationToken)
        reader.reportVisiblePosition(original.observation,
            position: ReadingPosition(anchorID: "heading"), cause: .userBrowsing)
        reader.reportVisiblePosition(viewer.observation,
            position: ReadingPosition(anchorID: "heading"), cause: .userBrowsing)
        guard case .diagram(let returned) = reader.page else { return XCTFail("A duplicate close must not navigate back") }
        XCTAssertEqual(returned.visitID, original.visitID)
        XCTAssertEqual(returned.focus.id, "prepay")
        XCTAssertEqual(returned.restorePosition, ReadingPosition(anchorID: "limits"))
        XCTAssertNotEqual(returned.observation, original.observation)
        reader.enlargeDiagram()
        let reopened = try XCTUnwrap(reader.fullscreenDiagram)
        reader.dismissPresentation(viewer.presentationToken)
        XCTAssertEqual(reader.fullscreenDiagram?.presentationToken, reopened.presentationToken)
        reader.back()
        XCTAssertNil(reader.fullscreenDiagram)
        reader.back()
        guard case .overview = reader.page else { return XCTFail("Fullscreen viewing adds no reading history step") }
    }

    func testViewerBlocksBackgroundNavigationAndAllMainPositionObservers() throws {
        var reader = try openedReader()
        guard case .diagram(let source) = reader.page else { return XCTFail() }
        let position = ReadingPosition(anchorID: "limits", localOffset: 26)
        reader.reportVisiblePosition(source.observation, position: position, cause: .userBrowsing)
        reader.enlargeDiagram()
        let viewer = try XCTUnwrap(reader.fullscreenDiagram)
        reader.reportVisiblePosition(source.observation,
            position: ReadingPosition(anchorID: "heading"), cause: .userBrowsing)
        reader.reportVisiblePosition(viewer.observation,
            position: ReadingPosition(anchorID: "diagram"), cause: .userBrowsing)
        reader.follow(source.overview)
        reader.advanceMainline()
        reader.switchMode(.report)
        reader.selectFocus(try XCTUnwrap(source.diagram.choice(for: "warranty")))
        reader.follow(try XCTUnwrap(source.focus.evidence))
        reader.enlargeDiagram()
        guard case .diagram(let primary) = reader.page else { return XCTFail("Covered content cannot navigate") }
        XCTAssertEqual(primary.sceneID, "business-delivery")
        XCTAssertEqual(primary.focus.id, "delivery")
        XCTAssertEqual(primary.restorePosition, position)
        XCTAssertFalse(reader.navigation.canAdvanceMainline)
        XCTAssertEqual(reader.fullscreenDiagram?.presentationToken, viewer.presentationToken)
    }

    func testOnlyTheCurrentVisibleRenderReceiptIsAcceptedWithoutWritingMainPosition() throws {
        var reader = try openedReader()
        guard case .diagram(let main) = reader.page else { return XCTFail() }
        let position = ReadingPosition(anchorID: "explanation", localOffset: 33)
        reader.reportVisiblePosition(main.observation, position: position, cause: .userBrowsing)
        let originalBookmark = reader.localBookmark
        reader.enlargeDiagram()
        let first = try XCTUnwrap(reader.fullscreenDiagram)
        reader.reportFullscreenDiagramDisplayed(first.observation)
        XCTAssertTrue(try XCTUnwrap(reader.fullscreenDiagram).isDisplayed)
        XCTAssertEqual(reader.localBookmark, originalBookmark, "A display receipt is not a new main-reading coordinate")
        reader.selectFocus(try XCTUnwrap(first.diagram.diagram.choice(for: "prepay")))
        let focused = try XCTUnwrap(reader.fullscreenDiagram)
        XCTAssertFalse(focused.isDisplayed)
        reader.reportFullscreenDiagramDisplayed(first.observation)
        XCTAssertFalse(try XCTUnwrap(reader.fullscreenDiagram).isDisplayed)
        reader.reportFullscreenDiagramDisplayed(focused.observation)
        reader.reportFullscreenDiagramDisplayed(focused.observation)
        let displayed = try XCTUnwrap(reader.fullscreenDiagram)
        XCTAssertTrue(displayed.isDisplayed)
        XCTAssertEqual(displayed.observation, focused.observation)
        reader.dismissPresentation(displayed.presentationToken)
        reader.reportFullscreenDiagramDisplayed(displayed.observation)
        guard case .diagram(let returned) = reader.page else { return XCTFail() }
        XCTAssertEqual(returned.restorePosition, ReadingPosition(anchorID: "explanation"))
        reader.enlargeDiagram()
        reader.reportFullscreenDiagramDisplayed(displayed.observation)
        XCTAssertFalse(try XCTUnwrap(reader.fullscreenDiagram).isDisplayed)
    }

    func testEnlargeIsOnlyAvailableForAnUncoveredDiagram() throws {
        var reader = StudyReader(study: try Self.publication.get())
        reader.enlargeDiagram()
        XCTAssertNil(reader.fullscreenDiagram)
        reader.switchMode(.report)
        reader.enlargeDiagram()
        XCTAssertNil(reader.fullscreenDiagram)
        reader.switchMode(.diagram)
        guard case .overview(let overview) = reader.page else { return XCTFail() }
        reader.follow(overview.beginOrResume)
        guard case .diagram(let diagram) = reader.page else { return XCTFail() }
        reader.follow(diagram.focus.explanation)
        reader.enlargeDiagram()
        XCTAssertNil(reader.fullscreenDiagram)
        reader.back()
        reader.enlargeDiagram()
        XCTAssertNotNil(reader.fullscreenDiagram)
    }

    func testReturningToTheSameFocusRequiresItsNewDisplayReceipt() throws {
        var reader = try openedReader()
        reader.enlargeDiagram()
        let initial = try XCTUnwrap(reader.fullscreenDiagram)
        reader.reportFullscreenDiagramDisplayed(initial.observation)
        reader.selectFocus(try XCTUnwrap(initial.diagram.diagram.choice(for: "prepay")))
        reader.selectFocus(try XCTUnwrap(initial.diagram.diagram.choice(for: "delivery")))
        let returned = try XCTUnwrap(reader.fullscreenDiagram)
        XCTAssertEqual(returned.diagram.focus.id, initial.diagram.focus.id)
        XCTAssertEqual(returned.diagram.visitID, initial.diagram.visitID)
        XCTAssertNotEqual(returned.observation, initial.observation)
        reader.reportFullscreenDiagramDisplayed(initial.observation)
        XCTAssertFalse(try XCTUnwrap(reader.fullscreenDiagram).isDisplayed)
        reader.reportFullscreenDiagramDisplayed(returned.observation)
        XCTAssertTrue(try XCTUnwrap(reader.fullscreenDiagram).isDisplayed)
    }

    func testForeignViewerCannotSelectConfirmOrCloseThisPresentation() throws {
        var reader = try openedReader()
        var other = try openedReader()
        reader.enlargeDiagram()
        other.enlargeDiagram()
        let own = try XCTUnwrap(reader.fullscreenDiagram)
        let foreign = try XCTUnwrap(other.fullscreenDiagram)
        reader.selectFocus(try XCTUnwrap(foreign.diagram.diagram.choice(for: "warranty")))
        reader.reportFullscreenDiagramDisplayed(foreign.observation)
        reader.dismissPresentation(foreign.presentationToken)
        let unchanged = try XCTUnwrap(reader.fullscreenDiagram)
        XCTAssertEqual(unchanged.presentationToken, own.presentationToken)
        XCTAssertEqual(unchanged.diagram.focus.id, "delivery")
        XCTAssertFalse(unchanged.isDisplayed)
    }

    func testChangingFullscreenFocusKeepsTheAnchorAndOnlyClearsOffsetsInsideChangedText() throws {
        for anchor in ["heading", "diagram", "explanation", "limits"] {
            var reader = try openedReader()
            guard case .diagram(let source) = reader.page else { return XCTFail() }
            let position = ReadingPosition(anchorID: anchor, localOffset: 42)
            reader.reportVisiblePosition(source.observation, position: position, cause: .userBrowsing)
            reader.enlargeDiagram()
            let unchanged = try XCTUnwrap(reader.fullscreenDiagram)
            reader.dismissPresentation(unchanged.presentationToken)
            guard case .diagram(let sameFocus) = reader.page else { return XCTFail() }
            XCTAssertEqual(sameFocus.restorePosition, position, "Opening without changing focus preserves the exact source")
            reader.enlargeDiagram()
            let viewer = try XCTUnwrap(reader.fullscreenDiagram)
            reader.selectFocus(try XCTUnwrap(viewer.diagram.diagram.choice(for: "prepay")))
            reader.dismissPresentation(viewer.presentationToken)
            guard case .diagram(let changed) = reader.page else { return XCTFail() }
            let expected = ["explanation", "limits"].contains(anchor) ? ReadingPosition(anchorID: anchor) : position
            XCTAssertEqual(changed.restorePosition, expected, "Source anchor: " + anchor)
            XCTAssertEqual(changed.focus.id, "prepay")
            XCTAssertEqual(changed.visitID, source.visitID)
        }
    }
}
