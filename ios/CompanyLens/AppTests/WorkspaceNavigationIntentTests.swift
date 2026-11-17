import Foundation
import Observation
import XCTest
import ResearchCore
@testable import CompanyLens

@MainActor
final class WorkspaceNavigationIntentTests: XCTestCase {
    func testReportEntranceWithoutAReaderDiscardsAnEarlierPendingOpen() async throws {
        let fixture = try fixture()
        let workspace = fixture.workspace
        let paused = expectation(description: "opening waits for the real package")
        await fixture.cloud.pauseCopy(fixture.original.path + "/snapshot.json") { paused.fulfill() }
        workspace.open(fixture.original.id)
        await fulfillment(of: [paused], timeout: 5)

        workspace.showReading(mode: .report)
        await fixture.cloud.resumeCopy(fixture.original.path + "/snapshot.json")
        await waitUntil("the earlier opening has finished preparation") { fixture.isReady(fixture.original.id) }

        XCTAssertNil(workspace.activeReading?.id, "a late package must not replace the later empty report entrance")
        XCTAssertFalse(workspace.isReadingVisible)
        XCTAssertNil(workspace.observationGeneration)
        XCTAssertNil(workspace.shelf.recommendedContinuation)
    }

    func testDiagramEntranceWithoutAReaderDiscardsAnEarlierPendingOpen() async throws {
        let fixture = try fixture()
        let workspace = fixture.workspace
        let paused = expectation(description: "opening waits for the real package")
        let path = fixture.original.path + "/snapshot.json"
        await fixture.cloud.pauseCopy(path) { paused.fulfill() }
        workspace.open(fixture.original.id)
        await fulfillment(of: [paused], timeout: 5)

        workspace.showReading(mode: .diagram)
        await fixture.cloud.resumeCopy(path)
        await waitUntil("the earlier opening has finished preparation") { fixture.isReady(fixture.original.id) }

        XCTAssertNil(workspace.activeReading?.id)
        XCTAssertFalse(workspace.isReadingVisible)
        XCTAssertNil(workspace.observationGeneration)
        XCTAssertNil(workspace.shelf.recommendedContinuation)
    }

    func testLibraryEntranceWithoutAReaderDiscardsAnEarlierPendingOpen() async throws {
        let fixture = try fixture()
        let workspace = fixture.workspace
        let paused = expectation(description: "opening waits for the real package")
        let path = fixture.original.path + "/snapshot.json"
        await fixture.cloud.pauseCopy(path) { paused.fulfill() }
        workspace.open(fixture.original.id)
        await fulfillment(of: [paused], timeout: 5)

        workspace.returnToLibrary()
        await fixture.cloud.resumeCopy(path)
        await waitUntil("the earlier opening has finished preparation") { fixture.isReady(fixture.original.id) }

        XCTAssertNil(workspace.activeReading?.id)
        XCTAssertFalse(workspace.isReadingVisible)
        XCTAssertNil(workspace.observationGeneration)
        XCTAssertNil(workspace.shelf.recommendedContinuation)
    }

    func testExplicitReportResumesTheRetainedVersionWhileAnotherVersionIsOpening() async throws {
        let fixture = try fixture(includeSecond: true)
        let workspace = fixture.workspace
        workspace.open(fixture.original.id)
        await waitUntil("the original study is open") { workspace.activeReading != nil }
        let original = try XCTUnwrap(workspace.activeReading)
        workspace.showReading(mode: .report)
        let binding = workspace.binding(for: original)
        guard case .report(let report) = binding.wrappedValue.primaryPage else { return XCTFail("report") }
        binding.wrappedValue.reportVisiblePosition(report.observation,
            position: ReadingPosition(anchorID: "report/summary", localOffset: 42), cause: .userBrowsing)
        workspace.returnToLibrary()
        let checkpoint = workspace.activeReading?.reader.checkpoint
        let next = try XCTUnwrap(fixture.next)
        let path = next.path + "/snapshot.json"
        let paused = expectation(description: "the replacement study is still arriving")
        await fixture.cloud.pauseCopy(path) { paused.fulfill() }
        workspace.open(next.id)
        await fulfillment(of: [paused], timeout: 5)

        workspace.showReading(mode: .report)
        await fixture.cloud.resumeCopy(path)
        await waitUntil("the discarded replacement finished preparing") { fixture.isReady(next.id) }

        XCTAssertEqual(workspace.activeReading?.id, original.id)
        XCTAssertEqual(workspace.activeReading?.study.identity, original.study.identity)
        XCTAssertTrue(workspace.isReadingVisible)
        XCTAssertEqual(workspace.activeReading?.reader.checkpoint, checkpoint)
        guard case .report(let resumed) = workspace.activeReading?.reader.primaryPage else { return XCTFail("retained report") }
        XCTAssertEqual(resumed.restorePosition, ReadingPosition(anchorID: "report/summary", localOffset: 42))
    }

    func testTwoOpensCompletedInReverseKeepTheLaterChosenVersion() async throws {
        let fixture = try fixture(includeSecond: true)
        let workspace = fixture.workspace
        let next = try XCTUnwrap(fixture.next)
        let originalPath = fixture.original.path + "/snapshot.json"
        let nextPath = next.path + "/snapshot.json"
        let originalPaused = expectation(description: "the first chosen version is delayed")
        let nextPaused = expectation(description: "the second chosen version is delayed")
        await fixture.cloud.pauseCopy(originalPath) { originalPaused.fulfill() }
        await fixture.cloud.pauseCopy(nextPath) { nextPaused.fulfill() }
        workspace.open(fixture.original.id)
        await fulfillment(of: [originalPaused], timeout: 5)
        workspace.open(next.id)
        await fulfillment(of: [nextPaused], timeout: 5)

        await fixture.cloud.resumeCopy(nextPath)
        await waitUntil("the later choice opens first") { workspace.activeReading?.study.identity.snapshotID == "navigation-fixture-v5" }
        let chosen = try XCTUnwrap(workspace.activeReading)
        await fixture.cloud.resumeCopy(originalPath)
        await waitUntil("the first choice eventually finishes") { fixture.isReady(fixture.original.id) }

        XCTAssertEqual(workspace.activeReading?.id, chosen.id)
        XCTAssertEqual(workspace.activeReading?.study.identity.snapshotID, "navigation-fixture-v5")
        XCTAssertEqual(workspace.activeReading?.study.research.research.report.revision, 5)
        XCTAssertTrue(workspace.isReadingVisible)
        XCTAssertNil(workspace.notice)
        guard case .report = workspace.activeReading?.reader.primaryPage else { return XCTFail("the selected report-only version") }
    }

    func testLateFailureCannotReplaceTheNoticeOrReportOfALaterIntent() async throws {
        let fixture = try fixture(includeSecond: true)
        let workspace = fixture.workspace
        workspace.open(fixture.original.id)
        await waitUntil("the original study is open") { workspace.activeReading != nil }
        let original = try XCTUnwrap(workspace.activeReading)
        workspace.returnToLibrary()
        let next = try XCTUnwrap(fixture.next)
        let path = next.path + "/snapshot.json"
        let paused = expectation(description: "the replacement will fail after the next intent")
        await fixture.cloud.pauseCopy(path) { paused.fulfill() }
        workspace.open(next.id)
        await fulfillment(of: [paused], timeout: 5)

        workspace.showReading(mode: .report)
        workspace.notice = "保留稍后操作的提示"
        await fixture.cloud.resumeCopy(path, failure: .unavailable("delayed opening failed"))
        await waitUntil("the obsolete preparation has failed") { fixture.hasFailed(next.id) }

        XCTAssertEqual(workspace.activeReading?.id, original.id)
        XCTAssertEqual(workspace.activeReading?.study.identity, original.study.identity)
        XCTAssertTrue(workspace.isReadingVisible)
        XCTAssertEqual(workspace.notice, "保留稍后操作的提示")
        guard case .report = workspace.activeReading?.reader.primaryPage else { return XCTFail("the later report intent remains visible") }
    }

    func testExplicitReportEntranceWinsOverStartupRestorationWithoutAReader() async throws {
        let fixture = try fixture()
        let workspace = fixture.workspace
        var reader = StudyReader(study: fixture.study, clock: { Date(timeIntervalSince1970: 1_700_000_000) })
        guard case .overview(let page) = reader.primaryPage else { return XCTFail("overview") }
        reader.reportVisiblePosition(page.observation,
            position: ReadingPosition(anchorID: "overview", localOffset: 12), cause: .userBrowsing)
        workspace.shelf.acceptCheckpoint(try XCTUnwrap(reader.checkpoint))
        fixture.defaults.set(Data("saved directory".utf8), forKey: "study-library-folder-bookmark")
        let paused = expectation(description: "startup captured its continuation and is restoring directory access")
        await fixture.cloud.pauseAccess { paused.fulfill() }
        let startup = Task { await workspace.start() }
        await fulfillment(of: [paused], timeout: 5)

        workspace.showReading(mode: .report)
        await fixture.cloud.resumeAccess()
        await startup.value
        await waitUntil("startup refresh finished preparing its offline package") { fixture.isReady(fixture.original.id) }

        XCTAssertNil(workspace.activeReading?.id, "startup must not reopen its captured continuation after an explicit empty report entry")
        XCTAssertFalse(workspace.isReadingVisible)
        XCTAssertNil(workspace.observationGeneration)
        XCTAssertNotNil(workspace.shelf.recommendedContinuation, "the user's saved reading remains available from the library")
    }

    private func fixture(includeSecond: Bool = false) throws -> NavigationFixture {
        let fixture = try NavigationFixture(includeSecond: includeSecond)
        addTeardownBlock {
            await fixture.cloud.resumeAll()
            await MainActor.run {
                try? FileManager.default.removeItem(at: fixture.root)
                fixture.defaults.removePersistentDomain(forName: fixture.defaultsName)
            }
        }
        return fixture
    }

    /// Observation waits for a named public state transition, rather than guessing a scheduler delay.
    private func waitUntil(_ description: String, predicate: @escaping @MainActor () -> Bool) async {
        let reached = expectation(description: description)
        var finished = false
        @MainActor func observe() {
            guard !finished else { return }
            withObservationTracking {
                if predicate() { finished = true; reached.fulfill() }
            } onChange: { Task { @MainActor in observe() } }
        }
        observe()
        await fulfillment(of: [reached], timeout: 10)
        finished = true
    }
}

private struct NavigationPublication {
    let id: ShelfVersionID
    let path: String
}

@MainActor
private final class NavigationFixture {
    let root: URL
    let cloud: NavigationCloudFolder
    let defaultsName = "workspace-navigation-" + UUID().uuidString
    let defaults: UserDefaults
    let original: NavigationPublication
    let next: NavigationPublication?
    let study: ReadableStudy
    let workspace: StudyWorkspace

    init(includeSecond: Bool) throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("workspace-navigation-" + UUID().uuidString)
        let remote = root.appendingPathComponent("cloud")
        let local = root.appendingPathComponent("local")
        try FileManager.default.createDirectory(at: remote, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: local, withIntermediateDirectories: true)
        let source = ProcessInfo.processInfo.environment["COMPANYLENS_STUDY_FIXTURE"].map(URL.init(fileURLWithPath:))
            ?? URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("Study")
        study = try ReadableStudy(root: source)
        let identity = study.identity
        let versionID = identity.snapshotID + "--" + identity.snapshotManifestSHA256
        let path = "packages/" + identity.companyID + "/" + versionID
        let destination = remote.appendingPathComponent(path)
        try FileManager.default.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
        try FileManager.default.copyItem(at: source, to: destination)
        let research = study.research.research
        var catalog: [String: Any] = ["schemaVersion": 1, "companies": [[
            "company": ["id": identity.companyID, "name": research.company.name, "code": research.company.code, "exchange": "SZ"],
            "currentVersionId": versionID,
            "versions": [["versionId": versionID, "snapshotId": identity.snapshotID,
                "snapshotManifestSHA256": identity.snapshotManifestSHA256,
                "resourceManifestSHA256": ReadingLibrary.sha256(try Data(contentsOf: destination.appendingPathComponent("resource-manifest.json"))),
                "packagePath": path, "reportId": identity.reportID, "reportRevision": research.report.revision,
                "financialPeriodStart": research.report.coverage.start, "financialPeriodEnd": research.report.coverage.end,
                "researchAsOf": research.report.researchAsOf]]
        ]]]
        if includeSecond {
            let candidate = root.appendingPathComponent("next-candidate")
            try FileManager.default.copyItem(at: source, to: candidate)
            try FileManager.default.removeItem(at: candidate.appendingPathComponent("reading.json"))
            var updatedResearch = try Self.object("research.json", in: candidate)
            var report = try XCTUnwrap(updatedResearch["report"] as? [String: Any])
            report["revision"] = 5
            report["summary"] = "第二版完整报告，有自己的正式研究身份。"
            updatedResearch["report"] = report
            var publication = try XCTUnwrap(updatedResearch["publication"] as? [String: Any])
            publication["snapshot_id"] = "navigation-fixture-v5"
            updatedResearch["publication"] = publication
            try Self.write(updatedResearch, to: "research.json", in: candidate)
            var snapshot = try Self.object("snapshot.json", in: candidate)
            snapshot["snapshot_id"] = "navigation-fixture-v5"
            var files = try XCTUnwrap(snapshot["files"] as? [String: String])
            files.removeValue(forKey: "reading.json")
            files["research.json"] = ReadingLibrary.sha256(try Data(contentsOf: candidate.appendingPathComponent("research.json")))
            snapshot["files"] = files
            try Self.write(snapshot, to: "snapshot.json", in: candidate)
            let snapshotHash = ReadingLibrary.sha256(try Data(contentsOf: candidate.appendingPathComponent("snapshot.json")))
            var manifest = try Self.object("resource-manifest.json", in: candidate)
            manifest["snapshotId"] = "navigation-fixture-v5"
            manifest["snapshotManifestSHA256"] = snapshotHash
            var datasets = try XCTUnwrap(manifest["datasets"] as? [[String: Any]])
                .filter { $0["file"] as? String != "reading.json" }
            for index in datasets.indices {
                let file = try XCTUnwrap(datasets[index]["file"] as? String)
                let bytes = try Data(contentsOf: candidate.appendingPathComponent(file))
                datasets[index]["sha256"] = ReadingLibrary.sha256(bytes)
                datasets[index]["bytes"] = bytes.count
            }
            manifest["datasets"] = datasets
            try Self.write(manifest, to: "resource-manifest.json", in: candidate)
            let nextVersionID = "navigation-fixture-v5--" + snapshotHash
            let nextPath = "packages/" + identity.companyID + "/" + nextVersionID
            let nextDestination = remote.appendingPathComponent(nextPath)
            try FileManager.default.moveItem(at: candidate, to: nextDestination)
            var companies = try XCTUnwrap(catalog["companies"] as? [[String: Any]])
            var versions = try XCTUnwrap(companies[0]["versions"] as? [[String: Any]])
            var nextVersion = versions[0]
            nextVersion["versionId"] = nextVersionID
            nextVersion["snapshotId"] = "navigation-fixture-v5"
            nextVersion["snapshotManifestSHA256"] = snapshotHash
            nextVersion["resourceManifestSHA256"] = ReadingLibrary.sha256(try Data(contentsOf: nextDestination.appendingPathComponent("resource-manifest.json")))
            nextVersion["packagePath"] = nextPath
            nextVersion["reportRevision"] = 5
            versions.append(nextVersion)
            companies[0]["versions"] = versions
            companies[0]["currentVersionId"] = nextVersionID
            catalog["companies"] = companies
            next = NavigationPublication(id: try Self.versionID(company: identity.companyID, version: nextVersionID), path: nextPath)
        } else { next = nil }
        let catalogData = try JSONSerialization.data(withJSONObject: catalog)
        try catalogData.write(to: remote.appendingPathComponent("catalog.json"))
        // A restarted shelf can discover its cached catalog without preparing any package yet.
        try catalogData.write(to: local.appendingPathComponent("catalog.json"))
        original = NavigationPublication(id: try Self.versionID(company: identity.companyID, version: versionID), path: path)
        cloud = NavigationCloudFolder(root: remote)
        defaults = UserDefaults(suiteName: defaultsName)!
        workspace = StudyWorkspace(shelf: StudyShelf(localRoot: local, deviceID: "navigation-tests", cloud: cloud), defaults: defaults)
    }

    func isReady(_ version: ShelfVersionID) -> Bool {
        workspace.shelf.entries.flatMap(\.versions).first { $0.id == version }?.state == .ready
    }

    func hasFailed(_ version: ShelfVersionID) -> Bool {
        if case .failed = workspace.shelf.entries.flatMap(\.versions).first(where: { $0.id == version })?.state { return true }
        return false
    }

    private static func versionID(company: String, version: String) throws -> ShelfVersionID {
        try JSONDecoder().decode(ShelfVersionID.self,
            from: JSONSerialization.data(withJSONObject: ["companyID": company, "versionID": version]))
    }

    private static func object(_ file: String, in root: URL) throws -> [String: Any] {
        try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: root.appendingPathComponent(file))) as? [String: Any])
    }

    private static func write(_ object: [String: Any], to file: String, in root: URL) throws {
        try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys]).write(to: root.appendingPathComponent(file))
    }
}

/// Real files cross the sole transport boundary; only their arrival can be delayed.
private actor NavigationCloudFolder: CloudFolder {
    let root: URL
    private var pauses: [String: () -> Void] = [:]
    private var waiting: [String: CheckedContinuation<CloudFolderError?, Never>] = [:]

    init(root: URL) { self.root = root }

    func pauseCopy(_ path: String, whenPaused: @escaping () -> Void) { pauses[path] = whenPaused }
    func resumeCopy(_ path: String, failure: CloudFolderError? = nil) { waiting.removeValue(forKey: path)?.resume(returning: failure) }
    func pauseAccess(whenPaused: @escaping () -> Void) { pauses["restore-access"] = whenPaused }
    func resumeAccess() { resumeCopy("restore-access") }
    func resumeAll() {
        pauses.removeAll()
        let pending = waiting.values
        waiting.removeAll()
        for continuation in pending { continuation.resume(returning: .cancelled) }
    }

    func restoreAccess(bookmark: Data) async throws -> CloudFolderAccess {
        if let paused = pauses.removeValue(forKey: "restore-access") {
            let failure = await withCheckedContinuation { continuation in
                waiting["restore-access"] = continuation
                paused()
            }
            if let failure { throw failure }
        }
        return CloudFolderAccess()
    }
    func copyFile(relativePath: String, to localURL: URL) async throws {
        if let paused = pauses.removeValue(forKey: relativePath) {
            let failure = await withCheckedContinuation { continuation in
                waiting[relativePath] = continuation
                paused()
            }
            if let failure { throw failure }
        }
        let source = root.appendingPathComponent(relativePath).standardizedFileURL.resolvingSymlinksInPath()
        guard source.path.hasPrefix(root.path + "/") else { throw CloudFolderError.invalidPath(relativePath) }
        guard FileManager.default.fileExists(atPath: source.path) else { throw CloudFolderError.missingFile(relativePath) }
        try FileManager.default.createDirectory(at: localURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try FileManager.default.copyItem(at: source, to: localURL)
    }
    func listRecordFiles() async throws -> [String] { [] }
    func replaceOwnRecord(deviceID: String, contents: Data) async throws {}
}
