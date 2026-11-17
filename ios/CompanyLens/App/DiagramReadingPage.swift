import SwiftUI
#if SWIFT_PACKAGE
import ResearchCore
#endif

struct OverviewReadingPage: View {
    let page: OverviewPage
    let follow: (ReadingLink) -> Void
    let onPosition: (ObservationToken, ReadingPosition, PositionCause) -> Void
    var body: some View {
        ReaderScroll(observation: page.observation,
                     restorePosition: page.restorePosition, arrivalCause: page.arrivalCause,
                     onPosition: { token, position, cause in
                         onPosition(token, position, cause)
                     }) {
            VStack(alignment: .leading, spacing: 24) {
                Text(page.title).font(.system(.largeTitle, design: .serif))
                    .fixedSize(horizontal: false, vertical: true)
                Text("研究路线 · 选一处自由看").font(.caption).foregroundStyle(StudyInk.muted)
                VStack(spacing: 12) {
                    ForEach(0..<((page.entries.count + 1) / 2), id: \.self) { row in
                        HStack(spacing: 12) {
                            ForEach(Array(page.entries.dropFirst(row * 2).prefix(2))) { item in
                                Button { follow(item.link) } label: {
                                    VStack(spacing: 9) {
                                        Image(systemName: item.icon).font(.system(size: 24, weight: .light))
                                        Text(item.label).font(.body.weight(.medium))
                                        Text(item.caption).font(.caption).foregroundStyle(StudyInk.muted)
                                    }
                                    .multilineTextAlignment(.center).frame(maxWidth: .infinity, minHeight: 120)
                                    .padding(10).contentShape(Rectangle())
                                    .overlay(Rectangle().stroke(StudyInk.line, lineWidth: 0.5))
                                }
                                .buttonStyle(.plain).accessibilityIdentifier("study-map-" + item.sceneID)
                            }
                            if row * 2 + 1 >= page.entries.count {
                                Color.clear.frame(maxWidth: .infinity)
                            }
                        }
                    }
                }
                Text("这次研究看到什么").font(.caption.weight(.semibold)).tracking(2)
                ResearchText(text: page.summary).font(.title3)
                VStack(alignment: .leading, spacing: 5) {
                    Text(page.coverage.start + " — " + page.coverage.end).font(.caption.monospaced())
                    Text("资料查到 " + page.researchAsOf + " · " + (page.coverageMode == "complete" ? "完整研究" : "图解为研究节选"))
                        .font(.caption).foregroundStyle(StudyInk.muted)
                }
                Button { follow(page.beginOrResume) } label: {
                    HStack { Text("进入图解阅读"); Spacer(); Image(systemName: "arrow.right") }
                        .font(.headline).padding(20).foregroundStyle(StudyInk.paper).background(.black)
                }.buttonStyle(.plain).accessibilityIdentifier("study-begin")
                Button("重新从头看 →") { follow(page.restart) }
                    .frame(minHeight: 44).buttonStyle(.plain).accessibilityIdentifier("study-restart")
            }.readingAnchor(id: "overview")
        }
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
                         onPosition: { token, position, cause in
                             onPosition(token, position, cause)
                         }) {
                VStack(alignment: .leading, spacing: 12) {
                    HStack {
                        Text(page.section).font(.caption.weight(.semibold)).tracking(2)
                        Spacer()
                        Text(String(format: "%02d / %02d", page.ordinal, page.sceneCount))
                            .font(.caption.monospaced()).foregroundStyle(StudyInk.muted)
                    }
                    Text(page.title).font(.system(.title, design: .serif))
                        .fixedSize(horizontal: false, vertical: true).accessibilityIdentifier("study-scene-title")
                    Text(page.question).font(.subheadline).foregroundStyle(StudyInk.muted)
                }.readingAnchor(id: "heading")
                Button { enlarge() } label: {
                    Label("放大查看这张图", systemImage: "arrow.up.left.and.arrow.down.right")
                        .frame(minHeight: 44)
                }.buttonStyle(.plain).accessibilityIdentifier("study-enlarge-diagram")
                StudyDiagram(view: page.diagram.raw, focus: page.focus.id, periods: page.diagram.periods) { id in
                    if let choice = page.diagram.choice(for: id) { selectFocus(choice) }
                }
                .readingAnchor(id: "diagram").accessibilityIdentifier("study-diagram")
                VStack(alignment: .leading, spacing: 10) {
                    Text(page.focus.title).font(.headline)
                    ResearchText(text: page.focus.body)
                    Button("展开解释 ↗") { follow(page.focus.explanation) }.frame(minHeight: 44)
                }.readingAnchor(id: "explanation").accessibilityIdentifier("study-explanation")
                VStack(alignment: .leading, spacing: 10) {
                    if !page.focus.caveat.isEmpty { ResearchText(text: page.focus.caveat) }
                    ForEach(page.focus.gaps) { gap in ResearchText(text: gap.description) }
                    ForEach(Array(page.essentialNotes.enumerated()), id: \.offset) { _, note in
                        ResearchText(text: note)
                    }
                    if page.focus.hasCounterEvidence { Text("这处也有反证，核对依据时一并查看。") }
                }
                .font(.subheadline).foregroundStyle(StudyInk.muted)
                .readingAnchor(id: "limits").accessibilityIdentifier("study-essential-notes")
                if !page.relatedReports.isEmpty {
                    VStack(alignment: .leading, spacing: 10) {
                        Text("相关的完整判断").font(.headline)
                        ForEach(page.relatedReports) { item in
                            Button { follow(item.link) } label: {
                                Label(item.title, systemImage: "arrow.up.right")
                                    .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
                            }
                            .buttonStyle(.plain).accessibilityIdentifier("study-related-report-" + item.id)
                        }
                    }
                }
            }
            diagramActions(page)
        }
    }

    private func diagramActions(_ page: DiagramPage) -> some View {
        VStack(spacing: 8) {
            Rectangle().fill(StudyInk.line).frame(height: 0.5)
            HStack {
                Button {
                    if let link = page.focus.evidence { follow(link) }
                } label: { Label("看原页依据", systemImage: "doc.text.magnifyingglass") }
                    .disabled(page.focus.evidence == nil).accessibilityIdentifier("study-evidence")
                Spacer()
                Button {
                    if let link = page.focus.calculations { follow(link) }
                } label: { Label("数字怎么算", systemImage: "equal") }
                    .disabled(page.focus.calculations == nil).accessibilityIdentifier("study-calculation")
            }.font(.subheadline).frame(minHeight: 44)
            if page.isMainlineEnd {
                Text("主线已到末尾 · 可以回到全貌，或深入完整报告与依据")
                    .font(.caption).foregroundStyle(StudyInk.muted)
                    .accessibilityIdentifier("study-mainline-end")
            }
            HStack(spacing: 14) {
                Button { back() } label: { Image(systemName: "arrow.left").frame(width: 44, height: 48) }
                    .disabled(!navigation.canGoBack).accessibilityLabel("回到刚才")
                    .accessibilityIdentifier("study-back")
                Button { advance() } label: {
                    HStack {
                        Text(page.isMainlineEnd ? "主线已到末尾" : page.nextLabel)
                        Spacer(minLength: 4)
                        Image(systemName: "arrow.right")
                    }
                    .font(.body.weight(.medium)).padding(.horizontal, 16)
                    .frame(maxWidth: .infinity, minHeight: 50)
                    .foregroundStyle(StudyInk.paper).background(.black)
                }
                .disabled(!navigation.canAdvanceMainline).accessibilityIdentifier("study-next")
            }
        }
        .buttonStyle(.plain).padding(.horizontal, 24).padding(.bottom, 12).background(StudyInk.paper)
    }
}

struct DiagramReadingToolbar: ToolbarContent {
    let overview: ReadingLink?
    let follow: (ReadingLink) -> Void
    let showReport: () -> Void
    var body: some ToolbarContent {
        ToolbarItem(placement: .primaryAction) {
            if let overview {
                Button { follow(overview) } label: { Label("全貌", systemImage: "viewfinder") }
                    .accessibilityIdentifier("study-overview")
            } else {
                Button("完整报告 ↗", action: showReport).accessibilityIdentifier("study-archive")
            }
        }
    }
}
