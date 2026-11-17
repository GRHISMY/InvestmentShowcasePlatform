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

    func testReverseBrowsingIntoAnUnanchoredHeadingKeepsItsOriginalSource() async throws {
        var reader = StudyReader(study: try study()); reader.switchMode(.report)
        guard case .report(let page) = reader.page else { return XCTFail() }
        let geometry = ReportFixtureLayout()
        let blocks = ReportReadingBody(page: page, follow: { _ in }).blocks.map { block in
            ReportDocumentBlock(id: block.id, anchors: block.anchors) {
                AnyView(block.content().background(ReportFixtureMarker(id: block.id, layout: geometry)))
            }
        }
        let host = ReportDocumentController()
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 390, height: 600))
        window.rootViewController = host; window.makeKeyAndVisible()
        defer { window.isHidden = true }
        let arrived = expectation(description: "arrive inside the first dimension without visiting its predecessor")
        var latest: ReadingScrollObservation?
        host.render(renderID: "dimension", target: .init(anchorID: try XCTUnwrap(page.dimensions.first).anchor.id, localOffset: 430), blocks: blocks) { event in
            if case .arrival = event.cause { arrived.fulfill() }
            if case .userBrowsing = event.cause { latest = event }
        }
        await fulfillment(of: [arrived], timeout: 8)
        XCTAssertTrue(host.view.accessibilityScroll(.up))
        let heading = try XCTUnwrap(geometry.markers["dimensions-heading"])
        let sourceY = heading.convert(.zero, to: window).y
        XCTAssertLessThan(sourceY, 0)
        XCTAssertGreaterThan(sourceY + heading.bounds.height, 0, "the viewport really starts in the unanchored index heading")
        let position = try XCTUnwrap(latest).position
        XCTAssertEqual(position.anchorID, "report/limits", "the index heading belongs to the preceding formal anchor")
        let returned = expectation(description: "return to the same heading gap")
        host.render(renderID: "returned-heading", target: position, blocks: blocks) { event in
            if case .arrival = event.cause { returned.fulfill() }
        }
        await fulfillment(of: [returned], timeout: 8)
        XCTAssertEqual(try XCTUnwrap(geometry.markers["dimensions-heading"]).convert(.zero, to: window).y,
                       sourceY, accuracy: 1)
    }

    func testDistantNonheadingAndSourceReturnHaveExactIndependentWindowGeometry() async throws {
        var reader = StudyReader(study: try study()); reader.switchMode(.report)
        guard case .report(let page) = reader.page else { return XCTFail() }
        let geometry = ReportFixtureLayout()
        let blocks = ReportReadingBody(page: page, follow: { _ in }).blocks.map { block in
            ReportDocumentBlock(id: block.id, anchors: block.anchors) {
                AnyView(block.content().background(ReportFixtureMarker(id: block.id, layout: geometry)))
            }
        }
        let host = ReportDocumentController()
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 390, height: 600))
        window.rootViewController = host; window.makeKeyAndVisible()
        defer { window.isHidden = true }
        func restore(_ id: String, _ anchor: String, _ offset: CGFloat) async throws {
            let arrival = expectation(description: id)
            var arrived = false
            host.render(renderID: id, target: .init(anchorID: anchor, localOffset: offset), blocks: blocks) { event in
                if case .arrival = event.cause, !arrived { arrived = true; arrival.fulfill() }
            }
            await fulfillment(of: [arrival], timeout: 8)
        }
        func headingY(_ text: String, expected: CGFloat) throws -> CGFloat {
            let candidates = accessibility(in: host.view).filter { $0.accessibilityLabel == text }
            return try XCTUnwrap(candidates.min { abs($0.accessibilityFrame.minY - expected) < abs($1.accessibilityFrame.minY - expected) }).accessibilityFrame.minY
        }
        try await restore("source", "claim/gree-service/known", 37)
        let sourceY = try headingY("我们查到了什么", expected: -37)
        XCTAssertEqual(sourceY, -37, accuracy: 1)
        let sourceRootY = try XCTUnwrap(geometry.markers["claim/gree-service"]).convert(.zero, to: window).y
        try await restore("distant", "claim/gree-dividend/meaning", 23)
        XCTAssertEqual(try headingY("这和赚钱、用钱有什么关系", expected: -23), -23, accuracy: 1)
        try await restore("returned", "claim/gree-service/known", 37)
        XCTAssertEqual(try headingY("我们查到了什么", expected: sourceY), sourceY, accuracy: 1)
        XCTAssertEqual(try XCTUnwrap(geometry.markers["claim/gree-service"]).convert(.zero, to: window).y,
                       sourceRootY, accuracy: 1)
        try await restore("last-monitor", "monitoring/monitor-quarter-profit", 0)
        try await restore("summary", "report/summary", 0)
        let summary = try XCTUnwrap(geometry.markers["report/summary"])
        XCTAssertEqual(summary.convert(.zero, to: window).y, 0, accuracy: 1)
    }

    func testNativeBrowsingKeepsLatestCallbacksAndDoesNotReloadOrSnapToTheOldTarget() async throws {
        var reader = StudyReader(study: try study()); reader.switchMode(.report)
        guard case .report(let page) = reader.page else { return XCTFail() }
        let geometry = ReportFixtureLayout()
        let blocks = ReportReadingBody(page: page, follow: { _ in }).blocks.map { block in
            ReportDocumentBlock(id: block.id, anchors: block.anchors) {
                AnyView(block.content().background(ReportFixtureMarker(id: block.id, layout: geometry)))
            }
        }
        let host = ReportDocumentController()
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 390, height: 600))
        window.rootViewController = host; window.makeKeyAndVisible()
        defer { window.isHidden = true }
        let arrived = expectation(description: "initial report arrival")
        var events: [ReadingScrollObservation] = []
        host.render(renderID: "browsing", target: .init(anchorID: "claim/gree-service/known", localOffset: 37), blocks: blocks) { event in
            if case .arrival = event.cause { arrived.fulfill() }
        }
        await fulfillment(of: [arrived], timeout: 8)
        let source = try XCTUnwrap(geometry.markers["claim/gree-service"])
        let before = source.convert(.zero, to: window).y
        for _ in 0..<4 {
            host.render(renderID: "browsing", target: .init(anchorID: "claim/gree-service/known", localOffset: 37), blocks: blocks) {
                events.append($0)
            }
            XCTAssertTrue(host.view.accessibilityScroll(.down))
            await Task.yield()
        }
        XCTAssertEqual(events.count, 4)
        XCTAssertTrue(events.allSatisfy { if case .userBrowsing = $0.cause { return true }; return false })
        XCTAssertNotEqual(events.first?.position, events.last?.position)
        XCTAssertLessThan(source.convert(.zero, to: window).y, before - 1_000)
        XCTAssertTrue(geometry.markers["claim/gree-service"] === source,
                      "genuine checkpoint updates keep the current authored body stable")
        let after = source.convert(.zero, to: window).y
        host.render(renderID: "browsing", target: .init(anchorID: "claim/gree-service/known", localOffset: 37), blocks: blocks) { _ in }
        await Task.yield()
        XCTAssertEqual(source.convert(.zero, to: window).y, after, accuracy: 1)
    }

    func testNativeReflowDoesNotCreateReadingAndStoppedScopeCannotEmitQueuedCallbacks() async throws {
        var reader = StudyReader(study: try study()); reader.switchMode(.report)
        guard case .report(let page) = reader.page else { return XCTFail() }
        let blocks = ReportReadingBody(page: page, follow: { _ in }).blocks
        let host = ReportDocumentController()
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 390, height: 600))
        window.rootViewController = host; window.makeKeyAndVisible()
        defer { window.isHidden = true }
        let initial = expectation(description: "report source arrival")
        var events: [ReadingScrollObservation] = []
        var environment = EnvironmentValues()
        host.render(renderID: "active", target: .init(anchorID: "claim/gree-service/known", localOffset: 37),
                    blocks: blocks, environment: environment) { event in
            events.append(event); if case .arrival = event.cause { initial.fulfill() }
        }
        await fulfillment(of: [initial], timeout: 8)
        environment.dynamicTypeSize = .accessibility5
        window.frame.size.width = 280
        host.render(renderID: "active", target: .init(anchorID: "claim/gree-service/known", localOffset: 37),
                    blocks: blocks, environment: environment) { events.append($0) }
        host.view.setNeedsLayout(); host.view.layoutIfNeeded()
        try await Task.sleep(nanoseconds: 150_000_000)
        let heading = try XCTUnwrap(accessibility(in: host.view).first { $0.accessibilityLabel == "我们查到了什么" })
        XCTAssertEqual(heading.accessibilityFrame.minY, -37, accuracy: 1)
        XCTAssertEqual(events.count, 1, "passive native reflow is not a new reading event")
        host.render(renderID: "cancelled", target: .init(anchorID: "report/summary"), blocks: blocks) { events.append($0) }
        host.stopObserving()
        try await Task.sleep(nanoseconds: 100_000_000)
        XCTAssertEqual(events.count, 1, "stopped scope rejects its queued native layout callback")
        let restored = expectation(description: "fresh visible scope restores before browsing")
        host.render(renderID: "cancelled", target: .init(anchorID: "claim/gree-service/known", localOffset: 23), blocks: blocks) { event in
            events.append(event); if case .arrival = event.cause { restored.fulfill() }
        }
        await fulfillment(of: [restored], timeout: 8)
        XCTAssertEqual(events.count, 2)
        XCTAssertEqual(events.last?.position.anchorID, "claim/gree-service/known")
        XCTAssertEqual(try XCTUnwrap(events.last).position.localOffset, 23, accuracy: 1)
    }

    func testCalculationReturnPreservesTheActualUnanchoredVerificationGap() async throws {
        var reader = StudyReader(study: try study()); reader.switchMode(.report)
        guard case .report(let initial) = reader.page else { return XCTFail() }
        let claim = try XCTUnwrap(initial.sections.flatMap(\.claims).first { $0.claim.id == "gree-2026-cash-drivers" })
        let facts = try XCTUnwrap(claim.anchor(for: .facts)).id
        let geometry = ReportFixtureLayout()
        func blocks(_ page: ReportPage) -> [ReportDocumentBlock] {
            ReportReadingBody(page: page, follow: { reader.follow($0) }).blocks.map { block in
                ReportDocumentBlock(id: block.id, anchors: block.anchors) {
                    AnyView(block.content().background(ReportFixtureMarker(id: block.id, layout: geometry)))
                }
            }
        }
        let host = ReportDocumentController()
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 390, height: 600))
        window.rootViewController = host; window.makeKeyAndVisible()
        defer { window.isHidden = true }
        func restore(_ id: String, page: ReportPage, target: ReadingScrollPosition) async throws {
            let arrived = expectation(description: id); var didArrive = false
            host.render(renderID: id, target: target, blocks: blocks(page)) { event in
                switch event.cause {
                case .arrival:
                    if !didArrive { didArrive = true; arrived.fulfill() }
                case .userBrowsing:
                    reader.reportVisiblePosition(page.observation, position: ReadingPosition(anchorID: event.position.anchorID,
                        localOffset: Double(event.position.localOffset)), cause: .userBrowsing)
                }
            }
            await fulfillment(of: [arrived], timeout: 8)
        }
        func calculationButton() throws -> NSObject {
            try XCTUnwrap(accessibility(in: host.view).first {
                $0.accessibilityLabel?.contains("核对这些数字怎么算") == true
            })
        }
        try await restore("facts", page: initial, target: .init(anchorID: facts))
        let gapOffset = try calculationButton().accessibilityFrame.minY + 5
        XCTAssertGreaterThan(gapOffset, 44)
        try await restore("gap", page: initial, target: .init(anchorID: facts, localOffset: gapOffset))
        XCTAssertEqual(try calculationButton().accessibilityFrame.minY, -5, accuracy: 1)
        XCTAssertTrue(host.view.accessibilityScroll(.up))
        XCTAssertTrue(host.view.accessibilityScroll(.down))
        guard case .report(let observed) = reader.page else { return XCTFail() }
        XCTAssertEqual(observed.restorePosition?.anchorID, facts,
                       "the unanchored verification gap belongs to the preceding facts")
        XCTAssertEqual(try XCTUnwrap(observed.restorePosition?.localOffset), Double(gapOffset), accuracy: 1)
        let sourceY = try XCTUnwrap(geometry.markers["claim/gree-2026-cash-drivers"]).convert(.zero, to: window).y
        XCTAssertTrue(try calculationButton().accessibilityActivate())
        guard case .detail(.calculations) = reader.page else { return XCTFail("use the actual resolved calculation action") }
        host.stopObserving(); reader.back()
        guard case .report(let returned) = reader.page else { return XCTFail() }
        XCTAssertNotEqual(returned.observation, initial.observation)
        let target = try XCTUnwrap(returned.restorePosition)
        try await restore("returned-gap", page: returned,
                          target: .init(anchorID: target.anchorID, localOffset: CGFloat(target.localOffset ?? 0)))
        XCTAssertEqual(try XCTUnwrap(geometry.markers["claim/gree-2026-cash-drivers"]).convert(.zero, to: window).y,
                       sourceY, accuracy: 1)
        XCTAssertEqual(try calculationButton().accessibilityFrame.minY, -5, accuracy: 1)
    }

    func testBrowsingAnUnanchoredIndexHeadingRetainsThePrecedingSemanticPosition() async throws {
        var reader = StudyReader(study: try study()); reader.switchMode(.report)
        guard case .report(let page) = reader.page else { return XCTFail() }
        let geometry = ReportFixtureLayout()
        let blocks = ReportReadingBody(page: page, follow: { _ in }).blocks.map { block in
            ReportDocumentBlock(id: block.id, anchors: block.anchors) {
                AnyView(block.content().background(ReportFixtureMarker(id: block.id, layout: geometry)))
            }
        }
        let host = ReportDocumentController()
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 390, height: 600))
        window.rootViewController = host; window.makeKeyAndVisible()
        defer { window.isHidden = true }
        var latest: ReadingScrollObservation?
        func restore(_ id: String, offset: CGFloat) async throws {
            let arrived = expectation(description: id); var didArrive = false
            host.render(renderID: id, target: .init(anchorID: "report/limits", localOffset: offset), blocks: blocks) { event in
                if case .arrival = event.cause, !didArrive { didArrive = true; arrived.fulfill() }
                if case .userBrowsing = event.cause { latest = event }
            }
            await fulfillment(of: [arrived], timeout: 8)
        }
        try await restore("limits", offset: 0)
        let heading = try XCTUnwrap(geometry.markers["dimensions-heading"])
        let offset = heading.convert(.zero, to: window).y + 3
        try await restore("index-gap", offset: offset)
        let sourceY = try XCTUnwrap(geometry.markers["dimensions-heading"]).convert(.zero, to: window).y
        XCTAssertTrue(host.view.accessibilityScroll(.up))
        XCTAssertTrue(host.view.accessibilityScroll(.down))
        XCTAssertEqual(try XCTUnwrap(geometry.markers["dimensions-heading"]).convert(.zero, to: window).y,
                       sourceY, accuracy: 1)
        XCTAssertEqual(latest?.position.anchorID, "report/limits")
        XCTAssertEqual(try XCTUnwrap(latest).position.localOffset, offset, accuracy: 1)
    }

    func testReverseBrowsingIntoAClaimLeadingGapKeepsThePrecedingSectionSource() async throws {
        var reader = StudyReader(study: try study()); reader.switchMode(.report)
        guard case .report(let page) = reader.page else { return XCTFail() }
        let geometry = ReportFixtureLayout()
        let blocks = ReportReadingBody(page: page, follow: { _ in }).blocks.map { block in
            ReportDocumentBlock(id: block.id, anchors: block.anchors) {
                AnyView(block.content().background(ReportFixtureMarker(id: block.id, layout: geometry)))
            }
        }
        let host = ReportDocumentController()
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 390, height: 600))
        window.rootViewController = host; window.makeKeyAndVisible()
        defer { window.isHidden = true }
        let arrived = expectation(description: "arrive inside the first claim")
        var latest: ReadingScrollObservation?
        host.render(renderID: "claim-gap", target: .init(anchorID: "claim/gree-service/heading", localOffset: 473), blocks: blocks) { event in
            if case .arrival = event.cause { arrived.fulfill() }
            if case .userBrowsing = event.cause { latest = event }
        }
        await fulfillment(of: [arrived], timeout: 8)
        XCTAssertTrue(host.view.accessibilityScroll(.up))
        let source = try XCTUnwrap(geometry.markers["claim/gree-service"])
        let sourceY = source.convert(.zero, to: window).y
        XCTAssertGreaterThan(sourceY, 0)
        XCTAssertLessThan(sourceY, 14, "the viewport really starts in the leading gap before the claim")
        let position = try XCTUnwrap(latest).position
        XCTAssertEqual(position.anchorID, "section/responsibility",
                       "the fourteen-point gap before a claim still belongs to the preceding section")
        let returned = expectation(description: "return to the claim leading gap")
        host.render(renderID: "returned-claim-gap", target: position, blocks: blocks) { event in
            if case .arrival = event.cause { returned.fulfill() }
        }
        await fulfillment(of: [returned], timeout: 8)
        XCTAssertEqual(try XCTUnwrap(geometry.markers["claim/gree-service"]).convert(.zero, to: window).y,
                       sourceY, accuracy: 1)
    }

    private func accessibility(in view: UIView) -> [NSObject] {
        var result: [NSObject] = [], visited = Set<ObjectIdentifier>()
        func append(_ object: NSObject) {
            guard visited.insert(ObjectIdentifier(object)).inserted else { return }
            result.append(object)
            object.accessibilityElements?.compactMap { $0 as? NSObject }.forEach(append)
            let count = object.accessibilityElementCount()
            if count > 0 && count < 2_000 {
                for index in 0..<count { if let child = object.accessibilityElement(at: index) as? NSObject { append(child) } }
            }
            if let native = object as? UIView { native.subviews.forEach(append) }
        }
        append(view); return result
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
