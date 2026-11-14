import SwiftUI
#if SWIFT_PACKAGE
import ResearchCore
#endif
#if canImport(UIKit)
import UIKit
#else
import AppKit
#endif

enum ReadingTheme {
    static let accent = Color.black
    static let background = Color.white
    static let paper = Color.white
}
struct ReadingCard<Content: View>: View {
    @ViewBuilder let content: Content
    var body: some View {
        VStack(alignment: .leading, spacing: 14) { content }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(18).background(ReadingTheme.paper)
            .overlay(Rectangle().stroke(Color.black.opacity(0.15), lineWidth: 0.5))
    }
}
struct ReadingHeading: View {
    let title: String
    var body: some View { Text(title).font(.headline).foregroundStyle(.primary).accessibilityAddTraits(.isHeader) }
}
struct LimitNote: View {
    let title: String
    let text: String
    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            Label(title, systemImage: "info.circle").font(.subheadline.weight(.semibold))
            Text(text).font(.subheadline).lineSpacing(5)
        }
        .foregroundStyle(.primary).padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color(white: 0.95))
        .overlay(Rectangle().stroke(Color.black.opacity(0.12), lineWidth: 0.5))
    }
}
struct ReadingAction: View {
    let title: String
    let symbol: String
    let action: () -> Void
    var body: some View {
        Button(action: action) {
            Label(title, systemImage: symbol).font(.body.weight(.semibold))
                .frame(maxWidth: .infinity, minHeight: 44)
        }.buttonStyle(.borderedProminent)
    }
}
struct CompanyMark: View {
    let name: String
    var body: some View {
        Text(String(name.prefix(1))).font(.system(size: 28, design: .serif))
            .frame(width: 48, height: 48)
            .overlay(Rectangle().stroke(.black.opacity(0.2), lineWidth: 0.5))
            .accessibilityLabel(name + "，研究对象")
    }
}

/// The route is the stable reading identity. Section anchors survive push, pop and glossary sheets.
struct RememberedReading<Content: View>: View {
    let route: ReaderRoute
    @ObservedObject var session: ReaderSession
    @ViewBuilder let content: Content
    @ReadingState private var anchor: String?
    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 20) { content }
                .padding(20).scrollTargetLayout()
        }
        .scrollPosition(id: $anchor, anchor: .top)
        .background(ReadingTheme.background)
        .onAppear { anchor = session.state.anchor(for: route) }
        .onChange(of: anchor) { _, value in
            if let value { session.send(.rememberAnchor(route: route, anchor: value)) }
        }
    }
}
/// Render the author's own paragraphs. Relative appendix links are replaced by
/// their labels because the native evidence routes below own those destinations.
struct ResearchText: View {
    let text: String
    var body: some View {
        let readable = text.replacingOccurrences(
            of: #"\[([^\]]+)\]\(evidence\.md[^)]*\)"#, with: "$1", options: .regularExpression)
        Text((try? AttributedString(markdown: readable,
            options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace))) ?? AttributedString(readable))
            .lineSpacing(6).textSelection(.enabled)
            .frame(maxWidth: .infinity, alignment: .leading)
    }
}

struct ClaimLink: View {
    let claim: ResearchClaim
    var compact = false
    let action: () -> Void
    var body: some View {
        Button(action: action) {
            HStack(alignment: .top, spacing: 14) {
                VStack(alignment: .leading, spacing: 9) {
                    Text(claim.title).font(compact ? .body.weight(.semibold) : .title3.bold())
                    if !compact { Text(claim.plainLanguage).font(.subheadline).lineSpacing(5) }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                Image(systemName: "arrow.up.right").font(.caption).padding(.top, 5)
            }
            .multilineTextAlignment(.leading).foregroundStyle(.primary)
            .padding(.vertical, 10).contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier("claim-" + claim.id)
        .accessibilityHint("打开解释、依据和还没查清的事")
    }
}

struct OverviewScreen: View {
    let library: ResearchLibrary
    @ObservedObject var session: ReaderSession
    private var paragraphs: [String] { library.research.report.summary.components(separatedBy: "\n\n") }
    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 25) {
                HStack(alignment: .top) {
                    VStack(alignment: .leading, spacing: 8) {
                        Text(library.research.company.code).font(.subheadline.monospaced()).tracking(2)
                        Text(library.research.company.name).font(.largeTitle.bold())
                    }
                    Spacer(minLength: 12)
                    CompanyMark(name: library.research.company.name)
                }
                VStack(spacing: 11) {
                    Rectangle().frame(height: 1)
                    ArchiveMetadata(label: "财报期间", value: library.research.report.coverage.start + " — " + library.research.report.coverage.end)
                    ArchiveMetadata(label: "资料查到", value: library.research.report.researchAsOf + " · 第" + String(library.research.report.revision) + "版")
                    Text("离线报告，日期之后的新消息尚未加入。")
                        .font(.caption).foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                VStack(alignment: .leading, spacing: 14) {
                    Text("这门生意怎么样").font(.caption.weight(.semibold)).tracking(2)
                    if let first = paragraphs.first { ResearchText(text: first).font(.title3) }
                }
                .padding(20).foregroundStyle(.white).background(.black)
                if paragraphs.count > 1 { ResearchText(text: paragraphs[1]) }
                HStack {
                    Text("先读这几条").font(.title2.bold())
                    Spacer()
                    Text("结论 → 依据 → 原页").font(.caption).foregroundStyle(.secondary)
                }
                ForEach(library.headlineClaims) { claim in
                    ReadingCard { ClaimLink(claim: claim) { session.openClaim(claim.id) } }
                }
                DisclosureGroup("阅读完整的总判断") {
                    VStack(alignment: .leading, spacing: 16) {
                        ForEach(Array(paragraphs.dropFirst(2).enumerated()), id: \.offset) { _, text in
                            ResearchText(text: text)
                        }
                    }.padding(.top, 14)
                }
                Rectangle().frame(height: 1)
                Text("全部研究 · " + String(library.orderedClaims.count) + "条结论").font(.title2.bold())
                Text("顺着公司的问题往下读，也可以直接选一条。").font(.subheadline).foregroundStyle(.secondary)
                ForEach(library.sections) { section in
                    VStack(alignment: .leading, spacing: 12) {
                        ReadingHeading(title: section.title)
                        ForEach(section.conclusionIds, id: \.self) { id in
                            if let claim = library.claim(id) {
                                Divider()
                                ClaimLink(claim: claim, compact: true) { session.openClaim(id) }
                            }
                        }
                    }.padding(.vertical, 6)
                }
                LimitNote(title: "读的时候要记住", text: library.research.report.limitations.joined(separator: "\n\n"))
            }.padding(20)
        }.background(ReadingTheme.background)
    }
}

struct ArchiveMetadata: View {
    let label: String
    let value: String
    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 14) {
            Text(label).font(.caption).foregroundStyle(.secondary).frame(width: 58, alignment: .leading)
            Text(value).font(.caption).frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

struct ClaimScreen: View {
    let claim: ResearchClaim
    let library: ResearchLibrary
    @ObservedObject var session: ReaderSession
    var body: some View {
        RememberedReading(route: .claim(claim.id), session: session) {
            VStack(alignment: .leading, spacing: 17) {
                Text("先把这件事说清楚").font(.caption).foregroundStyle(.secondary)
                Text(claim.title).font(.largeTitle.bold())
                ResearchText(text: claim.plainLanguage).font(.title3)
            }.id("conclusion")
            ReadingCard {
                ReadingHeading(title: "我们查到了什么")
                ResearchText(text: claim.statement)
            }.id("known")
            ReadingCard {
                ReadingHeading(title: "这和赚钱、用钱有什么关系")
                ResearchText(text: claim.financialImpact)
            }.id("meaning")
            if !claim.gaps.isEmpty {
                LimitNote(title: "还没查清的事", text: claim.gaps.map(\.description).joined(separator: "\n\n"))
                    .id("limits")
            }
            ReadingAction(title: "查看依据和计算", symbol: "doc.text.magnifyingglass") {
                session.send(.open(.evidence(claim.id)))
            }.id("evidence-action")
            if !claim.changeConditions.isEmpty {
                ReadingCard {
                    ReadingHeading(title: "什么会让我们重新判断")
                    ForEach(claim.changeConditions, id: \.self) { ResearchText(text: $0) }
                }.id("reconsider")
            }
            DisclosureGroup("展开研究过程与适用范围") {
                VStack(alignment: .leading, spacing: 16) {
                    Text(library.scope(of: claim)).font(.subheadline).foregroundStyle(.secondary)
                    ForEach(claim.reasoning, id: \.self) { ResearchText(text: $0) }
                    ForEach(claim.limitations, id: \.self) { ResearchText(text: $0).font(.footnote) }
                }.padding(.top, 12)
            }.id("research")
        }.navigationTitle("读懂这条结论").inlineReadingTitle()
    }
}

struct EvidenceRow: View {
    let page: EvidencePage
    let action: () -> Void
    var body: some View {
        Button(action: action) {
            HStack(spacing: 12) {
                Image(systemName: "doc.text")
                VStack(alignment: .leading, spacing: 5) {
                    Text("看PDF第" + String(page.physicalPage) + "页").font(.subheadline.weight(.semibold))
                    Text(page.title).font(.caption).foregroundStyle(.secondary)
                }
                Spacer(minLength: 4)
                Image(systemName: "chevron.right").font(.caption)
            }
            .foregroundStyle(.primary).frame(minHeight: 48).contentShape(Rectangle())
        }
        .buttonStyle(.plain).accessibilityIdentifier("source-" + page.id)
        .accessibilityHint("打开完整PDF中的这页，可以放大和选择文字")
    }
}

struct EvidenceCard: View {
    let evidence: ResearchEvidence
    let explanation: String
    let relation: String
    let claimID: String
    let library: ResearchLibrary
    @ObservedObject var session: ReaderSession
    private var role: String {
        switch relation {
        case "supports": return "支持这条判断"
        case "contradicts": return "需要同时考虑的反面材料"
        default: return "帮助理解背景"
        }
    }
    var body: some View {
        ReadingCard {
            Text(role).font(.caption).foregroundStyle(.secondary)
            ResearchText(text: explanation)
            DisclosureGroup("展开报告原话") {
                ResearchText(text: evidence.excerpt).font(.subheadline).padding(.top, 10)
            }
            if !evidence.locatorNote.isEmpty {
                DisclosureGroup("定位说明与材料限制") {
                    ResearchText(text: evidence.locatorNote).font(.footnote).padding(.top, 8)
                }
            }
            ForEach(library.pages(for: evidence.id)) { page in
                Divider()
                EvidenceRow(page: page) { session.send(.open(.source(claimID: claimID, evidenceID: page.id))) }
            }
        }
    }
}

func factValue(_ fact: ResearchFact) -> String {
    let unit: String
    switch fact.unit {
    case "CNY": unit = "元"
    case "CNY/share": unit = "元/股"
    case "percent": unit = "%"
    default: unit = fact.unit
    }
    let formatter = NumberFormatter()
    formatter.locale = Locale(identifier: "en_US_POSIX")
    formatter.numberStyle = .decimal
    formatter.usesGroupingSeparator = true
    let digits = fact.value.split(separator: ".").dropFirst().first?.count ?? 0
    formatter.minimumFractionDigits = digits
    formatter.maximumFractionDigits = digits
    return (formatter.string(from: NSDecimalNumber(string: fact.value, locale: Locale(identifier: "en_US_POSIX"))) ?? fact.value) + " " + unit
}

func factTitle(_ fact: ResearchFact, library: ResearchLibrary) -> String {
    // Translate machine-generated labels only; preserve authored Chinese labels.
    guard fact.label.contains(" / ") else { return fact.label }
    let names = [
        "cfo": "日常经营收款减去付款",
        "cash_sales": "销售收到的钱",
        "financial_loan_increase": "贷款与垫款净增加额",
        "money_funds": "账上货币资金",
        "term_deposits_outside_cash_equivalents": "未计入现金余额的定期存款和利息",
        "restricted_money_funds": "使用受限制的资金",
        "trading_financial_assets": "交易性金融资产",
        "other_debt_investments": "其他债权投资",
        "short_borrowings": "短期借款",
        "long_borrowings": "长期借款"
    ]
    guard let name = names[fact.metric] else { return fact.label }
    let period = library.research.periods.first { $0.id == fact.periodId }?.label ?? ""
    return period + " · " + name
}

struct EvidenceScreen: View {
    let claim: ResearchClaim
    let library: ResearchLibrary
    @ObservedObject var session: ReaderSession
    @ReadingState private var showLimits = false
    var body: some View {
        RememberedReading(route: .evidence(claim.id), session: session) {
            VStack(alignment: .leading, spacing: 12) {
                Text(claim.title).font(.title.bold())
                Text("数字和原话可以核对；解释和没查清的事也一起保留。")
                    .font(.subheadline).foregroundStyle(.secondary).lineSpacing(5)
            }.id("evidence-top")
            Picker("依据类型", selection: $showLimits) {
                Text("已有材料").tag(false)
                Text("反证与缺口").tag(true)
            }.pickerStyle(.segmented).id("evidence-tabs")
            if showLimits {
                if !claim.alternatives.isEmpty {
                    ReadingCard {
                        ReadingHeading(title: "还可能有别的解释")
                        ForEach(claim.alternatives, id: \.self) { ResearchText(text: $0) }
                    }.id("alternatives")
                }
                ForEach(claim.evidenceLinks.filter { $0.relation == "contradicts" }, id: \.evidenceId) { link in
                    if let item = library.evidence(link.evidenceId) {
                        EvidenceCard(evidence: item, explanation: link.explanation, relation: link.relation,
                            claimID: claim.id, library: library, session: session).id("counter-" + item.id)
                    }
                }
                if !claim.gaps.isEmpty {
                    LimitNote(title: "目前还缺什么", text: claim.gaps.map(\.description).joined(separator: "\n\n")).id("gaps")
                }
                ForEach(Array(claim.limitations.enumerated()), id: \.offset) { index, text in
                    ResearchText(text: text).font(.subheadline).id("limit-" + String(index))
                }
            } else {
                if !library.calculations(for: claim).isEmpty {
                    ReadingAction(title: "这些数字怎么算出来的", symbol: "equal.square") {
                        session.send(.open(.calculation(claim.id)))
                    }.id("calculation-action")
                }
                let facts = library.facts(for: claim)
                if !facts.isEmpty {
                    DisclosureGroup("查看引用的原始数字 · " + String(facts.count) + "项") {
                        VStack(alignment: .leading, spacing: 18) {
                            ForEach(facts) { fact in
                                VStack(alignment: .leading, spacing: 8) {
                                    Text(factTitle(fact, library: library)).font(.subheadline.weight(.semibold))
                                    Text(factValue(fact)).monospacedDigit().textSelection(.enabled)
                                    DisclosureGroup("原始名称和口径") {
                                        Text(fact.label + "\n" + fact.note).font(.footnote).padding(.top, 8)
                                    }
                                    ForEach(fact.evidenceIds, id: \.self) { evidenceID in
                                        ForEach(library.pages(for: evidenceID)) { page in
                                            EvidenceRow(page: page) { session.send(.open(.source(claimID: claim.id, evidenceID: page.id))) }
                                        }
                                    }
                                }
                                Divider()
                            }
                        }.padding(.top, 14)
                    }.id("facts")
                }
                ForEach(claim.evidenceLinks, id: \.evidenceId) { link in
                    if let item = library.evidence(link.evidenceId) {
                        EvidenceCard(evidence: item, explanation: link.explanation, relation: link.relation,
                            claimID: claim.id, library: library, session: session).id("support-" + item.id)
                    }
                }
            }
        }.navigationTitle("核对依据").inlineReadingTitle()
    }
}

struct CalculationScreen: View {
    let claimID: String
    let library: ResearchLibrary
    @ObservedObject var session: ReaderSession
    var body: some View {
        RememberedReading(route: .calculation(claimID), session: session) {
            Text("看懂数字怎么来的").font(.largeTitle.bold()).id("calculation-top")
            if let claim = library.claim(claimID) {
                Text(claim.title).font(.subheadline).foregroundStyle(.secondary)
                ForEach(library.calculations(for: claim)) { calculation in
                    ReadingCard {
                        ReadingHeading(title: calculation.title)
                        Text(calculation.result.displayValue + " " + calculation.result.displayUnit)
                            .font(.largeTitle.bold()).monospacedDigit().textSelection(.enabled)
                        ResearchText(text: calculation.explanation)
                    }.id("calculation-" + calculation.id)
                    ForEach(Array(calculation.inputs.enumerated()), id: \.offset) { index, input in
                        if let fact = library.fact(input.factId) {
                            ReadingCard {
                                Text(inputAction(input, index: index, operation: calculation.operation)).font(.caption).foregroundStyle(.secondary)
                                ReadingHeading(title: factTitle(fact, library: library))
                                Text(factValue(fact)).font(.title3).monospacedDigit().textSelection(.enabled)
                                DisclosureGroup("核对原始口径") {
                                    Text(fact.label + "\n" + fact.note + "\n计算系数：" + input.coefficient)
                                        .font(.footnote).padding(.top, 8)
                                }
                                ForEach(fact.evidenceIds, id: \.self) { evidenceID in
                                    ForEach(library.pages(for: evidenceID)) { page in
                                        EvidenceRow(page: page) { session.send(.open(.source(claimID: claimID, evidenceID: page.id))) }
                                    }
                                }
                            }.id(calculation.id + "-input-" + String(index))
                        }
                    }
                    if !calculation.limitations.isEmpty {
                        LimitNote(title: "这个结果能说明到哪里", text: calculation.limitations.joined(separator: "\n\n"))
                            .id(calculation.id + "-limits")
                    }
                }
            }
            Text("这里展示正式报告已经复核的结果，原始金额和对应PDF页都保留。").font(.footnote).foregroundStyle(.secondary)
        }.navigationTitle("核对计算").inlineReadingTitle()
    }
    private func inputAction(_ input: CalculationInput, index: Int, operation: String) -> String {
        guard operation == "linear_combination" else { return "原始输入 " + String(index + 1) }
        switch input.coefficient {
        case "1": return index == 0 ? "先取这个数" : "加上这个数"
        case "-1": return "减去这个数"
        default: return "这个数乘以 " + input.coefficient + " 后计入"
        }
    }
}

struct DimensionsScreen: View {
    let library: ResearchLibrary
    @ObservedObject var session: ReaderSession
    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 22) {
                Text("按你关心的问题查找").font(.largeTitle.bold())
                Text("这些是查找入口。报告的主线仍然跟着公司的实际问题走。")
                    .foregroundStyle(.secondary).lineSpacing(6)
                ForEach(library.research.presentation.dimensionOrder, id: \.self) { id in
                    if let dimension = library.dimension(id) {
                        Button { session.send(.open(.dimension(id))) } label: {
                            ReadingCard {
                                HStack {
                                    Text(dimension.title).font(.title3.bold())
                                    Spacer()
                                    Image(systemName: "chevron.right").font(.caption)
                                }
                                Text(String(dimension.conclusionIds.count) + "条相关判断").font(.subheadline).foregroundStyle(.secondary)
                                if !dimension.summary.isEmpty { ResearchText(text: dimension.summary).font(.subheadline) }
                            }.foregroundStyle(.primary)
                        }.buttonStyle(.plain)
                    }
                }
            }.padding(20)
        }.background(ReadingTheme.background)
    }
}

struct DimensionScreen: View {
    let dimension: ResearchDimension
    let library: ResearchLibrary
    @ObservedObject var session: ReaderSession
    var body: some View {
        RememberedReading(route: .dimension(dimension.id), session: session) {
            Text(dimension.title).font(.largeTitle.bold()).id("dimension-top")
            if !dimension.summary.isEmpty { ResearchText(text: dimension.summary) }
            ForEach(dimension.conclusionIds, id: \.self) { id in
                if let claim = library.claim(id) {
                    ReadingCard {
                        ClaimLink(claim: claim) { session.send(.open(.claim(id))) }
                    }.id("index-" + id)
                }
            }
        }.navigationTitle(dimension.title).inlineReadingTitle()
    }
}

struct MonitoringScreen: View {
    let library: ResearchLibrary
    @ObservedObject var session: ReaderSession
    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 22) {
                Text("接下来，还要查什么").font(.largeTitle.bold())
                Text("这是报告留下的调查问题。App不会自动替你查新公告，也不会把计划当作已经发生。")
                    .foregroundStyle(.secondary).lineSpacing(6)
                ForEach(library.research.monitoring) { item in
                    ReadingCard {
                        ResearchText(text: item.description)
                        ForEach(item.conclusionIds, id: \.self) { id in
                            if let claim = library.claim(id) {
                                Divider()
                                ClaimLink(claim: claim, compact: true) { session.openClaim(id) }
                            }
                        }
                    }
                }
            }.padding(20)
        }.background(ReadingTheme.background)
    }
}

struct SourceScreen: View {
    let page: EvidencePage
    @ObservedObject var session: ReaderSession
    @ReadingState private var command: PDFReadingAction = .locate
    @ReadingState private var commandID = 0
    @ReadingState private var currentPage = 0
    @ReadingState private var showLocation = true
    private var failed: Bool { session.state.pdfStatus == .failed(page.id) }
    private var loading: Bool { session.state.pdfStatus == .loading(page.id) }
    var body: some View {
        VStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 10) {
                Text(page.title).font(.headline)
                HStack {
                    Text("依据在PDF第" + String(page.physicalPage) + "页").font(.subheadline.weight(.medium))
                    Spacer(minLength: 5)
                    if currentPage > 0 { Text("正读第" + String(currentPage) + "页").font(.caption).foregroundStyle(.secondary) }
                }
                if showLocation {
                    Text("先找这一行：" + (page.focusText?.isEmpty == false ? page.focusText! : page.label))
                        .font(.footnote).lineLimit(3).textSelection(.enabled).foregroundStyle(.secondary)
                }
                Button(showLocation ? "收起定位提示" : "显示定位提示") { showLocation.toggle() }
                    .font(.caption).frame(minHeight: 30)
                HStack(spacing: 10) {
                    pdfButton("证据页", symbol: "scope", action: .locate)
                    pdfButton("放大", symbol: "plus.magnifyingglass", action: .zoomIn)
                    pdfButton("缩小", symbol: "minus.magnifyingglass", action: .zoomOut)
                    pdfButton("适应", symbol: "arrow.up.left.and.arrow.down.right", action: .fit)
                }
            }.padding(16).background(ReadingTheme.paper)
            Divider()
            if failed {
                ContentUnavailableView {
                    Label("这份原页暂时没打开", systemImage: "doc.questionmark")
                } description: {
                    Text("可以重试，也可以直接返回刚才的证据或计算。")
                } actions: {
                    Button("重新打开") { session.send(.retryPDF) }.buttonStyle(.borderedProminent)
                }
            } else {
                NativePDFReader(
                    request: PDFReadingRequest(
                        file: StudyResources.root.appendingPathComponent(page.documentFile),
                        physicalPage: page.physicalPage, focusText: page.focusText ?? "",
                        command: command, commandID: commandID
                    ),
                    onReady: { result in
                        switch result {
                        case .success(let count): session.send(.pdfLoaded(evidenceID: page.id, page: page.physicalPage, pageCount: count))
                        case .failure: session.send(.pdfFailed(evidenceID: page.id))
                        }
                    },
                    onPage: { currentPage = $0 }
                )
                .id(page.id)
                .overlay { if loading { ProgressView("正在打开原始PDF").padding(20).background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12)) } }
                .accessibilityLabel("完整PDF，可以缩放和选择文字")
            }
            Divider()
            HStack {
                Text("PDF物理页 · " + page.period).font(.caption).foregroundStyle(.secondary)
                Spacer()
                if !page.url.isEmpty, let url = URL(string: page.url) {
                    Link("原始发布链接", destination: url).font(.caption).frame(minHeight: 38)
                }
            }.padding(.horizontal, 16).background(ReadingTheme.paper)
        }
        .background(ReadingTheme.background)
        .navigationTitle("回到报告原页").inlineReadingTitle()
    }
    private func pdfButton(_ title: String, symbol: String, action: PDFReadingAction) -> some View {
        Button {
            command = action; commandID += 1
        } label: {
            VStack(spacing: 4) { Image(systemName: symbol); Text(title).font(.caption) }
                .frame(maxWidth: .infinity, minHeight: 44)
        }.buttonStyle(.plain).foregroundStyle(ReadingTheme.accent).disabled(failed || loading)
    }
}
