import SwiftUI
import XCTest

#if canImport(UIKit)
import UIKit

/// Exercises the renderer as a native host does, with published reading values.
/// Fixtures add coverage without inventing a new research expression.
@MainActor
final class StudyDiagramHostTests: XCTestCase {
    func testAllSixExpressionsUseNaturalHeightInsteadOfFillingTheCanvasProposal() throws {
        for kind in ["relation_graph", "argument", "comparison", "trend", "timeline", "text"] {
            let raw = try fixture(kind)
            let host = UIHostingController(rootView:
                StudyDiagram(view: raw, focus: "node-a", periods: try periods()) { _ in }
                    .frame(width: 320)
            )
            let fitted = host.sizeThatFits(in: CGSize(width: 320, height: 10_000))
            XCTAssertGreaterThan(fitted.height, 44, kind)
            XCTAssertLessThan(fitted.height, 5_000, "\(kind) must report natural content, not consume the proposed screen height")
        }
    }

    func testSelectingOneRelationshipKeepsOtherRelationshipsVisibleAndSelectable() async throws {
        var selection: XCTestExpectation?
        let raw = try fixture("relation_graph")
        let host = UIHostingController(rootView:
            StudyDiagram(view: raw, focus: "edge-ab", periods: try periods()) { id in
                if id == "edge-bc" { selection?.fulfill() }
            }.frame(width: 320)
        )
        let window = show(host, width: 320, height: 900)
        defer { window.isHidden = true }
        await Task.yield()
        host.view.layoutIfNeeded()
        let buttons = accessibility(in: host.view).filter { $0.accessibilityTraits.contains(.button) }
        XCTAssertTrue(buttons.contains { $0.accessibilityLabel?.contains("支付价款") == true })
        let other = try XCTUnwrap(buttons.first { $0.accessibilityLabel?.contains("控制并纳入报表") == true },
                                 "selection must not remove another declared relationship")
        let selected = expectation(description: "the other published relationship can be selected")
        selection = selected
        XCTAssertTrue(other.accessibilityActivate())
        await fulfillment(of: [selected], timeout: 2)
    }

    func testAuthoredRelationshipAndEventNotesRemainReadableAndSelectable() async throws {
        for (kind, notes) in [("relation_graph", ["实际支付", "边界待查"]),
                              ("timeline", ["尚未实际付款"])] {
            let host = UIHostingController(rootView:
                StudyDiagram(view: try fixture(kind), focus: "node-a", periods: try periods()) { _ in }
                    .frame(width: 320)
            )
            let natural = host.sizeThatFits(in: CGSize(width: 320, height: 10_000))
            let window = show(host, width: 320, height: natural.height)
            await Task.yield()
            host.view.layoutIfNeeded()
            let buttons = accessibility(in: host.view).filter { $0.accessibilityTraits.contains(.button) }
            for note in notes {
                let element = try XCTUnwrap(buttons.first { $0.accessibilityLabel?.contains(note) == true },
                                           "\(kind) must retain the authored note: \(note)")
                XCTAssertGreaterThanOrEqual(element.accessibilityFrame.height, 44)
            }
            window.isHidden = true
        }
    }

    func testLongNodeAndAnnotationHaveNativeReadingSpaceInsteadOfFixedClippedCards() async throws {
        let label = String(repeating: "这是需要完整辨认的具体公司与业务角色说明", count: 5)
        let annotation = String(repeating: "这处限制不能因标签较长而被缩小或截断。", count: 5)
        let raw = try fixture("relation_graph", annotation: annotation, nodeLabel: label)
        let host = UIHostingController(rootView:
            StudyDiagram(view: raw, focus: "node-a", periods: try periods()) { _ in }
                .frame(width: 320)
        )
        let fitted = host.sizeThatFits(in: CGSize(width: 320, height: 10_000))
        let window = show(host, width: 320, height: fitted.height + 20)
        defer { window.isHidden = true }
        await Task.yield()
        host.view.layoutIfNeeded()
        let buttons = accessibility(in: host.view).filter { $0.accessibilityTraits.contains(.button) }
        let node = try XCTUnwrap(buttons.first { $0.accessibilityLabel?.contains(label) == true })
        XCTAssertGreaterThanOrEqual(node.accessibilityFrame.width, 120)
        XCTAssertGreaterThan(node.accessibilityFrame.height, 110, "long node text needs a naturally taller card")
        XCTAssertTrue(node.accessibilityLabel?.contains("接收服务") == true, "published subtitle must remain readable")
        let note = try XCTUnwrap(buttons.first { $0.accessibilityLabel?.contains(annotation) == true })
        XCTAssertGreaterThanOrEqual(note.accessibilityFrame.height, 44)
        XCTAssertLessThanOrEqual(note.accessibilityFrame.width, 320)
    }

    func testLargerDynamicTypeGrowsAllSixExpressionsAndRendersTheirFullAnnotation() async throws {
        let annotation = String(repeating: "这是一段需要完整阅读的重要限制。", count: 5)
        for kind in ["relation_graph", "argument", "comparison", "trend", "timeline", "text"] {
            let raw = try fixture(kind, annotation: annotation)
            func host(_ size: DynamicTypeSize) throws -> UIHostingController<AnyView> {
                UIHostingController(rootView: AnyView(
                    StudyDiagram(view: raw, focus: "node-a", periods: try periods()) { _ in }
                        .frame(width: 320).environment(\.dynamicTypeSize, size)
                ))
            }
            let normal = try host(.large).sizeThatFits(in: CGSize(width: 320, height: 10_000))
            let enlarged = try host(.accessibility3)
            let natural = enlarged.sizeThatFits(in: CGSize(width: 320, height: 10_000))
            XCTAssertGreaterThan(natural.height, normal.height * 1.25,
                                 "\(kind) must grow with the reader's text size instead of retaining fixed small fonts")
            let window = show(enlarged, width: 320, height: natural.height)
            await Task.yield()
            enlarged.view.layoutIfNeeded()
            let labels = accessibility(in: enlarged.view).compactMap(\.accessibilityLabel)
            XCTAssertTrue(labels.contains { $0.contains(annotation) }, kind)
            if kind == "text" {
                XCTAssertTrue(labels.contains { $0.contains("接收服务") }, "qualitative text keeps its published subtitle")
            }
            let image = UIGraphicsImageRenderer(bounds: enlarged.view.bounds).image { _ in
                enlarged.view.drawHierarchy(in: enlarged.view.bounds, afterScreenUpdates: true)
            }
            let attachment = XCTAttachment(image: image)
            attachment.name = kind + "-accessibility3"
            attachment.lifetime = .keepAlways
            add(attachment)
            window.isHidden = true
        }
    }

    func testMultipleTrendSeriesShowUnitsAndPeriodsWhileKeepingRealDateSpacing() async throws {
        let raw = try fixture("trend")
        let host = UIHostingController(rootView:
            StudyDiagram(view: raw, focus: "series-sales", periods: try periods()) { _ in }
                .frame(width: 320)
        )
        let natural = host.sizeThatFits(in: CGSize(width: 320, height: 10_000))
        let window = show(host, width: 320, height: natural.height)
        defer { window.isHidden = true }
        await Task.yield()
        host.view.layoutIfNeeded()
        let elements = accessibility(in: host.view)
        let labels = elements.compactMap(\.accessibilityLabel)
        XCTAssertTrue(labels.contains { $0.contains("销售金额") })
        XCTAssertTrue(labels.contains { $0.contains("归母净利润") })
        XCTAssertTrue(labels.contains { $0.contains("亿元") })
        XCTAssertTrue(labels.contains { $0.contains("2020全年") })
        let buttons = elements.filter { $0.accessibilityTraits.contains(.button) }
        let points = try ["2020全年，10亿元", "2021全年，20亿元", "2024全年，15亿元"].map { position in
            try XCTUnwrap(buttons.first { $0.accessibilityLabel == "销售金额，" + position })
        }
        let firstYear = points[1].accessibilityFrame.midX - points[0].accessibilityFrame.midX
        let nextThreeYears = points[2].accessibilityFrame.midX - points[1].accessibilityFrame.midX
        XCTAssertGreaterThan(firstYear, 0)
        XCTAssertGreaterThan(nextThreeYears, firstYear * 2.5)
        XCTAssertLessThan(nextThreeYears, firstYear * 3.5,
                          "2021 to 2024 must retain about three times the spacing of 2020 to 2021")
    }

    func testFullscreenRestoresActualViewportAndConfirmsNewFocusWithoutRecreatingTheScrollView() async throws {
        let raw = try fixture("relation_graph")
        let periods = try periods()
        var requested = DiagramViewport(zoomScale: 2, contentOffset: CGPoint(x: 80, y: 120))
        var displayed: [AnyHashable] = []
        var confirmed: XCTestExpectation?
        var browsed: XCTestExpectation?
        var browsing = 0
        weak var nativeRoot: UIView?
        var focusAtReceipt: String?
        func screen(focus: String, renderID: String) -> AnyView {
            AnyView(DiagramFullscreenView(raw: raw, periods: periods, selectedFocus: focus,
                renderID: renderID, viewport: requested,
                onViewportChange: { viewport, cause in
                    requested = viewport
                    if case .userInteraction = cause { browsing += 1; browsed?.fulfill(); browsed = nil }
                },
                onDisplayed: { id in
                    if id == AnyHashable("focus-b"), let nativeRoot {
                        focusAtReceipt = self.accessibility(in: nativeRoot).first {
                            $0.accessibilityTraits.contains(.button)
                                && $0.accessibilityLabel?.contains("生产与履约公司") == true
                        }?.accessibilityValue
                    }
                    displayed.append(id)
                    confirmed?.fulfill()
                    confirmed = nil
                },
                onSelect: { _ in }, onClose: {}))
        }
        let host = UIHostingController(rootView: screen(focus: "node-a", renderID: "focus-a"))
        host.loadViewIfNeeded()
        nativeRoot = host.view
        host.view.layoutIfNeeded()
        XCTAssertTrue(displayed.isEmpty, "an unattached host cannot confirm a visible diagram")
        let window = show(host, width: 320, height: 480)
        defer { window.isHidden = true }
        await Task.yield()
        host.view.layoutIfNeeded()
        let scroll = try XCTUnwrap(zoomScroll(in: host.view), "fullscreen must use native zoom and pan")
        if !displayed.contains("focus-a") {
            let arrival = expectation(description: "first diagram actually displayed")
            confirmed = arrival
            await fulfillment(of: [arrival], timeout: 4)
        }
        XCTAssertEqual(scroll.zoomScale, 2, accuracy: 0.01)
        XCTAssertEqual(scroll.contentOffset.x, 80, accuracy: 1)
        XCTAssertEqual(scroll.contentOffset.y, 120, accuracy: 1)
        XCTAssertEqual(browsing, 0, "restoration is not user reading")
        let image = UIGraphicsImageRenderer(bounds: host.view.bounds).image { _ in
            host.view.drawHierarchy(in: host.view.bounds, afterScreenUpdates: true)
        }
        let attachment = XCTAttachment(image: image)
        attachment.name = "fullscreen-restored-native-viewport"
        attachment.lifetime = .keepAlways
        add(attachment)
        scroll.setZoomScale(2.5, animated: false)
        await Task.yield()
        XCTAssertEqual(browsing, 0, "a native programmatic zoom is not user reading")
        let didScroll = scroll.accessibilityScroll(.down)
        XCTAssertTrue(didScroll, "the native accessibility action can browse the enlarged diagram")
        if didScroll && browsing == 0 {
            let userScroll = expectation(description: "native accessibility scrolling reports user browsing")
            browsed = userScroll
            await fulfillment(of: [userScroll], timeout: 4)
        }
        XCTAssertGreaterThan(scroll.contentOffset.y, 120)
        let actualAfterBrowsing = DiagramViewport(zoomScale: scroll.zoomScale, contentOffset: scroll.contentOffset)
        let focusChanged = expectation(description: "new focus displayed at unchanged viewport")
        confirmed = focusChanged
        host.rootView = screen(focus: "node-b", renderID: "focus-b")
        host.view.setNeedsLayout()
        host.view.layoutIfNeeded()
        await fulfillment(of: [focusChanged], timeout: 4)
        XCTAssertEqual(displayed.last, AnyHashable("focus-b"))
        XCTAssertEqual(focusAtReceipt, "已选择", "the new semantic focus must already be rendered when it is confirmed")
        XCTAssertTrue(zoomScroll(in: host.view) === scroll)
        XCTAssertEqual(scroll.zoomScale, actualAfterBrowsing.zoomScale, accuracy: 0.01)
        XCTAssertEqual(scroll.contentOffset.y, actualAfterBrowsing.contentOffset.y, accuracy: 1)
        XCTAssertEqual(browsing, 1)
    }

    func testCoveredFullscreenDoesNotConfirmAQueuedDiagramAsVisible() async throws {
        var displayed: [AnyHashable] = []
        let host = UIHostingController(rootView:
            DiagramFullscreenView(raw: try fixture("relation_graph"), periods: try periods(),
                selectedFocus: "node-a", renderID: "covered", viewport: DiagramViewport(),
                onViewportChange: { _, _ in }, onDisplayed: { displayed.append($0) },
                onSelect: { _ in }, onClose: {})
        )
        let window = show(host, width: 320, height: 480)
        defer { window.isHidden = true }
        XCTAssertNotNil(zoomScroll(in: host.view), "the diagram has entered native layout")
        let cover = UIViewController()
        cover.view.backgroundColor = .white
        cover.modalPresentationStyle = .overFullScreen
        await withCheckedContinuation { continuation in
            host.present(cover, animated: false) { continuation.resume() }
        }
        XCTAssertTrue(host.presentedViewController === cover)
        await Task.yield()
        XCTAssertTrue(displayed.isEmpty, "a queued layout cannot confirm content covered by another presentation")
        await withCheckedContinuation { continuation in
            host.dismiss(animated: false) { continuation.resume() }
        }
    }

    func testRemovedFullscreenDropsQueuedCallbacksEvenWhenItsNativeControllersStayAlive() async throws {
        var viewportCallbacks = 0
        var displayCallbacks = 0
        let host = UIHostingController(rootView: AnyView(
            DiagramFullscreenView(raw: try fixture("relation_graph"), periods: try periods(),
                selectedFocus: "node-a", renderID: "removed", viewport: DiagramViewport(),
                onViewportChange: { _, _ in viewportCallbacks += 1 },
                onDisplayed: { _ in displayCallbacks += 1 }, onSelect: { _ in }, onClose: {})
        ))
        let window = show(host, width: 320, height: 480)
        let native = try XCTUnwrap(zoomScroll(in: host.view))
        let retainedControllers = host.children
        native.setContentOffset(CGPoint(x: 0, y: 80), animated: false)
        host.rootView = AnyView(EmptyView())
        host.view.setNeedsLayout()
        host.view.layoutIfNeeded()
        window.isHidden = true
        await withCheckedContinuation { continuation in
            DispatchQueue.main.async { continuation.resume() }
        }
        XCTAssertEqual(viewportCallbacks, 0, "dismantling cancels queued viewport facts without waiting for deinit")
        XCTAssertEqual(displayCallbacks, 0, "removed content cannot confirm a visible diagram")
        withExtendedLifetime(retainedControllers) {}
    }

    func testOnlyLatestContentGenerationCanConfirmDisplayEvenWhenAnIDIsReused() async throws {
        let raw = try fixture("relation_graph")
        let periods = try periods()
        var displayed: [AnyHashable] = []
        func screen(_ id: String, focus: String) -> AnyView {
            AnyView(DiagramFullscreenView(raw: raw, periods: periods,
                selectedFocus: focus, renderID: id, viewport: DiagramViewport(),
                onViewportChange: { _, _ in }, onDisplayed: { displayed.append($0) },
                onSelect: { _ in }, onClose: {}))
        }
        let host = UIHostingController(rootView: screen("a", focus: "node-a"))
        let window = show(host, width: 320, height: 480)
        defer { window.isHidden = true }
        let native = try XCTUnwrap(zoomScroll(in: host.view))
        host.rootView = screen("b", focus: "node-b")
        host.view.setNeedsLayout()
        host.view.layoutIfNeeded()
        host.rootView = screen("a", focus: "node-c")
        host.view.setNeedsLayout()
        host.view.layoutIfNeeded()
        await withCheckedContinuation { continuation in
            DispatchQueue.main.async { continuation.resume() }
        }
        XCTAssertEqual(displayed, [AnyHashable("a")], "an old a receipt must not escape after a → b → a")
        XCTAssertTrue(zoomScroll(in: host.view) === native)
    }

    private func zoomScroll(in view: UIView) -> UIScrollView? {
        if let scroll = view as? UIScrollView, scroll.maximumZoomScale > 1 { return scroll }
        return view.subviews.lazy.compactMap { self.zoomScroll(in: $0) }.first
    }

    private func show<V: View>(_ host: UIHostingController<V>, width: CGFloat, height: CGFloat) -> UIWindow {
        // Match the native reading host: its measured content is already inside
        // the host's safe-area layout, so the renderer receives its full proposal.
        host.safeAreaRegions = []
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: width, height: height))
        window.rootViewController = host
        window.makeKeyAndVisible()
        host.view.setNeedsLayout()
        host.view.layoutIfNeeded()
        return window
    }

    private func accessibility(in view: UIView) -> [NSObject] {
        var result: [NSObject] = []
        var visited = Set<ObjectIdentifier>()
        func append(_ object: NSObject) {
            guard visited.insert(ObjectIdentifier(object)).inserted else { return }
            result.append(object)
            if let children = object.accessibilityElements {
                children.compactMap { $0 as? NSObject }.forEach(append)
            }
            let count = object.accessibilityElementCount()
            if count > 0 && count < 2_000 {
                for index in 0..<count {
                    if let child = object.accessibilityElement(at: index) as? NSObject { append(child) }
                }
            }
            if let native = object as? UIView { native.subviews.forEach(append) }
        }
        append(view)
        return result
    }

    private func periods() throws -> [ResearchPeriod] {
        try decode([
            ["id": "p1", "start": "2020-01-01", "end": "2020-12-31", "kind": "annual", "label": "2020全年"],
            ["id": "p2", "start": "2021-01-01", "end": "2021-12-31", "kind": "annual", "label": "2021全年"],
            ["id": "p3", "start": "2024-01-01", "end": "2024-12-31", "kind": "annual", "label": "2024全年"],
        ])
    }

    private func fixture(_ kind: String, annotation: String = "补充说明", nodeLabel: String = "客户") throws -> ReadingView {
        let nodes: [[String: Any]] = [
            ["id": "a", "subject_id": "a", "label": nodeLabel, "subtitle": "接收服务", "kind": "business_role",
             "focus_id": "node-a", "icon": "person", "row": 0, "column": 0],
            ["id": "b", "subject_id": "b", "label": "生产与履约公司", "subtitle": "承担义务", "kind": "legal_entity",
             "focus_id": "node-b", "icon": "building.2", "row": 1, "column": 1],
            ["id": "c", "subject_id": "c", "label": "报表范围", "subtitle": "合并披露", "kind": "reporting_scope",
             "focus_id": "node-c", "icon": "square.stack", "row": 2, "column": 0],
        ]
        let edges: [[String: Any]] = [
            ["id": "ab", "from_id": "a", "to_id": "b", "label": "支付价款", "kind": "payment",
             "status": "disclosed", "focus_id": "edge-ab", "note": "实际支付"],
            ["id": "bc", "from_id": "b", "to_id": "c", "label": "控制并纳入报表", "kind": "control",
             "status": "unknown", "focus_id": "edge-bc", "note": "边界待查"],
        ]
        func value(_ index: Int, _ display: String) -> [String: Any] {
            ["ref": ["kind": "fact", "id": "value-\(index)"], "label": "第\(index)期",
             "raw_value": (Decimal(string: display)! * 100_000_000).description,
             "raw_unit": "CNY", "display_value": display, "display_unit": "亿元",
             "entity_id": "company", "period_id": "p\(index)",
             "period_label": [1: "2020全年", 2: "2021全年", 3: "2024全年"][index]!, "time_basis": "flow"]
        }
        let series: [[String: Any]] = [
            ["id": "sales", "label": "销售金额", "focus_id": "series-sales", "comparison": "time_series",
             "values": [value(1, "10"), value(2, "20"), value(3, "15")]],
            ["id": "profit", "label": "归母净利润", "focus_id": "series-profit", "comparison": "time_series",
             "values": [value(1, "2"), value(2, "3"), value(3, "1")]],
        ]
        let events: [[String: Any]] = [
            ["id": "event", "label": "董事会提出分配安排，后续仍需批准", "date_label": "2024全年", "stage": "proposed",
             "focus_id": "event-focus", "value_text": "10亿元", "note": "尚未实际付款",
             "observation_ref": ["kind": "observation", "id": "observation", "owner_id": "action"], "date_period_id": "p3"],
        ]
        return try decode([
            "id": "fixture-" + kind, "kind": kind, "title": "同一份正式图形", "caption": "数据与解释身份保持不变",
            "nodes": ["relation_graph", "argument", "text"].contains(kind) ? nodes : [],
            "edges": ["relation_graph", "argument"].contains(kind) ? edges : [],
            "series": ["comparison", "trend"].contains(kind) ? series : [],
            "events": kind == "timeline" ? events : [],
            "annotations": [["id": "annotation", "label": annotation, "icon": "info.circle", "focus_id": "annotation-focus"]],
            "notes": ["保留限制及原始含义。"],
        ])
    }

    private func decode<T: Decodable>(_ value: Any) throws -> T {
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        return try decoder.decode(T.self, from: JSONSerialization.data(withJSONObject: value))
    }
}
#endif
