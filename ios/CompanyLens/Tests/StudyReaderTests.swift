import Foundation
import XCTest
import ResearchCore

final class StudyReaderTests: XCTestCase {
    private static let publication = Result {
        try ReadableStudy(root: URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("Study"))
    }

    private func study() throws -> ReadableStudy { try Self.publication.get() }

    private func reportOnlyStudy(in root: URL) throws -> ReadableStudy {
        try FileManager.default.copyItem(at: study().resources.root, to: root)
        try FileManager.default.removeItem(at: root.appendingPathComponent("reading.json"))
        func object(_ name: String) throws -> [String: Any] {
            try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: root.appendingPathComponent(name))) as? [String: Any])
        }
        var snapshot = try object("snapshot.json")
        var files = try XCTUnwrap(snapshot["files"] as? [String: String])
        files.removeValue(forKey: "reading.json")
        snapshot["files"] = files
        let snapshotData = try JSONSerialization.data(withJSONObject: snapshot, options: [.sortedKeys])
        try snapshotData.write(to: root.appendingPathComponent("snapshot.json"))
        var manifest = try object("resource-manifest.json")
        manifest["snapshotManifestSHA256"] = ReadingLibrary.sha256(snapshotData)
        var datasets = try XCTUnwrap(manifest["datasets"] as? [[String: Any]])
        datasets.removeAll { $0["file"] as? String == "reading.json" }
        let index = try XCTUnwrap(datasets.firstIndex { $0["file"] as? String == "snapshot.json" })
        datasets[index]["sha256"] = ReadingLibrary.sha256(snapshotData)
        datasets[index]["bytes"] = snapshotData.count
        manifest["datasets"] = datasets
        try JSONSerialization.data(withJSONObject: manifest, options: [.sortedKeys])
            .write(to: root.appendingPathComponent("resource-manifest.json"))
        return try ReadableStudy(root: root)
    }

    func testOverviewOpensPublishedSceneWithResolvedDiagramAndDefaultFocus() throws {
        var reader = StudyReader(study: try study())
        guard case .overview(let overview) = reader.page else { return XCTFail("Start with the research overview") }
        XCTAssertEqual(overview.title, "一家公司，连起来看。")
        reader.follow(overview.beginOrResume)
        guard case .diagram(let page) = reader.page else { return XCTFail("Open the first published scene") }
        XCTAssertEqual(page.sceneID, "business-delivery")
        XCTAssertEqual(page.focus.id, "delivery")
        XCTAssertEqual(page.diagram.raw.id, "business")
        XCTAssertEqual(page.ordinal, 1)
        XCTAssertTrue(page.essentialNotes.contains("还不知道满意度调查问了谁、哪些人没回答，投诉怎样才算解决；也缺公司以外的人核实的实际服务结果。"))
        XCTAssertNotNil(page.focus.evidence)
        XCTAssertNil(page.focus.calculations)
        XCTAssertNotNil(page.diagram.choice(for: "warranty"))
        XCTAssertNil(page.diagram.choice(for: "cash-recent"))
    }

    func testFreeJumpAdvancesFromCurrentSceneAndBackRestoresActualSource() throws {
        var reader = StudyReader(study: try study())
        guard case .overview(let start) = reader.page else { return XCTFail() }
        reader.follow(start.beginOrResume)
        guard case .diagram(let first) = reader.page else { return XCTFail() }
        reader.follow(first.overview)
        guard case .overview(let overview) = reader.page else { return XCTFail() }
        reader.follow(try XCTUnwrap(overview.entries.first { $0.sceneID == "capital-choices" }).link)
        reader.advanceMainline()
        guard case .diagram(let next) = reader.page else { return XCTFail() }
        XCTAssertEqual(next.sceneID, "company-boundary")
        XCTAssertTrue(reader.navigation.canGoBack)
        reader.back()
        guard case .diagram(let jumped) = reader.page else { return XCTFail() }
        XCTAssertEqual(jumped.sceneID, "capital-choices")
        reader.back()
        guard case .diagram(let origin) = reader.page else { return XCTFail() }
        XCTAssertEqual(origin.sceneID, "business-delivery")
    }

    func testFocusChangesStayInPlaceAndReturnRestoresSourcesOwnFocus() throws {
        var reader = StudyReader(study: try study())
        guard case .overview(let start) = reader.page else { return XCTFail() }
        reader.follow(start.beginOrResume)
        guard case .diagram(let original) = reader.page else { return XCTFail() }
        reader.selectFocus(try XCTUnwrap(original.diagram.choice(for: "prepay")))
        reader.selectFocus(try XCTUnwrap(original.diagram.choice(for: "rebate")))
        reader.advanceMainline()
        guard case .diagram(let next) = reader.page else { return XCTFail() }
        XCTAssertEqual(next.sceneID, "business-prepay")
        XCTAssertEqual(next.focus.id, "prepay")
        reader.selectFocus(try XCTUnwrap(next.diagram.choice(for: "warranty")))
        reader.back()
        guard case .diagram(let returned) = reader.page else { return XCTFail() }
        XCTAssertEqual(returned.sceneID, "business-delivery")
        XCTAssertEqual(returned.focus.id, "rebate")
        XCTAssertEqual(returned.essentialNotes, original.essentialNotes)
        reader.back()
        guard case .overview = reader.page else { return XCTFail("Focus changes must not add back steps") }
    }

    func testContentPositionReturnsToSourceAndRejectsAnOldVisit() throws {
        var reader = StudyReader(study: try study())
        guard case .overview(let start) = reader.page else { return XCTFail() }
        reader.follow(start.beginOrResume)
        guard case .diagram(let source) = reader.page else { return XCTFail() }
        let position = ReadingPosition(anchorID: "explanation", localOffset: 42)
        reader.reportVisiblePosition(source.observation, position: position, cause: .userBrowsing)
        reader.advanceMainline()
        guard case .diagram(let next) = reader.page else { return XCTFail() }
        XCTAssertEqual(next.restorePosition, ReadingPosition(anchorID: "heading"))
        reader.reportVisiblePosition(source.observation,
            position: ReadingPosition(anchorID: "limits"), cause: .userBrowsing)
        reader.back()
        guard case .diagram(let returned) = reader.page else { return XCTFail() }
        XCTAssertEqual(returned.restorePosition, position)
        reader.reportVisiblePosition(source.observation,
            position: ReadingPosition(anchorID: "limits"), cause: .userBrowsing)
        guard case .diagram(let unchanged) = reader.page else { return XCTFail() }
        XCTAssertEqual(unchanged.restorePosition, position)
    }

    func testLegacyDetailsKeepPrimaryContentAndDismissExactlyOnce() throws {
        var reader = StudyReader(study: try study())
        guard case .overview(let start) = reader.page else { return XCTFail() }
        reader.follow(start.beginOrResume)
        guard case .diagram(let source) = reader.page else { return XCTFail() }
        reader.follow(source.focus.explanation)
        guard case .legacyPresentation(let detail) = reader.page else { return XCTFail("Open the explanation") }
        XCTAssertEqual(detail.text, "用户得到产品后，还需要装好、能用、坏了有人管。格力披露了这些安排；是否每次都做好，还要继续核实。")
        XCTAssertEqual(detail.study.identity, try study().identity)
        guard case .diagram(let background) = reader.primaryPage else { return XCTFail("Keep the source mounted") }
        XCTAssertEqual(background.sceneID, "business-delivery")
        reader.dismissPresentation(detail.presentationToken)
        reader.dismissPresentation(detail.presentationToken)
        guard case .diagram(let returned) = reader.page else { return XCTFail("A late close must not return twice") }
        XCTAssertEqual(returned.focus.id, "delivery")
    }

    func testLocalBookmarkResumesTheVersionAndPreservesExactBackSource() throws {
        let book = try study()
        var reader = StudyReader(study: book)
        guard case .overview(let start) = reader.page else { return XCTFail() }
        reader.follow(start.beginOrResume)
        guard case .diagram(let source) = reader.page else { return XCTFail() }
        reader.selectFocus(try XCTUnwrap(source.diagram.choice(for: "rebate")))
        guard case .diagram(let selected) = reader.page else { return XCTFail() }
        let anchor = ReadingPosition(anchorID: "explanation", localOffset: 37)
        reader.reportVisiblePosition(selected.observation, position: anchor, cause: .userBrowsing)
        reader.advanceMainline()
        let bytes = try XCTUnwrap(reader.localBookmark)
        var restored = StudyReader(study: book, bookmark: bytes)
        guard case .diagram(let resumed) = restored.page else { return XCTFail() }
        XCTAssertEqual(resumed.sceneID, "business-prepay")
        restored.back()
        guard case .diagram(let origin) = restored.page else { return XCTFail() }
        XCTAssertEqual(origin.focus.id, "rebate")
        XCTAssertEqual(origin.restorePosition, anchor)
    }

    func testExistingVisualBookmarkMigratesFocusAndBackSource() throws {
        let book = try study()
        let legacy: [String: Any] = ["schemaVersion": 1,
            "momentIDs": try XCTUnwrap(book.reading).document.sceneOrder,
            "currentID": "business-prepay", "focus": "warranty", "isOverview": false,
            "history": [["id": "business-delivery", "focus": "rebate"]]]
        let bytes = try JSONSerialization.data(withJSONObject: legacy)
        var reader = StudyReader(study: book, bookmark: bytes)
        guard case .diagram(let resumed) = reader.page else { return XCTFail("Migrate the existing bookmark") }
        XCTAssertEqual(resumed.focus.id, "warranty")
        reader.back()
        guard case .diagram(let source) = reader.page else { return XCTFail() }
        XCTAssertEqual(source.sceneID, "business-delivery")
        XCTAssertEqual(source.focus.id, "rebate")
        XCTAssertNotNil(reader.localBookmark)
    }

    func testFocusKeepsSemanticAnchorAndRejectsOldLayoutAndProgrammaticObservations() throws {
        var reader = StudyReader(study: try study())
        guard case .overview(let start) = reader.page else { return XCTFail() }
        XCTAssertEqual(start.restorePosition, ReadingPosition(anchorID: "overview"))
        reader.follow(start.beginOrResume)
        guard case .diagram(let source) = reader.page else { return XCTFail() }
        XCTAssertEqual(source.restorePosition, ReadingPosition(anchorID: "heading"))
        reader.reportVisiblePosition(source.observation,
            position: ReadingPosition(anchorID: "explanation", localOffset: 42), cause: .userBrowsing)
        reader.selectFocus(try XCTUnwrap(source.diagram.choice(for: "warranty")))
        guard case .diagram(let selected) = reader.page else { return XCTFail() }
        let expected = ReadingPosition(anchorID: "explanation")
        XCTAssertEqual(selected.restorePosition, expected)
        reader.reportVisiblePosition(source.observation,
            position: ReadingPosition(anchorID: "limits"), cause: .userBrowsing)
        reader.reportVisiblePosition(selected.observation,
            position: ReadingPosition(anchorID: "diagram"), cause: .programmatic)
        guard case .diagram(let unchanged) = reader.page else { return XCTFail() }
        XCTAssertEqual(unchanged.restorePosition, expected)
        reader.reportVisiblePosition(selected.observation,
            position: ReadingPosition(anchorID: "diagram"), cause: .userBrowsing)
        guard case .diagram(let browsed) = reader.page else { return XCTFail() }
        XCTAssertEqual(browsed.restorePosition, ReadingPosition(anchorID: "diagram"))
        XCTAssertEqual(browsed.observation, selected.observation, "Accepting position does not invalidate the observer")
    }

    func testBookmarkRecoversValidSceneWhenFocusOrLocalPositionIsObsolete() throws {
        let book = try study()
        var reader = StudyReader(study: book)
        guard case .overview(let start) = reader.page else { return XCTFail() }
        reader.follow(start.beginOrResume)
        var saved = try XCTUnwrap(JSONSerialization.jsonObject(with: XCTUnwrap(reader.localBookmark)) as? [String: Any])
        saved["current"] = ["sceneID": "business-delivery", "focusID": "removed-focus",
                            "position": ["anchorID": "explanation", "localOffset": 42]]
        let recovered = StudyReader(study: book, bookmark: try JSONSerialization.data(withJSONObject: saved))
        guard case .diagram(let page) = recovered.page else { return XCTFail("Keep the valid scene") }
        XCTAssertEqual(page.focus.id, "delivery")
        XCTAssertEqual(page.restorePosition, ReadingPosition(anchorID: "explanation"))
        saved["current"] = ["sceneID": "business-delivery", "focusID": "delivery",
                            "position": ["anchorID": "removed-paragraph", "localOffset": 42]]
        let invalidAnchor = StudyReader(study: book, bookmark: try JSONSerialization.data(withJSONObject: saved))
        guard case .diagram(let fallback) = invalidAnchor.page else { return XCTFail() }
        XCTAssertEqual(fallback.restorePosition, ReadingPosition(anchorID: "heading"))
    }

    func testReportOnlyPublicationUsesReportAdapterWithoutInventingDiagram() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("reader-report-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        var reader = StudyReader(study: try reportOnlyStudy(in: root))
        guard case .legacyPresentation(let report) = reader.page else { return XCTFail("Open the full report") }
        guard case .report = report.kind else { return XCTFail() }
        XCTAssertEqual(report.claims.count, 25)
        XCTAssertFalse(reader.navigation.canGoBack)
        reader.back()
        guard case .legacyPresentation = reader.page else { return XCTFail("Do not invent a diagram source") }
    }

    func testMainlineEndKeepsLastContentAndExplicitOverviewCanResumeOrRestart() throws {
        var reader = StudyReader(study: try study())
        guard case .overview(let start) = reader.page else { return XCTFail() }
        reader.follow(try XCTUnwrap(start.entries.first { $0.sceneID == "shareholder-returns" }).link)
        reader.advanceMainline()
        guard case .diagram(let end) = reader.page else { return XCTFail() }
        XCTAssertEqual(end.sceneID, "whole-company")
        XCTAssertTrue(end.isMainlineEnd)
        XCTAssertTrue(reader.navigation.isMainlineEnd)
        XCTAssertFalse(reader.navigation.canAdvanceMainline)
        reader.advanceMainline()
        guard case .diagram(let stayed) = reader.page else { return XCTFail("Keep the final content") }
        XCTAssertEqual(stayed.sceneID, "whole-company")
        XCTAssertEqual(stayed.observation, end.observation)
        reader.follow(stayed.overview)
        guard case .overview(let overview) = reader.page else { return XCTFail() }
        reader.follow(overview.beginOrResume)
        guard case .diagram(let resumed) = reader.page else { return XCTFail() }
        XCTAssertEqual(resumed.sceneID, "whole-company")
        reader.follow(resumed.overview)
        guard case .overview(let restart) = reader.page else { return XCTFail() }
        reader.follow(restart.restart)
        guard case .diagram(let first) = reader.page else { return XCTFail() }
        XCTAssertEqual(first.sceneID, "business-delivery")
        reader.back()
        guard case .overview = reader.page else { return XCTFail("Restart discards the old navigation path") }
    }

    func testBackgroundAndLateDetailCallbacksCannotChangeTheCurrentVisit() throws {
        var reader = StudyReader(study: try study())
        guard case .overview(let start) = reader.page else { return XCTFail() }
        reader.follow(start.beginOrResume)
        guard case .diagram(let source) = reader.page else { return XCTFail() }
        let sourcePosition = ReadingPosition(anchorID: "diagram", localOffset: 8)
        reader.reportVisiblePosition(source.observation, position: sourcePosition, cause: .userBrowsing)
        reader.follow(source.focus.explanation)
        guard case .legacyPresentation(let explanation) = reader.page else { return XCTFail() }
        reader.reportVisiblePosition(source.observation,
            position: ReadingPosition(anchorID: "explanation"), cause: .userBrowsing)
        reader.back()
        guard case .diagram(let returned) = reader.page else { return XCTFail() }
        XCTAssertEqual(returned.restorePosition, sourcePosition)
        reader.follow(try XCTUnwrap(returned.focus.evidence))
        guard case .legacyPresentation(let evidence) = reader.page else { return XCTFail() }
        reader.dismissPresentation(explanation.presentationToken)
        reader.reportVisiblePosition(explanation.observation,
            position: ReadingPosition(anchorID: "detail", localOffset: 90), cause: .userBrowsing)
        guard case .legacyPresentation(let current) = reader.page else { return XCTFail("Keep the new presentation") }
        XCTAssertEqual(current.presentationToken, evidence.presentationToken)
        XCTAssertEqual(current.restorePosition, ReadingPosition(anchorID: "detail"))
    }

    func testAnotherReaderAndOldFocusCannotSupplyNavigationOrObservations() throws {
        let book = try study()
        var reader = StudyReader(study: book)
        var other = StudyReader(study: book)
        guard case .overview(let start) = reader.page, case .overview(let otherStart) = other.page else { return XCTFail() }
        reader.follow(start.beginOrResume)
        other.follow(otherStart.beginOrResume)
        guard case .diagram(let original) = reader.page, case .diagram(let foreign) = other.page else { return XCTFail() }
        reader.selectFocus(try XCTUnwrap(foreign.diagram.choice(for: "warranty")))
        reader.follow(foreign.focus.explanation)
        reader.reportVisiblePosition(foreign.observation,
            position: ReadingPosition(anchorID: "limits"), cause: .userBrowsing)
        reader.selectFocus(try XCTUnwrap(original.diagram.choice(for: "prepay")))
        reader.follow(original.focus.explanation)
        guard case .diagram(let selected) = reader.page else { return XCTFail("Reject the old focus link") }
        XCTAssertEqual(selected.focus.id, "prepay")
        XCTAssertEqual(selected.restorePosition, ReadingPosition(anchorID: "heading"))
    }

    func testCorruptOrDifferentVersionBookmarkReturnsToOverviewWithNotice() throws {
        let book = try study()
        let invalid = StudyReader(study: book, bookmark: Data("broken".utf8))
        guard case .overview = invalid.page else { return XCTFail() }
        XCTAssertNotNil(invalid.notice)
        var reader = StudyReader(study: book)
        guard case .overview(let start) = reader.page else { return XCTFail() }
        reader.follow(start.beginOrResume)
        var saved = try XCTUnwrap(JSONSerialization.jsonObject(with: XCTUnwrap(reader.localBookmark)) as? [String: Any])
        var identity = try XCTUnwrap(saved["identity"] as? [String: Any])
        identity["snapshotManifestSHA256"] = String(repeating: "0", count: 64)
        saved["identity"] = identity
        let mismatched = StudyReader(study: book, bookmark: try JSONSerialization.data(withJSONObject: saved))
        guard case .overview = mismatched.page else { return XCTFail("Do not apply another exact version's position") }
        XCTAssertNotNil(mismatched.notice)
    }
}
