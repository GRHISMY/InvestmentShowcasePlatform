import Foundation

/// A read-only interpretation of the published research contract. No research
/// text or arithmetic is recreated here; views query the published identities.
public struct ResearchLibrary {
    public let research: ResearchData
    public let sections: [ResearchSection]
    public let pages: [EvidencePage]
    private let claimsByID: [String: ResearchClaim]
    private let evidenceByID: [String: ResearchEvidence]
    private let factsByID: [String: ResearchFact]
    private let calculationsByID: [String: ResearchCalculation]
    private let dimensionsByID: [String: ResearchDimension]

    public init(researchData: Data) throws {
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        let decoded = try decoder.decode(ResearchData.self, from: researchData)
        guard ["company-research/v1", "company-research/v1.1", "company-research/v1.2"].contains(decoded.schemaVersion) else {
            throw LibraryError.unsupportedVersion(decoded.schemaVersion)
        }
        let claims = try Self.index(decoded.conclusions, kind: "conclusion")
        let entities = try Self.index(decoded.entities, kind: "entity")
        let periods = try Self.index(decoded.periods, kind: "period")
        let sources = try Self.index(decoded.sources, kind: "source")
        let evidence = try Self.index(decoded.evidence, kind: "evidence")
        let facts = try Self.index(decoded.facts, kind: "fact")
        let calculations = try Self.index(decoded.calculations, kind: "calculation")
        let dimensions = try Self.index(decoded.dimensions, kind: "dimension")
        _ = try Self.index(decoded.monitoring, kind: "monitoring")
        guard !claims.isEmpty, decoded.report.review.status == "reviewed" else {
            throw LibraryError.invalidReport("A reviewed publication with conclusions is required.")
        }

        func references<T>(_ ids: [String], in table: [String: T], owner: String) throws {
            for id in ids where table[id] == nil { throw LibraryError.invalidReference(owner, id) }
        }
        var expandedPages: [EvidencePage] = []
        for source in decoded.sources {
            let path = source.assetPath
            let parts = path.split(separator: "/", omittingEmptySubsequences: false)
            guard parts.count == 2, parts[0] == "reports", !parts[1].isEmpty,
                  path.hasSuffix(".pdf"), !path.contains("\\"), !path.contains("%"),
                  !path.contains(":"), !path.contains("?"), !path.contains("#"),
                  !path.contains("\0"), !parts.contains(".."), source.pdfPages > 0,
                  source.sha256.range(of: "^[0-9a-f]{64}$", options: .regularExpression) != nil else {
                throw LibraryError.invalidSource(source.id)
            }
            try references([source.reportPeriodId], in: periods, owner: source.id)
        }
        guard Set(decoded.sources.map(\.assetPath)).count == decoded.sources.count else {
            throw LibraryError.invalidReport("Sources cannot share an asset path.")
        }
        for excerpt in decoded.evidence {
            guard let source = sources[excerpt.sourceId] else {
                throw LibraryError.invalidReference(excerpt.id, excerpt.sourceId)
            }
            guard !excerpt.physicalPages.isEmpty,
                  Set(excerpt.physicalPages).count == excerpt.physicalPages.count,
                  excerpt.physicalPages.allSatisfy({ (1...source.pdfPages).contains($0) }) else {
                throw LibraryError.invalidPage(excerpt.id)
            }
            for page in excerpt.physicalPages {
                expandedPages.append(EvidencePage(
                    id: excerpt.id + "-p" + String(page), sourceId: source.id,
                    title: source.title, period: periods[source.reportPeriodId]!.label,
                    label: "核对原文", sourceSha256: source.sha256,
                    url: source.originUrl ?? "", documentFile: source.assetPath,
                    physicalPage: page, pageCount: source.pdfPages, focusText: excerpt.excerpt))
            }
        }
        guard Set(expandedPages.map(\.id)).count == expandedPages.count else {
            throw LibraryError.invalidReport("Expanded evidence page identities collide.")
        }
        for fact in decoded.facts {
            try references(fact.evidenceIds, in: evidence, owner: fact.id)
            try references([fact.entityId], in: entities, owner: fact.id)
            try references([fact.periodId], in: periods, owner: fact.id)
            guard !fact.evidenceIds.isEmpty, Self.isDecimal(fact.value) else {
                throw LibraryError.invalidNumber(fact.id)
            }
        }
        for calculation in decoded.calculations {
            try references(calculation.inputs.map(\.factId), in: facts, owner: calculation.id)
            guard !calculation.inputs.isEmpty,
                  calculation.inputs.allSatisfy({ Self.isDecimal($0.coefficient) }),
                  Self.isDecimal(calculation.result.value), Self.isDecimal(calculation.result.displayValue) else {
                throw LibraryError.invalidNumber(calculation.id)
            }
        }
        for claim in decoded.conclusions {
            try references(claim.factIds, in: facts, owner: claim.id)
            try references(claim.calculationIds, in: calculations, owner: claim.id)
            try references(claim.evidenceLinks.map(\.evidenceId), in: evidence, owner: claim.id)
            try references(claim.entityIds, in: entities, owner: claim.id)
            try references(claim.periodIds, in: periods, owner: claim.id)
            try references(claim.dimensionIds, in: dimensions, owner: claim.id)
            _ = try Self.index(claim.gaps, kind: "gap of " + claim.id)
            guard !claim.entityIds.isEmpty, !claim.periodIds.isEmpty else {
                throw LibraryError.invalidReport("Missing scope for " + claim.id)
            }
        }
        for dimension in decoded.dimensions {
            try references(dimension.conclusionIds, in: claims, owner: dimension.id)
        }
        for monitor in decoded.monitoring {
            try references(monitor.conclusionIds, in: claims, owner: monitor.id)
        }
        try references(decoded.presentation.headlineConclusionIds, in: claims, owner: "headlines")
        let orderedDimensions = decoded.presentation.dimensionOrder
        guard Set(orderedDimensions) == Set(dimensions.keys), orderedDimensions.count == dimensions.count,
              Set(decoded.presentation.headlineConclusionIds).count == decoded.presentation.headlineConclusionIds.count else {
            throw LibraryError.invalidReport("Invalid presentation indexes.")
        }
        let suppliedSections = decoded.presentation.sections
        if !suppliedSections.isEmpty {
            _ = try Self.index(suppliedSections, kind: "section")
            let ids = suppliedSections.flatMap(\.conclusionIds)
            guard suppliedSections.allSatisfy({ !$0.conclusionIds.isEmpty }),
                  ids.count == claims.count, Set(ids) == Set(claims.keys) else {
                throw LibraryError.invalidReport("Sections must contain every conclusion exactly once.")
            }
        }
        research = decoded
        sections = suppliedSections.isEmpty
            ? [ResearchSection(id: "all-conclusions", title: "具体怎么看", conclusionIds: decoded.conclusions.map(\.id))]
            : suppliedSections
        pages = expandedPages
        claimsByID = claims
        evidenceByID = evidence
        factsByID = facts
        calculationsByID = calculations
        dimensionsByID = dimensions
    }

    public var orderedClaims: [ResearchClaim] { sections.flatMap(\.conclusionIds).compactMap(claim) }
    public var headlineClaims: [ResearchClaim] { research.presentation.headlineConclusionIds.compactMap(claim) }
    public var orderedDimensions: [ResearchDimension] { research.presentation.dimensionOrder.compactMap(dimension) }
    public func claim(_ id: String) -> ResearchClaim? { claimsByID[id] }
    public func page(_ id: String) -> EvidencePage? { pages.first { $0.id == id } }
    public func dimension(_ id: String) -> ResearchDimension? { dimensionsByID[id] }
    public func evidence(_ id: String) -> ResearchEvidence? { evidenceByID[id] }
    public func fact(_ id: String) -> ResearchFact? { factsByID[id] }
    public func calculation(_ id: String) -> ResearchCalculation? { calculationsByID[id] }
    public func pages(for evidenceID: String) -> [EvidencePage] {
        guard let excerpt = evidence(evidenceID) else { return [] }
        return excerpt.physicalPages.compactMap { page(evidenceID + "-p" + String($0)) }
    }
    /// A presentation can cite another page of an already packaged, hashed
    /// original without modifying the published research ledger.
    public func page(sourceID: String, physicalPage: Int, focusText: String) -> EvidencePage? {
        guard let source = research.sources.first(where: { $0.id == sourceID }),
              (1...source.pdfPages).contains(physicalPage),
              let period = research.periods.first(where: { $0.id == source.reportPeriodId }) else { return nil }
        return EvidencePage(id: sourceID + "-original-p" + String(physicalPage), sourceId: sourceID,
            title: source.title, period: period.label, label: "核对补充原页", sourceSha256: source.sha256,
            url: source.originUrl ?? "", documentFile: source.assetPath,
            physicalPage: physicalPage, pageCount: source.pdfPages, focusText: focusText)
    }
    public func facts(for claim: ResearchClaim) -> [ResearchFact] { claim.factIds.compactMap(fact) }
    public func calculations(for claim: ResearchClaim) -> [ResearchCalculation] { claim.calculationIds.compactMap(calculation) }
    public func scope(of claim: ResearchClaim) -> String {
        let names = claim.entityIds.compactMap { id in research.entities.first { $0.id == id }?.name }
        let periods = claim.periodIds.compactMap { id in research.periods.first { $0.id == id }?.label }
        return names.joined(separator: "、") + " · " + periods.joined(separator: "、")
    }

    private static func index<T: Identifiable>(_ values: [T], kind: String) throws -> [String: T] where T.ID == String {
        var result: [String: T] = [:]
        for value in values {
            guard !value.id.isEmpty, result[value.id] == nil else { throw LibraryError.duplicateIdentity(kind, value.id) }
            result[value.id] = value
        }
        return result
    }
    private static func isDecimal(_ value: String) -> Bool {
        value.range(of: "^-?(0|[1-9][0-9]*)(\\.[0-9]+)?$", options: .regularExpression) != nil
    }
    public enum LibraryError: Error, Equatable {
        case unsupportedVersion(String), duplicateIdentity(String, String)
        case invalidReference(String, String), invalidSource(String), invalidPage(String)
        case invalidNumber(String), invalidReport(String)
    }
}

public struct ResearchData: Decodable {
    public let schemaVersion: String
    public let report: ResearchReport
    public let company: ResearchCompany
    public let entities: [ResearchEntity]
    public let periods: [ResearchPeriod]
    public let sources: [ResearchSource]
    public let evidence: [ResearchEvidence]
    public let facts: [ResearchFact]
    public let calculations: [ResearchCalculation]
    public let conclusions: [ResearchClaim]
    public let dimensions: [ResearchDimension]
    public let presentation: ResearchPresentation
    public let monitoring: [ResearchMonitoring]
    public let publication: ResearchPublication
}
public struct ResearchReport: Decodable {
    public let id, researchAsOf, summary: String
    public let revision: Int
    public let coverage: ResearchCoverage
    public let limitations: [String]
    public let review: ResearchReview
}
public struct ResearchCoverage: Decodable { public let start, end: String }
public struct ResearchReview: Decodable { public let status, reviewer, reviewedAt, note: String }
public struct ResearchCompany: Decodable { public let id, name, code: String }
public struct ResearchEntity: Decodable, Identifiable { public let id, name, scope, note: String }
public struct ResearchPeriod: Decodable, Identifiable { public let id, start, end, kind, label: String }
public struct ResearchSource: Decodable, Identifiable {
    public let id, title, assetPath, sha256, reportPeriodId: String
    public let originUrl: String?
    public let pdfPages: Int
}
public struct ResearchPublication: Decodable { public let snapshotId: String }
public struct ResearchClaim: Decodable, Identifiable {
    public let id, title, plainLanguage, statement, financialImpact: String
    public let alternatives, reasoning, changeConditions, limitations: [String]
    public let gaps: [ResearchGap]
    public let evidenceLinks: [ResearchEvidenceLink]
    public let dimensionIds, entityIds, periodIds, factIds, calculationIds: [String]
    public let assessment: ResearchAssessment
}
public struct ResearchAssessment: Decodable { public let business, evidence: String }
public struct ResearchGap: Decodable, Identifiable { public let id, state, description: String }
public struct ResearchEvidenceLink: Decodable { public let evidenceId, relation, explanation: String }
public struct ResearchEvidence: Decodable, Identifiable {
    public let id, sourceId, excerpt, locatorNote: String
    public let physicalPages: [Int]
}
public struct ResearchFact: Decodable, Identifiable {
    public let id, metric, label, value, unit, note, entityId, periodId: String
    public let evidenceIds: [String]
}
public struct ResearchCalculation: Decodable, Identifiable {
    public let id, title, operation, explanation: String
    public let inputs: [CalculationInput]
    public let limitations: [String]
    public let result: CalculationResult
}
public struct CalculationInput: Decodable { public let factId, coefficient: String }
public struct CalculationResult: Decodable { public let value, unit, displayValue, displayUnit: String }
public struct ResearchSection: Decodable, Identifiable { public let id, title: String; public let conclusionIds: [String] }
public struct ResearchDimension: Decodable, Identifiable { public let id, title, summary: String; public let conclusionIds: [String] }
public struct ResearchMonitoring: Decodable, Identifiable {
    public let id, description, status: String
    public let trigger: String?
    public let conclusionIds: [String]
}
public struct ResearchPresentation: Decodable {
    public let headlineConclusionIds, dimensionOrder: [String]
    public let sections: [ResearchSection]
    enum CodingKeys: String, CodingKey { case headlineConclusionIds, dimensionOrder, sections }
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        headlineConclusionIds = try c.decode([String].self, forKey: .headlineConclusionIds)
        dimensionOrder = try c.decode([String].self, forKey: .dimensionOrder)
        sections = try c.decodeIfPresent([ResearchSection].self, forKey: .sections) ?? []
    }
}
/// Derived navigation address into a full, unchanged original PDF.
public struct EvidencePage: Identifiable {
    public let id, sourceId, title, period, label, sourceSha256, url, documentFile: String
    public let physicalPage, pageCount: Int
    public let focusText: String?
}
