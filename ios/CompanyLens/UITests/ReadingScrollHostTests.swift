import SwiftUI
import XCTest

#if canImport(UIKit)
import UIKit

@MainActor
final class ReadingScrollHostTests: XCTestCase {
    func testBrowsingBetweenAnchoredBlocksRestoresTheActualViewportInsteadOfJumpingToTheNextBlock() async throws {
        let host = ReadingScrollController()
        let laidOut = expectation(description: "initial layout")
        let browsed = expectation(description: "a real accessibility scroll is observed")
        let restored = expectation(description: "the gap position is restored")
        var position: ReadingScrollPosition?
        let marker = UIView()
        let content = AnyView(VStack(spacing: 0) {
            Text("First block").frame(height: 100).readingAnchor(id: "first")
            Text("Actions and spacing between blocks").frame(height: 180)
                .background(ScrollTestGeometryMarker(view: marker))
            Text("Next block").frame(height: 400).readingAnchor(id: "next")
        })
        host.render(renderID: "before", target: nil, content: content, onObservation: { event in
            if case .arrival = event.cause { laidOut.fulfill() }
            if case .userBrowsing = event.cause, position == nil { position = event.position; browsed.fulfill() }
        })
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 320, height: 200))
        window.rootViewController = host; window.makeKeyAndVisible()
        defer { window.isHidden = true }
        host.view.layoutIfNeeded()
        await fulfillment(of: [laidOut], timeout: 3)
        XCTAssertTrue(host.view.accessibilityScroll(.down))
        await fulfillment(of: [browsed], timeout: 3)
        let checkpoint = try XCTUnwrap(position)
        XCTAssertEqual(checkpoint.anchorID, "first")
        XCTAssertEqual(checkpoint.localOffset, 160, accuracy: 1)
        let before = marker.convert(marker.bounds, to: window).minY
        host.render(renderID: "returned", target: checkpoint, content: content, onObservation: { event in
            if case .arrival = event.cause { restored.fulfill() }
        })
        host.view.layoutIfNeeded()
        await fulfillment(of: [restored], timeout: 3)
        XCTAssertEqual(marker.convert(marker.bounds, to: window).minY, before, accuracy: 1)
    }

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

    func testAnAlreadyVisibleHostMovesToANewRenderTargetInActualWindowCoordinates() async throws {
        let host = ReadingScrollController()
        let initialArrival = expectation(description: "first render is actually visible")
        let laterArrival = expectation(description: "same host displays the new target")
        let marker = UIView()
        marker.isUserInteractionEnabled = false
        let content = AnyView(VStack(spacing: 0) {
            Text("First").frame(height: 400).readingAnchor(id: "first")
            Text("Second").frame(height: 400).readingAnchor(id: "second")
            Text("Third").frame(maxWidth: .infinity).frame(height: 400)
                .background(ScrollTestGeometryMarker(view: marker)).readingAnchor(id: "third")
            Text("Fourth").frame(height: 400).readingAnchor(id: "fourth")
        })
        var initialObservation: ReadingScrollObservation?
        var laterObservation: ReadingScrollObservation?
        let observe: (ReadingScrollObservation) -> Void = { observation in
            guard case .arrival = observation.cause else { return }
            if observation.renderID == AnyHashable("initial"), initialObservation == nil {
                initialObservation = observation
                initialArrival.fulfill()
            } else if observation.renderID == AnyHashable("retargeted"), laterObservation == nil {
                laterObservation = observation
                laterArrival.fulfill()
            }
        }
        host.render(renderID: "initial", target: ReadingScrollPosition(anchorID: "second", localOffset: 25),
                    content: content, onObservation: observe)
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 320, height: 200))
        window.rootViewController = host
        window.makeKeyAndVisible()
        defer { window.isHidden = true }
        host.view.layoutIfNeeded()
        await fulfillment(of: [initialArrival], timeout: 4)
        let initial = try XCTUnwrap(initialObservation)
        XCTAssertEqual(initial.position.anchorID, "second")
        XCTAssertEqual(initial.position.localOffset, 25, accuracy: 1)
        let viewport = host.view.convert(host.view.bounds, to: window)
        XCTAssertTrue(marker.window === window)
        let initialTarget = marker.convert(marker.bounds, to: window)
        XCTAssertGreaterThan(initialTarget.minY, viewport.maxY)
        XCTAssertEqual(initialTarget.minY, viewport.minY + 375, accuracy: 1)

        host.render(renderID: "retargeted", target: ReadingScrollPosition(anchorID: "third", localOffset: 25),
                    content: content, onObservation: observe)
        host.view.layoutIfNeeded()
        await fulfillment(of: [laterArrival], timeout: 4)
        let actual = try XCTUnwrap(laterObservation)
        XCTAssertEqual(actual.position.anchorID, "third")
        XCTAssertEqual(actual.position.localOffset, 25, accuracy: 1)
        XCTAssertTrue(marker.window === window)
        let visibleTarget = marker.convert(marker.bounds, to: window)
        XCTAssertTrue(visibleTarget.intersects(viewport))
        XCTAssertEqual(visibleTarget.minY, viewport.minY - 25, accuracy: 1)
    }
}

/// A fixture-owned view exposes real window coordinates without inspecting the
/// scroll controller's hierarchy, delegate state, or reported anchor geometry.
private struct ScrollTestGeometryMarker: UIViewRepresentable {
    let view: UIView
    func makeUIView(context: Context) -> UIView { view }
    func updateUIView(_ uiView: UIView, context: Context) {}
    func sizeThatFits(_ proposal: ProposedViewSize, uiView: UIView, context: Context) -> CGSize? {
        CGSize(width: proposal.width ?? 0, height: proposal.height ?? 0)
    }
}
#endif
