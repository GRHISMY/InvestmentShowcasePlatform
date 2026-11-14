import Foundation

struct ResolvedDetailContext {
    let title, text, caveat: String
    let calculations: [ResearchCalculation]
    let evidence: [ResearchEvidence]
    let counterEvidenceIDs: [String]
    let claims: [ResearchClaim]
}

extension ReaderContent {
    func resolve(_ context: DetailContext) -> ResolvedDetailContext {
        var focus: ReadingFocus?
        var claim: ResearchClaim?
        var sourceScene: ReadingScene?
        switch context {
        case .focus(let sceneID, let focusID):
            focus = study.reading?.focus(focusID)
            sourceScene = study.reading?.scene(sceneID)
        case .claim(let id): claim = study.research.claim(id)
        }
        let notes = claim.map { $0.limitations + $0.gaps.map(\.description) }
            ?? ([focus?.caveat ?? ""] + (sourceScene?.essentialNotes ?? []))
        var seen = Set<String>()
        let caveat = notes.filter { !$0.isEmpty && seen.insert($0).inserted }.joined(separator: "\n")
        return ResolvedDetailContext(
            title: claim?.title ?? focus?.title ?? "完整报告",
            text: claim?.plainLanguage ?? focus?.body ?? study.research.research.report.summary,
            caveat: caveat,
            calculations: claim.map { study.research.calculations(for: $0) }
                ?? focus?.calculationIds.compactMap(study.research.calculation) ?? [],
            evidence: (claim.map { claimEvidenceIDs($0) } ?? focus?.evidenceIds ?? []).compactMap(study.research.evidence),
            counterEvidenceIDs: claim.map { $0.evidenceLinks.filter { $0.relation == "contradicts" }.map(\.evidenceId) }
                ?? focus?.counterEvidenceIds ?? [],
            claims: claim.map { [$0] } ?? focus?.conclusionIds.compactMap(study.research.claim) ?? study.research.orderedClaims)
    }

}
