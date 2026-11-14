import Foundation

/// Stores opaque semantic slots. Only Reading interprets their contents.
struct ShelfRecords {
    struct Slot: Codable, Equatable {
        let identity: StudyIdentity
        let value: ReadingSlotCheckpoint
        let sequence: UInt64
        let eventID: UUID
    }
    struct DeviceFile: Codable, Equatable {
        let schemaVersion: Int
        let deviceID: String
        var sequence: UInt64
        var slots: [Slot]
    }
    let deviceID: String
    private(set) var devices: [String: DeviceFile]
    private var acceptedEvents: Set<UUID> = []

    init(deviceID: String) {
        self.deviceID = deviceID
        devices = [deviceID: DeviceFile(schemaVersion: 1, deviceID: deviceID, sequence: 0, slots: [])]
    }

    var ownFile: DeviceFile? { devices[deviceID] }

    mutating func restoreOwn(_ saved: DeviceFile) {
        devices[deviceID] = saved
        acceptedEvents.formUnion(saved.slots.map(\.eventID))
    }

    mutating func accept(_ checkpoint: ReadingCheckpoint) -> Bool {
        guard !checkpoint.updates.isEmpty, !acceptedEvents.contains(checkpoint.eventID),
              var own = devices[deviceID], own.sequence < UInt64.max else { return false }
        acceptedEvents.insert(checkpoint.eventID)
        own.sequence += 1
        for update in checkpoint.updates {
            own.slots.removeAll { $0.identity == checkpoint.identity && $0.value.slotKey == update.slotKey }
            own.slots.append(Slot(identity: checkpoint.identity, value: update, sequence: own.sequence, eventID: checkpoint.eventID))
        }
        devices[deviceID] = own
        return true
    }

    static func decode(_ data: Data, expectedDeviceID: String) throws -> DeviceFile {
        let decoded = try JSONDecoder().decode(DeviceFile.self, from: data)
        guard try ShelfPath.parts(expectedDeviceID).count == 1,
              decoded.schemaVersion == 1, decoded.deviceID == expectedDeviceID,
              decoded.slots.allSatisfy({ $0.sequence > 0 && $0.sequence <= decoded.sequence }) else {
            throw StudyPackageError.invalidManifest("personal record")
        }
        return decoded
    }

    mutating func receive(_ incoming: DeviceFile) -> Bool {
        if let current = devices[incoming.deviceID], current.sequence >= incoming.sequence { return false }
        devices[incoming.deviceID] = incoming
        if incoming.deviceID == deviceID { acceptedEvents.formUnion(incoming.slots.map(\.eventID)) }
        return true
    }

    func restoration(for identity: StudyIdentity, preferred: ShelfContinuationChoice? = nil) -> RestoreCandidates {
        let values = devices.values.flatMap { device in
            device.slots.filter { $0.identity == identity }.map { (device.deviceID, $0) }
        }.sorted { left, right in
            func isPreferred(_ value: (String, Slot)) -> Bool {
                value.1.value.slotKey == ReadingCheckpoint.mainSlotKey && value.0 == preferred?.deviceID
                    && value.1.sequence == preferred?.sequence
            }
            if isPreferred(left) != isPreferred(right) { return isPreferred(left) }
            if left.1.value.occurredAt != right.1.value.occurredAt { return left.1.value.occurredAt > right.1.value.occurredAt }
            if left.0 == right.0 { return left.1.sequence > right.1.sequence }
            return left.0 < right.0
        }
        return RestoreCandidates(identity: identity, records: values.map {
            RestoreCandidate(checkpoint: $0.1.value, isLocalDevice: $0.0 == deviceID)
        })
    }

    var continuations: [ShelfContinuationChoice] {
        devices.values.flatMap { device in
            device.slots.filter { $0.value.slotKey == ReadingCheckpoint.mainSlotKey }.map { slot in
                ShelfContinuationChoice(id: device.deviceID + "." + String(slot.sequence) + "." + slot.identity.snapshotManifestSHA256,
                    versionID: ShelfVersionID(companyID: slot.identity.companyID,
                        versionID: ShelfPublicationIdentity.versionID(snapshotID: slot.identity.snapshotID,
                            manifestSHA256: slot.identity.snapshotManifestSHA256)),
                    identity: slot.identity, deviceID: device.deviceID, sequence: slot.sequence,
                    occurredAt: slot.value.occurredAt, isLocalDevice: device.deviceID == deviceID)
            }
        }.sorted {
            if $0.occurredAt != $1.occurredAt { return $0.occurredAt > $1.occurredAt }
            if $0.deviceID == $1.deviceID { return $0.sequence > $1.sequence }
            return $0.deviceID < $1.deviceID
        }
    }
}

/// A concrete local filesystem, exercised with real temporary directories in tests.
/// There is no mock repository between the shelf and atomic file replacement.
enum ShelfRecordDisk {
    static func load(deviceID: String, root: URL) throws -> ShelfRecords.DeviceFile? {
        let file = try location(deviceID: deviceID, root: root)
        guard FileManager.default.fileExists(atPath: file.path) else { return nil }
        let decoded = try JSONDecoder().decode(ShelfRecords.DeviceFile.self, from: Data(contentsOf: file))
        guard decoded.schemaVersion == 1, decoded.deviceID == deviceID else {
            throw StudyPackageError.invalidManifest("personal record")
        }
        return decoded
    }
    static func save(_ record: ShelfRecords.DeviceFile, root: URL) async throws {
        try await Task.detached {
            let file = try location(deviceID: record.deviceID, root: root)
            try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.sortedKeys]
            try encoder.encode(record).write(to: file, options: .atomic)
        }.value
    }
    static func loadReceived(root: URL) throws -> [ShelfRecords.DeviceFile] {
        let directory = try ShelfPath.local("personal/received", in: root)
        guard FileManager.default.fileExists(atPath: directory.path) else { return [] }
        return try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
            .filter { $0.pathExtension == "json" }.compactMap { file in
                try? ShelfRecords.decode(Data(contentsOf: file), expectedDeviceID: file.deletingPathExtension().lastPathComponent)
            }
    }
    static func saveReceived(_ record: ShelfRecords.DeviceFile, root: URL) async throws {
        guard try ShelfPath.parts(record.deviceID).count == 1 else { throw CloudFolderError.invalidPath(record.deviceID) }
        let file = try ShelfPath.local("personal/received/" + record.deviceID + ".json", in: root)
        try await receivedWriter.save(record, to: file)
    }
    private static let receivedWriter = ReceivedRecordWriter()

    private static func location(deviceID: String, root: URL) throws -> URL {
        guard try ShelfPath.parts(deviceID).count == 1 else { throw CloudFolderError.invalidPath(deviceID) }
        return try ShelfPath.local("personal/" + deviceID + ".json", in: root)
    }
}

/// A late older delivery cannot replace a newer on-disk device candidate.
private actor ReceivedRecordWriter {
    func save(_ record: ShelfRecords.DeviceFile, to file: URL) throws {
        if let data = try? Data(contentsOf: file),
           let previous = try? ShelfRecords.decode(data, expectedDeviceID: record.deviceID),
           previous.sequence >= record.sequence { return }
        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        try JSONEncoder().encode(record).write(to: file, options: .atomic)
    }
}
