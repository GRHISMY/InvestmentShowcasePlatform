import SwiftUI
import XCTest
#if canImport(UIKit)
import UIKit

/// Exercises the native selection boundary used by the production TabView.
@MainActor
final class NativeWorkspaceTabHostTests: XCTestCase {
    func testIPadNativeTabsStayAtTheBottomInPortraitAndLandscape() throws {
        guard UIDevice.current.userInterfaceIdiom == .pad else { throw XCTSkip("iPad native layout") }
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launch()
        defer { XCUIDevice.shared.orientation = .portrait }
        let bar = app.tabBars.firstMatch
        XCTAssertTrue(bar.waitForExistence(timeout: 5), "The app exposes a system bottom tab bar on iPad")
        bar.buttons["workspace-tab-library"].tap()
        let open = app.buttons.matching(identifier: "library-open-current").firstMatch
        if open.waitForExistence(timeout: 3) { open.tap() }

        for (orientation, name) in [(UIDeviceOrientation.portrait, "portrait"), (.landscapeLeft, "landscape")] {
            XCUIDevice.shared.orientation = orientation
            for destination in ["library", "diagram", "report"] {
                let item = bar.buttons["workspace-tab-" + destination]
                XCTAssertTrue(item.waitForExistence(timeout: 5))
                item.tap()
                XCTAssertTrue(item.isSelected)
                XCTAssertGreaterThan(bar.frame.minY, app.frame.midY,
                                     "The native tab bar remains below the reading content")
                for identifier in ["library", "diagram", "report"] {
                    XCTAssertTrue(bar.buttons["workspace-tab-" + identifier].exists)
                }
                let screenshot = XCTAttachment(screenshot: app.screenshot())
                screenshot.name = "iPad-bottom-tabs-" + name + "-" + destination
                screenshot.lifetime = .keepAlways
                add(screenshot)
            }
        }
    }

    func testIPadReadingContentKeepsTheAvailableWidthAcrossNativeTabLayout() async throws {
        guard UIDevice.current.userInterfaceIdiom == .pad else { throw XCTSkip("iPad native layout") }
        let host = UIHostingController(rootView: scenario(blocked: false))
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 1024, height: 1366))
        host.traitOverrides.userInterfaceIdiom = .pad
        host.traitOverrides.horizontalSizeClass = .regular
        window.rootViewController = host
        window.makeKeyAndVisible()
        defer { window.isHidden = true }
        await Task.yield()
        host.view.layoutIfNeeded()
        let tabs = try XCTUnwrap(findTabs(in: host))

        XCTAssertEqual(selectedContent(in: tabs)?.traitCollection.horizontalSizeClass, .regular,
                       "The reading content must retain the iPad's available width")

        host.traitOverrides.horizontalSizeClass = .compact
        await Task.yield()
        host.view.layoutIfNeeded()
        XCTAssertEqual(selectedContent(in: tabs)?.traitCollection.horizontalSizeClass, .compact,
                       "A resized iPad window must also restore the content's compact width")
    }

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

    private func selectedContent(in tabs: UITabBarController) -> UIViewController? {
        if #available(iOS 18, *), let selected = tabs.selectedTab { return selected.viewController }
        return tabs.selectedViewController
    }
}
#endif
