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
public enum ReadingMode: String, Hashable, Codable { case diagram, report }

public struct SourceVisitID: Hashable, Codable {
    let rawValue: UUID
    init() { rawValue = UUID() }
}

public struct ObservationToken: Hashable {
    let reader, activation, scope: UUID
}

public struct PresentationToken: Hashable {
    let reader, presentation: UUID
}

public struct ReadingLink: Hashable {
    let reader, activation, scope: UUID
    let target: LinkTarget
}

public struct FocusChoice: Hashable {
    public let id: String
    let reader, activation: UUID
    let sceneID: String
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
    public let visitID: SourceVisitID
    public let title, summary: String
    public let company: ResearchCompany
    public let coverage: ResearchCoverage
    public let researchAsOf, coverageMode: String
    public let entries: [OverviewEntry]
    public let beginOrResume, restart: ReadingLink
    public let observation: ObservationToken
    public let anchors: [ReadingAnchor]
    public let restorePosition: ReadingPosition?
    public let arrivalCause: PositionCause
}

public struct ReaderDiagram {
    public let raw: ReadingView
    public let periods: [ResearchPeriod]
    let choices: [String: FocusChoice]
    public func choice(for focusID: String) -> FocusChoice? { choices[focusID] }
}

public struct FocusContent {
    public let id, title, body, caveat: String
    public let gaps: [ReadingGap]
    public let hasCounterEvidence: Bool
    public let explanation: ReadingLink
    public let calculations, evidence: ReadingLink?
}

public struct DiagramPage {
    public let visitID: SourceVisitID
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
    public let relatedReports: [ReportClaimLink]
}

/// Temporary adapter payload while report and shared details migrate to the same reader.
public struct LegacyReadingPresentation {
    public enum Kind { case explanation, calculations, evidence }
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
    case report(ReportPage)
    case legacyPresentation(LegacyReadingPresentation)
}

public enum ReportClaimPart: String, CaseIterable, Hashable {
    case heading, known, meaning, gaps, alternatives, reasoning, limitations, changeConditions, facts
}
public struct ReportClaimLink: Identifiable {
    public let id, title, summary: String
    public let link: ReadingLink
}
public struct RelatedDiagramLink: Identifiable {
    public let id, sceneID, sceneTitle, section, question, focusID, focusTitle: String
    public let link: ReadingLink
}
public struct ReportFactContent {
    public let fact: ResearchFact
    public let entityName, periodLabel: String
}
public struct ReportClaimContent {
    public let claim: ResearchClaim
    public let scope: String
    public let facts: [ReportFactContent]
    public let calculations, evidence: ReadingLink?
    public let relatedDiagrams: [RelatedDiagramLink]
    let partAnchors: [ReportClaimPart: ReadingAnchor]
    public func anchor(for part: ReportClaimPart) -> ReadingAnchor? { partAnchors[part] }
}
public struct ReportSectionContent: Identifiable {
    public let id, title: String
    public let anchor: ReadingAnchor
    public let claims: [ReportClaimContent]
}
public struct ReportDimensionContent: Identifiable {
    public let id, title, summary: String
    public let anchor: ReadingAnchor
    public let claims: [ReportClaimLink]
}
public struct ReportMonitoringContent: Identifiable {
    public let id, description, status: String
    public let anchor: ReadingAnchor
    public let claims: [ReportClaimLink]
}
public struct ReportPage {
    public let visitID: SourceVisitID
    public let title: String
    public let company: ResearchCompany
    public let coverage: ResearchCoverage
    public let researchAsOf: String
    public let revision: Int
    public let summary: String
    public let limitations: [String]
    public let headlineClaims: [ReportClaimLink]
    public let contents: [ReportClaimLink]
    public let sections: [ReportSectionContent]
    public let dimensions: [ReportDimensionContent]
    public let monitoring: [ReportMonitoringContent]
    public let summaryAnchor: ReadingAnchor
    public let limitationsAnchor: ReadingAnchor?
    public let observation: ObservationToken
    public let anchors: [ReadingAnchor]
    public let restorePosition: ReadingPosition?
    public let arrivalCause: PositionCause
}

