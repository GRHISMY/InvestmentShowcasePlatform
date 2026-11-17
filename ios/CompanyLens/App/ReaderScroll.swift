import SwiftUI
#if SWIFT_PACKAGE
import ResearchCore
#endif

/// Native geometry stays here. The token and cause are observations, not a
/// second decision about which reading record should win.
private struct ReadingObservationGenerationKey: EnvironmentKey {
    static let defaultValue: UUID? = nil
}
private struct RestoredReadingObservationKey: EnvironmentKey {
    static let defaultValue: Set<ObservationToken> = []
}
extension EnvironmentValues {
    var readingObservationGeneration: UUID? {
        get { self[ReadingObservationGenerationKey.self] }
        set { self[ReadingObservationGenerationKey.self] = newValue }
    }
    var restoredReadingObservations: Set<ObservationToken> {
        get { self[RestoredReadingObservationKey.self] }
        set { self[RestoredReadingObservationKey.self] = newValue }
    }
}
private struct ReadingRenderID: Hashable {
    let observation: ObservationToken
    let generation: UUID?
}

struct ReaderScroll<Content: View>: View {
    @Environment(\.readingObservationGeneration) private var generation
    @Environment(\.restoredReadingObservations) private var restoredObservations
    let observation: ObservationToken
    let restorePosition: ReadingPosition?
    let arrivalCause: PositionCause
    let onPosition: (ObservationToken, ReadingPosition, PositionCause) -> Void
    @ViewBuilder let content: Content
    var body: some View {
        let renderID = AnyHashable(ReadingRenderID(observation: observation, generation: generation))
        return ReadingScrollView(renderID: renderID,
                          target: restorePosition.map {
                              ReadingScrollPosition(anchorID: $0.anchorID, localOffset: CGFloat($0.localOffset ?? 0))
                          }, onObservation: { event in
            guard event.renderID == renderID else { return }
            let cause: PositionCause
            switch event.cause {
            case .arrival: cause = restoredObservations.contains(observation) ? .restoration : arrivalCause
            case .userBrowsing: cause = .userBrowsing
            }
            onPosition(observation, ReadingPosition(anchorID: event.position.anchorID,
                       localOffset: Double(event.position.localOffset)), cause)
        }) {
            VStack(alignment: .leading, spacing: 22) { content }
                .padding(24).frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

