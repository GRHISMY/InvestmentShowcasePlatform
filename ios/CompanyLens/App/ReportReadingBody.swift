import SwiftUI
#if SWIFT_PACKAGE
import ResearchCore
#endif

/// The complete authored report, with resolved links and semantic anchors.
/// All research relationships and navigation decisions arrive from the reader.
struct ReportReadingBody: View {
    let page: ReportPage
    let follow: (ReadingLink) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 28) {
            VStack(alignment: .leading, spacing: 28) {
                introduction
                if !page.headlineClaims.isEmpty {
                    VStack(alignment: .leading, spacing: 16) {
                        Text("先读这几条").font(.title2.weight(.semibold))
                        ForEach(page.headlineClaims) { item in
                            ReportClaimButton(item: item, identifier: "report-link-" + item.id, follow: follow)
                        }
                    }
                }
            }.readingAnchor(id: page.summaryAnchor.id)
            ForEach(page.sections) { section in
                VStack(alignment: .leading, spacing: 28) {
                    VStack(alignment: .leading, spacing: 12) {
                        Rectangle().frame(height: 1)
                        Text(section.title).font(.system(.title, design: .serif))
                    }.readingAnchor(id: section.anchor.id)
                    ForEach(section.claims, id: \.claim.id) { content in
                        ReportClaimBody(content: content, follow: follow)
                    }
                }
            }
            if let anchor = page.limitationsAnchor {
                VStack(alignment: .leading, spacing: 14) {
                    Text("整份研究的适用范围").font(.title2.weight(.semibold))
                    ForEach(Array(page.limitations.enumerated()), id: \.offset) { _, text in ResearchText(text: text) }
                }.readingAnchor(id: anchor.id)
            }
            dimensions
            monitoring
        }
        .textSelection(.enabled)
    }

    private var introduction: some View {
        VStack(alignment: .leading, spacing: 20) {
            Text(page.title).font(.system(.largeTitle, design: .serif))
                .accessibilityAddTraits(.isHeader)
            VStack(alignment: .leading, spacing: 6) {
                Text(page.coverage.start + " — " + page.coverage.end).font(.caption.monospaced())
                Text("资料查到 " + page.researchAsOf + " · 第 " + String(page.revision) + " 版")
                    .font(.caption).foregroundStyle(StudyInk.muted)
            }
            ResearchText(text: page.summary).font(.title3)
        }
    }

    private var dimensions: some View {
        VStack(alignment: .leading, spacing: 24) {
            Text("按关心的问题查找").font(.system(.title, design: .serif))
            ForEach(page.dimensions) { item in
                VStack(alignment: .leading, spacing: 14) {
                    Text(item.title).font(.headline)
                    if !item.summary.isEmpty { ResearchText(text: item.summary) }
                    ForEach(item.claims) { link in
                        ReportClaimButton(item: link, identifier: "report-dimension-" + item.id + "-" + link.id,
                                          follow: follow)
                    }
                }.readingAnchor(id: item.anchor.id)
            }
        }
    }

    private var monitoring: some View {
        VStack(alignment: .leading, spacing: 24) {
            Text("接下来，还要查什么").font(.system(.title, design: .serif))
            ForEach(page.monitoring) { item in
                VStack(alignment: .leading, spacing: 14) {
                    ResearchText(text: item.description)
                    ForEach(item.claims) { link in
                        ReportClaimButton(item: link, identifier: "report-monitor-" + item.id + "-" + link.id,
                                          follow: follow)
                    }
                }.readingAnchor(id: item.anchor.id)
            }
        }
    }
}

private struct ReportClaimButton: View {
    let item: ReportClaimLink
    let identifier: String
    let follow: (ReadingLink) -> Void

    var body: some View {
        Button { follow(item.link) } label: {
            HStack(alignment: .top, spacing: 12) {
                VStack(alignment: .leading, spacing: 7) {
                    Text(item.title).font(.headline)
                    Text(item.summary).font(.subheadline).foregroundStyle(StudyInk.muted)
                }.frame(maxWidth: .infinity, alignment: .leading)
                Image(systemName: "arrow.up.right").padding(.top, 3)
            }
            .multilineTextAlignment(.leading).padding(.vertical, 12).contentShape(Rectangle())
        }.buttonStyle(.plain).accessibilityIdentifier(identifier)
    }
}

private struct ReportClaimBody: View {
    let content: ReportClaimContent
    let follow: (ReadingLink) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 22) {
            block(.heading) {
                VStack(alignment: .leading, spacing: 14) {
                    Text(content.claim.title).font(.title2.weight(.semibold)).accessibilityAddTraits(.isHeader)
                        .accessibilityIdentifier("report-heading-" + content.claim.id)
                    ResearchText(text: content.claim.plainLanguage).font(.title3)
                    Text(content.scope).font(.caption).foregroundStyle(StudyInk.muted)
                }
            }
            block(.known) { section("我们查到了什么", text: content.claim.statement) }
            block(.meaning) { section("这和赚钱、用钱有什么关系", text: content.claim.financialImpact) }
            block(.gaps) {
                section("还没查清的事", texts: content.claim.gaps.map(\.description))
            }
            block(.alternatives) { section("还可能有别的解释", texts: content.claim.alternatives) }
            block(.facts) { facts }
            if content.calculations != nil || content.evidence != nil { verification }
            block(.reasoning) { section("研究过程", texts: content.claim.reasoning) }
            block(.limitations) { section("这条判断能说明到哪里", texts: content.claim.limitations) }
            block(.changeConditions) { section("什么会让我们重新判断", texts: content.claim.changeConditions) }
            if !content.relatedDiagrams.isEmpty { relatedDiagrams }
        }
        .padding(.vertical, 14)
    }

    @ViewBuilder private func block<Content: View>(_ part: ReportClaimPart,
                                                  @ViewBuilder content: () -> Content) -> some View {
        if let anchor = self.content.anchor(for: part) {
            content().readingAnchor(id: anchor.id)
        }
    }

    private func section(_ title: String, text: String) -> some View {
        section(title, texts: [text])
    }

    private func section(_ title: String, texts: [String]) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(title).font(.headline)
            ForEach(Array(texts.enumerated()), id: \.offset) { _, text in ResearchText(text: text) }
        }
    }

    private var facts: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("引用的原始数字").font(.headline)
            ForEach(content.facts, id: \.fact.id) { item in
                VStack(alignment: .leading, spacing: 6) {
                    Text(factTitle(item.fact, periodLabel: item.periodLabel)).font(.subheadline.weight(.semibold))
                    Text(factValue(item.fact)).font(.title3).monospacedDigit()
                    Text(item.entityName + " · " + item.periodLabel).font(.caption).foregroundStyle(StudyInk.muted)
                    if !item.fact.note.isEmpty { ResearchText(text: item.fact.note).font(.footnote) }
                }
            }
        }
    }

    private var verification: some View {
        VStack(alignment: .leading, spacing: 10) {
            if let link = content.calculations {
                Button { follow(link) } label: { Label("核对这些数字怎么算", systemImage: "equal.square") }
                    .accessibilityIdentifier("report-calculation-" + content.claim.id)
            }
            if let link = content.evidence {
                Button { follow(link) } label: { Label("查看依据与全部原页", systemImage: "doc.text.magnifyingglass") }
                    .accessibilityIdentifier("report-evidence-" + content.claim.id)
            }
        }.buttonStyle(.plain).frame(minHeight: 44, alignment: .leading)
    }

    private var relatedDiagrams: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("在图中看这条判断").font(.headline)
            ForEach(content.relatedDiagrams) { item in
                Button { follow(item.link) } label: {
                    VStack(alignment: .leading, spacing: 6) {
                        Label(item.sceneTitle + " · " + item.focusTitle, systemImage: "arrow.up.right")
                            .font(.subheadline.weight(.medium))
                        Text(item.question).font(.caption).foregroundStyle(StudyInk.muted)
                    }
                    .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain).accessibilityIdentifier("report-diagram-" + item.id)
            }
        }
    }
}
