import SwiftUI
#if SWIFT_PACKAGE
import ResearchCore
#endif

/// Receives one already projected report and opaque Reader actions.
struct ReportReadingPage: View {
    let page: ReportPage
    let canGoBack: Bool
    let follow: (ReadingLink) -> Void
    let back: () -> Void
    let onPosition: (ObservationToken, ReadingPosition, PositionCause) -> Void
    var body: some View {
        VStack(spacing: 0) {
            ReaderScroll(observation: page.observation, restorePosition: page.restorePosition,
                         arrivalCause: page.arrivalCause, onPosition: { token, position, cause in
                onPosition(token, position, cause)
            }) {
                ReportReadingBody(page: page, follow: { follow($0) })
            }
            HStack {
                Button { back() } label: { Label("回到刚才", systemImage: "arrow.left") }
                    .disabled(!canGoBack).accessibilityIdentifier("study-back")
                Spacer()
                Text("完整报告").font(.caption).foregroundStyle(StudyInk.muted)
            }
            .buttonStyle(.plain).frame(minHeight: 48).padding(.horizontal, 24).background(StudyInk.paper)
        }
    }
}

struct ReportReadingToolbar: ToolbarContent {
    let page: ReportPage
    let follow: (ReadingLink) -> Void
    var body: some ToolbarContent {
        ToolbarItem(placement: .primaryAction) {
            Menu {
                ForEach(page.contents) { item in
                    Button(item.title) { follow(item.link) }
                }
            } label: {
                Label("目录", systemImage: "list.bullet").frame(minHeight: 44)
            }
            .accessibilityLabel("完整报告目录").accessibilityIdentifier("report-contents")
        }
    }
}
