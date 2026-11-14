import SwiftUI
#if SWIFT_PACKAGE
import ResearchCore
#endif

/// PDFKit supplies physical-page observations; reading decides citation and resume meaning.
struct PDFReadingPageView: View {
    let page: PDFReadingPage
    let onClose: () -> Void
    let onLoad: (PDFLoadAttempt, Result<Int, PDFReadingFailure>) -> Void
    let onPage: (PDFObservationToken, Int, PositionCause) -> Void
    let onRetry: () -> Void
    let onCitation: (CitationTarget) -> Void
    let onContinue: (PDFDocumentChoice) -> Void
    @ReadingState private var command: PDFReadingAction = .locate
    @ReadingState private var commandID = 0

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Button(action: onClose) { Label("返回来源", systemImage: "chevron.left").frame(minHeight: 44) }
                    .accessibilityIdentifier("study-close-pdf")
                Spacer()
                Text("完整原始 PDF").font(.caption.weight(.semibold))
            }.padding(.horizontal, 18)
            Text(page.document.title).font(.subheadline.weight(.medium))
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading).padding(.horizontal, 18).padding(.bottom, 10)
            HStack(spacing: 18) {
                if let citation = page.currentCitation {
                    Button("核对引用第 " + String(citation.physicalPage) + " 页") { onCitation(citation.target) }
                        .accessibilityIdentifier("study-pdf-citation")
                }
                Button(page.resumePhysicalPage.map { "继续读第 " + String($0) + " 页" } ?? "从第 1 页阅读") {
                    onContinue(page.document.resume)
                }.accessibilityIdentifier("study-pdf-resume")
                Spacer(minLength: 0)
            }.font(.caption).padding(.horizontal, 18).frame(minHeight: 44)
            Divider()
            if case .failed(let failure) = page.loadState {
                ContentUnavailableView {
                    Label("原文暂时没有打开", systemImage: "doc.questionmark")
                } description: { Text(failureMessage(failure)) }
                actions: { Button("重试打开", action: onRetry).accessibilityIdentifier("study-pdf-retry") }
            } else {
                NativePDFReader(request: PDFReadingRequest(file: page.document.fileURL,
                    physicalPage: page.request.targetPhysicalPage, focusText: page.request.focusText ?? "",
                    command: command, commandID: commandID, paged: true,
                    attemptID: AnyHashable(page.request.attempt), renderID: AnyHashable(page.request.observation),
                    placementCause: page.request.cause == .restoration ? .restoration : .programmatic),
                    onLoad: { event in
                        guard event.attemptID == AnyHashable(page.request.attempt) else { return }
                        onLoad(page.request.attempt, event.result.mapError { failure in
                            switch failure {
                            case .missingFile: return .missingFile
                            case .invalidDocument: return .invalidDocument
                            case .invalidPage: return .invalidPage
                            }
                        })
                    }, onPageChange: { event in
                        guard event.attemptID == AnyHashable(page.request.attempt),
                              event.renderID == AnyHashable(page.request.observation) else { return }
                        let cause: PositionCause = event.cause == .userInteraction ? .userBrowsing
                            : event.cause == .restoration ? .restoration : .programmatic
                        onPage(page.request.observation, event.physicalPage, cause)
                    })
                    .accessibilityIdentifier("study-native-pdf")
                    .accessibilityLabel("完整原始 PDF，可翻页与缩放")
            }
            Divider()
            HStack {
                control("前页", symbol: "chevron.left", action: .previousPage)
                Spacer()
                Text(String(page.visiblePhysicalPage ?? page.request.targetPhysicalPage) + " / " + String(page.document.pageCount))
                    .font(.caption.monospaced()).accessibilityIdentifier("study-pdf-position")
                    .accessibilityValue(page.loadState == .ready ? "原文已打开" : "原文尚未打开")
                Spacer()
                control("后页", symbol: "chevron.right", action: .nextPage)
            }.padding(.horizontal, 18)
            HStack(spacing: 24) {
                control("缩小", symbol: "minus.magnifyingglass", action: .zoomOut)
                control("适合宽度", symbol: "arrow.left.and.right", action: .fit)
                control("放大", symbol: "plus.magnifyingglass", action: .zoomIn)
            }.padding(.bottom, 8)
        }.buttonStyle(.plain).background(StudyInk.paper).foregroundStyle(.black)
    }

    private func control(_ label: String, symbol: String, action: PDFReadingAction) -> some View {
        Button { command = action; commandID += 1 } label: {
            Label(label, systemImage: symbol).frame(minWidth: 44, minHeight: 44)
        }.font(.caption).disabled(page.loadState != .ready).accessibilityIdentifier("study-pdf-" + actionName(action))
    }

    private func actionName(_ action: PDFReadingAction) -> String {
        switch action {
        case .previousPage: return "previous"
        case .nextPage: return "next"
        case .zoomIn: return "zoom-in"
        case .zoomOut: return "zoom-out"
        case .fit: return "fit"
        case .locate: return "locate"
        }
    }
    private func failureMessage(_ failure: PDFReadingFailure) -> String {
        switch failure {
        case .missingFile: return "这份固定版本的原件暂时不可用，可以重试。"
        case .invalidDocument: return "文件未能作为 PDF 打开，可以重试。"
        case .invalidPage: return "原件中没有这处物理页。"
        case .pageCountMismatch: return "原件页数与这份研究的来源声明不一致。"
        }
    }
}
