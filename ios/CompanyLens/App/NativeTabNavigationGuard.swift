import SwiftUI
#if canImport(UIKit)
import UIKit

/// Reject a background native selection before UIKit optimistically highlights
/// it. SwiftUI still owns the TabView and its selection binding.
struct NativeTabNavigationGuard: UIViewControllerRepresentable {
    let isBlocked: Bool
    var itemIdentifiers: [String] = []
    func makeUIViewController(context: Context) -> Controller { Controller() }
    func updateUIViewController(_ controller: Controller, context: Context) {
        controller.proxy.isBlocked = isBlocked
        controller.itemIdentifiers = itemIdentifiers
        controller.install()
    }
    static func dismantleUIViewController(_ controller: Controller, coordinator: ()) { controller.uninstall() }

    final class Controller: UIViewController {
        let proxy = Delegate()
        var itemIdentifiers: [String] = []
        weak var installedOn: UITabBarController?
        override func viewDidAppear(_ animated: Bool) { super.viewDidAppear(animated); install() }
        override func didMove(toParent parent: UIViewController?) { super.didMove(toParent: parent); install() }
        override func viewDidLayoutSubviews() { super.viewDidLayoutSubviews(); install() }
        func install() {
            guard let controller = tabBarController ?? findTabController(in: parent) else { return }
            for (item, identifier) in zip(controller.tabBar.items ?? [], itemIdentifiers) {
                item.accessibilityIdentifier = identifier
            }
            if #available(iOS 18, *) {
                for (tab, identifier) in zip(controller.tabs, itemIdentifiers) {
                    tab.accessibilityIdentifier = identifier
                }
            }
            if controller.delegate !== proxy {
                proxy.forwarded = controller.delegate
                controller.delegate = proxy
            }
            installedOn = controller
        }
        private func findTabController(in controller: UIViewController?) -> UITabBarController? {
            guard let controller else { return nil }
            if let tabs = controller as? UITabBarController { return tabs }
            for child in controller.children {
                if let tabs = findTabController(in: child) { return tabs }
            }
            return nil
        }
        func uninstall() {
            if installedOn?.delegate === proxy { installedOn?.delegate = proxy.forwarded }
        }
    }
    final class Delegate: NSObject, UITabBarControllerDelegate {
        var isBlocked = false
        weak var forwarded: UITabBarControllerDelegate?
        func tabBarController(_ controller: UITabBarController, shouldSelect viewController: UIViewController) -> Bool {
            guard !isBlocked else { return false }
            return forwarded?.tabBarController?(controller, shouldSelect: viewController) ?? true
        }
        @available(iOS 18, *)
        func tabBarController(_ controller: UITabBarController, shouldSelectTab tab: UITab) -> Bool {
            guard !isBlocked else { return false }
            return forwarded?.tabBarController?(controller, shouldSelectTab: tab) ?? true
        }
        override func responds(to selector: Selector!) -> Bool {
            super.responds(to: selector) || forwarded?.responds(to: selector) == true
        }
        override func forwardingTarget(for selector: Selector!) -> Any? {
            forwarded?.responds(to: selector) == true ? forwarded : super.forwardingTarget(for: selector)
        }
    }
}
#else
struct NativeTabNavigationGuard: View {
    let isBlocked: Bool
    var itemIdentifiers: [String] = []
    var body: some View { EmptyView() }
}
#endif
