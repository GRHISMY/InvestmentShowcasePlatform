import SwiftUI
import PDFKit
#if canImport(UIKit)
import UIKit
#else
import AppKit
#endif

enum PDFReadingAction { case locate, zoomIn, zoomOut, fit, previousPage, nextPage }
/// Each fresh attempt identifies one immutable local original. A new render ID
/// locates its one-based physical page without requiring a toolbar command.
/// Control IDs change only for explicit native controls; keys are never decoded here.
struct PDFReadingRequest {
    let file: URL
    let physicalPage: Int
    let focusText: String
    let command: PDFReadingAction
    let commandID: Int
    var paged = false
    let attemptID: AnyHashable
    let renderID: AnyHashable
    var placementCause: PDFPageCause = .programmatic
}
enum PDFReadFailure: Error { case missingFile, invalidDocument, invalidPage }

enum PDFPageCause: Equatable { case programmatic, restoration, userInteraction }
struct PDFLoadEvent {
    let attemptID: AnyHashable
    let result: Result<Int, PDFReadFailure>
}
/// Facts and opaque keys are captured when PDFKit changes its current page,
/// before asynchronous delivery. Loading and page callbacks have no ordering guarantee.
struct PDFPageEvent {
    let attemptID, renderID: AnyHashable
    let physicalPage: Int
    let cause: PDFPageCause
}

/// Fit after SwiftUI gives PDFKit its real size; fitting a zero-size view makes a report unreadably small.
final class PageWidthPDFView: PDFView {
    private var widthFitPage: PDFPage?
    private var fittedWidth: CGFloat = 0
    private var followsWidth = true
    private var operationCause: PDFPageCause?
    var observationCause: PDFPageCause {
        if let operationCause { return operationCause }
        #if canImport(UIKit)
        func interacting(_ view: UIView) -> Bool {
            if let scroll = view as? UIScrollView,
               scroll.isTracking || scroll.isDragging || scroll.isDecelerating || scroll.isZooming { return true }
            if view.gestureRecognizers?.contains(where: { $0.state == .began || $0.state == .changed }) == true { return true }
            return view.subviews.contains(where: interacting)
        }
        return interacting(self) ? .userInteraction : .programmatic
        #else
        guard let event = NSApp.currentEvent, event.window === window else { return .programmatic }
        if event.type == .keyDown, let responder = window?.firstResponder as? NSView,
           responder.isDescendant(of: self) { return .userInteraction }
        let point = convert(event.locationInWindow, from: nil)
        return bounds.contains(point) && [.scrollWheel, .magnify, .smartMagnify, .leftMouseDragged].contains(event.type)
            ? .userInteraction : .programmatic
        #endif
    }
    override var intrinsicContentSize: CGSize { CGSize(width: -1, height: -1) }

    func perform(cause: PDFPageCause, _ operation: () -> Void) {
        let previous = operationCause
        operationCause = cause
        defer { operationCause = previous }
        operation()
    }

    func locate(_ page: PDFPage) {
        widthFitPage = page
        applyWidthFit(preferredPage: page)
        goToPageTop(page)
    }

    func clearOriginal() {
        document = nil
        highlightedSelections = []
        widthFitPage = nil
        fittedWidth = 0
        followsWidth = true
    }

    func fitWidth() {
        followsWidth = true
        fittedWidth = 0
        widthFitPage = currentPage
        applyWidthFit()
    }

    func zoom(by factor: CGFloat) {
        followsWidth = false
        autoScales = false
        scaleFactor = min(maxScaleFactor, max(minScaleFactor, scaleFactor * factor))
    }

    private func applyWidthFit(preferredPage: PDFPage? = nil) {
        guard followsWidth, bounds.width > 50, bounds.height > 50,
              abs(fittedWidth - bounds.width) > 1,
              let page = preferredPage ?? currentPage ?? widthFitPage else { return }
        fittedWidth = bounds.width
        let rect = page.bounds(for: displayBox)
        let pageWidth = page.rotation % 180 == 0 ? rect.width : rect.height
        guard pageWidth > 0 else { return }
        autoScales = false
        minScaleFactor = 0.1
        scaleFactor = min(maxScaleFactor, max(minScaleFactor, (bounds.width - 20) / pageWidth))
        layoutDocumentView()
        goToPageTop(page)
    }

    private func goToPageTop(_ page: PDFPage) {
        let rect = page.bounds(for: displayBox)
        go(to: PDFDestination(page: page, at: CGPoint(x: rect.minX, y: rect.maxY)))
    }

    #if canImport(UIKit)
    override func layoutSubviews() {
        super.layoutSubviews()
        perform(cause: .programmatic) { applyWidthFit() }
    }

    override func accessibilityScroll(_ direction: UIAccessibilityScrollDirection) -> Bool {
        let step: Int
        switch direction {
        case .down, .right, .next: step = 1
        case .up, .left, .previous: step = -1
        @unknown default: return super.accessibilityScroll(direction)
        }
        guard let document, let currentPage,
              let page = document.page(at: document.index(for: currentPage) + step) else { return false }
        perform(cause: .userInteraction) { locate(page) }
        UIAccessibility.post(notification: .pageScrolled,
            argument: "第\(document.index(for: page) + 1)页，共\(document.pageCount)页")
        return true
    }
    #else
    override func layout() {
        super.layout()
        perform(cause: .programmatic) { applyWidthFit() }
    }
    #endif
}

#if canImport(UIKit)
/// The owned native pager supplies a completed/cancelled gesture boundary that
/// PDFViewPageChanged does not expose. PDFKit still presents the complete original.
@MainActor final class PDFReadingController: UIViewController, UIPageViewControllerDataSource, UIPageViewControllerDelegate {
    private let pager = UIPageViewController(transitionStyle: .scroll, navigationOrientation: .horizontal)
    private let first = PDFPageController()
    private let coordinator: PDFReadingCoordinator
    private var pendingRequest: PDFReadingRequest?
    private var transitionIdentity: PDFPageIdentity?
    private var transitionCommand: Int?
    private(set) var isTransitioning = false
    private var cancelled = false

    init(coordinator: PDFReadingCoordinator) {
        self.coordinator = coordinator
        super.init(nibName: nil, bundle: nil)
        coordinator.pageController = self
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    var currentPDFView: PageWidthPDFView {
        (pager.viewControllers?.first as? PDFPageController ?? first).pdf
    }
    override func viewDidLoad() {
        super.viewDidLoad()
        addChild(pager)
        pager.view.frame = view.bounds
        pager.view.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        view.addSubview(pager.view)
        pager.didMove(toParent: self)
        pager.dataSource = self
        pager.delegate = self
        pager.setViewControllers([first], direction: .forward, animated: false)
    }
    func update(_ request: PDFReadingRequest) {
        guard !cancelled else { return }
        loadViewIfNeeded()
        if isTransitioning {
            pendingRequest = request
            let navigationSupersedes = transitionCommand != request.commandID &&
                [.locate, .previousPage, .nextPage].contains(request.command)
            if transitionIdentity != PDFPageIdentity(request) || navigationSupersedes {
                transitionIdentity = nil
            }
            return
        }
        pager.dataSource = request.paged ? self : nil
        coordinator.update(currentPDFView, request: request)
    }
    func pageViewController(_ pageViewController: UIPageViewController,
                            viewControllerBefore viewController: UIViewController) -> UIViewController? {
        neighbor(of: viewController, step: -1)
    }
    func pageViewController(_ pageViewController: UIPageViewController,
                            viewControllerAfter viewController: UIViewController) -> UIViewController? {
        neighbor(of: viewController, step: 1)
    }
    private func neighbor(of controller: UIViewController, step: Int) -> PDFPageController? {
        guard let source = (controller as? PDFPageController)?.pdf,
              let document = source.document, let current = source.currentPage,
              let page = document.page(at: document.index(for: current) + step) else { return nil }
        let child = PDFPageController()
        child.pdf.document = document
        child.pdf.highlightedSelections = source.highlightedSelections
        child.pdf.perform(cause: .programmatic) { child.pdf.locate(page) }
        return child
    }
    func pageViewController(_ pageViewController: UIPageViewController,
                            willTransitionTo pendingViewControllers: [UIViewController]) {
        isTransitioning = true
        transitionIdentity = coordinator.pageIdentity
        transitionCommand = coordinator.commandID
    }
    func pageViewController(_ pageViewController: UIPageViewController, didFinishAnimating finished: Bool,
                            previousViewControllers: [UIViewController], transitionCompleted completed: Bool) {
        guard !cancelled else { return }
        let identity = transitionIdentity
        transitionIdentity = nil
        isTransitioning = false
        coordinator.observe(currentPDFView)
        if completed, let identity { coordinator.committedPage(currentPDFView, identity: identity) }
        if let request = pendingRequest {
            pendingRequest = nil
            update(request)
        }
    }
    /// Direct PDFKit navigation and toolbar commands retain the visible PDFView,
    /// but invalidate neighbors cached for its former physical page.
    func refreshNeighbors(for pdf: PageWidthPDFView) {
        guard !cancelled, !isTransitioning, currentPDFView === pdf,
              let current = pager.viewControllers?.first else { return }
        pager.setViewControllers([current], direction: .forward, animated: false)
    }
    func cancel() {
        cancelled = true
        pendingRequest = nil
        transitionIdentity = nil
        pager.delegate = nil
        pager.dataSource = nil
        coordinator.cancel()
    }
}

@MainActor private final class PDFPageController: UIViewController {
    let pdf = PageWidthPDFView()
    init() {
        super.init(nibName: nil, bundle: nil)
        pdf.backgroundColor = .secondarySystemBackground
        pdf.displayMode = .singlePage
        pdf.displayDirection = .horizontal
        pdf.usePageViewController(false, withViewOptions: nil)
        pdf.displaysPageBreaks = true
        pdf.autoScales = false
        pdf.maxScaleFactor = 8
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    override func loadView() { view = pdf }
}

fileprivate struct PDFPageIdentity: Equatable {
    let attempt, render: AnyHashable
    init(_ request: PDFReadingRequest) { attempt = request.attemptID; render = request.renderID }
}
#endif

/// PDFKit owns text, pinch zoom and page geometry; callers provide a document and a command.
@MainActor final class PDFReadingCoordinator: NSObject {
    var onLoad: (PDFLoadEvent) -> Void
    var onPageChange: (PDFPageEvent) -> Void
    private var openedFile: URL?
    private var openedAttempt: AnyHashable?
    private var currentRenderID: AnyHashable?
    private var currentRequest: PDFReadingRequest?
    private var lastCommand: Int?
    private var observer: NSObjectProtocol?
    private weak var observedView: PageWidthPDFView?
    #if canImport(UIKit)
    weak var pageController: PDFReadingController?
    fileprivate var pageIdentity: PDFPageIdentity? { currentRequest.map(PDFPageIdentity.init) }
    fileprivate var commandID: Int? { currentRequest?.commandID }
    #endif
    private var active = true

    init(onLoad: @escaping (PDFLoadEvent) -> Void, onPageChange: @escaping (PDFPageEvent) -> Void) {
        self.onLoad = onLoad; self.onPageChange = onPageChange
    }

    func update(_ view: PageWidthPDFView, request: PDFReadingRequest) {
        guard active else { return }
        let newPlacement = currentRenderID != request.renderID
        currentRenderID = request.renderID
        currentRequest = request
        if openedFile != request.file || openedAttempt != request.attemptID {
            openedFile = request.file
            openedAttempt = request.attemptID
            if let observer { NotificationCenter.default.removeObserver(observer) }
            observer = nil
            observedView = nil
            view.clearOriginal()
            #if canImport(UIKit)
            pageController?.refreshNeighbors(for: view)
            #endif
            guard FileManager.default.fileExists(atPath: request.file.path) else {
                complete(.failure(.missingFile), attemptID: request.attemptID); return
            }
            guard let document = PDFDocument(url: request.file) else {
                complete(.failure(.invalidDocument), attemptID: request.attemptID); return
            }
            guard request.physicalPage > 0,
                  let page = document.page(at: request.physicalPage - 1) else {
                complete(.failure(.invalidPage), attemptID: request.attemptID); return
            }
            view.document = document
            view.displayMode = request.paged ? .singlePage : .singlePageContinuous
            view.displayDirection = request.paged ? .horizontal : .vertical
            #if canImport(UIKit)
            view.usePageViewController(false, withViewOptions: nil)
            #endif
            view.displaysPageBreaks = true
            view.autoScales = false
            view.maxScaleFactor = 8
            observe(view)
            DispatchQueue.main.async { [weak self, weak view] in
                guard let self, self.active, let view, view.document === document else { return }
                if self.currentRenderID == request.renderID {
                    view.perform(cause: request.placementCause) {
                        view.locate(page)
                        self.highlight(page: page, text: request.focusText, in: view)
                    }
                    self.onPageChange(PDFPageEvent(attemptID: request.attemptID,
                        renderID: request.renderID, physicalPage: request.physicalPage, cause: request.placementCause))
                }
                self.onLoad(PDFLoadEvent(attemptID: request.attemptID, result: .success(document.pageCount)))
            }
        }
        if view.document != nil { observe(view) }
        guard view.document != nil, lastCommand != request.commandID || newPlacement else { return }
        lastCommand = request.commandID
        let action: PDFReadingAction = newPlacement ? .locate : request.command
        DispatchQueue.main.async { [weak self, weak view] in
            guard let self, self.active, let view,
                  self.openedFile == request.file, self.openedAttempt == request.attemptID,
                  self.currentRenderID == request.renderID else { return }
            let cause: PDFPageCause = [.nextPage, .previousPage].contains(action) ? .userInteraction
                : (action == .locate ? request.placementCause : .programmatic)
            view.perform(cause: cause) {
                switch action {
                case .locate:
                    if let page = view.document?.page(at: request.physicalPage - 1) {
                        view.locate(page)
                        self.highlight(page: page, text: request.focusText, in: view)
                    }
                case .zoomIn: view.zoom(by: 1.35)
                case .zoomOut: view.zoom(by: 1 / 1.35)
                case .fit: view.fitWidth()
                case .previousPage, .nextPage:
                    if let document = view.document, let current = view.currentPage {
                        let index = document.index(for: current) + (request.command == .nextPage ? 1 : -1)
                        if let page = document.page(at: index) { view.locate(page) }
                    }
                }
            }
            #if canImport(UIKit)
            self.pageController?.refreshNeighbors(for: view)
            #endif
        }
    }

    fileprivate func observe(_ view: PageWidthPDFView) {
        guard observedView !== view else { return }
        if let observer { NotificationCenter.default.removeObserver(observer) }
        observedView = view
        observer = NotificationCenter.default.addObserver(forName: .PDFViewPageChanged, object: view, queue: .main) { [weak self, weak view] _ in
            let observation: PDFPageEvent? = MainActor.assumeIsolated {
                guard let self, self.active, let request = self.currentRequest, let view,
                      let current = view.currentPage, let document = view.document else { return nil }
                #if canImport(UIKit)
                guard self.pageController?.isTransitioning != true else { return nil }
                #endif
                return PDFPageEvent(attemptID: request.attemptID, renderID: request.renderID,
                    physicalPage: document.index(for: current) + 1, cause: view.observationCause)
            }
            guard let observation else { return }
            DispatchQueue.main.async { [weak self, weak view] in
                guard let self, self.active else { return }
                self.onPageChange(observation)
                #if canImport(UIKit)
                if let view { self.pageController?.refreshNeighbors(for: view) }
                #endif
            }
        }
    }

    #if canImport(UIKit)
    fileprivate func committedPage(_ view: PageWidthPDFView, identity: PDFPageIdentity) {
        guard active, let current = view.currentPage, let document = view.document else { return }
        let event = PDFPageEvent(attemptID: identity.attempt, renderID: identity.render,
            physicalPage: document.index(for: current) + 1, cause: .userInteraction)
        DispatchQueue.main.async { [weak self] in
            guard let self, self.active else { return }
            self.onPageChange(event)
        }
    }
    #endif

    private func highlight(page: PDFPage, text: String, in view: PDFView) {
        view.highlightedSelections = []
        guard !text.isEmpty, let content = page.string else { return }
        let range = (content as NSString).range(of: text)
        guard range.location != NSNotFound, let selection = page.selection(for: range) else { return }
        #if canImport(UIKit)
        selection.color = UIColor.systemYellow.withAlphaComponent(0.4)
        #else
        selection.color = NSColor.systemYellow.withAlphaComponent(0.4)
        #endif
        view.highlightedSelections = [selection]
    }

    private func complete(_ result: Result<Int, PDFReadFailure>, attemptID: AnyHashable) {
        let event = PDFLoadEvent(attemptID: attemptID, result: result)
        DispatchQueue.main.async { [weak self] in
            guard let self, self.active else { return }
            self.onLoad(event)
        }
    }

    func cancel() {
        active = false
        if let observer { NotificationCenter.default.removeObserver(observer) }
        observer = nil
        observedView = nil
    }
}

#if canImport(UIKit)
struct NativePDFReader: UIViewControllerRepresentable {
    let request: PDFReadingRequest
    let onLoad: (PDFLoadEvent) -> Void
    let onPageChange: (PDFPageEvent) -> Void
    func makeCoordinator() -> PDFReadingCoordinator { PDFReadingCoordinator(onLoad: onLoad, onPageChange: onPageChange) }
    func makeUIViewController(context: Context) -> PDFReadingController {
        let controller = PDFReadingController(coordinator: context.coordinator)
        controller.update(request)
        return controller
    }
    func updateUIViewController(_ controller: PDFReadingController, context: Context) {
        context.coordinator.onLoad = onLoad
        context.coordinator.onPageChange = onPageChange
        controller.update(request)
    }
    func sizeThatFits(_ proposal: ProposedViewSize, uiViewController: PDFReadingController, context: Context) -> CGSize? {
        CGSize(width: proposal.width ?? 390, height: proposal.height ?? 600)
    }
    static func dismantleUIViewController(_ controller: PDFReadingController, coordinator: PDFReadingCoordinator) { controller.cancel() }
}
#else
struct NativePDFReader: NSViewRepresentable {
    let request: PDFReadingRequest
    let onLoad: (PDFLoadEvent) -> Void
    let onPageChange: (PDFPageEvent) -> Void
    func makeCoordinator() -> PDFReadingCoordinator { PDFReadingCoordinator(onLoad: onLoad, onPageChange: onPageChange) }
    func makeNSView(context: Context) -> PageWidthPDFView {
        let view = PageWidthPDFView(); view.backgroundColor = .windowBackgroundColor
        context.coordinator.update(view, request: request); return view
    }
    func updateNSView(_ view: PageWidthPDFView, context: Context) {
        context.coordinator.onLoad = onLoad
        context.coordinator.onPageChange = onPageChange
        context.coordinator.update(view, request: request)
    }
    func sizeThatFits(_ proposal: ProposedViewSize, nsView: PageWidthPDFView, context: Context) -> CGSize? {
        CGSize(width: proposal.width ?? 390, height: proposal.height ?? 600)
    }
    static func dismantleNSView(_ view: PageWidthPDFView, coordinator: PDFReadingCoordinator) { coordinator.cancel() }
}
#endif
