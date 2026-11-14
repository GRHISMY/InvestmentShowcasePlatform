import SwiftUI

/// Smaller windows keep the same research focus. Its full explanation gets
/// a separate reading surface instead of overflowing the fixed diagram scene.
struct StudyExplanationSheet: View {
    let title: String
    let text: String
    let caveat: String
    @Environment(\.dismiss) private var dismiss
    var body: some View {
        VStack(alignment: .leading, spacing: 24) {
            HStack {
                Text("这张图说明什么").font(.caption).tracking(2)
                Spacer()
                Button { dismiss() } label: { Image(systemName: "xmark").frame(width: 44, height: 44) }
                    .accessibilityLabel("回到图中")
            }
            Text(title).font(.system(size: 25, design: .serif))
            Text(text).font(.system(size: 18)).lineSpacing(8)
            Divider()
            Text("还不能说到哪一步").font(.caption.weight(.semibold))
            Text(caveat).font(.system(size: 15)).lineSpacing(7).foregroundStyle(.secondary)
            Spacer(minLength: 0)
            Button("回到图中") { dismiss() }.font(.headline).frame(maxWidth: .infinity, minHeight: 50)
        }.padding(28).background(Color(red: 0.965, green: 0.959, blue: 0.936)).tint(.black)
        #if os(macOS)
        .frame(width: 430, height: 650)
        #else
        .presentationDetents([.large])
        #endif
    }
}
