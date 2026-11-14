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
            view.usePageViewController(request.paged, withViewOptions: nil)
            #endif
            view.displaysPageBreaks = true
            view.autoScales = false
            view.maxScaleFactor = 8
            observer = NotificationCenter.default.addObserver(forName: .PDFViewPageChanged, object: view, queue: .main) { [weak self, weak view] _ in
                let observation: PDFPageEvent? = MainActor.assumeIsolated {
                    guard let self, self.active, let request = self.currentRequest, let view,
                          let current = view.currentPage, let doc = view.document else { return nil }
                    return PDFPageEvent(attemptID: request.attemptID, renderID: request.renderID,
                        physicalPage: doc.index(for: current) + 1, cause: view.observationCause)
                }
                guard let observation else { return }
                DispatchQueue.main.async {
                    guard let self, self.active else { return }
                    self.onPageChange(observation)
                }
            }
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
        }
    }

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
    }
}

#if canImport(UIKit)
struct NativePDFReader: UIViewRepresentable {
    let request: PDFReadingRequest
    let onLoad: (PDFLoadEvent) -> Void
    let onPageChange: (PDFPageEvent) -> Void
    func makeCoordinator() -> PDFReadingCoordinator { PDFReadingCoordinator(onLoad: onLoad, onPageChange: onPageChange) }
    func makeUIView(context: Context) -> PageWidthPDFView {
        let view = PageWidthPDFView(); view.backgroundColor = .secondarySystemBackground
        context.coordinator.update(view, request: request); return view
    }
    func updateUIView(_ view: PageWidthPDFView, context: Context) {
        context.coordinator.onLoad = onLoad
        context.coordinator.onPageChange = onPageChange
        context.coordinator.update(view, request: request)
    }
    func sizeThatFits(_ proposal: ProposedViewSize, uiView: PageWidthPDFView, context: Context) -> CGSize? {
        CGSize(width: proposal.width ?? 390, height: proposal.height ?? 600)
    }
    static func dismantleUIView(_ view: PageWidthPDFView, coordinator: PDFReadingCoordinator) { coordinator.cancel() }
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
