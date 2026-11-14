import SwiftUI
import Observation
#if SWIFT_PACKAGE
import ResearchCore
#endif

/// Composition and window lifetime. The shelf creates readers; an active reader stays fixed.
@MainActor @Observable
final class StudyWorkspace {
    let shelf: StudyShelf
    var activeReading: ShelfReading?
    var notice: String?
    private let defaults: UserDefaults
    private var started = false
    @ObservationIgnored private var openTask: Task<Void, Never>?
    private static let folderKey = "study-library-folder-bookmark"

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        let key = "study-reading-device-id"
        let deviceID = defaults.string(forKey: key) ?? UUID().uuidString
        defaults.set(deviceID, forKey: key)
        let sample = try? BundledStudy.load()
        var legacy: [StudyIdentity: Data] = [:]
        if let sample {
            let identity = sample.identity
            let oldKey = "reading-package-v1." + identity.snapshotID + "." + (identity.readingID ?? "report")
                + ".r" + String(identity.readingRevision ?? 0)
            if let data = defaults.data(forKey: oldKey) { legacy[identity] = data }
        }
        shelf = StudyShelf(localRoot: URL.applicationSupportDirectory.appendingPathComponent("CompanyLens/Library"),
            deviceID: deviceID, cloud: AppleCloudFolder(ownDeviceID: deviceID), bundledStudy: sample, legacyBookmarks: legacy)
        if sample == nil { notice = "随附研究暂时没有打开，可以关联研究目录后重试。" }
    }

    func start() async {
        guard !started else { return }
        started = true
        await shelf.refresh()
        let startupChoice = shelf.recommendedContinuation
        if let bookmark = defaults.data(forKey: Self.folderKey) {
            if let replacement = await shelf.connect(bookmark: bookmark) { defaults.set(replacement, forKey: Self.folderKey) }
        }
        // Association invalidates prior opening intents. Schedule restoration after
        // access is resolved, and let any explicit reader action take precedence.
        if openTask == nil, let startupChoice { continueReading(startupChoice) }
        await shelf.refresh()
    }

    func refresh() async {
        switch shelf.connectionState {
        case .checking: return
        case .disconnected, .unavailable:
            if let bookmark = defaults.data(forKey: Self.folderKey),
               let replacement = await shelf.connect(bookmark: bookmark) {
                defaults.set(replacement, forKey: Self.folderKey)
            }
        case .connected, .needsSelection: break
        }
        await shelf.refresh()
    }

    func connect(_ folder: URL) async {
        do {
            let bookmark = try AppleCloudFolder.bookmark(for: folder)
            if let confirmed = await shelf.connect(bookmark: bookmark) {
                defaults.set(confirmed, forKey: Self.folderKey)
                notice = nil
                await shelf.refresh()
            }
        } catch { notice = error.localizedDescription }
    }

    func open(_ version: ShelfVersionID) {
        openTask?.cancel()
        openTask = Task {
            switch await shelf.readVersion(version) {
            case .opened(let reading): activeReading = reading; notice = nil
            case .unavailable(let reason): notice = reason
            case .superseded: break
            }
        }
    }

    func continueReading(_ choice: ShelfContinuationChoice? = nil) {
        openTask?.cancel()
        openTask = Task {
            switch await shelf.continueReading(choice) {
            case .opened(let reading): activeReading = reading; notice = nil
            case .unavailable(let reason): notice = reason
            case .superseded: break
            }
        }
    }

    func returnToLibrary() {
        openTask?.cancel()
        if let checkpoint = activeReading?.reader.checkpoint { shelf.acceptCheckpoint(checkpoint) }
        activeReading = nil
    }

    func binding(for reading: ShelfReading) -> Binding<StudyReader> {
        Binding(get: {
            guard let active = self.activeReading, active.id == reading.id else { return reading.reader }
            return active.reader
        }, set: { value in
            guard self.activeReading?.id == reading.id else { return }
            self.activeReading?.reader = value
            if let checkpoint = value.checkpoint { self.shelf.acceptCheckpoint(checkpoint) }
        })
    }
}

struct StudyWorkspaceView: View {
    @Bindable var workspace: StudyWorkspace
    @Environment(\.scenePhase) private var scenePhase
    var body: some View {
        Group {
            if let reading = workspace.activeReading {
                StudyReaderHost(study: reading.study, reader: workspace.binding(for: reading),
                                onLibrary: { workspace.returnToLibrary() }).id(reading.id)
                    .safeAreaInset(edge: .bottom, spacing: 0) {
                        ReadingRecordNotice(state: workspace.shelf.recordState,
                            onRetry: { Task { await workspace.shelf.retryRecords() } })
                    }
            } else { StudyLibraryView(workspace: workspace) }
        }
        .task { await workspace.start() }
        .onChange(of: scenePhase) { _, phase in
            if phase == .active { Task { await workspace.refresh() } }
            else { Task { await workspace.shelf.retryRecords() } }
        }
    }
}
