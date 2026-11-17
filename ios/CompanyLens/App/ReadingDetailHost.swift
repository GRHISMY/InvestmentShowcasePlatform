import SwiftUI
#if SWIFT_PACKAGE
import ResearchCore
#endif

/// Projects the reader's resolved path into native presentations. It owns no routes.
struct ReadingDetailHost: View {
    @Binding var reader: StudyReader
    let token: PresentationToken

    var body: some View {
        let path = reader.presentationPath
        let index = path.firstIndex { $0.token == token }
        let current = index.map { path[$0] }
        let shownNext = index.flatMap { path.indices.contains($0 + 1) ? path[$0 + 1] : nil }
        let returnLabel = sourceReturnLabel(index: index, path: path)
        Group {
            if let current {
                switch current.page {
                case .explanation(let page):
                    shell("展开解释", returnLabel: returnLabel, closeID: "study-close-explanation") {
                        scroll(title: page.title, observation: page.observation, position: page.restorePosition, cause: page.arrivalCause) {
                            ResearchText(text: page.text)
                            if !page.caveat.isEmpty { ResearchText(text: page.caveat).foregroundStyle(StudyInk.muted) }
                        }
                    }
                case .calculations(let page):
                    shell("核对计算", returnLabel: returnLabel, closeID: "study-close-calculation") {
                        scroll(title: page.title, observation: page.observation, position: page.restorePosition, cause: page.arrivalCause) {
                            ForEach(page.items) { item in calculation(item) }
                        }
                    }
                case .evidence(let page):
                    shell("核对依据", returnLabel: returnLabel, closeID: "study-close-evidence") {
                        scroll(title: page.title, observation: page.observation, position: page.restorePosition, cause: page.arrivalCause) {
                            ForEach(page.items) { item in evidence(item) }
                        }
                    }
                case .pdf(let page):
                    PDFReadingPageView(page: page, returnLabel: returnLabel, onClose: { reader.dismissPresentation(token) },
                        onLoad: { reader.reportPDFLoad($0, result: $1) },
                        onPage: { reader.reportPDFPage($0, physicalPage: $1, cause: $2) },
                        onRetry: { reader.retryPDF() }, onCitation: { reader.openCitation($0) },
                        onContinue: { reader.continuePDF($0) })
                }
            }
        }
        .background(StudyInk.grouped.ignoresSafeArea()).foregroundStyle(.primary).tint(.primary)
        .sheet(item: Binding(get: { shownNext }, set: { value in
            if value == nil, let token = shownNext?.token { reader.dismissPresentation(token) }
        })) { presentation in
            ReadingDetailHost(reader: $reader, token: presentation.token).id(presentation.token)
        }
        #if os(iOS)
        .presentationDetents([.large])
        #else
        .frame(minWidth: 440, idealWidth: 520, minHeight: 700)
        #endif
    }

    private func sourceReturnLabel(index: Int?, path: [ReadingDetailPresentation]) -> String {
        guard let index, index > 0 else {
            return reader.currentMode == .report ? "返回报告" : "返回图解"
        }
        switch path[index - 1].page {
        case .explanation: return "返回解释"
        case .calculations: return "返回计算"
        case .evidence: return "返回依据"
        case .pdf: return "返回原文"
        }
    }

    private func shell<Content: View>(_ label: String, returnLabel: String, closeID: String,
                                      @ViewBuilder content: () -> Content) -> some View {
        NavigationStack {
            content()
                .navigationTitle(label)
                .inlineReadingTitle()
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) {
                        Button { reader.dismissPresentation(token) } label: {
                            Label(returnLabel, systemImage: "chevron.backward")
                        }
                        .accessibilityLabel(returnLabel).accessibilityIdentifier(closeID)
                    }
                }
        }
    }

    private func scroll<Content: View>(title: String, observation: ObservationToken, position: ReadingPosition?,
                                       cause: PositionCause, @ViewBuilder content: () -> Content) -> some View {
        ReaderScroll(observation: observation, restorePosition: position, arrivalCause: cause, onPosition: {
            reader.reportVisiblePosition($0, position: $1, cause: $2)
        }) {
            Text(title).font(.title.bold()).fixedSize(horizontal: false, vertical: true)
                .readingAnchor(id: "detail")
            content()
        }
        .frame(maxWidth: 680).frame(maxWidth: .infinity)
    }

    private func calculation(_ item: CalculationContent) -> some View {
        VStack(alignment: .leading, spacing: 20) {
            VStack(alignment: .leading, spacing: 12) {
                Text(item.calculation.title).font(.title2.weight(.semibold))
                Text(item.calculation.result.displayValue + " " + item.calculation.result.displayUnit)
                    .font(.largeTitle.weight(.semibold)).monospacedDigit().textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
                ResearchText(text: item.calculation.explanation)
            }
            .padding(20).background(StudyInk.card, in: RoundedRectangle(cornerRadius: 18))
            .readingAnchor(id: item.anchor.id)
            Text("全部输入").font(.headline).accessibilityAddTraits(.isHeader)
            ForEach(item.inputs) { input in
                VStack(alignment: .leading, spacing: 12) {
                    Text(input.operationLabel).font(.caption.weight(.semibold)).foregroundStyle(StudyInk.muted)
                    Text(factTitle(input.fact.fact, periodLabel: input.fact.periodLabel)).font(.headline)
                    Text(factValue(input.fact.fact)).monospacedDigit().textSelection(.enabled)
                    Text(input.fact.entityName + " · " + input.fact.periodLabel).font(.caption).foregroundStyle(StudyInk.muted)
                    if !input.fact.fact.note.isEmpty { ResearchText(text: input.fact.fact.note).font(.footnote) }
                    ForEach(input.evidence) { reference in
                        Button { reader.follow(reference.link) } label: {
                            Label("查看依据 · " + reference.title, systemImage: "text.magnifyingglass")
                                .fixedSize(horizontal: false, vertical: true)
                                .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
                        }.buttonStyle(.bordered).accessibilityIdentifier("study-input-evidence-" + reference.id)
                    }
                    citations(input.citations)
                }
                .padding(20).background(StudyInk.card, in: RoundedRectangle(cornerRadius: 18))
                .readingAnchor(id: input.anchor.id)
            }
            if !item.calculation.limitations.isEmpty {
                Text("这项计算能说明到哪里").font(.headline)
                ForEach(Array(item.calculation.limitations.enumerated()), id: \.offset) { _, text in
                    ResearchText(text: text).foregroundStyle(StudyInk.muted)
                }
            }
            Rectangle().fill(StudyInk.line).frame(height: 1)
        }
    }

    private func evidence(_ item: EvidenceContent) -> some View {
        VStack(alignment: .leading, spacing: 18) {
            Text(item.source.title).font(.headline)
            Text(item.source.period).font(.caption).foregroundStyle(StudyInk.muted)
            if item.isCounterEvidence {
                Label("同时核对这处反证", systemImage: "exclamationmark.bubble")
                    .font(.subheadline.weight(.semibold))
            }
            Text("原文摘录").font(.subheadline.weight(.semibold)).accessibilityAddTraits(.isHeader)
            ResearchText(text: item.evidence.excerpt).textSelection(.enabled)
            if !item.evidence.locatorNote.isEmpty { ResearchText(text: item.evidence.locatorNote).foregroundStyle(StudyInk.muted) }
            if !item.uses.isEmpty { Text("这处依据用于").font(.headline).accessibilityAddTraits(.isHeader) }
            ForEach(Array(item.uses.enumerated()), id: \.offset) { _, use in
                VStack(alignment: .leading, spacing: 8) {
                    Text(use.claimTitle).font(.subheadline.weight(.semibold))
                    Text(relationLabel(use.relation)).font(.caption).foregroundStyle(StudyInk.muted)
                    ResearchText(text: use.explanation)
                }
            }
            citations(item.citations)
        }
        .padding(20).background(StudyInk.card, in: RoundedRectangle(cornerRadius: 18))
        .readingAnchor(id: item.anchor.id)
    }

    private func citations(_ items: [CitationContent]) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            if !items.isEmpty { Text("核对原始资料").font(.subheadline.weight(.semibold)).accessibilityAddTraits(.isHeader) }
            ForEach(items) { citation in
                Button { reader.openCitation(citation.target) } label: {
                    Label(citation.title + " · 原文第 " + String(citation.physicalPage) + " 页", systemImage: "doc.viewfinder")
                        .fixedSize(horizontal: false, vertical: true)
                        .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
                }.buttonStyle(.bordered).accessibilityIdentifier("study-open-pdf")
            }
        }
    }

    private func relationLabel(_ relation: String) -> String {
        switch relation {
        case "supports": return "支持这条判断"
        case "contradicts": return "与这条判断相矛盾"
        case "background": return "为这条判断提供背景"
        default: return relation
        }
    }
}
