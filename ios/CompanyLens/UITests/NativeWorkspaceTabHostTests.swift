import SwiftUI
import XCTest
#if canImport(UIKit)
import UIKit

/// Exercises the native selection boundary used by the production TabView.
@MainActor
final class NativeWorkspaceTabHostTests: XCTestCase {
    func testNativeSelectionIsRejectedBeforeAnOverlayCanChangeTheHighlightedTab() async throws {
        let host = UIHostingController(rootView: scenario(blocked: true))
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 390, height: 844))
        window.rootViewController = host
        window.makeKeyAndVisible()
        defer { window.isHidden = true }
        await Task.yield()
        host.view.layoutIfNeeded()
        let tabs = try XCTUnwrap(findTabs(in: host))
        let shouldSelectReport: () -> Bool?
        if #available(iOS 18, *), let report = tabs.tabs.last {
            shouldSelectReport = { tabs.delegate?.tabBarController?(tabs, shouldSelectTab: report) }
        } else {
            let report = try XCTUnwrap(tabs.viewControllers?.last)
            shouldSelectReport = { tabs.delegate?.tabBarController?(tabs, shouldSelect: report) }
        }
        let original = tabs.tabBar.selectedItem
        XCTAssertEqual(tabs.tabBar.items?.map(\.accessibilityIdentifier),
                       ["workspace-tab-library", "workspace-tab-diagram", "workspace-tab-report"])
        XCTAssertEqual(shouldSelectReport(), false,
                       "UIKit must reject the tap before it optimistically selects another native item")
        XCTAssertTrue(tabs.tabBar.selectedItem === original)

        host.rootView = scenario(blocked: false)
        await Task.yield()
        host.view.layoutIfNeeded()
        XCTAssertEqual(shouldSelectReport(), true,
                       "closing the overlay enables the normal SwiftUI selection binding again")
    }

    private func scenario(blocked: Bool) -> some View {
        TabView {
            Text("研究库").tabItem { Label("研究库", systemImage: "books.vertical") }
            Text("图解").tabItem { Label("图解", systemImage: "point.3.connected.trianglepath.dotted") }
            Text("报告").tabItem { Label("报告", systemImage: "doc.text") }
        }
        .background(NativeTabNavigationGuard(isBlocked: blocked,
            itemIdentifiers: ["workspace-tab-library", "workspace-tab-diagram", "workspace-tab-report"]))
    }

    private func findTabs(in controller: UIViewController) -> UITabBarController? {
        if let tabs = controller as? UITabBarController { return tabs }
        for child in controller.children { if let tabs = findTabs(in: child) { return tabs } }
        return nil
    }
}
#endif
