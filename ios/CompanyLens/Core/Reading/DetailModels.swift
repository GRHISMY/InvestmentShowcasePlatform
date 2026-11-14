import Foundation

public struct ReadingDetailPresentation: Identifiable {
    public let token: PresentationToken
    public let page: ReadingDetailPage
    public var id: PresentationToken { token }
}
public enum ReadingDetailPage {
    case explanation(ExplanationReadingPage)
    case calculations(CalculationReadingPage)
    case evidence(EvidenceReadingPage)
    case pdf(PDFReadingPage)
}
public struct ExplanationReadingPage {
    public let visitID: SourceVisitID
    public let title, text, caveat: String
    public let observation: ObservationToken
    public let anchors: [ReadingAnchor]
    public let restorePosition: ReadingPosition?
    public let arrivalCause: PositionCause
}
public struct CalculationReadingPage {
    public let visitID: SourceVisitID
    public let title: String
    public let items: [CalculationContent]
    public let observation: ObservationToken
    public let anchors: [ReadingAnchor]
    public let restorePosition: ReadingPosition?
    public let arrivalCause: PositionCause
}
public struct CalculationContent: Identifiable {
    public var id: String { calculation.id }
    public let calculation: ResearchCalculation
    public let inputs: [CalculationInputContent]
    public let anchor: ReadingAnchor
}
public struct CalculationInputContent: Identifiable {
    public let id: String
    public let ordinal: Int
    public let coefficient, operationLabel: String
    public let fact: ReportFactContent
    public let evidence: [EvidenceReference]
    public let citations: [CitationContent]
    public let anchor: ReadingAnchor
}
public struct EvidenceReference: Identifiable {
    public let id, title: String
    public let link: ReadingLink
}
public struct EvidenceReadingPage {
    public let visitID: SourceVisitID
    public let title: String
    public let items: [EvidenceContent]
    public let observation: ObservationToken
    public let anchors: [ReadingAnchor]
    public let restorePosition: ReadingPosition?
    public let arrivalCause: PositionCause
}
public struct EvidenceContent: Identifiable {
    public var id: String { evidence.id }
    public let evidence: ResearchEvidence
    public let source: PDFDocumentContent
    public let uses: [EvidenceUse]
    public let isCounterEvidence: Bool
    public let citations: [CitationContent]
    public let anchor: ReadingAnchor
}
public struct EvidenceUse {
    public let claimTitle, relation, explanation: String
}
public struct CitationTarget: Hashable {
    let reader, activation, scope: UUID
    let citationID, sourceID: String
    let physicalPage: Int
    let focusText: String?
}
public struct PDFDocumentChoice: Hashable {
    let reader, activation, scope: UUID
    let sourceID: String
}
public struct CitationContent: Identifiable {
    public let id, title, period: String
    public let physicalPage: Int
    public let target: CitationTarget
    public let document: PDFDocumentContent
}
public struct PDFDocumentContent: Identifiable {
    public let id, title, period: String
    public let pageCount: Int
    public let fileURL: URL
    public let resume: PDFDocumentChoice
}
public struct PDFLoadAttempt: Hashable { let rawValue: UUID; init() { rawValue = UUID() } }
public struct PDFPlacementID: Hashable { let rawValue: UUID; init() { rawValue = UUID() } }
public struct PDFObservationToken: Hashable {
    let attempt: PDFLoadAttempt
    let placement: PDFPlacementID
}
public enum PDFReadingFailure: Error, Equatable { case missingFile, invalidDocument, invalidPage, pageCountMismatch }
public enum PDFDocumentLoadState: Equatable { case loading, ready, failed(PDFReadingFailure) }
public struct PDFRenderRequest {
    public let attempt: PDFLoadAttempt
    public let observation: PDFObservationToken
    public let placementID: PDFPlacementID
    public let targetPhysicalPage: Int
    public let focusText: String?
    public let cause: PositionCause
}
public struct PDFReadingPage {
    public let visitID: SourceVisitID
    public let document: PDFDocumentContent
    public let currentCitation: CitationContent?
    public let visiblePhysicalPage: Int?
    public let resumePhysicalPage: Int?
    public let loadState: PDFDocumentLoadState
    public let request: PDFRenderRequest
}
