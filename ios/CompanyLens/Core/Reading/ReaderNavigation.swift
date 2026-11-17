import Foundation

enum ReaderAddress: Codable, Equatable {
    case overview
    case diagram(sceneID: String, focusID: String?)
    case report
    var mode: ReadingMode { if case .report = self { return .report }; return .diagram }
}

struct ReaderLocation: Codable, Equatable {
    var address: ReaderAddress
    var position: ReadingPosition?
    let visitID: SourceVisitID

    init(_ address: ReaderAddress, position: ReadingPosition? = nil, visitID: SourceVisitID = SourceVisitID()) {
        self.address = address
        self.position = position
        self.visitID = visitID
    }
}

struct ReaderVisit {
    var location: ReaderLocation
    let activationID = UUID()
    var scopeID = UUID()
    var arrivalCause: PositionCause
}

/// Source locations survive Back; authorization belongs to each activation.
struct ReaderNavigationState {
    var current = ReaderVisit(location: ReaderLocation(.overview), arrivalCause: .programmatic)
    var history: [ReaderLocation] = []
    var overviewOrigins: [SourceVisitID: ReaderLocation] = [:]
    var overviewOrigin: ReaderLocation? {
        get { overviewOrigins[current.location.visitID] }
        set { overviewOrigins[current.location.visitID] = newValue }
    }
    var overviewPosition: ReadingPosition?
    var modeLocations: [ReadingMode: ReaderLocation] = [:]

    var isOverview: Bool { if case .overview = current.location.address { return true }; return false }

    mutating func activate(_ location: ReaderLocation, cause: PositionCause = .userNavigation) {
        modeLocations[current.location.address.mode] = current.location
        current = ReaderVisit(location: location, arrivalCause: cause)
        modeLocations[location.address.mode] = location
    }

    mutating func enterScene(_ id: String) {
        if isOverview, let origin = overviewOrigin {
            if case .diagram(let sourceID, _) = origin.address, sourceID == id {
                activate(origin)
                return
            }
            history.append(origin)
        } else if !isOverview {
            if case .diagram(let sourceID, _) = current.location.address, sourceID == id { return }
            history.append(current.location)
        }
        activate(ReaderLocation(.diagram(sceneID: id, focusID: nil)))
    }

    mutating func showOverview() {
        guard !isOverview else { return }
        let overview = ReaderLocation(.overview, position: overviewPosition)
        overviewOrigins[overview.visitID] = current.location
        activate(overview)
    }

    mutating func back() {
        if isOverview {
            guard let origin = overviewOrigin else { return }
            activate(origin)
        } else if let origin = history.popLast() {
            activate(origin)
        } else { showOverview() }
    }

    mutating func selectFocus(_ id: String) {
        guard case .diagram(let sceneID, _) = current.location.address else { return }
        current.location.address = .diagram(sceneID: sceneID, focusID: id)
        if let position = current.location.position, ["explanation", "limits"].contains(position.anchorID) {
            current.location.position = ReadingPosition(anchorID: position.anchorID)
        }
        current.scopeID = UUID()
        current.arrivalCause = .userNavigation
    }

    mutating func remember(_ position: ReadingPosition) {
        current.location.position = position
        modeLocations[current.location.address.mode] = current.location
        if isOverview { overviewPosition = position }
    }

    mutating func follow(_ location: ReaderLocation) {
        guard location.address != current.location.address || location.position != current.location.position else { return }
        history.append(current.location)
        activate(location)
    }
}

enum LinkTarget: Hashable {
    case scene(String), overview, restart
    case reportClaim(String)
    case reportAnchor(String)
    case diagram(sceneID: String, focusID: String)
    case explanation(DetailContext), calculations(DetailContext), evidence(DetailContext)
    case evidenceSelection(DetailContext, [String])
}

struct ReaderAccess {
    let readerID: UUID
    private let activationID: UUID
    private let scopeID: UUID

    init(readerID: UUID, visit: ReaderVisit) {
        self.init(readerID: readerID, activationID: visit.activationID, scopeID: visit.scopeID)
    }
    init(readerID: UUID, activationID: UUID, scopeID: UUID) {
        self.readerID = readerID
        self.activationID = activationID
        self.scopeID = scopeID
    }
    var observation: ObservationToken {
        ObservationToken(reader: readerID, activation: activationID, scope: scopeID)
    }
    func link(_ target: LinkTarget) -> ReadingLink {
        ReadingLink(reader: readerID, activation: activationID, scope: scopeID, target: target)
    }
    func choice(_ id: String, sceneID: String) -> FocusChoice {
        FocusChoice(id: id, reader: readerID, activation: activationID, sceneID: sceneID)
    }
    func accepts(_ link: ReadingLink) -> Bool {
        link.reader == readerID && link.activation == activationID && link.scope == scopeID
    }
    func accepts(_ choice: FocusChoice) -> Bool {
        choice.reader == readerID && choice.activation == activationID
    }
    func document(_ sourceID: String) -> PDFDocumentChoice {
        PDFDocumentChoice(reader: readerID, activation: activationID, scope: scopeID, sourceID: sourceID)
    }
    func citation(_ page: EvidencePage) -> CitationTarget {
        CitationTarget(reader: readerID, activation: activationID, scope: scopeID,
            citationID: page.id, sourceID: page.sourceId, physicalPage: page.physicalPage, focusText: page.focusText)
    }
    func accepts(_ target: CitationTarget) -> Bool {
        target.reader == readerID && target.activation == activationID && target.scope == scopeID
    }
    func accepts(_ document: PDFDocumentChoice) -> Bool {
        document.reader == readerID && document.activation == activationID && document.scope == scopeID
    }
    func citation(_ value: PDFCitation) -> CitationTarget {
        CitationTarget(reader: readerID, activation: activationID, scope: scopeID,
            citationID: value.id, sourceID: value.sourceID, physicalPage: value.physicalPage, focusText: value.focusText)
    }
}

enum DetailContext: Hashable, Codable {
    case focus(sceneID: String, focusID: String)
    case claim(String)
}
