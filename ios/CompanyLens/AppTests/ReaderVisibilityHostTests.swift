#if os(macOS)
import AppKit
import SwiftUI
import XCTest
import ResearchCore
@testable import CompanyLens

/// Uses the production SwiftUI-to-native observation bridge, not Core-only observations.
@MainActor
final class ReaderVisibilityHostTests: XCTestCase {
    func testRecreatedNativeHostRestoresWithoutRedatingTheAcceptedCheckpoint() async throws {
        _ = NSApplication.shared
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let shelf = StudyShelf(localRoot: root, deviceID: "native-visibility",
            cloud: AppleCloudFolder(ownDeviceID: "native-visibility"), bundledStudy: try BundledStudy.load())
        let workspace = StudyWorkspace(shelf: shelf, defaults: UserDefaults(suiteName: UUID().uuidString)!)
        await workspace.start()
        workspace.open(try XCTUnwrap(shelf.entries.first?.currentVersionID))
        for _ in 0..<30 { await Task.yield() }
        let reading = try XCTUnwrap(workspace.activeReading)
        let old = workspace.binding(for: reading)
        guard case .overview(let overview) = old.wrappedValue.primaryPage else { return XCTFail("overview") }
        old.wrappedValue.follow(overview.beginOrResume)
        guard case .diagram(let diagram) = old.wrappedValue.primaryPage else { return XCTFail("diagram") }
        let first = expectation(description: "native host actually displays the diagram")
        let restored = expectation(description: "native host actually restores after reentry")
        let browsed = expectation(description: "native browsing enters through the production bridge")
        var arrived = false
        var currentArrival = first
        func screen(_ binding: Binding<StudyReader>) -> AnyView {
            let position: ReadingPosition?
            if case .diagram(let page) = binding.wrappedValue.primaryPage { position = page.restorePosition }
            else { position = nil }
            return AnyView(ReaderScroll(observation: diagram.observation,
                restorePosition: position ?? ReadingPosition(anchorID: "explanation", localOffset: 31),
                arrivalCause: .userNavigation, onPosition: { token, position, cause in
                    binding.wrappedValue.reportVisiblePosition(token, position: position, cause: cause)
                    if cause == .userBrowsing { browsed.fulfill() }
                    else if !arrived { arrived = true; currentArrival.fulfill() }
                }) {
                    Text("Heading").frame(height: 400).readingAnchor(id: "heading")
                    Text("Diagram").frame(height: 400).readingAnchor(id: "diagram")
                    Text("Explanation").frame(height: 400).readingAnchor(id: "explanation")
                    Text("Limits").frame(height: 400).readingAnchor(id: "limits")
                }
                .environment(\.readingObservationGeneration, workspace.observationGeneration)
                .environment(\.restoredReadingObservations, workspace.restoredObservations)
                .environment(\.readingObservationEnabled, workspace.isSceneActive)
                .frame(width: 320, height: 200))
        }
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 320, height: 200),
            styleMask: [.titled], backing: .buffered, defer: false)
        window.contentViewController = NSHostingController(rootView: screen(old))
        window.makeKeyAndOrderFront(nil)
        window.contentView?.layoutSubtreeIfNeeded()
        window.displayIfNeeded()
        defer { window.orderOut(nil) }
        await fulfillment(of: [first], timeout: 4)
        let accepted = try XCTUnwrap(workspace.activeReading?.reader.checkpoint)
        workspace.returnToLibrary()
        window.contentViewController = nil
        workspace.showReading()
        arrived = false
        currentArrival = restored
        let fresh = workspace.binding(for: try XCTUnwrap(workspace.activeReading))
        window.contentViewController = NSHostingController(rootView: screen(fresh))
        window.contentView?.layoutSubtreeIfNeeded()
        window.displayIfNeeded()
        await fulfillment(of: [restored], timeout: 4)
        XCTAssertEqual(workspace.activeReading?.id, reading.id)
        XCTAssertEqual(workspace.activeReading?.reader.checkpoint, accepted,
                       "native restoration retains the accepted reading time and event")
        old.wrappedValue.reportVisiblePosition(diagram.observation,
            position: ReadingPosition(anchorID: "limits", localOffset: 99), cause: .userBrowsing)
        XCTAssertEqual(workspace.activeReading?.reader.checkpoint, accepted,
                       "a late preceding-visibility observation remains revoked")
        let scroll = try XCTUnwrap(findScroll(in: try XCTUnwrap(window.contentView)))
        scroll.contentView.scroll(to: NSPoint(x: 0, y: 1300))
        NotificationCenter.default.post(name: NSScrollView.didLiveScrollNotification, object: scroll)
        await fulfillment(of: [browsed], timeout: 2)
        XCTAssertNotEqual(workspace.activeReading?.reader.checkpoint?.eventID, accepted.eventID)
        let browsedCheckpoint = workspace.activeReading?.reader.checkpoint
        let host = try XCTUnwrap(window.contentViewController as? NSHostingController<AnyView>)
        workspace.setSceneActive(false)
        host.rootView = screen(fresh)
        host.view.layoutSubtreeIfNeeded()
        for _ in 0..<10 { await Task.yield() }
        XCTAssertNil(findScroll(in: host.view), "inactive scenes dismantle the actual native measurement and observation host")
        NotificationCenter.default.post(name: NSScrollView.didLiveScrollNotification, object: scroll)
        XCTAssertEqual(workspace.activeReading?.reader.checkpoint, browsedCheckpoint)
        workspace.setSceneActive(true)
        currentArrival = expectation(description: "reactivated native host restores without a new actual reading")
        arrived = false
        let active = workspace.binding(for: try XCTUnwrap(workspace.activeReading))
        host.rootView = screen(active)
        host.view.layoutSubtreeIfNeeded()
        await fulfillment(of: [currentArrival], timeout: 4)
        XCTAssertEqual(workspace.activeReading?.reader.checkpoint, browsedCheckpoint)
        fresh.wrappedValue.reportVisiblePosition(diagram.observation,
            position: ReadingPosition(anchorID: "limits", localOffset: 99), cause: .userBrowsing)
        XCTAssertEqual(workspace.activeReading?.reader.checkpoint, browsedCheckpoint,
                       "the preceding active scene's authorization remains revoked")
    }

    private func findScroll(in view: NSView) -> NSScrollView? {
        if let scroll = view as? NSScrollView { return scroll }
        return view.subviews.compactMap { findScroll(in: $0) }.first
    }
}
#endif
