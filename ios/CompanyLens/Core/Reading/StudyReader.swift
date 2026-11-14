import Foundation

public struct ReadingAnchor: Hashable, Codable, Identifiable {
    public let id, label: String
}

public struct ReadingPosition: Equatable, Codable {
    public let anchorID: String
    public let localOffset: Double?
    public init(anchorID: String, localOffset: Double? = nil) {
        self.anchorID = anchorID
        self.localOffset = localOffset
    }
}

public enum PositionCause { case userNavigation, userBrowsing, programmatic, restoration }

public struct ObservationToken: Hashable {
    fileprivate let reader, visit, scope: UUID
}

public struct PresentationToken: Hashable {
    fileprivate let reader, presentation: UUID
}

public struct ReadingLink: Hashable {
    fileprivate let reader, visit, scope: UUID
    fileprivate let target: LinkTarget
}

public struct FocusChoice: Hashable {
    public let id: String
    fileprivate let reader, visit: UUID
    fileprivate let sceneID: String
}

public struct ReadingNavigation {
    public let canGoBack, canAdvanceMainline, isMainlineEnd: Bool
}

public struct OverviewEntry: Identifiable {
    public let sceneID, label, caption, icon: String
    public let link: ReadingLink
    public var id: String { sceneID }
}

public struct OverviewPage {
    public let title, summary: String
    public let company: ResearchCompany
    public let coverage: ResearchCoverage
    public let researchAsOf, coverageMode: String
    public let entries: [OverviewEntry]
    public let beginOrResume, restart, report: ReadingLink
    public let observation: ObservationToken
    public let anchors: [ReadingAnchor]
    public let restorePosition: ReadingPosition?
    public let arrivalCause: PositionCause
}

public struct ReaderDiagram {
    public let raw: ReadingView
    public let periods: [ResearchPeriod]
    fileprivate let choices: [String: FocusChoice]
    public func choice(for focusID: String) -> FocusChoice? { choices[focusID] }
}

public struct FocusContent {
    public let id, title, body, caveat: String
    public let gaps: [ReadingGap]
    public let hasCounterEvidence: Bool
    public let explanation: ReadingLink
    public let calculations, evidence: ReadingLink?
    public let report: ReadingLink
}

public struct DiagramPage {
    public let sceneID, section, title, question: String
    public let ordinal, sceneCount: Int
    public let diagram: ReaderDiagram
    public let focus: FocusContent
    public let essentialNotes: [String]
    public let overview: ReadingLink
    public let nextLabel: String
    public let isMainlineEnd: Bool
    public let observation: ObservationToken
    public let anchors: [ReadingAnchor]
    public let restorePosition: ReadingPosition?
    public let arrivalCause: PositionCause
}

/// Temporary adapter payload while report and shared details migrate to the same reader.
public struct LegacyReadingPresentation {
    public enum Kind { case report, explanation, calculations, evidence }
    public let kind: Kind
    public let study: ReadableStudy
    public let title, text, caveat: String
    public let calculations: [ResearchCalculation]
    public let evidence: [ResearchEvidence]
    public let counterEvidenceIDs: [String]
    public let claims: [ResearchClaim]
    public let presentationToken: PresentationToken
    public let observation: ObservationToken
    public let anchors: [ReadingAnchor]
    public let restorePosition: ReadingPosition?
}

public enum StudyReaderPage {
    case overview(OverviewPage)
    case diagram(DiagramPage)
    case legacyPresentation(LegacyReadingPresentation)
}

fileprivate enum LinkTarget: Hashable {
    case scene(String), overview, restart, report
    case explanation(String), calculations(String), evidence(String)
}

/// One immutable publication and one owner for its reading decisions. No file I/O occurs here.
public struct StudyReader {
    public private(set) var notice: String?
    private let study: ReadableStudy
    private let readerID = UUID()
    private var visitID = UUID()
    private var scopeID = UUID()
    private var isOverview = true
    private var sceneID: String
    private var focusID: String?
    private var arrivalCause: PositionCause = .programmatic
    private var history: [SceneVisit] = []
    private var overviewOrigin: SceneVisit?
    private var position: ReadingPosition?
    private var overviewPosition: ReadingPosition?
    private var presentation: LegacyVisit?

    private struct LegacyVisit {
        let kind: LegacyReadingPresentation.Kind
        let focusID: String?
        let token: PresentationToken
        let observation: ObservationToken
        var position: ReadingPosition?
    }

    private struct SceneVisit: Codable, Equatable {
        let sceneID: String
        let focusID: String?
        let position: ReadingPosition?
    }

    public init(study: ReadableStudy, bookmark: Data? = nil) {
        self.study = study
        sceneID = study.reading?.document.entrySceneId ?? ""
        if let bookmark, let saved = try? JSONDecoder().decode(Bookmark.self, from: bookmark),
           saved.schemaVersion == 2, saved.identity == study.identity,
           let current = sanitized(saved.current) {
            sceneID = current.sceneID
            focusID = current.focusID
            position = current.position
            isOverview = saved.isOverview
            history = saved.history.compactMap { sanitized($0) }
            overviewOrigin = saved.overviewOrigin.flatMap { sanitized($0) }
            overviewPosition = validPosition(saved.overviewPosition, anchors: ["overview"])
            if current != saved.current || history != saved.history || overviewOrigin != saved.overviewOrigin ||
                overviewPosition != saved.overviewPosition {
                notice = "上次位置有一部分已失效，已恢复可用内容。"
            }
            arrivalCause = .restoration
        } else if let bookmark, let reading = study.reading,
                  let old = try? JSONDecoder().decode(LegacyBookmark.self, from: bookmark),
                  old.schemaVersion == 1, old.momentIDs == reading.document.sceneOrder,
                  reading.scene(old.currentID) != nil {
            sceneID = old.currentID
            focusID = reading.validFocus(old.focus, in: old.currentID)
            isOverview = old.isOverview
            history = old.history.compactMap { visit in
                guard reading.scene(visit.id) != nil else { return nil }
                return SceneVisit(sceneID: visit.id, focusID: reading.validFocus(visit.focus, in: visit.id), position: nil)
            }
            if isOverview { overviewOrigin = currentSceneVisit }
            arrivalCause = .restoration
        } else if bookmark != nil {
            notice = "上次位置已无法使用，已回到这份研究全貌。"
        }
        if study.reading == nil { present(.report, focusID: nil) }
    }

    public var localBookmark: Data? {
        let saved = Bookmark(schemaVersion: 2, identity: study.identity, isOverview: isOverview,
            current: currentSceneVisit, history: history, overviewOrigin: overviewOrigin,
            overviewPosition: overviewPosition)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return try? encoder.encode(saved)
    }

    private struct Bookmark: Codable {
        let schemaVersion: Int
        let identity: StudyIdentity
        let isOverview: Bool
        let current: SceneVisit
        let history: [SceneVisit]
        let overviewOrigin: SceneVisit?
        let overviewPosition: ReadingPosition?
    }

    /// Read-only migration of the former visual reader's per-publication bookmark.
    private struct LegacyBookmark: Decodable {
        struct Visit: Decodable { let id: String; let focus: String? }
        let schemaVersion: Int
        let momentIDs: [String]
        let currentID: String
        let focus: String?
        let history: [Visit]
        let isOverview: Bool
    }

    private func sanitized(_ visit: SceneVisit) -> SceneVisit? {
        guard let reading = study.reading, reading.scene(visit.sceneID) != nil else { return nil }
        let focus = reading.validFocus(visit.focusID, in: visit.sceneID)
        var position = validPosition(visit.position, anchors: diagramAnchors.map(\.id))
        if visit.focusID != nil && focus == nil, let anchor = position?.anchorID,
           ["explanation", "limits"].contains(anchor) {
            position = ReadingPosition(anchorID: anchor)
        }
        return SceneVisit(sceneID: visit.sceneID, focusID: focus, position: position)
    }

    private func validPosition(_ position: ReadingPosition?, anchors: [String]) -> ReadingPosition? {
        guard let position, anchors.contains(position.anchorID) else { return nil }
        let offset = position.localOffset.flatMap { $0.isFinite && $0 >= 0 ? $0 : nil }
        return ReadingPosition(anchorID: position.anchorID, localOffset: offset)
    }

    public var page: StudyReaderPage {
        if let presentation { return .legacyPresentation(legacyPage(presentation)) }
        return primaryPage
    }

    public var navigation: ReadingNavigation {
        let scene = isOverview ? nil : study.reading?.scene(sceneID)
        return ReadingNavigation(canGoBack: study.reading != nil && (presentation != nil || !isOverview || overviewOrigin != nil),
            canAdvanceMainline: presentation == nil && scene?.nextSceneId != nil,
            isMainlineEnd: scene != nil && scene?.nextSceneId == nil)
    }

    public var primaryPage: StudyReaderPage {
        guard !isOverview, let reading = study.reading, let scene = reading.scene(sceneID),
              let raw = reading.view(scene.viewId),
              let focus = reading.focus(reading.validFocus(focusID, in: sceneID) ?? scene.defaultFocusId) else {
            return .overview(overviewPage)
        }
        let choices = Dictionary(uniqueKeysWithValues: scene.focusIds.map { id in
            (id, FocusChoice(id: id, reader: readerID, visit: visitID, sceneID: scene.id))
        })
        return .diagram(DiagramPage(sceneID: scene.id, section: scene.section, title: scene.title,
            question: scene.question, ordinal: (reading.document.sceneOrder.firstIndex(of: scene.id) ?? 0) + 1,
            sceneCount: reading.orderedScenes.count,
            diagram: ReaderDiagram(raw: raw, periods: study.research.research.periods, choices: choices),
            focus: FocusContent(id: focus.id, title: focus.title, body: focus.body, caveat: focus.caveat,
                gaps: focus.gaps, hasCounterEvidence: !focus.counterEvidenceIds.isEmpty,
                explanation: link(.explanation(focus.id)),
                calculations: focus.calculationIds.isEmpty ? nil : link(.calculations(focus.id)),
                evidence: focus.evidenceIds.isEmpty ? nil : link(.evidence(focus.id)), report: link(.report)),
            essentialNotes: scene.essentialNotes, overview: link(.overview), nextLabel: scene.nextLabel,
            isMainlineEnd: scene.nextSceneId == nil, observation: observation, anchors: diagramAnchors,
            restorePosition: position ?? ReadingPosition(anchorID: "heading"), arrivalCause: arrivalCause))
    }

    public mutating func follow(_ link: ReadingLink) {
        guard presentation == nil, link.reader == readerID, link.visit == visitID, link.scope == scopeID else { return }
        switch link.target {
        case .scene(let id): enterScene(id)
        case .overview:
            guard !isOverview else { return }
            overviewOrigin = currentSceneVisit
            isOverview = true
            activate()
        case .restart:
            guard let id = study.reading?.document.entrySceneId else { return }
            history = []
            overviewOrigin = nil
            sceneID = id
            focusID = nil
            position = nil
            isOverview = false
            activate()
        case .report: present(.report, focusID: activeFocus?.id)
        case .explanation(let id): present(.explanation, focusID: id)
        case .calculations(let id): present(.calculations, focusID: id)
        case .evidence(let id): present(.evidence, focusID: id)
        }
    }

    public mutating func advanceMainline() {
        guard presentation == nil, !isOverview, let next = study.reading?.scene(sceneID)?.nextSceneId else { return }
        enterScene(next)
    }

    public mutating func selectFocus(_ choice: FocusChoice) {
        guard presentation == nil, !isOverview, choice.reader == readerID, choice.visit == visitID,
              choice.sceneID == sceneID, study.reading?.validFocus(choice.id, in: sceneID) != nil else { return }
        guard choice.id != (focusID ?? study.reading?.scene(sceneID)?.defaultFocusId) else { return }
        focusID = choice.id
        if let position, ["explanation", "limits"].contains(position.anchorID) {
            self.position = ReadingPosition(anchorID: position.anchorID)
        }
        scopeID = UUID()
        arrivalCause = .userNavigation
    }

    public mutating func reportVisiblePosition(_ token: ObservationToken, position: ReadingPosition,
                                               cause: PositionCause) {
        guard (presentation.map { $0.observation == token } ?? (token == observation)),
              cause == .userNavigation || cause == .userBrowsing,
              (position.localOffset.map { $0.isFinite && $0 >= 0 } ?? true) else { return }
        let anchors = presentation == nil ? (isOverview ? ["overview"] : diagramAnchors.map(\.id)) : ["detail"]
        guard anchors.contains(position.anchorID) else { return }
        if presentation != nil { presentation?.position = position }
        else if isOverview { overviewPosition = position }
        else { self.position = position }
    }

    public mutating func back() {
        guard study.reading != nil else { return }
        if presentation != nil {
            presentation = nil
            activate()
        } else if isOverview {
            guard let origin = overviewOrigin else { return }
            restore(origin)
            overviewOrigin = nil
        } else if let origin = history.popLast() {
            restore(origin)
        } else {
            overviewOrigin = currentSceneVisit
            isOverview = true
            activate()
        }
    }

    public mutating func dismissPresentation(_ token: PresentationToken) {
        guard presentation?.token == token else { return }
        back()
    }

    private var activeFocus: ReadingFocus? {
        guard !isOverview, let scene = study.reading?.scene(sceneID) else { return nil }
        return study.reading?.focus(focusID ?? scene.defaultFocusId)
    }

    private mutating func present(_ kind: LegacyReadingPresentation.Kind, focusID: String?) {
        let id = UUID()
        presentation = LegacyVisit(kind: kind, focusID: focusID,
            token: PresentationToken(reader: readerID, presentation: id),
            observation: ObservationToken(reader: readerID, visit: id, scope: UUID()))
    }

    private func legacyPage(_ visit: LegacyVisit) -> LegacyReadingPresentation {
        let focus = visit.focusID.flatMap { study.reading?.focus($0) }
        let notes = [focus?.caveat ?? ""] + (study.reading?.scene(sceneID)?.essentialNotes ?? [])
        var seen = Set<String>()
        let caveat = notes.filter { !$0.isEmpty && seen.insert($0).inserted }.joined(separator: "\n")
        return LegacyReadingPresentation(kind: visit.kind, study: study,
            title: focus?.title ?? "完整报告", text: focus?.body ?? study.research.research.report.summary,
            caveat: caveat,
            calculations: focus?.calculationIds.compactMap(study.research.calculation) ?? [],
            evidence: focus?.evidenceIds.compactMap(study.research.evidence) ?? [],
            counterEvidenceIDs: focus?.counterEvidenceIds ?? [],
            claims: focus?.conclusionIds.compactMap(study.research.claim) ?? study.research.orderedClaims,
            presentationToken: visit.token, observation: visit.observation,
            anchors: [ReadingAnchor(id: "detail", label: "核对内容")],
            restorePosition: visit.position ?? ReadingPosition(anchorID: "detail"))
    }

    private var currentSceneVisit: SceneVisit { SceneVisit(sceneID: sceneID, focusID: focusID, position: position) }

    private mutating func enterScene(_ id: String) {
        guard study.reading?.scene(id) != nil else { return }
        if isOverview, let origin = overviewOrigin {
            if origin.sceneID == id {
                restore(origin)
                overviewOrigin = nil
                return
            }
            history.append(origin)
        } else if !isOverview {
            guard id != sceneID else { return }
            history.append(currentSceneVisit)
        }
        sceneID = id
        focusID = nil
        position = nil
        isOverview = false
        overviewOrigin = nil
        activate()
    }

    private mutating func restore(_ origin: SceneVisit) {
        sceneID = origin.sceneID
        focusID = origin.focusID
        position = origin.position
        isOverview = false
        activate()
    }

    private mutating func activate() {
        visitID = UUID()
        scopeID = UUID()
        arrivalCause = .userNavigation
    }

    private var observation: ObservationToken {
        ObservationToken(reader: readerID, visit: visitID, scope: scopeID)
    }

    private func link(_ target: LinkTarget) -> ReadingLink {
        ReadingLink(reader: readerID, visit: visitID, scope: scopeID, target: target)
    }

    private var diagramAnchors: [ReadingAnchor] {
        [ReadingAnchor(id: "heading", label: "当前问题"), ReadingAnchor(id: "diagram", label: "图解"),
         ReadingAnchor(id: "explanation", label: "焦点解释"), ReadingAnchor(id: "limits", label: "适用边界")]
    }

    private var overviewPage: OverviewPage {
        let reading = study.reading
        let research = study.research.research
        return OverviewPage(title: reading?.document.overview.title ?? research.company.name,
            summary: reading?.document.overview.summary ?? research.report.summary,
            company: research.company, coverage: research.report.coverage,
            researchAsOf: research.report.researchAsOf, coverageMode: reading?.document.coverage.mode ?? "complete",
            entries: reading?.document.overview.entries.map {
                OverviewEntry(sceneID: $0.sceneId, label: $0.label, caption: $0.caption, icon: $0.icon,
                              link: link(.scene($0.sceneId)))
            } ?? [], beginOrResume: link(.scene(sceneID)), restart: link(.restart), report: link(.report),
            observation: observation, anchors: [ReadingAnchor(id: "overview", label: "研究全貌")],
            restorePosition: overviewPosition ?? ReadingPosition(anchorID: "overview"), arrivalCause: arrivalCause)
    }
}
