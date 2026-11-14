import Foundation

/// Owns the reading seam; concrete content, navigation and persistence rules stay separate inside it.
public struct StudyReader {
    public private(set) var notice: String?
    private let content: ReaderContent
    private let readerID = UUID()
    private var state: ReaderNavigationState
    private var presentation: LegacyVisit?
    private var diagramViewing: DiagramViewing?

    public init(study: ReadableStudy, bookmark: Data? = nil) {
        content = ReaderContent(study: study)
        (state, notice) = ReaderBookmark.restore(bookmark, content: content)
        if study.reading == nil, state.current.location.address != .report {
            state.activate(ReaderLocation(.report), cause: .programmatic)
        }
    }

    public var localBookmark: Data? { ReaderBookmark.encode(state, identity: content.study.identity) }
    public var availableModes: [ReadingMode] { content.study.reading == nil ? [.report] : [.diagram, .report] }
    public var fullscreenDiagram: FullscreenDiagramPresentation? {
        diagramViewing?.projection(content: content, state: state, readerID: readerID)
    }
    public mutating func enlargeDiagram() {
        guard diagramViewing == nil, presentation == nil, content.scene(state.current.location) != nil else { return }
        diagramViewing = DiagramViewing(readerID: readerID)
    }
    public mutating func reportFullscreenDiagramDisplayed(_ token: ObservationToken) {
        let ownerID = readerID
        diagramViewing?.confirmDisplayed(token, readerID: ownerID)
    }
    public mutating func switchMode(_ mode: ReadingMode) {
        guard mainReadingIsAvailable, availableModes.contains(mode), state.current.location.address.mode != mode else { return }
        let location = state.modeLocations[mode] ?? ReaderLocation(mode == .report ? .report : .overview)
        state.follow(location)
    }
    public var primaryPage: StudyReaderPage { content.primary(state, access: access) }
    public var page: StudyReaderPage {
        if let presentation { return .legacyPresentation(content.legacy(presentation)) }
        return primaryPage
    }
    public var navigation: ReadingNavigation {
        let scene = content.scene(state.current.location)
        let canReturnToOverview = content.scene(state.current.location) != nil
        return ReadingNavigation(canGoBack: diagramViewing != nil || presentation != nil || !state.history.isEmpty || canReturnToOverview ||
            (state.isOverview && state.overviewOrigin != nil),
            canAdvanceMainline: mainReadingIsAvailable && scene?.nextSceneId != nil,
            isMainlineEnd: scene != nil && scene?.nextSceneId == nil)
    }
    private var access: ReaderAccess { ReaderAccess(readerID: readerID, visit: state.current) }
    private var mainReadingIsAvailable: Bool { presentation == nil && diagramViewing == nil }

    public mutating func follow(_ link: ReadingLink) {
        guard mainReadingIsAvailable, access.accepts(link) else { return }
        switch link.target {
        case .scene(let id):
            guard content.study.reading?.scene(id) != nil else { return }
            state.enterScene(id)
        case .overview: state.showOverview()
        case .restart:
            guard let id = content.entrySceneID else { return }
            state.history = []
            state.overviewOrigins = [:]
            state.activate(ReaderLocation(.diagram(sceneID: id, focusID: nil)))
        case .reportClaim(let id):
            guard let claim = content.study.research.claim(id), let anchor = content.claimAnchors(claim)[.heading] else { return }
            state.follow(ReaderLocation(.report, position: ReadingPosition(anchorID: anchor.id)))
        case .diagram(let sceneID, let focusID):
            guard content.study.reading?.validFocus(focusID, in: sceneID) != nil else { return }
            state.follow(ReaderLocation(.diagram(sceneID: sceneID, focusID: focusID)))
        case .explanation(let context): present(.explanation, context: context)
        case .calculations(let context): present(.calculations, context: context)
        case .evidence(let context): present(.evidence, context: context)
        }
    }

    public mutating func advanceMainline() {
        guard mainReadingIsAvailable, let next = content.scene(state.current.location)?.nextSceneId else { return }
        state.enterScene(next)
    }

    public mutating func selectFocus(_ choice: FocusChoice) {
        let selectionAccess = diagramViewing?.access(readerID: readerID) ?? access
        guard presentation == nil, selectionAccess.accepts(choice),
              let scene = content.scene(state.current.location), choice.sceneID == scene.id,
              content.study.reading?.validFocus(choice.id, in: scene.id) != nil,
              choice.id != content.focus(state.current.location)?.id else { return }
        state.selectFocus(choice.id)
        diagramViewing?.focusChanged()
    }

    public mutating func reportVisiblePosition(_ token: ObservationToken, position: ReadingPosition,
                                               cause: PositionCause) {
        guard diagramViewing == nil, cause == .userNavigation || cause == .userBrowsing,
              position.localOffset.map({ $0.isFinite && $0 >= 0 }) ?? true else { return }
        if let current = presentation {
            guard current.observation == token, position.anchorID == "detail" else { return }
            presentation?.position = position
        } else {
            guard token == access.observation,
                  content.anchors(state.current.location.address).contains(where: { $0.id == position.anchorID }) else { return }
            state.remember(position)
        }
    }

    public mutating func back() {
        if diagramViewing != nil {
            closeDiagramViewing()
        } else if presentation != nil {
            presentation = nil
            state.activate(state.current.location)
        } else {
            guard state.current.location.address != .report || !state.history.isEmpty else { return }
            state.back()
        }
    }

    public mutating func dismissPresentation(_ token: PresentationToken) {
        if diagramViewing?.presentationToken == token {
            closeDiagramViewing()
            return
        }
        guard presentation?.token == token else { return }
        back()
    }

    private mutating func closeDiagramViewing() {
        diagramViewing = nil
        state.activate(state.current.location, cause: .restoration)
    }

    private mutating func present(_ kind: LegacyReadingPresentation.Kind, context: DetailContext) {
        let id = UUID()
        presentation = LegacyVisit(kind: kind, context: context,
            token: PresentationToken(reader: readerID, presentation: id),
            observation: ObservationToken(reader: readerID, activation: id, scope: UUID()))
    }
}
