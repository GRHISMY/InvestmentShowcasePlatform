import Foundation

public struct ShelfVersionID: Hashable, Codable {
    public let companyID: String
    public let versionID: String
}

public enum ShelfConnectionState: Equatable {
    case disconnected
    case checking
    case connected
    case needsSelection(String)
    case unavailable(String)
}

public enum ShelfPreparationState: Equatable {
    case waiting
    case preparing
    case ready
    case failed(String)
}

public struct ShelfVersionEntry: Identifiable {
    public let id: ShelfVersionID
    public let snapshotID: String
    public let reportRevision: Int
    public let financialPeriodStart, financialPeriodEnd, researchAsOf: String
    public let isCurrent: Bool
    public let state: ShelfPreparationState
}

public struct ShelfEntry: Identifiable {
    public let id, name, code, exchange: String
    public let currentVersionID: ShelfVersionID
    public let versions: [ShelfVersionEntry]
    public internal(set) var continuations: [ShelfContinuationChoice] = []
    public internal(set) var hasUpdate = false
    /// The library's ordered recommendation for this company, including its original version.
    public var recommendedContinuation: ShelfContinuationChoice? { continuations.first }
}

public struct ShelfReading: Identifiable {
    public let id = UUID()
    public let study: ReadableStudy
    public var reader: StudyReader
}

public enum ShelfOpenResult {
    case opened(ShelfReading)
    case unavailable(String)
    case superseded
}

public struct ShelfContinuationChoice: Identifiable, Equatable {
    public let id: String
    public let versionID: ShelfVersionID
    public let identity: StudyIdentity
    public let deviceID: String
    public let sequence: UInt64
    public let occurredAt: Date
    public let isLocalDevice: Bool
}
