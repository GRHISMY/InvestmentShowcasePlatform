import Foundation

/// Owns the current scene, its selected detail, and the path back through scenes.
/// The overview temporarily covers the scene; it does not discard its position.
public struct VisualStudyState: Codable, Equatable {
    private struct Visit: Codable, Equatable {
        let id: String
        let focus: String?
    }

    private let momentIDs: [String]
    private var visits: [Visit] = []
    public private(set) var currentID: String
    public private(set) var focus: String?
    public private(set) var isOverview: Bool

    public var history: [String] { visits.map(\.id) }

    /// A bookmark is restored only against the same ordered scene catalogue.
    /// Invalid or obsolete data starts a fresh reading session.
    public init(momentIDs: [String], saved: Data? = nil) {
        var seen = Set<String>()
        let catalogue = momentIDs.filter { Self.isNonempty($0) && seen.insert($0).inserted }
        if let saved, let restored = try? JSONDecoder().decode(Self.self, from: saved),
           restored.momentIDs == catalogue {
            self = restored
            return
        }
        self.momentIDs = catalogue
        currentID = catalogue.first ?? ""
        focus = nil
        isOverview = catalogue.isEmpty
    }

    public mutating func enter(_ id: String) {
        guard momentIDs.contains(id) else { return }
        if id != currentID {
            visits.append(Visit(id: currentID, focus: focus))
            currentID = id
            focus = nil
        }
        isOverview = false
    }

    /// The last scene stays open until the reader explicitly opens the overview.
    public mutating func advance() {
        guard let position = momentIDs.firstIndex(of: currentID) else { return }
        if isOverview {
            isOverview = false
        } else if momentIDs.indices.contains(position + 1) {
            enter(momentIDs[position + 1])
        }
    }

    public mutating func back() {
        guard !momentIDs.isEmpty else { return }
        if isOverview {
            isOverview = false
        } else if let previous = visits.popLast() {
            currentID = previous.id
            focus = previous.focus
        } else {
            isOverview = true
        }
    }

    public mutating func overview() {
        isOverview = true
    }

    /// Focus IDs belong to each scene's content; this state machine keeps them
    /// opaque. The caller supplies a real detail ID or nil to close that detail.
    public mutating func selectFocus(_ id: String?) {
        guard !isOverview, !currentID.isEmpty else { return }
        if let id, !Self.isNonempty(id) { return }
        focus = id
    }

    public func encodedBookmark() -> Data? {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return try? encoder.encode(self)
    }

    private static func isNonempty(_ id: String) -> Bool {
        !id.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private enum CodingKeys: String, CodingKey {
        case schemaVersion, momentIDs, currentID, focus, history, isOverview
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let version = try container.decode(Int.self, forKey: .schemaVersion)
        guard version == 1 else {
            throw DecodingError.dataCorruptedError(forKey: .schemaVersion, in: container,
                                                  debugDescription: "Unsupported reading bookmark version")
        }
        momentIDs = try container.decode([String].self, forKey: .momentIDs)
        currentID = try container.decode(String.self, forKey: .currentID)
        focus = try container.decodeIfPresent(String.self, forKey: .focus)
        visits = try container.decode([Visit].self, forKey: .history)
        isOverview = try container.decode(Bool.self, forKey: .isOverview)
        let known = Set(momentIDs)
        let catalogueIsValid = known.count == momentIDs.count && momentIDs.allSatisfy(Self.isNonempty)
        let focusIsValid = focus.map(Self.isNonempty) ?? true
        let path = visits.map(\.id) + [currentID]
        let visitsAreValid = visits.allSatisfy {
            known.contains($0.id) && ($0.focus.map(Self.isNonempty) ?? true)
        } && zip(path, path.dropFirst()).allSatisfy { $0 != $1 }
        let positionIsValid = momentIDs.isEmpty
            ? currentID.isEmpty && focus == nil && visits.isEmpty && isOverview
            : known.contains(currentID)
        guard catalogueIsValid, focusIsValid, visitsAreValid, positionIsValid else {
            throw DecodingError.dataCorruptedError(forKey: .currentID, in: container,
                                                  debugDescription: "Invalid reading position or scene history")
        }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(1, forKey: .schemaVersion)
        try container.encode(momentIDs, forKey: .momentIDs)
        try container.encode(currentID, forKey: .currentID)
        try container.encodeIfPresent(focus, forKey: .focus)
        try container.encode(visits, forKey: .history)
        try container.encode(isOverview, forKey: .isOverview)
    }
}
