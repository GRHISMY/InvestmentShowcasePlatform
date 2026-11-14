import SwiftUI
#if SWIFT_PACKAGE
import ResearchCore
#endif
#if canImport(UIKit)
import UIKit
#else
import AppKit
#endif

private enum StudyInk {
    static let paper = Color(red: 0.965, green: 0.959, blue: 0.936)
    static let line = Color.black.opacity(0.18)
    static let muted = Color.black.opacity(0.58)
}

/// A platform Adapter for a validated reading package. No company story,
/// financial value, focus mapping or research relationship is authored here.
struct VisualStudyReader: View {
    let reading: ReadingLibrary
    @ReadingState private var state: VisualStudyState
    @ReadingState private var showEvidence = false
    @ReadingState private var showArchive = false
    @ReadingState private var showInsight = false
    @ReadingState private var showCalculation = false
    @ReadingState private var overviewPage = 0
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    private let bookmarkKey: String

    init(reading: ReadingLibrary) {
        self.reading = reading
        let identity = reading.document.researchRef.snapshotId + "." + reading.document.id + ".r" + String(reading.document.revision)
        bookmarkKey = "reading-package-v1." + identity
        let saved = UserDefaults.standard.data(forKey: bookmarkKey)
        var initial = VisualStudyState(momentIDs: reading.document.sceneOrder, saved: saved)
        if saved == nil { initial.overview() }
        if initial.focus != nil, reading.validFocus(initial.focus, in: initial.currentID) == nil { initial.selectFocus(nil) }
        _state = ReadingState(initialValue: initial)
    }

    private var library: ResearchLibrary { reading.research }
    private var scene: ReadingScene { reading.scene(state.currentID) ?? reading.orderedScenes[0] }
    private var focus: ReadingFocus {
        let selected = reading.validFocus(state.focus, in: scene.id) ?? scene.defaultFocusId
        return reading.focus(selected)!
    }
    private var figure: ReadingView { reading.view(scene.viewId)! }
    private var position: Int { reading.document.sceneOrder.firstIndex(of: scene.id) ?? 0 }
    private var limitText: String {
        var notes = [focus.caveat]
        for note in scene.essentialNotes where !notes.contains(where: { $0.contains(note) }) { notes.append(note) }
        return notes.filter { !$0.isEmpty }.joined(separator: "\n")
    }

    var body: some View {
        GeometryReader { geometry in
            let compact = geometry.size.height < 700
            VStack(spacing: 0) {
                masthead
                Rectangle().fill(.black).frame(height: 1)
                if state.isOverview { overview(compact: compact) }
                else {
                    let layout = sceneLayout(width: min(620, geometry.size.width), height: geometry.size.height)
                    readingScene(compact: layout.compact, diagramHeight: layout.diagramHeight)
                }
            }
            .frame(maxWidth: 620, maxHeight: .infinity)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(StudyInk.paper)
        }
        .background(StudyInk.paper.ignoresSafeArea()).foregroundStyle(.black).tint(.black).preferredColorScheme(.light)
        .sheet(isPresented: $showEvidence) {
            StudyEvidenceReader(library: library, ids: focus.evidenceIds, counterIDs: focus.counterEvidenceIds, context: focus.title)
        }
        .sheet(isPresented: $showCalculation) { StudyCalculationReader(library: library, calculationIDs: focus.calculationIds) }
        .sheet(isPresented: $showInsight) { StudyExplanationSheet(title: focus.title, text: focus.body, caveat: limitText) }
        .sheet(isPresented: $showArchive) {
            ZStack(alignment: .topTrailing) {
                ReaderRoot(library: library)
                Button { showArchive = false } label: {
                    Label("回到图中", systemImage: "xmark").font(.caption.bold()).padding(12).background(StudyInk.paper, in: Capsule())
                }.buttonStyle(.plain).padding(.top, 6).padding(.trailing, 12)
            }
            #if os(macOS)
            .frame(minWidth: 440, minHeight: 780)
            #endif
        }
        .onChange(of: state) { _, _ in persist() }
        .onChange(of: scenePhase) { _, phase in if phase != .active { persist() } }
    }

    private var masthead: some View {
        HStack(spacing: 10) {
            Text("研").font(.system(size: 24, design: .serif)).foregroundStyle(StudyInk.paper)
                .frame(width: 35, height: 39).background(.black)
            VStack(alignment: .leading, spacing: 3) {
                Text("黑白研究档案").font(.system(size: 14, weight: .semibold)).tracking(2)
                Text(library.research.company.name + " / " + library.research.company.code)
                    .font(.system(size: 10, design: .monospaced)).tracking(1)
            }
            Spacer()
            Button {
                if state.isOverview { showArchive = true } else { transition { state.overview() } }
            } label: {
                if state.isOverview { Text("原报告 ↗").font(.system(size: 12)).frame(minHeight: 44) }
                else { Label("全貌", systemImage: "viewfinder").font(.system(size: 13)).frame(minWidth: 60, minHeight: 44) }
            }.buttonStyle(.plain).accessibilityIdentifier(state.isOverview ? "study-archive" : "study-overview")
        }.padding(.horizontal, 22).padding(.vertical, 12)
    }

    private func overview(compact: Bool) -> some View {
        VStack(alignment: .leading, spacing: compact ? 12 : 17) {
            Text(reading.document.overview.title).font(.system(size: compact ? 25 : 29, design: .serif))
                .fixedSize(horizontal: false, vertical: true).padding(.top, 20)
            Text("研究路线 · 点一处自由看").font(.system(size: 11)).foregroundStyle(StudyInk.muted)
            overviewMap.frame(maxWidth: .infinity, maxHeight: .infinity)
            VStack(alignment: .leading, spacing: 7) {
                Text("这次研究看到什么").font(.system(size: 10, weight: .semibold)).tracking(2)
                Text(reading.document.overview.summary).font(.system(size: compact ? 15 : 17)).lineSpacing(5)
                    .fixedSize(horizontal: false, vertical: true)
            }
            VStack(alignment: .leading, spacing: 5) {
                Text(library.research.report.coverage.start + " — " + library.research.report.coverage.end)
                    .font(.system(size: 10, design: .monospaced))
                Text("资料查到 " + library.research.report.researchAsOf + " · " + (reading.document.coverage.mode == "complete" ? "完整研究" : "研究节选"))
                    .font(.system(size: 10)).foregroundStyle(StudyInk.muted)
            }
            if !state.history.isEmpty || position != 0 {
                Button("重新从头开始 →") {
                    transition { state = VisualStudyState(momentIDs: reading.document.sceneOrder) }
                }.font(.system(size: 12)).frame(minHeight: 32).buttonStyle(.plain).accessibilityIdentifier("study-restart")
            }
            Button { transition { state.enter(state.currentID) } } label: {
                HStack {
                    VStack(alignment: .leading, spacing: 5) {
                        Text(state.history.isEmpty && position == 0 ? "带我看懂" : "接着刚才看").font(.system(size: 17, weight: .medium))
                        Text(scene.question).font(.system(size: 11)).opacity(0.7)
                    }
                    Spacer(); Image(systemName: "arrow.right").font(.system(size: 21))
                }.padding(18).foregroundStyle(StudyInk.paper).background(.black)
            }.buttonStyle(.plain).accessibilityIdentifier("study-begin")
        }.padding(.horizontal, 24).padding(.bottom, 20)
    }

    private var overviewMap: some View {
        let entries = reading.document.overview.entries
        let pages = max(1, (entries.count + 5) / 6)
        let start = min(overviewPage, pages - 1) * 6
        let visible = Array(entries.dropFirst(start).prefix(6))
        return VStack(spacing: 0) {
            GeometryReader { geometry in
                let rows = max(1, (visible.count + 1) / 2)
                let w = geometry.size.width, h = geometry.size.height
                ZStack {
                    ForEach(Array(visible.enumerated()), id: \.element.id) { index, item in
                        let column = index % 2, row = index / 2
                        Button { transition { state.enter(item.sceneId) } } label: {
                            VStack(spacing: 7) {
                                Image(systemName: item.icon).font(.system(size: 23, weight: .light))
                                Text(item.label).font(.system(size: 14, weight: .medium)).multilineTextAlignment(.center)
                                Text(item.caption).font(.system(size: 10)).foregroundStyle(StudyInk.muted).multilineTextAlignment(.center)
                            }.frame(width: min(145, w * 0.45), height: 88).contentShape(Rectangle())
                        }.buttonStyle(.plain)
                            .position(x: w * (column == 0 ? 0.25 : 0.75), y: h * (CGFloat(row) + 0.5) / CGFloat(rows))
                            .accessibilityIdentifier("study-map-" + item.sceneId)
                    }
                }
            }
            if pages > 1 {
                HStack {
                    Button("上一组") { overviewPage = max(0, overviewPage - 1) }.disabled(overviewPage == 0)
                    Spacer(); Text(String(overviewPage + 1) + " / " + String(pages)).font(.caption.monospaced()); Spacer()
                    Button("下一组") { overviewPage = min(pages - 1, overviewPage + 1) }.disabled(overviewPage + 1 >= pages)
                }.font(.caption).frame(height: 36).buttonStyle(.plain)
            }
        }
    }

    private func readingScene(compact: Bool, diagramHeight: CGFloat) -> some View {
        VStack(alignment: .leading, spacing: compact ? 7 : 9) {
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Text(scene.section).font(.system(size: 10, weight: .semibold)).tracking(2)
                    Spacer()
                    Text(String(format: "%02d", position + 1) + " / " + String(format: "%02d", reading.orderedScenes.count))
                        .font(.system(size: 10, design: .monospaced)).foregroundStyle(StudyInk.muted)
                }
                Text(scene.title).font(.system(size: compact ? 23 : 25, design: .serif)).fixedSize(horizontal: false, vertical: true)
            }.padding(.top, compact ? 15 : 20)
            StudyDiagram(view: figure, focus: focus.id, periods: library.research.periods) { id in
                if reading.validFocus(id, in: scene.id) != nil { transition { state.selectFocus(id) } }
            }
            .frame(height: diagramHeight)
            .accessibilityIdentifier("study-diagram")
            if compact {
                Button { showInsight = true } label: {
                    HStack {
                        VStack(alignment: .leading, spacing: 4) {
                            Text(focus.title).font(.system(size: 14, weight: .medium))
                            Text("展开这张图的解释").font(.system(size: 10)).foregroundStyle(StudyInk.muted)
                        }
                        Spacer(); Image(systemName: "arrow.up.right")
                    }.frame(minHeight: 46).contentShape(Rectangle())
                }.buttonStyle(.plain)
            } else {
                VStack(alignment: .leading, spacing: 7) {
                    Text(focus.title).font(.system(size: 11, weight: .semibold)).foregroundStyle(StudyInk.muted)
                    Text(focus.body).font(.system(size: 15)).lineSpacing(5).fixedSize(horizontal: false, vertical: true)
                }.accessibilityIdentifier("study-explanation")
            }
            if !limitText.isEmpty {
                HStack(alignment: .top, spacing: 8) {
                    Image(systemName: "circle.dotted").font(.system(size: 11)).padding(.top, 2)
                    Text(limitText).font(.system(size: compact ? 10 : 11)).lineSpacing(3).fixedSize(horizontal: false, vertical: true)
                }.foregroundStyle(StudyInk.muted).accessibilityIdentifier("study-essential-notes")
            }
            if !focus.counterEvidenceIds.isEmpty {
                Text("这处也有反证，核对依据时一并查看。").font(.system(size: 11, weight: .medium))
            }
            Spacer(minLength: 0)
            HStack(spacing: 15) {
                Button { showEvidence = true } label: {
                    Label("看原页依据", systemImage: "doc.text.magnifyingglass").font(.system(size: 12)).frame(minHeight: 40)
                }.disabled(focus.evidenceIds.isEmpty).accessibilityIdentifier("study-evidence")
                Spacer()
                if !focus.calculationIds.isEmpty {
                    Button { showCalculation = true } label: {
                        Label("数字怎么算", systemImage: "equal").font(.system(size: 12)).frame(minHeight: 40)
                    }.accessibilityIdentifier("study-calculation")
                } else { Text("点图，换一个角度看").font(.system(size: 10)).foregroundStyle(StudyInk.muted) }
            }.buttonStyle(.plain)
            Rectangle().fill(StudyInk.line).frame(height: 0.5)
            HStack(spacing: 17) {
                Button {
                    transition {
                        state.back()
                        if state.focus != nil, reading.validFocus(state.focus, in: state.currentID) == nil { state.selectFocus(nil) }
                    }
                } label: { Image(systemName: "arrow.left").frame(width: 44, height: 48) }
                    .buttonStyle(.plain).accessibilityLabel("回到刚才").accessibilityIdentifier("study-back")
                Button {
                    transition { if let next = scene.nextSceneId { state.enter(next) } else { state.overview() } }
                } label: {
                    HStack {
                        Text(scene.nextLabel).font(.system(size: 14, weight: .medium)).multilineTextAlignment(.leading)
                        Spacer(minLength: 4); Image(systemName: "arrow.right")
                    }.padding(.horizontal, 17).frame(maxWidth: .infinity, minHeight: 49).foregroundStyle(StudyInk.paper).background(.black)
                }.buttonStyle(.plain).accessibilityIdentifier("study-next")
            }
        }.padding(.horizontal, 24).padding(.bottom, 15)
    }
    /// Budget actual text before giving the diagram its canvas. Flexible stacks
    /// alone can report a fitting ideal size while drawing past the next button.
    private func sceneLayout(width: CGFloat, height: CGFloat) -> (compact: Bool, diagramHeight: CGFloat) {
        let textWidth = max(180, width - 48)
        func budget(compact: Bool) -> CGFloat {
            let spacing: CGFloat = compact ? 7 : 9
            let heading = (compact ? 15.0 : 20.0) + 14 + 8
                + measuredHeight(scene.title, size: compact ? 23 : 25, width: textWidth)
            let explanation: CGFloat = compact ? 48
                : measuredHeight(focus.title, size: 11, width: textWidth) + 7
                  + measuredHeight(focus.body, size: 15, width: textWidth, lineSpacing: 5)
            let limit = limitText.isEmpty ? 0 : measuredHeight(limitText, size: compact ? 10 : 11, width: textWidth - 20, lineSpacing: 3)
            let counter: CGFloat = focus.counterEvidenceIds.isEmpty ? 0 : 18
            let gaps = spacing * CGFloat(8 + (counter > 0 ? 1 : 0))
            // Masthead, tools, divider, fixed navigation, bottom inset and a
            // small allowance for font metrics/paragraph leading.
            return height - 69 - heading - explanation - limit - counter - gaps - 40 - 1 - 50 - 15 - 18
        }
        let regular = budget(compact: false)
        let compact = height < 700 || regular < 190
        return (compact, min(compact ? 230 : 260, max(125, compact ? budget(compact: true) : regular)))
    }
    private func measuredHeight(_ text: String, size: CGFloat, width: CGFloat, lineSpacing: CGFloat = 0) -> CGFloat {
        let paragraph = NSMutableParagraphStyle(); paragraph.lineSpacing = lineSpacing
        #if canImport(UIKit)
        let font = UIFont.systemFont(ofSize: size)
        let rect = (text as NSString).boundingRect(with: CGSize(width: width, height: .greatestFiniteMagnitude),
            options: [.usesLineFragmentOrigin, .usesFontLeading], attributes: [.font: font, .paragraphStyle: paragraph], context: nil)
        #else
        let font = NSFont.systemFont(ofSize: size)
        let rect = (text as NSString).boundingRect(with: CGSize(width: width, height: .greatestFiniteMagnitude),
            options: [.usesLineFragmentOrigin, .usesFontLeading], attributes: [.font: font, .paragraphStyle: paragraph])
        #endif
        return ceil(rect.height)
    }
    private func transition(_ change: () -> Void) { withAnimation(reduceMotion ? nil : .easeInOut(duration: 0.2), change) }
    private func persist() {
        if let bookmark = state.encodedBookmark() { UserDefaults.standard.set(bookmark, forKey: bookmarkKey) }
    }
}

private struct StudyEvidenceReader: View {
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
