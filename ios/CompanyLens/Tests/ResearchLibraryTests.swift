import Foundation
import XCTest
@testable import ResearchCore

final class ResearchLibraryTests: XCTestCase {
    private func packagedLibrary() throws -> ResearchLibrary {
        let project = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent()
        return try ResearchLibrary(researchData: Data(contentsOf: project.appendingPathComponent("Study/research.json")))
    }

    func testSupplementalControlPageKeepsPublishedOriginalIdentity() throws {
        let library = try packagedLibrary()
        let sourceID = "pdf-7cc972f2d199e2ec"
        let source = try XCTUnwrap(library.research.sources.first { $0.id == sourceID })
        let originalEvidenceCount = library.research.evidence.count
        let page = try XCTUnwrap(library.page(sourceID: sourceID, physicalPage: 185,
                                             focusText: "珠海格力集团财务有限责任公司"))
        XCTAssertEqual(page.sourceId, source.id)
        XCTAssertEqual(page.sourceSha256, source.sha256)
        XCTAssertEqual(page.documentFile, source.assetPath)
        XCTAssertEqual(page.pageCount, source.pdfPages)
        XCTAssertEqual(page.physicalPage, 185)
        XCTAssertEqual(page.focusText, "珠海格力集团财务有限责任公司")
        XCTAssertEqual(library.research.evidence.count, originalEvidenceCount)
        if library.research.schemaVersion == "company-research/v1.2" {
            XCTAssertEqual(library.evidence("boundary-finance")?.physicalPages, [185], "Control evidence is now in the canonical publication")
        } else {
            XCTAssertNil(library.evidence("boundary-finance"))
        }
    }

    func testSupplementalPagesRejectUnknownSourceAndOutOfRangePages() throws {
        let library = try packagedLibrary()
        let source = try XCTUnwrap(library.research.sources.first)
        XCTAssertNil(library.page(sourceID: "missing-report", physicalPage: 1, focusText: ""))
        for page in [Int.min, -1, 0, source.pdfPages + 1, Int.max] {
            XCTAssertNil(library.page(sourceID: source.id, physicalPage: page, focusText: ""))
        }
        XCTAssertNotNil(library.page(sourceID: source.id, physicalPage: 1, focusText: ""))
        XCTAssertNotNil(library.page(sourceID: source.id, physicalPage: source.pdfPages, focusText: ""))
    }
}
