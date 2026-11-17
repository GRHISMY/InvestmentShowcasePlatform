import SwiftUI
#if SWIFT_PACKAGE
import ResearchCore
#endif

/// PDFKit supplies physical-page observations; reading decides citation and resume meaning.
private struct RestoredPDFReadingObservationKey: EnvironmentKey {
    static let defaultValue: PDFObservationToken? = nil
}
extension EnvironmentValues {
    var restoredPDFReadingObservation: PDFObservationToken? {
        get { self[RestoredPDFReadingObservationKey.self] }
        set { self[RestoredPDFReadingObservationKey.self] = newValue }
    }
}

private struct PDFHeaderHeightPreference: PreferenceKey {
    static let defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) { value = max(value, nextValue()) }
}

struct PDFReadingPageView: View {
    @Environment(\.readingObservationEnabled) private var observationEnabled
    @Environment(\.restoredPDFReadingObservation) private var restoredObservation
    let page: PDFReadingPage
    let returnLabel: String
    let onClose: () -> Void
    let onLoad: (PDFLoadAttempt, Result<Int, PDFReadingFailure>) -> Void
    let onPage: (PDFObservationToken, Int, PositionCause) -> Void
    let onRetry: () -> Void
    let onCitation: (CitationTarget) -> Void
    let onContinue: (PDFDocumentChoice) -> Void
    @ReadingState private var command: PDFReadingAction = .locate
    @ReadingState private var commandID = 0
    @ReadingState private var headerHeight: CGFloat = 0

    var body: some View {
        NavigationStack {
            GeometryReader { geometry in
                VStack(spacing: 0) {
                    // Full titles and actions remain reachable even in a short
                    // viewport or at accessibility text sizes. The original
                    // keeps the rest of the actual viewport.
                    ScrollView {
                        header.background {
                            GeometryReader { measured in
                                Color.clear.preference(key: PDFHeaderHeightPreference.self, value: measured.size.height)
                            }
                        }
                    }
                    .scrollBounceBehavior(.basedOnSize)
                    .onPreferenceChange(PDFHeaderHeightPreference.self) { height in
                        if abs(headerHeight - height) > 0.5 { headerHeight = height }
                    }
                    .frame(height: min(headerHeight > 0 ? headerHeight : geometry.size.height * 0.34,
                                       max(44, geometry.size.height * 0.34)))
                    Divider()
                    original.frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            }
            .safeAreaInset(edge: .bottom, spacing: 0) {
                VStack(spacing: 0) {
                    Divider()
                    controls.padding(.horizontal, 12).padding(.vertical, 8)
                }.background(.bar)
            }
            .background(StudyInk.paper)
            .navigationTitle("完整原始 PDF")
            .inlineReadingTitle()
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(action: onClose) { Label(returnLabel, systemImage: "chevron.backward") }
                        .accessibilityLabel(returnLabel).accessibilityIdentifier("study-close-pdf")
                }
            }
        }
        .buttonStyle(.plain).foregroundStyle(.primary).tint(.primary)
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(page.document.title).font(.subheadline.weight(.medium))
                .fixedSize(horizontal: false, vertical: true)
            ViewThatFits(in: .horizontal) {
                HStack(spacing: 10) { positionActions }
                    .fixedSize(horizontal: true, vertical: false)
                VStack(alignment: .leading, spacing: 8) { positionActions }
            }
            .font(.subheadline).buttonStyle(.bordered)
        }
        .frame(maxWidth: .infinity, alignment: .leading).padding(16)
    }

    @ViewBuilder private var positionActions: some View {
        if let citation = page.currentCitation {
            Button("核对引用第 " + String(citation.physicalPage) + " 页") { onCitation(citation.target) }
                .fixedSize(horizontal: false, vertical: true)
                .accessibilityIdentifier("study-pdf-citation")
        }
        Button(page.resumePhysicalPage.map { "继续读第 " + String($0) + " 页" } ?? "从第 1 页阅读") {
            onContinue(page.document.resume)
        }
        .fixedSize(horizontal: false, vertical: true).accessibilityIdentifier("study-pdf-resume")
    }

    @ViewBuilder private var original: some View {
        if case .failed(let failure) = page.loadState {
            ContentUnavailableView {
                Label("原文暂时没有打开", systemImage: "doc.questionmark")
            } description: { Text(failureMessage(failure)) }
            actions: { Button("重试打开", action: onRetry).accessibilityIdentifier("study-pdf-retry") }
        } else {
            if observationEnabled {
                NativePDFReader(request: PDFReadingRequest(file: page.document.fileURL,
                    physicalPage: restoredObservation == page.request.observation
                        ? (page.visiblePhysicalPage ?? page.request.targetPhysicalPage) : page.request.targetPhysicalPage,
                    focusText: page.request.focusText ?? "",
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
            } else { Color.clear.frame(maxWidth: .infinity, maxHeight: .infinity) }
        }
    }

    private var controls: some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: 8) {
                control("前页", symbol: "chevron.left", action: .previousPage)
                pagePosition
                control("后页", symbol: "chevron.right", action: .nextPage)
                Divider().frame(height: 24)
                zoomControls
            }.fixedSize(horizontal: true, vertical: false)
            VStack(spacing: 2) {
                HStack {
                    control("前页", symbol: "chevron.left", action: .previousPage)
                    Spacer(minLength: 0)
                    pagePosition
                    Spacer(minLength: 0)
                    control("后页", symbol: "chevron.right", action: .nextPage)
                }
                HStack(spacing: 12) { zoomControls }
            }
        }
        .frame(maxWidth: .infinity)
    }

    private var pagePosition: some View {
        Text(String(page.visiblePhysicalPage ?? page.request.targetPhysicalPage) + " / " + String(page.document.pageCount))
            .font(.caption.monospaced()).fixedSize(horizontal: false, vertical: true)
            .accessibilityIdentifier("study-pdf-position")
            .accessibilityValue(page.loadState == .ready ? "原文已打开" : "原文尚未打开")
    }

    @ViewBuilder private var zoomControls: some View {
        control("缩小", symbol: "minus.magnifyingglass", action: .zoomOut)
        control("适合宽度", symbol: "arrow.left.and.right", action: .fit)
        control("放大", symbol: "plus.magnifyingglass", action: .zoomIn)
    }

    private func control(_ label: String, symbol: String, action: PDFReadingAction) -> some View {
        Button { command = action; commandID += 1 } label: {
            Label(label, systemImage: symbol).labelStyle(.iconOnly)
                .frame(minWidth: 44, minHeight: 44).contentShape(Rectangle())
        }
        .font(.body).disabled(page.loadState != .ready)
        .accessibilityLabel(label).help(label).accessibilityIdentifier("study-pdf-" + actionName(action))
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
