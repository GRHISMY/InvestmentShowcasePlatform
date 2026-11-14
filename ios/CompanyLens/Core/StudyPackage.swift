import Foundation

/// Exact published bytes and reading compilation; company or period alone is not a version.
public struct StudyIdentity: Hashable, Codable {
    public let companyID, reportID, snapshotID, snapshotManifestSHA256: String
    public let readingID: String?
    public let readingRevision: Int?
}

/// The caller keeps this prepared directory in place for the entire reading lifetime.
public struct StudyPackageResources {
    public let root: URL
    fileprivate let documents: [String: URL]

    public func pdfURL(sourceID: String) throws -> URL {
        guard let url = documents[sourceID] else { throw StudyPackageError.unknownSource(sourceID) }
        return url
    }
}

public enum StudyPackageError: Error, Equatable, LocalizedError {
    case unknownSource(String)
    case hashMismatch(String)
    case invalidManifest(String)
    case sourceMismatch(String)
    case invalidPath(String)
    case missingFile(String)
    case unreadableFile(String)
    case invalidReading
    case invalidResearch

    public var errorDescription: String? {
        switch self {
        case .unknownSource: return "这份研究中没有对应的原始资料。"
        case .hashMismatch(let file): return "研究资料与发布版本不匹配：" + file
        case .invalidManifest: return "研究包清单不完整或与正式研究不一致，请重新准备资料。"
        case .sourceMismatch: return "原始资料与研究中的来源声明不一致，请重新准备资料。"
        case .invalidPath: return "研究包包含无法使用的资料路径。"
        case .missingFile(let file): return "研究包缺少资料：" + file
        case .unreadableFile(let file): return "研究资料暂时无法读取：" + file
        case .invalidReading: return "图解阅读稿损坏或未绑定这份正式研究，请重新准备资料。"
        case .invalidResearch: return "正式研究损坏或使用了尚不支持的格式，请重新准备资料。"
        }
    }
}

/// A read-only local publication. Loading never falls back to another package or bundle.
public struct ReadableStudy {
    public let identity: StudyIdentity
    public let research: ResearchLibrary
    public let reading: ReadingLibrary?
    public let resources: StudyPackageResources

    public init(root: URL, expectedSnapshotManifestSHA256: String? = nil) throws {
        let root = root.standardizedFileURL.resolvingSymlinksInPath()
        let researchData = try packageData("research.json", in: root)
        let research: ResearchLibrary
        do { research = try ResearchLibrary(researchData: researchData) }
        catch { throw StudyPackageError.invalidResearch }
        var sourceSizes: [String: Int] = [:]
        var sourceURLs: [String: URL] = [:]
        for source in research.research.sources {
            let url = try packageURL(source.assetPath, in: root)
            let bytes = try packageData(source.assetPath, in: root)
            guard ReadingLibrary.sha256(bytes) == source.sha256 else {
                throw StudyPackageError.hashMismatch(source.assetPath)
            }
            sourceSizes[source.id] = bytes.count
            sourceURLs[source.id] = url
        }
        let readingURL = root.appendingPathComponent("reading.json")
        let reading: ReadingLibrary?
        if FileManager.default.fileExists(atPath: readingURL.path) {
            let readingData = try packageData("reading.json", in: root)
            do { reading = try ReadingLibrary(researchData: researchData, readingData: readingData) }
            catch { throw StudyPackageError.invalidReading }
        } else { reading = nil }
        let snapshotData = try packageData("snapshot.json", in: root)
        if let expectedSnapshotManifestSHA256,
           ReadingLibrary.sha256(snapshotData) != expectedSnapshotManifestSHA256 {
            throw StudyPackageError.hashMismatch("snapshot.json")
        }
        let manifest = try packageManifest(ResourceManifest.self,
            data: packageData("resource-manifest.json", in: root), file: "resource-manifest.json")
        guard ReadingLibrary.sha256(snapshotData) == manifest.snapshotManifestSHA256 else {
            throw StudyPackageError.hashMismatch("snapshot.json")
        }
        guard manifest.documents.count == research.research.sources.count,
              Set(manifest.documents.map(\.sourceId)).count == manifest.documents.count else {
            throw StudyPackageError.invalidManifest("PDF sources")
        }
        for source in research.research.sources {
            guard let document = manifest.documents.first(where: { $0.sourceId == source.id }),
                  document.documentFile == source.assetPath, document.sha256 == source.sha256,
                  document.title == source.title, document.pageCount == source.pdfPages,
                  document.bytes == sourceSizes[source.id] else {
                throw StudyPackageError.sourceMismatch(source.id)
            }
        }
        let snapshot = try packageManifest(SnapshotManifest.self, data: snapshotData, file: "snapshot.json")
        guard snapshot.schemaVersion == "cfa-research-snapshot/v1", manifest.schemaVersion == 3,
              snapshot.snapshotID == research.research.publication.snapshotId,
              manifest.snapshotId == snapshot.snapshotID,
              manifest.researchAsOf == research.research.report.researchAsOf,
              manifest.financialPeriodStart == research.research.report.coverage.start,
              manifest.financialPeriodEnd == research.research.report.coverage.end,
              manifest.physicalPageNumbering == "one-based" else {
            throw StudyPackageError.invalidManifest("publication identity or metadata")
        }
        let fileNames = Set(snapshot.files.keys)
        guard Set(["research.json", "research.md", "evidence.md"]).isSubset(of: fileNames),
              fileNames.isDisjoint(with: ["snapshot.json", "resource-manifest.json", "gree-logo.png"]),
              Set(fileNames.filter { $0.lowercased().hasSuffix(".pdf") }) == Set(research.research.sources.map(\.assetPath)),
              fileNames.contains("reading.json") == (reading != nil) else {
            throw StudyPackageError.invalidManifest("published files")
        }
        for (path, expectedHash) in snapshot.files {
            let bytes = try packageData(path, in: root)
            guard ReadingLibrary.sha256(bytes) == expectedHash else { throw StudyPackageError.hashMismatch(path) }
        }
        var datasetFiles = Set(snapshot.files.keys.filter { !$0.contains("/") })
        datasetFiles.insert("snapshot.json")
        if FileManager.default.fileExists(atPath: root.appendingPathComponent("gree-logo.png").path) {
            datasetFiles.insert("gree-logo.png")
        }
        guard Set(manifest.datasets.map(\.file)) == datasetFiles,
              manifest.datasets.count == datasetFiles.count else {
            throw StudyPackageError.invalidManifest("datasets")
        }
        for dataset in manifest.datasets {
            let bytes = try packageData(dataset.file, in: root)
            guard bytes.count == dataset.bytes, ReadingLibrary.sha256(bytes) == dataset.sha256 else {
                throw StudyPackageError.hashMismatch(dataset.file)
            }
        }
        identity = StudyIdentity(companyID: research.research.company.id, reportID: research.research.report.id,
                                 snapshotID: research.research.publication.snapshotId,
                                 snapshotManifestSHA256: ReadingLibrary.sha256(snapshotData),
                                 readingID: reading?.document.id, readingRevision: reading?.document.revision)
        self.research = research
        self.reading = reading
        resources = StudyPackageResources(root: root, documents: sourceURLs)
    }
}

private func packageURL(_ path: String, in root: URL) throws -> URL {
    let parts = path.components(separatedBy: "/")
    guard root.isFileURL, !path.contains("\\"), !path.contains("\0"),
          parts.allSatisfy({ !$0.isEmpty && $0 != "." && $0 != ".." }) else {
        throw StudyPackageError.invalidPath(path)
    }
    let url = root.appendingPathComponent(path).resolvingSymlinksInPath()
    guard url.path.hasPrefix(root.path + "/") else { throw StudyPackageError.invalidPath(path) }
    guard FileManager.default.fileExists(atPath: url.path) else { throw StudyPackageError.missingFile(path) }
    guard (try? url.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true else {
        throw StudyPackageError.unreadableFile(path)
    }
    return url
}

private func packageData(_ path: String, in root: URL) throws -> Data {
    let url = try packageURL(path, in: root)
    do { return try Data(contentsOf: url) }
    catch { throw StudyPackageError.unreadableFile(path) }
}

private func packageManifest<T: Decodable>(_ type: T.Type, data: Data, file: String) throws -> T {
    do { return try JSONDecoder().decode(type, from: data) }
    catch { throw StudyPackageError.invalidManifest(file) }
}

private struct SnapshotManifest: Decodable {
    let schemaVersion, snapshotID: String
    let files: [String: String]

    private enum CodingKeys: String, CodingKey {
        case schemaVersion = "schema_version", snapshotID = "snapshot_id", files
    }
}

private struct ResourceManifest: Decodable {
    let schemaVersion: Int
    let snapshotId, snapshotManifestSHA256, researchAsOf: String
    let financialPeriodStart, financialPeriodEnd, physicalPageNumbering: String
    let documents: [Document]
    let datasets: [Dataset]

    struct Document: Decodable {
        let sourceId, title, documentFile, sha256: String
        let bytes, pageCount: Int
    }

    struct Dataset: Decodable {
        let file, sha256: String
        let bytes: Int
    }
}
