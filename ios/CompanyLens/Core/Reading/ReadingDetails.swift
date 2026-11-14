import Foundation

enum DetailAddress: Hashable, Codable {
    case explanation(DetailContext)
    case calculations(DetailContext)
    case evidence(DetailContext, selected: [String]?)
    case pdf(String)
    var context: DetailContext? {
        switch self {
        case .explanation(let context), .calculations(let context), .evidence(let context, _): return context
        case .pdf: return nil
        }
    }
    var storageKey: String {
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
        return (try? encoder.encode(self).base64EncodedString()) ?? ""
    }
}
struct DetailPosition: Codable, Equatable { let address: DetailAddress; let position: ReadingPosition }
struct DetailVisit {
    let address: DetailAddress
    let visitID = SourceVisitID()
    let token: PresentationToken
    var activationID = UUID()
    var scopeID = UUID()
    var position: ReadingPosition?
    var arrivalCause = PositionCause.userNavigation
    var pdf: PDFVisitState?

    func access(readerID: UUID) -> ReaderAccess {
        ReaderAccess(readerID: readerID, activationID: activationID, scopeID: scopeID)
    }

}

/// One temporary reading path. Main navigation stays fixed while it is open.
struct ReadingDetails {
    var visits: [DetailVisit] = []
    var remembered: [DetailAddress: ReadingPosition] = [:]
    var savedPositions: [DetailPosition] {
        remembered.map { DetailPosition(address: $0.key, position: $0.value) }
            .sorted { $0.address.storageKey < $1.address.storageKey }
    }
    var current: DetailVisit? { visits.last }
    mutating func remember(_ position: ReadingPosition) {
        guard !visits.isEmpty else { return }
        visits[visits.count - 1].position = position
        remembered[visits[visits.count - 1].address] = position
    }
    mutating func open(_ address: DetailAddress, readerID: UUID) {
        visits.append(DetailVisit(address: address,
            token: PresentationToken(reader: readerID, presentation: UUID()), position: remembered[address]))
    }
    mutating func openPDF(sourceID: String, state: PDFVisitState, readerID: UUID) {
        visits.append(DetailVisit(address: .pdf(sourceID),
            token: PresentationToken(reader: readerID, presentation: UUID()), pdf: state))
    }
    mutating func updatePDF(_ state: PDFVisitState) {
        guard !visits.isEmpty, case .pdf = visits[visits.count - 1].address else { return }
        visits[visits.count - 1].pdf = state
    }
    mutating func placePDF(_ state: PDFVisitState) {
        updatePDF(state)
        guard !visits.isEmpty else { return }
        visits[visits.count - 1].scopeID = UUID()
    }
    mutating func back() {
        guard !visits.isEmpty else { return }
        visits.removeLast()
        reactivate()
    }
    mutating func dismiss(_ token: PresentationToken) -> Bool {
        guard let index = visits.firstIndex(where: { $0.token == token }) else { return false }
        visits.removeSubrange(index...)
        reactivate()
        return true
    }
    mutating func reactivate() {
        guard !visits.isEmpty else { return }
        visits[visits.count - 1].activationID = UUID()
        visits[visits.count - 1].scopeID = UUID()
        visits[visits.count - 1].arrivalCause = .restoration
    }
}
