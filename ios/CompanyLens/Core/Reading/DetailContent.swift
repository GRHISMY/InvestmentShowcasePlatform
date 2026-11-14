import Foundation

extension ReaderContent {
    func validDetailPosition(_ saved: DetailPosition) -> DetailPosition? {
        guard let context = saved.address.context else { return nil }
        switch context {
        case .claim(let id): guard study.research.claim(id) != nil else { return nil }
        case .focus(let sceneID, let focusID):
            guard study.reading?.validFocus(focusID, in: sceneID) != nil else { return nil }
        }
        if case .evidence(_, let selected) = saved.address,
           selected?.contains(where: { study.research.evidence($0) == nil }) == true { return nil }
        let visit = DetailVisit(address: saved.address,
            token: PresentationToken(reader: UUID(), presentation: UUID()))
        guard detailAnchors(visit, readerID: UUID()).contains(where: { $0.id == saved.position.anchorID }) else { return nil }
        let offset = saved.position.localOffset.flatMap { $0.isFinite && $0 >= 0 ? $0 : nil }
        return DetailPosition(address: saved.address,
            position: ReadingPosition(anchorID: saved.position.anchorID, localOffset: offset))
    }
    func detailAnchors(_ visit: DetailVisit, readerID: UUID) -> [ReadingAnchor] {
        switch detail(visit, readerID: readerID) {
        case .explanation(let page): return page.anchors
        case .calculations(let page): return page.anchors
        case .evidence(let page): return page.anchors
        case .pdf: return []
        }
    }
    func document(_ sourceID: String, access: ReaderAccess) -> PDFDocumentContent? {
        guard let source = study.research.research.sources.first(where: { $0.id == sourceID }),
              let file = try? study.resources.pdfURL(sourceID: sourceID) else { return nil }
        let period = study.research.research.periods.first { $0.id == source.reportPeriodId }?.label ?? ""
        return PDFDocumentContent(id: source.id, title: source.title, period: period,
            pageCount: source.pdfPages, fileURL: file, resume: access.document(source.id))
    }

    func citations(_ evidenceID: String, access: ReaderAccess) -> [CitationContent] {
        study.research.pages(for: evidenceID).compactMap { page in
            guard let document = document(page.sourceId, access: access) else { return nil }
            return CitationContent(id: page.id, title: page.title, period: page.period,
                physicalPage: page.physicalPage, target: access.citation(page), document: document)
        }
    }

    func detail(_ visit: DetailVisit, readerID: UUID, pdfResumes: [String: Int] = [:]) -> ReadingDetailPage {
        let access = visit.access(readerID: readerID)
        if case .pdf(let sourceID) = visit.address, let pdf = visit.pdf,
           let document = document(sourceID, access: access) {
            let citation = pdf.citation.map {
                CitationContent(id: $0.id, title: document.title, period: document.period,
                    physicalPage: $0.physicalPage, target: access.citation($0), document: document)
            }
            return .pdf(PDFReadingPage(visitID: visit.visitID, document: document, currentCitation: citation,
                visiblePhysicalPage: pdf.visiblePhysicalPage, resumePhysicalPage: pdfResumes[sourceID],
                loadState: pdf.loadState, request: pdf.request))
        }
        guard let context = visit.address.context else { preconditionFailure("PDF visit requires its reading state") }
        let resolved = resolve(context)
        let initialAnchors = [ReadingAnchor(id: "detail", label: resolved.title)]
        switch visit.address {
        case .explanation:
            return .explanation(ExplanationReadingPage(visitID: visit.visitID, title: resolved.title,
                text: resolved.text, caveat: resolved.caveat, observation: access.observation,
                anchors: initialAnchors, restorePosition: visit.position ?? ReadingPosition(anchorID: "detail"),
                arrivalCause: visit.arrivalCause))
        case .calculations(let context):
            let items = resolved.calculations.map { calculation in
                CalculationContent(calculation: calculation, inputs: calculation.inputs.enumerated().compactMap { index, input in
                    guard let fact = study.research.fact(input.factId) else { return nil }
                    let data = study.research.research
                    let id = calculation.id + "/input/" + String(index)
                    let label = calculation.operation == "linear_combination"
                        ? (input.coefficient == "1" ? (index == 0 ? "先取" : "加上") : input.coefficient == "-1" ? "减去" : "乘以 " + input.coefficient)
                        : "原始输入 " + String(index + 1)
                    return CalculationInputContent(id: id, ordinal: index + 1,
                        coefficient: input.coefficient, operationLabel: label,
                        fact: ReportFactContent(fact: fact,
                            entityName: data.entities.first { $0.id == fact.entityId }?.name ?? "",
                            periodLabel: data.periods.first { $0.id == fact.periodId }?.label ?? ""),
                        evidence: fact.evidenceIds.compactMap { id in
                            guard let evidence = study.research.evidence(id) else { return nil }
                            return EvidenceReference(id: id, title: evidence.locatorNote,
                                link: access.link(.evidenceSelection(context, [id])))
                        }, citations: fact.evidenceIds.flatMap { citations($0, access: access) },
                        anchor: ReadingAnchor(id: id, label: fact.label))
                }, anchor: ReadingAnchor(id: "calculation/" + calculation.id, label: calculation.title))
            }
            let anchors = [ReadingAnchor(id: "detail", label: resolved.title)] + items.flatMap { [$0.anchor] + $0.inputs.map(\.anchor) }
            return .calculations(CalculationReadingPage(visitID: visit.visitID, title: resolved.title,
                items: items, observation: access.observation, anchors: anchors,
                restorePosition: visit.position ?? ReadingPosition(anchorID: "detail"), arrivalCause: visit.arrivalCause))
        case .evidence(_, let selected):
            let evidence = selected.map { $0.compactMap(study.research.evidence) } ?? resolved.evidence
            let items = evidence.compactMap { evidence -> EvidenceContent? in
                guard let source = document(evidence.sourceId, access: access) else { return nil }
                let uses = resolved.claims.flatMap { claim in
                    claim.evidenceLinks.filter { $0.evidenceId == evidence.id }.map {
                        EvidenceUse(claimTitle: claim.title, relation: $0.relation, explanation: $0.explanation)
                    }
                }
                return EvidenceContent(evidence: evidence, source: source, uses: uses,
                    isCounterEvidence: resolved.counterEvidenceIDs.contains(evidence.id) || uses.contains { $0.relation == "contradicts" },
                    citations: citations(evidence.id, access: access),
                    anchor: ReadingAnchor(id: "evidence/" + evidence.id, label: evidence.locatorNote))
            }
            let anchors = initialAnchors + items.map(\.anchor)
            return .evidence(EvidenceReadingPage(visitID: visit.visitID, title: resolved.title, items: items,
                observation: access.observation, anchors: anchors,
                restorePosition: visit.position ?? ReadingPosition(anchorID: "detail"), arrivalCause: visit.arrivalCause))
        case .pdf: preconditionFailure("Validated PDF visits always retain their fixed document")
        }
    }
}
