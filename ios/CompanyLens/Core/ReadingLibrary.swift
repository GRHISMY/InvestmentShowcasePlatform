import Foundation
import CryptoKit

/// One read-only Interface owns pairing, reference resolution and the data a
/// platform needs to render a scene. It does not choose a company's argument.
public struct ReadingLibrary {
    public let research: ResearchLibrary
    public let document: ReadingDocument
    private let scenesByID: [String: ReadingScene]
    private let focusesByID: [String: ReadingFocus]
    private let viewsByID: [String: ReadingView]

    public init(researchData: Data, readingData: Data) throws {
        let research = try ResearchLibrary(researchData: researchData)
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        let document = try decoder.decode(ReadingDocument.self, from: readingData)
        guard document.schemaVersion == "company-reading/v1" else { throw ReadingError.unsupportedVersion }
        guard document.researchRef.snapshotId == research.research.publication.snapshotId,
              document.researchRef.sha256 == Self.sha256(researchData) else { throw ReadingError.researchMismatch }
        guard !document.id.isEmpty, document.revision > 0 else { throw ReadingError.invalidReading("identity") }
        let scenes = try Self.index(document.scenes, "scenes")
        let focuses = try Self.index(document.focuses, "focuses")
        let views = try Self.index(document.views, "views")
        let graph = try decoder.decode(GraphEnvelope.self, from: researchData)
        let subjects = try Self.index(graph.subjects, "subjects")
        let relations = try Self.index(graph.relations, "relations")
        let actions = try Self.index(graph.capitalActions, "capital actions")
        let timeBases = Dictionary(uniqueKeysWithValues: graph.facts.map { ($0.id, $0.timeBasis) })

        func reference(_ ref: ReadingReference) throws {
            let valid: Bool
            switch ref.kind {
            case "subject": valid = subjects[ref.id] != nil
            case "relation": valid = relations[ref.id] != nil
            case "conclusion": valid = research.claim(ref.id) != nil
            case "fact": valid = research.fact(ref.id) != nil
            case "calculation": valid = research.calculation(ref.id) != nil
            case "evidence": valid = research.evidence(ref.id) != nil
            case "gap": valid = ref.ownerId.flatMap(research.claim)?.gaps.contains { $0.id == ref.id } == true
            case "observation": valid = ref.ownerId.flatMap { actions[$0] }?.observations.contains { $0.id == ref.id } == true
            default: valid = false
            }
            guard valid, !ref.id.isEmpty else { throw ReadingError.invalidReference(ref.kind + ":" + ref.id) }
            if !["gap", "observation"].contains(ref.kind), ref.ownerId != nil {
                throw ReadingError.invalidReference("unexpected owner: " + ref.id)
            }
        }
        func ids<T>(_ ids: [String], _ table: [String: T], _ owner: String) throws {
            guard Set(ids).count == ids.count, ids.allSatisfy({ table[$0] != nil }) else {
                throw ReadingError.invalidReference(owner)
            }
        }
        for subject in subjects.values { for ref in subject.refs { try reference(ref) } }
        for relation in relations.values {
            guard subjects[relation.fromId] != nil, subjects[relation.toId] != nil else {
                throw ReadingError.invalidReference(relation.id)
            }
            for ref in relation.refs { try reference(ref) }
        }
        func checkBasis(_ ref: ReadingReference, path: Set<ReadingReference>) throws {
            guard ref.kind == "subject" || ref.kind == "relation" else { return }
            guard !path.contains(ref) else { throw ReadingError.invalidReference("cyclic basis: " + ref.id) }
            let children = ref.kind == "subject" ? subjects[ref.id]?.refs : relations[ref.id]?.refs
            for child in children ?? [] { try checkBasis(child, path: path.union([ref])) }
        }
        for subject in subjects.values { for ref in subject.refs { try checkBasis(ref, path: []) } }
        for relation in relations.values { for ref in relation.refs { try checkBasis(ref, path: []) } }
        guard !scenes.isEmpty,
              Set(document.sceneOrder) == Set(scenes.keys), document.sceneOrder.count == scenes.count,
              document.entrySceneId == document.sceneOrder.first else { throw ReadingError.invalidReading("main route") }
        for (index, id) in document.sceneOrder.enumerated() {
            let scene = scenes[id]!
            guard views[scene.viewId] != nil, scene.focusIds.contains(scene.defaultFocusId) else {
                throw ReadingError.invalidReference(scene.id)
            }
            try ids(scene.focusIds, focuses, scene.id + " focuses")
            guard scene.conclusionIds.allSatisfy({ research.claim($0) != nil }) else {
                throw ReadingError.invalidReference(scene.id + " conclusions")
            }
            let expectedNext = index + 1 < document.sceneOrder.count ? document.sceneOrder[index + 1] : nil
            guard scene.nextSceneId == expectedNext else { throw ReadingError.invalidReading("next scene: " + id) }
            for ref in scene.essentialRefs {
                try reference(ref)
                if ref.kind == "gap", let owner = ref.ownerId,
                   let gap = research.claim(owner)?.gaps.first(where: { $0.id == ref.id }) {
                    guard scene.essentialNotes.joined(separator: "\n").contains(gap.description) else {
                        throw ReadingError.missingEssential(ref.id)
                    }
                }
            }
            if !scene.essentialRefs.isEmpty && scene.essentialNotes.isEmpty { throw ReadingError.missingEssential(scene.id) }
            let view = views[scene.viewId]!
            let clickable = view.nodes.map(\.focusId) + view.edges.map(\.focusId) + view.series.map(\.focusId)
                + view.events.map(\.focusId) + view.annotations.map(\.focusId)
            guard Set(clickable).isSubset(of: Set(scene.focusIds)) else {
                throw ReadingError.invalidReference(scene.id + " visible focuses")
            }
        }
        let covered = Set(document.scenes.flatMap(\.conclusionIds))
        let allClaims = Set(research.research.conclusions.map(\.id))
        guard covered == Set(document.coverage.conclusionIds), covered.isSubset(of: allClaims),
              Set(document.coverage.omittedConclusionIds) == allClaims.subtracting(covered),
              ["excerpt", "complete"].contains(document.coverage.mode),
              document.coverage.mode != "complete" || covered == allClaims else {
            throw ReadingError.invalidReading("coverage")
        }
        let sceneEssential = Set(document.scenes.flatMap(\.essentialRefs))
        for ref in document.coverage.essentialRefs {
            try reference(ref)
            guard sceneEssential.contains(ref) else { throw ReadingError.missingEssential(ref.id) }
        }
        guard document.overview.entries.allSatisfy({ scenes[$0.sceneId] != nil }) else {
            throw ReadingError.invalidReference("overview")
        }
        for focus in focuses.values {
            for ref in focus.refs { try reference(ref) }
            guard focus.evidenceIds.allSatisfy({ research.evidence($0) != nil }),
                  focus.calculationIds.allSatisfy({ research.calculation($0) != nil }),
                  focus.conclusionIds.allSatisfy({ research.claim($0) != nil }),
                  Set(focus.counterEvidenceIds).isSubset(of: Set(focus.evidenceIds)) else {
                throw ReadingError.invalidReference(focus.id)
            }
            let citedClaims = focus.conclusionIds.compactMap(research.claim)
            for gap in focus.gaps {
                guard research.research.conclusions.contains(where: { claim in
                    claim.gaps.contains { $0.id == gap.id && $0.description == gap.description && $0.state == gap.state }
                }) else { throw ReadingError.invalidReference(gap.id) }
            }
            for counter in focus.counterEvidenceIds {
                guard citedClaims.contains(where: { $0.evidenceLinks.contains { $0.evidenceId == counter && $0.relation == "contradicts" } }) else {
                    throw ReadingError.invalidReference("counter evidence: " + counter)
                }
            }
        }
        for view in views.values {
            guard ["relation_graph", "comparison", "trend", "timeline", "argument", "text"].contains(view.kind) else {
                throw ReadingError.unsupportedView(view.kind)
            }
            let nodes = try Self.index(view.nodes, view.id + " nodes")
            _ = try Self.index(view.edges, view.id + " edges")
            _ = try Self.index(view.series, view.id + " series")
            _ = try Self.index(view.events, view.id + " events")
            _ = try Self.index(view.annotations, view.id + " annotations")
            for node in view.nodes {
                guard let subject = subjects[node.subjectId], node.id == node.subjectId,
                      subject.label == node.label, subject.kind == node.kind,
                      (0...8).contains(node.row), (0...8).contains(node.column) else {
                    throw ReadingError.invalidReference("node: " + node.id)
                }
            }
            for edge in view.edges {
                guard let relation = relations[edge.id], relation.fromId == edge.fromId, relation.toId == edge.toId,
                      relation.label == edge.label, relation.kind == edge.kind, relation.status == edge.status,
                      nodes[edge.fromId] != nil, nodes[edge.toId] != nil else {
                    throw ReadingError.invalidReference("edge: " + edge.id)
                }
            }
            for series in view.series {
                guard !series.values.isEmpty else { throw ReadingError.invalidReading("empty numeric series") }
                for value in series.values {
                    try reference(value.ref)
                    try Self.validate(value, research: research, timeBases: timeBases)
                    if let context = value.contextRef {
                        try reference(context)
                        guard let format = value.contextFormat, let contextText = value.contextText else {
                            throw ReadingError.invalidNumber(series.id)
                        }
                        let baseline = try Self.number(context, research: research)
                        let expected = try Self.formatted(baseline.value, unit: baseline.unit, format: format)
                        let compactText = Self.compact(contextText)
                        guard compactText.hasSuffix(format.unit),
                              Decimal(string: String(compactText.dropLast(format.unit.count))) == Decimal(string: expected) else {
                            throw ReadingError.invalidNumber(series.id + " context")
                        }
                    }
                }
                guard Set(series.values.map(\.rawUnit)).count == 1,
                      Set(series.values.map(\.displayUnit)).count == 1,
                      Set(series.values.map(\.entityId)).count == 1,
                      Set(series.values.map(\.timeBasis)).count == 1 else { throw ReadingError.incompatibleComparison(series.id) }
                try Self.validateComparison(series, research: research)
            }
            for event in view.events {
                guard focuses[event.focusId] != nil, event.observationRef.kind == "observation",
                      let action = event.observationRef.ownerId.flatMap({ actions[$0] }),
                      let observation = action.observations.first(where: { $0.id == event.observationRef.id }),
                      let date = research.research.periods.first(where: { $0.id == event.datePeriodId }),
                      observation.stage == event.stage, date.label == event.dateLabel else {
                    throw ReadingError.invalidReference("event: " + event.id)
                }
                if ["proposed", "approved", "implementation_announced"].contains(event.stage) {
                    guard event.datePeriodId == observation.periodId else { throw ReadingError.invalidReference("event date: " + event.id) }
                } else {
                    guard action.observations.contains(where: { $0.periodId == event.datePeriodId }) else {
                        throw ReadingError.invalidReference("event date: " + event.id)
                    }
                }
                if let valueRef = event.valueRef {
                    try reference(valueRef)
                    guard valueRef.kind == "fact", let format = event.format,
                          action.observations.contains(where: { item in
                              item.factIds.contains(valueRef.id) && (event.stage == "proposed" || item.stage != "proposed")
                          }) else { throw ReadingError.invalidNumber(event.id) }
                    let number = try Self.number(valueRef, research: research)
                    let expected = try Self.formatted(number.value, unit: number.unit, format: format)
                    guard Self.numericText(event.valueText, matches: expected, unit: format.unit) else {
                        throw ReadingError.invalidNumber(event.id)
                    }
                } else if !event.valueText.isEmpty { throw ReadingError.invalidNumber(event.id) }
            }
        }
        self.research = research
        self.document = document
        scenesByID = scenes
        focusesByID = focuses
        viewsByID = views
    }

    public var orderedScenes: [ReadingScene] { document.sceneOrder.compactMap { scenesByID[$0] } }
    public func scene(_ id: String) -> ReadingScene? { scenesByID[id] }
    public func focus(_ id: String) -> ReadingFocus? { focusesByID[id] }
    public func view(_ id: String) -> ReadingView? { viewsByID[id] }
    public func validFocus(_ id: String?, in sceneID: String) -> String? {
        guard let id, scenesByID[sceneID]?.focusIds.contains(id) == true else { return nil }
        return id
    }
    public static func sha256(_ data: Data) -> String { SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined() }

    private static func index<T: Identifiable>(_ values: [T], _ owner: String) throws -> [String: T] where T.ID == String {
        var result: [String: T] = [:]
        for value in values {
            guard !value.id.isEmpty, result[value.id] == nil else { throw ReadingError.duplicateIdentity(owner) }
            result[value.id] = value
        }
        return result
    }
    private static func compact(_ text: String) -> String { text.filter { !$0.isWhitespace } }
    private struct NumberBaseline { let value, unit, entity: String; let period: String }
    private static func number(_ ref: ReadingReference, research: ResearchLibrary) throws -> NumberBaseline {
        if ref.kind == "fact", let fact = research.fact(ref.id) {
            return NumberBaseline(value: fact.value, unit: fact.unit, entity: fact.entityId, period: fact.periodId)
        }
        if ref.kind == "calculation", let calculation = research.calculation(ref.id),
           let first = calculation.inputs.first.flatMap({ research.fact($0.factId) }) {
            let inputs = calculation.inputs.compactMap { research.fact($0.factId) }
            let periods = Set(inputs.map(\.periodId))
            let entities = Set(inputs.map(\.entityId))
            return NumberBaseline(value: calculation.result.value, unit: calculation.result.unit, entity: entities.count == 1 ? first.entityId : "",
                                  period: periods.count == 1 ? first.periodId : "")
        }
        throw ReadingError.invalidNumber(ref.id)
    }
    private static func validate(_ value: ReadingValue, research: ResearchLibrary, timeBases: [String: String]) throws {
        let original = try number(value.ref, research: research)
        guard let originalNumber = Decimal(string: original.value, locale: Locale(identifier: "en_US_POSIX")),
              let rawNumber = Decimal(string: value.rawValue, locale: Locale(identifier: "en_US_POSIX")), originalNumber == rawNumber,
              original.unit == value.rawUnit, original.entity == value.entityId, original.period == value.periodId,
              Double(value.displayValue)?.isFinite == true,
              value.displayValue.range(of: "^-?[0-9]+(?:\\.[0-9]+)?$", options: .regularExpression) != nil else {
            throw ReadingError.invalidNumber(value.ref.id)
        }
        let digits = value.displayValue.split(separator: ".", omittingEmptySubsequences: false).dropFirst().first?.count ?? 0
        let expected = try formatted(original.value, unit: original.unit, format: ReadingFormat(unit: value.displayUnit, decimals: digits))
        guard Decimal(string: expected) == Decimal(string: value.displayValue) else { throw ReadingError.invalidNumber(value.ref.id) }
        if value.ref.kind == "fact", timeBases[value.ref.id] != value.timeBasis { throw ReadingError.invalidNumber(value.ref.id + " time basis") }
    }
    private static func numericText(_ text: String, matches value: String, unit: String) -> Bool {
        let text = compact(text)
        return text.hasSuffix(unit) && Decimal(string: String(text.dropLast(unit.count))) == Decimal(string: value)
    }
    private static func validateComparison(_ series: ReadingSeries, research: ResearchLibrary) throws {
        guard ["same_period", "annual_yoy", "same_period_yoy", "time_series", "not_applicable"].contains(series.comparison) else {
            throw ReadingError.incompatibleComparison(series.id)
        }
        if series.comparison == "not_applicable" || series.values.count < 2 { return }
        let periods = series.values.compactMap { value in research.research.periods.first { $0.id == value.periodId } }
        guard periods.count == series.values.count else { throw ReadingError.incompatibleComparison(series.id) }
        if series.comparison == "same_period" {
            guard Set(periods.map(\.id)).count == 1 else { throw ReadingError.incompatibleComparison(series.id) }
        } else if series.comparison == "time_series" {
            let ends = periods.map(\.end)
            guard Set(ends).count == ends.count, ends == ends.sorted() else { throw ReadingError.incompatibleComparison(series.id) }
        } else {
            let windows = periods.map { String($0.start.dropFirst(4)) + "/" + String($0.end.dropFirst(4)) }
            let years = periods.compactMap { Int($0.end.prefix(4)) }.sorted()
            guard Set(periods.map(\.kind)).count == 1, Set(windows).count == 1,
                  years.count == periods.count, Set(years).count == years.count,
                  zip(years, years.dropFirst()).allSatisfy({ $1 == $0 + 1 }),
                  series.comparison != "annual_yoy" || periods.allSatisfy({ $0.kind == "annual" }) else {
                throw ReadingError.incompatibleComparison(series.id)
            }
        }
    }
    private static func formatted(_ value: String, unit: String, format: ReadingFormat) throws -> String {
        let factors: [String: [String: String]] = [
            "CNY": ["元":"1", "千元":"1000", "万元":"10000", "百万元":"1000000", "亿元":"100000000"],
            "CNY/share": ["元/股":"1"], "percent": ["%":"1", "百分点":"1"],
            "ratio": ["倍":"1", "比例":"1", "%":"0.01"], "year":["年":"1"],
            "count":["个":"1", "项":"1", "股":"1"]
        ]
        guard (0...8).contains(format.decimals), let factor = factors[unit]?[format.unit],
              let raw = Decimal(string: value), let divisor = Decimal(string: factor) else { throw ReadingError.invalidNumber(value) }
        var quotient = raw / divisor, rounded = Decimal()
        NSDecimalRound(&rounded, &quotient, format.decimals, .plain)
        return NSDecimalNumber(decimal: rounded).stringValue
    }

    public enum ReadingError: Error, Equatable {
        case unsupportedVersion, researchMismatch, duplicateIdentity(String), invalidReference(String)
        case invalidReading(String), invalidNumber(String), incompatibleComparison(String), missingEssential(String), unsupportedView(String)
    }
}

public struct ReadingReference: Decodable, Hashable {
    public let kind, id: String
    public let ownerId: String?
}
public struct ReadingFormat: Decodable { public let unit: String; public let decimals: Int }
public struct ReadingDocument: Decodable {
    public let schemaVersion, id: String
    public let revision: Int
    public let researchRef: ReadingResearchRef
    public let entrySceneId: String
    public let sceneOrder: [String]
    public let overview: ReadingOverview
    public let coverage: ReadingCoverage
    public let views: [ReadingView]
    public let focuses: [ReadingFocus]
    public let scenes: [ReadingScene]
}
public struct ReadingResearchRef: Decodable { public let snapshotId, sha256: String }
public struct ReadingOverview: Decodable { public let title, summary: String; public let entries: [ReadingOverviewEntry] }
public struct ReadingOverviewEntry: Decodable, Identifiable {
    public let sceneId, label, caption, icon: String
    public var id: String { sceneId }
}
public struct ReadingCoverage: Decodable {
    public let mode: String
    public let conclusionIds, omittedConclusionIds: [String]
    public let essentialRefs: [ReadingReference]
}
public struct ReadingScene: Decodable, Identifiable {
    public let id, section, title, question, viewId, defaultFocusId: String
    public let focusIds, conclusionIds: [String]
    public let essentialRefs: [ReadingReference]
    public let essentialNotes: [String]
    public let nextSceneId: String?
    public let nextLabel: String
}
public struct ReadingFocus: Decodable, Identifiable {
    public let id, title, body, caveat: String
    public let refs: [ReadingReference]
    public let evidenceIds, calculationIds, conclusionIds, counterEvidenceIds: [String]
    public let gaps: [ReadingGap]
}
public struct ReadingGap: Decodable, Identifiable { public let id, description, state: String }
public struct ReadingView: Decodable, Identifiable {
    public let id, kind, title, caption: String
    public let nodes: [ReadingNode]
    public let edges: [ReadingEdge]
    public let series: [ReadingSeries]
    public let events: [ReadingTimelineEvent]
    public let annotations: [ReadingAnnotation]
    public let notes: [String]
}
public struct ReadingNode: Decodable, Identifiable {
    public let id, subjectId, label, subtitle, kind, focusId, icon: String
    public let row, column: Int
}
public struct ReadingEdge: Decodable, Identifiable {
    public let id, fromId, toId, label, kind, status, focusId, note: String
}
public struct ReadingSeries: Decodable, Identifiable {
    public let id, label, focusId, comparison: String
    public let values: [ReadingValue]
}
public struct ReadingValue: Decodable {
    public let ref: ReadingReference
    public let label, rawValue, rawUnit, displayValue, displayUnit, entityId, periodId, periodLabel, timeBasis: String
    public let contextText: String?
    public let contextRef: ReadingReference?
    public let contextFormat: ReadingFormat?
    public var text: String { displayValue + displayUnit }
    public var plotValue: Double { Double(displayValue) ?? 0 }
}
public struct ReadingTimelineEvent: Decodable, Identifiable {
    public let id, label, dateLabel, stage, focusId, valueText, note: String
    public let observationRef: ReadingReference
    public let datePeriodId: String
    public let valueRef: ReadingReference?
    public let format: ReadingFormat?
}
public struct ReadingAnnotation: Decodable, Identifiable { public let id, label, icon, focusId: String }

private struct GraphSubject: Decodable, Identifiable {
    let id, label, kind, note: String
    let entityId: String?
    let refs: [ReadingReference]
}
private struct GraphRelation: Decodable, Identifiable {
    let id, fromId, toId, label, kind, status, note: String
    let periodIds: [String]
    let refs: [ReadingReference]
}
private struct GraphObservation: Decodable, Identifiable { let id, periodId, stage: String; let factIds, evidenceIds: [String] }
private struct GraphAction: Decodable, Identifiable { let id: String; let observations: [GraphObservation] }
private struct GraphFactBasis: Decodable { let id, timeBasis: String }
private struct GraphEnvelope: Decodable {
    let subjects: [GraphSubject]
    let relations: [GraphRelation]
    let capitalActions: [GraphAction]
    let facts: [GraphFactBasis]
    enum CodingKeys: String, CodingKey { case subjects, relations, capitalActions, facts }
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        subjects = try container.decodeIfPresent([GraphSubject].self, forKey: .subjects) ?? []
        relations = try container.decodeIfPresent([GraphRelation].self, forKey: .relations) ?? []
        capitalActions = try container.decodeIfPresent([GraphAction].self, forKey: .capitalActions) ?? []
        facts = try container.decode([GraphFactBasis].self, forKey: .facts)
    }
}
