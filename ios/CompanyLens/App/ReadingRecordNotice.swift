import SwiftUI
#if SWIFT_PACKAGE
import ResearchCore
#endif

/// Reading keeps its place while the shelf reports a recoverable record failure.
struct ReadingRecordNotice: View {
    let state: ShelfRecordState
    let onRetry: () -> Void

    var body: some View {
        if case .unsaved(let reason) = state.local {
            failure("阅读位置尚未成功保存在本机。", reason: reason, retry: "重试保存阅读位置")
        } else if case .failed(let reason) = state.cloud {
            failure(state.local == .saved ? "阅读位置已保存在本机，同步尚未完成。" : "阅读记录同步尚未完成。",
                    reason: reason, retry: "重试同步阅读位置")
        }
    }

    private func failure(_ title: String, reason: String, retry: String) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Label(title, systemImage: "exclamationmark.circle").font(.subheadline)
                .fixedSize(horizontal: false, vertical: true)
            Text(reason).font(.caption).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            Button(retry, action: onRetry).font(.subheadline).buttonStyle(.plain)
                .frame(minWidth: 44, minHeight: 44, alignment: .leading)
        }
        .padding(12).frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.primary.opacity(0.05))
        .accessibilityElement(children: .contain)
    }
}
