import SwiftUI
#if SWIFT_PACKAGE
import ResearchCore
#endif

/// The single active host projects once and forwards opaque actions to Reader.
struct StudyReaderHost: View {
    let study: ReadableStudy
    @Binding var reader: StudyReader
    @Binding var diagramViewports: [SourceVisitID: DiagramViewport]
    let onLibrary: () -> Void

    var body: some View {
        let page = reader.primaryPage
        let shownPresentation = reader.presentationPath.first
        let shownDiagram = reader.fullscreenDiagram
        VStack(spacing: 0) {
            if let notice = reader.notice {
                Text(notice).font(.footnote).padding(12).frame(maxWidth: .infinity, alignment: .leading)
            }
            primaryPage(page)
        }
        .frame(maxWidth: 680, maxHeight: .infinity)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(StudyInk.paper.ignoresSafeArea())
        .foregroundStyle(.black).tint(.black).preferredColorScheme(.light)
        .navigationTitle(study.research.research.company.name)
        .inlineReadingTitle()
        .toolbar {
            ToolbarItem(placement: .navigation) {
                Button(action: onLibrary) { Label("切换公司", systemImage: "books.vertical") }
                    .accessibilityIdentifier("workspace-switch-company")
            }
            ToolbarItem(placement: .principal) {
                Text(study.research.research.company.name).font(.headline)
                    .accessibilityIdentifier("workspace-company-title")
            }
            switch page {
            case .report(let report): ReportReadingToolbar(page: report, follow: { reader.follow($0) })
            case .diagram(let diagram):
                DiagramReadingToolbar(overview: diagram.overview, follow: { reader.follow($0) },
                                      showReport: { reader.switchMode(.report) })
            case .overview:
                DiagramReadingToolbar(overview: nil, follow: { reader.follow($0) },
                                      showReport: { reader.switchMode(.report) })
            case .detail: ToolbarItem { EmptyView() }
            }
        }
        .sheet(isPresented: Binding(
            get: { !reader.presentationPath.isEmpty },
            set: { visible in
                if !visible, let token = shownPresentation?.token { reader.dismissPresentation(token) }
            }
        )) {
            if let shownPresentation {
                ReadingDetailHost(reader: $reader, token: shownPresentation.token).id(shownPresentation.token)
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
    }

    @ViewBuilder private func primaryPage(_ page: StudyReaderPage) -> some View {
        switch page {
        case .overview(let page):
            OverviewReadingPage(page: page, follow: { reader.follow($0) }, onPosition: observe)
        case .diagram(let page):
            DiagramReadingPage(page: page, navigation: reader.navigation, follow: { reader.follow($0) },
                selectFocus: { reader.selectFocus($0) }, enlarge: { reader.enlargeDiagram() },
                back: { reader.back() }, advance: { reader.advanceMainline() }, onPosition: observe)
        case .report(let page):
            ReportReadingPage(page: page, canGoBack: reader.navigation.canGoBack,
                follow: { reader.follow($0) }, back: { reader.back() }, onPosition: observe)
        case .detail: EmptyView()
        }
    }

    private func observe(_ token: ObservationToken, _ position: ReadingPosition, _ cause: PositionCause) {
        reader.reportVisiblePosition(token, position: position, cause: cause)
    }

    private func fullscreenDiagram(_ viewing: FullscreenDiagramPresentation) -> some View {
        let page = viewing.diagram
        return DiagramFullscreenView(
            raw: page.diagram.raw, periods: page.diagram.periods, selectedFocus: page.focus.id,
            renderID: AnyHashable(viewing.observation), viewport: diagramViewports[page.visitID] ?? DiagramViewport(),
            onViewportChange: { viewport, cause in
                guard reader.fullscreenDiagram?.presentationToken == viewing.presentationToken else { return }
                diagramViewports[page.visitID] = viewport
                if cause == .userInteraction {
                    reader.reportVisiblePosition(viewing.observation,
                        position: ReadingPosition(anchorID: "diagram"), cause: .userBrowsing)
                }
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


extension View {
    @ViewBuilder func inlineReadingTitle() -> some View {
        #if canImport(UIKit)
        navigationBarTitleDisplayMode(.inline)
        #else
        self
        #endif
    }
}
