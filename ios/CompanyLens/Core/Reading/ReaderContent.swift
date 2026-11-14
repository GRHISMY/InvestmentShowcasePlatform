import Foundation

/// Concrete published-content resolution. It never chooses navigation or record order.
struct ReaderContent {
    let study: ReadableStudy
    var entrySceneID: String? { study.reading?.document.entrySceneId }
    var diagramAnchors: [ReadingAnchor] {
        [ReadingAnchor(id: "heading", label: "当前问题"), ReadingAnchor(id: "diagram", label: "图解"),
         ReadingAnchor(id: "explanation", label: "焦点解释"), ReadingAnchor(id: "limits", label: "适用边界")]
    }

    func scene(_ location: ReaderLocation) -> ReadingScene? {
        guard case .diagram(let id, _) = location.address else { return nil }
        return study.reading?.scene(id)
    }

    func focus(_ location: ReaderLocation) -> ReadingFocus? {
        guard case .diagram(let id, let selected) = location.address,
              let scene = study.reading?.scene(id) else { return nil }
        return study.reading?.focus(study.reading?.validFocus(selected, in: id) ?? scene.defaultFocusId)
    }

    func primary(_ state: ReaderNavigationState, access: ReaderAccess) -> StudyReaderPage {
        let visit = state.current
        if case .report = visit.location.address { return .report(report(visit, access: access)) }
        guard let scene = scene(visit.location), let reading = study.reading,
              let raw = reading.view(scene.viewId), let focus = focus(visit.location) else {
            return .overview(overview(state, access: access))
        }
        let context = DetailContext.focus(sceneID: scene.id, focusID: focus.id)
        let choices = Dictionary(uniqueKeysWithValues: scene.focusIds.map { ($0, access.choice($0, sceneID: scene.id)) })
        return .diagram(DiagramPage(visitID: visit.location.visitID,
            sceneID: scene.id, section: scene.section, title: scene.title, question: scene.question,
            ordinal: (reading.document.sceneOrder.firstIndex(of: scene.id) ?? 0) + 1,
            sceneCount: reading.orderedScenes.count,
            diagram: ReaderDiagram(raw: raw, periods: study.research.research.periods, choices: choices),
            focus: FocusContent(id: focus.id, title: focus.title, body: focus.body, caveat: focus.caveat,
                gaps: focus.gaps, hasCounterEvidence: !focus.counterEvidenceIds.isEmpty,
                explanation: access.link(.explanation(context)),
                calculations: focus.calculationIds.isEmpty ? nil : access.link(.calculations(context)),
                evidence: focus.evidenceIds.isEmpty ? nil : access.link(.evidence(context))),
            essentialNotes: scene.essentialNotes, overview: access.link(.overview), nextLabel: scene.nextLabel,
            isMainlineEnd: scene.nextSceneId == nil, observation: access.observation, anchors: diagramAnchors,
            restorePosition: visit.location.position ?? ReadingPosition(anchorID: "heading"), arrivalCause: visit.arrivalCause,
            relatedReports: relatedReports(visit.location, access: access)))
    }

    private func overview(_ state: ReaderNavigationState, access: ReaderAccess) -> OverviewPage {
        let reading = study.reading
        let research = study.research.research
        var resumeID = entrySceneID ?? ""
        if let origin = state.overviewOrigin, case .diagram(let id, _) = origin.address { resumeID = id }
        return OverviewPage(visitID: state.current.location.visitID,
            title: reading?.document.overview.title ?? research.company.name,
            summary: reading?.document.overview.summary ?? research.report.summary,
            company: research.company, coverage: research.report.coverage,
            researchAsOf: research.report.researchAsOf, coverageMode: reading?.document.coverage.mode ?? "complete",
            entries: reading?.document.overview.entries.map {
                OverviewEntry(sceneID: $0.sceneId, label: $0.label, caption: $0.caption, icon: $0.icon,
                    link: access.link(.scene($0.sceneId)))
            } ?? [], beginOrResume: access.link(.scene(resumeID)), restart: access.link(.restart),
            observation: access.observation, anchors: [ReadingAnchor(id: "overview", label: "研究全貌")],
            restorePosition: state.current.location.position ?? ReadingPosition(anchorID: "overview"),
            arrivalCause: state.current.arrivalCause)
    }

    func legacy(_ visit: LegacyVisit) -> LegacyReadingPresentation {
        var focus: ReadingFocus?
        var claim: ResearchClaim?
        var sourceScene: ReadingScene?
        switch visit.context {
        case .focus(let sceneID, let focusID):
            focus = study.reading?.focus(focusID)
            sourceScene = study.reading?.scene(sceneID)
        case .claim(let id): claim = study.research.claim(id)
        }
        let notes = claim.map { $0.limitations + $0.gaps.map(\.description) }
            ?? ([focus?.caveat ?? ""] + (sourceScene?.essentialNotes ?? []))
        var seen = Set<String>()
        let caveat = notes.filter { !$0.isEmpty && seen.insert($0).inserted }.joined(separator: "\n")
        return LegacyReadingPresentation(kind: visit.kind, study: study,
            title: claim?.title ?? focus?.title ?? "完整报告",
            text: claim?.plainLanguage ?? focus?.body ?? study.research.research.report.summary,
            caveat: caveat,
            calculations: claim.map { study.research.calculations(for: $0) }
                ?? focus?.calculationIds.compactMap(study.research.calculation) ?? [],
            evidence: (claim.map { claimEvidenceIDs($0) } ?? focus?.evidenceIds ?? []).compactMap(study.research.evidence),
            counterEvidenceIDs: claim.map { $0.evidenceLinks.filter { $0.relation == "contradicts" }.map(\.evidenceId) }
                ?? focus?.counterEvidenceIds ?? [],
            claims: claim.map { [$0] } ?? focus?.conclusionIds.compactMap(study.research.claim) ?? study.research.orderedClaims,
            presentationToken: visit.token, observation: visit.observation,
            anchors: [ReadingAnchor(id: "detail", label: "核对内容")],
            restorePosition: visit.position ?? ReadingPosition(anchorID: "detail"))
    }

    func anchors(_ address: ReaderAddress) -> [ReadingAnchor] {
        switch address {
        case .overview: return [ReadingAnchor(id: "overview", label: "研究全貌")]
        case .diagram: return diagramAnchors
        case .report: return reportAnchors
        }
    }

    func validPosition(_ position: ReadingPosition?, address: ReaderAddress) -> ReadingPosition? {
        guard let position, anchors(address).contains(where: { $0.id == position.anchorID }) else { return nil }
        let offset = position.localOffset.flatMap { $0.isFinite && $0 >= 0 ? $0 : nil }
        return ReadingPosition(anchorID: position.anchorID, localOffset: offset)
    }

    func sanitized(_ location: ReaderLocation) -> ReaderLocation? {
        var result = location
        if case .diagram(let sceneID, let selected) = location.address {
            guard let reading = study.reading, reading.scene(sceneID) != nil else { return nil }
            let focus = reading.validFocus(selected, in: sceneID)
            result.address = .diagram(sceneID: sceneID, focusID: focus)
            result.position = validPosition(location.position, address: result.address)
            if selected != nil && focus == nil, let position = result.position,
               ["explanation", "limits"].contains(position.anchorID) {
                result.position = ReadingPosition(anchorID: position.anchorID)
            }
        } else { result.position = validPosition(location.position, address: location.address) }
        return result
    }
}
