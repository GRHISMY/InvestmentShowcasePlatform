import Foundation

struct ShelfCatalog: Codable {
    let schemaVersion: Int
    let companies: [Company]
    struct Company: Codable {
        struct Identity: Codable { let id, name, code, exchange: String }
        let company: Identity
        let currentVersionId: String
        let versions: [Version]
    }
    struct Version: Codable, Equatable {
        let versionId, snapshotId, snapshotManifestSHA256, resourceManifestSHA256, packagePath: String
        let reportId: String
        let reportRevision: Int
        let financialPeriodStart, financialPeriodEnd, researchAsOf: String
    }

    /// Local state preserves discovery metadata separately from the bundled input.
    /// Both commit together, so a restart cannot forget an immutable cloud definition.
    struct Cache: Codable {
        let catalog: ShelfCatalog
        let published: ShelfCatalog?
        let verified: Set<ShelfVersionID>?
    }

    func validateUpdate(against previous: ShelfCatalog?, protecting versions: Set<ShelfVersionID>) throws {
        guard let previous else { return }
        for item in companies {
            guard let old = previous.companies.first(where: { $0.company.id == item.company.id }) else { continue }
            for version in item.versions {
                if versions.contains(ShelfVersionID(companyID: item.company.id, versionID: version.versionId)),
                   let known = old.versions.first(where: { $0.versionId == version.versionId }), known != version {
                    throw StudyPackageError.invalidManifest("immutable publication definition changed")
                }
            }
        }
    }

    static func bundled(_ study: ReadableStudy) throws -> ShelfCatalog {
        let identity = study.identity
        let report = study.research.research.report
        let company = study.research.research.company
        let versionID = ShelfPublicationIdentity.versionID(snapshotID: identity.snapshotID, manifestSHA256: identity.snapshotManifestSHA256)
        let manifest = try Data(contentsOf: study.resources.root.appendingPathComponent("resource-manifest.json"))
        let version = Version(versionId: versionID, snapshotId: identity.snapshotID,
            snapshotManifestSHA256: identity.snapshotManifestSHA256, resourceManifestSHA256: ReadingLibrary.sha256(manifest),
            packagePath: "packages/" + company.id + "/" + versionID, reportId: identity.reportID,
            reportRevision: report.revision, financialPeriodStart: report.coverage.start,
            financialPeriodEnd: report.coverage.end, researchAsOf: report.researchAsOf)
        return ShelfCatalog(schemaVersion: 1, companies: [Company(company: Company.Identity(id: company.id,
            name: company.name, code: company.code, exchange: ""), currentVersionId: versionID, versions: [version])])
    }

    /// A missing cloud entry does not delete an already known original publication.
    func retainingKnownVersions(from previous: ShelfCatalog?) -> ShelfCatalog {
        guard let previous else { return self }
        var merged = companies
        for old in previous.companies {
            if let index = merged.firstIndex(where: { $0.company.id == old.company.id }) {
                let current = merged[index]
                let extra = old.versions.filter { old in !current.versions.contains(where: { $0.versionId == old.versionId }) }
                merged[index] = Company(company: current.company, currentVersionId: current.currentVersionId,
                    versions: current.versions + extra)
            } else { merged.append(old) }
        }
        return ShelfCatalog(schemaVersion: schemaVersion, companies: merged)
    }

    static func decode(_ data: Data) throws -> ShelfCatalog {
        let catalog = try JSONDecoder().decode(ShelfCatalog.self, from: data)
        guard catalog.schemaVersion == 1,
              Set(catalog.companies.map(\.company.id)).count == catalog.companies.count else { throw StudyPackageError.invalidManifest("catalog schema") }
        for item in catalog.companies {
            guard Set(item.versions.map(\.versionId)).count == item.versions.count,
                  item.versions.contains(where: { $0.versionId == item.currentVersionId }) else {
                throw StudyPackageError.invalidManifest("duplicate publication identity")
            }
            guard try ShelfPath.parts(item.company.id).count == 1 else { throw CloudFolderError.invalidPath(item.company.id) }
            for version in item.versions {
                guard try ShelfPath.parts(version.versionId).count == 1,
                      version.versionId == ShelfPublicationIdentity.versionID(snapshotID: version.snapshotId,
                          manifestSHA256: version.snapshotManifestSHA256),
                      version.packagePath == "packages/" + item.company.id + "/" + version.versionId else {
                    throw CloudFolderError.invalidPath(version.packagePath)
                }
            }
        }
        return catalog
    }

    func entries(states: [ShelfVersionID: ShelfPreparationState]) -> [ShelfEntry] {
        companies.map { item in
            ShelfEntry(id: item.company.id, name: item.company.name, code: item.company.code,
                exchange: item.company.exchange,
                currentVersionID: ShelfVersionID(companyID: item.company.id, versionID: item.currentVersionId),
                versions: item.versions.map { version in
                    let id = ShelfVersionID(companyID: item.company.id, versionID: version.versionId)
                    return ShelfVersionEntry(id: id, snapshotID: version.snapshotId, reportRevision: version.reportRevision,
                        financialPeriodStart: version.financialPeriodStart, financialPeriodEnd: version.financialPeriodEnd,
                        researchAsOf: version.researchAsOf, isCurrent: version.versionId == item.currentVersionId,
                        state: states[id] ?? .waiting)
                })
        }
    }
}

/// One identity rule is shared by distribution discovery and continuation lookup.
enum ShelfPublicationIdentity {
    static func versionID(snapshotID: String, manifestSHA256: String) -> String {
        snapshotID + "--" + manifestSHA256
    }
}
