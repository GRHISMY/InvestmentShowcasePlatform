import Foundation
import XCTest
import ResearchCore

final class ReadingCheckpointContractTests: XCTestCase {
    func testCheckpointPreservesOnlyTheSuppliedSlotPayloadAndOccurrenceTime() throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("Study")
        let identity = try ReadableStudy(root: root).identity
        let slot = ReadingSlotCheckpoint(slotKey: ReadingCheckpoint.mainSlotKey,
            payload: Data("opaque-main-position".utf8), occurredAt: Date(timeIntervalSince1970: 1234))
        let checkpoint = ReadingCheckpoint(identity: identity,
            eventID: UUID(uuidString: "00000000-0000-0000-0000-000000000001")!, updates: [slot])
        let restored = try JSONDecoder().decode(ReadingCheckpoint.self, from: JSONEncoder().encode(checkpoint))
        XCTAssertEqual(restored, checkpoint)
        XCTAssertEqual(restored.updates.count, 1)
        XCTAssertEqual(restored.updates[0].occurredAt, Date(timeIntervalSince1970: 1234))
        let candidates = RestoreCandidates(identity: identity, candidates: restored.updates)
        XCTAssertEqual(candidates.candidates, [slot])
    }
}
