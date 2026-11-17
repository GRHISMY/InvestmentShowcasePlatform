import Foundation

/// Owns the reading seam; concrete content, navigation and persistence rules stay separate inside it.
public struct StudyReader {
    public private(set) var notice: String?
    private let content: ReaderContent
    private let readerID = UUID()
    private var state: ReaderNavigationState
    private var details = ReadingDetails()
    private var pdfRules = PDFReadingRules()
    private var diagramViewing: DiagramViewing?
    private var records: ReaderRecords

    public init(study: ReadableStudy, bookmark: Data? = nil, restoreCandidates: RestoreCandidates? = nil,
                clock: @escaping () -> Date = Date.init) {
        content = ReaderContent(study: study)
        records = ReaderRecords(identity: study.identity, clock: clock)
        (state, notice) = ReaderBookmark.restore(bookmark, content: content)
        let memory = ReaderBookmark.memory(bookmark, content: content)
        details.remembered = Dictionary(memory.details.map { ($0.address, $0.position) }, uniquingKeysWith: { _, latest in latest })
        pdfRules.resumePages = memory.pdf
        let validLegacy = bookmark != nil && notice == nil
        switch ReaderRecords.restoreMain(restoreCandidates, content: content, state: &state) {
        case .restored?: notice = nil
        case .restoredAlternative?:
            notice = "优先阅读位置已失效，已恢复本版本的其他可用位置，可返回书库重新选择。"
        case .unavailable?:
            notice = validLegacy ? "现有阅读记录暂不适用，已保留本机有效位置。" : "现有阅读位置已失效，已回到这份研究起点。"
        case nil: break
        }
        ReaderRecords.restoreOtherSlots(restoreCandidates, content: content, state: &state, details: &details, pdf: &pdfRules)
        if study.reading == nil, state.current.location.address != .report {
            state.activate(ReaderLocation(.report), cause: .programmatic)
        }
    }
    public var checkpoint: ReadingCheckpoint? { records.checkpoint }

    public var presentationPath: [ReadingDetailPresentation] {
        details.visits.map { ReadingDetailPresentation(token: $0.token,
            page: content.detail($0, readerID: readerID, pdfResumes: pdfRules.resumePages)) }
    }
    public var localBookmark: Data? {
        ReaderBookmark.encode(state, identity: content.study.identity,
            detailPositions: details.savedPositions, pdfResumePages: pdfRules.resumePages)
    }
    /// Cheap navigation chrome projection; does not build report/detail content.
    public var currentMode: ReadingMode { state.current.location.address.mode }
    public var blocksMainNavigation: Bool { !mainReadingIsAvailable }
    public var availableModes: [ReadingMode] { content.study.reading == nil ? [.report] : [.diagram, .report] }
    public var fullscreenDiagram: FullscreenDiagramPresentation? {
        diagramViewing?.projection(content: content, state: state, readerID: readerID)
    }
    public mutating func enlargeDiagram() {
        guard diagramViewing == nil, details.current == nil, content.scene(state.current.location) != nil else { return }
        diagramViewing = DiagramViewing(readerID: readerID)
    }
    public mutating func reportFullscreenDiagramDisplayed(_ token: ObservationToken) {
        let ownerID = readerID
        if diagramViewing?.confirmDisplayed(token, readerID: ownerID) == true { records.main(state) }
    }
    public mutating func switchMode(_ mode: ReadingMode) {
        guard mainReadingIsAvailable, availableModes.contains(mode), state.current.location.address.mode != mode else { return }
        let location = state.modeLocations[mode] ?? ReaderLocation(mode == .report ? .report : .overview)
        state.follow(location)
    }
    public var primaryPage: StudyReaderPage { content.primary(state, access: access) }
    public var page: StudyReaderPage {
        if let current = details.current {
            return .detail(content.detail(current, readerID: readerID, pdfResumes: pdfRules.resumePages))
        }
        return primaryPage
    }
    public var navigation: ReadingNavigation {
        let scene = content.scene(state.current.location)
        let canReturnToOverview = content.scene(state.current.location) != nil
        return ReadingNavigation(canGoBack: diagramViewing != nil || details.current != nil || !state.history.isEmpty || canReturnToOverview ||
            (state.isOverview && state.overviewOrigin != nil),
            canAdvanceMainline: mainReadingIsAvailable && scene?.nextSceneId != nil,
            isMainlineEnd: scene != nil && scene?.nextSceneId == nil)
    }
    private var access: ReaderAccess { ReaderAccess(readerID: readerID, visit: state.current) }
    private var mainReadingIsAvailable: Bool { details.current == nil && diagramViewing == nil }

    public mutating func openCitation(_ target: CitationTarget) {
        let currentAccess = details.current?.access(readerID: readerID) ?? access
        guard diagramViewing == nil, currentAccess.accepts(target),
              let document = content.document(target.sourceID, access: currentAccess),
              (1...document.pageCount).contains(target.physicalPage) else { return }
        if let current = details.current, case .pdf(let sourceID) = current.address,
           sourceID == target.sourceID, var pdf = current.pdf {
            pdfRules.locate(PDFCitation(target), state: &pdf)
            details.placePDF(pdf)
            return
        }
        details.openPDF(sourceID: target.sourceID,
            state: PDFVisitState(citation: PDFCitation(target), targetPhysicalPage: target.physicalPage,
                placementFocusText: target.focusText), readerID: readerID)
    }
    public mutating func reportPDFLoad(_ attempt: PDFLoadAttempt, result: Result<Int, PDFReadingFailure>) {
        guard let current = details.current, case .pdf(let sourceID) = current.address, var pdf = current.pdf,
              let document = content.document(sourceID, access: current.access(readerID: readerID)) else { return }
        let clock = records.clock
        let accepted = pdfRules.loaded(attempt, result: result, state: &pdf, sourceID: sourceID,
            pageCount: document.pageCount, clock: clock)
        details.updatePDF(pdf)
        if let accepted { records.pdf(sourceID, reading: accepted) }
    }
    public mutating func continuePDF(_ choice: PDFDocumentChoice) {
        let currentAccess = details.current?.access(readerID: readerID) ?? access
        guard diagramViewing == nil, currentAccess.accepts(choice),
              content.document(choice.sourceID, access: currentAccess) != nil else { return }
        if let current = details.current, case .pdf(let sourceID) = current.address,
           sourceID == choice.sourceID, var pdf = current.pdf {
            pdfRules.continueReading(sourceID: sourceID, state: &pdf)
            details.placePDF(pdf)
        } else {
            details.openPDF(sourceID: choice.sourceID,
                state: PDFVisitState(targetPhysicalPage: pdfRules.resumePages[choice.sourceID] ?? 1), readerID: readerID)
        }
    }
    public mutating func reportPDFPage(_ token: PDFObservationToken, physicalPage: Int, cause: PositionCause) {
        guard let current = details.current, case .pdf(let sourceID) = current.address, var pdf = current.pdf,
              let document = content.document(sourceID, access: current.access(readerID: readerID)) else { return }
        let clock = records.clock
        let accepted = pdfRules.page(token, physicalPage: physicalPage, cause: cause, state: &pdf,
            sourceID: sourceID, pageCount: document.pageCount, clock: clock)
        details.updatePDF(pdf)
        if let accepted { records.pdf(sourceID, reading: accepted) }
    }
    public mutating func retryPDF() {
        guard var pdf = details.current?.pdf, pdfRules.retry(state: &pdf) else { return }
        details.placePDF(pdf)
    }

    public mutating func follow(_ link: ReadingLink) {
        let actionAccess = details.current?.access(readerID: readerID) ?? access
        guard diagramViewing == nil, actionAccess.accepts(link) else { return }
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
        case .explanation(let context): details.open(.explanation(context), readerID: readerID)
        case .calculations(let context): details.open(.calculations(context), readerID: readerID)
        case .evidence(let context): details.open(.evidence(context, selected: nil), readerID: readerID)
        case .evidenceSelection(let context, let ids): details.open(.evidence(context, selected: ids), readerID: readerID)
        }
    }

    public mutating func advanceMainline() {
        guard mainReadingIsAvailable, let next = content.scene(state.current.location)?.nextSceneId else { return }
        state.enterScene(next)
    }

    public mutating func selectFocus(_ choice: FocusChoice) {
        let selectionAccess = diagramViewing?.access(readerID: readerID) ?? access
        guard details.current == nil, selectionAccess.accepts(choice),
              let scene = content.scene(state.current.location), choice.sceneID == scene.id,
              content.study.reading?.validFocus(choice.id, in: scene.id) != nil,
              choice.id != content.focus(state.current.location)?.id else { return }
        state.selectFocus(choice.id)
        diagramViewing?.focusChanged()
    }

    public mutating func reportVisiblePosition(_ token: ObservationToken, position: ReadingPosition,
                                               cause: PositionCause) {
        guard cause == .userNavigation || cause == .userBrowsing,
              position.localOffset.map({ $0.isFinite && $0 >= 0 }) ?? true else { return }
        if let viewing = diagramViewing {
            guard cause == .userBrowsing, viewing.isDisplayed,
                  token == viewing.access(readerID: readerID).observation else { return }
            records.main(state)
            return
        }
        if let current = details.current {
            guard current.access(readerID: readerID).observation == token,
                  content.detailAnchors(current, readerID: readerID).contains(where: { $0.id == position.anchorID }) else { return }
            details.remember(position)
            records.detail(current.address, position: position)
        } else {
            guard token == access.observation,
                  content.anchors(state.current.location.address).contains(where: { $0.id == position.anchorID }) else { return }
            state.remember(position)
            records.main(state)
        }
    }

    public mutating func back() {
        if diagramViewing != nil {
            closeDiagramViewing()
        } else if details.current != nil {
            details.back()
            if details.current == nil { state.activate(state.current.location) }
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
        guard details.dismiss(token) else { return }
        if details.current == nil { state.activate(state.current.location) }
    }

    private mutating func closeDiagramViewing() {
        let cause = diagramViewing?.mainArrivalCause ?? .restoration
        diagramViewing = nil
        state.activate(state.current.location, cause: cause)
    }

}
