import SwiftUI
import Observation
#if SWIFT_PACKAGE
import ResearchCore
#endif

enum WorkspaceTab: String, CaseIterable {
    case library, diagram, report
}

private enum WorkspaceSurface {
    case library
    case reading
    case placeholder(ReadingMode)
}

/// Window-local geometry follows the retained reading, never its cloud record.
@MainActor @Observable
final class ReadingPresentationState {
    let readingID: UUID
    var diagramViewports: [SourceVisitID: DiagramViewport] = [:]
    init(readingID: UUID) { self.readingID = readingID }
}

/// Composition and window lifetime. The shelf creates readers; an active reader stays fixed.
@MainActor @Observable
final class StudyWorkspace {
    let shelf: StudyShelf
    private(set) var activeReading: ShelfReading?
    private var surface: WorkspaceSurface = .library
    var isReadingVisible: Bool { if case .reading = surface { return true }; return false }
    var selectedTab: WorkspaceTab {
        switch surface {
        case .library: return .library
        case .placeholder(let mode): return mode == .report ? .report : .diagram
        case .reading: return activeReading?.reader.currentMode == .report ? .report : .diagram
        }
    }
    private(set) var presentationState: ReadingPresentationState?
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

    /// A tab expresses an intent; accepted Reader state supplies the selection.
    func showReading(mode: ReadingMode? = nil) {
        guard activeReading?.reader.blocksMainNavigation != true else { return }
        _ = beginNavigation()
        guard var reading = activeReading else {
            hideReading(on: .placeholder(mode ?? .diagram))
            return
        }
        if let mode, !reading.reader.availableModes.contains(mode) {
            hideReading(on: .placeholder(mode))
            return
        }
        let previousTab = selectedTab
        let wasVisible = isReadingVisible
        if let mode { reading.reader.switchMode(mode) }
        activeReading = reading
        surface = .reading
        guard !wasVisible || selectedTab != previousTab else { return }
        restoredObservations = wasVisible ? [] : reading.reader.visibleObservations
        restoredPDFObservation = wasVisible ? nil : reading.reader.visiblePDFObservation
        observationGeneration = isSceneActive ? UUID() : nil
    }

    func selectTab(_ tab: WorkspaceTab) {
        switch tab {
        case .library: returnToLibrary()
        case .diagram: showReading(mode: .diagram)
        case .report: showReading(mode: .report)
        }
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
        guard activeReading?.reader.blocksMainNavigation != true else { return }
        _ = beginNavigation()
        hideReading(on: .library)
    }

    private func hideReading(on surface: WorkspaceSurface) {
        observationGeneration = nil
        restoredObservations = []
        restoredPDFObservation = nil
        self.surface = surface
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
            presentationState = ReadingPresentationState(readingID: reading.id)
            activeVersion = version
            observationGeneration = isSceneActive ? UUID() : nil
            restoredObservations = []
            restoredPDFObservation = nil
            surface = .reading
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
            let previousMode = self.activeReading?.reader.currentMode
            self.activeReading?.reader = value
            // A cross-mode association/back moves the single host into another tab.
            // Its outgoing native callbacks must not inherit the new visible period.
            if previousMode != value.currentMode {
                self.observationGeneration = UUID()
                self.restoredObservations = []
                self.restoredPDFObservation = nil
            }
            if let checkpoint = value.checkpoint { self.shelf.acceptCheckpoint(checkpoint) }
        })
    }
}

struct StudyWorkspaceView: View {
    @Bindable var workspace: StudyWorkspace
    @Environment(\.scenePhase) private var scenePhase
    var body: some View {
        TabView(selection: Binding(get: { workspace.selectedTab }, set: { workspace.selectTab($0) })) {
            NavigationStack { StudyLibraryView(workspace: workspace).navigationTitle("研究库") }
                .tabItem {
                    Image(systemName: "books.vertical").accessibilityIdentifier("workspace-tab-library")
                    Text("研究库")
                }
                .tag(WorkspaceTab.library)
            readingEntry(.diagram)
                .tabItem {
                    Image(systemName: "point.3.connected.trianglepath.dotted").accessibilityIdentifier("workspace-tab-diagram")
                    Text("图解")
                }
                .tag(WorkspaceTab.diagram)
            readingEntry(.report)
                .tabItem {
                    Image(systemName: "doc.text").accessibilityIdentifier("workspace-tab-report")
                    Text("报告")
                }
                .tag(WorkspaceTab.report)
        }
        .tint(.accentColor)
        .background(NativeTabNavigationGuard(isBlocked: workspace.activeReading?.reader.blocksMainNavigation == true,
            itemIdentifiers: WorkspaceTab.allCases.map { "workspace-tab-" + $0.rawValue }))
        .task { await workspace.start() }
        .onAppear { workspace.setSceneActive(scenePhase == .active) }
        .onChange(of: scenePhase) { _, phase in
            workspace.setSceneActive(phase == .active)
            if phase == .active { Task { await workspace.refresh() } }
            else { Task { await workspace.shelf.retryRecords() } }
        }
    }

    @ViewBuilder private func readingEntry(_ tab: WorkspaceTab) -> some View {
        NavigationStack {
            if workspace.selectedTab == tab {
                if workspace.isReadingVisible, let reading = workspace.activeReading,
                   let retainedPresentation = workspace.presentationState {
                    @Bindable var presentation = retainedPresentation
                    StudyReaderHost(study: reading.study, reader: workspace.binding(for: reading),
                        diagramViewports: $presentation.diagramViewports,
                        onLibrary: { workspace.returnToLibrary() }).id(reading.id)
                        .environment(\.readingObservationGeneration, workspace.observationGeneration)
                        .environment(\.restoredReadingObservations, workspace.restoredObservations)
                        .environment(\.restoredPDFReadingObservation, workspace.restoredPDFObservation)
                        .environment(\.readingObservationEnabled, workspace.isSceneActive)
                        .safeAreaInset(edge: .bottom, spacing: 0) {
                            ReadingRecordNotice(state: workspace.shelf.recordState,
                                onRetry: { Task { await workspace.shelf.retryRecords() } })
                        }
                } else { readingPlaceholder }
            } else { Color.clear }
        }
    }

    private var readingPlaceholder: some View {
        VStack(spacing: 20) {
            if let reading = workspace.activeReading {
                ContentUnavailableView("这份研究没有图解", systemImage: "doc.text",
                    description: Text("可以阅读这份研究的完整报告。"))
                    .accessibilityIdentifier("workspace-no-diagram")
                Button("阅读完整报告") { workspace.showReading(mode: .report) }.buttonStyle(.borderedProminent)
                Text(reading.study.research.research.company.name)
                    .accessibilityIdentifier("workspace-company-title")
            } else {
                ContentUnavailableView("请先选择公司", systemImage: "books.vertical",
                    description: Text("在研究库中选择公司后，图解和报告将显示同一份研究。"))
                    .accessibilityIdentifier("workspace-empty-study")
            }
            Button("选择公司") { workspace.returnToLibrary() }.buttonStyle(.bordered)
        }
        .navigationTitle(workspace.activeReading?.study.research.research.company.name ?? "选择公司")
        .inlineReadingTitle()
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
