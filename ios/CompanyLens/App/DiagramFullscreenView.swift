import SwiftUI
#if SWIFT_PACKAGE
import ResearchCore
#endif
#if canImport(UIKit)
import UIKit
#else
import AppKit
#endif

/// Presentation geometry only. The caller owns its lifetime and source-visit policy.
struct DiagramViewport: Equatable {
    var zoomScale: CGFloat = 1
    var contentOffset: CGPoint = .zero
}

enum DiagramViewportCause: Equatable {
    case restoration, layout, userInteraction
}

struct DiagramFullscreenView: View {
    @Environment(\.readingObservationEnabled) private var observationEnabled
    let raw: ReadingView
    let periods: [ResearchPeriod]
    let selectedFocus: String
    let renderID: AnyHashable
    let viewport: DiagramViewport
    let onViewportChange: (DiagramViewport, DiagramViewportCause) -> Void
    let onDisplayed: (AnyHashable) -> Void
    let onSelect: (String) -> Void
    let onClose: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Spacer()
                Button(action: onClose) {
                    Label("关闭", systemImage: "xmark")
                        .labelStyle(.iconOnly)
                        .frame(minWidth: 44, minHeight: 44)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel("关闭全屏图解")
            }
            .padding(.horizontal, 12)

            if observationEnabled {
                DiagramNativeViewport(
                    content: AnyView(StudyDiagram(
                        view: raw, focus: selectedFocus, periods: periods,
                        allowsHorizontalScroll: false, onSelect: onSelect
                    )),
                    viewport: viewport,
                    renderID: renderID,
                    onDisplayed: onDisplayed,
                    onViewportChange: onViewportChange
                )
            } else { Color.clear.frame(maxWidth: .infinity, maxHeight: .infinity) }
        }
        .foregroundStyle(.black)
        .background(Color(red: 0.965, green: 0.959, blue: 0.936))
    }
}

private extension DiagramViewport {
    var finite: DiagramViewport {
        DiagramViewport(
            zoomScale: zoomScale.isFinite ? min(4, max(1, zoomScale)) : 1,
            contentOffset: CGPoint(
                x: contentOffset.x.isFinite ? contentOffset.x : 0,
                y: contentOffset.y.isFinite ? contentOffset.y : 0
            )
        )
    }
}

/// Native delegates may fire during a representable update or a layout pass.
/// Coalesce their facts onto the next turn before notifying SwiftUI's owner.
@MainActor
private final class DiagramViewportReporter {
    private var onChange: ((DiagramViewport, DiagramViewportCause) -> Void)?
    private var pending: [(DiagramViewport, DiagramViewportCause)] = []
    private var lastEmitted: DiagramViewport?
    private var renderID: AnyHashable
    private var generation: UInt64 = 0
    private var active = true
    private var scheduled = false

    init(renderID: AnyHashable, onChange: @escaping (DiagramViewport, DiagramViewportCause) -> Void) {
        self.renderID = renderID
        self.onChange = onChange
    }

    func update(renderID: AnyHashable, onChange: @escaping (DiagramViewport, DiagramViewportCause) -> Void) {
        guard active else { return }
        self.onChange = onChange
        if self.renderID != renderID {
            self.renderID = renderID
            generation &+= 1
            pending.removeAll()
            scheduled = false
        }
    }

    func invalidate() {
        active = false
        generation &+= 1
        pending.removeAll()
        scheduled = false
        onChange = nil
    }

    func hasEmitted(_ viewport: DiagramViewport) -> Bool { lastEmitted == viewport }

    func report(_ viewport: DiagramViewport, cause: DiagramViewportCause) {
        guard active else { return }
        // Coalesce contiguous samples, preserving every change of provenance.
        // In particular, a later layout cannot erase a user's observation.
        if pending.last?.1 == cause {
            pending[pending.count - 1] = (viewport, cause)
        } else {
            pending.append((viewport, cause))
        }
        guard !scheduled else { return }
        scheduled = true
        let queuedGeneration = generation
        DispatchQueue.main.async { [weak self] in
            guard let self, self.active, self.generation == queuedGeneration else { return }
            self.scheduled = false
            let events = self.pending
            self.pending.removeAll()
            for event in events {
                guard self.active, self.generation == queuedGeneration else { return }
                // A real user observation may refresh reading time even without movement.
                guard event.1 == .userInteraction || self.lastEmitted != event.0 else { continue }
                self.lastEmitted = event.0
                self.onChange?(event.0, event.1)
            }
        }
    }
}

/// A receipt describes one content generation that has completed native layout
/// in a visible window. IDs alone are insufficient for an A → B → A update.
@MainActor
private final class DiagramDisplayReporter {
    private var renderID: AnyHashable
    private var onDisplayed: ((AnyHashable) -> Void)?
    private var generation: UInt64 = 0
    private var laidOutGeneration: UInt64?
    private var deliveredGeneration: UInt64?
    private var scheduledGeneration: UInt64?
    private var active = true

    init(renderID: AnyHashable, onDisplayed: @escaping (AnyHashable) -> Void) {
        self.renderID = renderID
        self.onDisplayed = onDisplayed
    }

    func update(renderID: AnyHashable, onDisplayed: @escaping (AnyHashable) -> Void) {
        guard active else { return }
        self.onDisplayed = onDisplayed
        if self.renderID != renderID {
            self.renderID = renderID
            generation &+= 1
            laidOutGeneration = nil
            scheduledGeneration = nil
        }
    }

    func didLayout(isVisible: @escaping () -> Bool) {
        guard active else { return }
        laidOutGeneration = generation
        visibilityChanged(isVisible: isVisible)
    }

    func visibilityChanged(isVisible: @escaping () -> Bool) {
        guard active, laidOutGeneration == generation, deliveredGeneration != generation,
              scheduledGeneration != generation, isVisible() else { return }
        let queuedGeneration = generation
        let queuedID = renderID
        scheduledGeneration = queuedGeneration
        DispatchQueue.main.async { [weak self] in
            guard let self, self.active, self.generation == queuedGeneration,
                  self.renderID == queuedID else { return }
            self.scheduledGeneration = nil
            guard self.laidOutGeneration == queuedGeneration,
                  self.deliveredGeneration != queuedGeneration, isVisible() else { return }
            self.deliveredGeneration = queuedGeneration
            self.onDisplayed?(queuedID)
        }
    }

    func invalidate() {
        active = false
        generation &+= 1
        laidOutGeneration = nil
        scheduledGeneration = nil
        onDisplayed = nil
    }
}

private func finiteDiagramSize(_ measured: CGSize, viewport: CGSize) -> CGSize {
    CGSize(
        width: measured.width.isFinite ? max(1, measured.width) : max(1, viewport.width),
        height: measured.height.isFinite ? max(1, measured.height) : max(1, viewport.height)
    )
}

#if canImport(UIKit)

private final class DiagramWindowAwareView: UIView {
    var onWindowChange: (() -> Void)?
    override func didMoveToWindow() {
        super.didMoveToWindow()
        onWindowChange?()
    }
}

private final class DiagramUIKitScrollView: UIScrollView {
    var handlingAccessibilityScroll = false
    var onAccessibilityBrowsing: (() -> Void)?

    override func accessibilityScroll(_ direction: UIAccessibilityScrollDirection) -> Bool {
        var target = contentOffset
        let vertical = contentSize.height > bounds.height
        switch direction {
        case .down: target.y += bounds.height * 0.8
        case .up: target.y -= bounds.height * 0.8
        case .right: target.x += bounds.width * 0.8
        case .left: target.x -= bounds.width * 0.8
        case .next:
            if vertical { target.y += bounds.height * 0.8 } else { target.x += bounds.width * 0.8 }
        case .previous:
            if vertical { target.y -= bounds.height * 0.8 } else { target.x -= bounds.width * 0.8 }
        @unknown default: return super.accessibilityScroll(direction)
        }
        target.x = min(max(0, target.x), max(0, contentSize.width - bounds.width))
        target.y = min(max(0, target.y), max(0, contentSize.height - bounds.height))
        guard target != contentOffset else { return false }
        handlingAccessibilityScroll = true
        setContentOffset(target, animated: false)
        layoutIfNeeded()
        handlingAccessibilityScroll = false
        onAccessibilityBrowsing?()
        UIAccessibility.post(notification: .pageScrolled, argument: nil)
        return true
    }
}

private struct DiagramNativeViewport: UIViewControllerRepresentable {
    let content: AnyView
    let viewport: DiagramViewport
    let renderID: AnyHashable
    let onDisplayed: (AnyHashable) -> Void
    let onViewportChange: (DiagramViewport, DiagramViewportCause) -> Void

    func makeUIViewController(context: Context) -> DiagramViewportController {
        DiagramViewportController(
            content: content, viewport: viewport, renderID: renderID,
            onDisplayed: onDisplayed, onViewportChange: onViewportChange
        )
    }

    func updateUIViewController(_ controller: DiagramViewportController, context: Context) {
        controller.update(content: content, viewport: viewport, renderID: renderID,
                          onDisplayed: onDisplayed, onViewportChange: onViewportChange)
    }

    static func dismantleUIViewController(_ controller: DiagramViewportController, coordinator: ()) {
        controller.invalidate()
    }
}

private final class DiagramViewportController: UIViewController, UIScrollViewDelegate {
    private let scrollView = DiagramUIKitScrollView()
    private let canvas = UIView()
    private let hosting: UIHostingController<AnyView>
    private let reporter: DiagramViewportReporter
    private let displayReporter: DiagramDisplayReporter
    private var lastRequested: DiagramViewport
    private var pendingRestore: DiagramViewport?
    private var naturalSize = CGSize.zero
    private var viewportSize = CGSize.zero
    private var needsMeasurement = true
    private var applyingGeometry = false
    private var active = true
    private var disappearing = false
    private var dragSession = false
    private var decelerationSession = false
    private var pinchSession = false

    init(content: AnyView, viewport: DiagramViewport, renderID: AnyHashable,
         onDisplayed: @escaping (AnyHashable) -> Void,
         onViewportChange: @escaping (DiagramViewport, DiagramViewportCause) -> Void) {
        hosting = UIHostingController(rootView: content)
        reporter = DiagramViewportReporter(renderID: renderID, onChange: onViewportChange)
        displayReporter = DiagramDisplayReporter(renderID: renderID, onDisplayed: onDisplayed)
        lastRequested = viewport
        pendingRestore = viewport.finite
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is unavailable") }

    override func loadView() {
        let root = DiagramWindowAwareView()
        root.onWindowChange = { [weak self] in self?.visibilityChanged() }
        view = root
        view.backgroundColor = .clear
        scrollView.frame = view.bounds
        scrollView.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        scrollView.backgroundColor = .clear
        scrollView.contentInsetAdjustmentBehavior = .never
        scrollView.minimumZoomScale = 1
        scrollView.maximumZoomScale = 4
        scrollView.isDirectionalLockEnabled = false
        scrollView.delegate = self
        scrollView.onAccessibilityBrowsing = { [weak self] in self?.reportNativeChange(userCompletion: true) }
        scrollView.panGestureRecognizer.addTarget(self, action: #selector(gestureStateChanged))
        scrollView.pinchGestureRecognizer?.addTarget(self, action: #selector(gestureStateChanged))
        view.addSubview(scrollView)
        scrollView.addSubview(canvas)
        addChild(hosting)
        hosting.sizingOptions = []
        hosting.safeAreaRegions = []
        hosting.view.backgroundColor = .clear
        canvas.addSubview(hosting.view)
        hosting.didMove(toParent: self)
        NotificationCenter.default.addObserver(self, selector: #selector(windowBecameVisible),
            name: UIWindow.didBecomeVisibleNotification, object: nil)
    }

    deinit { NotificationCenter.default.removeObserver(self) }

    func update(content: AnyView, viewport: DiagramViewport, renderID: AnyHashable,
                onDisplayed: @escaping (AnyHashable) -> Void,
                onViewportChange: @escaping (DiagramViewport, DiagramViewportCause) -> Void) {
        guard active else { return }
        reporter.update(renderID: renderID, onChange: onViewportChange)
        displayReporter.update(renderID: renderID, onDisplayed: onDisplayed)
        hosting.rootView = content
        needsMeasurement = true
        if viewport != lastRequested {
            lastRequested = viewport
            // A binding echo of an actual native fact needs no restoration.
            if !reporter.hasEmitted(viewport), viewport.finite != actualViewport {
                pendingRestore = viewport.finite
            }
        }
        if isViewLoaded { view.setNeedsLayout() }
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        layoutDiagram()
    }

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        disappearing = false
        visibilityChanged()
    }

    override func viewWillDisappear(_ animated: Bool) {
        disappearing = true
        super.viewWillDisappear(animated)
    }

    func invalidate() {
        active = false
        reporter.invalidate()
        displayReporter.invalidate()
        resetGestureSessions()
        scrollView.delegate = nil
        scrollView.onAccessibilityBrowsing = nil
        scrollView.panGestureRecognizer.removeTarget(self, action: #selector(gestureStateChanged))
        scrollView.pinchGestureRecognizer?.removeTarget(self, action: #selector(gestureStateChanged))
        (viewIfLoaded as? DiagramWindowAwareView)?.onWindowChange = nil
        NotificationCenter.default.removeObserver(self)
    }

    private var isVisible: Bool {
        guard active, !disappearing, isViewLoaded, let window = view.window,
              !window.isHidden, window.alpha > 0,
              view.bounds.width > 0, view.bounds.height > 0,
              hosting.view.bounds.width > 0, hosting.view.bounds.height > 0 else { return false }
        var ancestor: UIView? = hosting.view
        while let current = ancestor {
            if current.isHidden || current.alpha <= 0 { return false }
            ancestor = current.superview
        }
        var controller: UIViewController? = self
        while let current = controller {
            if current.presentedViewController != nil || current.isBeingDismissed || current.isMovingFromParent { return false }
            controller = current.parent
        }
        return !hosting.view.convert(hosting.view.bounds, to: view).intersection(view.bounds).isEmpty
    }

    private func visibilityChanged() {
        guard active, isViewLoaded else { return }
        view.setNeedsLayout()
        displayReporter.visibilityChanged { [weak self] in self?.isVisible == true }
    }

    @objc private func windowBecameVisible(_ notification: Notification) {
        guard let window = notification.object as? UIWindow, window === viewIfLoaded?.window else { return }
        visibilityChanged()
    }

    private var actualViewport: DiagramViewport {
        DiagramViewport(zoomScale: scrollView.zoomScale, contentOffset: scrollView.contentOffset)
    }

    private func layoutDiagram() {
        let available = scrollView.bounds.size
        guard active, available.width > 0, available.height > 0, !applyingGeometry else { return }
        let resized = viewportSize != available
        guard needsMeasurement || resized || pendingRestore != nil else {
            displayReporter.visibilityChanged { [weak self] in self?.isVisible == true }
            return
        }
        applyingGeometry = true
        defer { applyingGeometry = false }
        let restoration = pendingRestore
        let desired = (restoration ?? actualViewport).finite
        var geometryChanged = false

        if needsMeasurement || resized {
            let measured = finiteDiagramSize(
                hosting.sizeThatFits(in: CGSize(width: available.width, height: 10_000)),
                viewport: available
            )
            let canvasSize = CGSize(
                width: max(available.width, measured.width),
                height: max(available.height, measured.height)
            )
            if measured != naturalSize || resized {
                geometryChanged = true
                resetGestureSessions()
                // Set an untransformed frame; UIScrollView owns the zoom transform.
                scrollView.setZoomScale(1, animated: false)
                canvas.frame = CGRect(origin: .zero, size: canvasSize)
                hosting.view.frame = CGRect(origin: .zero, size: measured)
                scrollView.contentSize = canvasSize
                naturalSize = measured
            }
            viewportSize = available
            needsMeasurement = false
        }
        if geometryChanged || restoration != nil {
            resetGestureSessions()
            scrollView.setZoomScale(desired.zoomScale, animated: false)
            let offset = CGPoint(
                x: min(max(0, desired.contentOffset.x), max(0, scrollView.contentSize.width - available.width)),
                y: min(max(0, desired.contentOffset.y), max(0, scrollView.contentSize.height - available.height))
            )
            scrollView.setContentOffset(offset, animated: false)
        }
        pendingRestore = nil
        hosting.view.setNeedsLayout()
        hosting.view.layoutIfNeeded()
        reporter.report(actualViewport, cause: restoration == nil ? .layout : .restoration)
        displayReporter.didLayout { [weak self] in self?.isVisible == true }
    }

    func viewForZooming(in scrollView: UIScrollView) -> UIView? { canvas }

    private func reportNativeChange(userCompletion: Bool = false) {
        guard active, !applyingGeometry, !scrollView.handlingAccessibilityScroll else { return }
        let user = userCompletion || scrollView.isTracking || scrollView.isDragging || scrollView.isDecelerating || scrollView.isZooming
        reporter.report(actualViewport, cause: user ? .userInteraction : .layout)
    }

    func scrollViewDidScroll(_ scrollView: UIScrollView) { reportNativeChange() }
    func scrollViewDidZoom(_ scrollView: UIScrollView) { reportNativeChange() }
    func scrollViewWillBeginDragging(_ scrollView: UIScrollView) {
        guard active, !applyingGeometry else { return }
        dragSession = true
        decelerationSession = false
    }
    func scrollViewDidEndDragging(_ scrollView: UIScrollView, willDecelerate decelerate: Bool) {
        reportNativeChange(userCompletion: dragSession)
        decelerationSession = dragSession && decelerate
        dragSession = false
    }
    func scrollViewWillBeginDecelerating(_ scrollView: UIScrollView) {
        if active, !applyingGeometry { decelerationSession = true }
    }
    func scrollViewDidEndDecelerating(_ scrollView: UIScrollView) {
        reportNativeChange(userCompletion: decelerationSession)
        decelerationSession = false
    }
    func scrollViewWillBeginZooming(_ scrollView: UIScrollView, with view: UIView?) {
        guard active, !applyingGeometry else { return }
        let state = scrollView.pinchGestureRecognizer?.state
        pinchSession = state == .began || state == .changed
    }
    func scrollViewDidEndZooming(_ scrollView: UIScrollView, with view: UIView?, atScale scale: CGFloat) {
        reportNativeChange(userCompletion: pinchSession)
        pinchSession = false
    }
    func scrollViewDidEndScrollingAnimation(_ scrollView: UIScrollView) { resetGestureSessions() }

    private func resetGestureSessions() {
        dragSession = false
        decelerationSession = false
        pinchSession = false
    }

    @objc private func gestureStateChanged(_ recognizer: UIGestureRecognizer) {
        if recognizer.state == .cancelled || recognizer.state == .failed { resetGestureSessions() }
    }
}

#else

private struct DiagramNativeViewport: NSViewControllerRepresentable {
    let content: AnyView
    let viewport: DiagramViewport
    let renderID: AnyHashable
    let onDisplayed: (AnyHashable) -> Void
    let onViewportChange: (DiagramViewport, DiagramViewportCause) -> Void

    func makeNSViewController(context: Context) -> DiagramViewportController {
        DiagramViewportController(
            content: content, viewport: viewport, renderID: renderID,
            onDisplayed: onDisplayed, onViewportChange: onViewportChange
        )
    }

    func updateNSViewController(_ controller: DiagramViewportController, context: Context) {
        controller.update(content: content, viewport: viewport, renderID: renderID,
                          onDisplayed: onDisplayed, onViewportChange: onViewportChange)
    }

    static func dismantleNSViewController(_ controller: DiagramViewportController, coordinator: ()) {
        controller.invalidate()
    }
}

private final class DiagramWindowAwareView: NSView {
    var onWindowChange: (() -> Void)?
    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        onWindowChange?()
    }
}

private final class DiagramFlippedCanvas: NSView {
    override var isFlipped: Bool { true }
}

private final class DiagramAppKitScrollView: NSScrollView {
    var handlingUserEvent = false
    var onUserEvent: (() -> Void)?

    override func scrollWheel(with event: NSEvent) {
        handlingUserEvent = true
        super.scrollWheel(with: event)
        onUserEvent?()
        handlingUserEvent = false
    }

    override func magnify(with event: NSEvent) {
        handlingUserEvent = true
        super.magnify(with: event)
        onUserEvent?()
        handlingUserEvent = false
    }

    override func smartMagnify(with event: NSEvent) {
        handlingUserEvent = true
        super.smartMagnify(with: event)
        onUserEvent?()
        handlingUserEvent = false
    }
}

private final class DiagramViewportController: NSViewController {
    private let scrollView = DiagramAppKitScrollView()
    private let canvas = DiagramFlippedCanvas()
    private let hosting: NSHostingController<AnyView>
    private let reporter: DiagramViewportReporter
    private let displayReporter: DiagramDisplayReporter
    private var lastRequested: DiagramViewport
    private var pendingRestore: DiagramViewport?
    private var naturalSize = CGSize.zero
    private var viewportSize = CGSize.zero
    private var needsMeasurement = true
    private var applyingGeometry = false
    private var liveScroll = false
    private var liveMagnify = false
    private var active = true

    init(content: AnyView, viewport: DiagramViewport, renderID: AnyHashable,
         onDisplayed: @escaping (AnyHashable) -> Void,
         onViewportChange: @escaping (DiagramViewport, DiagramViewportCause) -> Void) {
        hosting = NSHostingController(rootView: content)
        reporter = DiagramViewportReporter(renderID: renderID, onChange: onViewportChange)
        displayReporter = DiagramDisplayReporter(renderID: renderID, onDisplayed: onDisplayed)
        lastRequested = viewport
        pendingRestore = viewport.finite
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is unavailable") }

    override func loadView() {
        let root = DiagramWindowAwareView()
        root.onWindowChange = { [weak self] in self?.visibilityChanged() }
        view = root
        scrollView.frame = view.bounds
        scrollView.autoresizingMask = [.width, .height]
        scrollView.drawsBackground = false
        scrollView.hasHorizontalScroller = true
        scrollView.hasVerticalScroller = true
        scrollView.scrollerStyle = .overlay
        scrollView.allowsMagnification = true
        scrollView.minMagnification = 1
        scrollView.maxMagnification = 4
        scrollView.usesPredominantAxisScrolling = false
        view.addSubview(scrollView)
        scrollView.documentView = canvas
        addChild(hosting)
        hosting.sizingOptions = []
        hosting.safeAreaRegions = []
        canvas.addSubview(hosting.view)
        scrollView.contentView.postsBoundsChangedNotifications = true
        let center = NotificationCenter.default
        center.addObserver(self, selector: #selector(boundsChanged), name: NSView.boundsDidChangeNotification, object: scrollView.contentView)
        center.addObserver(self, selector: #selector(willScroll), name: NSScrollView.willStartLiveScrollNotification, object: scrollView)
        center.addObserver(self, selector: #selector(didScroll), name: NSScrollView.didLiveScrollNotification, object: scrollView)
        center.addObserver(self, selector: #selector(didEndScroll), name: NSScrollView.didEndLiveScrollNotification, object: scrollView)
        center.addObserver(self, selector: #selector(willMagnify), name: NSScrollView.willStartLiveMagnifyNotification, object: scrollView)
        center.addObserver(self, selector: #selector(didEndMagnify), name: NSScrollView.didEndLiveMagnifyNotification, object: scrollView)
        for name in [NSWindow.didExposeNotification, NSWindow.didBecomeKeyNotification,
                     NSWindow.didDeminiaturizeNotification, NSWindow.didChangeOcclusionStateNotification,
                     NSWindow.willBeginSheetNotification, NSWindow.didEndSheetNotification] {
            center.addObserver(self, selector: #selector(windowPresentationChanged), name: name, object: nil)
        }
        scrollView.onUserEvent = { [weak self] in self?.reportNativeChange() }
    }

    deinit { NotificationCenter.default.removeObserver(self) }

    func update(content: AnyView, viewport: DiagramViewport, renderID: AnyHashable,
                onDisplayed: @escaping (AnyHashable) -> Void,
                onViewportChange: @escaping (DiagramViewport, DiagramViewportCause) -> Void) {
        guard active else { return }
        reporter.update(renderID: renderID, onChange: onViewportChange)
        displayReporter.update(renderID: renderID, onDisplayed: onDisplayed)
        hosting.rootView = content
        needsMeasurement = true
        if viewport != lastRequested {
            lastRequested = viewport
            if !reporter.hasEmitted(viewport), viewport.finite != actualViewport {
                pendingRestore = viewport.finite
            }
        }
        if isViewLoaded { view.needsLayout = true }
    }

    override func viewDidLayout() {
        super.viewDidLayout()
        layoutDiagram()
    }

    override func viewDidAppear() {
        super.viewDidAppear()
        visibilityChanged()
    }

    func invalidate() {
        active = false
        reporter.invalidate()
        displayReporter.invalidate()
        liveScroll = false
        liveMagnify = false
        scrollView.onUserEvent = nil
        (isViewLoaded ? view as? DiagramWindowAwareView : nil)?.onWindowChange = nil
        NotificationCenter.default.removeObserver(self)
    }

    private var isVisible: Bool {
        guard active, isViewLoaded, let window = view.window,
              window.isVisible, !window.isMiniaturized, window.attachedSheet == nil,
              view.bounds.width > 0, view.bounds.height > 0,
              hosting.view.bounds.width > 0, hosting.view.bounds.height > 0,
              !hosting.view.isHiddenOrHasHiddenAncestor else { return false }
        var ancestor: NSView? = hosting.view
        while let current = ancestor {
            if current.alphaValue <= 0 { return false }
            ancestor = current.superview
        }
        return !hosting.view.convert(hosting.view.bounds, to: view).intersection(view.bounds).isEmpty
    }

    private func visibilityChanged() {
        guard active, isViewLoaded else { return }
        view.needsLayout = true
        displayReporter.visibilityChanged { [weak self] in self?.isVisible == true }
    }

    @objc private func windowPresentationChanged(_ notification: Notification) {
        guard isViewLoaded, let window = notification.object as? NSWindow,
              window === view.window else { return }
        visibilityChanged()
    }

    private var actualViewport: DiagramViewport {
        DiagramViewport(zoomScale: scrollView.magnification, contentOffset: scrollView.contentView.bounds.origin)
    }

    private func layoutDiagram() {
        let available = scrollView.contentView.frame.size
        guard active, available.width > 0, available.height > 0, !applyingGeometry else { return }
        let resized = viewportSize != available
        guard needsMeasurement || resized || pendingRestore != nil else {
            displayReporter.visibilityChanged { [weak self] in self?.isVisible == true }
            return
        }
        applyingGeometry = true
        defer { applyingGeometry = false }
        let restoration = pendingRestore
        let desired = (restoration ?? actualViewport).finite
        var geometryChanged = false
        if needsMeasurement || resized {
            let measured = finiteDiagramSize(
                hosting.sizeThatFits(in: CGSize(width: available.width, height: 10_000)),
                viewport: available
            )
            if measured != naturalSize || resized {
                geometryChanged = true
                liveScroll = false
                liveMagnify = false
                canvas.frame = CGRect(origin: .zero, size: CGSize(
                    width: max(available.width, measured.width),
                    height: max(available.height, measured.height)
                ))
                hosting.view.frame = CGRect(origin: .zero, size: measured)
                naturalSize = measured
            }
            viewportSize = available
            needsMeasurement = false
        }
        if geometryChanged || restoration != nil {
            liveScroll = false
            liveMagnify = false
            scrollView.magnification = desired.zoomScale
            let visible = scrollView.contentView.bounds.size
            scrollView.contentView.scroll(to: CGPoint(
                x: min(max(0, desired.contentOffset.x), max(0, canvas.bounds.width - visible.width)),
                y: min(max(0, desired.contentOffset.y), max(0, canvas.bounds.height - visible.height))
            ))
            scrollView.reflectScrolledClipView(scrollView.contentView)
        }
        pendingRestore = nil
        hosting.view.needsLayout = true
        hosting.view.layoutSubtreeIfNeeded()
        reporter.report(actualViewport, cause: restoration == nil ? .layout : .restoration)
        displayReporter.didLayout { [weak self] in self?.isVisible == true }
    }

    private func reportNativeChange(userCompletion: Bool = false) {
        guard active, !applyingGeometry else { return }
        let user = userCompletion || scrollView.handlingUserEvent || liveScroll || liveMagnify
        reporter.report(actualViewport, cause: user ? .userInteraction : .layout)
    }

    @objc private func boundsChanged(_ notification: Notification) { reportNativeChange() }
    @objc private func willScroll(_ notification: Notification) {
        if active, !applyingGeometry { liveScroll = true }
    }
    @objc private func didScroll(_ notification: Notification) {
        guard active, !applyingGeometry else { return }
        liveScroll = true
        reportNativeChange()
    }
    @objc private func didEndScroll(_ notification: Notification) {
        reportNativeChange(userCompletion: liveScroll)
        liveScroll = false
    }
    @objc private func willMagnify(_ notification: Notification) {
        if active, !applyingGeometry { liveMagnify = true }
    }
    @objc private func didEndMagnify(_ notification: Notification) {
        reportNativeChange(userCompletion: liveMagnify)
        liveMagnify = false
    }
}

#endif
