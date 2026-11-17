import Foundation

/// Semantic addresses cross devices; runtime visit and observation identities never do.
struct SemanticReadingLocation: Codable {
    let address: ReaderAddress
    let position: ReadingPosition?
    init(_ location: ReaderLocation) { address = location.address; position = location.position }
    var freshLocation: ReaderLocation { ReaderLocation(address, position: position) }
}
struct MainReadingSource: Codable {
    let location: SemanticReadingLocation
    let overviewOrigin: SemanticReadingLocation?
}
struct RestoredMainReading {
    let location: ReaderLocation
    let history: [ReaderLocation]
    let overviewOrigins: [SourceVisitID: ReaderLocation]
}
struct MainReadingRecord: Codable {
    let schemaVersion: Int
    let location: SemanticReadingLocation
    let overviewOrigin: SemanticReadingLocation?
    let history: [MainReadingSource]?
}
struct DetailReadingRecord: Codable { let schemaVersion: Int; let detail: DetailPosition }
struct PDFReadingRecord: Codable { let schemaVersion: Int; let sourceID: String; let physicalPage: Int }
enum MainReadingRestoration { case restored, restoredAlternative, unavailable }

/// Emits one observation's changed slots rather than re-dating an entire saved reader.
struct ReaderRecords {
    let identity: StudyIdentity
    let clock: () -> Date
    private(set) var checkpoint: ReadingCheckpoint?

    mutating func main(_ state: ReaderNavigationState) {
        let value = MainReadingRecord(schemaVersion: 1, location: SemanticReadingLocation(state.current.location),
            overviewOrigin: state.overviewOrigin.map(SemanticReadingLocation.init),
            history: state.history.map { location in
                MainReadingSource(location: SemanticReadingLocation(location),
                    overviewOrigin: state.overviewOrigins[location.visitID].map(SemanticReadingLocation.init))
            })
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
        guard let payload = try? encoder.encode(value) else { return }
        emit([(ReadingCheckpoint.mainSlotKey, payload), ("mode:" + state.current.location.address.mode.rawValue, payload)])
    }

    mutating func detail(_ address: DetailAddress, position: ReadingPosition) {
        let value = DetailReadingRecord(schemaVersion: 1, detail: DetailPosition(address: address, position: position))
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
        guard let payload = try? encoder.encode(value) else { return }
        emit([("detail:" + address.storageKey, payload)])
    }

    mutating func pdf(_ sourceID: String, reading: AcceptedPDFReading) {
        let value = PDFReadingRecord(schemaVersion: 1, sourceID: sourceID, physicalPage: reading.physicalPage)
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
        guard let payload = try? encoder.encode(value) else { return }
        emit([("pdf:" + sourceID, payload)], occurredAt: reading.occurredAt)
    }

    private mutating func emit(_ values: [(String, Data)], occurredAt: Date? = nil) {
        let time = occurredAt ?? clock()
        guard time.timeIntervalSinceReferenceDate.isFinite else { return }
        checkpoint = ReadingCheckpoint(identity: identity, updates: values.map {
            ReadingSlotCheckpoint(slotKey: $0.0, payload: $0.1, occurredAt: time)
        })
    }

    static func validMain(_ candidate: ReadingSlotCheckpoint, content: ReaderContent,
                          isLocalDevice: Bool) -> RestoredMainReading? {
        guard candidate.occurredAt.timeIntervalSinceReferenceDate.isFinite,
              let value = try? JSONDecoder().decode(MainReadingRecord.self, from: candidate.payload),
              value.schemaVersion == 1 else { return nil }
        func appropriate(_ value: ReaderLocation) -> ReaderLocation {
            guard !isLocalDevice, let position = value.position else { return value }
            var result = value
            result.position = ReadingPosition(anchorID: position.anchorID)
            return result
        }
        var origins: [SourceVisitID: ReaderLocation] = [:]
        func restore(_ source: MainReadingSource) -> ReaderLocation? {
            guard source.location.position.map({ position in
                content.anchors(source.location.address).contains { $0.id == position.anchorID }
            }) ?? true, let valid = content.sanitized(source.location.freshLocation) else { return nil }
            let location = appropriate(valid)
            if case .overview = location.address,
               let origin = source.overviewOrigin.flatMap({ content.sanitized($0.freshLocation) }),
               content.scene(origin) != nil {
                origins[location.visitID] = appropriate(origin)
            }
            return location
        }
        guard let location = restore(MainReadingSource(location: value.location, overviewOrigin: value.overviewOrigin)) else { return nil }
        let history = (value.history ?? []).compactMap(restore)
        return RestoredMainReading(location: location, history: history, overviewOrigins: origins)
    }

    static func restoreMain(_ candidates: RestoreCandidates?, content: ReaderContent,
                            state: inout ReaderNavigationState) -> MainReadingRestoration? {
        guard let candidates, candidates.identity == content.study.identity else { return nil }
        var rejected = false
        for supplied in candidates.records where supplied.checkpoint.slotKey == ReadingCheckpoint.mainSlotKey {
            let candidate = supplied.checkpoint
            guard let restored = validMain(candidate, content: content, isLocalDevice: supplied.isLocalDevice) else {
                rejected = true
                continue
            }
            state.history = restored.history
            state.overviewOrigins.merge(restored.overviewOrigins, uniquingKeysWith: { _, incoming in incoming })
            state.activate(restored.location, cause: .restoration)
            return rejected ? .restoredAlternative : .restored
        }
        return rejected ? .unavailable : nil
    }

    static func restoreOtherSlots(_ candidates: RestoreCandidates?, content: ReaderContent,
                                  state: inout ReaderNavigationState, details: inout ReadingDetails,
                                  pdf: inout PDFReadingRules) {
        guard let candidates, candidates.identity == content.study.identity else { return }
        for mode in [ReadingMode.diagram, .report] {
            for supplied in candidates.records where supplied.checkpoint.slotKey == "mode:" + mode.rawValue {
                let candidate = supplied.checkpoint
                guard let restored = validMain(candidate, content: content, isLocalDevice: supplied.isLocalDevice),
                      restored.location.address.mode == mode else { continue }
                state.modeLocations[mode] = restored.location
                if let origin = restored.overviewOrigins[restored.location.visitID] {
                    state.overviewOrigins[restored.location.visitID] = origin
                }
                break
            }
        }
        var accepted = Set<String>()
        for supplied in candidates.records where supplied.checkpoint.slotKey.hasPrefix("detail:") {
            let candidate = supplied.checkpoint
            guard !accepted.contains(candidate.slotKey), candidate.occurredAt.timeIntervalSinceReferenceDate.isFinite,
                  let record = try? JSONDecoder().decode(DetailReadingRecord.self, from: candidate.payload),
                  record.schemaVersion == 1, candidate.slotKey == "detail:" + record.detail.address.storageKey,
                  let valid = content.validDetailPosition(record.detail) else { continue }
            details.remembered[valid.address] = supplied.isLocalDevice ? valid.position : ReadingPosition(anchorID: valid.position.anchorID)
            accepted.insert(candidate.slotKey)
        }
        for supplied in candidates.records where supplied.checkpoint.slotKey.hasPrefix("pdf:") {
            let candidate = supplied.checkpoint
            guard !accepted.contains(candidate.slotKey), candidate.occurredAt.timeIntervalSinceReferenceDate.isFinite,
                  let record = try? JSONDecoder().decode(PDFReadingRecord.self, from: candidate.payload),
                  record.schemaVersion == 1, candidate.slotKey == "pdf:" + record.sourceID,
                  content.study.research.research.sources.contains(where: {
                      $0.id == record.sourceID && (1...$0.pdfPages).contains(record.physicalPage)
                  }) else { continue }
            pdf.resumePages[record.sourceID] = record.physicalPage
            accepted.insert(candidate.slotKey)
        }
    }
}

// Library receives presentation metadata through Reading's own restoration validator.
extension StudyReader {
    static func continuationMode(in study: ReadableStudy, identity: StudyIdentity,
                                 checkpoint: ReadingSlotCheckpoint, isLocalDevice: Bool) -> ReadingMode? {
        guard identity == study.identity, checkpoint.slotKey == ReadingCheckpoint.mainSlotKey,
              let restored = ReaderRecords.validMain(checkpoint, content: ReaderContent(study: study),
                  isLocalDevice: isLocalDevice) else { return nil }
        return normalizedMode(restored.location.address.mode, in: study)
    }

    static func continuationTitle(in study: ReadableStudy, identity: StudyIdentity,
                                  checkpoint: ReadingSlotCheckpoint, isLocalDevice: Bool) -> String? {
        let content = ReaderContent(study: study)
        guard identity == study.identity, checkpoint.slotKey == ReadingCheckpoint.mainSlotKey,
              let restored = ReaderRecords.validMain(checkpoint, content: content,
                  isLocalDevice: isLocalDevice) else { return nil }
        let location = normalizedMode(restored.location.address.mode, in: study) == restored.location.address.mode
            ? restored.location : ReaderLocation(.report)
        return content.title(for: location)
    }

    static func normalizedMode(_ mode: ReadingMode, in study: ReadableStudy) -> ReadingMode {
        availableModes(in: study).contains(mode) ? mode : .report
    }
}
