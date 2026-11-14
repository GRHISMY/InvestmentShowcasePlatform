import Foundation
import XCTest
import ResearchCore

final class ReadingRecordTests: XCTestCase {
    private static let publication = Result {
        try ReadableStudy(root: URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .deletingLastPathComponent().appendingPathComponent("Study"))
    }
    private func study() throws -> ReadableStudy { try Self.publication.get() }
    private final class Clock { var time = Date(timeIntervalSince1970: 100) }

    func testActualVisibleMainReadingEmitsOnlyMainAndCurrentModeAtTheObservationTime() throws {
        let time = Date(timeIntervalSince1970: 1000)
        let book = try study()
        var reader = StudyReader(study: book, clock: { time })
        guard case .overview(let overview) = reader.page else { return XCTFail() }
        reader.follow(overview.beginOrResume)
        XCTAssertNil(reader.checkpoint, "Choosing content is not proof that it was displayed")
        guard case .diagram(let diagram) = reader.page else { return XCTFail() }
        let position = ReadingPosition(anchorID: "explanation")
        reader.reportVisiblePosition(diagram.observation, position: position, cause: .programmatic)
        reader.reportVisiblePosition(diagram.observation, position: position, cause: .restoration)
        XCTAssertNil(reader.checkpoint)
        reader.reportVisiblePosition(diagram.observation, position: position, cause: .userNavigation)
        let checkpoint = try XCTUnwrap(reader.checkpoint)
        XCTAssertEqual(checkpoint.identity, book.identity)
        XCTAssertEqual(checkpoint.updates.map(\.slotKey), [ReadingCheckpoint.mainSlotKey, "mode:diagram"])
        XCTAssertTrue(checkpoint.updates.allSatisfy { $0.occurredAt == time && !$0.payload.isEmpty })
    }

    func testRestoreSkipsInvalidMainAndRespectsTheNextSuppliedCandidateWithoutResorting() throws {
        let book = try study()
        var source = StudyReader(study: book, clock: { Date(timeIntervalSince1970: 100) })
        guard case .overview(let overview) = source.page else { return XCTFail() }
        source.follow(overview.beginOrResume)
        guard case .diagram(let first) = source.page else { return XCTFail() }
        source.reportVisiblePosition(first.observation,
            position: ReadingPosition(anchorID: "explanation"), cause: .userBrowsing)
        let firstSlot = try XCTUnwrap(source.checkpoint?.updates.first { $0.slotKey == ReadingCheckpoint.mainSlotKey })
        source.advanceMainline()
        guard case .diagram(let second) = source.page else { return XCTFail() }
        source.reportVisiblePosition(second.observation, position: ReadingPosition(anchorID: "heading"), cause: .userBrowsing)
        let secondSlot = try XCTUnwrap(source.checkpoint?.updates.first { $0.slotKey == ReadingCheckpoint.mainSlotKey })
        let corruptedText = try XCTUnwrap(String(data: firstSlot.payload, encoding: .utf8))
            .replacingOccurrences(of: "business-delivery", with: "removed-scene")
        let invalid = ReadingSlotCheckpoint(slotKey: firstSlot.slotKey, payload: Data(corruptedText.utf8),
            occurredAt: Date(timeIntervalSince1970: 400))
        let laterButNotSelected = ReadingSlotCheckpoint(slotKey: secondSlot.slotKey, payload: secondSlot.payload,
            occurredAt: Date(timeIntervalSince1970: 300))
        var restored = StudyReader(study: book,
            restoreCandidates: RestoreCandidates(identity: book.identity, candidates: [invalid, firstSlot, laterButNotSelected]))
        guard case .diagram(let page) = restored.page else { return XCTFail("Try the next valid supplied main candidate") }
        XCTAssertEqual(page.sceneID, "business-delivery")
        XCTAssertEqual(page.restorePosition, ReadingPosition(anchorID: "explanation"))
        XCTAssertNotEqual(page.visitID, first.visitID)
        XCTAssertNil(restored.checkpoint, "Restoring must not invent a new occurrence")
        restored.reportVisiblePosition(first.observation, position: ReadingPosition(anchorID: "limits"), cause: .userBrowsing)
        XCTAssertNil(restored.checkpoint, "A restored visit cannot retain the old activation's authority")
    }

    func testDetailObservationsUpdateOnlyTheirOwnSlotAndRepeatedReadingIsANewEvent() throws {
        let clock = Clock()
        var reader = StudyReader(study: try study(), clock: { clock.time })
        reader.switchMode(.report)
        guard case .report(let report) = reader.page else { return XCTFail() }
        reader.reportVisiblePosition(report.observation,
            position: ReadingPosition(anchorID: report.summaryAnchor.id), cause: .userNavigation)
        let main = try XCTUnwrap(reader.checkpoint)
        let claim = try XCTUnwrap(report.sections.flatMap(\.claims).first { $0.claim.id == "gree-2026-cash-drivers" })
        reader.follow(try XCTUnwrap(claim.calculations))
        XCTAssertEqual(reader.checkpoint, main, "Opening alone must not stamp any slot")
        guard case .detail(.calculations(let calculation)) = reader.page else { return XCTFail() }
        let position = ReadingPosition(anchorID: try XCTUnwrap(calculation.items.first?.inputs.first).anchor.id)
        clock.time = Date(timeIntervalSince1970: 200)
        reader.reportVisiblePosition(calculation.observation, position: position, cause: .userNavigation)
        let first = try XCTUnwrap(reader.checkpoint)
        XCTAssertEqual(first.updates.count, 1)
        XCTAssertTrue(try XCTUnwrap(first.updates.first).slotKey.hasPrefix("detail:"))
        XCTAssertEqual(first.updates.first?.occurredAt, clock.time)
        XCTAssertNotEqual(first.eventID, main.eventID)
        reader.reportVisiblePosition(calculation.observation, position: position, cause: .userBrowsing)
        let reread = try XCTUnwrap(reader.checkpoint)
        XCTAssertNotEqual(reread.eventID, first.eventID, "Equal coordinates and equal clock values do not suppress an actual reread")
        XCTAssertEqual(reread.updates.first?.slotKey, first.updates.first?.slotKey)
        reader.reportVisiblePosition(calculation.observation, position: position, cause: .restoration)
        XCTAssertEqual(reader.checkpoint, reread)
    }

    func testModeAndDetailSlotsRestoreTheirOwnValidCandidatesWithoutReplacingTheMainSelection() throws {
        let book = try study()
        var source = StudyReader(study: book)
        source.switchMode(.report)
        guard case .report(let report) = source.page else { return XCTFail() }
        let judgment = try XCTUnwrap(report.sections.flatMap(\.claims).first { $0.claim.id == "gree-latest-quarter" })
        let reportPosition = ReadingPosition(anchorID: try XCTUnwrap(judgment.anchor(for: .known)).id, localOffset: 23)
        source.reportVisiblePosition(report.observation, position: reportPosition, cause: .userBrowsing)
        let reportSlot = try XCTUnwrap(source.checkpoint?.updates.first { $0.slotKey == "mode:report" })
        let claim = try XCTUnwrap(report.sections.flatMap(\.claims).first { $0.claim.id == "gree-2026-cash-drivers" })
        source.follow(try XCTUnwrap(claim.calculations))
        guard case .detail(.calculations(let calculation)) = source.page else { return XCTFail() }
        let detailPosition = ReadingPosition(anchorID: try XCTUnwrap(calculation.items.first?.inputs.first).anchor.id, localOffset: 7)
        source.reportVisiblePosition(calculation.observation, position: detailPosition, cause: .userBrowsing)
        let detailSlot = try XCTUnwrap(source.checkpoint?.updates.first)
        source.back()
        source.switchMode(.diagram)
        guard case .overview(let overview) = source.page else { return XCTFail() }
        source.follow(overview.beginOrResume)
        guard case .diagram(let diagram) = source.page else { return XCTFail() }
        source.reportVisiblePosition(diagram.observation, position: ReadingPosition(anchorID: "diagram"), cause: .userBrowsing)
        let main = try XCTUnwrap(source.checkpoint?.updates.first { $0.slotKey == ReadingCheckpoint.mainSlotKey })
        let wrongMode = ReadingSlotCheckpoint(slotKey: reportSlot.slotKey, payload: main.payload, occurredAt: Date())
        let invalidDetail = ReadingSlotCheckpoint(slotKey: detailSlot.slotKey, payload: Data("broken".utf8), occurredAt: Date())
        var restored = StudyReader(study: book, restoreCandidates: RestoreCandidates(identity: book.identity,
            records: [main, wrongMode, reportSlot, invalidDetail, detailSlot].map { RestoreCandidate(checkpoint: $0, isLocalDevice: true) }))
        guard case .diagram(let selected) = restored.page else { return XCTFail() }
        XCTAssertEqual(selected.sceneID, "business-delivery")
        restored.switchMode(.report)
        guard case .report(let restoredReport) = restored.page else { return XCTFail() }
        XCTAssertEqual(restoredReport.restorePosition, reportPosition)
        let reopened = try XCTUnwrap(restoredReport.sections.flatMap(\.claims).first { $0.claim.id == "gree-2026-cash-drivers" })
        restored.follow(try XCTUnwrap(reopened.calculations))
        guard case .detail(.calculations(let detail)) = restored.page else { return XCTFail() }
        XCTAssertEqual(detail.restorePosition, detailPosition)
        XCTAssertNil(restored.checkpoint)

        var remote = StudyReader(study: book, restoreCandidates: RestoreCandidates(identity: book.identity,
            candidates: [main, reportSlot, detailSlot]))
        remote.switchMode(.report)
        guard case .report(let remoteReport) = remote.page else { return XCTFail() }
        XCTAssertEqual(remoteReport.restorePosition, ReadingPosition(anchorID: reportPosition.anchorID))
        let remoteClaim = try XCTUnwrap(remoteReport.sections.flatMap(\.claims).first { $0.claim.id == "gree-2026-cash-drivers" })
        remote.follow(try XCTUnwrap(remoteClaim.calculations))
        guard case .detail(.calculations(let remoteDetail)) = remote.page else { return XCTFail() }
        XCTAssertEqual(remoteDetail.restorePosition, ReadingPosition(anchorID: detailPosition.anchorID))
    }

    func testPDFEmitsOnlyActualBrowsingAndKeepsItsOriginalTimeWhenLoadReadyArrivesLater() throws {
        let clock = Clock()
        let book = try study()
        var reader = StudyReader(study: book, clock: { clock.time })
        reader.switchMode(.report)
        guard case .report(let report) = reader.page else { return XCTFail() }
        reader.reportVisiblePosition(report.observation,
            position: ReadingPosition(anchorID: report.summaryAnchor.id), cause: .userNavigation)
        let main = try XCTUnwrap(reader.checkpoint)
        let claim = try XCTUnwrap(report.sections.flatMap(\.claims).first { $0.claim.id == "gree-cash" })
        reader.follow(try XCTUnwrap(claim.evidence))
        guard case .detail(.evidence(let evidence)) = reader.page else { return XCTFail() }
        reader.openCitation(try XCTUnwrap(evidence.items.first { $0.id == "e-cfo" }?.citations.first).target)
        guard case .detail(.pdf(let pdf)) = reader.page else { return XCTFail() }
        reader.reportPDFPage(pdf.request.observation, physicalPage: 29, cause: .programmatic)
        XCTAssertEqual(reader.checkpoint, main)
        clock.time = Date(timeIntervalSince1970: 200)
        reader.reportPDFPage(pdf.request.observation, physicalPage: 35, cause: .userBrowsing)
        XCTAssertEqual(reader.checkpoint, main, "Buffer until the opened document is verified")
        clock.time = Date(timeIntervalSince1970: 300)
        reader.reportPDFLoad(pdf.request.attempt, result: .success(219))
        let browsing = try XCTUnwrap(reader.checkpoint)
        XCTAssertEqual(browsing.updates.map(\.slotKey), ["pdf:" + pdf.document.id])
        XCTAssertEqual(browsing.updates.first?.occurredAt, Date(timeIntervalSince1970: 200))
        reader.reportPDFPage(pdf.request.observation, physicalPage: 29, cause: .programmatic)
        XCTAssertEqual(reader.checkpoint, browsing)
        clock.time = Date(timeIntervalSince1970: 400)
        reader.reportPDFPage(pdf.request.observation, physicalPage: 35, cause: .userBrowsing)
        let reread = try XCTUnwrap(reader.checkpoint)
        XCTAssertNotEqual(reread.eventID, browsing.eventID)
        XCTAssertEqual(reread.updates.first?.occurredAt, clock.time)
        reader.back()
        reader.reportPDFPage(pdf.request.observation, physicalPage: 99, cause: .userBrowsing)
        XCTAssertEqual(reader.checkpoint, reread)
    }

    func testPDFRestoreRejectsAnOutOfRangeCandidateAndKeepsCitationDistinctFromResume() throws {
        let book = try study()
        var source = StudyReader(study: book)
        source.switchMode(.report)
        guard case .report(let report) = source.page else { return XCTFail() }
        let claim = try XCTUnwrap(report.sections.flatMap(\.claims).first { $0.claim.id == "gree-cash" })
        source.follow(try XCTUnwrap(claim.evidence))
        guard case .detail(.evidence(let evidence)) = source.page else { return XCTFail() }
        source.openCitation(try XCTUnwrap(evidence.items.first { $0.id == "e-cfo" }?.citations.first).target)
        guard case .detail(.pdf(let opened)) = source.page else { return XCTFail() }
        source.reportPDFLoad(opened.request.attempt, result: .success(219))
        source.reportPDFPage(opened.request.observation, physicalPage: 35, cause: .userBrowsing)
        let slot = try XCTUnwrap(source.checkpoint?.updates.first)
        let invalidText = try XCTUnwrap(String(data: slot.payload, encoding: .utf8))
            .replacingOccurrences(of: ":35", with: ":999")
        let invalid = ReadingSlotCheckpoint(slotKey: slot.slotKey, payload: Data(invalidText.utf8), occurredAt: Date())
        var restored = StudyReader(study: book,
            restoreCandidates: RestoreCandidates(identity: book.identity, candidates: [invalid, slot]))
        restored.switchMode(.report)
        guard case .report(let main) = restored.page else { return XCTFail() }
        restored.follow(try XCTUnwrap(main.sections.flatMap(\.claims).first { $0.claim.id == "gree-cash" }?.evidence))
        guard case .detail(.evidence(let restoredEvidence)) = restored.page else { return XCTFail() }
        restored.continuePDF(try XCTUnwrap(restoredEvidence.items.first { $0.id == "e-cfo" }).source.resume)
        guard case .detail(.pdf(let resumed)) = restored.page else { return XCTFail() }
        XCTAssertEqual(resumed.request.targetPhysicalPage, 35)
        XCTAssertNil(restored.checkpoint)
        restored.back()
        guard case .detail(.evidence(let latest)) = restored.page else { return XCTFail() }
        restored.openCitation(try XCTUnwrap(latest.items.first { $0.id == "e-cfo" }?.citations.first).target)
        guard case .detail(.pdf(let citation)) = restored.page else { return XCTFail() }
        XCTAssertEqual(citation.request.targetPhysicalPage, 29)
        XCTAssertEqual(citation.resumePhysicalPage, 35)
    }

    func testIdenticalCheckpointValuesKeepLocalOffsetsOnlyWhenTheirDeviceProvenanceIsLocal() throws {
        let book = try study()
        var source = StudyReader(study: book)
        guard case .overview(let overview) = source.page else { return XCTFail() }
        source.follow(overview.beginOrResume)
        guard case .diagram(let diagram) = source.page else { return XCTFail() }
        let position = ReadingPosition(anchorID: "diagram", localOffset: 42)
        source.reportVisiblePosition(diagram.observation, position: position, cause: .userBrowsing)
        let slot = try XCTUnwrap(source.checkpoint?.updates.first)
        let local = StudyReader(study: book, restoreCandidates: RestoreCandidates(identity: book.identity,
            records: [RestoreCandidate(checkpoint: slot, isLocalDevice: true)]))
        let remote = StudyReader(study: book, restoreCandidates: RestoreCandidates(identity: book.identity,
            records: [RestoreCandidate(checkpoint: slot, isLocalDevice: false)]))
        guard case .diagram(let localPage) = local.page, case .diagram(let remotePage) = remote.page else { return XCTFail() }
        XCTAssertEqual(localPage.restorePosition, position)
        XCTAssertEqual(remotePage.restorePosition, ReadingPosition(anchorID: "diagram"))
        let defaultRemote = StudyReader(study: book,
            restoreCandidates: RestoreCandidates(identity: book.identity, candidates: [slot]))
        guard case .diagram(let conservative) = defaultRemote.page else { return XCTFail() }
        XCTAssertEqual(conservative.restorePosition?.localOffset, nil)
    }

    func testFullscreenRecordsOnlyTheConfirmedFocusAndNeverStoresItsViewportAsAMainPosition() throws {
        let clock = Clock()
        let book = try study()
        var reader = StudyReader(study: book, clock: { clock.time })
        guard case .overview(let overview) = reader.page else { return XCTFail() }
        reader.follow(overview.beginOrResume)
        guard case .diagram(let main) = reader.page else { return XCTFail() }
        let position = ReadingPosition(anchorID: "limits", localOffset: 42)
        reader.reportVisiblePosition(main.observation, position: position, cause: .userNavigation)
        let initial = try XCTUnwrap(reader.checkpoint)
        reader.enlargeDiagram()
        let first = try XCTUnwrap(reader.fullscreenDiagram)
        reader.selectFocus(try XCTUnwrap(first.diagram.diagram.choice(for: "prepay")))
        XCTAssertEqual(reader.checkpoint, initial)
        let focused = try XCTUnwrap(reader.fullscreenDiagram)
        clock.time = Date(timeIntervalSince1970: 200)
        reader.reportFullscreenDiagramDisplayed(first.observation)
        XCTAssertEqual(reader.checkpoint, initial)
        reader.reportFullscreenDiagramDisplayed(focused.observation)
        let visible = try XCTUnwrap(reader.checkpoint)
        XCTAssertNotEqual(visible.eventID, initial.eventID)
        XCTAssertEqual(visible.updates.map(\.slotKey), [ReadingCheckpoint.mainSlotKey, "mode:diagram"])
        XCTAssertTrue(visible.updates.allSatisfy { $0.occurredAt == clock.time })
        reader.reportFullscreenDiagramDisplayed(focused.observation)
        XCTAssertEqual(reader.checkpoint, visible, "The same display receipt is idempotent")
        clock.time = Date(timeIntervalSince1970: 300)
        reader.reportVisiblePosition(focused.observation,
            position: ReadingPosition(anchorID: "diagram", localOffset: 999), cause: .userBrowsing)
        let reread = try XCTUnwrap(reader.checkpoint)
        XCTAssertNotEqual(reread.eventID, visible.eventID)
        let restored = StudyReader(study: book, restoreCandidates: RestoreCandidates(identity: book.identity, candidates: reread.updates))
        guard case .diagram(let restoredMain) = restored.page else { return XCTFail() }
        XCTAssertEqual(restoredMain.focus.id, "prepay")
        XCTAssertEqual(restoredMain.restorePosition, ReadingPosition(anchorID: "limits"))
        XCTAssertNil(restored.fullscreenDiagram)
        XCTAssertNil(restored.checkpoint)
    }

    func testValidNewMainClearsAnInvalidLegacyNoticeAndInvalidNewMainCanUseValidLegacy() throws {
        let book = try study()
        var source = StudyReader(study: book)
        guard case .overview(let overview) = source.page else { return XCTFail() }
        source.follow(overview.beginOrResume)
        guard case .diagram(let diagram) = source.page else { return XCTFail() }
        source.reportVisiblePosition(diagram.observation, position: ReadingPosition(anchorID: "diagram"), cause: .userBrowsing)
        let slot = try XCTUnwrap(source.checkpoint?.updates.first)
        let valid = StudyReader(study: book, bookmark: Data("bad legacy".utf8),
            restoreCandidates: RestoreCandidates(identity: book.identity, candidates: [slot]))
        guard case .diagram = valid.page else { return XCTFail() }
        XCTAssertNil(valid.notice, "A valid new main must not inherit the rejected legacy warning")
        let invalidSlot = ReadingSlotCheckpoint(slotKey: ReadingCheckpoint.mainSlotKey,
            payload: Data("bad candidate".utf8), occurredAt: Date())
        let fallback = StudyReader(study: book, bookmark: try XCTUnwrap(source.localBookmark),
            restoreCandidates: RestoreCandidates(identity: book.identity, candidates: [invalidSlot]))
        guard case .diagram(let legacy) = fallback.page else { return XCTFail("Retain the valid local fallback") }
        XCTAssertEqual(legacy.restorePosition?.anchorID, "diagram")
        XCTAssertNotNil(fallback.notice)
        let none = StudyReader(study: book,
            restoreCandidates: RestoreCandidates(identity: book.identity, candidates: [invalidSlot]))
        guard case .overview = none.page else { return XCTFail() }
        XCTAssertNotNil(none.notice)
        XCTAssertNil(none.checkpoint)
    }

    func testMainCheckpointPreservesSemanticBackSourcesAcrossReopenWithFreshAuthority() throws {
        let book = try study()
        var source = StudyReader(study: book)
        guard case .overview(let overview) = source.page else { return XCTFail() }
        source.follow(overview.beginOrResume)
        guard case .diagram(let initial) = source.page else { return XCTFail() }
        source.selectFocus(try XCTUnwrap(initial.diagram.choice(for: "warranty")))
        guard case .diagram(let graph) = source.page else { return XCTFail() }
        let position = ReadingPosition(anchorID: "limits", localOffset: 42)
        source.reportVisiblePosition(graph.observation, position: position, cause: .userBrowsing)
        source.follow(try XCTUnwrap(graph.relatedReports.first { $0.id == "gree-service" }).link)
        guard case .report(let report) = source.page else { return XCTFail() }
        source.reportVisiblePosition(report.observation,
            position: try XCTUnwrap(report.restorePosition), cause: .userNavigation)
        let checkpoint = try XCTUnwrap(source.checkpoint)
        for local in [true, false] {
            var restored = StudyReader(study: book, restoreCandidates: RestoreCandidates(identity: book.identity,
                records: checkpoint.updates.map { RestoreCandidate(checkpoint: $0, isLocalDevice: local) }))
            guard case .report = restored.page else { return XCTFail() }
            restored.back()
            guard case .diagram(let returned) = restored.page else { return XCTFail("Back must retain the actual source after reopen") }
            XCTAssertEqual(returned.focus.id, "warranty")
            XCTAssertEqual(returned.restorePosition, local ? position : ReadingPosition(anchorID: "limits"))
            XCTAssertNotEqual(returned.visitID, graph.visitID)
            restored.reportVisiblePosition(graph.observation,
                position: ReadingPosition(anchorID: "heading"), cause: .userBrowsing)
            XCTAssertNil(restored.checkpoint)
        }
    }

    func testClosingBeforeANewFullscreenFocusIsDisplayedRecordsOnlyItsLaterMainArrival() throws {
        let book = try study()
        var reader = StudyReader(study: book)
        guard case .overview(let overview) = reader.page else { return XCTFail() }
        reader.follow(overview.beginOrResume)
        guard case .diagram(let first) = reader.page else { return XCTFail() }
        reader.reportVisiblePosition(first.observation,
            position: ReadingPosition(anchorID: "limits", localOffset: 42), cause: .userNavigation)
        let initial = try XCTUnwrap(reader.checkpoint)
        reader.enlargeDiagram()
        let viewer = try XCTUnwrap(reader.fullscreenDiagram)
        reader.selectFocus(try XCTUnwrap(viewer.diagram.diagram.choice(for: "prepay")))
        let pending = try XCTUnwrap(reader.fullscreenDiagram)
        reader.dismissPresentation(pending.presentationToken)
        XCTAssertEqual(reader.checkpoint, initial, "Closing is not a display receipt")
        guard case .diagram(let main) = reader.page else { return XCTFail() }
        XCTAssertEqual(main.focus.id, "prepay")
        XCTAssertEqual(main.restorePosition, ReadingPosition(anchorID: "limits"))
        XCTAssertEqual(main.arrivalCause, .userNavigation)
        reader.reportFullscreenDiagramDisplayed(pending.observation)
        XCTAssertEqual(reader.checkpoint, initial, "The closed viewer cannot confirm the new focus")
        reader.reportVisiblePosition(main.observation, position: try XCTUnwrap(main.restorePosition), cause: main.arrivalCause)
        XCTAssertNotEqual(reader.checkpoint?.eventID, initial.eventID)
    }

    func testInvalidPreferredMainExplainsFallbackToAnotherValidCandidateWithoutLosingItsVersion() throws {
        let book = try study()
        var source = StudyReader(study: book)
        guard case .overview(let overview) = source.page else { return XCTFail() }
        source.follow(overview.beginOrResume)
        guard case .diagram(let first) = source.page else { return XCTFail() }
        source.reportVisiblePosition(first.observation,
            position: ReadingPosition(anchorID: "heading"), cause: .userBrowsing)
        let preferred = try XCTUnwrap(source.checkpoint?.updates.first)
        let invalidText = try XCTUnwrap(String(data: preferred.payload, encoding: .utf8))
            .replacingOccurrences(of: "business-delivery", with: "removed-scene")
        let invalid = ReadingSlotCheckpoint(slotKey: ReadingCheckpoint.mainSlotKey,
            payload: Data(invalidText.utf8), occurredAt: preferred.occurredAt)
        source.advanceMainline()
        guard case .diagram(let next) = source.page else { return XCTFail() }
        source.reportVisiblePosition(next.observation,
            position: ReadingPosition(anchorID: "explanation"), cause: .userBrowsing)
        let valid = try XCTUnwrap(source.checkpoint?.updates.first)
        for bookmark in [nil, Data("unusable legacy".utf8)] as [Data?] {
            let restored = StudyReader(study: book, bookmark: bookmark,
                restoreCandidates: RestoreCandidates(identity: book.identity, candidates: [invalid, valid]))
            guard case .diagram(let actual) = restored.page else { return XCTFail("Retain the valid fallback") }
            XCTAssertEqual(actual.sceneID, next.sceneID)
            XCTAssertEqual(actual.restorePosition, ReadingPosition(anchorID: "explanation"))
            let notice = try XCTUnwrap(restored.notice, "Do not silently replace the selected invalid position")
            XCTAssertTrue(notice.contains("失效"))
            XCTAssertTrue(notice.contains("其他可用位置"))
            XCTAssertNil(restored.checkpoint, "Fallback restores without inventing an actual reading")
        }
    }
}
