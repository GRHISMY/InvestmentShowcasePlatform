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

private struct StudyPackageResourcesKey: EnvironmentKey {
    static let defaultValue: StudyPackageResources? = nil
}

extension EnvironmentValues {
    var studyPackageResources: StudyPackageResources? {
        get { self[StudyPackageResourcesKey.self] }
        set { self[StudyPackageResourcesKey.self] = newValue }
    }
}

@main struct CompanyLensApp: App {
    private let library: Result<ReadableStudy, Error>
    init() {
        library = Result { try BundledStudy.load() }
        #if os(macOS)
        NSApplication.shared.setActivationPolicy(.regular)
        #endif
    }
    var body: some Scene {
        WindowGroup {
            switch library {
            case .success(let book):
                Group {
                    StudyReaderHost(study: book)
                }
                .environment(\.studyPackageResources, book.resources)
            case .failure(let error):
                ContentUnavailableView("资料暂时没打开", systemImage: "doc.questionmark", description: Text(error.localizedDescription))
            }
        }
        #if os(macOS)
        .defaultSize(width: 440, height: 890)
        #endif
    }
}
