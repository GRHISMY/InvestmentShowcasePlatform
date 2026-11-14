import Foundation

/// Persistence formats stay here; navigation and content never depend on their encoding.
enum ReaderBookmark {
    struct Memory: Codable {
        let identity: StudyIdentity
        let details: [DetailPosition]
        let pdf: [String: Int]
    }
    private struct MemoryEnvelope: Decodable { let readingMemory: Memory }
    private struct Current: Codable {
        let schemaVersion: Int
        let identity: StudyIdentity
        let current: ReaderLocation
        let history: [ReaderLocation]
        let overviewOrigin: ReaderLocation?
        let overviewPosition: ReadingPosition?
        let modeLocations: [ReadingMode: ReaderLocation]?
        let overviewOrigins: [SourceVisitID: ReaderLocation]?
    }
    private struct VersionTwo: Decodable {
        struct Scene: Decodable {
            let sceneID: String
            let focusID: String?
            let position: ReadingPosition?
            var location: ReaderLocation { ReaderLocation(.diagram(sceneID: sceneID, focusID: focusID), position: position) }
        }
        let schemaVersion: Int
        let identity: StudyIdentity
        let isOverview: Bool
        let current: Scene
        let history: [Scene]
        let overviewOrigin: Scene?
        let overviewPosition: ReadingPosition?
    }
    private struct VersionOne: Decodable {
        struct Visit: Decodable { let id: String; let focus: String? }
        let schemaVersion: Int
        let momentIDs: [String]
        let currentID: String
        let focus: String?
        let history: [Visit]
        let isOverview: Bool
    }

    static func encode(_ state: ReaderNavigationState, identity: StudyIdentity,
                       detailPositions: [DetailPosition] = [], pdfResumePages: [String: Int] = [:]) -> Data? {
        let saved = Current(schemaVersion: 3, identity: identity, current: state.current.location,
            history: state.history, overviewOrigin: state.overviewOrigin, overviewPosition: state.overviewPosition,
            modeLocations: state.modeLocations, overviewOrigins: state.overviewOrigins)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        guard let data = try? encoder.encode(saved),
              var object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let memory = try? encoder.encode(Memory(identity: identity, details: detailPositions, pdf: pdfResumePages)),
              let memoryObject = try? JSONSerialization.jsonObject(with: memory) else { return nil }
        object["readingMemory"] = memoryObject
        return try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
    }

    static func memory(_ data: Data?, content: ReaderContent) -> Memory {
        let empty = Memory(identity: content.study.identity, details: [], pdf: [:])
        guard let data, let envelope = try? JSONDecoder().decode(MemoryEnvelope.self, from: data),
              envelope.readingMemory.identity == content.study.identity else { return empty }
        let pdf = envelope.readingMemory.pdf.filter { sourceID, page in
            content.study.research.research.sources.contains { $0.id == sourceID && (1...$0.pdfPages).contains(page) }
        }
        return Memory(identity: content.study.identity,
            details: envelope.readingMemory.details.compactMap(content.validDetailPosition), pdf: pdf)
    }

    static func restore(_ data: Data?, content: ReaderContent) -> (ReaderNavigationState, String?) {
        let fresh = ReaderNavigationState()
        guard let data else { return (fresh, nil) }
        let decoder = JSONDecoder()
        if let saved = try? decoder.decode(Current.self, from: data), saved.schemaVersion == 3,
           saved.identity == content.study.identity, let current = content.sanitized(saved.current) {
            var state = fresh
            state.activate(current, cause: .restoration)
            state.history = saved.history.compactMap(content.sanitized)
            state.overviewOrigins = (saved.overviewOrigins ?? [:]).compactMapValues(content.sanitized)
            if state.overviewOrigin == nil { state.overviewOrigin = saved.overviewOrigin.flatMap(content.sanitized) }
            state.overviewPosition = content.validPosition(saved.overviewPosition, address: .overview)
            state.modeLocations = (saved.modeLocations ?? [:]).compactMapValues(content.sanitized)
                .filter { $0.key == $0.value.address.mode }
            state.modeLocations[current.address.mode] = current
            let changed = current != saved.current || state.history != saved.history ||
                state.overviewOrigin != saved.overviewOrigin || state.overviewPosition != saved.overviewPosition
            return (state, changed ? "上次位置有一部分已失效，已恢复可用内容。" : nil)
        }
        if let saved = try? decoder.decode(VersionTwo.self, from: data), saved.schemaVersion == 2,
           saved.identity == content.study.identity, let current = content.sanitized(saved.current.location) {
            var state = fresh
            state.history = saved.history.compactMap { content.sanitized($0.location) }
            state.overviewPosition = content.validPosition(saved.overviewPosition, address: .overview)
            state.activate(saved.isOverview ? ReaderLocation(.overview, position: state.overviewPosition) : current,
                           cause: .restoration)
            state.overviewOrigin = saved.overviewOrigin.flatMap { content.sanitized($0.location) }
            let changed = current.address != saved.current.location.address || current.position != saved.current.position ||
                state.history.count != saved.history.count
            return (state, changed ? "上次位置有一部分已失效，已恢复可用内容。" : nil)
        }
        if let old = try? decoder.decode(VersionOne.self, from: data), old.schemaVersion == 1,
           let reading = content.study.reading, old.momentIDs == reading.document.sceneOrder,
           let current = content.sanitized(ReaderLocation(.diagram(sceneID: old.currentID, focusID: old.focus))) {
            var state = fresh
            state.history = old.history.compactMap {
                content.sanitized(ReaderLocation(.diagram(sceneID: $0.id, focusID: $0.focus)))
            }
            state.activate(old.isOverview ? ReaderLocation(.overview) : current, cause: .restoration)
            if old.isOverview { state.overviewOrigin = current }
            return (state, nil)
        }
        return (fresh, "上次位置已无法使用，已回到这份研究全貌。")
    }
}
