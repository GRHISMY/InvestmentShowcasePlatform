import Foundation

/// An actual observation updates only these slots, with its original occurrence time.
public struct ReadingSlotCheckpoint: Codable, Equatable {
    public let slotKey: String
    public let payload: Data
    public let occurredAt: Date
    public init(slotKey: String, payload: Data, occurredAt: Date) {
        self.slotKey = slotKey; self.payload = payload; self.occurredAt = occurredAt
    }
}

public struct ReadingCheckpoint: Codable, Equatable {
    public static let mainSlotKey = "main"
    public let identity: StudyIdentity
    public let eventID: UUID
    public let updates: [ReadingSlotCheckpoint]
    public init(identity: StudyIdentity, eventID: UUID = UUID(), updates: [ReadingSlotCheckpoint]) {
        self.identity = identity; self.eventID = eventID; self.updates = updates
    }
}

public struct RestoreCandidate: Codable, Equatable {
    public let checkpoint: ReadingSlotCheckpoint
    public let isLocalDevice: Bool
    public init(checkpoint: ReadingSlotCheckpoint, isLocalDevice: Bool = false) {
        self.checkpoint = checkpoint; self.isLocalDevice = isLocalDevice
    }
}

/// Candidates arrive ordered with provenance; unknown provenance is conservatively remote.
public struct RestoreCandidates: Codable, Equatable {
    public let identity: StudyIdentity
    public let records: [RestoreCandidate]
    public var candidates: [ReadingSlotCheckpoint] { records.map(\.checkpoint) }
    public init(identity: StudyIdentity, candidates: [ReadingSlotCheckpoint]) {
        self.init(identity: identity, records: candidates.map { RestoreCandidate(checkpoint: $0) })
    }
    public init(identity: StudyIdentity, records: [RestoreCandidate]) {
        self.identity = identity; self.records = records
    }
}
