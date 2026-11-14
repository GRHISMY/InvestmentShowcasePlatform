import Foundation

public struct FullscreenDiagramPresentation {
    public let presentationToken: PresentationToken
    public let diagram: DiagramPage
    public let observation: ObservationToken
    public let arrivalCause: PositionCause
    public let isDisplayed: Bool
}

/// Viewing has its own activation, never another scene, focus or viewport.
struct DiagramViewing {
    let presentationToken: PresentationToken
    private let activationID = UUID()
    private var scopeID = UUID()
    private(set) var isDisplayed = false
    private var focusAwaitingDisplay = false
    let arrivalCause = PositionCause.userNavigation
    var mainArrivalCause: PositionCause { focusAwaitingDisplay ? .userNavigation : .restoration }

    init(readerID: UUID) {
        presentationToken = PresentationToken(reader: readerID, presentation: UUID())
    }

    func access(readerID: UUID) -> ReaderAccess {
        ReaderAccess(readerID: readerID, activationID: activationID, scopeID: scopeID)
    }

    mutating func focusChanged() {
        scopeID = UUID()
        isDisplayed = false
        focusAwaitingDisplay = true
    }

    mutating func confirmDisplayed(_ token: ObservationToken, readerID: UUID) -> Bool {
        guard !isDisplayed, token == access(readerID: readerID).observation else { return false }
        isDisplayed = true
        focusAwaitingDisplay = false
        return true
    }

    func projection(content: ReaderContent, state: ReaderNavigationState, readerID: UUID) -> FullscreenDiagramPresentation? {
        var viewingState = state
        viewingState.current.arrivalCause = arrivalCause
        let viewingAccess = access(readerID: readerID)
        guard case .diagram(let diagram) = content.primary(viewingState, access: viewingAccess) else { return nil }
        return FullscreenDiagramPresentation(presentationToken: presentationToken, diagram: diagram,
            observation: viewingAccess.observation, arrivalCause: arrivalCause, isDisplayed: isDisplayed)
    }
}
