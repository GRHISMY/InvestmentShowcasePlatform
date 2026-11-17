import SwiftUI
import Observation
#if SWIFT_PACKAGE
import ResearchCore
#endif

/// Composition and window lifetime. The shelf creates readers; an active reader stays fixed.
@MainActor @Observable
final class StudyWorkspace {
    let shelf: StudyShelf
    private(set) var activeReading: ShelfReading?
    private(set) var isReadingVisible = false
    private(set) var observationGeneration: UUID?
    private(set) var restoredObservations: Set<ObservationToken> = []
    private(set) var restoredPDFObservation: PDFObservationToken?
    private(set) var isSceneActive = true
    private var activeVersion: ShelfVersionID?
    private var navigationIntent = UUID()
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

    init(shelf: StudyShelf, defaults: UserDefaults) {
        self.shelf = shelf
        self.defaults = defaults
    }

    func start() async {
        guard !started else { return }
        started = true
        let startupIntent = navigationIntent
        await shelf.refresh()
        let startupChoice = shelf.recommendedContinuation
        if let bookmark = defaults.data(forKey: Self.folderKey) {
            if let replacement = await shelf.connect(bookmark: bookmark) { defaults.set(replacement, forKey: Self.folderKey) }
        }
        // Association invalidates prior opening intents. Schedule restoration after
        // access is resolved, and let any explicit reader action take precedence.
        if navigationIntent == startupIntent, openTask == nil, let startupChoice { continueReading(startupChoice) }
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
        if activeVersion == version { showReading(); return }
        let intent = beginNavigation()
        openTask = Task {
            let result = await shelf.readVersion(version)
            guard navigationIntent == intent, !Task.isCancelled else { return }
            finishOpening(result, version: version)
            openTask = nil
        }
    }

    func continueReading(_ choice: ShelfContinuationChoice? = nil) {
        if activeReading != nil, choice == nil {
            showReading()
            return
        }
        let selected = choice ?? shelf.recommendedContinuation
        let intent = beginNavigation()
        openTask = Task {
            let result = await shelf.continueReading(selected)
            guard navigationIntent == intent, !Task.isCancelled else { return }
            finishOpening(result, version: selected?.versionID)
            openTask = nil
        }
    }

    /// Visibility belongs to the workspace; the retained Reader still owns all reading state.
    func showReading(mode: ReadingMode? = nil) {
        guard var reading = activeReading else { return }
        _ = beginNavigation()
        if let mode { reading.reader.switchMode(mode); activeReading = reading }
        guard !isReadingVisible else { return }
        restoredObservations = reading.reader.visibleObservations
        restoredPDFObservation = reading.reader.visiblePDFObservation
        observationGeneration = isSceneActive ? UUID() : nil
        isReadingVisible = true
    }

    func setSceneActive(_ active: Bool) {
        guard active != isSceneActive else { return }
        isSceneActive = active
        observationGeneration = nil
        guard active, isReadingVisible, let reading = activeReading else { return }
        restoredObservations = reading.reader.visibleObservations
        restoredPDFObservation = reading.reader.visiblePDFObservation
        observationGeneration = UUID()
    }

    func returnToLibrary() {
        guard activeReading?.reader.presentationPath.isEmpty != false,
              activeReading?.reader.fullscreenDiagram == nil else { return }
        _ = beginNavigation()
        observationGeneration = nil
        restoredObservations = []
        restoredPDFObservation = nil
        isReadingVisible = false
        if let checkpoint = activeReading?.reader.checkpoint { shelf.acceptCheckpoint(checkpoint) }
    }

    private func beginNavigation() -> UUID {
        openTask?.cancel()
        openTask = nil
        navigationIntent = UUID()
        return navigationIntent
    }

    private func finishOpening(_ result: ShelfOpenResult, version: ShelfVersionID?) {
        switch result {
        case .opened(let reading):
            activeReading = reading
            activeVersion = version
            observationGeneration = isSceneActive ? UUID() : nil
            restoredObservations = []
            restoredPDFObservation = nil
            isReadingVisible = true
            notice = nil
        case .unavailable(let reason): notice = reason
        case .superseded: break
        }
    }

    func binding(for reading: ShelfReading) -> Binding<StudyReader> {
        let generation = observationGeneration
        return Binding(get: {
            guard let active = self.activeReading, active.id == reading.id else { return reading.reader }
            return active.reader
        }, set: { value in
            guard self.activeReading?.id == reading.id, self.isReadingVisible,
                  self.isSceneActive, generation != nil, self.observationGeneration == generation else { return }
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
            if let reading = workspace.activeReading, workspace.isReadingVisible {
                StudyReaderHost(study: reading.study, reader: workspace.binding(for: reading),
                                onLibrary: { workspace.returnToLibrary() }).id(reading.id)
                    .environment(\.readingObservationGeneration, workspace.observationGeneration)
                    .environment(\.restoredReadingObservations, workspace.restoredObservations)
                    .environment(\.restoredPDFReadingObservation, workspace.restoredPDFObservation)
                    .environment(\.readingObservationEnabled, workspace.isSceneActive)
                    .safeAreaInset(edge: .bottom, spacing: 0) {
                        ReadingRecordNotice(state: workspace.shelf.recordState,
                            onRetry: { Task { await workspace.shelf.retryRecords() } })
                    }
            } else { StudyLibraryView(workspace: workspace) }
        }
        .task { await workspace.start() }
        .onAppear { workspace.setSceneActive(scenePhase == .active) }
        .onChange(of: scenePhase) { _, phase in
            workspace.setSceneActive(phase == .active)
            if phase == .active { Task { await workspace.refresh() } }
            else { Task { await workspace.shelf.retryRecords() } }
        }
    }
}

private extension StudyReader {
    var visibleObservations: Set<ObservationToken> {
        var observations: Set<ObservationToken> = []
        switch primaryPage {
        case .overview(let page): observations.insert(page.observation)
        case .diagram(let page): observations.insert(page.observation)
        case .report(let page): observations.insert(page.observation)
        case .detail: break
        }
        for presentation in presentationPath {
            switch presentation.page {
            case .explanation(let page): observations.insert(page.observation)
            case .calculations(let page): observations.insert(page.observation)
            case .evidence(let page): observations.insert(page.observation)
            case .pdf: break
            }
        }
        return observations
    }
    var visiblePDFObservation: PDFObservationToken? {
        for presentation in presentationPath {
            if case .pdf(let page) = presentation.page { return page.request.observation }
        }
        return nil
    }
}
