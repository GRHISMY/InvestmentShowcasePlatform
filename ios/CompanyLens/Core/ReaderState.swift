import Foundation

/// The destination and its research context travel together through the reading stack.
public enum ReaderRoute: Hashable {
    case claim(String)
    case evidence(String)
    case calculation(String)
    case source(claimID: String?, evidenceID: String)
    case dimension(String)
}

public enum PDFLoadState: Equatable {
    case idle
    case loading(String)
    case ready(evidenceID: String, page: Int, pageCount: Int)
    case failed(String)
}

public enum ReaderEvent: Equatable {
    case open(ReaderRoute)
    case backToDepth(Int)
    case rememberAnchor(route: ReaderRoute, anchor: String)
    case showGlossary(String)
    case dismissGlossary
    case pdfLoaded(evidenceID: String, page: Int, pageCount: Int)
    case pdfFailed(evidenceID: String)
    case retryPDF
    case reset
}

/// One interface owns navigation, reading positions, the glossary overlay, and PDF lifecycle.
/// Invalid transitions are ignored. Async PDF results are accepted only for the current source.
public struct ReaderState: Equatable {
    public private(set) var path: [ReaderRoute] = []
    public private(set) var bookmarks: [ReaderRoute: String] = [:]
    public private(set) var glossaryID: String?
    public private(set) var pdfStatus: PDFLoadState = .idle

    public init() {}

    public var current: ReaderRoute? { path.last }

    public func anchor(for route: ReaderRoute) -> String? { bookmarks[route] }

    public mutating func send(_ event: ReaderEvent) {
        switch event {
        case .open(let route):
            guard route != current, canOpen(route) else { return }
            path.append(route)
            glossaryID = nil
            beginCurrentPDFIfNeeded()

        case .backToDepth(let depth):
            guard depth >= 0, depth < path.count else { return }
            path.removeLast(path.count - depth)
            glossaryID = nil
            beginCurrentPDFIfNeeded()

        case .rememberAnchor(let route, let anchor):
            // A disappearing screen can still report its position after a child is pushed.
            guard path.contains(route) else { return }
            if anchor.isEmpty {
                bookmarks.removeValue(forKey: route)
            } else {
                bookmarks[route] = anchor
            }

        case .showGlossary(let id):
            guard !id.isEmpty else { return }
            glossaryID = id

        case .dismissGlossary:
            glossaryID = nil

        case .pdfLoaded(let evidenceID, let page, let pageCount):
            guard currentEvidenceID == evidenceID else { return }
            guard pageCount > 0, (1...pageCount).contains(page) else {
                pdfStatus = .failed(evidenceID)
                return
            }
            pdfStatus = .ready(evidenceID: evidenceID, page: page, pageCount: pageCount)

        case .pdfFailed(let evidenceID):
            guard currentEvidenceID == evidenceID else { return }
            pdfStatus = .failed(evidenceID)

        case .retryPDF:
            guard let id = currentEvidenceID, pdfStatus == .failed(id) else { return }
            pdfStatus = .loading(id)

        case .reset:
            self = ReaderState()
        }
    }

    private var currentEvidenceID: String? {
        guard case .source(_, let id) = current else { return nil }
        return id
    }

    private func canOpen(_ route: ReaderRoute) -> Bool {
        switch route {
        case .claim(let id):
            guard !id.isEmpty else { return false }
            if path.isEmpty { return true }
            // A dimension summary is a real parent, so back restores its reading position.
            guard case .dimension = current else { return false }
            return true
        case .dimension(let id):
            return !id.isEmpty && path.isEmpty
        case .evidence(let id):
            guard case .claim(let owner) = current else { return false }
            return !id.isEmpty && id == owner
        case .calculation(let id):
            guard case .evidence(let owner) = current else { return false }
            return !id.isEmpty && id == owner
        case .source(let owner, let evidenceID):
            guard !evidenceID.isEmpty else { return false }
            if let owner {
                switch current {
                case .evidence(let active), .calculation(let active):
                    return !owner.isEmpty && owner == active
                default:
                    return false
                }
            }
            // Summary-only dimensions can show original material without a full claim.
            guard case .dimension = current else { return false }
            return true
        }
    }

    private mutating func beginCurrentPDFIfNeeded() {
        if let id = currentEvidenceID {
            pdfStatus = .loading(id)
        } else {
            pdfStatus = .idle
        }
    }
}
