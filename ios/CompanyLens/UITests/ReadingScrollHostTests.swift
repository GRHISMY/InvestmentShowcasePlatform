import SwiftUI
import XCTest

#if canImport(UIKit)
import UIKit

@MainActor
final class ReadingScrollHostTests: XCTestCase {
    func testAnUnlaidHostDoesNotClaimItsRequestedPositionIsVisible() {
        let host = ReadingScrollController()
        var observations: [ReadingScrollObservation] = []
        host.render(renderID: "unlaid", target: ReadingScrollPosition(anchorID: "second"),
                    content: AnyView(VStack(spacing: 0) {
                        Text("First").frame(height: 400).readingAnchor(id: "first")
                        Text("Second").frame(height: 400).readingAnchor(id: "second")
                    }), onObservation: { observations.append($0) })
        XCTAssertTrue(observations.isEmpty)
    }

    func testActualLayoutRestoresTheRequestedAnchorAndLocalOffset() async throws {
        let host = ReadingScrollController()
        let visible = expectation(description: "laid out restored content is visible")
        var arrival: ReadingScrollObservation?
        host.render(renderID: "laid-out", target: ReadingScrollPosition(anchorID: "second", localOffset: 25),
                    content: AnyView(VStack(spacing: 0) {
                        Text("First").frame(height: 400).readingAnchor(id: "first")
                        Text("Second").frame(height: 400).readingAnchor(id: "second")
                    }), onObservation: { observation in
                        if case .arrival = observation.cause, arrival == nil {
                            arrival = observation
                            visible.fulfill()
                        }
                    })
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 320, height: 200))
        window.rootViewController = host
        window.makeKeyAndVisible()
        defer { window.isHidden = true }
        host.view.layoutIfNeeded()
        await fulfillment(of: [visible], timeout: 4)
        let actual = try XCTUnwrap(arrival)
        XCTAssertEqual(actual.renderID, AnyHashable("laid-out"))
        XCTAssertEqual(actual.position.anchorID, "second")
        XCTAssertEqual(actual.position.localOffset, 25, accuracy: 1)
    }

    func testUserScrollDoesNotAuthorizeLaterProgrammaticReflowAsBrowsing() async {
        let host = ReadingScrollController()
        let arrived = expectation(description: "initial content is laid out")
        let browsed = expectation(description: "native accessibility scroll browses actual content")
        var passiveReflow: XCTestExpectation?
        var receivedArrival = false, receivedBrowsing = false
        let observe: (ReadingScrollObservation) -> Void = { observation in
            switch observation.cause {
            case .arrival:
                if !receivedArrival { receivedArrival = true; arrived.fulfill() }
            case .userBrowsing:
                if !receivedBrowsing { receivedBrowsing = true; browsed.fulfill() }
                else { passiveReflow?.fulfill() }
            }
        }
        let content = AnyView(VStack(spacing: 0) {
            Text("First").frame(height: 400).readingAnchor(id: "first")
            Text("Second").frame(height: 400).readingAnchor(id: "second")
            Text("Third").frame(height: 400).readingAnchor(id: "third")
        })
        host.render(renderID: "reflow", target: nil, content: content, onObservation: observe)
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 320, height: 200))
        window.rootViewController = host
        window.makeKeyAndVisible()
        defer { window.isHidden = true }
        host.view.layoutIfNeeded()
        await fulfillment(of: [arrived], timeout: 4)
        XCTAssertTrue(host.view.accessibilityScroll(.down))
        await fulfillment(of: [browsed], timeout: 2)

        let noBrowsing = expectation(description: "font and layout changes are not a user scroll")
        noBrowsing.isInverted = true
        passiveReflow = noBrowsing
        host.render(renderID: "reflow", target: nil,
                    content: AnyView(VStack(spacing: 0) {
                        Text("First changed").frame(height: 650).readingAnchor(id: "first")
                        Text("Second changed").frame(height: 500).readingAnchor(id: "second")
                    }.environment(\.dynamicTypeSize, .accessibility3)), onObservation: observe)
        host.view.setNeedsLayout()
        host.view.layoutIfNeeded()
        await fulfillment(of: [noBrowsing], timeout: 0.3)
    }
}
#endif
