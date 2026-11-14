import XCTest
@testable import ResearchCore

final class ReaderStateTests: XCTestCase {
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
        XCTAssertEqual(reader.pdfStatus, .loading("cash-p177"))

        reader.send(.pdfLoaded(evidenceID: "cash-p177", page: 177, pageCount: 230))
        reader.send(.backToDepth(3))
        XCTAssertEqual(reader.current, calculation)
        XCTAssertEqual(reader.pdfStatus, .idle)
        XCTAssertEqual(reader.anchor(for: calculation), "input-2")
        reader.send(.backToDepth(2))
        XCTAssertEqual(reader.current, evidence)
        XCTAssertEqual(reader.anchor(for: evidence), "cash-p177")
        reader.send(.backToDepth(1))
        XCTAssertEqual(reader.current, claim)
        XCTAssertEqual(reader.anchor(for: claim), "reasoning-2")
    }

    func testForeignClaimCannotReplaceEvidenceContext() {
        var reader = ReaderState()
        reader.send(.open(.claim("cash")))
        let original = reader
        reader.send(.open(.evidence("capital")))
        XCTAssertEqual(reader, original)
        reader.send(.open(.calculation("capital")))
        XCTAssertEqual(reader, original)
        reader.send(.open(.source(claimID: "capital", evidenceID: "capital-p154")))
        XCTAssertEqual(reader, original)
        reader.send(.open(.evidence("cash")))
        XCTAssertEqual(reader.current, .evidence("cash"))
    }

    func testGlossaryIsAnOverlayAndDoesNotLoseReadingPosition() {
        var reader = ReaderState()
        let route = ReaderRoute.claim("customer")
        reader.send(.open(route))
        reader.send(.rememberAnchor(route: route, anchor: "who-pays"))
        let path = reader.path
        let bookmarks = reader.bookmarks
        reader.send(.showGlossary("consolidated"))
        XCTAssertEqual(reader.glossaryID, "consolidated")
        XCTAssertEqual(reader.path, path)
        XCTAssertEqual(reader.bookmarks, bookmarks)
        reader.send(.dismissGlossary)
        XCTAssertNil(reader.glossaryID)
        XCTAssertEqual(reader.path, path)
        XCTAssertEqual(reader.anchor(for: route), "who-pays")
    }

    func testInvalidPDFPageFailsAndRetryKeepsSourceIdentity() {
        for invalid in [(0, 230), (231, 230), (1, 0), (-1, 230)] {
            var reader = ReaderState()
            reader.send(.open(.claim("cash")))
            reader.send(.open(.evidence("cash")))
            reader.send(.open(.source(claimID: "cash", evidenceID: "cash-p177")))
            reader.send(.pdfLoaded(evidenceID: "cash-p177", page: invalid.0, pageCount: invalid.1))
            XCTAssertEqual(reader.pdfStatus, .failed("cash-p177"))
            reader.send(.retryPDF)
            XCTAssertEqual(reader.pdfStatus, .loading("cash-p177"))
            reader.send(.pdfLoaded(evidenceID: "cash-p177", page: 177, pageCount: 230))
            XCTAssertEqual(reader.pdfStatus, .ready(evidenceID: "cash-p177", page: 177, pageCount: 230))
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
        XCTAssertEqual(reader.pdfStatus, .loading("cash-p177"))
        reader.send(.backToDepth(2))
        reader.send(.pdfLoaded(evidenceID: "cash-p177", page: 177, pageCount: 230))
        reader.send(.pdfFailed(evidenceID: "cash-p177"))
        XCTAssertEqual(reader.current, .evidence("cash"))
        XCTAssertEqual(reader.pdfStatus, .idle)
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
        XCTAssertEqual(reader.current, source)
        reader.send(.backToDepth(1))
        XCTAssertEqual(reader.current, .dimension("profit"))
        XCTAssertEqual(reader.anchor(for: .dimension("profit")), "report")
        XCTAssertEqual(reader.pdfStatus, .idle)
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
        XCTAssertEqual(reader.path, [dimension, claim, .evidence("cash")])
        reader.send(.backToDepth(2))
        XCTAssertEqual(reader.current, claim)
        XCTAssertEqual(reader.anchor(for: claim), "reasoning-2")
        reader.send(.backToDepth(1))
        XCTAssertEqual(reader.current, dimension)
        XCTAssertEqual(reader.anchor(for: dimension), "related-claim")
        XCTAssertEqual(reader.pdfStatus, .idle)
    }

    func testRoutesCannotSkipTheirReadingContext() {
        var reader = ReaderState()
        reader.send(.open(.evidence("cash")))
        reader.send(.open(.calculation("cash")))
        reader.send(.open(.source(claimID: nil, evidenceID: "cash-p177")))
        XCTAssertEqual(reader, ReaderState())

        reader.send(.open(.claim("cash")))
        let claimState = reader
        reader.send(.open(.calculation("cash")))
        reader.send(.open(.source(claimID: "cash", evidenceID: "cash-p177")))
        reader.send(.open(.claim("capital")))
        XCTAssertEqual(reader, claimState)

        reader.send(.open(.evidence("cash")))
        reader.send(.open(.calculation("cash")))
        let calculationState = reader
        reader.send(.open(.evidence("cash")))
        reader.send(.open(.dimension("profit")))
        XCTAssertEqual(reader, calculationState)
    }

    func testRetryOnlyRunsForCurrentFailedSourceAndResetClearsSession() {
        var reader = ReaderState()
        reader.send(.open(.claim("capital")))
        reader.send(.rememberAnchor(route: .claim("capital"), anchor: "limits"))
        reader.send(.retryPDF)
        XCTAssertEqual(reader.pdfStatus, .idle)
        reader.send(.open(.evidence("capital")))
        reader.send(.open(.source(claimID: "capital", evidenceID: "capital-p154")))
        reader.send(.pdfFailed(evidenceID: "capital-p154"))
        reader.send(.retryPDF)
        XCTAssertEqual(reader.pdfStatus, .loading("capital-p154"))
        reader.send(.showGlossary("impairment"))
        reader.send(.reset)
        XCTAssertEqual(reader, ReaderState())
    }
}
