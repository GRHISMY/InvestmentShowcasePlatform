import SwiftUI
#if SWIFT_PACKAGE
import ResearchCore
#endif
#if os(macOS)
import AppKit
#endif

// Resolve the property-wrapper type explicitly when an SDK also exports a State macro.
typealias ReadingState<Value> = SwiftUI.State<Value>

/// The bundle is only a composition-root input. Reading and PDF hosts receive
/// an already validated, fixed publication instead of discovering another root.
enum BundledStudy {
    static var root: URL {
        #if SWIFT_PACKAGE
        return Bundle.module.resourceURL!.appendingPathComponent("Study", isDirectory: true)
        #else
        return Bundle.main.resourceURL!.appendingPathComponent("Study", isDirectory: true)
        #endif
    }
    static func load() throws -> ReadableStudy { try ReadableStudy(root: root) }
}

@main @MainActor struct CompanyLensApp: App {
    @ReadingState private var workspace = StudyWorkspace()
    init() {
        #if os(macOS)
        NSApplication.shared.setActivationPolicy(.regular)
        #endif
    }
    var body: some Scene {
        #if os(macOS)
        Window("看懂公司", id: "main") { StudyWorkspaceView(workspace: workspace) }
            .defaultSize(width: 440, height: 890)
        #else
        WindowGroup { StudyWorkspaceView(workspace: workspace) }
        #endif
    }
}
