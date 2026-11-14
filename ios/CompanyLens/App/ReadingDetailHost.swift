import SwiftUI
#if SWIFT_PACKAGE
import ResearchCore
#endif

/// Projects the reader's resolved path into native presentations. It owns no routes.
struct ReadingDetailHost: View {
    @Binding var reader: StudyReader
    let token: PresentationToken

    private var current: ReadingDetailPresentation? { reader.presentationPath.first { $0.token == token } }
    private var next: ReadingDetailPresentation? {
        let path = reader.presentationPath
        guard let index = path.firstIndex(where: { $0.token == token }), path.indices.contains(index + 1) else { return nil }
        return path[index + 1]
    }

    var body: some View {
        let shownNext = next
        Group {
            if let current {
                switch current.page {
                case .explanation(let page):
                    shell("展开解释", closeID: "study-close-explanation") {
                        scroll(title: page.title, observation: page.observation, position: page.restorePosition, cause: page.arrivalCause) {
                            ResearchText(text: page.text)
                            if !page.caveat.isEmpty { ResearchText(text: page.caveat).foregroundStyle(StudyInk.muted) }
                        }
                    }
                case .calculations(let page):
                    shell("核对计算", closeID: "study-close-calculation") {
                        scroll(title: page.title, observation: page.observation, position: page.restorePosition, cause: page.arrivalCause) {
                            ForEach(page.items) { item in calculation(item) }
                        }
                    }
                case .evidence(let page):
                    shell("核对依据", closeID: "study-close-evidence") {
                        scroll(title: page.title, observation: page.observation, position: page.restorePosition, cause: page.arrivalCause) {
                            ForEach(page.items) { item in evidence(item) }
                        }
                    }
                case .pdf(let page):
                    PDFReadingPageView(page: page, onClose: { reader.dismissPresentation(token) },
                        onLoad: { reader.reportPDFLoad($0, result: $1) },
                        onPage: { reader.reportPDFPage($0, physicalPage: $1, cause: $2) },
                        onRetry: { reader.retryPDF() }, onCitation: { reader.openCitation($0) },
                        onContinue: { reader.continuePDF($0) })
                }
            }
        }
        .background(StudyInk.paper.ignoresSafeArea()).foregroundStyle(.black).tint(.black)
        .preferredColorScheme(.light)
        .sheet(item: Binding(get: { next }, set: { value in
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

    private func shell<Content: View>(_ label: String, closeID: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(spacing: 0) {
            HStack {
                Text(label).font(.caption.weight(.medium)).tracking(2)
                Spacer()
                Button { reader.dismissPresentation(token) } label: {
                    Label("返回来源", systemImage: "xmark").labelStyle(.iconOnly).frame(width: 44, height: 44)
                }.buttonStyle(.plain).accessibilityLabel("关闭" + label + "，返回来源").accessibilityIdentifier(closeID)
            }.padding(.horizontal, 24)
            Rectangle().fill(StudyInk.line).frame(height: 0.5)
            content()
        }
    }

    private func scroll<Content: View>(title: String, observation: ObservationToken, position: ReadingPosition?,
                                       cause: PositionCause, @ViewBuilder content: () -> Content) -> some View {
        ReaderScroll(observation: observation, restorePosition: position, arrivalCause: cause, onPosition: {
            reader.reportVisiblePosition($0, position: $1, cause: $2)
        }) {
            Text(title).font(.system(.title, design: .serif)).fixedSize(horizontal: false, vertical: true)
                .readingAnchor(id: "detail")
            content()
        }
    }

    private func calculation(_ item: CalculationContent) -> some View {
        VStack(alignment: .leading, spacing: 20) {
            VStack(alignment: .leading, spacing: 12) {
                Text(item.calculation.title).font(.title2.weight(.semibold))
                Text(item.calculation.result.displayValue + " " + item.calculation.result.displayUnit)
                    .font(.system(.largeTitle, design: .serif)).monospacedDigit().textSelection(.enabled)
                ResearchText(text: item.calculation.explanation)
            }.readingAnchor(id: item.anchor.id)
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
                                .frame(minHeight: 44, alignment: .leading)
                        }.buttonStyle(.plain).accessibilityIdentifier("study-input-evidence-" + reference.id)
                    }
                    citations(input.citations)
                }.padding(.vertical, 12).readingAnchor(id: input.anchor.id)
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
            if item.isCounterEvidence { Text("同时核对这处反证").font(.subheadline.weight(.semibold)) }
            ResearchText(text: item.evidence.excerpt).textSelection(.enabled)
            if !item.evidence.locatorNote.isEmpty { ResearchText(text: item.evidence.locatorNote).foregroundStyle(StudyInk.muted) }
            ForEach(Array(item.uses.enumerated()), id: \.offset) { _, use in
                VStack(alignment: .leading, spacing: 8) {
                    Text(use.claimTitle).font(.subheadline.weight(.semibold))
                    Text(relationLabel(use.relation)).font(.caption).foregroundStyle(StudyInk.muted)
                    ResearchText(text: use.explanation)
                }
            }
            citations(item.citations)
            Rectangle().fill(StudyInk.line).frame(height: 1)
        }.readingAnchor(id: item.anchor.id)
    }

    private func citations(_ items: [CitationContent]) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            ForEach(items) { citation in
                Button { reader.openCitation(citation.target) } label: {
                    Label(citation.title + " · 原文第 " + String(citation.physicalPage) + " 页", systemImage: "doc.viewfinder")
                        .frame(minHeight: 44, alignment: .leading)
                }.buttonStyle(.plain).accessibilityIdentifier("study-open-pdf")
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
