import SwiftUI
#if SWIFT_PACKAGE
import ResearchCore
#endif

/// An immutable piece of the projected report and the semantic positions it owns.
/// Bodies remain deferred until the native document needs to lay them out.
struct ReportDocumentBlock: Identifiable {
    let id: String
    let anchors: [String]
    let content: () -> AnyView
}

struct ReportDocumentView: View {
    @Environment(\.readingObservationGeneration) private var generation
    @Environment(\.restoredReadingObservations) private var restoredObservations
    @Environment(\.readingObservationEnabled) private var observationEnabled
    let page: ReportPage
    let follow: (ReadingLink) -> Void
    let onPosition: (ObservationToken, ReadingPosition, PositionCause) -> Void

    private struct RenderID: Hashable {
        let observation: ObservationToken
        let generation: UUID?
    }

    var body: some View {
        let renderID = AnyHashable(RenderID(observation: page.observation, generation: generation))
        if observationEnabled {
            NativeReportDocument(renderID: renderID, target: page.restorePosition.map {
                ReadingScrollPosition(anchorID: $0.anchorID, localOffset: CGFloat($0.localOffset ?? 0))
            }, blocks: ReportReadingBody(page: page, follow: follow).blocks) { event in
                guard event.renderID == renderID else { return }
                let cause: PositionCause
                switch event.cause {
                case .arrival: cause = restoredObservations.contains(page.observation) ? .restoration : page.arrivalCause
                case .userBrowsing: cause = .userBrowsing
                }
                onPosition(page.observation, ReadingPosition(anchorID: event.position.anchorID,
                           localOffset: Double(event.position.localOffset)), cause)
            }
        } else { Color.clear.frame(maxWidth: .infinity, maxHeight: .infinity) }
    }
}

#if canImport(UIKit)
// The first adapter deliberately retains the existing eager document. The
// regression at this boundary establishes native work before virtualizing it.
typealias ReportDocumentController = ReadingScrollController
extension ReportDocumentController {
    func render(renderID: AnyHashable, target: ReadingScrollPosition?, blocks: [ReportDocumentBlock],
                environment: EnvironmentValues? = nil,
                onObservation: @escaping (ReadingScrollObservation) -> Void) {
        render(renderID: renderID, target: target, content: AnyView(
            VStack(alignment: .leading, spacing: 0) {
                ForEach(blocks) { block in block.content() }
            }
            .font(.body).foregroundStyle(.primary)
            .frame(maxWidth: 620, alignment: .leading)
            .frame(maxWidth: .infinity, alignment: .center)
            .textSelection(.enabled).padding(24)
        ), environment: environment, onObservation: onObservation)
    }
}

private struct NativeReportDocument: UIViewControllerRepresentable {
    let renderID: AnyHashable
    let target: ReadingScrollPosition?
    let blocks: [ReportDocumentBlock]
    let onObservation: (ReadingScrollObservation) -> Void
    func makeUIViewController(context: Context) -> ReportDocumentController { ReportDocumentController() }
    func updateUIViewController(_ controller: ReportDocumentController, context: Context) {
        controller.render(renderID: renderID, target: target, blocks: blocks,
                          environment: context.environment, onObservation: onObservation)
    }
    static func dismantleUIViewController(_ controller: ReportDocumentController, coordinator: ()) {
        controller.stopObserving()
    }
}
#else
private struct NativeReportDocument: View {
    let renderID: AnyHashable
    let target: ReadingScrollPosition?
    let blocks: [ReportDocumentBlock]
    let onObservation: (ReadingScrollObservation) -> Void
    var body: some View {
        ReadingScrollView(renderID: renderID, target: target, onObservation: onObservation) {
            VStack(alignment: .leading, spacing: 0) { ForEach(blocks) { $0.content() } }
                .font(.body).foregroundStyle(.primary)
                .frame(maxWidth: 620, alignment: .leading)
                .frame(maxWidth: .infinity, alignment: .center)
                .textSelection(.enabled).padding(24)
        }
    }
}
#endif
