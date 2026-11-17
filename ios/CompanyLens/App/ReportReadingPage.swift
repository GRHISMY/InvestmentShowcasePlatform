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
        ReaderScroll(observation: page.observation, restorePosition: page.restorePosition,
                     arrivalCause: page.arrivalCause, onPosition: onPosition) {
            // Every authored block is laid out in the native document. Keeping
            // distant anchors available is required for arbitrary restoration;
            // a lazy stack in this fixed hosting document cannot provide that.
            ReportReadingBody(page: page, follow: follow)
        }
        .background(.background)
        .safeAreaInset(edge: .bottom, spacing: 0) {
            if canGoBack {
                HStack {
                    Button(action: back) { Label("回到刚才", systemImage: "arrow.backward") }
                        .accessibilityIdentifier("study-back")
                    Spacer()
                }
                .font(.subheadline.weight(.medium)).padding(.horizontal, 24).padding(.vertical, 12)
                .background(.bar)
            }
        }
    }
}

struct ReportReadingToolbar: ToolbarContent {
    let page: ReportPage
    let follow: (ReadingLink) -> Void
    var body: some ToolbarContent {
        ToolbarItem(placement: .primaryAction) {
            ReportContentsButton(page: page, follow: follow)
        }
    }
}

private struct ReportContentsButton: View {
    let page: ReportPage
    let follow: (ReadingLink) -> Void
    @State private var showingContents = false

    var body: some View {
        Button { showingContents = true } label: {
            Label("目录", systemImage: "list.bullet").frame(minHeight: 44)
        }
        .accessibilityLabel("完整报告目录").accessibilityIdentifier("report-contents")
        .sheet(isPresented: $showingContents) {
            ReportContentsList(page: page) { link in
                showingContents = false
                follow(link)
            }
        }
    }
}

private struct ReportContentsList: View {
    let page: ReportPage
    let follow: (ReadingLink) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var search = ""

    private var items: [ReportContentsItem] {
        search.isEmpty ? page.outline : page.outline.filter { $0.title.localizedStandardContains(search) }
    }

    var body: some View {
        NavigationStack {
            List(items) { item in
                Button { follow(item.link) } label: {
                    Text(item.title)
                        .font(item.isSubheading ? .body : .headline)
                        .foregroundStyle(.primary)
                        .padding(.leading, item.isSubheading ? 12 : 0)
                        .padding(.vertical, 4)
                        .frame(maxWidth: .infinity, minHeight: 36, alignment: .leading)
                }
                .accessibilityIdentifier("report-contents-" + item.id)
            }
            .accessibilityIdentifier("report-contents-list")
            #if canImport(UIKit)
            .searchable(text: $search, placement: .navigationBarDrawer(displayMode: .always), prompt: "搜索目录")
            #else
            .searchable(text: $search, prompt: "搜索目录")
            #endif
            .navigationTitle("完整报告目录")
            .inlineReadingTitle()
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("完成") { dismiss() }.accessibilityIdentifier("report-contents-close")
                }
            }
        }
        .presentationDetents([.large])
        .presentationDragIndicator(.visible)
    }
}
