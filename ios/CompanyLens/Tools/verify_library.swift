import Foundation
import CryptoKit
import PDFKit

private struct ResourceManifest: Decodable {
    let snapshotId: String
    let documents: [DocumentEntry]
    let datasets: [DatasetEntry]
    let pageReferences: Int
}
private struct DocumentEntry: Decodable {
    let sourceId, documentFile, sha256: String
    let bytes, pageCount: Int
}
private struct DatasetEntry: Decodable { let file, sha256: String; let bytes: Int }
private struct DocumentCheck: Encodable {
    let sourceID: String
    let actualPages: Int
    let hashMatches, byteCountMatches, pageCountMatches: Bool
}
private struct PageCheck: Encodable {
    let evidencePageID: String
    let physicalPage: Int
    let pageExists, normalizedExcerptFound: Bool
}
private struct RejectionCheck: Encodable { let name: String; let rejectedWithExpectedError: Bool }
private struct LibraryCheckReport: Encodable {
    let checkedAt, snapshotID: String
    let passed: Bool
    let counts: [String: Int]
    let errors, locatingLimitations: [String]
    let documents: [DocumentCheck]
    let pages: [PageCheck]
    let invalidInputs: [RejectionCheck]
}

@main struct VerifyResearchLibrary {
    static func main() {
        guard CommandLine.arguments.count == 2 else {
            fputs("Usage: verify-library /path/to/Resources\n", stderr); exit(2)
        }
        do { try run(resources: URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)) }
        catch { fputs("FAIL library verification: \(error)\n", stderr); exit(1) }
    }
    private static func sha256(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }
    private static func compact(_ value: String) -> String {
        value.unicodeScalars.filter { !CharacterSet.whitespacesAndNewlines.contains($0) }.map(String.init).joined()
    }
    private static func run(resources: URL) throws {
        let raw = try Data(contentsOf: resources.appendingPathComponent("research.json"))
        let library = try ResearchLibrary(researchData: raw)
        let manifest = try JSONDecoder().decode(ResourceManifest.self,
            from: Data(contentsOf: resources.appendingPathComponent("resource-manifest.json")))
        var errors: [String] = []
        var limitations: [String] = []
        var documentChecks: [DocumentCheck] = []
        var pageChecks: [PageCheck] = []
        var documents: [String: PDFDocument] = [:]
        if manifest.snapshotId != library.research.publication.snapshotId { errors.append("Snapshot identity mismatch.") }
        if manifest.pageReferences != library.pages.count { errors.append("Evidence page count mismatch.") }
        let declaredSources = Set(library.research.sources.map(\.id))
        if Set(manifest.documents.map(\.sourceId)) != declaredSources || manifest.documents.count != declaredSources.count {
            errors.append("Manifest document list differs from the research sources.")
        }
        for dataset in manifest.datasets {
            guard !dataset.file.contains("/"), !dataset.file.contains("..") else {
                errors.append("Unsafe dataset path."); continue
            }
            let data = try Data(contentsOf: resources.appendingPathComponent(dataset.file))
            if data.count != dataset.bytes || sha256(data) != dataset.sha256 {
                errors.append("Dataset mismatch: " + dataset.file)
            }
        }
        if !manifest.datasets.contains(where: { $0.file == "research.json" }) { errors.append("Research dataset is not pinned.") }
        for source in library.research.sources {
            guard let entry = manifest.documents.first(where: { $0.sourceId == source.id }),
                  entry.documentFile == source.assetPath, entry.sha256 == source.sha256,
                  entry.pageCount == source.pdfPages else {
                errors.append("Source metadata mismatch: " + source.id); continue
            }
            let data = try Data(contentsOf: resources.appendingPathComponent(source.assetPath))
            guard let document = PDFDocument(data: data) else {
                errors.append("Cannot open PDF: " + source.id); continue
            }
            documents[source.id] = document
            let check = DocumentCheck(sourceID: source.id, actualPages: document.pageCount,
                hashMatches: sha256(data) == source.sha256, byteCountMatches: data.count == entry.bytes,
                pageCountMatches: document.pageCount == source.pdfPages)
            documentChecks.append(check)
            if !check.hashMatches || !check.byteCountMatches || !check.pageCountMatches { errors.append("PDF mismatch: " + source.id) }
        }
        for reference in library.pages {
            let page = documents[reference.sourceId]?.page(at: reference.physicalPage - 1)
            let found = compact(page?.string ?? "").contains(compact(reference.focusText ?? ""))
            pageChecks.append(PageCheck(evidencePageID: reference.id, physicalPage: reference.physicalPage,
                                       pageExists: page != nil, normalizedExcerptFound: found))
            if page == nil { errors.append("Missing physical page: " + reference.id) }
            if !found { limitations.append(reference.id + ": excerpt is not a single literal page-text span; original page navigation remains available.") }
        }

        // The same public loading interface rejects corrupt inputs. Each mutation
        // is in memory; neither the publication nor the bundled resource changes.
        let original = try JSONSerialization.jsonObject(with: raw) as! [String: Any]
        var rejectedChecks: [RejectionCheck] = []
        func rejected(_ name: String, expected: ResearchLibrary.LibraryError,
                      mutate: (inout [String: Any]) -> Void) throws {
            var value = original
            mutate(&value)
            let data = try JSONSerialization.data(withJSONObject: value)
            do {
                _ = try ResearchLibrary(researchData: data)
                rejectedChecks.append(RejectionCheck(name: name, rejectedWithExpectedError: false))
            } catch {
                rejectedChecks.append(RejectionCheck(name: name,
                    rejectedWithExpectedError: (error as? ResearchLibrary.LibraryError) == expected))
            }
        }
        let firstEvidence = library.research.evidence[0]
        let firstSource = library.research.sources[0]
        let firstClaim = library.research.conclusions[0]
        try rejected("zero-physical-page", expected: .invalidPage(firstEvidence.id)) { value in
            var rows = value["evidence"] as! [[String: Any]]; rows[0]["physical_pages"] = [0]; value["evidence"] = rows
        }
        let evidenceSource = library.research.sources.first { $0.id == firstEvidence.sourceId }!
        try rejected("page-beyond-pdf", expected: .invalidPage(firstEvidence.id)) { value in
            var rows = value["evidence"] as! [[String: Any]]; rows[0]["physical_pages"] = [evidenceSource.pdfPages + 1]; value["evidence"] = rows
        }
        try rejected("source-path-escape", expected: .invalidSource(firstSource.id)) { value in
            var rows = value["sources"] as! [[String: Any]]; rows[0]["asset_path"] = "../external.pdf"; value["sources"] = rows
        }
        try rejected("unknown-evidence", expected: .invalidReference(firstClaim.id, "missing-evidence")) { value in
            var rows = value["conclusions"] as! [[String: Any]]
            rows[0]["evidence_links"] = [["evidence_id": "missing-evidence", "relation": "supports", "explanation": "Invalid reference"]]
            value["conclusions"] = rows
        }
        try rejected("duplicate-conclusion", expected: .duplicateIdentity("conclusion", firstClaim.id)) { value in
            var rows = value["conclusions"] as! [[String: Any]]; rows.append(rows[0]); value["conclusions"] = rows
        }
        try rejected("unsupported-contract", expected: .unsupportedVersion("company-research/future")) { $0["schema_version"] = "company-research/future" }
        if let firstCalculation = library.research.calculations.first {
            try rejected("unknown-calculation-input", expected: .invalidReference(firstCalculation.id, "missing-fact")) { value in
                var rows = value["calculations"] as! [[String: Any]]
                rows[0]["inputs"] = [["fact_id": "missing-fact", "coefficient": "1"]]; value["calculations"] = rows
            }
        }
        if !library.research.presentation.sections.isEmpty {
            try rejected("section-silently-drops-conclusion", expected: .invalidReport("Sections must contain every conclusion exactly once.")) { value in
                var presentation = value["presentation"] as! [String: Any]
                var sections = presentation["sections"] as! [[String: Any]]
                var ids = sections[0]["conclusion_ids"] as! [String]; ids.removeLast()
                sections[0]["conclusion_ids"] = ids; presentation["sections"] = sections; value["presentation"] = presentation
            }
        }
        var fallback = original
        var presentation = fallback["presentation"] as! [String: Any]
        presentation.removeValue(forKey: "sections"); fallback["presentation"] = presentation
        fallback["schema_version"] = "company-research/v1"
        let legacy = try ResearchLibrary(researchData: JSONSerialization.data(withJSONObject: fallback))
        if legacy.orderedClaims.map(\.id) != library.research.conclusions.map(\.id) {
            errors.append("Absent sections changed the original conclusion order.")
        }
        if library.orderedClaims.count != library.research.conclusions.count { errors.append("Some conclusions are unreachable.") }
        if rejectedChecks.contains(where: { !$0.rejectedWithExpectedError }) { errors.append("A corrupt input was not rejected as expected.") }
        let report = LibraryCheckReport(checkedAt: ISO8601DateFormatter().string(from: Date()),
            snapshotID: library.research.publication.snapshotId, passed: errors.isEmpty,
            counts: ["conclusions": library.orderedClaims.count, "headlines": library.headlineClaims.count,
                     "sections": library.sections.count, "dimensions": library.research.dimensions.count,
                     "facts": library.research.facts.count, "calculations": library.research.calculations.count,
                     "evidenceExcerpts": library.research.evidence.count, "pageReferences": library.pages.count,
                     "uniqueCompletePDFs": documents.count, "invalidInputChecks": rejectedChecks.count],
            errors: errors, locatingLimitations: limitations, documents: documentChecks, pages: pageChecks, invalidInputs: rejectedChecks)
        let output = resources.deletingLastPathComponent().appendingPathComponent("Verification")
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        try encoder.encode(report).write(to: output.appendingPathComponent("library-checks.json"), options: .atomic)
        print("\(report.passed ? "PASS" : "FAIL") \(library.orderedClaims.count) conclusions / \(library.research.calculations.count) calculations / \(pageChecks.count) page references / \(documents.count) complete PDFs")
        print("Invalid-input rejection: \(rejectedChecks.filter(\.rejectedWithExpectedError).count)/\(rejectedChecks.count); nonfatal text locating limits: \(limitations.count)")
        if !errors.isEmpty { errors.forEach { fputs($0 + "\n", stderr) }; exit(1) }
    }
}
