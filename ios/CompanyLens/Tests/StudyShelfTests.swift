import Foundation
import XCTest
import Observation
@testable import ResearchCore

@MainActor
final class StudyShelfTests: XCTestCase {
    private var root: URL!
    private var remote: URL!
    private var local: URL!
    private let versionID = "cn-sz-000651-2020-2026-r4-338655191847af3d--8b903db1a5461c5c1b3e835491d3d3eab00c001dcf450314f3c5514e1e34589f"

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("shelf-tests-" + UUID().uuidString)
        remote = root.appendingPathComponent("remote")
        local = root.appendingPathComponent("local")
        try FileManager.default.createDirectory(at: remote, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws { try FileManager.default.removeItem(at: root) }

    func testReadingWaysAppearOnlyForValidatedVersionsAndSurviveOfflineRestart() async throws {
        try publishedLibrary()
        let shelf = StudyShelf(localRoot: local, deviceID: "iphone", cloud: DirectoryCloudFolder(root: remote))
        _ = await shelf.connect(bookmark: Data())
        await shelf.refresh()
        let id = try XCTUnwrap(shelf.entries.first?.currentVersionID)
        XCTAssertEqual(shelf.availableModes(for: id), [.diagram, .report])
        try FileManager.default.removeItem(at: remote)
        let restarted = StudyShelf(localRoot: local, deviceID: "iphone", cloud: DirectoryCloudFolder(root: remote))
        XCTAssertNil(restarted.availableModes(for: id), "Cached catalog metadata alone cannot promise reading capabilities")
        await restarted.refresh()
        XCTAssertEqual(restarted.availableModes(for: id), [.diagram, .report])
        guard case .opened(let reading) = await restarted.readVersion(id) else { return XCTFail("Prepared version should open offline") }
        try FileManager.default.removeItem(at: reading.study.resources.root.appendingPathComponent("reading.json"))
        await restarted.refresh()
        XCTAssertNil(restarted.availableModes(for: id), "A failed revalidation must remove stale capabilities")
    }

    func testPublishedCatalogDiscoversCompanyAndExactVersion() async throws {
        try publishedLibrary()
        let shelf = StudyShelf(localRoot: local, deviceID: "iphone", cloud: DirectoryCloudFolder(root: remote))
        _ = await shelf.connect(bookmark: Data())
        await shelf.refresh()
        let company = try XCTUnwrap(shelf.entries.first)
        XCTAssertEqual(company.id, "cn-sz-000651")
        XCTAssertEqual(company.name, "格力电器")
        XCTAssertEqual(company.currentVersionID.versionID, versionID)
        XCTAssertEqual(company.versions.first?.reportRevision, 4)
        XCTAssertEqual(company.versions.first?.researchAsOf, "2026-11-09")
    }

    func testRefreshPreparesTheCompletePublicationBeforeItCanBeOpened() async throws {
        try publishedLibrary()
        let shelf = StudyShelf(localRoot: local, deviceID: "iphone", cloud: DirectoryCloudFolder(root: remote))
        _ = await shelf.connect(bookmark: Data())
        await shelf.refresh()
        let version = try XCTUnwrap(shelf.entries.first?.versions.first)
        XCTAssertEqual(version.state, .ready)
    }

    func testPreparedVersionOpensFromItsPrivateLocalBytesWhileCloudIsUnavailable() async throws {
        try publishedLibrary()
        let shelf = StudyShelf(localRoot: local, deviceID: "iphone", cloud: DirectoryCloudFolder(root: remote))
        _ = await shelf.connect(bookmark: Data())
        await shelf.refresh()
        let version = try XCTUnwrap(shelf.entries.first?.versions.first?.id)
        try FileManager.default.removeItem(at: remote)
        guard case .opened(let reading) = await shelf.readVersion(version) else {
            return XCTFail("已经准备的完整研究应可离线打开")
        }
        XCTAssertEqual(reading.study.identity.snapshotManifestSHA256, "8b903db1a5461c5c1b3e835491d3d3eab00c001dcf450314f3c5514e1e34589f")
        let pdf = try reading.study.resources.pdfURL(sourceID: "pdf-7cc972f2d199e2ec")
        XCTAssertTrue(pdf.path.hasPrefix(local.path + "/"))
        XCTAssertFalse(try Data(contentsOf: pdf).isEmpty)
        guard case .overview = reading.reader.primaryPage else { return XCTFail("新阅读应从研究全貌开始") }
    }

    func testRestartCanDiscoverAndOpenPreparedVersionsWithoutDirectoryPermission() async throws {
        try publishedLibrary()
        let first = StudyShelf(localRoot: local, deviceID: "iphone", cloud: DirectoryCloudFolder(root: remote))
        _ = await first.connect(bookmark: Data())
        await first.refresh()
        let id = try XCTUnwrap(first.entries.first?.currentVersionID)
        try FileManager.default.removeItem(at: remote)
        let restarted = StudyShelf(localRoot: local, deviceID: "iphone", cloud: DirectoryCloudFolder(root: remote))
        await restarted.refresh()
        XCTAssertEqual(restarted.entries.first?.versions.first?.state, .ready)
        guard case .opened = await restarted.readVersion(id) else { return XCTFail("重启后本机研究应仍可打开") }
        XCTAssertEqual(restarted.connectionState, .disconnected)
    }

    func testUnsupportedCatalogDoesNotReplaceAnAlreadyReadableLibrary() async throws {
        try publishedLibrary()
        let shelf = StudyShelf(localRoot: local, deviceID: "iphone", cloud: DirectoryCloudFolder(root: remote))
        _ = await shelf.connect(bookmark: Data())
        await shelf.refresh()
        let file = remote.appendingPathComponent("catalog.json")
        var catalog = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: file)) as? [String: Any])
        catalog["schemaVersion"] = 99
        try JSONSerialization.data(withJSONObject: catalog).write(to: file)
        await shelf.refresh()
        guard case .unavailable = shelf.connectionState else { return XCTFail("未知目录格式必须明确报错") }
        XCTAssertEqual(shelf.entries.first?.versions.first?.state, .ready)
    }

    func testMissingOriginalDoesNotBecomeReadyAndCanBeRetriedWhenItsBytesArrive() async throws {
        let package = try publishedLibrary()
        let source = package.appendingPathComponent("reports/pdf-7cc972f2d199e2ec.pdf")
        let delayed = root.appendingPathComponent("delayed.pdf")
        try FileManager.default.moveItem(at: source, to: delayed)
        let shelf = StudyShelf(localRoot: local, deviceID: "iphone", cloud: DirectoryCloudFolder(root: remote))
        _ = await shelf.connect(bookmark: Data())
        await shelf.refresh()
        let version = try XCTUnwrap(shelf.entries.first?.versions.first)
        guard case .failed = version.state else { return XCTFail("缺原件时不可就绪") }
        try FileManager.default.moveItem(at: delayed, to: source)
        await shelf.retryPreparation(version.id)
        XCTAssertEqual(shelf.entries.first?.versions.first?.state, .ready)
        guard case .opened = await shelf.readVersion(version.id) else { return XCTFail("完整到达后可以阅读") }
    }

    func testCatalogCannotNameAPackageOutsideItsPublishedCompanyVersionDirectory() async throws {
        try publishedLibrary()
        let file = remote.appendingPathComponent("catalog.json")
        var catalog = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: file)) as? [String: Any])
        var companies = try XCTUnwrap(catalog["companies"] as? [[String: Any]])
        var versions = try XCTUnwrap(companies[0]["versions"] as? [[String: Any]])
        versions[0]["packagePath"] = "../outside"
        companies[0]["versions"] = versions
        catalog["companies"] = companies
        try JSONSerialization.data(withJSONObject: catalog).write(to: file)
        let shelf = StudyShelf(localRoot: local, deviceID: "iphone", cloud: DirectoryCloudFolder(root: remote))
        _ = await shelf.connect(bookmark: Data())
        await shelf.refresh()
        XCTAssertTrue(shelf.entries.isEmpty)
        guard case .unavailable = shelf.connectionState else { return XCTFail("目录路径逃逸须明确拒绝") }
    }

    func testRefreshCanRecoverFromTemporaryCloudUnavailabilityWithoutSelectingFolderAgain() async throws {
        try publishedLibrary()
        let shelf = StudyShelf(localRoot: local, deviceID: "iphone", cloud: DirectoryCloudFolder(root: remote))
        _ = await shelf.connect(bookmark: Data())
        await shelf.refresh()
        let catalog = remote.appendingPathComponent("catalog.json")
        let delayed = root.appendingPathComponent("delayed-catalog.json")
        try FileManager.default.moveItem(at: catalog, to: delayed)
        await shelf.refresh()
        guard case .unavailable = shelf.connectionState else { return XCTFail("暂不可取得须可见") }
        XCTAssertEqual(shelf.entries.first?.versions.first?.state, .ready)
        try FileManager.default.moveItem(at: delayed, to: catalog)
        await shelf.refresh()
        XCTAssertEqual(shelf.connectionState, .connected)
        XCTAssertEqual(shelf.entries.first?.versions.first?.state, .ready)
    }

    func testAnOlderOpenFinishingLateCannotReplaceTheLaterReadingIntent() async throws {
        try publishedLibrary()
        let cloud = GatedCloudFolder(root: remote)
        let shelf = StudyShelf(localRoot: local, deviceID: "iphone", cloud: cloud)
        _ = await shelf.connect(bookmark: Data())
        await shelf.refresh()
        let original = try XCTUnwrap(shelf.entries.first?.currentVersionID)
        let next = try publishNextVersion()
        let missing = remote.appendingPathComponent(next.path + "/reports/pdf-7cc972f2d199e2ec.pdf")
        let delayed = root.appendingPathComponent("delayed-next.pdf")
        try FileManager.default.moveItem(at: missing, to: delayed)
        await shelf.refresh()
        try FileManager.default.moveItem(at: delayed, to: missing)
        let paused = expectation(description: "新版打开正在等待原件")
        await cloud.pauseNextCopy(next.path + "/reports/pdf-7cc972f2d199e2ec.pdf", whenPaused: { paused.fulfill() })
        let earlier = Task { await shelf.readVersion(next.id) }
        await fulfillment(of: [paused], timeout: 5)
        guard case .opened(let later) = await shelf.readVersion(original) else {
            await cloud.resume()
            return XCTFail("后选择的已就绪原版应该立即打开")
        }
        XCTAssertEqual(later.study.research.research.report.revision, 4)
        await cloud.resume()
        guard case .superseded = await earlier.value else { return XCTFail("迟到的旧意图应被替代") }
    }

    func testBundledFormalStudyIsAFirstLaunchOfflineEntryAndLaterCatalogDoesNotDuplicateIt() async throws {
        let package = try publishedLibrary()
        let bundled = try ReadableStudy(root: package)
        let shelf = StudyShelf(localRoot: local, deviceID: "iphone", cloud: DirectoryCloudFolder(root: remote), bundledStudy: bundled)
        await shelf.refresh()
        let id = try XCTUnwrap(shelf.entries.first?.currentVersionID)
        XCTAssertEqual(shelf.entries.first?.versions.first?.state, .ready)
        guard case .opened(let opened) = await shelf.readVersion(id) else { return XCTFail("随附完整研究应可离线阅读") }
        XCTAssertEqual(opened.study.identity, bundled.identity)
        _ = await shelf.connect(bookmark: Data())
        await shelf.refresh()
        XCTAssertEqual(shelf.entries.count, 1)
        XCTAssertEqual(shelf.entries.first?.versions.count, 1)
    }

    func testOpeningAVersionWhileItsAutomaticPreparationIsWaitingStillLeavesItReady() async throws {
        try publishedLibrary()
        let cloud = GatedCloudFolder(root: remote)
        let shelf = StudyShelf(localRoot: local, deviceID: "iphone", cloud: cloud)
        _ = await shelf.connect(bookmark: Data())
        await shelf.refresh()
        let next = try publishNextVersion()
        let paused = expectation(description: "自动准备等待原件")
        await cloud.pauseNextCopy(next.path + "/reports/pdf-7cc972f2d199e2ec.pdf", whenPaused: { paused.fulfill() })
        let preparation = Task { await shelf.refresh() }
        await fulfillment(of: [paused], timeout: 5)
        let opening = Task { await shelf.readVersion(next.id) }
        await Task.yield()
        await cloud.resume()
        await preparation.value
        guard case .opened(let reading) = await opening.value else { return XCTFail("前台打开应与自动准备安全共存") }
        XCTAssertEqual(reading.study.research.research.report.revision, 5)
        XCTAssertEqual(shelf.entries.first?.versions.first(where: { $0.id == next.id })?.state, .ready)
    }

    func testALateOlderCatalogResponseCannotTurnTheCurrentPublicationBack() async throws {
        try publishedLibrary()
        let cloud = GatedCloudFolder(root: remote)
        let shelf = StudyShelf(localRoot: local, deviceID: "iphone", cloud: cloud)
        _ = await shelf.connect(bookmark: Data())
        await shelf.refresh()
        let paused = expectation(description: "旧目录响应在路上")
        await cloud.pauseNextCopy("catalog.json", afterCopy: true, whenPaused: { paused.fulfill() })
        let earlier = Task { await shelf.refresh() }
        await fulfillment(of: [paused], timeout: 5)
        let next = try publishNextVersion()
        await shelf.refresh()
        XCTAssertEqual(shelf.entries.first?.currentVersionID, next.id)
        await cloud.resume()
        await earlier.value
        XCTAssertEqual(shelf.entries.first?.currentVersionID, next.id)
        XCTAssertEqual(shelf.entries.first?.versions.first(where: { $0.id == next.id })?.state, .ready)
    }

    func testOneWaitingPublicationDoesNotHoldBackOtherAutomaticPreparations() async throws {
        try publishedLibrary()
        let cloud = GatedCloudFolder(root: remote)
        let shelf = StudyShelf(localRoot: local, deviceID: "iphone", cloud: cloud)
        _ = await shelf.connect(bookmark: Data())
        await shelf.refresh()
        let waiting = try publishNextVersion()
        let other = try publishNextVersion(revision: 6)
        let paused = expectation(description: "一份研究等待iCloud原件")
        await cloud.pauseNextCopy(waiting.path + "/reports/pdf-7cc972f2d199e2ec.pdf", whenPaused: { paused.fulfill() })
        let refresh = Task { await shelf.refresh() }
        await fulfillment(of: [paused], timeout: 5)
        let ready = expectation(description: "另一份完整研究独立准备完成")
        var finished = false
        @MainActor func observeOther() {
            guard !finished else { return }
            withObservationTracking {
                if shelf.entries.first?.versions.first(where: { $0.id == other.id })?.state == .ready {
                    finished = true; ready.fulfill()
                } else { _ = shelf.entries }
            } onChange: { Task { @MainActor in observeOther() } }
        }
        observeOther()
        await fulfillment(of: [ready], timeout: 5)
        finished = true
        await cloud.resume()
        await refresh.value
        XCTAssertEqual(shelf.entries.first?.versions.first(where: { $0.id == other.id })?.state, .ready)
    }

    func testRevokedFolderPermissionRequestsReselectionWhileKeepingPreparedResearchReadable() async throws {
        try publishedLibrary()
        let cloud = GatedCloudFolder(root: remote)
        let shelf = StudyShelf(localRoot: local, deviceID: "iphone", cloud: cloud)
        _ = await shelf.connect(bookmark: Data())
        await shelf.refresh()
        let original = try XCTUnwrap(shelf.entries.first?.currentVersionID)
        await cloud.revokePermission()
        await shelf.refresh()
        guard case .needsSelection = shelf.connectionState else { return XCTFail("撤权后应提示重新选目录") }
        XCTAssertEqual(shelf.entries.first?.versions.first?.state, .ready)
        guard case .opened = await shelf.readVersion(original) else { return XCTFail("授权失效不应影响已准备的本机研究") }
    }

    func testReadingThePreparedCurrentVersionClearsTheUpdateBadgeWithoutDeletingOldContinuations() async throws {
        let originalPackage = try publishedLibrary()
        let shelf = StudyShelf(localRoot: local, deviceID: "iphone", cloud: DirectoryCloudFolder(root: remote))
        _ = await shelf.connect(bookmark: Data())
        await shelf.refresh()
        var original = StudyReader(study: try ReadableStudy(root: originalPackage), clock: { Date(timeIntervalSince1970: 1_700_000_010) })
        guard case .overview(let overview) = original.primaryPage else { return XCTFail("原版有全貌") }
        original.reportVisiblePosition(overview.observation, position: ReadingPosition(anchorID: "overview"), cause: .userNavigation)
        shelf.acceptCheckpoint(try XCTUnwrap(original.checkpoint))
        let next = try publishNextVersion()
        await shelf.refresh()
        XCTAssertEqual(shelf.entries.first?.hasUpdate, true)
        XCTAssertEqual(shelf.entries.first?.recommendedContinuation?.identity.snapshotManifestSHA256,
            "8b903db1a5461c5c1b3e835491d3d3eab00c001dcf450314f3c5514e1e34589f")
        guard case .opened(let opening) = await shelf.readVersion(next.id) else { return XCTFail("新版应就绪") }
        var current = StudyReader(study: opening.study, clock: { Date(timeIntervalSince1970: 1_700_000_020) })
        guard case .report(let report) = current.primaryPage else { return XCTFail("该新版fixture为纯完整报告") }
        current.reportVisiblePosition(report.observation, position: ReadingPosition(anchorID: report.summaryAnchor.id), cause: .userNavigation)
        shelf.acceptCheckpoint(try XCTUnwrap(current.checkpoint))
        XCTAssertEqual(shelf.entries.first?.hasUpdate, false)
        XCTAssertEqual(shelf.entries.first?.continuations.count, 2)
        await shelf.retryRecords()
    }

    func testALateFailedFolderAssociationCannotReplaceANewerConfirmedAssociation() async throws {
        try publishedLibrary()
        let cloud = GatedCloudFolder(root: remote)
        let shelf = StudyShelf(localRoot: local, deviceID: "iphone", cloud: cloud)
        let firstBookmark = Data("folder-A".utf8), laterBookmark = Data("folder-B".utf8)
        let paused = expectation(description: "旧目录授权响应尚未返回")
        await cloud.pauseNextAccess(firstBookmark, failure: .needsSelection, whenPaused: { paused.fulfill() })
        let first = Task { await shelf.connect(bookmark: firstBookmark) }
        await fulfillment(of: [paused], timeout: 5)
        let confirmed = await shelf.connect(bookmark: laterBookmark)
        XCTAssertEqual(shelf.connectionState, .connected)
        await cloud.resumeAccess()
        let ignored = await first.value
        XCTAssertNil(ignored)
        XCTAssertEqual(shelf.connectionState, .connected)
        XCTAssertEqual(confirmed, laterBookmark)
    }

    func testDuplicateVersionIdentitiesCannotBePublishedAsTwoReadableEntries() async throws {
        try publishedLibrary()
        let file = remote.appendingPathComponent("catalog.json")
        var catalog = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: file)) as? [String: Any])
        var companies = try XCTUnwrap(catalog["companies"] as? [[String: Any]])
        var versions = try XCTUnwrap(companies[0]["versions"] as? [[String: Any]])
        versions.append(versions[0])
        companies[0]["versions"] = versions
        catalog["companies"] = companies
        try JSONSerialization.data(withJSONObject: catalog).write(to: file)
        let shelf = StudyShelf(localRoot: local, deviceID: "iphone", cloud: DirectoryCloudFolder(root: remote))
        _ = await shelf.connect(bookmark: Data())
        await shelf.refresh()
        XCTAssertTrue(shelf.entries.isEmpty)
        guard case .unavailable = shelf.connectionState else { return XCTFail("同一版本只能有一个明确条目") }
    }

    func testCatalogCompanyMetadataMustBelongToTheValidatedPublication() async throws {
        try publishedLibrary()
        let file = remote.appendingPathComponent("catalog.json")
        let original = try Data(contentsOf: file)
        for field in ["name", "code"] {
            var catalog = try XCTUnwrap(JSONSerialization.jsonObject(with: original) as? [String: Any])
            var companies = try XCTUnwrap(catalog["companies"] as? [[String: Any]])
            var company = try XCTUnwrap(companies[0]["company"] as? [String: Any])
            company[field] = field == "name" ? "另一家公司" : "123456"
            companies[0]["company"] = company
            catalog["companies"] = companies
            try JSONSerialization.data(withJSONObject: catalog).write(to: file)
            let shelf = StudyShelf(localRoot: local.appendingPathComponent(field), deviceID: "iphone", cloud: DirectoryCloudFolder(root: remote))
            _ = await shelf.connect(bookmark: Data())
            await shelf.refresh()
            let entry = try XCTUnwrap(shelf.entries.first?.versions.first)
            if case .failed = entry.state {} else { XCTFail("目录公司" + field + "与正式研究不一致，不可就绪") }
            if case .unavailable = await shelf.readVersion(entry.id) {} else { XCTFail("错标公司的研究不可被当成可读版本交付") }
        }
    }

    func testLateCatalogSuccessCannotHideRevokedPermissionReportedByRecordExchange() async throws {
        try publishedLibrary()
        let cloud = GatedCloudFolder(root: remote)
        let shelf = StudyShelf(localRoot: local, deviceID: "iphone", cloud: cloud)
        _ = await shelf.connect(bookmark: Data())
        let catalogPaused = expectation(description: "目录响应迟到")
        let recordsPaused = expectation(description: "记录目录检查等待")
        await cloud.pauseNextCopy("catalog.json", afterCopy: true, whenPaused: { catalogPaused.fulfill() })
        await cloud.pauseRecordListing { recordsPaused.fulfill() }
        let refresh = Task { await shelf.refresh() }
        await fulfillment(of: [catalogPaused, recordsPaused], timeout: 5)
        let revoked = expectation(description: "记录检查报告撤权")
        var finished = false
        @MainActor func observeRevocation() {
            guard !finished else { return }
            withObservationTracking {
                if case .needsSelection = shelf.connectionState { finished = true; revoked.fulfill() }
            } onChange: { Task { @MainActor in observeRevocation() } }
        }
        observeRevocation()
        await cloud.resumeRecordListing(failure: .needsSelection)
        await fulfillment(of: [revoked], timeout: 5)
        finished = true
        await cloud.resume()
        await refresh.value
        guard case .needsSelection = shelf.connectionState else { return XCTFail("晚到目录成功不能掩盖已确认撤权") }
    }

    func testAConflictingKnownPublicationCannotInvalidateTheAlreadyPreparedOriginal() async throws {
        try publishedLibrary()
        let shelf = StudyShelf(localRoot: local, deviceID: "iphone", cloud: DirectoryCloudFolder(root: remote))
        _ = await shelf.connect(bookmark: Data())
        await shelf.refresh()
        let id = try XCTUnwrap(shelf.entries.first?.currentVersionID)
        let file = remote.appendingPathComponent("catalog.json")
        var catalog = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: file)) as? [String: Any])
        var companies = try XCTUnwrap(catalog["companies"] as? [[String: Any]])
        var versions = try XCTUnwrap(companies[0]["versions"] as? [[String: Any]])
        versions[0]["resourceManifestSHA256"] = String(repeating: "0", count: 64)
        companies[0]["versions"] = versions; catalog["companies"] = companies
        try JSONSerialization.data(withJSONObject: catalog).write(to: file)
        await shelf.refresh()
        XCTAssertEqual(shelf.entries.first?.versions.first?.state, .ready)
        guard case .unavailable = shelf.connectionState else { return XCTFail("同一发布版本被改写必须拒绝") }
        guard case .opened(let original) = await shelf.readVersion(id) else { return XCTFail("原有效版本应保持可读") }
        XCTAssertEqual(original.study.identity.snapshotManifestSHA256, "8b903db1a5461c5c1b3e835491d3d3eab00c001dcf450314f3c5514e1e34589f")
        let restarted = StudyShelf(localRoot: local, deviceID: "iphone", cloud: DirectoryCloudFolder(root: remote))
        _ = await restarted.connect(bookmark: Data())
        await restarted.refresh()
        XCTAssertEqual(restarted.entries.first?.versions.first?.state, .ready)
        guard case .opened = await restarted.readVersion(id) else { return XCTFail("重启仍保留已知版本定义") }
    }

    func testBundledFormalStudyDoesNotApproveFalseCatalogCoverageDates() async throws {
        let package = try publishedLibrary()
        let bundled = try ReadableStudy(root: package)
        let shelf = StudyShelf(localRoot: local, deviceID: "iphone", cloud: DirectoryCloudFolder(root: remote), bundledStudy: bundled)
        let file = remote.appendingPathComponent("catalog.json")
        var catalog = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: file)) as? [String: Any])
        var companies = try XCTUnwrap(catalog["companies"] as? [[String: Any]])
        var versions = try XCTUnwrap(companies[0]["versions"] as? [[String: Any]])
        versions[0]["financialPeriodEnd"] = "2030-12-31"
        versions[0]["researchAsOf"] = "2030-12-31"
        companies[0]["versions"] = versions; catalog["companies"] = companies
        try JSONSerialization.data(withJSONObject: catalog).write(to: file)
        _ = await shelf.connect(bookmark: Data())
        await shelf.refresh()
        guard case .unavailable = shelf.connectionState else { return XCTFail("随附包不能为错误研究期间背书") }
        XCTAssertEqual(shelf.entries.first?.versions.first?.financialPeriodEnd, "2026-09-30")
        XCTAssertEqual(shelf.entries.first?.versions.first?.state, .ready)
        guard let id = shelf.entries.first?.currentVersionID, case .opened = await shelf.readVersion(id) else {
            return XCTFail("错误目录不能使已验证随附原版变得不可读")
        }
    }

    func testCatalogRequiresTheCanonicalPublicationIdentityAndAnExistingCurrentVersion() async throws {
        let originalPackage = try publishedLibrary()
        let file = remote.appendingPathComponent("catalog.json")
        let originalData = try Data(contentsOf: file)
        let alias = "human-label"
        let aliasPackage = originalPackage.deletingLastPathComponent().appendingPathComponent(alias)
        try FileManager.default.copyItem(at: originalPackage, to: aliasPackage)
        for invalidCase in ["alias", "missing-current"] {
            var catalog = try XCTUnwrap(JSONSerialization.jsonObject(with: originalData) as? [String: Any])
            var companies = try XCTUnwrap(catalog["companies"] as? [[String: Any]])
            if invalidCase == "alias" {
                var versions = try XCTUnwrap(companies[0]["versions"] as? [[String: Any]])
                versions[0]["versionId"] = alias
                versions[0]["packagePath"] = "packages/cn-sz-000651/" + alias
                companies[0]["versions"] = versions
                companies[0]["currentVersionId"] = alias
            } else { companies[0]["currentVersionId"] = "does-not-exist" }
            catalog["companies"] = companies
            try JSONSerialization.data(withJSONObject: catalog).write(to: file)
            let shelf = StudyShelf(localRoot: local.appendingPathComponent(invalidCase), deviceID: "iphone", cloud: DirectoryCloudFolder(root: remote))
            _ = await shelf.connect(bookmark: Data())
            await shelf.refresh()
            XCTAssertTrue(shelf.entries.isEmpty, invalidCase)
            if case .unavailable = shelf.connectionState {} else { XCTFail("目录不可接受无法继续的版本身份：" + invalidCase) }
        }
    }

    func testAnUnverifiedBadCatalogDefinitionCanBeCorrectedWithoutPoisoningItsVersionForever() async throws {
        try publishedLibrary()
        let file = remote.appendingPathComponent("catalog.json")
        let correct = try Data(contentsOf: file)
        var catalog = try XCTUnwrap(JSONSerialization.jsonObject(with: correct) as? [String: Any])
        var companies = try XCTUnwrap(catalog["companies"] as? [[String: Any]])
        var versions = try XCTUnwrap(companies[0]["versions"] as? [[String: Any]])
        versions[0]["financialPeriodEnd"] = "2030-12-31"
        companies[0]["versions"] = versions; catalog["companies"] = companies
        try JSONSerialization.data(withJSONObject: catalog).write(to: file)
        let shelf = StudyShelf(localRoot: local, deviceID: "iphone", cloud: DirectoryCloudFolder(root: remote))
        _ = await shelf.connect(bookmark: Data())
        await shelf.refresh()
        guard case .failed = shelf.entries.first?.versions.first?.state else { return XCTFail("错误声明未通过完整验证") }
        try correct.write(to: file)
        await shelf.refresh()
        XCTAssertEqual(shelf.entries.first?.versions.first?.state, .ready)
    }

    func testFirstCloudPublicationMayOmitTheBundledLogoWithoutChangingItsFormalVersion() async throws {
        let package = try publishedLibrary()
        let bundleRoot = root.appendingPathComponent("immutable-bundle")
        try FileManager.default.copyItem(at: package, to: bundleRoot)
        let bundle = try ReadableStudy(root: bundleRoot)
        let manifestFile = package.appendingPathComponent("resource-manifest.json")
        var manifest = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: manifestFile)) as? [String: Any])
        let datasets = try XCTUnwrap(manifest["datasets"] as? [[String: Any]])
        manifest["datasets"] = datasets.filter { $0["file"] as? String != "gree-logo.png" }
        let logo = package.appendingPathComponent("gree-logo.png")
        if FileManager.default.fileExists(atPath: logo.path) { try FileManager.default.removeItem(at: logo) }
        let bytes = try JSONSerialization.data(withJSONObject: manifest, options: [.sortedKeys])
        try bytes.write(to: manifestFile)
        let catalogFile = remote.appendingPathComponent("catalog.json")
        var catalog = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: catalogFile)) as? [String: Any])
        var companies = try XCTUnwrap(catalog["companies"] as? [[String: Any]])
        var versions = try XCTUnwrap(companies[0]["versions"] as? [[String: Any]])
        versions[0]["resourceManifestSHA256"] = ReadingLibrary.sha256(bytes)
        companies[0]["versions"] = versions; catalog["companies"] = companies
        try JSONSerialization.data(withJSONObject: catalog).write(to: catalogFile)
        let shelf = StudyShelf(localRoot: local, deviceID: "iphone", cloud: DirectoryCloudFolder(root: remote), bundledStudy: bundle)
        _ = await shelf.connect(bookmark: Data())
        await shelf.refresh()
        XCTAssertEqual(shelf.entries.first?.versions.count, 1)
        XCTAssertEqual(shelf.entries.first?.versions.first?.state, .ready)
        let id = try XCTUnwrap(shelf.entries.first?.currentVersionID)
        guard case .opened(let reading) = await shelf.readVersion(id) else { return XCTFail("合法派生差异不应阻断完整正式研究") }
        XCTAssertEqual(reading.study.identity, bundle.identity)
        let restarted = StudyShelf(localRoot: local, deviceID: "iphone", cloud: DirectoryCloudFolder(root: remote), bundledStudy: bundle)
        _ = await restarted.connect(bookmark: Data())
        await restarted.refresh()
        XCTAssertEqual(restarted.entries.first?.versions.first?.state, .ready)
    }

    private func publishNextVersion(revision: Int = 5) throws -> (id: ShelfVersionID, path: String) {
        let source = remote.appendingPathComponent("packages/cn-sz-000651/" + versionID)
        let candidate = root.appendingPathComponent("next-candidate")
        try FileManager.default.copyItem(at: source, to: candidate)
        try FileManager.default.removeItem(at: candidate.appendingPathComponent("reading.json"))
        func object(_ file: String) throws -> [String: Any] {
            try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: candidate.appendingPathComponent(file))) as? [String: Any])
        }
        func write(_ object: [String: Any], _ file: String) throws {
            try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys]).write(to: candidate.appendingPathComponent(file))
        }
        let snapshotID = "fixture-publication-v" + String(revision)
        var research = try object("research.json")
        var report = try XCTUnwrap(research["report"] as? [String: Any])
        report["revision"] = revision
        report["summary"] = "第二版研究，有自己的完整报告。"
        research["report"] = report
        var publication = try XCTUnwrap(research["publication"] as? [String: Any])
        publication["snapshot_id"] = snapshotID
        research["publication"] = publication
        try write(research, "research.json")
        var snapshot = try object("snapshot.json")
        snapshot["snapshot_id"] = snapshotID
        var files = try XCTUnwrap(snapshot["files"] as? [String: String])
        files.removeValue(forKey: "reading.json")
        files["research.json"] = ReadingLibrary.sha256(try Data(contentsOf: candidate.appendingPathComponent("research.json")))
        snapshot["files"] = files
        try write(snapshot, "snapshot.json")
        let snapshotHash = ReadingLibrary.sha256(try Data(contentsOf: candidate.appendingPathComponent("snapshot.json")))
        var manifest = try object("resource-manifest.json")
        manifest["snapshotId"] = snapshotID
        manifest["snapshotManifestSHA256"] = snapshotHash
        var datasets = try XCTUnwrap(manifest["datasets"] as? [[String: Any]]).filter { $0["file"] as? String != "reading.json" }
        for index in datasets.indices {
            let bytes = try Data(contentsOf: candidate.appendingPathComponent(try XCTUnwrap(datasets[index]["file"] as? String)))
            datasets[index]["sha256"] = ReadingLibrary.sha256(bytes)
            datasets[index]["bytes"] = bytes.count
        }
        manifest["datasets"] = datasets
        try write(manifest, "resource-manifest.json")
        let nextID = snapshotID + "--" + snapshotHash
        let nextPath = "packages/cn-sz-000651/" + nextID
        try FileManager.default.moveItem(at: candidate, to: remote.appendingPathComponent(nextPath))
        let catalogFile = remote.appendingPathComponent("catalog.json")
        var catalog = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: catalogFile)) as? [String: Any])
        var companies = try XCTUnwrap(catalog["companies"] as? [[String: Any]])
        var versions = try XCTUnwrap(companies[0]["versions"] as? [[String: Any]])
        var next = versions[0]
        next["versionId"] = nextID; next["snapshotId"] = snapshotID; next["snapshotManifestSHA256"] = snapshotHash
        next["resourceManifestSHA256"] = ReadingLibrary.sha256(try Data(contentsOf: remote.appendingPathComponent(nextPath + "/resource-manifest.json")))
        next["packagePath"] = nextPath; next["reportRevision"] = revision
        versions.append(next)
        companies[0]["versions"] = versions; companies[0]["currentVersionId"] = nextID
        catalog["companies"] = companies
        try JSONSerialization.data(withJSONObject: catalog).write(to: catalogFile)
        return (ShelfVersionID(companyID: "cn-sz-000651", versionID: nextID), nextPath)
    }

    @discardableResult private func publishedLibrary() throws -> URL {
        let source = ProcessInfo.processInfo.environment["COMPANYLENS_STUDY_FIXTURE"].map(URL.init(fileURLWithPath:)) ?? URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("Study")
        let path = "packages/cn-sz-000651/" + versionID
        let destination = remote.appendingPathComponent(path)
        try FileManager.default.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
        try FileManager.default.copyItem(at: source, to: destination)
        let manifest = try Data(contentsOf: destination.appendingPathComponent("resource-manifest.json"))
        let catalog: [String: Any] = ["schemaVersion": 1, "companies": [[
            "company": ["id": "cn-sz-000651", "name": "格力电器", "code": "000651", "exchange": "SZ"],
            "currentVersionId": versionID,
            "versions": [["versionId": versionID, "snapshotId": "cn-sz-000651-2020-2026-r4-338655191847af3d",
                "snapshotManifestSHA256": "8b903db1a5461c5c1b3e835491d3d3eab00c001dcf450314f3c5514e1e34589f",
                "resourceManifestSHA256": ReadingLibrary.sha256(manifest), "packagePath": path,
                "reportId": "cn-sz-000651-2020-2026", "reportRevision": 4,
                "financialPeriodStart": "2020-01-01", "financialPeriodEnd": "2026-09-30", "researchAsOf": "2026-11-09"]]
        ]]]
        try JSONSerialization.data(withJSONObject: catalog).write(to: remote.appendingPathComponent("catalog.json"))
        return destination
    }
}

/// A real filesystem adapter. Tests substitute only the external cloud directory.
private struct DirectoryCloudFolder: CloudFolder {
    let root: URL
    func restoreAccess(bookmark: Data) async throws -> CloudFolderAccess { CloudFolderAccess() }
    func copyFile(relativePath: String, to localURL: URL) async throws {
        let source = root.appendingPathComponent(relativePath).standardizedFileURL.resolvingSymlinksInPath()
        guard source.path.hasPrefix(root.path + "/") else { throw CloudFolderError.invalidPath(relativePath) }
        guard FileManager.default.fileExists(atPath: source.path) else { throw CloudFolderError.missingFile(relativePath) }
        try FileManager.default.createDirectory(at: localURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try FileManager.default.copyItem(at: source, to: localURL)
    }
    func listRecordFiles() async throws -> [String] { [] }
    func replaceOwnRecord(deviceID: String, contents: Data) async throws {}
}

private actor GatedCloudFolder: CloudFolder {
    let directory: DirectoryCloudFolder
    private var nextPath: String?
    private var whenPaused: (() -> Void)?
    private var pauseAfterCopy = false
    private var revoked = false
    private var recordListingPaused: (() -> Void)?
    private var recordListingWaiting: CheckedContinuation<Void, Never>?
    private var recordListingFailure: CloudFolderError?
    func pauseRecordListing(_ action: @escaping () -> Void) { recordListingPaused = action }
    func resumeRecordListing(failure: CloudFolderError?) {
        recordListingFailure = failure
        recordListingWaiting?.resume(); recordListingWaiting = nil
    }
    private var accessBookmark: Data?
    private var accessFailure: CloudFolderError?
    private var accessPaused: (() -> Void)?
    private var accessWaiting: CheckedContinuation<Void, Never>?
    func pauseNextAccess(_ bookmark: Data, failure: CloudFolderError?, whenPaused: @escaping () -> Void) {
        accessBookmark = bookmark; accessFailure = failure; accessPaused = whenPaused
    }
    func resumeAccess() { accessWaiting?.resume(); accessWaiting = nil }
    func revokePermission() { revoked = true }
    private var waiting: CheckedContinuation<Void, Never>?
    init(root: URL) { directory = DirectoryCloudFolder(root: root) }
    func pauseNextCopy(_ path: String, afterCopy: Bool = false, whenPaused: @escaping () -> Void) {
        nextPath = path; self.whenPaused = whenPaused; pauseAfterCopy = afterCopy
    }
    func resume() { waiting?.resume(); waiting = nil }
    func restoreAccess(bookmark: Data) async throws -> CloudFolderAccess {
        if accessBookmark == bookmark {
            accessBookmark = nil
            let failure = accessFailure
            await withCheckedContinuation { continuation in
                accessWaiting = continuation; accessPaused?(); accessPaused = nil
            }
            if let failure { throw failure }
        }
        if revoked { throw CloudFolderError.needsSelection }
        return try await directory.restoreAccess(bookmark: bookmark)
    }
    func copyFile(relativePath: String, to localURL: URL) async throws {
        if revoked { throw CloudFolderError.needsSelection }
        let shouldPause = nextPath == relativePath
        let copied = shouldPause && pauseAfterCopy
        if copied { try await directory.copyFile(relativePath: relativePath, to: localURL) }
        if shouldPause {
            nextPath = nil
            await withCheckedContinuation { continuation in
                waiting = continuation
                whenPaused?(); whenPaused = nil
            }
        }
        if !copied { try await directory.copyFile(relativePath: relativePath, to: localURL) }
    }
    func listRecordFiles() async throws -> [String] {
        if let action = recordListingPaused {
            recordListingPaused = nil
            await withCheckedContinuation { continuation in recordListingWaiting = continuation; action() }
        }
        if let failure = recordListingFailure { throw failure }
        return []
    }
    func replaceOwnRecord(deviceID: String, contents: Data) async throws {}
}
