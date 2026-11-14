import Foundation
import XCTest
@testable import ResearchCore

final class ReadingLibraryTests: XCTestCase {
    private struct Fixture { var research: Data; var reading: [String: Any]; let factID: String }

    private func fixture() throws -> Fixture {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        var object = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: root.appendingPathComponent("Study/research.json"))) as? [String: Any])
        object["schema_version"] = "company-research/v1.2"
        let oldBytes = try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
        let book = try ResearchLibrary(researchData: oldBytes)
        let claim = try XCTUnwrap(book.research.conclusions.first(where: { !$0.gaps.isEmpty }))
        let gap = try XCTUnwrap(claim.gaps.first)
        let fact = try XCTUnwrap(book.research.facts.first(where: { $0.unit == "CNY" }))
        let sourceRef: [String: Any] = ["kind": "conclusion", "id": claim.id]
        object["subjects"] = [
            ["id": "subject-a", "label": "研究中的一个角色", "kind": "business_role", "note": "", "refs": [sourceRef]],
            ["id": "subject-b", "label": "另一位参与者", "kind": "business_role", "note": "", "refs": [sourceRef]]
        ]
        object["relations"] = [["id": "relation-a", "from_id": "subject-a", "to_id": "subject-b", "label": "研究说明的关系",
                                "kind": "description", "status": "inferred", "period_ids": [claim.periodIds[0]], "refs": [sourceRef], "note": ""]]
        let bytes = try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
        let gapRef: [String: Any] = ["kind": "gap", "id": gap.id, "owner_id": claim.id]
        let evidence = Array(Set(claim.evidenceLinks.map(\.evidenceId) + fact.evidenceIds)).sorted()
        let focus: [String: Any] = ["id": "focus-a", "title": "一个自由研究的问题", "body": "解释来自这次研究。", "caveat": "保留尚未查清的事。",
                                   "refs": [sourceRef, ["kind": "fact", "id": fact.id]], "evidence_ids": evidence,
                                   "calculation_ids": claim.calculationIds, "conclusion_ids": [claim.id],
                                   "gaps": claim.gaps.map { ["id": $0.id, "description": $0.description, "state": $0.state] },
                                   "counter_evidence_ids": claim.evidenceLinks.filter { $0.relation == "contradicts" }.map(\.evidenceId)]
        let view: [String: Any] = ["id": "view-a", "kind": "text", "title": "由研究决定的表达", "caption": "",
                                  "nodes": [], "edges": [], "series": [], "events": [], "annotations": [], "notes": []]
        let scene: [String: Any] = ["id": "scene-a", "section": "自定主线", "title": "一个场景也可以是一份阅读稿", "question": "发生了什么？",
                                   "view_id": "view-a", "default_focus_id": "focus-a", "focus_ids": ["focus-a"], "conclusion_ids": [claim.id],
                                   "essential_refs": [gapRef], "essential_notes": [gap.description], "next_label": "回到全貌"]
        let reading: [String: Any] = [
            "schema_version": "company-reading/v1", "id": "free-reading", "revision": 1,
            "research_ref": ["snapshot_id": book.research.publication.snapshotId, "sha256": ReadingLibrary.sha256(bytes)],
            "entry_scene_id": "scene-a", "scene_order": ["scene-a"],
            "overview": ["title": "这家公司自己的问题", "summary": "不要求每家公司有相同章节。", "entries": [["scene_id": "scene-a", "label": "先看这里", "caption": "研究自己的入口", "icon": "circle"]]],
            "coverage": ["mode": "excerpt", "conclusion_ids": [claim.id], "omitted_conclusion_ids": book.research.conclusions.map(\.id).filter { $0 != claim.id }, "essential_refs": [gapRef]],
            "focuses": [focus], "views": [view], "scenes": [scene]
        ]
        return Fixture(research: bytes, reading: reading, factID: fact.id)
    }
    private func open(_ fixture: Fixture) throws -> ReadingLibrary {
        try ReadingLibrary(researchData: fixture.research, readingData: JSONSerialization.data(withJSONObject: fixture.reading, options: [.sortedKeys]))
    }
    private func withNumber(_ input: Fixture) throws -> Fixture {
        var fixture = input
        let book = try ResearchLibrary(researchData: fixture.research)
        let fact = try XCTUnwrap(book.fact(fixture.factID))
        let raw = try XCTUnwrap(Decimal(string: fact.value)); var quotient = raw / 100000000, rounded = Decimal()
        NSDecimalRound(&rounded, &quotient, 2, .plain)
        let factObject = try XCTUnwrap((JSONSerialization.jsonObject(with: fixture.research) as? [String: Any])?["facts"] as? [[String: Any]])
        let basis = try XCTUnwrap(factObject.first { $0["id"] as? String == fact.id }?["time_basis"] as? String)
        let value: [String: Any] = ["ref": ["kind": "fact", "id": fact.id], "label": "原始值", "raw_value": fact.value, "raw_unit": fact.unit,
                                    "display_value": NSDecimalNumber(decimal: rounded).stringValue, "display_unit": "亿元", "entity_id": fact.entityId,
                                    "period_id": fact.periodId, "period_label": book.research.periods.first { $0.id == fact.periodId }!.label, "time_basis": basis]
        var views = fixture.reading["views"] as! [[String: Any]]
        views[0]["kind"] = "comparison"
        views[0]["series"] = [["id": "series-a", "label": "正式数字", "focus_id": "focus-a", "comparison": "not_applicable", "values": [value]]]
        fixture.reading["views"] = views
        return fixture
    }

    func testPackagedReadingIsBoundAndEverySceneHasResearchBackedEntrypoints() throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("Study")
        let reading = try ReadingLibrary(researchData: Data(contentsOf: root.appendingPathComponent("research.json")),
                                         readingData: Data(contentsOf: root.appendingPathComponent("reading.json")))
        XCTAssertFalse(reading.orderedScenes.isEmpty)
        for scene in reading.orderedScenes {
            let focus = try XCTUnwrap(reading.focus(scene.defaultFocusId))
            XCTAssertNotNil(reading.view(scene.viewId))
            XCTAssertFalse(focus.body.isEmpty)
            for id in focus.evidenceIds { XCTAssertFalse(reading.research.pages(for: id).isEmpty) }
            for id in focus.calculationIds { XCTAssertNotNil(reading.research.calculation(id)) }
        }
    }

    func testQualitativeSingleSceneDoesNotRequireFixedCompanyTemplate() throws {
        let fixture = try fixture(), reading = try open(fixture)
        XCTAssertEqual(reading.orderedScenes.count, 1)
        XCTAssertEqual(reading.document.overview.title, "这家公司自己的问题")
        XCTAssertEqual(reading.view("view-a")?.kind, "text")
        XCTAssertEqual(reading.validFocus("focus-a", in: "scene-a"), "focus-a")
        XCTAssertNil(reading.validFocus("a-focus-from-another-scene", in: "scene-a"))
    }

    func testResearchByteMismatchIsRejectedBeforeRendering() throws {
        var fixture = try fixture()
        fixture.research.append(0x20)
        XCTAssertThrowsError(try open(fixture)) { XCTAssertEqual($0 as? ReadingLibrary.ReadingError, .researchMismatch) }
    }

    func testMissingEssentialGapCannotDisappearFromMainScene() throws {
        var fixture = try fixture(), scenes = fixture.reading["scenes"] as! [[String: Any]]
        scenes[0]["essential_notes"] = []
        fixture.reading["scenes"] = scenes
        XCTAssertThrowsError(try open(fixture))
    }

    func testUnknownEvidenceAndBrokenNextSceneAreRejected() throws {
        var fixture = try fixture(), focuses = fixture.reading["focuses"] as! [[String: Any]]
        focuses[0]["evidence_ids"] = ["a-missing-original"]
        fixture.reading["focuses"] = focuses
        XCTAssertThrowsError(try open(fixture))
        fixture = try self.fixture()
        var scenes = fixture.reading["scenes"] as! [[String: Any]]
        scenes[0]["next_scene_id"] = "missing-scene"
        fixture.reading["scenes"] = scenes
        XCTAssertThrowsError(try open(fixture))
    }

    func testNumberUsesPairedResearchAndRejectsAnotherDisplayedAmount() throws {
        var fixture = try withNumber(self.fixture())
        XCTAssertNoThrow(try open(fixture))
        var views = fixture.reading["views"] as! [[String: Any]]
        var series = views[0]["series"] as! [[String: Any]]
        var values = series[0]["values"] as! [[String: Any]]
        values[0]["display_value"] = "1234567.89"
        series[0]["values"] = values; views[0]["series"] = series; fixture.reading["views"] = views
        XCTAssertThrowsError(try open(fixture))
    }

    func testBalanceCannotBeRelabelledAsFlow() throws {
        var fixture = try withNumber(self.fixture())
        var views = fixture.reading["views"] as! [[String: Any]], series = views[0]["series"] as! [[String: Any]]
        var values = series[0]["values"] as! [[String: Any]]
        let old = values[0]["time_basis"] as! String
        values[0]["time_basis"] = old == "balance" ? "flow" : "balance"
        series[0]["values"] = values; views[0]["series"] = series; fixture.reading["views"] = views
        XCTAssertThrowsError(try open(fixture))
    }

    func testGraphLabelsAndArrowsMustMatchResearchRelations() throws {
        var fixture = try fixture(), views = fixture.reading["views"] as! [[String: Any]]
        views[0]["kind"] = "relation_graph"
        views[0]["nodes"] = [
            ["id": "subject-a", "subject_id": "subject-a", "label": "研究中的一个角色", "subtitle": "", "kind": "business_role", "focus_id": "focus-a", "icon": "circle", "row": 0, "column": 0],
            ["id": "subject-b", "subject_id": "subject-b", "label": "另一位参与者", "subtitle": "", "kind": "business_role", "focus_id": "focus-a", "icon": "circle", "row": 1, "column": 1]]
        views[0]["edges"] = [["id": "relation-a", "from_id": "subject-a", "to_id": "subject-b", "label": "研究说明的关系", "kind": "description", "status": "inferred", "focus_id": "focus-a", "note": ""]]
        fixture.reading["views"] = views
        XCTAssertNoThrow(try open(fixture))
        var edges = views[0]["edges"] as! [[String: Any]]
        edges[0]["status"] = "disclosed"
        views[0]["edges"] = edges; fixture.reading["views"] = views
        XCTAssertThrowsError(try open(fixture), "A reading layout cannot upgrade a research inference to a disclosed fact")
    }

    func testUnsupportedExpressionDoesNotSilentlySubstituteAnotherMeaning() throws {
        var fixture = try fixture(), views = fixture.reading["views"] as! [[String: Any]]
        views[0]["kind"] = "execute-arbitrary-drawing-code"
        fixture.reading["views"] = views
        XCTAssertThrowsError(try open(fixture))
    }
}
