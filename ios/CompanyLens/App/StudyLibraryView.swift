import SwiftUI
import UniformTypeIdentifiers
#if SWIFT_PACKAGE
import ResearchCore
#endif

struct StudyLibraryView: View {
    @Bindable var workspace: StudyWorkspace
    @ReadingState private var selectingFolder = false
    @ReadingState private var showingConnection = false
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 28) {
                continuation
                VStack(alignment: .leading, spacing: 14) {
                    ViewThatFits(in: .horizontal) {
                        HStack {
                            Text("全部研究").font(.title2.bold())
                            Spacer()
                            companyCount
                        }
                        VStack(alignment: .leading, spacing: 6) {
                            Text("全部研究").font(.title2.bold())
                            companyCount
                        }
                    }
                    ForEach(workspace.shelf.entries) { entry in company(entry) }
                    if workspace.shelf.entries.isEmpty {
                        ContentUnavailableView("还没有研究", systemImage: "books.vertical",
                            description: Text("请在“文件”中选定 iCloud Drive 内的专用研究目录。"))
                            .libraryCard()
                    }
                }
                libraryStatus
            }
            .padding(.horizontal, 20).padding(.top, 14).padding(.bottom, 28)
            .frame(maxWidth: 760, alignment: .leading).frame(maxWidth: .infinity)
        }
        .background(StudyInk.grouped.ignoresSafeArea())
        .navigationTitle("研究库")
        #if canImport(UIKit)
        .navigationBarTitleDisplayMode(.large)
        #endif
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button { showingConnection = true } label: {
                    Label("同步状态", systemImage: "icloud").foregroundStyle(.tint)
                }.accessibilityIdentifier("library-sync")
                    .accessibilityValue(localRecordLabel + "；" + cloudRecordLabel)
            }
        }
        .sheet(isPresented: $showingConnection) {
            NavigationStack {
                ScrollView { connection.padding(20).frame(maxWidth: 760).frame(maxWidth: .infinity) }
                    .background(StudyInk.grouped)
                    .navigationTitle("同步状态")
                    .toolbar {
                        ToolbarItem(placement: .confirmationAction) {
                            Button("完成") { showingConnection = false }
                        }
                    }
            }
            .fileImporter(isPresented: $selectingFolder, allowedContentTypes: [.folder]) { result in
                switch result {
                case .success(let folder): Task { await workspace.connect(folder) }
                case .failure(let error):
                    if (error as NSError).code != NSUserCancelledError { workspace.notice = error.localizedDescription }
                }
            }
        }
    }

    private var companyCount: some View {
        Text("\(workspace.shelf.entries.count) 家公司").font(.subheadline).foregroundStyle(.secondary)
    }

    @ViewBuilder private var continuation: some View {
        if let reading = workspace.activeReading {
            let research = reading.study.research.research
            continuationSection {
                Button { workspace.showReading() } label: {
                    VStack(alignment: .leading, spacing: 16) {
                        cardHeading(research.company.name, subtitle: "当前阅读 · " + modeLabel(reading.reader.currentMode))
                        Text(reading.reader.currentTitle)
                            .font(.title3.weight(.semibold)).fixedSize(horizontal: false, vertical: true)
                            .accessibilityIdentifier("library-current-title")
                        Text(coverage(research.report.coverage.start, research.report.coverage.end))
                            .font(.caption).foregroundStyle(.secondary)
                        continuePrompt("回到当前阅读位置")
                    }.libraryCard()
                }.buttonStyle(.plain).accessibilityIdentifier("library-continue")
            }
        } else if let choice = workspace.shelf.recommendedContinuation {
            continuationSection {
                Button { workspace.continueReading(choice) } label: {
                    VStack(alignment: .leading, spacing: 16) {
                        cardHeading(continuationCompany(choice), subtitle: continuationMode(choice))
                        Text(workspace.shelf.continuationTitle(for: choice) ?? "阅读位置待核验")
                            .font(.title3.weight(.semibold)).fixedSize(horizontal: false, vertical: true)
                            .accessibilityIdentifier("library-current-title")
                        if let version = continuationVersion(choice) {
                            Text(coverage(version.financialPeriodStart, version.financialPeriodEnd))
                                .font(.caption).foregroundStyle(.secondary)
                        }
                        Text(deviceAndTime(choice)).font(.caption).foregroundStyle(.secondary)
                        continuePrompt("回到上次的阅读位置")
                    }.libraryCard()
                }.buttonStyle(.plain).accessibilityIdentifier("library-continue")
            }
        }
    }

    private func continuationSection<Content: View>(@ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("继续阅读").font(.title2.bold())
            content()
        }
    }

    private func cardHeading(_ name: String, subtitle: String) -> some View {
        HStack(alignment: .top, spacing: 14) {
            if !dynamicTypeSize.isAccessibilitySize {
                companyMark(name)
            }
            VStack(alignment: .leading, spacing: 5) {
                Text(name).font(.headline).foregroundStyle(.primary)
                Text(subtitle).font(.subheadline).foregroundStyle(.secondary)
            }.frame(maxWidth: .infinity, alignment: .leading)
            Image(systemName: "arrow.up.right").font(.subheadline.weight(.medium)).foregroundStyle(.secondary)
                .padding(.top, 5).accessibilityHidden(true)
        }.multilineTextAlignment(.leading)
    }

    private func continuePrompt(_ title: String) -> some View {
        HStack {
            Label(title, systemImage: "arrow.turn.down.right")
                .font(.subheadline.weight(.medium)).foregroundStyle(Color.accentColor)
            Spacer(minLength: 0)
            Image(systemName: "chevron.right").font(.caption.weight(.semibold)).foregroundStyle(.tertiary)
                .accessibilityHidden(true)
        }.frame(minHeight: 24, alignment: .leading)
    }

    private func continuationCompany(_ choice: ShelfContinuationChoice) -> String {
        workspace.shelf.entries.first { $0.id == choice.versionID.companyID }?.name ?? "上次的研究"
    }

    private func continuationVersion(_ choice: ShelfContinuationChoice) -> ShelfVersionEntry? {
        workspace.shelf.entries.first { $0.id == choice.versionID.companyID }?.versions.first { $0.id == choice.versionID }
    }

    private func continuationMode(_ choice: ShelfContinuationChoice) -> String {
        workspace.shelf.readingMode(for: choice).map(modeLabel) ?? "阅读位置待核验"
    }

    private func modeLabel(_ mode: ReadingMode) -> String { mode == .report ? "完整报告" : "图解阅读" }

    private func availableModes(_ version: ShelfVersionEntry) -> String {
        guard let modes = workspace.shelf.availableModes(for: version.id) else { return "阅读方式待准备" }
        return modes.map(modeLabel).joined(separator: " · ")
    }

    private func coverage(_ start: String, _ end: String) -> String { "研究期间 " + start + " — " + end }

    private func deviceAndTime(_ choice: ShelfContinuationChoice) -> String {
        (choice.isLocalDevice ? "这台设备 · " : "另一台设备 · ")
            + choice.occurredAt.formatted(date: .abbreviated, time: .shortened)
    }

    private var connection: some View {
        VStack(alignment: .leading, spacing: 16) {
            Label("研究目录与阅读记录", systemImage: "icloud").font(.headline)
            Text(connectionLabel).font(.subheadline).foregroundStyle(.secondary)
            VStack(alignment: .leading, spacing: 2) {
                Button { selectingFolder = true } label: {
                    Label("选择研究目录", systemImage: "folder.badge.plus").frame(minHeight: 44)
                }.accessibilityIdentifier("library-connect")
                Button { Task { await workspace.refresh() } } label: {
                    Label("检查更新", systemImage: "arrow.clockwise").frame(minHeight: 44)
                }.accessibilityIdentifier("library-refresh")
            }.buttonStyle(.plain).foregroundStyle(Color.accentColor)
            if let notice = workspace.notice {
                Text(notice).font(.subheadline).foregroundStyle(.secondary).textSelection(.enabled)
            }
            Divider()
            recordStatus
        }.libraryCard()
    }

    private var recordStatus: some View {
        VStack(alignment: .leading, spacing: 10) {
            Label(localRecordLabel, systemImage: "internaldrive").font(.footnote)
                .accessibilityIdentifier("library-record-status")
            Label(cloudRecordLabel, systemImage: "icloud").font(.footnote).foregroundStyle(.secondary)
            if case .unsaved = workspace.shelf.recordState.local {
                Button("重试保存阅读位置") { Task { await workspace.shelf.retryRecords() } }.frame(minHeight: 44)
            }
            if case .failed = workspace.shelf.recordState.cloud {
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

    private func companyMark(_ name: String) -> some View {
        Text(String(name.prefix(1))).font(.title3.weight(.semibold))
            .foregroundStyle(.primary).frame(width: 44, height: 44)
            .background(Color.primary.opacity(0.045), in: RoundedRectangle(cornerRadius: 12))
            .accessibilityHidden(true)
    }

    private var libraryStatus: some View {
        VStack(alignment: .leading, spacing: 12) {
            if let notice = workspace.notice {
                Text(notice).font(.subheadline).textSelection(.enabled)
            }
            switch workspace.shelf.connectionState {
            case .disconnected, .needsSelection, .unavailable:
                VStack(alignment: .leading, spacing: 8) {
                    Text(connectionLabel).font(.subheadline).foregroundStyle(.secondary)
                    Button { showingConnection = true } label: {
                        Label("管理研究目录", systemImage: "folder").frame(minHeight: 44)
                    }
                }
            case .checking:
                ProgressView("正在核对研究目录…").font(.subheadline)
            case .connected: EmptyView()
            }
            recordStatus
        }.frame(maxWidth: .infinity, alignment: .leading)
    }

    private func company(_ entry: ShelfEntry) -> some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack(alignment: .center, spacing: 12) {
                if !dynamicTypeSize.isAccessibilitySize { companyMark(entry.name) }
                VStack(alignment: .leading, spacing: 4) {
                    Text(entry.name).font(.headline)
                    Text(entry.code + (entry.exchange.isEmpty ? "" : " · " + entry.exchange))
                        .font(.subheadline.monospacedDigit()).foregroundStyle(.secondary)
                }
                Spacer(minLength: 0)
            }
            if entry.hasUpdate {
                Label("有更新 · 新版已准备好", systemImage: "sparkles")
                    .font(.subheadline.weight(.medium)).foregroundStyle(Color.accentColor)
            }
            if let current = entry.versions.first(where: \.isCurrent) {
                Text(coverage(current.financialPeriodStart, current.financialPeriodEnd))
                    .font(.subheadline).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                versionState(current, entry: entry)
            }
            if let choice = entry.recommendedContinuation, showsCompanyContinuation(choice) {
                Button { workspace.continueReading(choice) } label: {
                    VStack(alignment: .leading, spacing: 5) {
                        Label("继续这份研究", systemImage: "bookmark")
                        Text(workspace.shelf.continuationTitle(for: choice) ?? "阅读位置待核验")
                            .foregroundStyle(.primary).fixedSize(horizontal: false, vertical: true)
                        Text(continuationVersion(choice).map { "第 \($0.reportRevision) 版 · " } ?? "")
                            + Text(continuationMode(choice))
                    }.font(.subheadline).frame(minHeight: 44, alignment: .leading)
                }.buttonStyle(.plain).foregroundStyle(Color.accentColor)
                    .accessibilityIdentifier("library-company-continue-" + entry.id)
            }
            if entry.continuations.count > 1 {
                DisclosureGroup {
                    VStack(alignment: .leading, spacing: 12) {
                        ForEach(entry.continuations) { choice in
                            Button { workspace.continueReading(choice) } label: {
                                VStack(alignment: .leading, spacing: 6) {
                                    Text(workspace.shelf.continuationTitle(for: choice) ?? "阅读位置待核验")
                                        .foregroundStyle(.primary).fixedSize(horizontal: false, vertical: true)
                                    Text(continuationVersion(choice).map { "第 \($0.reportRevision) 版 · " } ?? "原版本 · ")
                                        + Text(continuationMode(choice))
                                    Text(deviceAndTime(choice)).font(.caption).foregroundStyle(.secondary)
                                }.frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
                                    .padding(.vertical, 6).contentShape(Rectangle())
                            }.buttonStyle(.plain).font(.subheadline).foregroundStyle(Color.accentColor)
                            Divider()
                        }
                    }.padding(.top, 8)
                } label: {
                    Label("选择阅读位置 · \(entry.continuations.count) 个候选", systemImage: "clock.arrow.circlepath")
                        .frame(minHeight: 44)
                }.accessibilityIdentifier("library-continuation-choices")
            }
            // Preparation and failures stay visible; only already-readable older versions fold away.
            ForEach(entry.versions.filter { !$0.isCurrent && $0.state != .ready }) { version in
                Divider()
                versionMetadata(version)
                versionState(version, entry: entry)
            }
            DisclosureGroup("版本与资料") {
                VStack(alignment: .leading, spacing: 12) {
                    if let current = entry.versions.first(where: \.isCurrent) {
                        versionMetadata(current)
                        Text(availableModes(current)).font(.subheadline).foregroundStyle(.secondary)
                    }
                    ForEach(entry.versions.filter { !$0.isCurrent && $0.state == .ready }) { version in
                        Divider()
                        versionMetadata(version)
                        versionState(version, entry: entry)
                    }
                }.padding(.top, 8)
            }.font(.subheadline).accessibilityIdentifier("library-other-versions")
        }.libraryCard()
    }

    private func showsCompanyContinuation(_ choice: ShelfContinuationChoice) -> Bool {
        if let active = workspace.activeReading { return active.study.identity != choice.identity }
        return workspace.shelf.recommendedContinuation != choice
    }

    private func versionMetadata(_ version: ShelfVersionEntry) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(coverage(version.financialPeriodStart, version.financialPeriodEnd))
                .font(.subheadline).fixedSize(horizontal: false, vertical: true)
            Text("资料截至 " + version.researchAsOf + " · 第 \(version.reportRevision) 版" + (version.isCurrent ? " · 当前版本" : ""))
                .font(.caption).foregroundStyle(.secondary)
        }
    }

    @ViewBuilder private func versionState(_ version: ShelfVersionEntry, entry: ShelfEntry) -> some View {
        switch version.state {
        case .ready:
            ViewThatFits(in: .horizontal) {
                HStack(spacing: 12) {
                    offlineState
                    Spacer(minLength: 0)
                    openVersion(version, entry: entry)
                }
                VStack(alignment: .leading, spacing: 8) {
                    offlineState
                    openVersion(version, entry: entry)
                }
            }
        case .preparing:
            ProgressView("正在准备完整研究…").font(.subheadline)
        case .waiting:
            Label("等待取得完整研究", systemImage: "arrow.down.circle").font(.subheadline).foregroundStyle(.secondary)
        case .failed(let reason):
            Label("这份研究暂时未能准备完整", systemImage: "exclamationmark.circle").font(.subheadline)
            Text(reason).font(.footnote).foregroundStyle(.secondary).textSelection(.enabled)
            Button("重新准备") { Task { await workspace.shelf.retryPreparation(version.id) } }
                .frame(minHeight: 44).accessibilityIdentifier("library-retry-preparation")
        }
    }

    private var offlineState: some View {
        Label("可离线阅读", systemImage: "checkmark.circle.fill").font(.caption).foregroundStyle(.secondary)
    }

    private func openVersion(_ version: ShelfVersionEntry, entry: ShelfEntry) -> some View {
        Button { workspace.open(version.id) } label: {
            HStack(spacing: 8) {
                Text(version.isCurrent ? (entry.hasUpdate ? "阅读新版" : "打开研究") : "打开这个版本")
                Image(systemName: "chevron.right").font(.caption.weight(.semibold)).accessibilityHidden(true)
            }.frame(minHeight: 44)
        }.buttonStyle(.plain).font(.subheadline.weight(.medium)).foregroundStyle(Color.accentColor)
            .accessibilityIdentifier(version.isCurrent ? "library-open-current" : "library-open-version")
    }
}

private extension View {
    func libraryCard() -> some View {
        padding(20).frame(maxWidth: .infinity, alignment: .leading).multilineTextAlignment(.leading)
            .background(StudyInk.card, in: RoundedRectangle(cornerRadius: 24))
    }
}
