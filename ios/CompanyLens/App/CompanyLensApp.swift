import SwiftUI
#if SWIFT_PACKAGE
import ResearchCore
#endif
#if os(macOS)
import AppKit
#endif

// Resolve the property-wrapper type explicitly when an SDK also exports a State macro.
typealias ReadingState<Value> = SwiftUI.State<Value>

enum StudyResources {
    static var root: URL {
        #if SWIFT_PACKAGE
        return Bundle.module.resourceURL!.appendingPathComponent("Study", isDirectory: true)
        #else
        return Bundle.main.resourceURL!.appendingPathComponent("Study", isDirectory: true)
        #endif
    }
    static func load() throws -> ResearchLibrary {
        try ResearchLibrary(
            researchData: Data(contentsOf: root.appendingPathComponent("research.json"))
        )
    }
    static func loadPackage() throws -> LoadedStudy {
        let bytes = try Data(contentsOf: root.appendingPathComponent("research.json"))
        let research = try ResearchLibrary(researchData: bytes)
        let sidecar = root.appendingPathComponent("reading.json")
        let reading = FileManager.default.fileExists(atPath: sidecar.path)
            ? try ReadingLibrary(researchData: bytes, readingData: Data(contentsOf: sidecar)) : nil
        return LoadedStudy(research: research, reading: reading)
    }
}

struct LoadedStudy { let research: ResearchLibrary; let reading: ReadingLibrary? }

@MainActor final class ReaderSession: ObservableObject {
    @Published private(set) var state = ReaderState()
    func send(_ event: ReaderEvent) { state.send(event) }
    func openClaim(_ id: String) { send(.reset); send(.open(.claim(id))) }
}

@main struct CompanyLensApp: App {
    private let library: Result<LoadedStudy, Error>
    init() {
        library = Result { try StudyResources.loadPackage() }
        #if os(macOS)
        NSApplication.shared.setActivationPolicy(.regular)
        #endif
    }
    var body: some Scene {
        WindowGroup {
            switch library {
            case .success(let book):
                if let reading = book.reading { VisualStudyReader(reading: reading) }
                else { ReaderRoot(library: book.research) }
            case .failure:
                ContentUnavailableView("资料暂时没打开", systemImage: "doc.questionmark", description: Text("请重新打开应用。研究原件不会因此改变。"))
            }
        }
        #if os(macOS)
        .defaultSize(width: 440, height: 890)
        #endif
    }
}

enum ReadingTab: String, CaseIterable, Identifiable {
    case overview = "总览", dimensions = "问题索引", monitoring = "继续追踪"
    var id: String { rawValue }
    var symbol: String {
        switch self { case .overview: "house"; case .dimensions: "square.stack"; case .monitoring: "clock" }
    }
}

struct ReaderRoot: View {
    let library: ResearchLibrary
    @StateObject private var session = ReaderSession()
    @ReadingState private var tab: ReadingTab = .overview
    var body: some View {
        NavigationStack(path: Binding(
            get: { session.state.path },
            set: { session.send(.backToDepth($0.count)) }
        )) {
            VStack(spacing: 0) {
                Group {
                    switch tab {
                    case .overview: OverviewScreen(library: library, session: session)
                    case .dimensions: DimensionsScreen(library: library, session: session)
                    case .monitoring: MonitoringScreen(library: library, session: session)
                    }
                }
                Divider()
                HStack(spacing: 0) {
                    ForEach(ReadingTab.allCases) { item in
                        Button {
                            tab = item
                        } label: {
                            VStack(spacing: 5) {
                                Image(systemName: item.symbol).font(.system(size: 19))
                                Text(item.rawValue).font(.caption)
                            }
                            .foregroundStyle(tab == item ? ReadingTheme.accent : .secondary)
                            .frame(maxWidth: .infinity, minHeight: 54)
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .accessibilityAddTraits(tab == item ? [.isSelected] : [])
                    }
                }
                .background(ReadingTheme.paper)
            }
            .background(ReadingTheme.background)
            .navigationTitle("看懂公司")
            .inlineReadingTitle()
            .navigationDestination(for: ReaderRoute.self) { route in
                destination(route)
            }
        }
        .tint(ReadingTheme.accent)
        .preferredColorScheme(.light)
    }

    @ViewBuilder private func destination(_ route: ReaderRoute) -> some View {
        switch route {
        case .claim(let id):
            if let claim = library.claim(id) {
                ClaimScreen(claim: claim, library: library, session: session)
            }
        case .evidence(let id):
            if let claim = library.claim(id) {
                EvidenceScreen(claim: claim, library: library, session: session)
            }
        case .calculation(let id):
            if library.claim(id) != nil {
                CalculationScreen(claimID: id, library: library, session: session)
            }
        case .source(_, let evidenceID):
            if let page = library.page(evidenceID) {
                SourceScreen(page: page, session: session)
            }
        case .dimension(let id):
            if let dimension = library.dimension(id) {
                DimensionScreen(dimension: dimension, library: library, session: session)
            }
        }
    }
}

extension View {
    @ViewBuilder func inlineReadingTitle() -> some View {
        #if os(iOS)
        navigationBarTitleDisplayMode(.inline)
        #else
        self
        #endif
    }
}
