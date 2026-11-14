import Foundation
import XCTest
import ResearchCore

final class ReportReadingTests: XCTestCase {
    private static let publication = Result {
        try ReadableStudy(root: URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("Study"))
    }
    private func study() throws -> ReadableStudy { try Self.publication.get() }

    func testReportContainsEveryPublishedJudgmentDimensionsAndMonitoring() throws {
        var reader = StudyReader(study: try study())
        reader.switchMode(.report)
        guard case .report(let page) = reader.page else { return XCTFail("Read the complete report") }
        XCTAssertEqual(page.company.name, "格力电器")
        XCTAssertEqual(page.sections.count, 5)
        XCTAssertEqual(page.sections.flatMap(\.claims).count, 25)
        XCTAssertEqual(page.dimensions.count, 5)
        XCTAssertEqual(page.monitoring.count, 13)
        let claim = try XCTUnwrap(page.sections.flatMap(\.claims).first { $0.claim.id == "gree-debt-maturity" })
        XCTAssertFalse(claim.claim.statement.isEmpty, "A judgment omitted from the diagrams remains in the report")
        XCTAssertNotNil(claim.anchor(for: .known))
        XCTAssertEqual(page.restorePosition, ReadingPosition(anchorID: page.summaryAnchor.id))
        XCTAssertEqual(reader.availableModes, [.diagram, .report])
    }

    func testOrdinaryModeSwitchRestoresEachModesLocationAndSourceIdentity() throws {
        var reader = StudyReader(study: try study())
        guard case .overview(let overview) = reader.page else { return XCTFail() }
        reader.follow(overview.beginOrResume)
        guard case .diagram(let original) = reader.page else { return XCTFail() }
        reader.selectFocus(try XCTUnwrap(original.diagram.choice(for: "rebate")))
        guard case .diagram(let focused) = reader.page else { return XCTFail() }
        let diagramPosition = ReadingPosition(anchorID: "limits", localOffset: 12)
        reader.reportVisiblePosition(focused.observation, position: diagramPosition, cause: .userBrowsing)
        reader.switchMode(.report)
        guard case .report(let report) = reader.page else { return XCTFail() }
        let judgment = try XCTUnwrap(report.sections.flatMap(\.claims).first { $0.claim.id == "gree-latest-quarter" })
        let reportPosition = ReadingPosition(anchorID: try XCTUnwrap(judgment.anchor(for: .known)).id, localOffset: 20)
        reader.reportVisiblePosition(report.observation, position: reportPosition, cause: .userBrowsing)
        reader.switchMode(.diagram)
        guard case .diagram(let restoredDiagram) = reader.page else { return XCTFail("Restore the diagram, not its overview") }
        XCTAssertEqual(restoredDiagram.focus.id, "rebate")
        XCTAssertEqual(restoredDiagram.restorePosition, diagramPosition)
        XCTAssertEqual(restoredDiagram.visitID, original.visitID)
        XCTAssertNotEqual(restoredDiagram.observation, original.observation)
        reader.switchMode(.report)
        guard case .report(let restoredReport) = reader.page else { return XCTFail() }
        XCTAssertEqual(restoredReport.restorePosition, reportPosition)
        XCTAssertEqual(restoredReport.visitID, report.visitID)
        reader.back()
        guard case .diagram(let source) = reader.page else { return XCTFail("Switching also preserves the actual source") }
        XCTAssertEqual(source.restorePosition, diagramPosition)
    }

    func testReportIndexLinkTargetsTheJudgmentAndBackRestoresReportOrigin() throws {
        var reader = StudyReader(study: try study())
        reader.switchMode(.report)
        guard case .report(let source) = reader.page else { return XCTFail() }
        let link = try XCTUnwrap(source.headlineClaims.first { $0.id == "gree-latest-quarter" })
        reader.follow(link.link)
        guard case .report(let target) = reader.page else { return XCTFail() }
        let claim = try XCTUnwrap(target.sections.flatMap(\.claims).first { $0.claim.id == "gree-latest-quarter" })
        XCTAssertEqual(target.restorePosition, ReadingPosition(anchorID: try XCTUnwrap(claim.anchor(for: .heading)).id))
        XCTAssertNotEqual(target.visitID, source.visitID)
        reader.back()
        guard case .report(let returned) = reader.page else { return XCTFail() }
        XCTAssertEqual(returned.visitID, source.visitID)
        XCTAssertEqual(returned.restorePosition, ReadingPosition(anchorID: source.summaryAnchor.id))
    }

    func testDeclaredAssociationsTargetExplicitContentAndReturnThroughActualSources() throws {
        var reader = StudyReader(study: try study())
        guard case .overview(let overview) = reader.page else { return XCTFail() }
        reader.follow(try XCTUnwrap(overview.entries.first { $0.sceneID == "profit-change" }).link)
        guard case .diagram(let original) = reader.page else { return XCTFail() }
        reader.switchMode(.report)
        guard case .report(let priorReport) = reader.page else { return XCTFail() }
        let prior = try XCTUnwrap(priorReport.sections.flatMap(\.claims).first { $0.claim.id == "gree-service" })
        reader.reportVisiblePosition(priorReport.observation,
            position: ReadingPosition(anchorID: try XCTUnwrap(prior.anchor(for: .known)).id), cause: .userBrowsing)
        reader.switchMode(.diagram)
        guard case .diagram(let source) = reader.page else { return XCTFail() }
        let related = try XCTUnwrap(source.relatedReports.first { $0.id == "gree-latest-quarter" })
        reader.follow(related.link)
        guard case .report(let report) = reader.page else { return XCTFail() }
        let judgment = try XCTUnwrap(report.sections.flatMap(\.claims).first { $0.claim.id == "gree-latest-quarter" })
        XCTAssertEqual(report.restorePosition, ReadingPosition(anchorID: try XCTUnwrap(judgment.anchor(for: .heading)).id),
                       "Explicit Q wins over the report's saved P")
        XCTAssertEqual(judgment.relatedDiagrams.count, 7)
        XCTAssertEqual(judgment.relatedDiagrams.filter { $0.sceneID == "profit-change" }.count, 3)
        let target = try XCTUnwrap(judgment.relatedDiagrams.first { $0.sceneID == "whole-company" && $0.focusID == "profit-unknown" })
        let reportPosition = ReadingPosition(anchorID: try XCTUnwrap(judgment.anchor(for: .known)).id, localOffset: 17)
        reader.reportVisiblePosition(report.observation, position: reportPosition, cause: .userBrowsing)
        reader.follow(target.link)
        guard case .diagram(let graphB) = reader.page else { return XCTFail() }
        XCTAssertEqual(graphB.sceneID, "whole-company")
        XCTAssertEqual(graphB.focus.id, "profit-unknown")
        reader.back()
        guard case .report(let returnedReport) = reader.page else { return XCTFail() }
        XCTAssertEqual(returnedReport.visitID, report.visitID)
        XCTAssertEqual(returnedReport.restorePosition, reportPosition)
        reader.back()
        guard case .diagram(let returnedDiagram) = reader.page else { return XCTFail() }
        XCTAssertEqual(returnedDiagram.visitID, original.visitID)
        XCTAssertEqual(returnedDiagram.focus.id, "profit-observation")
    }

    func testReportJudgmentOpensItsResolvedChecksAndReturnsToReportPosition() throws {
        var reader = StudyReader(study: try study())
        reader.switchMode(.report)
        guard case .report(let report) = reader.page else { return XCTFail() }
        let claim = try XCTUnwrap(report.sections.flatMap(\.claims).first { $0.claim.id == "gree-2026-cash-drivers" })
        let position = ReadingPosition(anchorID: try XCTUnwrap(claim.anchor(for: .meaning)).id, localOffset: 24)
        reader.reportVisiblePosition(report.observation, position: position, cause: .userBrowsing)
        reader.follow(try XCTUnwrap(claim.calculations))
        guard case .detail(.calculations(let calculation)) = reader.page else { return XCTFail() }
        XCTAssertEqual(calculation.title, "2026年销售收款减少，收回贷款补了一部分")
        XCTAssertEqual(calculation.items.map(\.id), ["calc-q3-cfo-change", "calc-q3-sales-change", "calc-q3-loan-contribution"])
        guard case .report(let background) = reader.primaryPage else { return XCTFail() }
        XCTAssertEqual(background.visitID, report.visitID)
        reader.dismissPresentation(try XCTUnwrap(reader.presentationPath.last).token)
        guard case .report(let returned) = reader.page else { return XCTFail() }
        XCTAssertEqual(returned.restorePosition, position)
        let current = try XCTUnwrap(returned.sections.flatMap(\.claims).first { $0.claim.id == "gree-2026-cash-drivers" })
        reader.follow(try XCTUnwrap(current.evidence))
        guard case .detail(.evidence(let evidence)) = reader.page else { return XCTFail() }
        XCTAssertEqual(evidence.items.map(\.id), ["e-q3-cfo26", "e-q3-cfo25", "e-q3-sales26", "e-q3-sales25", "e-q3-loans26", "e-q3-loans25"])
        XCTAssertTrue(evidence.items.allSatisfy { $0.uses.contains { $0.claimTitle == evidence.title } })
        reader.back()
        guard case .report(let source) = reader.page else { return XCTFail() }
        XCTAssertEqual(source.visitID, report.visitID)
        XCTAssertEqual(source.restorePosition, position)
    }

    func testEachOverviewRetainsItsOwnSourceAcrossModeAndRelatedReading() throws {
        var reader = StudyReader(study: try study())
        guard case .overview(let start) = reader.page else { return XCTFail() }
        reader.follow(start.beginOrResume)
        guard case .diagram(let graphA) = reader.page else { return XCTFail() }
        reader.follow(graphA.overview)
        guard case .overview(let overviewA) = reader.page else { return XCTFail() }
        reader.switchMode(.report)
        guard case .report(let report) = reader.page else { return XCTFail() }
        let claim = try XCTUnwrap(report.sections.flatMap(\.claims).first { $0.claim.id == "gree-service" })
        reader.follow(try XCTUnwrap(claim.relatedDiagrams.first { $0.sceneID == "business-prepay" && $0.focusID == "delivery" }).link)
        guard case .diagram(let graphB) = reader.page else { return XCTFail() }
        reader.follow(graphB.overview)
        reader.switchMode(.report)
        reader.back()
        reader.back()
        guard case .diagram(let returnedB) = reader.page else { return XCTFail() }
        XCTAssertEqual(returnedB.visitID, graphB.visitID)
        reader.back()
        reader.back()
        guard case .overview(let returnedOverview) = reader.page else { return XCTFail() }
        XCTAssertEqual(returnedOverview.visitID, overviewA.visitID)
        reader.back()
        guard case .diagram(let returnedA) = reader.page else { return XCTFail("The earlier overview must retain its own source") }
        XCTAssertEqual(returnedA.visitID, graphA.visitID)
    }

    func testModesAndTheirSourceIdentitiesSurviveLocalReopen() throws {
        let book = try study()
        var reader = StudyReader(study: book)
        guard case .overview(let start) = reader.page else { return XCTFail() }
        reader.follow(start.beginOrResume)
        guard case .diagram(let original) = reader.page else { return XCTFail() }
        reader.selectFocus(try XCTUnwrap(original.diagram.choice(for: "rebate")))
        reader.switchMode(.report)
        guard case .report(let report) = reader.page else { return XCTFail() }
        reader.follow(try XCTUnwrap(report.headlineClaims.first { $0.id == "gree-latest-quarter" }).link)
        guard case .report(let chosen) = reader.page else { return XCTFail() }
        var restored = StudyReader(study: book, bookmark: try XCTUnwrap(reader.localBookmark))
        guard case .report(let reopened) = restored.page else { return XCTFail() }
        XCTAssertEqual(reopened.visitID, chosen.visitID)
        XCTAssertEqual(reopened.restorePosition, chosen.restorePosition)
        restored.switchMode(.diagram)
        guard case .diagram(let diagram) = restored.page else { return XCTFail() }
        XCTAssertEqual(diagram.focus.id, "rebate")
        XCTAssertEqual(diagram.visitID, original.visitID)
        XCTAssertNotEqual(diagram.observation, original.observation)
    }

    func testUnrelatedJudgmentHasNoInventedDiagramAndFocusListsAllDeclaredReports() throws {
        var reader = StudyReader(study: try study())
        reader.switchMode(.report)
        guard case .report(let report) = reader.page else { return XCTFail() }
        let noDiagram = try XCTUnwrap(report.sections.flatMap(\.claims).first { $0.claim.id == "gree-profit" })
        XCTAssertTrue(noDiagram.relatedDiagrams.isEmpty)
        reader.switchMode(.diagram)
        guard case .overview(let overview) = reader.page else { return XCTFail() }
        reader.follow(overview.beginOrResume)
        guard case .diagram(let original) = reader.page else { return XCTFail() }
        XCTAssertEqual(original.relatedReports.map(\.id), ["gree-partner-financing", "gree-service"])
        reader.selectFocus(try XCTUnwrap(original.diagram.choice(for: "warranty")))
        guard case .diagram(let selected) = reader.page else { return XCTFail() }
        XCTAssertEqual(selected.relatedReports.map(\.id), ["gree-service", "gree-economic-scarcity", "gree-partner-financing"])
    }

    func testRevisitingSameSceneCreatesDistinctSourceButBackRestoresFirstIdentityAndRejectsOldTokens() throws {
        var reader = StudyReader(study: try study())
        guard case .overview(let start) = reader.page else { return XCTFail() }
        reader.follow(start.beginOrResume)
        guard case .diagram(let firstA) = reader.page else { return XCTFail() }
        reader.advanceMainline()
        guard case .diagram(let graphB) = reader.page else { return XCTFail() }
        reader.follow(graphB.overview)
        guard case .overview(let map) = reader.page else { return XCTFail() }
        reader.follow(try XCTUnwrap(map.entries.first { $0.sceneID == "business-delivery" }).link)
        guard case .diagram(let secondA) = reader.page else { return XCTFail() }
        XCTAssertNotEqual(secondA.visitID, firstA.visitID)
        reader.back()
        guard case .diagram(let returnedB) = reader.page else { return XCTFail() }
        XCTAssertEqual(returnedB.visitID, graphB.visitID)
        reader.back()
        guard case .diagram(let returnedA) = reader.page else { return XCTFail() }
        XCTAssertEqual(returnedA.visitID, firstA.visitID)
        reader.selectFocus(try XCTUnwrap(firstA.diagram.choice(for: "warranty")))
        reader.reportVisiblePosition(firstA.observation, position: ReadingPosition(anchorID: "limits"), cause: .userBrowsing)
        guard case .diagram(let unchanged) = reader.page else { return XCTFail() }
        XCTAssertEqual(unchanged.focus.id, "delivery")
        XCTAssertEqual(unchanged.restorePosition, ReadingPosition(anchorID: "heading"))
    }

    func testPersistentReportContentsCanTargetAJudgmentOutsideTheHeadlines() throws {
        let publication = try study()
        var reader = StudyReader(study: publication)
        reader.switchMode(.report)
        guard case .report(let report) = reader.page else { return XCTFail() }
        XCTAssertEqual(report.contents.map(\.id), publication.research.orderedClaims.map(\.id))
        XCTAssertEqual(report.contents.count, 25)
        XCTAssertFalse(report.headlineClaims.contains { $0.id == "gree-profit" })
        reader.follow(try XCTUnwrap(report.contents.first { $0.id == "gree-profit" }).link)
        guard case .report(let target) = reader.page else { return XCTFail() }
        XCTAssertEqual(target.restorePosition, ReadingPosition(anchorID: "claim/gree-profit/heading"))
    }
}
