import Foundation
import XCTest
import ResearchCore

final class PDFReadingTests: XCTestCase {
    private static let publication = Result {
        try ReadableStudy(root: URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .deletingLastPathComponent().appendingPathComponent("Study"))
    }
    private func citationReader() throws -> (StudyReader, CitationContent) {
        var reader = StudyReader(study: try Self.publication.get())
        reader.switchMode(.report)
        guard case .report(let report) = reader.page else { throw FixtureError.missingContent }
        let claim = try XCTUnwrap(report.sections.flatMap(\.claims).first { $0.claim.id == "gree-cash" })
        reader.follow(try XCTUnwrap(claim.evidence))
        guard case .evidence(let evidence) = reader.presentationPath.last?.page else { throw FixtureError.missingContent }
        let citation = try XCTUnwrap(evidence.items.first { $0.id == "e-cfo" }?.citations.first)
        return (reader, citation)
    }
    private enum FixtureError: Error { case missingContent }

    func testCitationOpensItsPublishedPageAndFixedDocumentBeforeAnyLoadCallback() throws {
        var (reader, citation) = try citationReader()
        reader.openCitation(citation.target)
        guard case .pdf(let page) = reader.presentationPath.last?.page else { return XCTFail() }
        XCTAssertEqual(page.request.targetPhysicalPage, 29)
        XCTAssertEqual(page.currentCitation?.physicalPage, 29)
        XCTAssertEqual(page.document.pageCount, 219)
        XCTAssertEqual(page.document.fileURL, citation.document.fileURL)
        XCTAssertEqual(page.loadState, .loading)
        XCTAssertNil(page.visiblePhysicalPage)
        XCTAssertEqual(reader.presentationPath.count, 2)
    }

    func testPageBeforeLoadReadyIsAcceptedWithoutTurningAutomaticPlacementIntoResume() throws {
        var (reader, citation) = try citationReader()
        reader.openCitation(citation.target)
        guard case .pdf(let opening) = reader.presentationPath.last?.page else { return XCTFail() }
        reader.reportPDFPage(opening.request.observation, physicalPage: 29, cause: .programmatic)
        reader.reportPDFLoad(opening.request.attempt, result: .success(219))
        guard case .pdf(let loaded) = reader.presentationPath.last?.page else { return XCTFail() }
        XCTAssertEqual(loaded.loadState, .ready)
        XCTAssertEqual(loaded.visiblePhysicalPage, 29)
        XCTAssertNil(loaded.resumePhysicalPage)
        reader.reportPDFPage(loaded.request.observation, physicalPage: 50, cause: .userBrowsing)
        guard case .pdf(let browsed) = reader.presentationPath.last?.page else { return XCTFail() }
        XCTAssertEqual(browsed.resumePhysicalPage, 50)
    }

    func testCitation29PreservesResume50AndRecheckingDoesNotOverwriteManual35OrAddALayer() throws {
        var (reader, citation) = try citationReader()
        reader.openCitation(citation.target)
        guard case .pdf(let first) = reader.presentationPath.last?.page else { return XCTFail() }
        reader.reportPDFLoad(first.request.attempt, result: .success(219))
        reader.reportPDFPage(first.request.observation, physicalPage: 50, cause: .userBrowsing)
        reader.back()
        guard case .evidence(let evidence) = reader.presentationPath.last?.page else { return XCTFail() }
        reader.openCitation(try XCTUnwrap(evidence.items.first { $0.id == "e-cfo" }?.citations.first).target)
        guard case .pdf(let fresh) = reader.presentationPath.last?.page else { return XCTFail() }
        XCTAssertEqual(fresh.request.targetPhysicalPage, 29)
        XCTAssertEqual(fresh.resumePhysicalPage, 50)
        reader.reportPDFLoad(fresh.request.attempt, result: .success(219))
        reader.reportPDFPage(fresh.request.observation, physicalPage: 29, cause: .programmatic)
        reader.reportPDFPage(fresh.request.observation, physicalPage: 35, cause: .userBrowsing)
        guard case .pdf(let manual) = reader.presentationPath.last?.page else { return XCTFail() }
        reader.openCitation(try XCTUnwrap(manual.currentCitation).target)
        guard case .pdf(let located) = reader.presentationPath.last?.page else { return XCTFail() }
        XCTAssertEqual(reader.presentationPath.count, 2)
        XCTAssertEqual(located.visitID, manual.visitID)
        XCTAssertEqual(located.request.attempt, manual.request.attempt)
        XCTAssertNotEqual(located.request.placementID, manual.request.placementID)
        XCTAssertEqual(located.request.targetPhysicalPage, 29)
        reader.reportPDFPage(manual.request.observation, physicalPage: 100, cause: .userBrowsing)
        reader.reportPDFPage(located.request.observation, physicalPage: 29, cause: .programmatic)
        guard case .pdf(let verified) = reader.presentationPath.last?.page else { return XCTFail() }
        XCTAssertEqual(verified.resumePhysicalPage, 35)
        XCTAssertEqual(verified.visiblePhysicalPage, 29)
    }

    func testContinuingTheDocumentUsesItsResumeWithoutAddingAnotherPDFLayer() throws {
        var (reader, citation) = try citationReader()
        reader.openCitation(citation.target)
        guard case .pdf(let first) = reader.presentationPath.last?.page else { return XCTFail() }
        reader.reportPDFLoad(first.request.attempt, result: .success(219))
        reader.reportPDFPage(first.request.observation, physicalPage: 35, cause: .userBrowsing)
        guard case .pdf(let browsed) = reader.presentationPath.last?.page else { return XCTFail() }
        reader.continuePDF(browsed.document.resume)
        guard case .pdf(let resumed) = reader.presentationPath.last?.page else { return XCTFail() }
        XCTAssertEqual(resumed.request.targetPhysicalPage, 35)
        XCTAssertNil(resumed.request.focusText)
        XCTAssertEqual(resumed.currentCitation?.physicalPage, 29)
        XCTAssertEqual(resumed.visitID, first.visitID)
        XCTAssertEqual(reader.presentationPath.count, 2)
        reader.back()
        guard case .evidence(let evidence) = reader.presentationPath.last?.page else { return XCTFail() }
        reader.continuePDF(try XCTUnwrap(evidence.items.first { $0.id == "e-cfo" }).source.resume)
        guard case .pdf(let reopened) = reader.presentationPath.last?.page else { return XCTFail() }
        XCTAssertEqual(reopened.request.targetPhysicalPage, 35)
        XCTAssertNil(reopened.currentCitation)
    }

    func testRetryKeepsTheCitationAndSourceButRejectsThePreviousLoadAttempt() throws {
        var (reader, citation) = try citationReader()
        reader.openCitation(citation.target)
        guard case .pdf(let failedAttempt) = reader.presentationPath.last?.page else { return XCTFail() }
        reader.reportPDFLoad(failedAttempt.request.attempt, result: .failure(.missingFile))
        reader.retryPDF()
        guard case .pdf(let retry) = reader.presentationPath.last?.page else { return XCTFail() }
        XCTAssertEqual(retry.visitID, failedAttempt.visitID)
        XCTAssertEqual(retry.document.fileURL, failedAttempt.document.fileURL)
        XCTAssertEqual(retry.request.targetPhysicalPage, 29)
        XCTAssertNotEqual(retry.request.attempt, failedAttempt.request.attempt)
        reader.reportPDFLoad(failedAttempt.request.attempt, result: .success(219))
        reader.reportPDFPage(failedAttempt.request.observation, physicalPage: 99, cause: .userBrowsing)
        guard case .pdf(let pending) = reader.presentationPath.last?.page else { return XCTFail() }
        XCTAssertEqual(pending.loadState, .loading)
        XCTAssertNil(pending.resumePhysicalPage)
        reader.reportPDFLoad(retry.request.attempt, result: .success(218))
        guard case .pdf(let mismatch) = reader.presentationPath.last?.page else { return XCTFail() }
        XCTAssertEqual(mismatch.loadState, .failed(.pageCountMismatch))
        reader.retryPDF()
        guard case .pdf(let validAttempt) = reader.presentationPath.last?.page else { return XCTFail() }
        reader.reportPDFLoad(validAttempt.request.attempt, result: .success(219))
        reader.reportPDFPage(validAttempt.request.observation, physicalPage: 219, cause: .userBrowsing)
        guard case .pdf(let lastPage) = reader.presentationPath.last?.page else { return XCTFail() }
        XCTAssertEqual(lastPage.visiblePhysicalPage, 219)
        reader.back()
        XCTAssertEqual(reader.presentationPath.count, 1)
    }

    func testAnAutomaticReceiptArrivingAfterUserBrowsingCannotMoveTheVisiblePageBackward() throws {
        var (reader, citation) = try citationReader()
        reader.openCitation(citation.target)
        guard case .pdf(let page) = reader.presentationPath.last?.page else { return XCTFail() }
        reader.reportPDFLoad(page.request.attempt, result: .success(219))
        reader.reportPDFPage(page.request.observation, physicalPage: 35, cause: .userBrowsing)
        reader.reportPDFPage(page.request.observation, physicalPage: 29, cause: .programmatic)
        guard case .pdf(let current) = reader.presentationPath.last?.page else { return XCTFail() }
        XCTAssertEqual(current.visiblePhysicalPage, 35)
        XCTAssertEqual(current.resumePhysicalPage, 35)
    }

    func testClosingTheOuterBranchRejectsLateLoadPageAndCitationActions() throws {
        var (reader, citation) = try citationReader()
        guard case .report(let source) = reader.primaryPage else { return XCTFail() }
        reader.openCitation(citation.target)
        guard case .pdf(let pdf) = reader.presentationPath.last?.page else { return XCTFail() }
        let outerToken = try XCTUnwrap(reader.presentationPath.first).token
        reader.dismissPresentation(outerToken)
        reader.dismissPresentation(outerToken)
        reader.reportPDFLoad(pdf.request.attempt, result: .success(219))
        reader.reportPDFPage(pdf.request.observation, physicalPage: 99, cause: .userBrowsing)
        reader.openCitation(citation.target)
        XCTAssertTrue(reader.presentationPath.isEmpty)
        guard case .report(let main) = reader.page else { return XCTFail() }
        XCTAssertEqual(main.visitID, source.visitID)
        let claim = try XCTUnwrap(main.sections.flatMap(\.claims).first { $0.claim.id == "gree-cash" })
        reader.follow(try XCTUnwrap(claim.evidence))
        guard case .evidence(let evidence) = reader.presentationPath.last?.page else { return XCTFail() }
        reader.continuePDF(try XCTUnwrap(evidence.items.first { $0.id == "e-cfo" }).source.resume)
        guard case .pdf(let clean) = reader.presentationPath.last?.page else { return XCTFail() }
        XCTAssertEqual(clean.request.targetPhysicalPage, 1)
    }

    func testInvalidPagesAndDuplicateLoadResultsDoNotPolluteAReadyDocument() throws {
        var (reader, citation) = try citationReader()
        reader.openCitation(citation.target)
        guard case .pdf(let pdf) = reader.presentationPath.last?.page else { return XCTFail() }
        reader.reportPDFLoad(pdf.request.attempt, result: .success(219))
        reader.reportPDFPage(pdf.request.observation, physicalPage: 1, cause: .userBrowsing)
        for page in [-1, 0, 220] {
            reader.reportPDFPage(pdf.request.observation, physicalPage: page, cause: .userBrowsing)
        }
        reader.reportPDFLoad(pdf.request.attempt, result: .failure(.invalidDocument))
        guard case .pdf(let current) = reader.presentationPath.last?.page else { return XCTFail() }
        XCTAssertEqual(current.visiblePhysicalPage, 1)
        XCTAssertEqual(current.resumePhysicalPage, 1)
        XCTAssertEqual(current.loadState, .ready)
    }
}
