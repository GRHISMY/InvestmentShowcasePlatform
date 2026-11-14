import Foundation
import XCTest
import ResearchCore

final class DetailReadingTests: XCTestCase {
    private static let publication = Result {
        try ReadableStudy(root: URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .deletingLastPathComponent().appendingPathComponent("Study"))
    }
    private func reportReader() throws -> StudyReader {
        var reader = StudyReader(study: try Self.publication.get())
        reader.switchMode(.report)
        return reader
    }

    func testCalculationsResolveEveryInputAndEveryCitationFromTheReportContext() throws {
        var reader = try reportReader()
        guard case .report(let report) = reader.page else { return XCTFail() }
        let claim = try XCTUnwrap(report.sections.flatMap(\.claims).first { $0.claim.id == "gree-2026-cash-drivers" })
        reader.follow(try XCTUnwrap(claim.calculations))
        let presentation = try XCTUnwrap(reader.presentationPath.last)
        guard case .calculations(let page) = presentation.page else { return XCTFail() }
        XCTAssertEqual(page.items.map(\.id), ["calc-q3-cfo-change", "calc-q3-sales-change", "calc-q3-loan-contribution"])
        XCTAssertEqual(page.items.flatMap(\.inputs).count, 6)
        XCTAssertTrue(page.items.flatMap(\.inputs).allSatisfy { !$0.citations.isEmpty && !$0.evidence.isEmpty })
        let input = try XCTUnwrap(page.items.first?.inputs.first)
        XCTAssertEqual(input.fact.fact.id, "q3-cfo26")
        XCTAssertEqual(input.coefficient, "1")
        guard case .report(let background) = reader.primaryPage else { return XCTFail() }
        XCTAssertEqual(background.visitID, report.visitID)
    }

    func testAnInputEvidenceLinkShowsOnlyItsCompleteEvidenceWithPublishedUseAndAllPages() throws {
        var reader = try reportReader()
        guard case .report(let report) = reader.page else { return XCTFail() }
        let claim = try XCTUnwrap(report.sections.flatMap(\.claims).first { $0.claim.id == "gree-2026-cash-drivers" })
        reader.follow(try XCTUnwrap(claim.calculations))
        guard case .calculations(let calculations) = reader.presentationPath.last?.page else { return XCTFail() }
        let input = try XCTUnwrap(calculations.items.first?.inputs.first)
        reader.follow(try XCTUnwrap(input.evidence.first).link)
        guard case .evidence(let evidence) = reader.presentationPath.last?.page else { return XCTFail() }
        XCTAssertEqual(evidence.items.map(\.id), ["e-q3-cfo26"])
        let item = try XCTUnwrap(evidence.items.first)
        XCTAssertEqual(item.citations.map(\.physicalPage), item.evidence.physicalPages)
        XCTAssertTrue(item.uses.contains { $0.relation == "supports" && !$0.explanation.isEmpty })
        XCTAssertEqual(item.source.fileURL, try Self.publication.get().resources.pdfURL(sourceID: item.evidence.sourceId))
    }

    func testBackRestoresEveryDetailsOwnPositionAndRejectsItsOldActivation() throws {
        var reader = try reportReader()
        guard case .report(let report) = reader.page else { return XCTFail() }
        let claim = try XCTUnwrap(report.sections.flatMap(\.claims).first { $0.claim.id == "gree-2026-cash-drivers" })
        let mainPosition = ReadingPosition(anchorID: try XCTUnwrap(claim.anchor(for: .meaning)).id, localOffset: 18)
        reader.reportVisiblePosition(report.observation, position: mainPosition, cause: .userBrowsing)
        reader.follow(try XCTUnwrap(claim.calculations))
        guard case .calculations(let calculation) = reader.presentationPath.last?.page else { return XCTFail() }
        let input = try XCTUnwrap(calculation.items.first?.inputs.first)
        let position = ReadingPosition(anchorID: input.anchor.id, localOffset: 7)
        reader.reportVisiblePosition(calculation.observation, position: position, cause: .userBrowsing)
        reader.follow(try XCTUnwrap(input.evidence.first).link)
        reader.back()
        guard case .calculations(let returned) = reader.presentationPath.last?.page else { return XCTFail() }
        XCTAssertEqual(returned.visitID, calculation.visitID)
        XCTAssertEqual(returned.restorePosition, position)
        reader.reportVisiblePosition(calculation.observation, position: ReadingPosition(anchorID: "detail"), cause: .userBrowsing)
        guard case .calculations(let unchanged) = reader.presentationPath.last?.page else { return XCTFail() }
        XCTAssertEqual(unchanged.restorePosition, position)
        reader.back()
        XCTAssertTrue(reader.presentationPath.isEmpty)
        guard case .report(let main) = reader.page else { return XCTFail() }
        XCTAssertEqual(main.visitID, report.visitID)
        XCTAssertEqual(main.restorePosition, mainPosition)
    }

    func testLocalReopenStartsAtMainReadingAndRestoresDetailsOnlyWhenReopened() throws {
        var reader = try reportReader()
        guard case .report(let report) = reader.page else { return XCTFail() }
        let claim = try XCTUnwrap(report.sections.flatMap(\.claims).first { $0.claim.id == "gree-2026-cash-drivers" })
        reader.follow(try XCTUnwrap(claim.calculations))
        guard case .calculations(let calculations) = reader.presentationPath.last?.page else { return XCTFail() }
        let input = try XCTUnwrap(calculations.items.first?.inputs.first)
        let calculationPosition = ReadingPosition(anchorID: input.anchor.id, localOffset: 7)
        reader.reportVisiblePosition(calculations.observation, position: calculationPosition, cause: .userBrowsing)
        reader.follow(try XCTUnwrap(input.evidence.first).link)
        guard case .evidence(let evidence) = reader.presentationPath.last?.page else { return XCTFail() }
        let item = try XCTUnwrap(evidence.items.first)
        let evidencePosition = ReadingPosition(anchorID: item.anchor.id, localOffset: 4)
        reader.reportVisiblePosition(evidence.observation, position: evidencePosition, cause: .userBrowsing)
        reader.openCitation(try XCTUnwrap(item.citations.first).target)
        guard case .pdf(let pdf) = reader.presentationPath.last?.page else { return XCTFail() }
        reader.reportPDFLoad(pdf.request.attempt, result: .success(pdf.document.pageCount))
        reader.reportPDFPage(pdf.request.observation, physicalPage: 5, cause: .userBrowsing)
        var reopened = StudyReader(study: try Self.publication.get(), bookmark: try XCTUnwrap(reader.localBookmark))
        XCTAssertTrue(reopened.presentationPath.isEmpty)
        guard case .report(let main) = reopened.page else { return XCTFail("Startup remains main reading") }
        let same = try XCTUnwrap(main.sections.flatMap(\.claims).first { $0.claim.id == "gree-2026-cash-drivers" })
        reopened.follow(try XCTUnwrap(same.calculations))
        guard case .calculations(let restoredCalc) = reopened.presentationPath.last?.page else { return XCTFail() }
        XCTAssertEqual(restoredCalc.restorePosition, calculationPosition)
        reopened.follow(try XCTUnwrap(restoredCalc.items.first?.inputs.first?.evidence.first).link)
        guard case .evidence(let restoredEvidence) = reopened.presentationPath.last?.page else { return XCTFail() }
        XCTAssertEqual(restoredEvidence.restorePosition, evidencePosition)
        reopened.continuePDF(try XCTUnwrap(restoredEvidence.items.first).source.resume)
        guard case .pdf(let continued) = reopened.presentationPath.last?.page else { return XCTFail() }
        XCTAssertEqual(continued.request.targetPhysicalPage, 5)
    }

    func testFullExcerptsMultiplePagesAndQualitativeCounterEvidenceRemainAvailable() throws {
        for (claimID, evidenceID, expectedPages) in [
            ("gree-profit", "e-q3-costs", [6]),
            ("gree-dunan-headroom", "e-dunan-assumptions", [159, 160])
        ] {
            var reader = try reportReader()
            guard case .report(let report) = reader.page else { return XCTFail() }
            let claim = try XCTUnwrap(report.sections.flatMap(\.claims).first { $0.claim.id == claimID })
            reader.follow(try XCTUnwrap(claim.evidence))
            guard case .evidence(let evidence) = reader.presentationPath.last?.page else { return XCTFail() }
            let item = try XCTUnwrap(evidence.items.first { $0.id == evidenceID })
            XCTAssertEqual(item.citations.map(\.physicalPage), expectedPages)
            if evidenceID == "e-q3-costs" { XCTAssertEqual(item.evidence.excerpt.count, 1077) }
        }
        var qualitative = StudyReader(study: try Self.publication.get())
        guard case .overview(let overview) = qualitative.page else { return XCTFail() }
        qualitative.follow(overview.beginOrResume)
        guard case .diagram(let diagram) = qualitative.page else { return XCTFail() }
        XCTAssertNil(diagram.focus.calculations)
        qualitative.follow(try XCTUnwrap(diagram.focus.evidence))
        guard case .evidence(let page) = qualitative.presentationPath.last?.page else { return XCTFail() }
        XCTAssertTrue(try XCTUnwrap(page.items.first { $0.id == "resp-payables-boundary" }).isCounterEvidence)
    }
}
