import Foundation
import Observation

/// The sole owner of publication preparation and durable reading record I/O.
@MainActor @Observable
public final class StudyShelf {
    public private(set) var connectionState: ShelfConnectionState = .disconnected
    public var recordState: ShelfRecordState { recordStore.state }
    public var recommendedContinuation: ShelfContinuationChoice? { recordStore.continuations.first }
    public var entries: [ShelfEntry] {
        let choices = recordStore.continuations
        return (catalog?.entries(states: states) ?? []).map { value in
            var entry = value
            entry.continuations = choices.filter { $0.versionID.companyID == entry.id }
            entry.hasUpdate = entry.versions.contains { $0.id == entry.currentVersionID && $0.state == .ready }
                && entry.continuations.first.map { $0.versionID != entry.currentVersionID } == true
            return entry
        }
    }
    private let localRoot: URL
    private let cloud: any CloudFolder
    private let recordStore: ShelfRecordStore
    private let legacyBookmarks: [StudyIdentity: Data]
    private struct PreparationWork {
        let id: UUID
        let task: Task<ReadableStudy, Error>
    }
    private var preparations: [ShelfVersionID: PreparationWork] = [:]
    private var bundled: [ShelfVersionID: ReadableStudy] = [:]
    private var validatedStudies: [ShelfVersionID: ReadableStudy] = [:]
    private var connectionIntent: UUID?
    private var openIntent: UUID?
    private var refreshIntent: UUID?
    private var hasAccess = false
    private var catalog: ShelfCatalog?
    private var publishedCatalog: ShelfCatalog?
    private var verifiedVersions: Set<ShelfVersionID> = []
    private var states: [ShelfVersionID: ShelfPreparationState] = [:]

    public init(localRoot: URL, deviceID: String, cloud: any CloudFolder, bundledStudy: ReadableStudy? = nil,
                legacyBookmarks: [StudyIdentity: Data] = [:]) {
        self.localRoot = localRoot
        self.cloud = cloud
        self.legacyBookmarks = legacyBookmarks
        recordStore = ShelfRecordStore(localRoot: localRoot, deviceID: deviceID, cloud: cloud)
        let saved = localRoot.appendingPathComponent("catalog.json")
        if let data = try? Data(contentsOf: saved) {
            if let cache = try? JSONDecoder().decode(ShelfCatalog.Cache.self, from: data) {
                catalog = cache.catalog
                publishedCatalog = cache.published
                verifiedVersions = cache.verified ?? []
            } else if let legacy = try? ShelfCatalog.decode(data) {
                catalog = legacy
                publishedCatalog = legacy
            }
        }
        if let bundledStudy, let initial = try? ShelfCatalog.bundled(bundledStudy), let item = initial.companies.first {
            let id = ShelfVersionID(companyID: item.company.id, versionID: item.currentVersionId)
            bundled[id] = bundledStudy
            validatedStudies[id] = bundledStudy
            states[id] = .ready
            catalog = (catalog ?? initial).retainingKnownVersions(from: initial)
        }
        recordStore.onAccessFailure = { [weak self] error in self?.connectionFailed(error) }
    }

    /// Capabilities come from a successfully validated package, never catalog metadata.
    public func availableModes(for version: ShelfVersionID) -> [ReadingMode]? {
        validatedStudies[version].map(StudyReader.availableModes(in:))
    }

    /// Resolves only the exact opaque candidate; display never changes its ordering or identity.
    public func readingMode(for choice: ShelfContinuationChoice) -> ReadingMode? {
        guard let study = validatedStudies[choice.versionID],
              let checkpoint = recordStore.mainCheckpoint(for: choice) else { return nil }
        return StudyReader.continuationMode(in: study, identity: choice.identity,
            checkpoint: checkpoint, isLocalDevice: choice.isLocalDevice)
    }

    public func acceptCheckpoint(_ checkpoint: ReadingCheckpoint) { recordStore.acceptCheckpoint(checkpoint) }
    public func retryRecords() async { await recordStore.retryRecords() }

    /// Returns the bookmark confirmed by this request, refreshed when necessary.
    /// Nil means this request failed or was replaced; another request's state is irrelevant.
    public func connect(bookmark: Data) async -> Data? {
        let intent = UUID()
        connectionIntent = intent
        refreshIntent = nil
        openIntent = nil
        hasAccess = false
        recordStore.setConnected(false)
        connectionState = .checking
        defer { if connectionIntent == intent { connectionIntent = nil } }
        do {
            let result = try await cloud.restoreAccess(bookmark: bookmark)
            guard connectionIntent == intent, !Task.isCancelled else { return nil }
            hasAccess = true
            connectionState = .connected
            recordStore.setConnected(true)
            return result.replacementBookmark ?? bookmark
        } catch {
            guard connectionIntent == intent, !Task.isCancelled else { return nil }
            connectionFailed(error)
            return nil
        }
    }

    public func retryPreparation(_ version: ShelfVersionID) async {
        guard let company = catalog?.companies.first(where: { $0.company.id == version.companyID }),
              let publication = company.versions.first(where: { $0.versionId == version.versionID }) else { return }
        _ = try? await prepare(publication, company: company.company)
    }

    public func continueReading(_ choice: ShelfContinuationChoice? = nil) async -> ShelfOpenResult {
        guard let selected = choice ?? recommendedContinuation else {
            openIntent = nil
            return .unavailable("还没有可以继续的阅读位置。")
        }
        guard recordStore.continuations.contains(selected) else {
            openIntent = nil
            return .unavailable("这个阅读位置候选已经变化，请重新选择。")
        }
        let frozen = recordStore.restoration(for: selected.identity, preferred: selected)
        return await open(selected.versionID, restoration: frozen)
    }

    public func readVersion(_ version: ShelfVersionID) async -> ShelfOpenResult {
        await open(version)
    }

    private func open(_ version: ShelfVersionID, restoration: RestoreCandidates? = nil) async -> ShelfOpenResult {
        let intent = UUID()
        openIntent = intent
        defer { if openIntent == intent { openIntent = nil } }
        guard let company = catalog?.companies.first(where: { $0.company.id == version.companyID }),
              let publication = company.versions.first(where: { $0.versionId == version.versionID }) else {
            return .unavailable("这份研究版本尚未出现在研究库中。")
        }
        do {
            let study = try await prepare(publication, company: company.company)
            guard openIntent == intent, !Task.isCancelled else { return .superseded }
            if let restoration, restoration.identity != study.identity {
                return .unavailable("这份研究编排与所选阅读位置不一致，请重新选择可用的位置。")
            }
            let candidates = restoration ?? recordStore.restoration(for: study.identity)
            return .opened(ShelfReading(study: study, reader: StudyReader(study: study, bookmark: legacyBookmarks[study.identity], restoreCandidates: candidates)))
        } catch {
            guard openIntent == intent, !Task.isCancelled else { return .superseded }
            return .unavailable(error.localizedDescription)
        }
    }

    public func refresh() async {
        async let publications: Void = refreshPublications()
        async let personal: Void = recordStore.refresh()
        _ = await (publications, personal)
    }

    private func refreshPublications() async {
        let intent = UUID()
        refreshIntent = intent
        defer { if refreshIntent == intent { refreshIntent = nil } }
        if let catalog {
            for item in catalog.companies {
                for version in item.versions {
                    let id = ShelfVersionID(companyID: item.company.id, versionID: version.versionId)
                    if bundledStudy(for: version, company: item.company) != nil {
                        states[id] = .ready
                        rememberVerified(version, companyID: item.company.id)
                        continue
                    }
                    if let root = try? ShelfPreparation.localURL(for: id, root: localRoot),
                       FileManager.default.fileExists(atPath: root.path) {
                        do {
                            let study = try await ShelfPreparation.readLocal(root: root, version: version, company: item.company)
                            guard refreshIntent == intent else { return }
                            validatedStudies[id] = study
                            states[id] = .ready
                            rememberVerified(version, companyID: item.company.id)
                        } catch {
                            guard refreshIntent == intent else { return }
                            validatedStudies[id] = nil
                            states[id] = .failed(error.localizedDescription)
                        }
                    } else if preparations[id] == nil {
                        validatedStudies[id] = nil
                        states[id] = .waiting
                    }
                }
            }
        }
        guard hasAccess else { return }
        let staging = localRoot.appendingPathComponent("staging/" + UUID().uuidString)
        do {
            try FileManager.default.createDirectory(at: staging, withIntermediateDirectories: true)
            defer { try? FileManager.default.removeItem(at: staging) }
            let file = staging.appendingPathComponent("catalog.json")
            try await cloud.copyFile(relativePath: "catalog.json", to: file)
            guard refreshIntent == intent, !Task.isCancelled else { return }
            let discovered = try ShelfCatalog.decode(Data(contentsOf: file))
            for company in discovered.companies {
                for version in company.versions {
                    let id = ShelfVersionID(companyID: company.company.id, versionID: version.versionId)
                    if let input = bundled[id], !ShelfPreparation.matchesMetadata(input, version: version, company: company.company) {
                        throw StudyPackageError.invalidManifest("catalog conflicts with the validated bundled publication")
                    }
                }
            }
            try discovered.validateUpdate(against: publishedCatalog,
                protecting: verifiedVersions.union(preparations.keys))
            let published = discovered.retainingKnownVersions(from: publishedCatalog)
            let catalog = discovered.retainingKnownVersions(from: self.catalog)
            let cache = ShelfCatalog.Cache(catalog: catalog, published: published, verified: verifiedVersions)
            try JSONEncoder().encode(cache).write(to: localRoot.appendingPathComponent("catalog.json"), options: .atomic)
            self.catalog = catalog
            publishedCatalog = published
            connectionState = .connected
            await withTaskGroup(of: Void.self) { group in
                for item in catalog.companies {
                    for version in item.versions {
                        group.addTask { [weak self] in
                            _ = try? await self?.prepare(version, company: item.company)
                        }
                    }
                }
            }
        } catch {
            guard refreshIntent == intent, !Task.isCancelled else { return }
            connectionFailed(error)
        }
    }

    private func connectionFailed(_ error: Error) {
        if let failure = error as? CloudFolderError, failure == .needsSelection {
            refreshIntent = nil
            hasAccess = false
            recordStore.setConnected(false)
            connectionState = .needsSelection(error.localizedDescription)
        } else {
            connectionState = .unavailable(error.localizedDescription)
        }
    }

    private func prepare(_ version: ShelfCatalog.Version, company: ShelfCatalog.Company.Identity) async throws -> ReadableStudy {
        let companyID = company.id
        let id = ShelfVersionID(companyID: companyID, versionID: version.versionId)
        if let study = bundledStudy(for: version, company: company) {
            rememberVerified(version, companyID: company.id)
            return study
        }
        if let pending = preparations[id] { return try await pending.task.value }
        let workID = UUID(), root = localRoot, folder = cloud
        if states[id] != .ready { states[id] = .preparing }
        let task = Task.detached {
            try await ShelfPreparation.prepare(version: version, company: company, localRoot: root, cloud: folder)
        }
        preparations[id] = PreparationWork(id: workID, task: task)
        do {
            let study = try await task.value
            if preparations[id]?.id == workID {
                preparations[id] = nil
                states[id] = .ready
                validatedStudies[id] = study
                rememberVerified(version, companyID: companyID)
            }
            return study
        } catch {
            if preparations[id]?.id == workID {
                preparations[id] = nil
                validatedStudies[id] = nil
                states[id] = .failed(error.localizedDescription)
            }
            throw error
        }
    }

    /// Only validated or in-flight definitions become immutable. A malformed,
    /// never-prepared declaration can be corrected and retried without erasing history.
    private func rememberVerified(_ version: ShelfCatalog.Version, companyID: String) {
        let id = ShelfVersionID(companyID: companyID, versionID: version.versionId)
        guard !verifiedVersions.contains(id),
              publishedCatalog?.companies.first(where: { $0.company.id == companyID })?.versions.contains(version) == true,
              let catalog else { return }
        verifiedVersions.insert(id)
        do {
            let cache = ShelfCatalog.Cache(catalog: catalog, published: publishedCatalog, verified: verifiedVersions)
            try JSONEncoder().encode(cache).write(to: localRoot.appendingPathComponent("catalog.json"), options: .atomic)
        } catch { connectionState = .unavailable(error.localizedDescription) }
    }

    private func bundledStudy(for version: ShelfCatalog.Version, company: ShelfCatalog.Company.Identity) -> ReadableStudy? {
        let companyID = company.id
        let id = ShelfVersionID(companyID: companyID, versionID: version.versionId)
        guard let study = bundled[id], ShelfPreparation.matchesMetadata(study, version: version, company: company) else { return nil }
        return study
    }

}
