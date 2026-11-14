// Standalone Foundation verification for hosts without the XCTest framework.
// Compile with Core/ReaderState.swift. These scenarios cross the same send Interface
// as the standard XCTest suite; they do not claim the XCTest runner was available.
import Foundation
func expectEqual<T: Equatable>(_ a: T, _ b: T, file: StaticString = #file, line: UInt = #line) {
    precondition(a == b, "Expected \(b), got \(a)", file: file, line: line)
}
func expectNil<T>(_ a: T?, file: StaticString = #file, line: UInt = #line) {
    precondition(a == nil, "Expected nil", file: file, line: line)
}

final class ReaderStateChecks {
    func testCalculationSourceBackPreservesClaimAndReadingPositions() {
        var reader = ReaderState()
        let claim = ReaderRoute.claim("cash")
        let evidence = ReaderRoute.evidence("cash")
        let calculation = ReaderRoute.calculation("cash")
        reader.send(.open(claim))
        reader.send(.rememberAnchor(route: claim, anchor: "reasoning-2"))
        reader.send(.open(evidence))
        reader.send(.rememberAnchor(route: evidence, anchor: "cash-p177"))
        reader.send(.open(calculation))
        reader.send(.rememberAnchor(route: calculation, anchor: "input-2"))
        reader.send(.open(.source(claimID: "cash", evidenceID: "cash-p177")))
        expectEqual(reader.pdfStatus, .loading("cash-p177"))

        reader.send(.pdfLoaded(evidenceID: "cash-p177", page: 177, pageCount: 230))
        reader.send(.backToDepth(3))
        expectEqual(reader.current, calculation)
        expectEqual(reader.pdfStatus, .idle)
        expectEqual(reader.anchor(for: calculation), "input-2")
        reader.send(.backToDepth(2))
        expectEqual(reader.current, evidence)
        expectEqual(reader.anchor(for: evidence), "cash-p177")
        reader.send(.backToDepth(1))
        expectEqual(reader.current, claim)
        expectEqual(reader.anchor(for: claim), "reasoning-2")
    }

    func testForeignClaimCannotReplaceEvidenceContext() {
        var reader = ReaderState()
        reader.send(.open(.claim("cash")))
        let original = reader
        reader.send(.open(.evidence("capital")))
        expectEqual(reader, original)
        reader.send(.open(.calculation("capital")))
        expectEqual(reader, original)
        reader.send(.open(.source(claimID: "capital", evidenceID: "capital-p154")))
        expectEqual(reader, original)
        reader.send(.open(.evidence("cash")))
        expectEqual(reader.current, .evidence("cash"))
    }

    func testGlossaryIsAnOverlayAndDoesNotLoseReadingPosition() {
        var reader = ReaderState()
        let route = ReaderRoute.claim("customer")
        reader.send(.open(route))
        reader.send(.rememberAnchor(route: route, anchor: "who-pays"))
        let path = reader.path
        let bookmarks = reader.bookmarks
        reader.send(.showGlossary("consolidated"))
        expectEqual(reader.glossaryID, "consolidated")
        expectEqual(reader.path, path)
        expectEqual(reader.bookmarks, bookmarks)
        reader.send(.dismissGlossary)
        expectNil(reader.glossaryID)
        expectEqual(reader.path, path)
        expectEqual(reader.anchor(for: route), "who-pays")
    }

    func testInvalidPDFPageFailsAndRetryKeepsSourceIdentity() {
        for invalid in [(0, 230), (231, 230), (1, 0), (-1, 230)] {
            var reader = ReaderState()
            reader.send(.open(.claim("cash")))
            reader.send(.open(.evidence("cash")))
            reader.send(.open(.source(claimID: "cash", evidenceID: "cash-p177")))
            reader.send(.pdfLoaded(evidenceID: "cash-p177", page: invalid.0, pageCount: invalid.1))
            expectEqual(reader.pdfStatus, .failed("cash-p177"))
            reader.send(.retryPDF)
            expectEqual(reader.pdfStatus, .loading("cash-p177"))
            reader.send(.pdfLoaded(evidenceID: "cash-p177", page: 177, pageCount: 230))
            expectEqual(reader.pdfStatus, .ready(evidenceID: "cash-p177", page: 177, pageCount: 230))
        }
    }

    func testStalePDFCallbacksCannotOverwriteCurrentSourceOrPoppedScreen() {
        var reader = ReaderState()
        reader.send(.open(.claim("cash")))
        reader.send(.open(.evidence("cash")))
        reader.send(.open(.source(claimID: "cash", evidenceID: "cash-p29")))
        reader.send(.backToDepth(2))
        reader.send(.open(.source(claimID: "cash", evidenceID: "cash-p177")))
        reader.send(.pdfLoaded(evidenceID: "cash-p29", page: 29, pageCount: 230))
        reader.send(.pdfFailed(evidenceID: "cash-p29"))
        expectEqual(reader.pdfStatus, .loading("cash-p177"))
        reader.send(.backToDepth(2))
        reader.send(.pdfLoaded(evidenceID: "cash-p177", page: 177, pageCount: 230))
        reader.send(.pdfFailed(evidenceID: "cash-p177"))
        expectEqual(reader.current, .evidence("cash"))
        expectEqual(reader.pdfStatus, .idle)
    }

    func testNativeBackOnlyShortensPathAndPreservesSummarySourceContext() {
        var reader = ReaderState()
        reader.send(.open(.dimension("profit")))
        reader.send(.rememberAnchor(route: .dimension("profit"), anchor: "report"))
        reader.send(.open(.source(claimID: nil, evidenceID: "profit-q3-p6")))
        let source = reader.current
        reader.send(.backToDepth(-1))
        reader.send(.backToDepth(8))
        reader.send(.backToDepth(2))
        expectEqual(reader.current, source)
        reader.send(.backToDepth(1))
        expectEqual(reader.current, .dimension("profit"))
        expectEqual(reader.anchor(for: .dimension("profit")), "report")
        expectEqual(reader.pdfStatus, .idle)
    }

    func testDimensionClaimEvidenceBackRestoresDimensionContext() {
        var reader = ReaderState()
        let dimension = ReaderRoute.dimension("cash")
        let claim = ReaderRoute.claim("cash")
        reader.send(.open(dimension))
        reader.send(.rememberAnchor(route: dimension, anchor: "related-claim"))
        reader.send(.open(claim))
        reader.send(.rememberAnchor(route: claim, anchor: "reasoning-2"))
        reader.send(.open(.evidence("cash")))
        expectEqual(reader.path, [dimension, claim, .evidence("cash")])
        reader.send(.backToDepth(2))
        expectEqual(reader.current, claim)
        expectEqual(reader.anchor(for: claim), "reasoning-2")
        reader.send(.backToDepth(1))
        expectEqual(reader.current, dimension)
        expectEqual(reader.anchor(for: dimension), "related-claim")
        expectEqual(reader.pdfStatus, .idle)
    }

    func testRoutesCannotSkipTheirReadingContext() {
        var reader = ReaderState()
        reader.send(.open(.evidence("cash")))
        reader.send(.open(.calculation("cash")))
        reader.send(.open(.source(claimID: nil, evidenceID: "cash-p177")))
        expectEqual(reader, ReaderState())

        reader.send(.open(.claim("cash")))
        let claimState = reader
        reader.send(.open(.calculation("cash")))
        reader.send(.open(.source(claimID: "cash", evidenceID: "cash-p177")))
        reader.send(.open(.claim("capital")))
        expectEqual(reader, claimState)

        reader.send(.open(.evidence("cash")))
        reader.send(.open(.calculation("cash")))
        let calculationState = reader
        reader.send(.open(.evidence("cash")))
        reader.send(.open(.dimension("profit")))
        expectEqual(reader, calculationState)
    }

    func testRetryOnlyRunsForCurrentFailedSourceAndResetClearsSession() {
        var reader = ReaderState()
        reader.send(.open(.claim("capital")))
        reader.send(.rememberAnchor(route: .claim("capital"), anchor: "limits"))
        reader.send(.retryPDF)
        expectEqual(reader.pdfStatus, .idle)
        reader.send(.open(.evidence("capital")))
        reader.send(.open(.source(claimID: "capital", evidenceID: "capital-p154")))
        reader.send(.pdfFailed(evidenceID: "capital-p154"))
        reader.send(.retryPDF)
        expectEqual(reader.pdfStatus, .loading("capital-p154"))
        reader.send(.showGlossary("impairment"))
        reader.send(.reset)
        expectEqual(reader, ReaderState())
    }
}

@main struct ReaderStateDirectChecks {
    static func main() {
        let tests = ReaderStateChecks()
        tests.testCalculationSourceBackPreservesClaimAndReadingPositions()
        print("PASS testCalculationSourceBackPreservesClaimAndReadingPositions")
        tests.testForeignClaimCannotReplaceEvidenceContext()
        print("PASS testForeignClaimCannotReplaceEvidenceContext")
        tests.testGlossaryIsAnOverlayAndDoesNotLoseReadingPosition()
        print("PASS testGlossaryIsAnOverlayAndDoesNotLoseReadingPosition")
        tests.testInvalidPDFPageFailsAndRetryKeepsSourceIdentity()
        print("PASS testInvalidPDFPageFailsAndRetryKeepsSourceIdentity")
        tests.testStalePDFCallbacksCannotOverwriteCurrentSourceOrPoppedScreen()
        print("PASS testStalePDFCallbacksCannotOverwriteCurrentSourceOrPoppedScreen")
        tests.testNativeBackOnlyShortensPathAndPreservesSummarySourceContext()
        print("PASS testNativeBackOnlyShortensPathAndPreservesSummarySourceContext")
        tests.testDimensionClaimEvidenceBackRestoresDimensionContext()
        print("PASS testDimensionClaimEvidenceBackRestoresDimensionContext")
        tests.testRoutesCannotSkipTheirReadingContext()
        print("PASS testRoutesCannotSkipTheirReadingContext")
        tests.testRetryOnlyRunsForCurrentFailedSourceAndResetClearsSession()
        print("PASS testRetryOnlyRunsForCurrentFailedSourceAndResetClearsSession")
        print("PASS 9 direct Interface scenarios (no XCTest runner used)")
    }
}
