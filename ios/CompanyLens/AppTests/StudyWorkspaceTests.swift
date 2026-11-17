import Foundation
import SwiftUI
import XCTest
import ResearchCore
@testable import CompanyLens

@MainActor
final class StudyWorkspaceTests: XCTestCase {
    func testEmptyReadingEntrancesAskForACompanyWithoutCreatingAReader() throws {
        let workspace = try workspace()
        workspace.showReading(mode: .report)
        XCTAssertEqual(workspace.selectedTab, .report)
        XCTAssertNil(workspace.activeReading)
        XCTAssertFalse(workspace.isReadingVisible)
        workspace.showReading(mode: .diagram)
        XCTAssertEqual(workspace.selectedTab, .diagram)
        XCTAssertNil(workspace.activeReading)
        workspace.returnToLibrary()
        XCTAssertEqual(workspace.selectedTab, .library)
    }

    func testReturningToLibraryKeepsTheSameReadingAndItsSourceRelationships() async throws {
        let workspace = try workspace()
        await workspace.start()
        let version = try XCTUnwrap(workspace.shelf.entries.first?.currentVersionID)
        workspace.open(version)
        await settle()
        let reading = try XCTUnwrap(workspace.activeReading)
        var binding = workspace.binding(for: reading)
        guard case .overview(let overview) = binding.wrappedValue.primaryPage else { return XCTFail("overview") }
        binding.wrappedValue.follow(overview.beginOrResume)
        guard case .diagram(let page) = binding.wrappedValue.primaryPage else { return XCTFail("diagram") }
        binding.wrappedValue.selectFocus(try XCTUnwrap(page.diagram.choice(for: "rebate")))
        guard case .diagram(let selected) = binding.wrappedValue.primaryPage else { return XCTFail("selected diagram") }
        binding.wrappedValue.reportVisiblePosition(selected.observation,
            position: ReadingPosition(anchorID: "explanation", localOffset: 31), cause: .userBrowsing)
        binding.wrappedValue.switchMode(.report)
        binding = workspace.binding(for: try XCTUnwrap(workspace.activeReading))
        guard case .report(let report) = binding.wrappedValue.primaryPage else { return XCTFail("report") }
        binding.wrappedValue.reportVisiblePosition(report.observation,
            position: ReadingPosition(anchorID: "report/summary", localOffset: 42), cause: .userBrowsing)
        binding.wrappedValue.switchMode(.diagram)
        binding = workspace.binding(for: try XCTUnwrap(workspace.activeReading))
        let bookmark = binding.wrappedValue.localBookmark

        workspace.returnToLibrary()

        XCTAssertEqual(workspace.activeReading?.id, reading.id, "returning to the library must retain the original Reader")
        XCTAssertEqual(workspace.activeReading?.reader.localBookmark, bookmark)
        workspace.showReading()
        var resumed = workspace.binding(for: try XCTUnwrap(workspace.activeReading))
        guard case .diagram(let diagram) = resumed.wrappedValue.primaryPage else { return XCTFail("diagram") }
        XCTAssertEqual(diagram.focus.id, "rebate")
        XCTAssertEqual(diagram.restorePosition, ReadingPosition(anchorID: "explanation", localOffset: 31))
        resumed.wrappedValue.switchMode(.report)
        resumed = workspace.binding(for: try XCTUnwrap(workspace.activeReading))
        guard case .report(let restoredReport) = resumed.wrappedValue.primaryPage else { return XCTFail("report") }
        XCTAssertEqual(restoredReport.restorePosition, ReadingPosition(anchorID: "report/summary", localOffset: 42))
        resumed.wrappedValue.back()
        guard case .diagram(let origin) = resumed.wrappedValue.primaryPage else { return XCTFail("original diagram source") }
        XCTAssertEqual(origin.focus.id, "rebate")
        XCTAssertEqual(workspace.activeReading?.id, reading.id)
    }

    func testHiddenAndPreviousVisibilityCallbacksCannotChangeTheRetainedReading() async throws {
        let workspace = try workspace()
        await workspace.start()
        workspace.open(try XCTUnwrap(workspace.shelf.entries.first?.currentVersionID))
        await settle()
        let reading = try XCTUnwrap(workspace.activeReading)
        let old = workspace.binding(for: reading)
        guard case .overview(let overview) = old.wrappedValue.primaryPage else { return XCTFail("overview") }
        old.wrappedValue.follow(overview.beginOrResume)
        guard case .diagram(let page) = old.wrappedValue.primaryPage else { return XCTFail("diagram") }
        old.wrappedValue.reportVisiblePosition(page.observation,
            position: ReadingPosition(anchorID: "explanation", localOffset: 31), cause: .userBrowsing)
        let accepted = try XCTUnwrap(workspace.activeReading?.reader.checkpoint)
        workspace.returnToLibrary()
        old.wrappedValue.reportVisiblePosition(page.observation,
            position: ReadingPosition(anchorID: "limits", localOffset: 99), cause: .userBrowsing)
        XCTAssertEqual(workspace.activeReading?.reader.checkpoint, accepted, "hidden callbacks have no reading authority")

        workspace.continueReading()
        await settle()
        XCTAssertEqual(workspace.activeReading?.id, reading.id, "continue resumes the retained Reader")
        old.wrappedValue.reportVisiblePosition(page.observation,
            position: ReadingPosition(anchorID: "limits", localOffset: 99), cause: .userBrowsing)
        XCTAssertEqual(workspace.activeReading?.reader.checkpoint, accepted, "the preceding visible period remains revoked after reentry")
        let choice = workspace.shelf.recommendedContinuation
        await workspace.shelf.retryRecords()
        XCTAssertEqual(workspace.shelf.recommendedContinuation, choice, "saving and retrying an accepted checkpoint preserves its reading occurrence time")
        let fresh = workspace.binding(for: try XCTUnwrap(workspace.activeReading))
        guard case .diagram(let restored) = fresh.wrappedValue.primaryPage else { return XCTFail("diagram") }
        XCTAssertEqual(restored.restorePosition, ReadingPosition(anchorID: "explanation", localOffset: 31))
        fresh.wrappedValue.reportVisiblePosition(restored.observation,
            position: ReadingPosition(anchorID: "limits", localOffset: 7), cause: .userBrowsing)
        XCTAssertNotEqual(workspace.activeReading?.reader.checkpoint?.eventID, accepted.eventID)
        guard case .diagram(let browsed) = fresh.wrappedValue.primaryPage else { return XCTFail("diagram") }
        XCTAssertEqual(browsed.restorePosition, ReadingPosition(anchorID: "limits", localOffset: 7))
    }

    func testDetailAndFullscreenRejectBackgroundLibraryAndModeNavigation() async throws {
        let workspace = try workspace()
        await workspace.start()
        workspace.open(try XCTUnwrap(workspace.shelf.entries.first?.currentVersionID))
        await settle()
        let reading = try XCTUnwrap(workspace.activeReading)
        var binding = workspace.binding(for: reading)
        guard case .overview(let overview) = binding.wrappedValue.primaryPage else { return XCTFail("overview") }
        binding.wrappedValue.follow(overview.beginOrResume)
        guard case .diagram(let page) = binding.wrappedValue.primaryPage else { return XCTFail("diagram") }
        binding.wrappedValue.follow(try XCTUnwrap(page.focus.evidence))
        let token = try XCTUnwrap(binding.wrappedValue.presentationPath.first?.token)
        workspace.showReading(mode: .report)
        workspace.returnToLibrary()
        XCTAssertTrue(workspace.isReadingVisible)
        guard case .diagram = binding.wrappedValue.primaryPage else { return XCTFail("reader mode must remain diagram while checking evidence") }
        XCTAssertEqual(binding.wrappedValue.presentationPath.first?.token, token)
        binding.wrappedValue.dismissPresentation(token)
        workspace.showReading(mode: .report)
        guard case .report = binding.wrappedValue.primaryPage else { return XCTFail("closing evidence enables report navigation") }
        workspace.showReading(mode: .diagram)
        binding = workspace.binding(for: try XCTUnwrap(workspace.activeReading))
        binding.wrappedValue.enlargeDiagram()
        let fullscreen = try XCTUnwrap(binding.wrappedValue.fullscreenDiagram)
        workspace.showReading(mode: .report)
        workspace.returnToLibrary()
        XCTAssertTrue(workspace.isReadingVisible)
        guard case .diagram = binding.wrappedValue.primaryPage else { return XCTFail("fullscreen protects its diagram source") }
        XCTAssertEqual(binding.wrappedValue.fullscreenDiagram?.presentationToken, fullscreen.presentationToken)
    }

    func testFailedOpenKeepsTheOriginalReadingAndLaterLibraryIntentWins() async throws {
        let workspace = try workspace()
        await workspace.start()
        let version = try XCTUnwrap(workspace.shelf.entries.first?.currentVersionID)
        workspace.open(version)
        await settle()
        let original = try XCTUnwrap(workspace.activeReading)
        workspace.returnToLibrary()
        let missing = try JSONDecoder().decode(ShelfVersionID.self,
            from: Data(#"{"companyID":"missing-company","versionID":"missing-version"}"#.utf8))
        workspace.open(missing)
        await settle()
        XCTAssertEqual(workspace.activeReading?.id, original.id)
        XCTAssertEqual(workspace.activeReading?.study.identity, original.study.identity)
        XCTAssertFalse(workspace.isReadingVisible)
        XCTAssertNotNil(workspace.notice)
        workspace.open(missing)
        workspace.showReading(mode: .report)
        await settle()
        XCTAssertEqual(workspace.activeReading?.id, original.id)
        XCTAssertTrue(workspace.isReadingVisible)
        guard case .report = workspace.activeReading?.reader.primaryPage else { return XCTFail("later explicit report intent wins") }
    }

    func testInactiveSceneRevokesObservationsWithoutChangingTheSelectedPage() async throws {
        let workspace = try workspace()
        await workspace.start()
        workspace.open(try XCTUnwrap(workspace.shelf.entries.first?.currentVersionID))
        await settle()
        let reading = try XCTUnwrap(workspace.activeReading)
        let old = workspace.binding(for: reading)
        guard case .overview(let page) = old.wrappedValue.primaryPage else { return XCTFail("overview") }
        old.wrappedValue.reportVisiblePosition(page.observation,
            position: ReadingPosition(anchorID: "overview", localOffset: 12), cause: .userBrowsing)
        let accepted = workspace.activeReading?.reader.checkpoint
        workspace.setSceneActive(false)
        old.wrappedValue.reportVisiblePosition(page.observation,
            position: ReadingPosition(anchorID: "overview", localOffset: 99), cause: .userBrowsing)
        XCTAssertTrue(workspace.isReadingVisible, "scene visibility does not change the chosen page")
        XCTAssertEqual(workspace.activeReading?.reader.checkpoint, accepted)
        workspace.setSceneActive(true)
        old.wrappedValue.reportVisiblePosition(page.observation,
            position: ReadingPosition(anchorID: "overview", localOffset: 99), cause: .userBrowsing)
        XCTAssertEqual(workspace.activeReading?.reader.checkpoint, accepted)
        XCTAssertEqual(workspace.activeReading?.id, reading.id)
        let fresh = workspace.binding(for: try XCTUnwrap(workspace.activeReading))
        fresh.wrappedValue.reportVisiblePosition(page.observation,
            position: ReadingPosition(anchorID: "overview", localOffset: 14), cause: .userBrowsing)
        XCTAssertNotEqual(workspace.activeReading?.reader.checkpoint?.eventID, accepted?.eventID)
    }

    func testExplicitOtherDeviceCandidateOfTheSameVersionIsHonored() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let study = try BundledStudy.load()
        let cloud = WorkspaceRecordDirectory(root: root.appendingPathComponent("cloud"))
        let local = StudyShelf(localRoot: root.appendingPathComponent("local"), deviceID: "local", cloud: cloud, bundledStudy: study)
        let other = StudyShelf(localRoot: root.appendingPathComponent("other"), deviceID: "other", cloud: cloud, bundledStudy: study)
        var localReader = StudyReader(study: study, clock: { Date(timeIntervalSince1970: 1_700_000_001) })
        guard case .overview(let overview) = localReader.primaryPage else { return XCTFail("overview") }
        localReader.follow(overview.beginOrResume)
        guard case .diagram(let diagram) = localReader.primaryPage else { return XCTFail("diagram") }
        localReader.reportVisiblePosition(diagram.observation, position: ReadingPosition(anchorID: "explanation", localOffset: 31), cause: .userBrowsing)
        local.acceptCheckpoint(try XCTUnwrap(localReader.checkpoint))
        var remoteReader = StudyReader(study: study, clock: { Date(timeIntervalSince1970: 1_700_000_002) })
        remoteReader.switchMode(.report)
        guard case .report(let report) = remoteReader.primaryPage else { return XCTFail("report") }
        remoteReader.reportVisiblePosition(report.observation, position: ReadingPosition(anchorID: "report/summary", localOffset: 42), cause: .userBrowsing)
        other.acceptCheckpoint(try XCTUnwrap(remoteReader.checkpoint))
        _ = await other.connect(bookmark: Data())
        await other.retryRecords()
        _ = await local.connect(bookmark: Data())
        await local.retryRecords()
        await local.refresh()
        let choices = try XCTUnwrap(local.entries.first?.continuations)
        let localChoice = try XCTUnwrap(choices.first { $0.deviceID == "local" })
        let remoteChoice = try XCTUnwrap(choices.first { $0.deviceID == "other" })
        XCTAssertEqual(localChoice.identity, remoteChoice.identity)
        let workspace = StudyWorkspace(shelf: local, defaults: UserDefaults(suiteName: UUID().uuidString)!)
        workspace.continueReading(localChoice)
        await settle()
        let original = try XCTUnwrap(workspace.activeReading)
        guard case .diagram = original.reader.primaryPage else { return XCTFail("chosen local diagram") }
        workspace.returnToLibrary()
        workspace.continueReading()
        XCTAssertEqual(workspace.activeReading?.id, original.id, "ordinary resume retains the Reader")
        workspace.continueReading(remoteChoice)
        await settle()
        let selected = try XCTUnwrap(workspace.activeReading)
        XCTAssertNotEqual(selected.id, original.id, "an explicit different candidate replaces only after Shelf opens it")
        guard case .report(let chosenReport) = selected.reader.primaryPage else { return XCTFail("explicit other-device report candidate must win") }
        XCTAssertEqual(chosenReport.restorePosition?.anchorID, "report/summary")
        XCTAssertNil(chosenReport.restorePosition?.localOffset, "the other device's pixel offset is not reused")
    }

    func testAssociationAndSourceReturnDeriveTheSelectedReadingTab() async throws {
        let workspace = try workspace()
        await workspace.start()
        workspace.open(try XCTUnwrap(workspace.shelf.entries.first?.currentVersionID))
        await settle()
        let reading = try XCTUnwrap(workspace.activeReading)
        var binding = workspace.binding(for: reading)
        guard case .overview(let overview) = binding.wrappedValue.primaryPage else { return XCTFail("overview") }
        binding.wrappedValue.follow(overview.beginOrResume)
        guard case .diagram(let diagram) = binding.wrappedValue.primaryPage else { return XCTFail("diagram") }
        binding.wrappedValue.follow(try XCTUnwrap(diagram.relatedReports.first).link)
        XCTAssertEqual(workspace.selectedTab, .report)
        XCTAssertEqual(workspace.activeReading?.reader.currentMode, .report)
        binding = workspace.binding(for: reading)
        binding.wrappedValue.back()
        XCTAssertEqual(workspace.selectedTab, .diagram)
        guard case .diagram(let returned) = workspace.activeReading?.reader.primaryPage else { return XCTFail("source") }
        XCTAssertEqual(returned.sceneID, diagram.sceneID)
        XCTAssertEqual(returned.focus.id, diagram.focus.id)
        XCTAssertEqual(workspace.activeReading?.id, reading.id)
    }

    func testModeTabsRevokeThePreviousHostsAuthorityAndKeepLocalDiagramGeometry() async throws {
        let workspace = try workspace()
        await workspace.start()
        workspace.open(try XCTUnwrap(workspace.shelf.entries.first?.currentVersionID))
        await settle()
        let reading = try XCTUnwrap(workspace.activeReading)
        let outgoing = workspace.binding(for: reading)
        guard case .overview(let overview) = outgoing.wrappedValue.primaryPage else { return XCTFail("overview") }
        outgoing.wrappedValue.follow(overview.beginOrResume)
        guard case .diagram(let diagram) = outgoing.wrappedValue.primaryPage else { return XCTFail("diagram") }
        outgoing.wrappedValue.reportVisiblePosition(diagram.observation,
            position: ReadingPosition(anchorID: "explanation", localOffset: 31), cause: .userBrowsing)
        let accepted = workspace.activeReading?.reader.checkpoint
        let presentation = try XCTUnwrap(workspace.presentationState)
        presentation.diagramViewports[diagram.visitID] = DiagramViewport(zoomScale: 2, contentOffset: CGPoint(x: 100, y: 80))
        workspace.showReading(mode: .report)
        outgoing.wrappedValue.reportVisiblePosition(diagram.observation,
            position: ReadingPosition(anchorID: "limits", localOffset: 99), cause: .userBrowsing)
        XCTAssertEqual(workspace.activeReading?.reader.checkpoint, accepted)
        XCTAssertEqual(workspace.selectedTab, .report)
        workspace.returnToLibrary()
        workspace.showReading(mode: .diagram)
        XCTAssertTrue(workspace.presentationState === presentation)
        XCTAssertEqual(presentation.readingID, reading.id)
        XCTAssertEqual(presentation.diagramViewports[diagram.visitID]?.zoomScale, 2)
        XCTAssertEqual(presentation.diagramViewports[diagram.visitID]?.contentOffset, CGPoint(x: 100, y: 80))
        guard case .diagram(let restored) = workspace.activeReading?.reader.primaryPage else { return XCTFail("restored diagram") }
        XCTAssertEqual(restored.restorePosition, ReadingPosition(anchorID: "explanation", localOffset: 31))
        outgoing.wrappedValue.reportVisiblePosition(restored.observation,
            position: ReadingPosition(anchorID: "limits", localOffset: 99), cause: .userBrowsing)
        XCTAssertEqual(workspace.activeReading?.reader.checkpoint, accepted)
    }

    private func workspace() throws -> StudyWorkspace {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        let shelf = StudyShelf(localRoot: root, deviceID: "workspace-tests",
            cloud: AppleCloudFolder(ownDeviceID: "workspace-tests"), bundledStudy: try BundledStudy.load())
        return StudyWorkspace(shelf: shelf, defaults: UserDefaults(suiteName: UUID().uuidString)!)
    }

    private func settle() async {
        for _ in 0..<30 { await Task.yield() }
    }
}

private struct WorkspaceRecordDirectory: CloudFolder {
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
