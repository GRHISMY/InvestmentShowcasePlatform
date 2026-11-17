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
import UIKit
private struct ReportDocumentAppearance: Equatable {
    let dynamicTypeSize: DynamicTypeSize
    let colorScheme: ColorScheme
    let contrast: ColorSchemeContrast
    let direction: LayoutDirection
    let locale: String
    let legibility: LegibilityWeight?
    let enabled: Bool
    let buttonShapes: Bool
    init(_ values: EnvironmentValues) {
        dynamicTypeSize = values.dynamicTypeSize; colorScheme = values.colorScheme
        contrast = values.colorSchemeContrast; direction = values.layoutDirection
        locale = values.locale.identifier; legibility = values.legibilityWeight
        enabled = values.isEnabled; buttonShapes = values.accessibilityShowButtonShapes
    }
}

private final class ReportNativeCollectionView: UICollectionView {
    var onLayoutStarted: ((CGSize) -> Void)?
    var onLayout: (() -> Void)?
    var onAccessibilityBrowsing: (() -> Void)?
    override func layoutSubviews() {
        onLayoutStarted?(bounds.size)
        super.layoutSubviews()
        onLayout?()
    }
    override func accessibilityScroll(_ direction: UIAccessibilityScrollDirection) -> Bool {
        let step: CGFloat
        switch direction {
        case .down: step = bounds.height * 0.8
        case .up: step = -bounds.height * 0.8
        default: return super.accessibilityScroll(direction)
        }
        let target = min(max(0, contentSize.height - bounds.height), max(0, contentOffset.y + step))
        guard target != contentOffset.y else { return false }
        setContentOffset(CGPoint(x: contentOffset.x, y: target), animated: false)
        layoutIfNeeded(); onAccessibilityBrowsing?()
        UIAccessibility.post(notification: .pageScrolled, argument: nil)
        return true
    }
}

/// Each cell owns its native hosting controller so safe-area geometry stays
/// fixed while it crosses the viewport. The document already owns its insets.
private final class ReportDocumentCell: UICollectionViewCell {
    private let hosting = UIHostingController(rootView: AnyView(EmptyView()))
    override init(frame: CGRect) {
        super.init(frame: frame)
        backgroundColor = .clear
        hosting.safeAreaRegions = []
        hosting.sizingOptions = [.intrinsicContentSize]
        hosting.view.backgroundColor = .clear
        hosting.view.translatesAutoresizingMaskIntoConstraints = false
        contentView.addSubview(hosting.view)
        NSLayoutConstraint.activate([
            hosting.view.leadingAnchor.constraint(equalTo: contentView.leadingAnchor),
            hosting.view.trailingAnchor.constraint(equalTo: contentView.trailingAnchor),
            hosting.view.topAnchor.constraint(equalTo: contentView.topAnchor),
            hosting.view.bottomAnchor.constraint(equalTo: contentView.bottomAnchor)
        ])
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    func render(_ root: AnyView, in parent: UIViewController) {
        if hosting.parent !== parent {
            parent.addChild(hosting); hosting.didMove(toParent: parent)
        }
        hosting.rootView = root
        hosting.view.invalidateIntrinsicContentSize()
        setNeedsLayout()
    }
    override func preferredLayoutAttributesFitting(_ attributes: UICollectionViewLayoutAttributes) -> UICollectionViewLayoutAttributes {
        let result = attributes.copy() as! UICollectionViewLayoutAttributes
        let size = hosting.sizeThatFits(in: CGSize(width: attributes.size.width, height: CGFloat.greatestFiniteMagnitude))
        result.size.height = ceil(size.height)
        return result
    }
}

/// Owns a genuine native viewport. Report content and opaque actions are immutable
/// during a render activation; observations only replace the current callback.
/// A renewed activation or a changed text/layout environment refreshes the bodies.
@MainActor
final class ReportDocumentController: UIViewController, UICollectionViewDataSource, UICollectionViewDelegate {
    private let collection: ReportNativeCollectionView
    private var scope: ReadingDocumentScope?
    private var blocks: [ReportDocumentBlock] = []
    private var rows: [[ReportDocumentBlock]] = []
    private var rowForAnchor: [String: Int] = [:]
    private var target: ReadingScrollPosition?
    private var environment: EnvironmentValues?
    private var appearance: ReportDocumentAppearance?
    private var arrived = false
    private var arrivalInterrupted = false
    private var positioning = false
    private var requestedTargetRow = false
    private var stablePasses = 0
    private var correctionPasses = 0
    private var scheduledScope: UUID?
    private var lastLayoutSize: CGSize?
    private var lastVisiblePosition: ReadingScrollPosition?
    private var onObservation: (ReadingScrollObservation) -> Void = { _ in }

    init() {
        let item = NSCollectionLayoutItem(layoutSize: .init(widthDimension: .fractionalWidth(1), heightDimension: .estimated(240)))
        let group = NSCollectionLayoutGroup.vertical(layoutSize: .init(widthDimension: .fractionalWidth(1), heightDimension: .estimated(240)), subitems: [item])
        let configuration = UICollectionViewCompositionalLayoutConfiguration()
        configuration.contentInsetsReference = .none
        collection = ReportNativeCollectionView(frame: .zero,
            collectionViewLayout: UICollectionViewCompositionalLayout(section: NSCollectionLayoutSection(group: group), configuration: configuration))
        super.init(nibName: nil, bundle: nil)
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    override func loadView() {
        view = collection
        collection.backgroundColor = .clear
        collection.contentInsetAdjustmentBehavior = .never
        collection.dataSource = self; collection.delegate = self
        collection.register(ReportDocumentCell.self, forCellWithReuseIdentifier: "report-body")
        collection.onLayoutStarted = { [weak self] size in self?.prepareForLayout(size: size) }
        collection.onLayout = { [weak self] in
            guard let self else { return }
            if self.arrived, self.target == nil {
                self.lastVisiblePosition = self.observation(cause: .arrival)?.position
            }
            self.scheduleMeasurement()
        }
        collection.onAccessibilityBrowsing = { [weak self] in self?.reportUserBrowsing() }
    }

    func render(renderID: AnyHashable, target: ReadingScrollPosition?, blocks: [ReportDocumentBlock],
                environment: EnvironmentValues? = nil,
                onObservation: @escaping (ReadingScrollObservation) -> Void) {
        loadViewIfNeeded()
        let nextAppearance = environment.map(ReportDocumentAppearance.init)
        self.onObservation = onObservation
        collection.delegate = self
        if scope?.renderID != renderID {
            self.scope?.anchors.onChange = nil
            let scope = ReadingDocumentScope(renderID: renderID)
            self.scope = scope; self.blocks = blocks
            rows = []
            for block in blocks {
                // An unanchored heading still belongs to its preceding authored
                // anchor. Keep that actual marker realized while the gap is visible.
                if block.anchors.isEmpty, !rows.isEmpty { rows[rows.count - 1].append(block) }
                else { rows.append([block]) }
            }
            rowForAnchor = Dictionary(uniqueKeysWithValues: rows.enumerated().flatMap { row, blocks in
                blocks.flatMap { $0.anchors.map { ($0, row) } }
            })
            self.target = target; self.environment = environment; appearance = nextAppearance
            arrived = false; arrivalInterrupted = false; requestedTargetRow = false; stablePasses = 0; correctionPasses = 0
            lastVisiblePosition = nil; lastLayoutSize = collection.bounds.size
            let id = scope.id
            scope.anchors.onChange = { [weak self] in
                guard self?.scope?.id == id else { return }
                self?.scheduleMeasurement()
            }
            collection.reloadData()
            collection.setNeedsLayout()
        } else if appearance != nextAppearance {
            // Reflow retains the actual semantic viewport without creating a
            // browsing observation or renewing the reader's restoration arrival.
            // Reflow may arrive before a directed target has been displayed.
            // Its requested semantic position outranks transient initial geometry.
            let preserved = self.target ?? lastVisiblePosition ?? observation(cause: .arrival)?.position
            self.environment = environment; appearance = nextAppearance
            for path in collection.indexPathsForVisibleItems {
                if let cell = collection.cellForItem(at: path) { configure(cell, row: path.item) }
            }
            collection.collectionViewLayout.invalidateLayout()
            if let preserved { preserveViewport(at: preserved) }
        }
        scheduleMeasurement()
    }

    func collectionView(_ collectionView: UICollectionView, numberOfItemsInSection section: Int) -> Int { rows.count }
    func collectionView(_ collectionView: UICollectionView, cellForItemAt indexPath: IndexPath) -> UICollectionViewCell {
        let cell = collectionView.dequeueReusableCell(withReuseIdentifier: "report-body", for: indexPath)
        configure(cell, row: indexPath.item)
        return cell
    }
    private func configure(_ cell: UICollectionViewCell, row: Int) {
        guard let scope, rows.indices.contains(row) else { return }
        let blocks = rows[row], first = row == 0, last = row == rows.count - 1
        let environment = self.environment
        guard let cell = cell as? ReportDocumentCell else { return }
        cell.render(AnyView(
            ReportHostedBlock(blocks: blocks, scope: scope, environment: environment)
                .padding(.horizontal, 24).padding(.top, first ? 24 : 0).padding(.bottom, last ? 24 : 0)
        ), in: self)
    }

    private func prepareForLayout(size: CGSize) {
        defer { lastLayoutSize = size }
        guard let previous = lastLayoutSize, previous.width != size.width,
              arrived, let position = lastVisiblePosition else { return }
        // UIKit changes bounds before laying out the cells. Geometry measured
        // now can mix old row heights with the new viewport, so retain the last
        // settled semantic position rather than an absolute document offset.
        preserveViewport(at: position)
    }

    private func preserveViewport(at position: ReadingScrollPosition) {
        target = position
        requestedTargetRow = false
        stablePasses = 0
        correctionPasses = 0
    }

    private func scheduleMeasurement() {
        guard let scope, scheduledScope != scope.id, !positioning else { return }
        let id = scope.id; scheduledScope = id
        DispatchQueue.main.async { [weak self] in
            guard let self, self.scheduledScope == id else { return }
            self.scheduledScope = nil
            guard self.scope?.id == id else { return }
            self.collection.layoutIfNeeded()
            self.correctTargetAndConfirmArrival()
        }
    }
    private var hasVisibleLayout: Bool {
        guard let window = view.window, !window.isHidden,
              collection.bounds.width > 0, collection.bounds.height > 0,
              collection.contentSize.height > 0 else { return false }
        var ancestor: UIView? = view
        while let current = ancestor {
            if current.isHidden || current.alpha == 0 { return false }
            ancestor = current.superview
        }
        return true
    }
    private func correctTargetAndConfirmArrival() {
        guard !positioning, hasVisibleLayout, let scope, !blocks.isEmpty else { return }
        guard !arrived || target != nil else { return }
        if arrivalInterrupted { acceptActualArrival(); return }
        let target = target ?? ReadingScrollPosition(anchorID: blocks.flatMap(\.anchors).first ?? "")
        guard let row = rowForAnchor[target.anchorID] else { return }
        positioning = true
        defer { positioning = false }
        if !requestedTargetRow {
            requestedTargetRow = true
            collection.scrollToItem(at: IndexPath(item: row, section: 0), at: .top, animated: false)
            collection.layoutIfNeeded()
        }
        guard let anchor = scope.anchors.measure(in: collection).first(where: { $0.id == target.anchorID }) else {
            return
        }
        let offset = target.localOffset.isFinite ? max(0, target.localOffset) : 0
        let maximum = max(0, collection.contentSize.height - collection.bounds.height)
        let desired = min(maximum, max(0, anchor.frame.minY + offset))
        let delta = desired - collection.contentOffset.y
        correctionPasses += 1
        if abs(delta) > 0.5 {
            stablePasses = 0
            collection.setContentOffset(CGPoint(x: 0, y: desired), animated: false)
            collection.layoutIfNeeded()
        } else { stablePasses += 1 }
        if stablePasses >= 2 {
            self.target = nil
            if let event = observation(cause: .arrival) {
                lastVisiblePosition = event.position
                if !arrived { arrived = true; onObservation(event) }
            }
        } else if correctionPasses < 16 {
            let id = scope.id
            DispatchQueue.main.async { [weak self] in
                guard self?.scope?.id == id else { return }
                self?.scheduleMeasurement()
            }
        }
    }
    private func observation(cause: ReadingScrollObservation.Cause) -> ReadingScrollObservation? {
        guard let scope else { return nil }
        let anchors = scope.anchors.measure(in: collection).sorted { $0.frame.minY < $1.frame.minY }
        let viewport = collection.bounds
        guard let anchor = anchors.last(where: { $0.frame.minY <= viewport.minY })
                ?? anchors.first(where: { $0.frame.intersects(viewport) }) else { return nil }
        return ReadingScrollObservation(renderID: scope.renderID,
            position: ReadingScrollPosition(anchorID: anchor.id, localOffset: max(0, viewport.minY - anchor.frame.minY)), cause: cause)
    }
    private func acceptActualArrival() {
        guard !arrived, hasVisibleLayout, let event = observation(cause: .arrival) else { return }
        target = nil
        arrivalInterrupted = false
        arrived = true
        lastVisiblePosition = event.position
        onObservation(event)
    }

    private func reportUserBrowsing() {
        guard !positioning, hasVisibleLayout, let scope else { return }
        // Native input owns the viewport even if self-sizing has not yet
        // completed its queued restoration confirmation.
        target = nil
        if !arrived {
            arrivalInterrupted = true
            acceptActualArrival()
        }
        guard self.scope?.id == scope.id, arrived else { return }
        if let event = observation(cause: .userBrowsing) {
            lastVisiblePosition = event.position
            onObservation(event)
        }
    }
    func scrollViewWillBeginDragging(_ scrollView: UIScrollView) {
        target = nil
        if !arrived {
            arrivalInterrupted = true
            acceptActualArrival()
        }
    }
    func scrollViewDidScroll(_ scrollView: UIScrollView) {
        guard scrollView.isTracking || scrollView.isDragging || scrollView.isDecelerating else { return }
        reportUserBrowsing()
    }
    func scrollViewDidEndDragging(_ scrollView: UIScrollView, willDecelerate decelerate: Bool) {
        if !decelerate { reportUserBrowsing() }
    }
    func scrollViewDidEndDecelerating(_ scrollView: UIScrollView) { reportUserBrowsing() }
    func scrollViewDidScrollToTop(_ scrollView: UIScrollView) { reportUserBrowsing() }
    func stopObserving() {
        scope?.anchors.onChange = nil; scope = nil; scheduledScope = nil
        arrived = false; arrivalInterrupted = false; target = nil; lastVisiblePosition = nil; lastLayoutSize = nil
        onObservation = { _ in }; collection.delegate = nil
    }
}

private struct ReportHostedBlock: View {
    let blocks: [ReportDocumentBlock]
    let scope: ReadingDocumentScope
    let environment: EnvironmentValues?
    var body: some View {
        Group {
            if let environment { content.environment(\.self, environment) }
            else { content }
        }.environment(\.readingDocumentScope, scope)
    }
    private var content: some View {
        VStack(alignment: .leading, spacing: 0) {
            ForEach(blocks) { $0.content() }
        }.font(.body).foregroundStyle(.primary)
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: 620, alignment: .leading)
            .frame(maxWidth: .infinity, alignment: .center).textSelection(.enabled).ignoresSafeArea()
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
