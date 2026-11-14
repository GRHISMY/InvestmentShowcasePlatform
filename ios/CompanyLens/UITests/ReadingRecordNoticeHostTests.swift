import SwiftUI
import XCTest

#if canImport(UIKit)
import UIKit

@MainActor
final class ReadingRecordNoticeHostTests: XCTestCase {
    func testAnUnsavedLocalPositionIsVisibleAndCanBeRetriedWhileReading() async throws {
        var state = ShelfRecordState()
        state.local = .unsaved("磁盘空间不足")
        state.cloud = .pending
        var retried: XCTestExpectation?
        let host = UIHostingController(rootView: ReadingRecordNotice(state: state) { retried?.fulfill() })
        let window = show(host)
        defer { window.isHidden = true }
        await Task.yield()
        host.view.layoutIfNeeded()
        let elements = accessibility(in: host.view)
        let labels = elements.compactMap(\.accessibilityLabel)
        XCTAssertTrue(labels.contains { $0.contains("本机") && $0.contains("尚未") },
                      "active reading must explain that its latest local position is not saved")
        XCTAssertTrue(labels.contains { $0.contains("磁盘空间不足") }, "the actual local failure remains available")
        let retry = try XCTUnwrap(elements.first {
            $0.accessibilityTraits.contains(.button) && $0.accessibilityLabel?.contains("重试") == true
        }, "the reader can retry without returning to the library")
        let action = expectation(description: "the reading host receives the retry action")
        retried = action
        XCTAssertTrue(retry.accessibilityActivate())
        await fulfillment(of: [action], timeout: 2)
    }

    func testCloudFailureKeepsTheLocalSavedFactAndHasItsOwnRetry() async throws {
        var state = ShelfRecordState()
        state.local = .saved
        state.cloud = .failed("iCloud暂时无法连接")
        var retried: XCTestExpectation?
        let host = UIHostingController(rootView: ReadingRecordNotice(state: state) { retried?.fulfill() })
        let window = show(host)
        defer { window.isHidden = true }
        await Task.yield()
        host.view.layoutIfNeeded()
        let elements = accessibility(in: host.view)
        let labels = elements.compactMap(\.accessibilityLabel)
        XCTAssertTrue(labels.contains { $0.contains("本机") && $0.contains("已保存") },
                      "the reader knows the local position survived the cloud failure")
        XCTAssertTrue(labels.contains { $0.contains("同步") && $0.contains("尚未") })
        XCTAssertFalse(labels.contains { $0.contains("尚未成功保存") }, "cloud failure must not claim that local saving failed")
        XCTAssertTrue(labels.contains { $0.contains("iCloud暂时无法连接") })
        let retry = try XCTUnwrap(elements.first {
            $0.accessibilityTraits.contains(.button) && $0.accessibilityLabel?.contains("重试") == true
                && $0.accessibilityLabel?.contains("同步") == true
        })
        let action = expectation(description: "the reading host receives the cloud retry action")
        retried = action
        XCTAssertTrue(retry.accessibilityActivate())
        await fulfillment(of: [action], timeout: 2)
    }

    func testOrdinaryRecordStatesLeaveTheActualSafeAreaReadingViewportUnchanged() async throws {
        func reading() -> some View {
            VStack(spacing: 0) {
                Text("研究标题").frame(height: 72)
                Text("图解阅读 / 完整报告").frame(height: 60)
                ReadingScrollView(renderID: "reading", target: nil, onObservation: { _ in }) {
                    Text("正文仍可继续阅读").frame(maxWidth: .infinity, minHeight: 2_000)
                        .readingAnchor(id: "body")
                }
            }
            .frame(maxWidth: 680, maxHeight: .infinity)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        let baseline = UIHostingController(rootView: reading())
        let baselineWindow = show(baseline, height: 600)
        await Task.yield()
        baseline.view.layoutIfNeeded()
        let expected = try XCTUnwrap(scrollView(in: baseline.view)).bounds.height
        XCTAssertEqual(expected, 468, accuracy: 1)
        baselineWindow.isHidden = true

        for local in [ShelfLocalRecordState.saved, .saving] {
            for cloud in [ShelfCloudRecordState.waitingForConnection, .pending, .exchanging, .accepted] {
                var state = ShelfRecordState()
                state.local = local
                state.cloud = cloud
                let host = UIHostingController(rootView: reading().safeAreaInset(edge: .bottom, spacing: 0) {
                    ReadingRecordNotice(state: state, onRetry: {})
                })
                let window = show(host, height: 600)
                await Task.yield()
                host.view.layoutIfNeeded()
                let actual = try XCTUnwrap(scrollView(in: host.view))
                XCTAssertEqual(actual.bounds.height, expected, accuracy: 1,
                               "normal saving or exchange states cannot consume the active reader's safe-area viewport")
                XCTAssertGreaterThan(actual.contentSize.height, actual.bounds.height)
                XCTAssertFalse(accessibility(in: host.view).contains {
                    $0.accessibilityTraits.contains(.button) && $0.accessibilityLabel?.contains("重试") == true
                })
                window.isHidden = true
            }
        }
    }

    func testRecordFailureAndRecoveryPreserveTheRetargetedReadersViewport() async throws {
        func screen(_ state: ShelfRecordState, render: Int) -> AnyView {
            AnyView(VStack(spacing: 0) {
                Text("研究标题").frame(height: 72)
                Text("图解阅读 / 完整报告").frame(height: 60)
                ReadingScrollView(renderID: render,
                    target: ReadingScrollPosition(anchorID: "body", localOffset: 80), onObservation: { _ in }) {
                    Text("正文 \(render)").frame(maxWidth: .infinity, minHeight: 2_000)
                        .readingAnchor(id: "body")
                }
            }
            .frame(maxWidth: 680, maxHeight: .infinity)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .safeAreaInset(edge: .bottom, spacing: 0) { ReadingRecordNotice(state: state, onRetry: {}) })
        }
        let host = UIHostingController(rootView: screen(ShelfRecordState(), render: 0))
        let window = show(host, height: 600)
        defer { window.isHidden = true }
        await Task.yield()
        host.view.layoutIfNeeded()
        let baseline = try XCTUnwrap(scrollView(in: host.view)).bounds.height
        XCTAssertEqual(baseline, 468, accuracy: 1)
        var unsaved = ShelfRecordState()
        unsaved.local = .unsaved("磁盘空间不足")
        var cloudFailure = ShelfRecordState()
        cloudFailure.cloud = .failed("iCloud暂时无法连接")
        for (index, state) in [unsaved, ShelfRecordState(), cloudFailure, ShelfRecordState()].enumerated() {
            host.rootView = screen(state, render: index + 1)
            host.view.setNeedsLayout()
            host.view.layoutIfNeeded()
            await Task.yield()
            host.view.layoutIfNeeded()
            let scroll = try XCTUnwrap(scrollView(in: host.view))
            XCTAssertGreaterThan(scroll.bounds.height, 200, "a failure notice keeps the active body readable")
            if state.local == .saved, state.cloud != cloudFailure.cloud {
                XCTAssertEqual(scroll.bounds.height, baseline, accuracy: 1,
                               "recovering removes the notice's full reserved space")
            }
        }
    }

    private func scrollView(in view: UIView) -> UIScrollView? {
        if let scroll = view as? UIScrollView { return scroll }
        return view.subviews.lazy.compactMap { self.scrollView(in: $0) }.first
    }

    private func show<V: View>(_ host: UIHostingController<V>, height: CGFloat = 260) -> UIWindow {
        host.safeAreaRegions = []
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 320, height: height))
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
}
#endif
