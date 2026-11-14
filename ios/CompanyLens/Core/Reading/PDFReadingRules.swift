import Foundation

struct PDFCitation: Codable, Hashable {
    let id, sourceID: String
    let physicalPage: Int
    let focusText: String?
    init(_ target: CitationTarget) {
        id = target.citationID; sourceID = target.sourceID
        physicalPage = target.physicalPage; focusText = target.focusText
    }
}
struct PDFVisitState {
    var citation: PDFCitation?
    var targetPhysicalPage: Int
    var visiblePhysicalPage: Int?
    var loadState = PDFDocumentLoadState.loading
    var attempt = PDFLoadAttempt()
    var placement = PDFPlacementID()
    var cause = PositionCause.programmatic
    var placementFocusText: String?
    var pendingPage: PDFPageFact?
    var userBrowsedPlacement = false
    var observation: PDFObservationToken { PDFObservationToken(attempt: attempt, placement: placement) }
    var request: PDFRenderRequest {
        PDFRenderRequest(attempt: attempt, observation: observation, placementID: placement,
            targetPhysicalPage: targetPhysicalPage, focusText: placementFocusText, cause: cause)
    }
}
struct PDFPageFact { let physicalPage: Int; let cause: PositionCause; let occurredAt: Date? }
struct AcceptedPDFReading { let physicalPage: Int; let occurredAt: Date }
struct PDFReadingRules {
    var resumePages: [String: Int] = [:]

    func locate(_ citation: PDFCitation, state: inout PDFVisitState) {
        state.citation = citation
        state.targetPhysicalPage = citation.physicalPage
        state.placementFocusText = citation.focusText
        state.placement = PDFPlacementID()
        state.cause = .programmatic
        state.pendingPage = nil
        state.userBrowsedPlacement = false
    }
    func continueReading(sourceID: String, state: inout PDFVisitState) {
        state.targetPhysicalPage = resumePages[sourceID] ?? 1
        state.placementFocusText = nil
        state.placement = PDFPlacementID()
        state.cause = .programmatic
        state.pendingPage = nil
        state.userBrowsedPlacement = false
    }
    func retry(state: inout PDFVisitState) -> Bool {
        guard case .failed = state.loadState else { return false }
        state.attempt = PDFLoadAttempt()
        state.placement = PDFPlacementID()
        state.loadState = .loading
        state.visiblePhysicalPage = nil
        state.pendingPage = nil
        state.userBrowsedPlacement = false
        state.cause = .programmatic
        return true
    }

    mutating func loaded(_ attempt: PDFLoadAttempt, result: Result<Int, PDFReadingFailure>,
                         state: inout PDFVisitState, sourceID: String, pageCount: Int,
                         clock: () -> Date) -> AcceptedPDFReading? {
        guard state.attempt == attempt, state.loadState == .loading else { return nil }
        switch result {
        case .failure(let failure):
            state.loadState = .failed(failure); state.pendingPage = nil
            return nil
        case .success(let actualCount):
            guard actualCount == pageCount else {
                state.loadState = .failed(.pageCountMismatch); state.pendingPage = nil
                return nil
            }
            state.loadState = .ready
            if let pending = state.pendingPage {
                state.pendingPage = nil
                return page(state.observation, physicalPage: pending.physicalPage, cause: pending.cause,
                     state: &state, sourceID: sourceID, pageCount: pageCount,
                     clock: clock, originalTime: pending.occurredAt)
            }
            return nil
        }
    }

    mutating func page(_ token: PDFObservationToken, physicalPage: Int, cause: PositionCause,
                      state: inout PDFVisitState, sourceID: String, pageCount: Int,
                      clock: () -> Date, originalTime: Date? = nil) -> AcceptedPDFReading? {
        guard token == state.observation, (1...pageCount).contains(physicalPage),
              state.loadState == .loading || state.loadState == .ready else { return nil }
        guard cause == .userBrowsing || !state.userBrowsedPlacement else { return nil }
        let time = cause == .userBrowsing ? (originalTime ?? clock()) : nil
        if cause == .userBrowsing { state.userBrowsedPlacement = true }
        if state.loadState == .loading {
            state.pendingPage = PDFPageFact(physicalPage: physicalPage, cause: cause, occurredAt: time)
            return nil
        }
        state.visiblePhysicalPage = physicalPage
        if cause == .userBrowsing { resumePages[sourceID] = physicalPage }
        return time.map { AcceptedPDFReading(physicalPage: physicalPage, occurredAt: $0) }
    }
}
