import SwiftUI
import UniformTypeIdentifiers
#if SWIFT_PACKAGE
import ResearchCore
#endif

struct StudyLibraryView: View {
    @Bindable var workspace: StudyWorkspace
    @ReadingState private var selectingFolder = false
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 30) {
                VStack(alignment: .leading, spacing: 12) {
                    Text("研").font(.system(size: 34, design: .serif)).foregroundStyle(StudyInk.paper)
                        .frame(width: 48, height: 54).background(.black)
                    Text("研究库").font(.system(.largeTitle, design: .serif))
                    Text("把一家公司，连起来看。").font(.title3)
                    Text("Mac 发布到 iCloud Drive；这里阅读完整研究与原始资料。")
                        .font(.subheadline).foregroundStyle(StudyInk.muted)
                }
                Rectangle().frame(height: 1)
                connection
                if let choice = workspace.shelf.recommendedContinuation {
                    Button { workspace.continueReading(choice) } label: {
                        HStack {
                            Label("继续阅读 · " + continuationCompany(choice), systemImage: "bookmark")
                            Spacer(); Image(systemName: "arrow.right")
                        }
                            .padding(18).foregroundStyle(StudyInk.paper).background(.black)
                    }.buttonStyle(.plain).accessibilityIdentifier("library-continue")
                    recordStatus
                }
                if let notice = workspace.notice {
                    Text(notice).font(.subheadline).foregroundStyle(StudyInk.muted)
                }
                ForEach(workspace.shelf.entries) { entry in company(entry) }
                if workspace.shelf.entries.isEmpty {
                    ContentUnavailableView("还没有研究", systemImage: "books.vertical",
                        description: Text("请在“文件”中选定 iCloud Drive 内的专用研究目录。"))
                }
            }.padding(24).frame(maxWidth: 680, alignment: .leading).frame(maxWidth: .infinity)
        }
        .background(StudyInk.paper.ignoresSafeArea()).foregroundStyle(.black).tint(.black).preferredColorScheme(.light)
        .fileImporter(isPresented: $selectingFolder, allowedContentTypes: [.folder]) { result in
            switch result {
            case .success(let folder): Task { await workspace.connect(folder) }
            case .failure(let error):
                if (error as NSError).code != NSUserCancelledError { workspace.notice = error.localizedDescription }
            }
        }
    }

    private func continuationCompany(_ choice: ShelfContinuationChoice) -> String {
        workspace.shelf.entries.first { $0.id == choice.versionID.companyID }?.name ?? "上次的研究"
    }

    private var connection: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(connectionLabel).font(.subheadline)
            HStack(spacing: 20) {
                Button { selectingFolder = true } label: {
                    Label("选择研究目录", systemImage: "folder.badge.plus").frame(minHeight: 44)
                }.accessibilityIdentifier("library-connect")
                Button { Task { await workspace.refresh() } } label: {
                    Label("检查更新", systemImage: "arrow.clockwise").frame(minHeight: 44)
                }.accessibilityIdentifier("library-refresh")
            }.buttonStyle(.plain).font(.subheadline)
        }
    }

    private var recordStatus: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(localRecordLabel).font(.caption).accessibilityIdentifier("library-record-status")
            Text(cloudRecordLabel).font(.caption).foregroundStyle(StudyInk.muted)
            if case .unsaved = workspace.shelf.recordState.local {
                Button("重试保存阅读位置") { Task { await workspace.shelf.retryRecords() } }.frame(minHeight: 44)
            } else if case .failed = workspace.shelf.recordState.cloud {
                Button("重试同步阅读位置") { Task { await workspace.shelf.retryRecords() } }.frame(minHeight: 44)
            }
        }
    }

    private var localRecordLabel: String {
        switch workspace.shelf.recordState.local {
        case .saved: return "阅读位置已保存在本机"
        case .saving: return "正在保存阅读位置…"
        case .unsaved(let reason): return "阅读位置尚未成功保存：" + reason
        }
    }
    private var cloudRecordLabel: String {
        switch workspace.shelf.recordState.cloud {
        case .waitingForConnection: return "关联研究目录后，同步阅读记录。"
        case .pending: return "阅读记录等待同步"
        case .exchanging: return "正在交换阅读记录…"
        case .accepted: return "阅读记录已写入研究目录"
        case .failed(let reason): return "阅读记录暂未完成同步：" + reason
        }
    }

    private var connectionLabel: String {
        switch workspace.shelf.connectionState {
        case .disconnected: return "选择一次专用研究目录，之后打开时检查更新。已准备的研究可以离线阅读。"
        case .checking: return "正在关联研究目录…"
        case .connected: return "已关联研究目录"
        case .needsSelection(let reason), .unavailable(let reason): return reason
        }
    }

    private func company(_ entry: ShelfEntry) -> some View {
        VStack(alignment: .leading, spacing: 20) {
            HStack(alignment: .firstTextBaseline) {
                Text(entry.name).font(.system(.title, design: .serif))
                Spacer()
                Text(entry.code + " · " + entry.exchange).font(.caption.monospaced()).foregroundStyle(StudyInk.muted)
            }
            if entry.hasUpdate { Text("有更新 · 新版已准备好").font(.subheadline.weight(.semibold)) }
            if let choice = entry.recommendedContinuation {
                Button { workspace.continueReading(choice) } label: {
                    Label("继续这份研究", systemImage: "bookmark").frame(minHeight: 44)
                }.buttonStyle(.plain).accessibilityIdentifier("library-company-continue-" + entry.id)
            }
            if entry.continuations.count > 1 {
                Menu("选择阅读位置") {
                    ForEach(entry.continuations) { choice in
                        Button((choice.isLocalDevice ? "这台设备 · " : "另一台设备 · ")
                               + choice.occurredAt.formatted(date: .abbreviated, time: .shortened)) {
                            workspace.continueReading(choice)
                        }
                    }
                }.frame(minHeight: 44).accessibilityIdentifier("library-continuation-choices")
            }
            ForEach(entry.versions) { version in
                VStack(alignment: .leading, spacing: 10) {
                    Text(version.financialPeriodStart + " — " + version.financialPeriodEnd).font(.subheadline.monospaced())
                    Text("资料截至 " + version.researchAsOf + " · 第 " + String(version.reportRevision) + " 版")
                        .font(.caption).foregroundStyle(StudyInk.muted)
                    switch version.state {
                    case .ready:
                        Button { workspace.open(version.id) } label: {
                            HStack { Text(version.isCurrent ? (entry.hasUpdate ? "阅读新版" : "打开研究") : "打开这个版本"); Spacer(); Image(systemName: "arrow.right") }
                                .padding(18).foregroundStyle(StudyInk.paper).background(.black)
                        }.buttonStyle(.plain).accessibilityIdentifier(version.isCurrent ? "library-open-current" : "library-open-version")
                    case .preparing: ProgressView("正在准备完整研究…").font(.subheadline)
                    case .waiting: Text("等待取得完整研究").font(.subheadline).foregroundStyle(StudyInk.muted)
                    case .failed(let reason):
                        Text("这份研究暂时未能准备完整。").font(.subheadline).foregroundStyle(StudyInk.muted)
                        DisclosureGroup("查看原因") { Text(reason).font(.footnote).textSelection(.enabled) }
                        Button("重新准备") { Task { await workspace.shelf.retryPreparation(version.id) } }.frame(minHeight: 44)
                    }
                }
            }
            Rectangle().fill(StudyInk.line).frame(height: 1)
        }
    }
}
