import Foundation

/// Persistence formats stay here; navigation and content never depend on their encoding.
enum ReaderBookmark {
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

    static func encode(_ state: ReaderNavigationState, identity: StudyIdentity) -> Data? {
        let saved = Current(schemaVersion: 3, identity: identity, current: state.current.location,
            history: state.history, overviewOrigin: state.overviewOrigin, overviewPosition: state.overviewPosition,
            modeLocations: state.modeLocations, overviewOrigins: state.overviewOrigins)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return try? encoder.encode(saved)
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
