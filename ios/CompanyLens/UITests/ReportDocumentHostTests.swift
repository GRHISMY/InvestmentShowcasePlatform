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
