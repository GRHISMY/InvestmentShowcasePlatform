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
        VStack(alignment: .leading, spacing: 32) {
            VStack(alignment: .leading, spacing: 32) {
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
                VStack(alignment: .leading, spacing: 32) {
                    VStack(alignment: .leading, spacing: 12) {
                        Divider()
                        Text(section.title).font(.title.bold()).accessibilityAddTraits(.isHeader)
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
        .font(.body)
        .foregroundStyle(.primary)
        .frame(maxWidth: 620, alignment: .leading)
        .frame(maxWidth: .infinity, alignment: .center)
        .textSelection(.enabled)
    }

    private var introduction: some View {
        VStack(alignment: .leading, spacing: 20) {
            Text("完整研究").font(.largeTitle.bold())
                .accessibilityAddTraits(.isHeader)
                .accessibilityIdentifier("report-summary-heading")
            VStack(alignment: .leading, spacing: 6) {
                Text(page.coverage.start + " — " + page.coverage.end).font(.caption.monospaced())
                Text("资料查到 " + page.researchAsOf + " · 第 " + String(page.revision) + " 版")
                    .font(.caption).foregroundStyle(.secondary)
            }
            ResearchText(text: page.summary).font(.body)
        }
    }

    private var dimensions: some View {
        VStack(alignment: .leading, spacing: 24) {
            Text("按关心的问题查找").font(.title.bold())
            ForEach(page.dimensions) { item in
                VStack(alignment: .leading, spacing: 14) {
                    Text(item.title).font(.headline).accessibilityAddTraits(.isHeader)
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
            Text("接下来，还要查什么").font(.title.bold())
            ForEach(page.monitoring) { item in
                VStack(alignment: .leading, spacing: 14) {
                    ResearchText(text: item.description)
                    Text("状态：" + monitoringStatus(item.status))
                        .font(.caption).foregroundStyle(.secondary)
                        .accessibilityIdentifier("report-monitor-status-" + item.id)
                    if let trigger = item.trigger {
                        Text("何时跟进：" + monitoringTrigger(trigger))
                            .font(.caption).foregroundStyle(.secondary)
                            .accessibilityIdentifier("report-monitor-trigger-" + item.id)
                    }
                    ForEach(item.claims) { link in
                        ReportClaimButton(item: link, identifier: "report-monitor-" + item.id + "-" + link.id,
                                          follow: follow)
                    }
                }.readingAnchor(id: item.anchor.id)
            }
        }
    }

    private func monitoringStatus(_ status: String) -> String {
        status == "pending" ? "待核对" : status
    }

    private func monitoringTrigger(_ trigger: String) -> String {
        switch trigger {
        case "next_report": return "下一份报告披露时"
        case "qualitative_event": return "相关事件发生时"
        default: return trigger
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
                    Text(item.summary).font(.subheadline).foregroundStyle(.secondary)
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
                    Text(content.scope).font(.caption).foregroundStyle(.secondary)
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
            relatedDiagrams
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
                    Text(item.entityName + " · " + item.periodLabel).font(.caption).foregroundStyle(.secondary)
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
        }
        .buttonStyle(.plain).font(.subheadline.weight(.medium)).foregroundStyle(.tint)
        .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
        .padding(18)
        .background(.quaternary.opacity(0.4), in: RoundedRectangle(cornerRadius: 18))
    }

    private var relatedDiagrams: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("在图中看这条判断").font(.headline)
            if content.relatedDiagrams.isEmpty {
                Text(content.calculations != nil || content.evidence != nil
                     ? "这条判断暂无关联图解，可继续核对计算与依据。" : "这条判断暂无关联图解。")
                    .font(.subheadline).foregroundStyle(.secondary)
                    .accessibilityIdentifier("report-no-diagram-" + content.claim.id)
            } else if content.relatedDiagrams.count > 1 {
                Text("选择一个相关位置").font(.subheadline).foregroundStyle(.secondary)
            }
            ForEach(content.relatedDiagrams) { item in
                Button { follow(item.link) } label: {
                    VStack(alignment: .leading, spacing: 6) {
                        Label(item.sceneTitle + " · " + item.focusTitle, systemImage: "arrow.up.right")
                            .font(.subheadline.weight(.medium))
                        Text(item.question).font(.caption).foregroundStyle(.secondary)
                    }
                    .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain).accessibilityIdentifier("report-diagram-" + item.id)
            }
        }
    }
}
