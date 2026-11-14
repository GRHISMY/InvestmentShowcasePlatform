import SwiftUI
#if SWIFT_PACKAGE
import ResearchCore
#endif

/// One platform host forwards user intent to the reader and observes visible
/// content. Pages neither assemble reading history nor coordinate storage.
struct StudyReaderHost: View {
    private let study: ReadableStudy
    private let bookmarkKey: String
    @ReadingState private var reader: StudyReader
    @ReadingState private var diagramViewports: [SourceVisitID: DiagramViewport] = [:]
    @Environment(\.scenePhase) private var scenePhase

    init(study: ReadableStudy) {
        self.study = study
        let reading = study.identity
        bookmarkKey = "reading-package-v1." + reading.snapshotID + "." + (reading.readingID ?? "report")
            + ".r" + String(reading.readingRevision ?? 0)
        _reader = ReadingState(initialValue: StudyReader(study: study,
            bookmark: UserDefaults.standard.data(forKey: bookmarkKey)))
    }

    private var presentation: LegacyReadingPresentation? {
        if case .legacyPresentation(let page) = reader.page { return page }
        return nil
    }

    var body: some View {
        let shownPresentation = presentation
        let shownDiagram = reader.fullscreenDiagram
        VStack(spacing: 0) {
            masthead
            Rectangle().fill(.black).frame(height: 1)
            modePicker
            if let notice = reader.notice {
                Text(notice).font(.footnote).padding(12).frame(maxWidth: .infinity, alignment: .leading)
            }
            primaryPage
        }
        .frame(maxWidth: 680, maxHeight: .infinity)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(StudyInk.paper.ignoresSafeArea())
        .foregroundStyle(.black).tint(.black).preferredColorScheme(.light)
        .sheet(isPresented: Binding(
            get: { presentation != nil },
            set: { visible in
                if !visible, let token = shownPresentation?.presentationToken {
                    reader.dismissPresentation(token)
                }
            }
        )) {
            if let shownPresentation {
                legacyPresentation(shownPresentation)
                    .environment(\.studyPackageResources, shownPresentation.study.resources)
                    .id(shownPresentation.presentationToken)
            }
        }
        .diagramCover(isPresented: Binding(
            get: { reader.fullscreenDiagram != nil },
            set: { visible in
                if !visible, let token = shownDiagram?.presentationToken { reader.dismissPresentation(token) }
            }
        )) {
            if let shownDiagram { fullscreenDiagram(shownDiagram) }
        }
        .onChange(of: reader.localBookmark) { _, _ in persist() }
        .onChange(of: scenePhase) { _, phase in if phase != .active { persist() } }
    }

    private var masthead: some View {
        HStack(spacing: 10) {
            Text("研").font(.system(size: 24, design: .serif)).foregroundStyle(StudyInk.paper)
                .frame(width: 35, height: 39).background(.black)
            VStack(alignment: .leading, spacing: 3) {
                Text("黑白研究档案").font(.subheadline.weight(.semibold)).tracking(2)
                Text(study.research.research.company.name + " / " + study.research.research.company.code)
                    .font(.caption.monospaced()).foregroundStyle(StudyInk.muted)
            }
            Spacer(minLength: 8)
            switch reader.primaryPage {
            case .overview:
                Button("完整报告 ↗") { reader.switchMode(.report) }
                    .accessibilityIdentifier("study-archive")
            case .diagram(let page):
                Button { reader.follow(page.overview) } label: {
                    Label("全貌", systemImage: "viewfinder")
                }.accessibilityIdentifier("study-overview")
            case .report(let page):
                Menu {
                    ForEach(page.contents) { item in
                        Button(item.title) { reader.follow(item.link) }
                    }
                } label: {
                    Label("目录", systemImage: "list.bullet").frame(minHeight: 44)
                }
                .accessibilityLabel("完整报告目录").accessibilityIdentifier("report-contents")
            case .legacyPresentation: EmptyView()
            }
        }
        .font(.subheadline).buttonStyle(.plain)
        .frame(minHeight: 48).padding(.horizontal, 22).padding(.vertical, 10)
    }

    @ViewBuilder private var primaryPage: some View {
        switch reader.primaryPage {
        case .overview(let page): overview(page)
        case .diagram(let page): diagram(page)
        case .report(let page): report(page)
        case .legacyPresentation: EmptyView()
        }
    }

    private var selectedMode: ReadingMode {
        if case .report = reader.primaryPage { return .report }
        return .diagram
    }

    @ViewBuilder private var modePicker: some View {
        if reader.availableModes.count > 1 {
            HStack(spacing: 0) {
                ForEach(reader.availableModes, id: \.self) { mode in
                    Button { reader.switchMode(mode) } label: {
                        Text(mode == .diagram ? "图解阅读" : "完整报告")
                            .font(.subheadline.weight(.medium)).frame(maxWidth: .infinity, minHeight: 44)
                            .foregroundStyle(selectedMode == mode ? StudyInk.paper : Color.black)
                            .background(selectedMode == mode ? Color.black : Color.clear)
                    }
                    .buttonStyle(.plain).disabled(selectedMode == mode)
                    .accessibilityIdentifier("reader-mode-" + mode.rawValue)
                    .accessibilityAddTraits(selectedMode == mode ? .isSelected : [])
                }
            }.padding(.horizontal, 24).padding(.vertical, 8)
        }
    }

    private func report(_ page: ReportPage) -> some View {
        VStack(spacing: 0) {
            ReaderScroll(observation: page.observation, restorePosition: page.restorePosition,
                         arrivalCause: page.arrivalCause, onPosition: { token, position, cause in
                reader.reportVisiblePosition(token, position: position, cause: cause)
            }) {
                ReportReadingBody(page: page, follow: { reader.follow($0) })
            }
            HStack {
                Button { reader.back() } label: { Label("回到刚才", systemImage: "arrow.left") }
                    .disabled(!reader.navigation.canGoBack).accessibilityIdentifier("study-back")
                Spacer()
                Text("完整报告").font(.caption).foregroundStyle(StudyInk.muted)
            }
            .buttonStyle(.plain).frame(minHeight: 48).padding(.horizontal, 24).background(StudyInk.paper)
        }
    }

    private func overview(_ page: OverviewPage) -> some View {
        ReaderScroll(observation: page.observation,
                     restorePosition: page.restorePosition, arrivalCause: page.arrivalCause,
                     onPosition: { token, position, cause in
                         reader.reportVisiblePosition(token, position: position, cause: cause)
                     }) {
            VStack(alignment: .leading, spacing: 24) {
                Text(page.title).font(.system(.largeTitle, design: .serif))
                    .fixedSize(horizontal: false, vertical: true)
                Text("研究路线 · 选一处自由看").font(.caption).foregroundStyle(StudyInk.muted)
                LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 12) {
                    ForEach(page.entries) { item in
                        Button { reader.follow(item.link) } label: {
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
                }
                Text("这次研究看到什么").font(.caption.weight(.semibold)).tracking(2)
                ResearchText(text: page.summary).font(.title3)
                VStack(alignment: .leading, spacing: 5) {
                    Text(page.coverage.start + " — " + page.coverage.end).font(.caption.monospaced())
                    Text("资料查到 " + page.researchAsOf + " · " + (page.coverageMode == "complete" ? "完整研究" : "图解为研究节选"))
                        .font(.caption).foregroundStyle(StudyInk.muted)
                }
                Button { reader.follow(page.beginOrResume) } label: {
                    HStack { Text("进入图解阅读"); Spacer(); Image(systemName: "arrow.right") }
                        .font(.headline).padding(20).foregroundStyle(StudyInk.paper).background(.black)
                }.buttonStyle(.plain).accessibilityIdentifier("study-begin")
                Button("重新从头看 →") { reader.follow(page.restart) }
                    .frame(minHeight: 44).buttonStyle(.plain).accessibilityIdentifier("study-restart")
            }.readingAnchor(id: "overview")
        }
    }

    private func diagram(_ page: DiagramPage) -> some View {
        VStack(spacing: 0) {
            ReaderScroll(observation: page.observation,
                         restorePosition: page.restorePosition, arrivalCause: page.arrivalCause,
                         onPosition: { token, position, cause in
                             reader.reportVisiblePosition(token, position: position, cause: cause)
                         }) {
                VStack(alignment: .leading, spacing: 12) {
                    HStack {
                        Text(page.section).font(.caption.weight(.semibold)).tracking(2)
                        Spacer()
                        Text(String(format: "%02d / %02d", page.ordinal, page.sceneCount))
                            .font(.caption.monospaced()).foregroundStyle(StudyInk.muted)
                    }
                    Text(page.title).font(.system(.title, design: .serif))
                        .fixedSize(horizontal: false, vertical: true)
                    Text(page.question).font(.subheadline).foregroundStyle(StudyInk.muted)
                }.readingAnchor(id: "heading")
                Button { reader.enlargeDiagram() } label: {
                    Label("放大查看这张图", systemImage: "arrow.up.left.and.arrow.down.right")
                        .frame(minHeight: 44)
                }.buttonStyle(.plain).accessibilityIdentifier("study-enlarge-diagram")
                StudyDiagram(view: page.diagram.raw, focus: page.focus.id, periods: page.diagram.periods) { id in
                    if let choice = page.diagram.choice(for: id) { reader.selectFocus(choice) }
                }
                .readingAnchor(id: "diagram").accessibilityIdentifier("study-diagram")
                VStack(alignment: .leading, spacing: 10) {
                    Text(page.focus.title).font(.headline)
                    ResearchText(text: page.focus.body)
                    Button("展开解释 ↗") { reader.follow(page.focus.explanation) }.frame(minHeight: 44)
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
                            Button { reader.follow(item.link) } label: {
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

    private func fullscreenDiagram(_ viewing: FullscreenDiagramPresentation) -> some View {
        let page = viewing.diagram
        return DiagramFullscreenView(
            raw: page.diagram.raw, periods: page.diagram.periods, selectedFocus: page.focus.id,
            renderID: AnyHashable(viewing.observation), viewport: diagramViewports[page.visitID] ?? DiagramViewport(),
            onViewportChange: { viewport, _ in
                guard reader.fullscreenDiagram?.observation == viewing.observation else { return }
                diagramViewports[page.visitID] = viewport
            },
            onDisplayed: { rendered in
                guard rendered == AnyHashable(viewing.observation) else { return }
                reader.reportFullscreenDiagramDisplayed(viewing.observation)
            },
            onSelect: { id in
                if let choice = page.diagram.choice(for: id) { reader.selectFocus(choice) }
            },
            onClose: { reader.dismissPresentation(viewing.presentationToken) }
        )
        .id(viewing.presentationToken)
    }

    private func diagramActions(_ page: DiagramPage) -> some View {
        VStack(spacing: 8) {
            Rectangle().fill(StudyInk.line).frame(height: 0.5)
            HStack {
                Button {
                    if let link = page.focus.evidence { reader.follow(link) }
                } label: { Label("看原页依据", systemImage: "doc.text.magnifyingglass") }
                    .disabled(page.focus.evidence == nil).accessibilityIdentifier("study-evidence")
                Spacer()
                Button {
                    if let link = page.focus.calculations { reader.follow(link) }
                } label: { Label("数字怎么算", systemImage: "equal") }
                    .disabled(page.focus.calculations == nil).accessibilityIdentifier("study-calculation")
            }.font(.subheadline).frame(minHeight: 44)
            if page.isMainlineEnd {
                Text("主线已到末尾 · 可以回到全貌，或深入完整报告与依据")
                    .font(.caption).foregroundStyle(StudyInk.muted)
                    .accessibilityIdentifier("study-mainline-end")
            }
            HStack(spacing: 14) {
                Button { reader.back() } label: { Image(systemName: "arrow.left").frame(width: 44, height: 48) }
                    .disabled(!reader.navigation.canGoBack).accessibilityLabel("回到刚才")
                    .accessibilityIdentifier("study-back")
                Button { reader.advanceMainline() } label: {
                    HStack {
                        Text(page.isMainlineEnd ? "主线已到末尾" : page.nextLabel)
                        Spacer(minLength: 4)
                        Image(systemName: "arrow.right")
                    }
                    .font(.body.weight(.medium)).padding(.horizontal, 16)
                    .frame(maxWidth: .infinity, minHeight: 50)
                    .foregroundStyle(StudyInk.paper).background(.black)
                }
                .disabled(!reader.navigation.canAdvanceMainline).accessibilityIdentifier("study-next")
            }
        }
        .buttonStyle(.plain).padding(.horizontal, 24).padding(.bottom, 12).background(StudyInk.paper)
    }

    @ViewBuilder private func legacyPresentation(_ page: LegacyReadingPresentation) -> some View {
        switch page.kind {
        case .explanation:
            StudyExplanationSheet(title: page.title, text: page.text, caveat: page.caveat)
        case .calculations:
            StudyCalculationReader(library: page.study.research, calculationIDs: page.calculations.map(\.id))
        case .evidence:
            StudyEvidenceReader(library: page.study.research, ids: page.evidence.map(\.id),
                                counterIDs: page.counterEvidenceIDs, context: page.title)
        }
    }

    private func persist() {
        if let data = reader.localBookmark { UserDefaults.standard.set(data, forKey: bookmarkKey) }
    }
}

/// Native geometry stays here. The token and cause are observations, not a
/// second decision about which reading record should win.
private struct ReaderScroll<Content: View>: View {
    let observation: ObservationToken
    let restorePosition: ReadingPosition?
    let arrivalCause: PositionCause
    let onPosition: (ObservationToken, ReadingPosition, PositionCause) -> Void
    @ViewBuilder let content: Content
    var body: some View {
        ReadingScrollView(renderID: AnyHashable(observation),
                          target: restorePosition.map {
                              ReadingScrollPosition(anchorID: $0.anchorID, localOffset: CGFloat($0.localOffset ?? 0))
                          }, onObservation: { event in
            guard event.renderID == AnyHashable(observation) else { return }
            let cause: PositionCause
            switch event.cause {
            case .arrival: cause = arrivalCause
            case .userBrowsing: cause = .userBrowsing
            }
            onPosition(observation, ReadingPosition(anchorID: event.position.anchorID,
                       localOffset: Double(event.position.localOffset)), cause)
        }) {
            VStack(alignment: .leading, spacing: 22) { content }
                .padding(24).frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

private extension View {
    @ViewBuilder func diagramCover<Cover: View>(isPresented: Binding<Bool>, @ViewBuilder content: @escaping () -> Cover) -> some View {
        #if canImport(UIKit)
        fullScreenCover(isPresented: isPresented, content: content)
        #else
        sheet(isPresented: isPresented, content: content)
        #endif
    }
}
