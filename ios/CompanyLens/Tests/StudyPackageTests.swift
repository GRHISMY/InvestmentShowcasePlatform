import Foundation
import XCTest
@testable import ResearchCore

final class StudyPackageTests: XCTestCase {
    private var temporaryRoot: URL!

    override func setUpWithError() throws {
        temporaryRoot = FileManager.default.temporaryDirectory.appendingPathComponent("study-package-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: temporaryRoot, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try FileManager.default.removeItem(at: temporaryRoot)
    }

    private func package() throws -> URL {
        let source = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Study")
        let destination = temporaryRoot.appendingPathComponent(UUID().uuidString)
        try FileManager.default.copyItem(at: source, to: destination)
        return destination
    }

    private func json(_ path: String, in root: URL) throws -> [String: Any] {
        try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: root.appendingPathComponent(path))) as? [String: Any])
    }

    private func write(_ object: [String: Any], to path: String, in root: URL) throws {
        try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys]).write(to: root.appendingPathComponent(path))
    }

    private func writeSnapshot(_ snapshot: [String: Any], in root: URL) throws {
        try write(snapshot, to: "snapshot.json", in: root)
        let bytes = try Data(contentsOf: root.appendingPathComponent("snapshot.json"))
        var manifest = try json("resource-manifest.json", in: root)
        manifest["snapshotManifestSHA256"] = ReadingLibrary.sha256(bytes)
        var datasets = try XCTUnwrap(manifest["datasets"] as? [[String: Any]])
        let index = try XCTUnwrap(datasets.firstIndex { $0["file"] as? String == "snapshot.json" })
        datasets[index]["sha256"] = ReadingLibrary.sha256(bytes)
        datasets[index]["bytes"] = bytes.count
        manifest["datasets"] = datasets
        try write(manifest, to: "resource-manifest.json", in: root)
    }

    private func resealPayload(in root: URL) throws {
        var snapshot = try json("snapshot.json", in: root)
        var files = try XCTUnwrap(snapshot["files"] as? [String: String])
        for path in files.keys { files[path] = ReadingLibrary.sha256(try Data(contentsOf: root.appendingPathComponent(path))) }
        snapshot["files"] = files
        try writeSnapshot(snapshot, in: root)
        var manifest = try json("resource-manifest.json", in: root)
        var datasets = try XCTUnwrap(manifest["datasets"] as? [[String: Any]])
        for index in datasets.indices {
            let path = try XCTUnwrap(datasets[index]["file"] as? String)
            let bytes = try Data(contentsOf: root.appendingPathComponent(path))
            datasets[index]["sha256"] = ReadingLibrary.sha256(bytes)
            datasets[index]["bytes"] = bytes.count
        }
        manifest["datasets"] = datasets
        try write(manifest, to: "resource-manifest.json", in: root)
    }

    func testPublishedPackageOpensItsExactResearchAndReadingVersion() throws {
        let study = try ReadableStudy(root: package())
        XCTAssertEqual(study.identity.companyID, "cn-sz-000651")
        XCTAssertEqual(study.identity.reportID, "cn-sz-000651-2020-2026")
        XCTAssertEqual(study.identity.snapshotID, "cn-sz-000651-2020-2026-r4-338655191847af3d")
        XCTAssertEqual(study.identity.snapshotManifestSHA256, "8b903db1a5461c5c1b3e835491d3d3eab00c001dcf450314f3c5514e1e34589f")
        XCTAssertEqual(study.research.research.company.name, "格力电器")
        XCTAssertEqual(study.reading?.document.id, "gree-connected-study")
        XCTAssertEqual(study.identity.readingID, "gree-connected-study")
        XCTAssertEqual(study.identity.readingRevision, 2)
    }

    func testSameRelativePDFNameStaysInsideEachOpenedPackage() throws {
        let firstRoot = try package(), secondRoot = try package()
        let first = try ReadableStudy(root: firstRoot), second = try ReadableStudy(root: secondRoot)
        let sourceID = "pdf-7cc972f2d199e2ec"
        let firstPDF = try first.resources.pdfURL(sourceID: sourceID)
        let secondPDF = try second.resources.pdfURL(sourceID: sourceID)
        XCTAssertEqual(firstPDF, firstRoot.appendingPathComponent("reports/pdf-7cc972f2d199e2ec.pdf"))
        XCTAssertEqual(secondPDF, secondRoot.appendingPathComponent("reports/pdf-7cc972f2d199e2ec.pdf"))
        XCTAssertNotEqual(firstPDF, secondPDF)
    }

    func testMissingDeclaredPDFPreventsOpeningPackage() throws {
        let root = try package()
        try FileManager.default.removeItem(at: root.appendingPathComponent("reports/pdf-7cc972f2d199e2ec.pdf"))
        XCTAssertThrowsError(try ReadableStudy(root: root))
    }

    func testChangedPDFBytesPreventsOpeningPackage() throws {
        let root = try package()
        try Data("a different original".utf8).write(to: root.appendingPathComponent("reports/pdf-7cc972f2d199e2ec.pdf"))
        XCTAssertThrowsError(try ReadableStudy(root: root))
    }

    func testChangedPublishedReportCannotBypassFormalFileManifest() throws {
        let root = try package()
        try Data("a replaced report".utf8).write(to: root.appendingPathComponent("research.md"))
        XCTAssertThrowsError(try ReadableStudy(root: root))
    }

    func testSnapshotBytesMustMatchDistributionManifestDigest() throws {
        let root = try package()
        var manifest = try json("resource-manifest.json", in: root)
        manifest["snapshotManifestSHA256"] = String(repeating: "0", count: 64)
        try write(manifest, to: "resource-manifest.json", in: root)
        XCTAssertThrowsError(try ReadableStudy(root: root))
    }

    func testRequestedSnapshotDigestCannotOpenAnotherValidPublication() throws {
        let root = try package()
        XCTAssertThrowsError(try ReadableStudy(root: root, expectedSnapshotManifestSHA256: String(repeating: "0", count: 64)))
    }

    func testDistributionDocumentMustMatchItsPublishedSource() throws {
        let mismatches: [String: Any] = ["pageCount": 218, "bytes": 1,
            "sha256": String(repeating: "0", count: 64), "sourceId": "another-source",
            "documentFile": "reports/another.pdf", "title": "Another source"]
        for (field, value) in mismatches {
            let root = try package()
            var manifest = try json("resource-manifest.json", in: root)
            var documents = try XCTUnwrap(manifest["documents"] as? [[String: Any]])
            documents[0][field] = value
            manifest["documents"] = documents
            try write(manifest, to: "resource-manifest.json", in: root)
            XCTAssertThrowsError(try ReadableStudy(root: root), "Mismatched " + field)
        }
    }

    func testDistributionDatasetCannotContradictPublishedFiles() throws {
        for (field, value) in ["bytes": 1, "sha256": String(repeating: "0", count: 64), "file": "another.md"] as [String: Any] {
            let root = try package()
            var manifest = try json("resource-manifest.json", in: root)
            var datasets = try XCTUnwrap(manifest["datasets"] as? [[String: Any]])
            datasets[0][field] = value
            manifest["datasets"] = datasets
            try write(manifest, to: "resource-manifest.json", in: root)
            XCTAssertThrowsError(try ReadableStudy(root: root), "Mismatched " + field)
        }
    }

    func testManifestsMustIdentifyTheSameSupportedPublication() throws {
        let mismatches: [(String, String, Any)] = [
            ("snapshot.json", "schema_version", "unknown-snapshot/v9"),
            ("snapshot.json", "snapshot_id", "another-publication"),
            ("resource-manifest.json", "schemaVersion", 99),
            ("resource-manifest.json", "snapshotId", "another-publication"),
            ("resource-manifest.json", "researchAsOf", "2020-01-01"),
            ("resource-manifest.json", "financialPeriodStart", "2020-01-02"),
            ("resource-manifest.json", "financialPeriodEnd", "2026-10-01"),
            ("resource-manifest.json", "physicalPageNumbering", "zero-based")]
        for (path, field, value) in mismatches {
            let root = try package()
            var object = try json(path, in: root)
            object[field] = value
            if path == "snapshot.json" { try writeSnapshot(object, in: root) }
            else { try write(object, to: path, in: root) }
            XCTAssertThrowsError(try ReadableStudy(root: root), "Mismatched " + field)
        }
    }

    func testFormalInventoryMustIncludeResearchViewsAndEveryDeclaredSource() throws {
        for omitted in ["research.json", "research.md", "evidence.md", "reading.json", "reports/pdf-7cc972f2d199e2ec.pdf"] {
            let root = try package()
            var snapshot = try json("snapshot.json", in: root)
            var files = try XCTUnwrap(snapshot["files"] as? [String: String])
            files.removeValue(forKey: omitted)
            snapshot["files"] = files
            var manifest = try json("resource-manifest.json", in: root)
            manifest["datasets"] = try XCTUnwrap(manifest["datasets"] as? [[String: Any]]).filter { $0["file"] as? String != omitted }
            try write(manifest, to: "resource-manifest.json", in: root)
            try writeSnapshot(snapshot, in: root)
            XCTAssertThrowsError(try ReadableStudy(root: root), "Undeclared " + omitted)
        }
    }

    func testPackageRejectsAnOriginalSymlinkedOutsideItsFixedRoot() throws {
        let root = try package()
        let original = root.appendingPathComponent("reports/pdf-7cc972f2d199e2ec.pdf")
        let outside = temporaryRoot.appendingPathComponent("outside.pdf")
        try FileManager.default.moveItem(at: original, to: outside)
        try FileManager.default.createSymbolicLink(at: original, withDestinationURL: outside)
        XCTAssertThrowsError(try ReadableStudy(root: root))
    }

    func testWrongReadingBindingIsAnExplicitReadingFailure() throws {
        let root = try package()
        var reading = try json("reading.json", in: root)
        reading["research_ref"] = ["snapshot_id": "another-publication", "sha256": String(repeating: "0", count: 64)]
        try write(reading, to: "reading.json", in: root)
        try resealPayload(in: root)
        XCTAssertThrowsError(try ReadableStudy(root: root)) {
            XCTAssertEqual($0 as? StudyPackageError, .invalidReading)
        }
    }

    func testUnsupportedResearchIsAnExplicitResearchFailure() throws {
        let root = try package()
        var research = try json("research.json", in: root)
        research["schema_version"] = "company-research/v99"
        try write(research, to: "research.json", in: root)
        try resealPayload(in: root)
        XCTAssertThrowsError(try ReadableStudy(root: root)) {
            XCTAssertEqual($0 as? StudyPackageError, .invalidResearch)
        }
    }

    func testReportOnlyPublicationOpensWithoutAnUndeclaredReadingFile() throws {
        let root = try package()
        try FileManager.default.removeItem(at: root.appendingPathComponent("reading.json"))
        var snapshot = try json("snapshot.json", in: root)
        var files = try XCTUnwrap(snapshot["files"] as? [String: String])
        files.removeValue(forKey: "reading.json")
        snapshot["files"] = files
        var manifest = try json("resource-manifest.json", in: root)
        manifest["datasets"] = try XCTUnwrap(manifest["datasets"] as? [[String: Any]]).filter { $0["file"] as? String != "reading.json" }
        try write(manifest, to: "resource-manifest.json", in: root)
        try writeSnapshot(snapshot, in: root)

        let study = try ReadableStudy(root: root)
        XCTAssertNil(study.reading)
        XCTAssertNil(study.identity.readingID)
        XCTAssertNil(study.identity.readingRevision)
        XCTAssertEqual(study.research.orderedClaims.count, 25)
    }

    func testMissingDeclaredReadingCannotFallBackToReport() throws {
        let root = try package()
        try FileManager.default.removeItem(at: root.appendingPathComponent("reading.json"))
        XCTAssertThrowsError(try ReadableStudy(root: root))
    }

    func testUnrecognizedSourceDoesNotFallBackToAnyOtherPDF() throws {
        let study = try ReadableStudy(root: package())
        XCTAssertThrowsError(try study.resources.pdfURL(sourceID: "not-in-this-publication")) {
            XCTAssertEqual($0 as? StudyPackageError, .unknownSource("not-in-this-publication"))
        }
    }

    func testFormalManifestCannotReachOutsideItsPackage() throws {
        let root = try package()
        let outside = temporaryRoot.appendingPathComponent("outside.md")
        let bytes = Data("outside the selected package".utf8)
        try bytes.write(to: outside)
        var snapshot = try json("snapshot.json", in: root)
        var files = try XCTUnwrap(snapshot["files"] as? [String: String])
        files["../outside.md"] = ReadingLibrary.sha256(bytes)
        snapshot["files"] = files
        try writeSnapshot(snapshot, in: root)
        XCTAssertThrowsError(try ReadableStudy(root: root)) {
            XCTAssertEqual($0 as? StudyPackageError, .invalidPath("../outside.md"))
        }
    }

    func testDifferentVersionsWithTheSamePDFPathKeepTheirOwnOriginalBytes() throws {
        let firstRoot = try package(), secondRoot = try package()
        let path = "reports/pdf-7cc972f2d199e2ec.pdf", sourceID = "pdf-7cc972f2d199e2ec"
        let secondPDF = secondRoot.appendingPathComponent(path)
        var bytes = try Data(contentsOf: secondPDF)
        bytes.append(Data("\n% Second immutable fixture publication\n".utf8))
        try bytes.write(to: secondPDF)
        let hash = ReadingLibrary.sha256(bytes)
        let newSnapshotID = "second-fixture-publication"

        var research = try json("research.json", in: secondRoot)
        var publication = try XCTUnwrap(research["publication"] as? [String: Any])
        publication["snapshot_id"] = newSnapshotID
        research["publication"] = publication
        var sources = try XCTUnwrap(research["sources"] as? [[String: Any]])
        let sourceIndex = try XCTUnwrap(sources.firstIndex { $0["id"] as? String == sourceID })
        sources[sourceIndex]["sha256"] = hash
        research["sources"] = sources
        try write(research, to: "research.json", in: secondRoot)
        var reading = try json("reading.json", in: secondRoot)
        reading["research_ref"] = ["snapshot_id": newSnapshotID,
            "sha256": ReadingLibrary.sha256(try Data(contentsOf: secondRoot.appendingPathComponent("research.json")))]
        try write(reading, to: "reading.json", in: secondRoot)
        var snapshot = try json("snapshot.json", in: secondRoot)
        snapshot["snapshot_id"] = newSnapshotID
        try write(snapshot, to: "snapshot.json", in: secondRoot)
        var manifest = try json("resource-manifest.json", in: secondRoot)
        manifest["snapshotId"] = newSnapshotID
        var documents = try XCTUnwrap(manifest["documents"] as? [[String: Any]])
        let documentIndex = try XCTUnwrap(documents.firstIndex { $0["sourceId"] as? String == sourceID })
        documents[documentIndex]["sha256"] = hash
        documents[documentIndex]["bytes"] = bytes.count
        manifest["documents"] = documents
        try write(manifest, to: "resource-manifest.json", in: secondRoot)
        try resealPayload(in: secondRoot)

        let first = try ReadableStudy(root: firstRoot), second = try ReadableStudy(root: secondRoot)
        XCTAssertNotEqual(first.identity, second.identity)
        let firstBytes = try Data(contentsOf: first.resources.pdfURL(sourceID: sourceID))
        let secondBytes = try Data(contentsOf: second.resources.pdfURL(sourceID: sourceID))
        XCTAssertNotEqual(firstBytes, secondBytes)
        XCTAssertEqual(secondBytes, bytes)
    }

    func testMalformedManifestProducesAnExplicitPackageFailure() throws {
        for path in ["snapshot.json", "resource-manifest.json"] {
            let root = try package()
            if path == "snapshot.json" { try writeSnapshot([:], in: root) }
            else { try write([:], to: path, in: root) }
            XCTAssertThrowsError(try ReadableStudy(root: root)) {
                XCTAssertEqual($0 as? StudyPackageError, .invalidManifest(path))
            }
        }
    }
}
