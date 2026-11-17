import SwiftUI
import XCTest
#if canImport(UIKit)
import UIKit

@MainActor
final class ReportDocumentHostTests: XCTestCase {
    func testCompleteReportShowsItsFirstReadableViewportWithoutLayingOutDistantAuthoredBodies() async throws {
        var reader = StudyReader(study: try study())
        reader.switchMode(.report)
        guard case .report(let page) = reader.page else { return XCTFail("Open the complete report") }
        let authored = ReportReadingBody(page: page, follow: { _ in }).blocks
        XCTAssertEqual(authored.flatMap(\.anchors).count, page.anchors.count)
        XCTAssertEqual(Set(authored.flatMap(\.anchors)), Set(page.anchors.map(\.id)))
        let layout = ReportFixtureLayout()
        let blocks = authored.map { block in
            ReportDocumentBlock(id: block.id, anchors: block.anchors) {
                AnyView(block.content().background(ReportFixtureMarker(id: block.id, layout: layout)))
            }
        }
        let host = ReportDocumentController()
        let visible = expectation(description: "the real first report viewport arrives")
        var arrived = false
        host.render(renderID: "complete-report", target: .init(anchorID: "report/summary"), blocks: blocks) { event in
            if case .arrival = event.cause, !arrived { arrived = true; visible.fulfill() }
        }
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 390, height: 600))
        window.rootViewController = host; window.makeKeyAndVisible()
        defer { window.isHidden = true }
        await fulfillment(of: [visible], timeout: 8)
        let marker = try XCTUnwrap(layout.markers["report/summary"])
        XCTAssertTrue(marker.window === window)
        XCTAssertTrue(marker.convert(marker.bounds, to: window).intersects(window.bounds))
        XCTAssertGreaterThan(marker.bounds.height, 100, "the authored summary is laid out at readable natural height")
        XCTAssertLessThan(layout.laidOut.count, 12,
                          "first reading must not lay out all \(authored.count) complete authored bodies; observed \(layout.laidOut.count)")
        XCTAssertFalse(layout.laidOut.contains("monitoring/monitor-quarter-profit"),
                       "the last monitoring text is available for later reading without being laid out at first arrival")
    }

    func testWidthOnlyAndAccessibilityReflowKeepTheActualSemanticSourceMarker() async throws {
        var reader = StudyReader(study: try study()); reader.switchMode(.report)
        guard case .report(let page) = reader.page else { return XCTFail() }
        let geometry = ReportFixtureLayout()
        let sourceID = "fixture/reflow-source"
        let blocks = ReportReadingBody(page: page, follow: { _ in }).blocks.map { block in
            guard block.id == "claim/gree-service" else { return block }
            return ReportDocumentBlock(id: block.id, anchors: block.anchors + [sourceID]) {
                AnyView(VStack(alignment: .leading, spacing: 0) {
                    // Retain the real complete authored body before the fixture's
                    // own source marker. Its text must actually reflow at width/AX.
                    block.content()
                    Text("来源位置").frame(maxWidth: .infinity).frame(height: 200)
                        .background(ReportFixtureMarker(id: sourceID, layout: geometry))
                        .readingAnchor(id: sourceID)
                })
            }
        }
        let host = ReportDocumentController()
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 390, height: 600))
        window.rootViewController = host; window.makeKeyAndVisible()
        defer { window.isHidden = true }
        var events: [ReadingScrollObservation] = []
        let initial = expectation(description: "the actual source marker arrives")
        var environment = EnvironmentValues()
        host.render(renderID: "reflow", target: .init(anchorID: sourceID, localOffset: 37),
                    blocks: blocks, environment: environment) { event in
            events.append(event); if case .arrival = event.cause { initial.fulfill() }
        }
        await fulfillment(of: [initial], timeout: 8)
        let source = try XCTUnwrap(geometry.markers[sourceID])
        XCTAssertEqual(source.convert(.zero, to: window).y, -37, accuracy: 1)
        let initialWidth = source.bounds.width

        // No render call or environment change: only UIKit's available width changes.
        window.frame.size.width = 280
        window.layoutIfNeeded(); host.view.layoutIfNeeded()
        try await Task.sleep(nanoseconds: 200_000_000)
        XCTAssertLessThan(source.bounds.width, initialWidth - 100, "the report really laid out at the narrower width")
        XCTAssertEqual(source.convert(.zero, to: window).y, -37, accuracy: 1,
                       "pure native width reflow preserves the same semantic source and local offset")
        XCTAssertEqual(events.count, 1, "passive width reflow does not create reading")

        environment.dynamicTypeSize = .accessibility5
        host.render(renderID: "reflow", target: nil, blocks: blocks, environment: environment) { events.append($0) }
        host.view.layoutIfNeeded()
        try await Task.sleep(nanoseconds: 200_000_000)
        XCTAssertEqual(source.convert(.zero, to: window).y, -37, accuracy: 1,
                       "AX XXXL also preserves the independently measured source marker")
        XCTAssertEqual(events.count, 1)

        // Cancel pending reflow, then restore another scope; queued work cannot
        // move that later viewport back to this source.
        window.frame.size.width = 320
        host.view.setNeedsLayout(); host.stopObserving()
        let reopened = expectation(description: "new scope summary arrives")
        let summaryGeometry = ReportFixtureLayout()
        let reopenedBlocks = ReportReadingBody(page: page, follow: { _ in }).blocks.map { block in
            ReportDocumentBlock(id: block.id, anchors: block.anchors) {
                AnyView(block.content().background(ReportFixtureMarker(id: block.id, layout: summaryGeometry)))
            }
        }
        host.render(renderID: "reopened", target: .init(anchorID: "report/summary", localOffset: 23), blocks: reopenedBlocks) { event in
            if case .arrival = event.cause { reopened.fulfill() }
        }
        await fulfillment(of: [reopened], timeout: 8)
        try await Task.sleep(nanoseconds: 100_000_000)
        let summary = try XCTUnwrap(summaryGeometry.markers["report/summary"])
        XCTAssertEqual(summary.convert(.zero, to: window).y, -23, accuracy: 1)
        XCTAssertEqual(events.count, 1, "old reflow callbacks remain cancelled")
    }

    private func study() throws -> ReadableStudy {
        let bundle = Bundle(for: Self.self)
        return try ReadableStudy(root: XCTUnwrap(bundle.url(forResource: "Study", withExtension: nil)))
    }
}

/// The fixture owns these views. Assertions use the views' actual layout and
/// window coordinates, independently of the document's reported geometry.
@MainActor private final class ReportFixtureLayout {
    var laidOut: Set<String> = []
    var markers: [String: UIView] = [:]
}
private final class ReportFixtureMarkerView: UIView {
    var onLayout: (() -> Void)?
    override func layoutSubviews() { super.layoutSubviews(); if bounds.height > 0 { onLayout?() } }
}
private struct ReportFixtureMarker: UIViewRepresentable {
    let id: String
    let layout: ReportFixtureLayout
    func makeUIView(context: Context) -> ReportFixtureMarkerView {
        let view = ReportFixtureMarkerView(); view.isUserInteractionEnabled = false
        view.onLayout = { layout.laidOut.insert(id) }
        layout.markers[id] = view
        return view
    }
    func updateUIView(_ view: ReportFixtureMarkerView, context: Context) {}
    func sizeThatFits(_ proposal: ProposedViewSize, uiView: ReportFixtureMarkerView, context: Context) -> CGSize? {
        CGSize(width: proposal.width ?? 0, height: proposal.height ?? 0)
    }
}
#endif
