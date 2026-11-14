import Foundation

/// Copies declared bytes into a private candidate, then earns a permanent version directory.
/// A cloud download acknowledgement or a directory listing never grants readiness.
enum ShelfPreparation {
    private struct Snapshot: Decodable { let files: [String: String] }
    private struct Resources: Decodable {
        struct Dataset: Decodable { let file: String }
        struct Document: Decodable { let documentFile: String }
        let datasets: [Dataset]
        let documents: [Document]
    }

    static func prepare(version: ShelfCatalog.Version, company: ShelfCatalog.Company.Identity, localRoot: URL,
                        cloud: any CloudFolder) async throws -> ReadableStudy {
        let id = ShelfVersionID(companyID: company.id, versionID: version.versionId)
        let destination = try localURL(for: id, root: localRoot)
        if FileManager.default.fileExists(atPath: destination.path) {
            return try validate(root: destination, version: version, company: company)
        }
        let candidate = localRoot.appendingPathComponent("staging/package-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: candidate, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: candidate) }
        try await copy("snapshot.json", version: version, candidate: candidate, cloud: cloud)
        try await copy("resource-manifest.json", version: version, candidate: candidate, cloud: cloud)
        let snapshotBytes = try Data(contentsOf: candidate.appendingPathComponent("snapshot.json"))
        let resourceBytes = try Data(contentsOf: candidate.appendingPathComponent("resource-manifest.json"))
        guard ReadingLibrary.sha256(snapshotBytes) == version.snapshotManifestSHA256 else {
            throw StudyPackageError.hashMismatch("snapshot.json")
        }
        guard ReadingLibrary.sha256(resourceBytes) == version.resourceManifestSHA256 else {
            throw StudyPackageError.hashMismatch("resource-manifest.json")
        }
        let snapshot = try JSONDecoder().decode(Snapshot.self, from: snapshotBytes)
        let resources = try JSONDecoder().decode(Resources.self, from: resourceBytes)
        let files = Set(snapshot.files.keys).union(resources.datasets.map(\.file)).union(resources.documents.map(\.documentFile))
        for path in files.sorted() where path != "snapshot.json" && path != "resource-manifest.json" {
            try await copy(path, version: version, candidate: candidate, cloud: cloud)
        }
        _ = try validate(root: candidate, version: version, company: company)
        try FileManager.default.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
        try FileManager.default.moveItem(at: candidate, to: destination)
        return try validate(root: destination, version: version, company: company)
    }

    static func localURL(for id: ShelfVersionID, root: URL) throws -> URL {
        let relative = "versions/" + id.companyID + "/" + id.versionID
        return try ShelfPath.local(relative, in: root)
    }

    static func readLocal(root: URL, version: ShelfCatalog.Version, company: ShelfCatalog.Company.Identity) async throws -> ReadableStudy {
        try await Task.detached { try validate(root: root, version: version, company: company) }.value
    }

    static func validate(root: URL, version: ShelfCatalog.Version, company: ShelfCatalog.Company.Identity) throws -> ReadableStudy {
        let resourceBytes = try Data(contentsOf: root.appendingPathComponent("resource-manifest.json"))
        guard ReadingLibrary.sha256(resourceBytes) == version.resourceManifestSHA256 else {
            throw StudyPackageError.hashMismatch("resource-manifest.json")
        }
        let study = try ReadableStudy(root: root, expectedSnapshotManifestSHA256: version.snapshotManifestSHA256)
        guard matchesMetadata(study, version: version, company: company) else {
            throw StudyPackageError.invalidManifest("catalog identity")
        }
        return study
    }

    static func matchesMetadata(_ study: ReadableStudy, version: ShelfCatalog.Version,
                                company: ShelfCatalog.Company.Identity) -> Bool {
        let report = study.research.research.report
        return study.identity.companyID == company.id
            && study.research.research.company.name == company.name
            && study.research.research.company.code == company.code
            && study.identity.reportID == version.reportId
            && study.identity.snapshotID == version.snapshotId
            && report.revision == version.reportRevision
            && report.coverage.start == version.financialPeriodStart
            && report.coverage.end == version.financialPeriodEnd
            && report.researchAsOf == version.researchAsOf
    }

    private static func copy(_ path: String, version: ShelfCatalog.Version, candidate: URL,
                             cloud: any CloudFolder) async throws {
        let localURL = try ShelfPath.local(path, in: candidate)
        _ = try ShelfPath.parts(version.packagePath)
        try FileManager.default.createDirectory(at: localURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try await cloud.copyFile(relativePath: version.packagePath + "/" + path, to: localURL)
    }
}

enum ShelfPath {
    static func parts(_ path: String) throws -> [String] {
        let parts = path.components(separatedBy: "/")
        guard !path.contains("\\"), !path.contains("\0"),
              parts.allSatisfy({ !$0.isEmpty && $0 != "." && $0 != ".." }) else {
            throw CloudFolderError.invalidPath(path)
        }
        return parts
    }
    static func local(_ path: String, in root: URL) throws -> URL {
        _ = try parts(path)
        let canonicalRoot = root.standardizedFileURL.resolvingSymlinksInPath()
        let result = canonicalRoot.appendingPathComponent(path).resolvingSymlinksInPath()
        guard result.path.hasPrefix(canonicalRoot.path + "/") else { throw CloudFolderError.invalidPath(path) }
        return result
    }
}
