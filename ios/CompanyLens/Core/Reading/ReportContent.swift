import Foundation

extension ReaderContent {
    var summaryAnchor: ReadingAnchor { ReadingAnchor(id: "report/summary", label: "完整研究摘要") }
    var limitationsAnchor: ReadingAnchor? {
        study.research.research.report.limitations.isEmpty ? nil : ReadingAnchor(id: "report/limits", label: "研究限制")
    }

    func claimAnchors(_ claim: ResearchClaim) -> [ReportClaimPart: ReadingAnchor] {
        var parts: [ReportClaimPart] = [.heading, .known, .meaning]
        if !claim.gaps.isEmpty { parts.append(.gaps) }
        if !claim.alternatives.isEmpty { parts.append(.alternatives) }
        if !claim.reasoning.isEmpty { parts.append(.reasoning) }
        if !claim.limitations.isEmpty { parts.append(.limitations) }
        if !claim.changeConditions.isEmpty { parts.append(.changeConditions) }
        if !claim.factIds.isEmpty { parts.append(.facts) }
        return Dictionary(uniqueKeysWithValues: parts.map {
            ($0, ReadingAnchor(id: "claim/" + claim.id + "/" + $0.rawValue, label: claim.title))
        })
    }

    var reportAnchors: [ReadingAnchor] {
        var result = [summaryAnchor]
        for section in study.research.sections {
            result.append(ReadingAnchor(id: "section/" + section.id, label: section.title))
            for claim in section.conclusionIds.compactMap(study.research.claim) {
                let anchors = claimAnchors(claim)
                result += ReportClaimPart.allCases.compactMap { anchors[$0] }
            }
        }
        if let limitationsAnchor { result.append(limitationsAnchor) }
        result += study.research.orderedDimensions.map { ReadingAnchor(id: "dimension/" + $0.id, label: $0.title) }
        result += study.research.research.monitoring.map { ReadingAnchor(id: "monitoring/" + $0.id, label: $0.description) }
        return result
    }

    func claimLink(_ claim: ResearchClaim, access: ReaderAccess) -> ReportClaimLink {
        ReportClaimLink(id: claim.id, title: claim.title, summary: claim.plainLanguage, link: access.link(.reportClaim(claim.id)))
    }

    func relatedReports(_ location: ReaderLocation, access: ReaderAccess) -> [ReportClaimLink] {
        let ids = (focus(location)?.conclusionIds ?? []) + (scene(location)?.conclusionIds ?? [])
        var seen = Set<String>()
        return ids.filter { seen.insert($0).inserted }.compactMap(study.research.claim).map { claimLink($0, access: access) }
    }

    func relatedDiagrams(_ claim: ResearchClaim, access: ReaderAccess) -> [RelatedDiagramLink] {
        guard let reading = study.reading else { return [] }
        return reading.orderedScenes.flatMap { scene -> [RelatedDiagramLink] in
            let matched = scene.focusIds.filter { reading.focus($0)?.conclusionIds.contains(claim.id) == true }
            let targets = matched.isEmpty && scene.conclusionIds.contains(claim.id) ? [scene.defaultFocusId] : matched
            return targets.compactMap { id in
                guard let focus = reading.focus(id) else { return nil }
                return RelatedDiagramLink(id: String(scene.id.utf8.count) + ":" + scene.id + id,
                    sceneID: scene.id, sceneTitle: scene.title, section: scene.section, question: scene.question,
                    focusID: id, focusTitle: focus.title, link: access.link(.diagram(sceneID: scene.id, focusID: id)))
            }
        }
    }

    func claimEvidenceIDs(_ claim: ResearchClaim) -> [String] {
        var ids = claim.evidenceLinks.map(\.evidenceId)
        ids += study.research.facts(for: claim).flatMap(\.evidenceIds)
        ids += study.research.calculations(for: claim).flatMap(\.inputs)
            .compactMap { study.research.fact($0.factId) }.flatMap(\.evidenceIds)
        var seen = Set<String>()
        return ids.filter { seen.insert($0).inserted }
    }

    func report(_ visit: ReaderVisit, access: ReaderAccess) -> ReportPage {
        let library = study.research
        let data = library.research
        let sections = library.sections.map { section in
            ReportSectionContent(id: section.id, title: section.title,
                anchor: ReadingAnchor(id: "section/" + section.id, label: section.title),
                claims: section.conclusionIds.compactMap(library.claim).map { claim in
                    ReportClaimContent(claim: claim, scope: library.scope(of: claim),
                        facts: library.facts(for: claim).map { fact in
                            ReportFactContent(fact: fact,
                                entityName: data.entities.first { $0.id == fact.entityId }?.name ?? "",
                                periodLabel: data.periods.first { $0.id == fact.periodId }?.label ?? "")
                        }, calculations: claim.calculationIds.isEmpty ? nil : access.link(.calculations(.claim(claim.id))),
                        evidence: claimEvidenceIDs(claim).isEmpty ? nil : access.link(.evidence(.claim(claim.id))),
                        relatedDiagrams: relatedDiagrams(claim, access: access), partAnchors: claimAnchors(claim))
                })
        }
        return ReportPage(visitID: visit.location.visitID, title: data.company.name + " · 完整研究",
            company: data.company, coverage: data.report.coverage, researchAsOf: data.report.researchAsOf,
            revision: data.report.revision, summary: data.report.summary, limitations: data.report.limitations,
            headlineClaims: library.headlineClaims.map { claimLink($0, access: access) },
            contents: library.orderedClaims.map { claimLink($0, access: access) }, sections: sections,
            dimensions: library.orderedDimensions.map {
                ReportDimensionContent(id: $0.id, title: $0.title, summary: $0.summary,
                    anchor: ReadingAnchor(id: "dimension/" + $0.id, label: $0.title),
                    claims: $0.conclusionIds.compactMap(library.claim).map { claimLink($0, access: access) })
            }, monitoring: data.monitoring.map {
                ReportMonitoringContent(id: $0.id, description: $0.description, status: $0.status,
                    anchor: ReadingAnchor(id: "monitoring/" + $0.id, label: $0.description),
                    claims: $0.conclusionIds.compactMap(library.claim).map { claimLink($0, access: access) })
            }, summaryAnchor: summaryAnchor, limitationsAnchor: limitationsAnchor,
            observation: access.observation, anchors: reportAnchors,
            restorePosition: visit.location.position ?? ReadingPosition(anchorID: summaryAnchor.id), arrivalCause: visit.arrivalCause)
    }
}
