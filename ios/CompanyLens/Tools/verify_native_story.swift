import Foundation
import CryptoKit
import PDFKit

/// Checks the same compiled JSON Interface used by the actual native reader.
/// Build with Core/ResearchLibrary.swift and Core/ReadingLibrary.swift.
@main struct VerifyNativeStory {
    static func main() {
        do {
            guard CommandLine.arguments.count == 2 else {
                throw CheckFailure("Usage: verify-native-story /absolute/path/to/Study")
            }
            try run(URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true))
        } catch { fputs("FAIL native story: \(error)\n", stderr); exit(1) }
    }
    struct CheckFailure: Error { let message: String; init(_ message: String) { self.message = message } }
    static func require(_ condition: Bool, _ text: String) throws { if !condition { throw CheckFailure(text) } }
    static func normal(_ text: String) -> String {
        text.unicodeScalars.filter { !CharacterSet.whitespacesAndNewlines.contains($0) }.map(String.init).joined()
    }
    static func run(_ root: URL) throws {
        let original = try Data(contentsOf: root.appendingPathComponent("research.json"))
        let readingData = try Data(contentsOf: root.appendingPathComponent("reading.json"))
        let book = try ReadingLibrary(researchData: original, readingData: readingData)
        let library = book.research
        var requested = Set<String>(), pageRoutes = Set<String>()
        var routeCount = 0
        for scene in book.orderedScenes {
            for focusID in scene.focusIds {
                try require(book.validFocus(focusID, in: scene.id) == focusID, "Unreachable focus " + focusID)
                guard let focus = book.focus(focusID) else { throw CheckFailure("Missing focus") }
                requested.formUnion(focus.evidenceIds)
                routeCount += 1
                for calculationID in focus.calculationIds {
                    guard let calculation = library.calculation(calculationID) else { throw CheckFailure("Missing calculation") }
                    for input in calculation.inputs {
                        guard let fact = library.fact(input.factId) else { throw CheckFailure("Missing calculation input") }
                        requested.formUnion(fact.evidenceIds)
                    }
                }
            }
        }
        var documents: [String: PDFDocument] = [:]
        var locatingLimitations: [String] = []
        var popplerMatches: [String] = []
        for id in requested.sorted() {
            guard let evidence = library.evidence(id),
                  let source = library.research.sources.first(where: { $0.id == evidence.sourceId }) else {
                throw CheckFailure("Unknown source route " + id)
            }
            let file = root.appendingPathComponent(source.assetPath)
            if documents[source.id] == nil {
                let bytes = try Data(contentsOf: file)
                let hash = SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined()
                try require(hash == source.sha256, "Changed original " + source.id)
                guard let document = PDFDocument(data: bytes) else { throw CheckFailure("Unreadable original") }
                try require(document.pageCount == source.pdfPages, "Wrong original page count")
                documents[source.id] = document
            }
            let document = documents[source.id]!
            let routes = library.pages(for: id)
            try require(routes.count == evidence.physicalPages.count, "Missing physical-page route")
            var contents = ""
            for route in routes {
                guard let page = document.page(at: route.physicalPage - 1) else { throw CheckFailure("Missing original page") }
                contents += page.string ?? ""
                pageRoutes.insert(source.id + ":" + String(route.physicalPage))
            }
            if !normal(contents).contains(normal(evidence.excerpt)) {
                var extracted = ""
                for route in routes {
                    let process = Process(), output = Pipe(), diagnostic = Pipe()
                    process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
                    process.arguments = ["pdftotext", "-f", String(route.physicalPage), "-l", String(route.physicalPage), "-layout", file.path, "-"]
                    process.standardOutput = output; process.standardError = diagnostic
                    try process.run()
                    let bytes = output.fileHandleForReading.readDataToEndOfFile()
                    process.waitUntilExit()
                    try require(process.terminationStatus == 0, "Cannot extract original page")
                    extracted += String(decoding: bytes, as: UTF8.self)
                }
                if normal(extracted).contains(normal(evidence.excerpt)) { popplerMatches.append(id) }
                else { locatingLimitations.append(id) }
            }
        }
        try require(try Data(contentsOf: root.appendingPathComponent("research.json")) == original, "Research changed during verification")
        try require(try Data(contentsOf: root.appendingPathComponent("reading.json")) == readingData, "Reading changed during verification")
        let result: [String: Any] = ["passed": true, "snapshot": book.document.researchRef.snapshotId,
            "readingId": book.document.id, "scenes": book.orderedScenes.count, "views": book.document.views.count,
            "focuses": book.document.focuses.count, "focusRoutes": routeCount, "canonicalEvidence": requested.count,
            "originalPDFs": documents.count, "physicalPages": pageRoutes.count,
            "popplerTableMatches": popplerMatches, "locatingLimitations": locatingLimitations,
            "researchAndReadingUnchanged": true]
        let json = try JSONSerialization.data(withJSONObject: result, options: [.prettyPrinted, .sortedKeys])
        print(String(decoding: json, as: UTF8.self))
    }
}
