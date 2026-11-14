import SwiftUI
import PDFKit
#if SWIFT_PACKAGE
import ResearchCore
#endif
#if canImport(UIKit)
import UIKit
#else
import AppKit
#endif

enum PDFReadingAction { case locate, zoomIn, zoomOut, fit, previousPage, nextPage }
struct PDFReadingRequest {
    let file: URL
    let physicalPage: Int
    let focusText: String
    let command: PDFReadingAction
    let commandID: Int
    var paged = false
}
enum PDFReadFailure: Error { case missingFile, invalidDocument, invalidPage }

/// Fit after SwiftUI gives PDFKit its real size; fitting a zero-size view makes a report unreadably small.
final class PageWidthPDFView: PDFView {
    private var widthFitPage: PDFPage?
    private var fittedWidth: CGFloat = 0
    private var followsWidth = true
    override var intrinsicContentSize: CGSize { CGSize(width: -1, height: -1) }

    func locate(_ page: PDFPage) {
        widthFitPage = page
        applyWidthFit()
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

    private func applyWidthFit() {
        guard followsWidth, bounds.width > 50, bounds.height > 50,
              abs(fittedWidth - bounds.width) > 1,
              let page = widthFitPage ?? currentPage else { return }
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
    override func layoutSubviews() { super.layoutSubviews(); applyWidthFit() }
    #else
    override func layout() { super.layout(); applyWidthFit() }
    #endif
}

/// PDFKit owns text, pinch zoom and page geometry; callers provide a document and a command.
@MainActor final class PDFReadingCoordinator: NSObject {
    var onReady: (Result<Int, PDFReadFailure>) -> Void
    var onPage: (Int) -> Void
    private var openedFile: URL?
    private var lastCommand: Int?
    private var observer: NSObjectProtocol?
    private var active = true

    init(onReady: @escaping (Result<Int, PDFReadFailure>) -> Void, onPage: @escaping (Int) -> Void) {
        self.onReady = onReady; self.onPage = onPage
    }

    func update(_ view: PageWidthPDFView, request: PDFReadingRequest) {
        guard active else { return }
        if openedFile != request.file {
            openedFile = request.file
            guard FileManager.default.fileExists(atPath: request.file.path) else {
                complete(.failure(.missingFile)); return
            }
            guard let document = PDFDocument(url: request.file) else {
                complete(.failure(.invalidDocument)); return
            }
            guard request.physicalPage > 0,
                  let page = document.page(at: request.physicalPage - 1) else {
                complete(.failure(.invalidPage)); return
            }
            view.document = document
            view.displayMode = request.paged ? .singlePage : .singlePageContinuous
            view.displayDirection = request.paged ? .horizontal : .vertical
            view.displaysPageBreaks = true
            view.autoScales = false
            view.maxScaleFactor = 8
            observer = NotificationCenter.default.addObserver(forName: .PDFViewPageChanged, object: view, queue: .main) { [weak self, weak view] _ in
                DispatchQueue.main.async {
                    guard let self, self.active, let view,
                          let current = view.currentPage, let doc = view.document else { return }
                    self.onPage(doc.index(for: current) + 1)
                }
            }
            DispatchQueue.main.async { [weak self, weak view] in
                guard let self, self.active, let view, view.document === document else { return }
                view.locate(page)
                self.highlight(page: page, text: request.focusText, in: view)
                self.onPage(request.physicalPage)
                self.onReady(.success(document.pageCount))
            }
        }
        guard view.document != nil, lastCommand != request.commandID else { return }
        lastCommand = request.commandID
        DispatchQueue.main.async { [weak self, weak view] in
            guard let self, self.active, let view else { return }
            switch request.command {
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

    private func highlight(page: PDFPage, text: String, in view: PDFView) {
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

    private func complete(_ result: Result<Int, PDFReadFailure>) {
        DispatchQueue.main.async { [weak self] in
            guard let self, self.active else { return }
            self.onReady(result)
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
    let onReady: (Result<Int, PDFReadFailure>) -> Void
    let onPage: (Int) -> Void
    func makeCoordinator() -> PDFReadingCoordinator { PDFReadingCoordinator(onReady: onReady, onPage: onPage) }
    func makeUIView(context: Context) -> PageWidthPDFView {
        let view = PageWidthPDFView(); view.backgroundColor = .secondarySystemBackground
        context.coordinator.update(view, request: request); return view
    }
    func updateUIView(_ view: PageWidthPDFView, context: Context) { context.coordinator.update(view, request: request) }
    func sizeThatFits(_ proposal: ProposedViewSize, uiView: PageWidthPDFView, context: Context) -> CGSize? {
        CGSize(width: proposal.width ?? 390, height: proposal.height ?? 600)
    }
    static func dismantleUIView(_ view: PageWidthPDFView, coordinator: PDFReadingCoordinator) { coordinator.cancel() }
}
#else
struct NativePDFReader: NSViewRepresentable {
    let request: PDFReadingRequest
    let onReady: (Result<Int, PDFReadFailure>) -> Void
    let onPage: (Int) -> Void
    func makeCoordinator() -> PDFReadingCoordinator { PDFReadingCoordinator(onReady: onReady, onPage: onPage) }
    func makeNSView(context: Context) -> PageWidthPDFView {
        let view = PageWidthPDFView(); view.backgroundColor = .windowBackgroundColor
        context.coordinator.update(view, request: request); return view
    }
    func updateNSView(_ view: PageWidthPDFView, context: Context) { context.coordinator.update(view, request: request) }
    func sizeThatFits(_ proposal: ProposedViewSize, nsView: PageWidthPDFView, context: Context) -> CGSize? {
        CGSize(width: proposal.width ?? 390, height: proposal.height ?? 600)
    }
    static func dismantleNSView(_ view: PageWidthPDFView, coordinator: PDFReadingCoordinator) { coordinator.cancel() }
}
#endif
