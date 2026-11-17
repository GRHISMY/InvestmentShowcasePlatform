import SwiftUI
#if SWIFT_PACKAGE
import ResearchCore
#endif

private var diagramReadingBackground: Color {
    #if canImport(UIKit)
    Color(uiColor: .systemGroupedBackground)
    #else
    Color(nsColor: .windowBackgroundColor)
    #endif
}

struct OverviewReadingPage: View {
    let page: OverviewPage
    let follow: (ReadingLink) -> Void
    let onPosition: (ObservationToken, ReadingPosition, PositionCause) -> Void

    var body: some View {
        ReaderScroll(observation: page.observation,
                     restorePosition: page.restorePosition, arrivalCause: page.arrivalCause,
                     onPosition: onPosition) {
            VStack(alignment: .leading, spacing: 26) {
                VStack(alignment: .leading, spacing: 10) {
                    Text("研究全貌").font(.subheadline).foregroundStyle(StudyInk.muted)
                    Text(page.title).font(.title.bold())
                        .fixedSize(horizontal: false, vertical: true)
                        .accessibilityAddTraits(.isHeader)
                    Text(page.company.name).font(.subheadline).foregroundStyle(StudyInk.muted)
                }
                VStack(alignment: .leading, spacing: 16) {
                    Text("这次研究看到什么").font(.title3.bold()).accessibilityAddTraits(.isHeader)
                    ResearchText(text: page.summary)
                    VStack(alignment: .leading, spacing: 6) {
                        Text(page.coverage.start + " — " + page.coverage.end).monospacedDigit()
                        Text("资料查到 " + page.researchAsOf + " · " + (page.coverageMode == "complete" ? "完整研究" : "图解为研究节选"))
                    }.font(.caption).foregroundStyle(StudyInk.muted)
                }
                Button { follow(page.beginOrResume) } label: {
                    Label("进入图解阅读", systemImage: "arrow.right")
                        .font(.headline).frame(maxWidth: .infinity, minHeight: 44)
                }
                .buttonStyle(.borderedProminent).controlSize(.large).accessibilityIdentifier("study-begin")
                VStack(alignment: .leading, spacing: 12) {
                    Text("研究路线").font(.title3.bold()).accessibilityAddTraits(.isHeader)
                    Text("选一处自由看，也可以从当前位置沿主线继续。")
                        .font(.subheadline).foregroundStyle(StudyInk.muted)
                    // Eager rows keep every published entry measurable after a source return.
                    ForEach(page.entries) { item in
                        Button { follow(item.link) } label: {
                            HStack(alignment: .top, spacing: 14) {
                                Image(systemName: item.icon).font(.title2)
                                    .frame(width: 32).frame(minHeight: 32).foregroundStyle(.tint)
                                VStack(alignment: .leading, spacing: 6) {
                                    Text(item.label).font(.headline)
                                    Text(item.caption).font(.subheadline).foregroundStyle(StudyInk.muted)
                                }.fixedSize(horizontal: false, vertical: true)
                                Spacer(minLength: 0)
                                Image(systemName: "chevron.right").font(.caption.weight(.semibold))
                                    .foregroundStyle(StudyInk.muted).padding(.top, 5)
                            }
                            .multilineTextAlignment(.leading).padding(18)
                            .frame(maxWidth: .infinity, minHeight: 64, alignment: .leading)
                            .background(.background, in: RoundedRectangle(cornerRadius: 20))
                            .contentShape(RoundedRectangle(cornerRadius: 20))
                        }
                        .buttonStyle(.plain).accessibilityIdentifier("study-map-" + item.sceneID)
                    }
                }
                Button("重新从头看") { follow(page.restart) }
                    .frame(minHeight: 44).accessibilityIdentifier("study-restart")
            }.readingAnchor(id: "overview")
        }
        .background(diagramReadingBackground)
    }
}

struct DiagramReadingPage: View {
    let page: DiagramPage
    let navigation: ReadingNavigation
    let follow: (ReadingLink) -> Void
    let selectFocus: (FocusChoice) -> Void
    let enlarge: () -> Void
    let back: () -> Void
    let advance: () -> Void
    let onPosition: (ObservationToken, ReadingPosition, PositionCause) -> Void

    var body: some View {
        VStack(spacing: 0) {
            ReaderScroll(observation: page.observation,
                         restorePosition: page.restorePosition, arrivalCause: page.arrivalCause,
                         onPosition: onPosition) {
                VStack(alignment: .leading, spacing: 12) {
                    Text(page.section + " · " + String(page.ordinal) + " / " + String(page.sceneCount))
                        .font(.subheadline).foregroundStyle(StudyInk.muted)
                    Text(page.title).font(.title.bold())
                        .fixedSize(horizontal: false, vertical: true)
                        .accessibilityAddTraits(.isHeader).accessibilityIdentifier("study-scene-title")
                    Text(page.question).font(.body).foregroundStyle(StudyInk.muted)
                        .fixedSize(horizontal: false, vertical: true)
                }.readingAnchor(id: "heading")
                VStack(alignment: .leading, spacing: 18) {
                    HStack(alignment: .firstTextBaseline) {
                        Text("图解").font(.headline).accessibilityAddTraits(.isHeader)
                        Spacer()
                        Button(action: enlarge) {
                            Label("全屏查看", systemImage: "arrow.up.left.and.arrow.down.right")
                                .font(.subheadline).frame(minHeight: 44)
                        }.accessibilityIdentifier("study-enlarge-diagram")
                    }
                    StudyDiagram(view: page.diagram.raw, focus: page.focus.id, periods: page.diagram.periods) { id in
                        if let choice = page.diagram.choice(for: id) { selectFocus(choice) }
                    }.accessibilityIdentifier("study-diagram")
                    Text("点选图中内容查看说明；宽图可横向拖动。")
                        .font(.caption).foregroundStyle(StudyInk.muted)
                }
                .padding(18).background(.background, in: RoundedRectangle(cornerRadius: 20))
                .readingAnchor(id: "diagram")
                VStack(alignment: .leading, spacing: 16) {
                    Text(page.focus.title).font(.title3.bold()).accessibilityAddTraits(.isHeader)
                        .accessibilityIdentifier("study-explanation")
                    ResearchText(text: page.focus.body)
                    Button { follow(page.focus.explanation) } label: {
                        Label("展开完整解释", systemImage: "text.alignleft").frame(minHeight: 44)
                    }
                    verificationActions
                }
                .padding(20).background(.background, in: RoundedRectangle(cornerRadius: 20))
                .readingAnchor(id: "explanation")
                VStack(alignment: .leading, spacing: 12) {
                    if !page.focus.caveat.isEmpty { ResearchText(text: page.focus.caveat) }
                    ForEach(page.focus.gaps) { gap in ResearchText(text: gap.description) }
                    ForEach(Array(page.essentialNotes.enumerated()), id: \.offset) { _, note in
                        ResearchText(text: note)
                    }
                    if page.focus.hasCounterEvidence {
                        Label("这处也有反证，核对依据时一并查看。", systemImage: "info.circle")
                    }
                }
                .font(.subheadline).foregroundStyle(StudyInk.muted)
                .readingAnchor(id: "limits").accessibilityIdentifier("study-essential-notes")
                if !page.relatedReports.isEmpty {
                    VStack(alignment: .leading, spacing: 12) {
                        Text("在完整报告中深入阅读").font(.headline).accessibilityAddTraits(.isHeader)
                        ForEach(page.relatedReports) { item in
                            Button { follow(item.link) } label: {
                                HStack(alignment: .top, spacing: 12) {
                                    Text(item.title).fixedSize(horizontal: false, vertical: true)
                                    Spacer(minLength: 0)
                                    Image(systemName: "arrow.up.right").font(.subheadline)
                                }
                                .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
                            }
                            .buttonStyle(.plain).accessibilityIdentifier("study-related-report-" + item.id)
                        }
                    }.padding(20).background(.background, in: RoundedRectangle(cornerRadius: 20))
                }
                if page.isMainlineEnd {
                    VStack(alignment: .leading, spacing: 12) {
                        Text("主线已到末尾 · 可以回到全貌，或深入完整报告与依据")
                            .font(.subheadline).foregroundStyle(StudyInk.muted)
                            .accessibilityIdentifier("study-mainline-end")
                        Button { follow(page.overview) } label: {
                            Label("回到研究全貌", systemImage: "viewfinder").frame(minHeight: 44)
                        }
                    }
                }
                diagramActions
            }
        }
        .background(diagramReadingBackground)
    }

    @ViewBuilder private var verificationActions: some View {
        if page.focus.evidence != nil || page.focus.calculations != nil {
            Divider()
            ViewThatFits(in: .horizontal) {
                HStack(spacing: 12) { verificationButtons }
                VStack(alignment: .leading, spacing: 8) { verificationButtons }
            }.buttonStyle(.bordered)
        }
    }

    @ViewBuilder private var verificationButtons: some View {
        if let link = page.focus.evidence {
            Button { follow(link) } label: {
                Label("看原页依据", systemImage: "doc.text.magnifyingglass")
                    .fixedSize(horizontal: false, vertical: true).frame(minHeight: 32)
            }.accessibilityIdentifier("study-evidence")
        }
        if let link = page.focus.calculations {
            Button { follow(link) } label: {
                Label("数字怎么算", systemImage: "equal")
                    .fixedSize(horizontal: false, vertical: true).frame(minHeight: 32)
            }.accessibilityIdentifier("study-calculation")
        }
    }

    private var diagramActions: some View {
        HStack(spacing: 12) {
            Button(action: back) {
                Image(systemName: "arrow.left").frame(minWidth: 32, minHeight: 36)
            }
            .buttonStyle(.bordered).disabled(!navigation.canGoBack)
            .accessibilityLabel("回到刚才").accessibilityIdentifier("study-back")
            Button(action: advance) {
                HStack(alignment: .center, spacing: 10) {
                    Text(page.isMainlineEnd ? "主线已到末尾" : page.nextLabel)
                        .fixedSize(horizontal: false, vertical: true)
                    Spacer(minLength: 0)
                    Image(systemName: "arrow.right")
                }
                .font(.body.weight(.medium)).frame(maxWidth: .infinity, minHeight: 36)
            }
            .buttonStyle(.borderedProminent).disabled(!navigation.canAdvanceMainline)
            .accessibilityIdentifier("study-next")
        }
        .padding(.vertical, 8)
    }
}

struct DiagramReadingToolbar: ToolbarContent {
    let overview: ReadingLink?
    let follow: (ReadingLink) -> Void
    let showReport: () -> Void
    var body: some ToolbarContent {
        ToolbarItem(placement: .primaryAction) {
            if let overview {
                Button { follow(overview) } label: { Label("研究全貌", systemImage: "list.bullet").foregroundStyle(.tint) }
                    .accessibilityIdentifier("study-overview")
            } else {
                Button("完整报告", action: showReport).foregroundStyle(.tint).accessibilityIdentifier("study-archive")
            }
        }
    }
}
