import Foundation
import XCTest
@testable import ResearchCore

@MainActor
final class StudyShelfRecordTests: XCTestCase {
    private var root: URL!
    private var study: ReadableStudy!
    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("shelf-record-tests-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let fixture = ProcessInfo.processInfo.environment["COMPANYLENS_STUDY_FIXTURE"].map(URL.init(fileURLWithPath:)) ?? URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("Study")
        study = try ReadableStudy(root: fixture)
    }
    override func tearDownWithError() throws { try FileManager.default.removeItem(at: root) }

    func testAcceptedActualReadingImmediatelyOffersItsOriginalVersionAndOccurrenceTime() async throws {
        let shelf = makeShelf()
        let occurred = Date(timeIntervalSince1970: 1_700_000_001)
        shelf.acceptCheckpoint(ReadingCheckpoint(identity: study.identity, updates: [
            ReadingSlotCheckpoint(slotKey: ReadingCheckpoint.mainSlotKey, payload: Data("third-section".utf8), occurredAt: occurred)
        ]))
        let continuation = try XCTUnwrap(shelf.recommendedContinuation)
        XCTAssertEqual(continuation.identity, study.identity)
        XCTAssertEqual(continuation.occurredAt, occurred)
        XCTAssertEqual(continuation.deviceID, "iphone")
        XCTAssertEqual(continuation.sequence, 1)
        await shelf.retryRecords()
    }

    func testActualReadingSurvivesARealLocalSaveAndRestartWithoutRestamping() async throws {
        let shelf = makeShelf()
        let occurred = Date(timeIntervalSince1970: 1_700_000_002)
        shelf.acceptCheckpoint(ReadingCheckpoint(identity: study.identity, updates: [
            ReadingSlotCheckpoint(slotKey: ReadingCheckpoint.mainSlotKey, payload: Data("eighth-section".utf8), occurredAt: occurred)
        ]))
        await shelf.retryRecords()
        XCTAssertEqual(shelf.recordState.local, .saved)
        let restarted = makeShelf()
        let continuation = try XCTUnwrap(restarted.recommendedContinuation)
        XCTAssertEqual(continuation.occurredAt, occurred)
        XCTAssertEqual(continuation.sequence, 1)
        XCTAssertEqual(continuation.identity, study.identity)
    }

    func testCompanyEntryOffersTheSameExplicitContinuationAsTheHomeRecommendation() async throws {
        let shelf = makeShelf()
        let occurred = Date(timeIntervalSince1970: 1_700_000_003)
        shelf.acceptCheckpoint(ReadingCheckpoint(identity: study.identity, updates: [
            ReadingSlotCheckpoint(slotKey: ReadingCheckpoint.mainSlotKey, payload: Data("sixth-section".utf8), occurredAt: occurred)
        ]))
        XCTAssertEqual(shelf.entries.first?.continuations.first, shelf.recommendedContinuation)
        XCTAssertEqual(shelf.entries.first?.continuations.count, 1)
        await shelf.retryRecords()
    }

    func testLocalWriteFailureRetainsAcceptedPositionAndRetryDoesNotChangeItsTimeOrSequence() async throws {
        let local = root.appendingPathComponent("local")
        try FileManager.default.createDirectory(at: local, withIntermediateDirectories: true)
        let obstacle = local.appendingPathComponent("personal")
        try Data("not a directory".utf8).write(to: obstacle)
        let shelf = makeShelf()
        let occurred = Date(timeIntervalSince1970: 1_700_000_004)
        shelf.acceptCheckpoint(ReadingCheckpoint(identity: study.identity, updates: [
            ReadingSlotCheckpoint(slotKey: ReadingCheckpoint.mainSlotKey, payload: Data("reread-third-section".utf8), occurredAt: occurred)
        ]))
        await shelf.retryRecords()
        guard case .unsaved = shelf.recordState.local else { return XCTFail("真实写入失败不能显示已保存") }
        XCTAssertEqual(shelf.recommendedContinuation?.occurredAt, occurred)
        try FileManager.default.removeItem(at: obstacle)
        await shelf.retryRecords()
        XCTAssertEqual(shelf.recordState.local, .saved)
        let restarted = makeShelf()
        XCTAssertEqual(restarted.recommendedContinuation?.sequence, 1)
        XCTAssertEqual(restarted.recommendedContinuation?.occurredAt, occurred)
    }

    func testRapidAcceptedReadingsAndDelayedDuplicatesPersistTheLatestActualReading() async throws {
        let shelf = makeShelf()
        let first = ReadingCheckpoint(identity: study.identity, updates: [
            ReadingSlotCheckpoint(slotKey: ReadingCheckpoint.mainSlotKey, payload: Data("eighth-section".utf8), occurredAt: Date(timeIntervalSince1970: 1_700_000_000))
        ])
        shelf.acceptCheckpoint(first)
        for number in 1...19 {
            shelf.acceptCheckpoint(ReadingCheckpoint(identity: study.identity, updates: [
                ReadingSlotCheckpoint(slotKey: ReadingCheckpoint.mainSlotKey, payload: Data("third-section".utf8), occurredAt: Date(timeIntervalSince1970: 1_700_000_000 + Double(number)))
            ]))
            await Task.yield()
        }
        shelf.acceptCheckpoint(first)
        await shelf.retryRecords()
        let restarted = makeShelf()
        XCTAssertEqual(restarted.recommendedContinuation?.sequence, 20)
        XCTAssertEqual(restarted.recommendedContinuation?.occurredAt, Date(timeIntervalSince1970: 1_700_000_019))
    }

    func testUpdatingOnlyAPDFSlotDoesNotRestampTheUntouchedMainPosition() async throws {
        let shelf = makeShelf()
        let mainTime = Date(timeIntervalSince1970: 1_700_000_005)
        shelf.acceptCheckpoint(ReadingCheckpoint(identity: study.identity, updates: [
            ReadingSlotCheckpoint(slotKey: ReadingCheckpoint.mainSlotKey, payload: Data("main".utf8), occurredAt: mainTime)
        ]))
        shelf.acceptCheckpoint(ReadingCheckpoint(identity: study.identity, updates: [
            ReadingSlotCheckpoint(slotKey: "pdf:original", payload: Data("page35".utf8), occurredAt: Date(timeIntervalSince1970: 1_700_000_099))
        ]))
        await shelf.retryRecords()
        let restarted = makeShelf()
        XCTAssertEqual(restarted.recommendedContinuation?.occurredAt, mainTime)
        XCTAssertEqual(restarted.recommendedContinuation?.sequence, 1)
    }

    func testCloudWriteFailureIsIndependentOfLocalSaveAndCanRetryWithoutRestamping() async throws {
        let cloudPath = root.appendingPathComponent("cloud")
        try Data("provider temporarily unavailable".utf8).write(to: cloudPath)
        let shelf = makeShelf()
        let occurred = Date(timeIntervalSince1970: 1_700_000_006)
        shelf.acceptCheckpoint(ReadingCheckpoint(identity: study.identity, updates: [
            ReadingSlotCheckpoint(slotKey: ReadingCheckpoint.mainSlotKey, payload: Data("third-section".utf8), occurredAt: occurred)
        ]))
        _ = await shelf.connect(bookmark: Data())
        await shelf.retryRecords()
        XCTAssertEqual(shelf.recordState.local, .saved)
        guard case .failed = shelf.recordState.cloud else { return XCTFail("云写入失败应独立可见") }
        XCTAssertEqual(shelf.recommendedContinuation?.occurredAt, occurred)
        try FileManager.default.removeItem(at: cloudPath)
        await shelf.retryRecords()
        XCTAssertEqual(shelf.recordState.local, .saved)
        XCTAssertEqual(shelf.recordState.cloud, .accepted)
        XCTAssertEqual(shelf.recommendedContinuation?.occurredAt, occurred)
        XCTAssertEqual(shelf.recommendedContinuation?.sequence, 1)
    }

    func testAnotherDeviceReceivesActualReadingEvenWhenThePublicationCatalogIsUnavailable() async throws {
        let iphone = makeShelf()
        let occurred = Date(timeIntervalSince1970: 1_700_000_007)
        iphone.acceptCheckpoint(ReadingCheckpoint(identity: study.identity, updates: [
            ReadingSlotCheckpoint(slotKey: ReadingCheckpoint.mainSlotKey, payload: Data("third-section".utf8), occurredAt: occurred)
        ]))
        _ = await iphone.connect(bookmark: Data())
        await iphone.retryRecords()
        let ipad = makeShelf(deviceID: "ipad")
        _ = await ipad.connect(bookmark: Data())
        await ipad.refresh()
        let received = try XCTUnwrap(ipad.recommendedContinuation)
        XCTAssertEqual(received.deviceID, "iphone")
        XCTAssertFalse(received.isLocalDevice)
        XCTAssertEqual(received.occurredAt, occurred)
        XCTAssertEqual(received.identity, study.identity)
        XCTAssertEqual(ipad.entries.first?.versions.first?.state, .ready)
    }

    func testReceivedDeviceCandidatesSurviveAnOfflineRestartAndAnEmptyCloudListing() async throws {
        let iphone = makeShelf()
        let occurred = Date(timeIntervalSince1970: 1_700_000_008)
        iphone.acceptCheckpoint(ReadingCheckpoint(identity: study.identity, updates: [
            ReadingSlotCheckpoint(slotKey: ReadingCheckpoint.mainSlotKey, payload: Data("third-section".utf8), occurredAt: occurred)
        ]))
        _ = await iphone.connect(bookmark: Data())
        await iphone.retryRecords()
        let ipad = makeShelf(deviceID: "ipad")
        _ = await ipad.connect(bookmark: Data())
        await ipad.refresh()
        try FileManager.default.removeItem(at: root.appendingPathComponent("cloud/records"))
        await ipad.refresh()
        XCTAssertEqual(ipad.recommendedContinuation?.deviceID, "iphone")
        let restarted = makeShelf(deviceID: "ipad")
        XCTAssertEqual(restarted.recommendedContinuation?.deviceID, "iphone")
        XCTAssertEqual(restarted.recommendedContinuation?.occurredAt, occurred)
        XCTAssertEqual(restarted.connectionState, .disconnected)
    }

    func testContinueReadingRestoresTheOriginalVersionAndActualMainLocationAfterRestart() async throws {
        var reader = StudyReader(study: study, clock: { Date(timeIntervalSince1970: 1_700_000_009) })
        guard case .overview(let overview) = reader.primaryPage else { return XCTFail("正式样本有研究全貌") }
        let target = try XCTUnwrap(overview.entries.first(where: { $0.sceneID == "cash-recent" }))
        reader.follow(target.link)
        guard case .diagram(let shown) = reader.primaryPage else { return XCTFail("应进入所选图解") }
        reader.reportVisiblePosition(shown.observation, position: ReadingPosition(anchorID: "heading"), cause: .userNavigation)
        let shelf = makeShelf()
        shelf.acceptCheckpoint(try XCTUnwrap(reader.checkpoint))
        await shelf.retryRecords()
        let restarted = makeShelf()
        let choice = try XCTUnwrap(restarted.recommendedContinuation)
        guard case .opened(let opened) = await restarted.continueReading(choice) else { return XCTFail("应能继续原版实际阅读") }
        XCTAssertEqual(opened.study.identity, study.identity)
        guard case .diagram(let restored) = opened.reader.primaryPage else { return XCTFail("启动应回到主阅读") }
        XCTAssertEqual(restored.sceneID, "cash-recent")
        XCTAssertEqual(restored.restorePosition?.anchorID, "heading")
        XCTAssertNil(opened.reader.checkpoint)
    }

    func testAnExistingValidLegacyBookmarkIsReadWithoutInventingAnActualReadingTime() async throws {
        var original = StudyReader(study: study)
        guard case .overview(let overview) = original.primaryPage else { return XCTFail("应有全貌") }
        original.follow(try XCTUnwrap(overview.entries.first(where: { $0.sceneID == "profit-change" })).link)
        let bookmark = try XCTUnwrap(original.localBookmark)
        let shelf = StudyShelf(localRoot: root.appendingPathComponent("local"), deviceID: "iphone",
            cloud: RecordDirectory(root: root.appendingPathComponent("cloud")), bundledStudy: study,
            legacyBookmarks: [study.identity: bookmark])
        let version = try XCTUnwrap(shelf.entries.first?.currentVersionID)
        guard case .opened(let restored) = await shelf.readVersion(version) else { return XCTFail("应能迁移有效书签") }
        guard case .diagram(let page) = restored.reader.primaryPage else { return XCTFail("应回到旧主阅读") }
        XCTAssertEqual(page.sceneID, "profit-change")
        XCTAssertNil(shelf.recommendedContinuation)
        XCTAssertNil(restored.reader.checkpoint)
    }

    func testLatestActualRereadingWinsWhileAnotherDeviceRemainsAnExplicitChoice() async throws {
        let iphone = makeShelf()
        iphone.acceptCheckpoint(try actualCheckpoint(scene: "shareholder-returns", time: 1_700_000_010))
        _ = await iphone.connect(bookmark: Data())
        await iphone.retryRecords()
        guard case .opened(let active) = await iphone.continueReading() else { return XCTFail("原设备应可继续") }
        let ipad = makeShelf(deviceID: "ipad")
        ipad.acceptCheckpoint(try actualCheckpoint(scene: "profit-change", time: 1_700_000_020))
        _ = await ipad.connect(bookmark: Data())
        await ipad.retryRecords()
        await iphone.refresh()
        XCTAssertEqual(iphone.entries.first?.continuations.count, 2)
        XCTAssertEqual(iphone.recommendedContinuation?.deviceID, "ipad")
        guard case .diagram(let unchanged) = active.reader.primaryPage else { return XCTFail("活动阅读应仍在原处") }
        XCTAssertEqual(unchanged.sceneID, "shareholder-returns")
        let alternate = try XCTUnwrap(iphone.entries.first?.continuations.first(where: { $0.deviceID == "iphone" }))
        guard case .opened(let explicit) = await iphone.continueReading(alternate),
              case .diagram(let oldPlace) = explicit.reader.primaryPage else { return XCTFail("明确选择应优先") }
        XCTAssertEqual(oldPlace.sceneID, "shareholder-returns")
        guard case .opened(let recommended) = await iphone.continueReading(),
              case .diagram(let reread) = recommended.reader.primaryPage else { return XCTFail("应恢复最近回读位置") }
        XCTAssertEqual(reread.sceneID, "profit-change")
    }

    func testADeviceRecordWithImpossibleSequenceIsRejectedWithoutBlockingReadyResearch() async throws {
        let iphone = makeShelf()
        iphone.acceptCheckpoint(try actualCheckpoint(scene: "cash-recent", time: 1_700_000_030))
        _ = await iphone.connect(bookmark: Data())
        await iphone.retryRecords()
        let file = root.appendingPathComponent("cloud/records/iphone.json")
        var invalid = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: file)) as? [String: Any])
        invalid["sequence"] = 0
        try JSONSerialization.data(withJSONObject: invalid).write(to: file)
        let ipad = makeShelf(deviceID: "ipad")
        _ = await ipad.connect(bookmark: Data())
        await ipad.refresh()
        XCTAssertNil(ipad.recommendedContinuation)
        guard case .failed = ipad.recordState.cloud else { return XCTFail("损坏的设备记录应报告格式失败") }
        XCTAssertEqual(ipad.entries.first?.versions.first?.state, .ready)
    }

    func testOldRecordDownloadCannotEnterANewerFolderAssociation() async throws {
        let iphone = makeShelf()
        iphone.acceptCheckpoint(try actualCheckpoint(scene: "profit-change", time: 1_700_000_040))
        _ = await iphone.connect(bookmark: Data("A".utf8))
        await iphone.retryRecords()
        let delayed = DelayedRecordFolder(root: root.appendingPathComponent("cloud"))
        let ipad = StudyShelf(localRoot: root.appendingPathComponent("ipad"), deviceID: "ipad", cloud: delayed, bundledStudy: study)
        _ = await ipad.connect(bookmark: Data("A".utf8))
        let paused = expectation(description: "旧目录的记录已取得字节但响应迟到")
        await delayed.pauseRecord { paused.fulfill() }
        let oldRefresh = Task { await ipad.refresh() }
        await fulfillment(of: [paused], timeout: 5)
        try FileManager.default.removeItem(at: root.appendingPathComponent("cloud/records"))
        _ = await ipad.connect(bookmark: Data("B".utf8))
        await delayed.resume()
        await oldRefresh.value
        XCTAssertEqual(ipad.connectionState, .connected)
        XCTAssertNil(ipad.recommendedContinuation)
    }

    func testAnOldRecordWriteErrorCannotRevokeANewerConfirmedFolder() async throws {
        let delayed = DelayedRecordFolder(root: root.appendingPathComponent("cloud"))
        let shelf = StudyShelf(localRoot: root.appendingPathComponent("local"), deviceID: "iphone", cloud: delayed, bundledStudy: study)
        _ = await shelf.connect(bookmark: Data("A".utf8))
        let paused = expectation(description: "旧目录中的记录写入响应迟到")
        await delayed.pauseWrite(failure: .needsSelection) { paused.fulfill() }
        shelf.acceptCheckpoint(try actualCheckpoint(scene: "cash-recent", time: 1_700_000_050))
        let oldSave = Task { await shelf.retryRecords() }
        await fulfillment(of: [paused], timeout: 5)
        _ = await shelf.connect(bookmark: Data("B".utf8))
        await delayed.resumeWrite()
        await oldSave.value
        XCTAssertEqual(shelf.connectionState, .connected)
        await shelf.retryRecords()
        XCTAssertEqual(shelf.recordState.cloud, .accepted)
        XCTAssertEqual(shelf.recommendedContinuation?.occurredAt, Date(timeIntervalSince1970: 1_700_000_050))
    }

    func testOnlyTheOriginalDeviceRestoresItsLocalPixelOffset() async throws {
        let iphone = makeShelf()
        iphone.acceptCheckpoint(try actualCheckpoint(scene: "profit-change", time: 1_700_000_060, offset: 42))
        await iphone.retryRecords()
        guard case .opened(let local) = await iphone.continueReading(),
              case .diagram(let localPage) = local.reader.primaryPage else { return XCTFail("本机应可继续") }
        XCTAssertEqual(localPage.restorePosition?.localOffset, 42)
        _ = await iphone.connect(bookmark: Data())
        await iphone.retryRecords()
        let ipad = makeShelf(deviceID: "ipad")
        _ = await ipad.connect(bookmark: Data())
        await ipad.refresh()
        guard case .opened(let remote) = await ipad.continueReading(),
              case .diagram(let remotePage) = remote.reader.primaryPage else { return XCTFail("其他设备应能续读语义位置") }
        XCTAssertEqual(remotePage.sceneID, "profit-change")
        XCTAssertEqual(remotePage.restorePosition?.anchorID, "heading")
        XCTAssertNil(remotePage.restorePosition?.localOffset)
    }

    func testRecordRetryRecoversAProviderReadFailureAndClearsItsSeparateError() async throws {
        let iphone = makeShelf()
        iphone.acceptCheckpoint(try actualCheckpoint(scene: "profit-change", time: 1_700_000_070))
        _ = await iphone.connect(bookmark: Data())
        await iphone.retryRecords()
        let cloud = DelayedRecordFolder(root: root.appendingPathComponent("cloud"))
        await cloud.failNextRecordRead(.unavailable("文件还没有到达"))
        let ipad = StudyShelf(localRoot: root.appendingPathComponent("ipad"), deviceID: "ipad", cloud: cloud, bundledStudy: study)
        _ = await ipad.connect(bookmark: Data())
        await ipad.refresh()
        guard case .failed = ipad.recordState.cloud else { return XCTFail("暂时无法取得记录须可重试") }
        XCTAssertNil(ipad.recommendedContinuation)
        await ipad.retryRecords()
        XCTAssertEqual(ipad.recommendedContinuation?.deviceID, "iphone")
        XCTAssertEqual(ipad.recommendedContinuation?.occurredAt, Date(timeIntervalSince1970: 1_700_000_070))
        XCTAssertEqual(ipad.recordState.cloud, .accepted)
        XCTAssertEqual(ipad.entries.first?.versions.first?.state, .ready)
    }

    func testLateOlderAndRepeatedDeviceFilesCannotRollBackACachedActualReading() async throws {
        let iphone = makeShelf()
        iphone.acceptCheckpoint(try actualCheckpoint(scene: "shareholder-returns", time: 1_700_000_080))
        _ = await iphone.connect(bookmark: Data())
        await iphone.retryRecords()
        let remoteFile = root.appendingPathComponent("cloud/records/iphone.json")
        let earlierDelivery = try Data(contentsOf: remoteFile)
        iphone.acceptCheckpoint(try actualCheckpoint(scene: "profit-change", time: 1_700_000_090))
        await iphone.retryRecords()
        let ipad = makeShelf(deviceID: "ipad")
        _ = await ipad.connect(bookmark: Data())
        await ipad.refresh()
        XCTAssertEqual(ipad.recommendedContinuation?.sequence, 2)
        try earlierDelivery.write(to: remoteFile, options: .atomic)
        await ipad.refresh()
        await ipad.refresh()
        XCTAssertEqual(ipad.recommendedContinuation?.sequence, 2)
        XCTAssertEqual(ipad.entries.first?.continuations.count, 1)
        let restarted = makeShelf(deviceID: "ipad")
        XCTAssertEqual(restarted.recommendedContinuation?.sequence, 2)
        XCTAssertEqual(restarted.recommendedContinuation?.occurredAt, Date(timeIntervalSince1970: 1_700_000_090))
    }

    private func actualCheckpoint(scene: String, time: TimeInterval, offset: Double? = nil) throws -> ReadingCheckpoint {
        var reader = StudyReader(study: study, clock: { Date(timeIntervalSince1970: time) })
        guard case .overview(let overview) = reader.primaryPage else { XCTFail("Fixture应有全貌"); throw NSError(domain: "StudyShelfFixture", code: 1) }
        reader.follow(try XCTUnwrap(overview.entries.first(where: { $0.sceneID == scene })).link)
        guard case .diagram(let page) = reader.primaryPage else { XCTFail("Fixture应有指定图解"); throw NSError(domain: "StudyShelfFixture", code: 2) }
        reader.reportVisiblePosition(page.observation, position: ReadingPosition(anchorID: "heading", localOffset: offset), cause: .userNavigation)
        return try XCTUnwrap(reader.checkpoint)
    }

    private func makeShelf(deviceID: String = "iphone") -> StudyShelf {
        StudyShelf(localRoot: root.appendingPathComponent(deviceID == "iphone" ? "local" : deviceID), deviceID: deviceID, cloud: RecordDirectory(root: root.appendingPathComponent("cloud")), bundledStudy: study)
    }
}

private struct RecordDirectory: CloudFolder {
    let root: URL
    func restoreAccess(bookmark: Data) async throws -> CloudFolderAccess { CloudFolderAccess() }
    func copyFile(relativePath: String, to localURL: URL) async throws {
        try FileManager.default.createDirectory(at: localURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try FileManager.default.copyItem(at: root.appendingPathComponent(relativePath), to: localURL)
    }
    func listRecordFiles() async throws -> [String] {
        let directory = root.appendingPathComponent("records")
        guard FileManager.default.fileExists(atPath: directory.path) else { return [] }
        return try FileManager.default.contentsOfDirectory(atPath: directory.path).map { "records/" + $0 }
    }
    func replaceOwnRecord(deviceID: String, contents: Data) async throws {
        let directory = root.appendingPathComponent("records")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try contents.write(to: directory.appendingPathComponent(deviceID + ".json"), options: .atomic)
    }
}

private actor DelayedRecordFolder: CloudFolder {
    let directory: RecordDirectory
    private var onPause: (() -> Void)?
    private var waiting: CheckedContinuation<Void, Never>?
    private var nextReadFailure: CloudFolderError?
    func failNextRecordRead(_ error: CloudFolderError) { nextReadFailure = error }
    private var writePaused: (() -> Void)?
    private var writeFailure: CloudFolderError?
    private var writeWaiting: CheckedContinuation<Void, Never>?
    init(root: URL) { directory = RecordDirectory(root: root) }
    func pauseWrite(failure: CloudFolderError?, whenPaused: @escaping () -> Void) {
        writeFailure = failure; writePaused = whenPaused
    }
    func resumeWrite() { writeWaiting?.resume(); writeWaiting = nil }
    func pauseRecord(_ action: @escaping () -> Void) { onPause = action }
    func resume() { waiting?.resume(); waiting = nil }
    func restoreAccess(bookmark: Data) async throws -> CloudFolderAccess { CloudFolderAccess() }
    func copyFile(relativePath: String, to localURL: URL) async throws {
        if relativePath.hasPrefix("records/"), let error = nextReadFailure {
            nextReadFailure = nil; throw error
        }
        try await directory.copyFile(relativePath: relativePath, to: localURL)
        if relativePath.hasPrefix("records/"), let action = onPause {
            onPause = nil
            await withCheckedContinuation { continuation in waiting = continuation; action() }
        }
    }
    func listRecordFiles() async throws -> [String] { try await directory.listRecordFiles() }
    func replaceOwnRecord(deviceID: String, contents: Data) async throws {
        if let action = writePaused {
            writePaused = nil
            let failure = writeFailure
            await withCheckedContinuation { continuation in writeWaiting = continuation; action() }
            if let failure { throw failure }
        }
        try await directory.replaceOwnRecord(deviceID: deviceID, contents: contents)
    }
}
