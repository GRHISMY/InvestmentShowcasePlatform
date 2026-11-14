import SwiftUI

#if canImport(UIKit)
import UIKit
#else
import AppKit
#endif

struct ReadingScrollPosition: Equatable {
    let anchorID: String
    var localOffset: CGFloat = 0
}

struct ReadingScrollObservation {
    enum Cause { case arrival, userBrowsing }
    let renderID: AnyHashable
    let position: ReadingScrollPosition
    let cause: Cause
}

struct ReadingScrollView<Content: View>: View {
    let renderID: AnyHashable
    let target: ReadingScrollPosition?
    let onObservation: (ReadingScrollObservation) -> Void
    private let content: Content

    init(renderID: AnyHashable, target: ReadingScrollPosition?,
         onObservation: @escaping (ReadingScrollObservation) -> Void,
         @ViewBuilder content: () -> Content) {
        self.renderID = renderID
        self.target = target
        self.onObservation = onObservation
        self.content = content()
    }

    var body: some View {
        NativeReadingScroll(renderID: renderID, target: target,
                            content: AnyView(content), onObservation: onObservation)
    }
}

extension View {
    func readingAnchor(id: String) -> some View { modifier(ReadingAnchorModifier(id: id)) }
}

private struct ReadingDocumentScope {
    let renderID: AnyHashable
    let coordinateSpace = UUID()
}

private struct ReadingDocumentScopeKey: EnvironmentKey {
    static let defaultValue: ReadingDocumentScope? = nil
}

private extension EnvironmentValues {
    var readingDocumentScope: ReadingDocumentScope? {
        get { self[ReadingDocumentScopeKey.self] }
        set { self[ReadingDocumentScopeKey.self] = newValue }
    }
}

private struct MeasuredReadingAnchor: Equatable {
    let renderID: AnyHashable
    let id: String
    let frame: CGRect
}

private struct ReadingAnchorFramesKey: PreferenceKey {
    static var defaultValue: [MeasuredReadingAnchor] { [] }
    static func reduce(value: inout [MeasuredReadingAnchor], nextValue: () -> [MeasuredReadingAnchor]) {
        value.append(contentsOf: nextValue())
    }
}

private struct ReadingAnchorModifier: ViewModifier {
    let id: String
    @Environment(\.readingDocumentScope) private var scope

    func body(content: Content) -> some View {
        content.background {
            if let scope {
                GeometryReader { geometry in
                    Color.clear.preference(key: ReadingAnchorFramesKey.self,
                        value: [MeasuredReadingAnchor(renderID: scope.renderID, id: id,
                            frame: geometry.frame(in: .named(scope.coordinateSpace)))])
                }
            }
        }
    }
}

private struct ReadingScrollDocument: View {
    let content: AnyView
    let scope: ReadingDocumentScope
    let environment: EnvironmentValues?
    let onFrames: ([MeasuredReadingAnchor]) -> Void

    var body: some View {
        if let environment { document.environment(\.self, environment) }
        else { document }
    }

    private var document: some View {
        content.frame(maxWidth: .infinity, alignment: .topLeading)
            .fixedSize(horizontal: false, vertical: true)
            .environment(\.readingDocumentScope, scope)
            .coordinateSpace(name: scope.coordinateSpace)
            .onPreferenceChange(ReadingAnchorFramesKey.self, perform: onFrames)
    }
}

/// Render identity changes invalidate old geometry. A target belongs to that render,
/// so ordinary redraws never fight a reader's subsequent scroll position.
private final class ReadingScrollState {
    var scope: ReadingDocumentScope?
    var target: ReadingScrollPosition?
    var anchors: [MeasuredReadingAnchor] = []
    var arrived = false
    var onObservation: (ReadingScrollObservation) -> Void = { _ in }

    func configure(renderID: AnyHashable, target: ReadingScrollPosition?,
                   onObservation: @escaping (ReadingScrollObservation) -> Void) {
        if scope?.renderID != renderID {
            scope = ReadingDocumentScope(renderID: renderID)
            self.target = target
            anchors = []
            arrived = false
        }
        self.onObservation = onObservation
    }

    func accept(_ frames: [MeasuredReadingAnchor]) {
        anchors = frames.filter { $0.renderID == scope?.renderID && $0.frame.height > 0 && $0.frame.width > 0 }
            .sorted { $0.frame.minY < $1.frame.minY }
    }

    func targetOffset(maximum: CGFloat) -> CGFloat? {
        guard !anchors.isEmpty else { return nil }
        guard let target else { return 0 }
        guard let anchor = anchors.first(where: { $0.id == target.anchorID }) else { return nil }
        let offset = target.localOffset.isFinite ? max(0, target.localOffset) : 0
        return min(maximum, max(0, anchor.frame.minY + offset))
    }

    func observation(in viewport: CGRect, cause: ReadingScrollObservation.Cause) -> ReadingScrollObservation? {
        guard let scope, let anchor = anchors.first(where: { $0.frame.intersects(viewport) }) else { return nil }
        return ReadingScrollObservation(renderID: scope.renderID,
            position: ReadingScrollPosition(anchorID: anchor.id, localOffset: max(0, viewport.minY - anchor.frame.minY)),
            cause: cause)
    }
}

#if canImport(UIKit)
private final class ReadingNativeScrollView: UIScrollView {
    var onLayoutStarted: (() -> Void)?
    var onLayout: (() -> Void)?
    var onAccessibilityBrowsing: (() -> Void)?
    override func layoutSubviews() {
        onLayoutStarted?()
        super.layoutSubviews()
        onLayout?()
    }

    override func accessibilityScroll(_ direction: UIAccessibilityScrollDirection) -> Bool {
        let step: CGFloat
        switch direction {
        case .down: step = bounds.height * 0.8
        case .up: step = -bounds.height * 0.8
        default: return super.accessibilityScroll(direction)
        }
        let target = min(max(0, contentSize.height - bounds.height), max(0, contentOffset.y + step))
        guard target != contentOffset.y else { return false }
        setContentOffset(CGPoint(x: contentOffset.x, y: target), animated: false)
        layoutIfNeeded()
        onAccessibilityBrowsing?()
        UIAccessibility.post(notification: .pageScrolled, argument: nil)
        return true
    }
}

@MainActor
final class ReadingScrollController: UIViewController, UIScrollViewDelegate {
    private let scroll = ReadingNativeScrollView()
    private let hosting = UIHostingController(rootView: AnyView(EmptyView()))
    private let reading = ReadingScrollState()
    private var positioning = false
    private var layingOut = false

    override func loadView() {
        view = scroll
        scroll.backgroundColor = .clear
        scroll.contentInsetAdjustmentBehavior = .never
        scroll.delegate = self
        scroll.onLayoutStarted = { [weak self] in self?.layingOut = true }
        scroll.onLayout = { [weak self] in
            self?.layingOut = false
            self?.confirmArrival()
        }
        scroll.onAccessibilityBrowsing = { [weak self] in self?.reportUserBrowsing() }
        hosting.sizingOptions = [.intrinsicContentSize]
        hosting.safeAreaRegions = []
        addChild(hosting)
        hosting.view.backgroundColor = .clear
        hosting.view.translatesAutoresizingMaskIntoConstraints = false
        scroll.addSubview(hosting.view)
        NSLayoutConstraint.activate([
            hosting.view.leadingAnchor.constraint(equalTo: scroll.contentLayoutGuide.leadingAnchor),
            hosting.view.trailingAnchor.constraint(equalTo: scroll.contentLayoutGuide.trailingAnchor),
            hosting.view.topAnchor.constraint(equalTo: scroll.contentLayoutGuide.topAnchor),
            hosting.view.bottomAnchor.constraint(equalTo: scroll.contentLayoutGuide.bottomAnchor),
            hosting.view.widthAnchor.constraint(equalTo: scroll.frameLayoutGuide.widthAnchor)
        ])
        hosting.didMove(toParent: self)
    }

    func render(renderID: AnyHashable, target: ReadingScrollPosition?, content: AnyView,
                environment: EnvironmentValues? = nil,
                onObservation: @escaping (ReadingScrollObservation) -> Void) {
        loadViewIfNeeded()
        reading.configure(renderID: renderID, target: target, onObservation: onObservation)
        guard let scope = reading.scope else { return }
        hosting.rootView = AnyView(ReadingScrollDocument(content: content, scope: scope, environment: environment,
            onFrames: { [weak self] frames in
                guard let self, self.reading.scope?.renderID == scope.renderID else { return }
                self.reading.accept(frames)
                DispatchQueue.main.async { [weak self] in self?.confirmArrival() }
            }))
        hosting.view.invalidateIntrinsicContentSize()
        view.setNeedsLayout()
    }

    private var hasVisibleLayout: Bool {
        guard let window = view.window, !window.isHidden,
              scroll.bounds.width > 0, scroll.bounds.height > 0,
              hosting.view.bounds.height > 0, scroll.contentSize.height > 0 else { return false }
        var ancestor: UIView? = view
        while let current = ancestor {
            if current.isHidden || current.alpha == 0 { return false }
            ancestor = current.superview
        }
        return true
    }

    private func confirmArrival() {
        guard !positioning, !reading.arrived, hasVisibleLayout,
              let offset = reading.targetOffset(maximum: max(0, scroll.contentSize.height - scroll.bounds.height)) else { return }
        positioning = true
        scroll.setContentOffset(CGPoint(x: 0, y: offset), animated: false)
        scroll.layoutIfNeeded()
        positioning = false
        let viewport = CGRect(origin: scroll.contentOffset, size: scroll.bounds.size)
        guard let observation = reading.observation(in: viewport, cause: .arrival) else { return }
        reading.arrived = true
        reading.onObservation(observation)
    }

    func scrollViewDidScroll(_ scrollView: UIScrollView) {
        guard !layingOut, scrollView.isTracking || scrollView.isDragging || scrollView.isDecelerating else { return }
        reportUserBrowsing()
    }

    func scrollViewDidEndDragging(_ scrollView: UIScrollView, willDecelerate decelerate: Bool) {
        if !decelerate { reportUserBrowsing() }
    }

    func scrollViewDidEndDecelerating(_ scrollView: UIScrollView) { reportUserBrowsing() }
    func scrollViewDidScrollToTop(_ scrollView: UIScrollView) { reportUserBrowsing() }

    private func reportUserBrowsing() {
        guard !positioning, reading.arrived, hasVisibleLayout,
              let observation = reading.observation(in: CGRect(origin: scroll.contentOffset, size: scroll.bounds.size), cause: .userBrowsing) else { return }
        reading.onObservation(observation)
    }

    func stopObserving() {
        reading.onObservation = { _ in }
        scroll.delegate = nil
    }
}

private struct NativeReadingScroll: UIViewControllerRepresentable {
    let renderID: AnyHashable
    let target: ReadingScrollPosition?
    let content: AnyView
    let onObservation: (ReadingScrollObservation) -> Void

    func makeUIViewController(context: Context) -> ReadingScrollController { ReadingScrollController() }
    func updateUIViewController(_ controller: ReadingScrollController, context: Context) {
        controller.render(renderID: renderID, target: target, content: content,
                          environment: context.environment, onObservation: onObservation)
    }
    static func dismantleUIViewController(_ controller: ReadingScrollController, coordinator: ()) {
        controller.stopObserving()
    }
}
#else
private final class ReadingMacScrollView: NSScrollView {
    var onLayout: (() -> Void)?

    override func layout() {
        super.layout()
        onLayout?()
    }
}

@MainActor
final class ReadingScrollController: NSViewController {
    private let scroll = ReadingMacScrollView()
    private let hosting = NSHostingView(rootView: AnyView(EmptyView()))
    private let reading = ReadingScrollState()
    private var positioning = false
    private var observers: [NSObjectProtocol] = []

    override func loadView() {
        view = scroll
        scroll.drawsBackground = false
        scroll.borderType = .noBorder
        scroll.hasVerticalScroller = true
        scroll.hasHorizontalScroller = false
        scroll.autohidesScrollers = true
        scroll.automaticallyAdjustsContentInsets = false
        scroll.contentInsets = .init()
        hosting.sizingOptions = [.intrinsicContentSize]
        hosting.safeAreaRegions = []
        hosting.translatesAutoresizingMaskIntoConstraints = false
        hosting.setContentHuggingPriority(.defaultLow, for: .horizontal)
        hosting.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        scroll.documentView = hosting
        NSLayoutConstraint.activate([
            hosting.leadingAnchor.constraint(equalTo: scroll.contentView.leadingAnchor),
            hosting.topAnchor.constraint(equalTo: scroll.contentView.topAnchor),
            hosting.widthAnchor.constraint(equalTo: scroll.contentView.widthAnchor)
        ])
        scroll.onLayout = { [weak self] in self?.confirmArrival() }
        scroll.contentView.postsBoundsChangedNotifications = true
        observers.append(NotificationCenter.default.addObserver(forName: NSView.boundsDidChangeNotification,
            object: scroll.contentView, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.confirmArrival() }
            })
        observers.append(NotificationCenter.default.addObserver(forName: NSScrollView.didLiveScrollNotification,
            object: scroll, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.reportUserBrowsing() }
            })
    }

    override func viewDidAppear() {
        super.viewDidAppear()
        confirmArrival()
    }

    func render(renderID: AnyHashable, target: ReadingScrollPosition?, content: AnyView,
                environment: EnvironmentValues? = nil,
                onObservation: @escaping (ReadingScrollObservation) -> Void) {
        _ = view
        reading.configure(renderID: renderID, target: target, onObservation: onObservation)
        guard let scope = reading.scope else { return }
        hosting.rootView = AnyView(ReadingScrollDocument(content: content, scope: scope, environment: environment,
            onFrames: { [weak self] frames in
                guard let self, self.reading.scope?.renderID == scope.renderID else { return }
                self.reading.accept(frames)
                DispatchQueue.main.async { [weak self] in self?.confirmArrival() }
            }))
        hosting.invalidateIntrinsicContentSize()
        view.needsLayout = true
    }

    private var hasVisibleLayout: Bool {
        guard let window = view.window, window.isVisible, !view.isHiddenOrHasHiddenAncestor,
              scroll.contentView.bounds.width > 0, scroll.contentView.bounds.height > 0,
              hosting.bounds.width > 0, hosting.bounds.height > 0 else { return false }
        return true
    }

    private func confirmArrival() {
        guard !positioning, !reading.arrived, hasVisibleLayout,
              let offset = reading.targetOffset(maximum: max(0, hosting.bounds.height - scroll.contentView.bounds.height)) else { return }
        positioning = true
        scroll.contentView.scroll(to: NSPoint(x: 0, y: offset))
        scroll.reflectScrolledClipView(scroll.contentView)
        scroll.layoutSubtreeIfNeeded()
        positioning = false
        guard let observation = reading.observation(in: scroll.documentVisibleRect, cause: .arrival) else { return }
        reading.arrived = true
        reading.onObservation(observation)
    }

    private func reportUserBrowsing() {
        guard !positioning, reading.arrived, hasVisibleLayout,
              let observation = reading.observation(in: scroll.documentVisibleRect, cause: .userBrowsing) else { return }
        reading.onObservation(observation)
    }

    func stopObserving() {
        reading.onObservation = { _ in }
        for observer in observers { NotificationCenter.default.removeObserver(observer) }
        observers = []
    }

    deinit {
        for observer in observers { NotificationCenter.default.removeObserver(observer) }
    }
}

private struct NativeReadingScroll: NSViewControllerRepresentable {
    let renderID: AnyHashable
    let target: ReadingScrollPosition?
    let content: AnyView
    let onObservation: (ReadingScrollObservation) -> Void
    func makeNSViewController(context: Context) -> ReadingScrollController { ReadingScrollController() }
    func updateNSViewController(_ controller: ReadingScrollController, context: Context) {
        controller.render(renderID: renderID, target: target, content: content,
                          environment: context.environment, onObservation: onObservation)
    }
    static func dismantleNSViewController(_ controller: ReadingScrollController, coordinator: ()) {
        controller.stopObserving()
    }
}
#endif
