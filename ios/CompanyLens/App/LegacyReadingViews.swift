import SwiftUI
#if SWIFT_PACKAGE
import ResearchCore
#endif
#if canImport(UIKit)
import UIKit
#else
import AppKit
#endif

enum StudyInk {
    static let paper = Color(red: 0.965, green: 0.959, blue: 0.936)
    static let line = Color.black.opacity(0.18)
    static let muted = Color.black.opacity(0.58)
}

struct StudyEvidenceReader: View {
    let library: ResearchLibrary
    let ids: [String]
    let counterIDs: [String]
    let context: String
    @Environment(\.dismiss) private var dismiss
    @ReadingState private var index = 0
    @ReadingState private var chunkIndex = 0
    @ReadingState private var source: EvidencePage?
    private var evidence: ResearchEvidence? { ids.indices.contains(index) ? library.evidence(ids[index]) : nil }
    private var chunks: [String] {
        guard let evidence else { return ["这条依据暂时没有打开。"] }
        let characters = Array(evidence.excerpt)
        guard !characters.isEmpty else { return [""] }
        return stride(from: 0, to: characters.count, by: 180).map { String(characters[$0..<min($0 + 180, characters.count)]) }
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            HStack {
                Text("把判断放回原文里").font(.system(size: 20, design: .serif)); Spacer()
                Button { dismiss() } label: { Image(systemName: "xmark").frame(width: 44, height: 44) }
                    .accessibilityLabel("回到刚才的图").accessibilityIdentifier("study-close-evidence")
            }
            Text(context).font(.subheadline).foregroundStyle(StudyInk.muted)
            Rectangle().frame(height: 1)
            if let evidence, let page = library.pages(for: evidence.id).first {
                VStack(alignment: .leading, spacing: 8) {
                    if counterIDs.contains(evidence.id) { Text("这是一处反证").font(.caption.bold()) }
                    Text(page.title).font(.headline)
                    Text("PDF物理页 " + evidence.physicalPages.map(String.init).joined(separator: "、"))
                        .font(.caption.monospaced()).foregroundStyle(StudyInk.muted)
                }
                Text("原文摘录").font(.caption.weight(.semibold)).tracking(2)
                Text(chunks[min(chunkIndex, chunks.count - 1)]).font(.system(size: 17)).lineSpacing(8).textSelection(.enabled)
                if chunks.count > 1 {
                    HStack {
                        Button("前段") { chunkIndex = max(0, chunkIndex - 1) }.disabled(chunkIndex == 0); Spacer()
                        Text("摘录 " + String(chunkIndex + 1) + "/" + String(chunks.count)).font(.caption); Spacer()
                        Button("后段") { chunkIndex = min(chunks.count - 1, chunkIndex + 1) }.disabled(chunkIndex == chunks.count - 1)
                    }.font(.subheadline).frame(minHeight: 44)
                }
                Text(evidence.locatorNote).font(.footnote).foregroundStyle(StudyInk.muted).lineSpacing(4)
                Spacer(minLength: 0)
                ForEach(library.pages(for: evidence.id)) { page in
                    Button { source = page } label: {
                        HStack {
                            Label("打开原PDF第" + String(page.physicalPage) + "页", systemImage: "doc.viewfinder")
                            Spacer(); Image(systemName: "arrow.up.right")
                        }.font(.system(size: 14, weight: .medium)).padding(16).foregroundStyle(StudyInk.paper).background(.black)
                    }.buttonStyle(.plain).accessibilityIdentifier("study-open-pdf")
                }
            } else { ContentUnavailableView("这条依据暂时没有打开", systemImage: "doc.questionmark") }
            HStack {
                Button { change(-1) } label: { Image(systemName: "arrow.left").frame(width: 44, height: 44) }.disabled(index == 0)
                Spacer(); Text("依据 " + String(index + 1) + " / " + String(ids.count)).font(.caption.monospaced()); Spacer()
                Button { change(1) } label: { Image(systemName: "arrow.right").frame(width: 44, height: 44) }.disabled(index + 1 >= ids.count)
            }
        }.padding(24).background(StudyInk.paper).foregroundStyle(.black).tint(.black)
        #if os(iOS)
        .presentationDetents([.large]).fullScreenCover(item: $source) { StudyPDFScreen(page: $0) }
        #else
        .frame(width: 440, height: 780).sheet(item: $source) { StudyPDFScreen(page: $0).frame(width: 650, height: 850) }
        #endif
    }
    private func change(_ delta: Int) { index = min(max(0, index + delta), max(0, ids.count - 1)); chunkIndex = 0 }
}

struct StudyPDFScreen: View {
    let page: EvidencePage
    var returnLabel = "回到依据"
    @Environment(\.dismiss) private var dismiss
    @Environment(\.studyPackageResources) private var resources
    @ReadingState private var command: PDFReadingAction = .locate
    @ReadingState private var commandID = 0
    @ReadingState private var currentPage = 0
    @ReadingState private var failed = false
    private var file: URL? { resources.flatMap { try? $0.pdfURL(sourceID: page.sourceId) } }
    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Button { dismiss() } label: { Label(returnLabel, systemImage: "chevron.left").font(.system(size: 13)).frame(minHeight: 44) }
                    .accessibilityIdentifier("study-close-pdf")
                Spacer()
                Text("原始PDF").font(.system(size: 12, weight: .semibold)).tracking(2)
            }.padding(.horizontal, 18)
            Text(page.title).font(.system(size: 14, weight: .medium)).lineLimit(2)
                .frame(maxWidth: .infinity, alignment: .leading).padding(.horizontal, 18).padding(.bottom, 12)
            Divider()
            if failed || file == nil {
                ContentUnavailableView("PDF暂时没有打开", systemImage: "doc.questionmark", description: Text("关闭后可以重新打开这份原件。"))
            } else if let file {
                NativePDFReader(request: PDFReadingRequest(file: file,
                    physicalPage: page.physicalPage, focusText: page.focusText ?? "", command: command, commandID: commandID, paged: true),
                    onReady: { result in if case .failure = result { failed = true } },
                    onPage: { currentPage = $0 })
                .accessibilityLabel("完整原始PDF，单页阅读，可缩放")
            }
            Divider()
            HStack {
                pdfControl("前页", symbol: "chevron.left", action: .previousPage)
                Spacer()
                Text(String(currentPage == 0 ? page.physicalPage : currentPage) + " / " + String(page.pageCount))
                    .font(.system(size: 12, design: .monospaced))
                    .accessibilityIdentifier("study-pdf-position")
                    .accessibilityValue(currentPage > 0 ? "原文已打开" : "正在打开原文")
                Spacer()
                pdfControl("后页", symbol: "chevron.right", action: .nextPage)
            }.padding(.horizontal, 20)
            HStack(spacing: 30) {
                pdfControl("证据页", symbol: "scope", action: .locate)
                pdfControl("放大", symbol: "plus.magnifyingglass", action: .zoomIn)
                pdfControl("缩小", symbol: "minus.magnifyingglass", action: .zoomOut)
                pdfControl("适应", symbol: "arrow.up.left.and.arrow.down.right", action: .fit)
            }.padding(.horizontal, 12).padding(.bottom, 8)
        }.background(StudyInk.paper).foregroundStyle(.black).tint(.black)
    }
    private func pdfControl(_ title: String, symbol: String, action: PDFReadingAction) -> some View {
        Button { command = action; commandID += 1 } label: {
            VStack(spacing: 5) { Image(systemName: symbol); Text(title).font(.system(size: 10)) }.frame(minWidth: 44, minHeight: 44)
        }.buttonStyle(.plain).accessibilityLabel(title)
    }
}
