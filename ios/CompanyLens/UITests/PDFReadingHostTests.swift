import SwiftUI
import PDFKit
import XCTest

#if canImport(UIKit)
import UIKit

@MainActor
final class PDFReadingHostTests: XCTestCase {
    func testRetryCanOpenTheSameURLAfterTheMissingLocalFileBecomesAvailable() async throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let file = folder.appendingPathComponent("original.pdf")
        var loads: [PDFLoadEvent] = []
        var ready: XCTestExpectation?
        func screen(_ attempt: String) -> AnyView {
            AnyView(NativePDFReader(request: PDFReadingRequest(file: file,
                physicalPage: 1, focusText: "", command: .locate, commandID: 0,
                paged: true, attemptID: attempt, renderID: "page-one"),
                onLoad: { loads.append($0); ready?.fulfill(); ready = nil },
                onPageChange: { _ in }))
        }
        let missing = expectation(description: "missing local original has a load result")
        ready = missing
        let host = UIHostingController(rootView: screen("missing"))
        let window = show(host)
        defer { window.isHidden = true }
        await fulfillment(of: [missing], timeout: 3)
        guard case .failure(.missingFile) = try XCTUnwrap(loads.last).result else {
            return XCTFail("the first attempt must report its missing local original")
        }
        try pdf(pages: 2).write(to: file)
        let retried = expectation(description: "a new attempt opens the now available same URL")
        ready = retried
        host.rootView = screen("retry")
        host.view.setNeedsLayout()
        host.view.layoutIfNeeded()
        await fulfillment(of: [retried], timeout: 3)
        let result = try XCTUnwrap(loads.last)
        XCTAssertEqual(result.attemptID, AnyHashable("retry"))
        guard case .success(2) = result.result else { return XCTFail("retry must load the complete two-page original") }
    }

    func testResizingPreservesTheNativeCurrentPageInsteadOfReturningToTheInitialCitation() async throws {
        let file = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".pdf")
        try pdf(pages: 40).write(to: file)
        defer { try? FileManager.default.removeItem(at: file) }
        let loaded = expectation(description: "the full original opens at citation page 29")
        var page35: XCTestExpectation?
        let host = UIHostingController(rootView:
            NativePDFReader(request: PDFReadingRequest(file: file,
                physicalPage: 29, focusText: "", command: .locate, commandID: 0,
                paged: true, attemptID: "original", renderID: "citation-29"),
                onLoad: { if case .success = $0.result { loaded.fulfill() } },
                onPageChange: { if $0.physicalPage == 35 { page35?.fulfill(); page35 = nil } })
        )
        let window = show(host)
        defer { window.isHidden = true }
        await fulfillment(of: [loaded], timeout: 3)
        let native = try XCTUnwrap(pdfView(in: host.view))
        let document = try XCTUnwrap(native.document)
        XCTAssertEqual(document.index(for: try XCTUnwrap(native.currentPage)) + 1, 29)
        let browsed = expectation(description: "PDFKit really changes its current page to 35")
        page35 = browsed
        native.go(to: try XCTUnwrap(document.page(at: 34)))
        await fulfillment(of: [browsed], timeout: 3)
        XCTAssertEqual(document.index(for: try XCTUnwrap(native.currentPage)) + 1, 35)
        window.frame.size.width = 480
        host.view.setNeedsLayout()
        host.view.layoutIfNeeded()
        native.setNeedsLayout()
        native.layoutIfNeeded()
        await Task.yield()
        XCTAssertEqual(native.bounds.width, 480, accuracy: 1, "the native reader receives the resized width")
        XCTAssertEqual(document.index(for: try XCTUnwrap(native.currentPage)) + 1, 35,
                       "rotation or resizing must fit the currently browsed page, not the original citation")
    }

    func testReplacingTheOriginalDoesNotDuplicateRealPDFKitPageObservations() async throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let first = folder.appendingPathComponent("first.pdf"), second = folder.appendingPathComponent("second.pdf")
        try pdf(pages: 2).write(to: first)
        try pdf(pages: 3).write(to: second)
        var ready: XCTestExpectation?
        var changed: XCTestExpectation?
        var pages: [PDFPageEvent] = []
        func screen(_ file: URL, attempt: String) -> AnyView {
            AnyView(NativePDFReader(request: PDFReadingRequest(file: file,
                physicalPage: 1, focusText: "", command: .locate, commandID: 0,
                paged: true, attemptID: attempt, renderID: attempt),
                onLoad: { if case .success = $0.result { ready?.fulfill(); ready = nil } },
                onPageChange: { pages.append($0); changed?.fulfill(); changed = nil }))
        }
        let firstReady = expectation(description: "first original opens")
        ready = firstReady
        let host = UIHostingController(rootView: screen(first, attempt: "first"))
        let window = show(host)
        defer { window.isHidden = true }
        await fulfillment(of: [firstReady], timeout: 3)
        let secondReady = expectation(description: "replacement original opens")
        ready = secondReady
        host.rootView = screen(second, attempt: "second")
        host.view.setNeedsLayout()
        host.view.layoutIfNeeded()
        await fulfillment(of: [secondReady], timeout: 3)
        await withCheckedContinuation { continuation in DispatchQueue.main.async { continuation.resume() } }
        let native = try XCTUnwrap(pdfView(in: host.view))
        let target = try XCTUnwrap(native.document?.page(at: 1))
        var nativeChanges = 0
        let notification = NotificationCenter.default.addObserver(forName: .PDFViewPageChanged,
            object: native, queue: .main) { _ in nativeChanges += 1 }
        defer { NotificationCenter.default.removeObserver(notification) }
        pages.removeAll()
        let moved = expectation(description: "the native current page changes")
        changed = moved
        native.go(to: target)
        await fulfillment(of: [moved], timeout: 3)
        await withCheckedContinuation { continuation in DispatchQueue.main.async { continuation.resume() } }
        XCTAssertGreaterThan(nativeChanges, 0, "the test observes real PDFView notifications")
        XCTAssertEqual(pages.count, nativeChanges, "replacing a document must not leave another page observer attached")
        XCTAssertTrue(pages.allSatisfy { $0.attemptID == AnyHashable("second") && $0.physicalPage == 2 })
    }

    func testAnUnmatchedCitationStillOpensItsPageAndClearsThePreviousHighlight() async throws {
        let file = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".pdf")
        try pdf(pages: 2).write(to: file)
        defer { try? FileManager.default.removeItem(at: file) }
        var loaded: XCTestExpectation?
        var placed: XCTestExpectation?
        var failures = 0
        func screen(page: Int, text: String, command: Int) -> AnyView {
            AnyView(NativePDFReader(request: PDFReadingRequest(file: file,
                physicalPage: page, focusText: text, command: .locate, commandID: command,
                paged: true, attemptID: "original", renderID: command),
                onLoad: { event in
                    if case .failure = event.result { failures += 1 }
                    loaded?.fulfill(); loaded = nil
                }, onPageChange: { if $0.physicalPage == page { placed?.fulfill(); placed = nil } }))
        }
        let first = expectation(description: "the matching original opens")
        loaded = first
        let host = UIHostingController(rootView: screen(page: 1, text: "distinct searchable quotation", command: 0))
        let window = show(host)
        defer { window.isHidden = true }
        await fulfillment(of: [first], timeout: 3)
        let native = try XCTUnwrap(pdfView(in: host.view))
        XCTAssertFalse(native.highlightedSelections?.isEmpty ?? true, "the text fixture really supports a PDFKit highlight")
        let second = expectation(description: "a citation with no text match still opens its physical page")
        placed = second
        host.rootView = screen(page: 2, text: "quotation absent from the original", command: 1)
        host.view.setNeedsLayout()
        host.view.layoutIfNeeded()
        await fulfillment(of: [second], timeout: 3)
        XCTAssertEqual(native.document?.index(for: try XCTUnwrap(native.currentPage)), 1)
        XCTAssertEqual(failures, 0, "a missing highlight is not a document failure")
        XCTAssertTrue(native.highlightedSelections?.isEmpty ?? true, "the prior citation's highlight must be removed")
    }

    func testAQueuedFailureCannotBorrowTheIdentityOfANewSuccessfulAttempt() async throws {
        let file = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".pdf")
        defer { try? FileManager.default.removeItem(at: file) }
        var loads: [PDFLoadEvent] = []
        let opened = expectation(description: "the replacement attempt succeeds")
        func screen(_ attempt: String) -> AnyView {
            AnyView(NativePDFReader(request: PDFReadingRequest(file: file,
                physicalPage: 1, focusText: "", command: .locate, commandID: 0,
                paged: true, attemptID: attempt, renderID: attempt),
                onLoad: { event in
                    loads.append(event)
                    if case .success = event.result { opened.fulfill() }
                }, onPageChange: { _ in }))
        }
        let host = UIHostingController(rootView: screen("missing"))
        let window = show(host)
        defer { window.isHidden = true }
        // The first failure is queued; the next request is accepted before its delivery.
        try pdf(pages: 2).write(to: file)
        host.rootView = screen("replacement")
        host.view.setNeedsLayout()
        host.view.layoutIfNeeded()
        await fulfillment(of: [opened], timeout: 3)
        XCTAssertFalse(loads.contains { event in
            if case .failure = event.result { return event.attemptID == AnyHashable("replacement") }
            return false
        }, "a failure from the previous attempt cannot be relabelled as the new attempt")
        XCTAssertTrue(loads.contains { event in
            if case .success(2) = event.result { return event.attemptID == AnyHashable("replacement") }
            return false
        })
    }

    func testAQueuedNativePageChangeCannotBorrowANewAttemptOrPlacement() async throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let original = folder.appendingPathComponent("original.pdf"), missing = folder.appendingPathComponent("missing.pdf")
        try pdf(pages: 2).write(to: original)
        var ready: XCTestExpectation?
        var pages: [PDFPageEvent] = []
        func screen(_ file: URL, attempt: String) -> AnyView {
            AnyView(NativePDFReader(request: PDFReadingRequest(file: file,
                physicalPage: 1, focusText: "", command: .locate, commandID: 0,
                paged: true, attemptID: attempt, renderID: attempt + "-placement"),
                onLoad: { _ in ready?.fulfill(); ready = nil }, onPageChange: { pages.append($0) }))
        }
        let first = expectation(description: "the first original opens")
        ready = first
        let host = UIHostingController(rootView: screen(original, attempt: "first"))
        let window = show(host)
        defer { window.isHidden = true }
        await fulfillment(of: [first], timeout: 3)
        await withCheckedContinuation { continuation in DispatchQueue.main.async { continuation.resume() } }
        let native = try XCTUnwrap(pdfView(in: host.view))
        let document = try XCTUnwrap(native.document)
        pages.removeAll()
        native.go(to: try XCTUnwrap(document.page(at: 1)))
        XCTAssertEqual(document.index(for: try XCTUnwrap(native.currentPage)), 1)
        let second = expectation(description: "the next original fails locally")
        ready = second
        host.rootView = screen(missing, attempt: "second")
        host.view.setNeedsLayout()
        host.view.layoutIfNeeded()
        await fulfillment(of: [second], timeout: 3)
        XCTAssertFalse(pages.contains { $0.attemptID == AnyHashable("second") || $0.renderID == AnyHashable("second-placement") },
                       "the queued first-document notification cannot acquire the second failed request's keys")
    }

    func testANewPlacementSupersedesAQueuedCitationWithoutNeedingANewControlCommand() async throws {
        let file = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".pdf")
        try pdf(pages: 40).write(to: file)
        defer { try? FileManager.default.removeItem(at: file) }
        let opened = expectation(description: "the full original opens")
        var ready = false
        var pages: [PDFPageEvent] = []
        func screen(page: Int, render: String) -> AnyView {
            AnyView(NativePDFReader(request: PDFReadingRequest(file: file,
                physicalPage: page, focusText: "", command: .locate, commandID: 0,
                paged: true, attemptID: "original", renderID: render),
                onLoad: { event in
                    if case .success = event.result, !ready { ready = true; opened.fulfill() }
                }, onPageChange: { pages.append($0) }))
        }
        let host = UIHostingController(rootView: screen(page: 29, render: "citation-29"))
        let window = show(host)
        defer { window.isHidden = true }
        host.rootView = screen(page: 35, render: "restored-35")
        host.view.setNeedsLayout()
        host.view.layoutIfNeeded()
        await fulfillment(of: [opened], timeout: 3)
        await withCheckedContinuation { continuation in DispatchQueue.main.async { continuation.resume() } }
        let native = try XCTUnwrap(pdfView(in: host.view))
        XCTAssertEqual(native.document?.index(for: try XCTUnwrap(native.currentPage)), 34,
                       "the latest placement is independent of the toolbar command counter")
        XCTAssertFalse(pages.contains { $0.renderID == AnyHashable("restored-35") && $0.physicalPage == 29 },
                       "an old queued citation cannot claim to be the newer placement")
    }

    func testExplicitPageBrowsingAndProgrammaticPageChangesKeepTheirActualCauses() async throws {
        let file = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".pdf")
        try pdf(pages: 3).write(to: file)
        defer { try? FileManager.default.removeItem(at: file) }
        let opened = expectation(description: "the restored original opens")
        var initialLoad = true
        var pages: [PDFPageEvent] = []
        var expectedPage = 0
        var moved: XCTestExpectation?
        func screen(_ action: PDFReadingAction, command: Int) -> AnyView {
            AnyView(NativePDFReader(request: PDFReadingRequest(file: file,
                physicalPage: 1, focusText: "", command: action, commandID: command,
                paged: true, attemptID: "original", renderID: "restored", placementCause: .restoration),
                onLoad: { event in
                    if case .success = event.result, initialLoad { initialLoad = false; opened.fulfill() }
                }, onPageChange: { event in
                    pages.append(event)
                    if event.physicalPage == expectedPage { moved?.fulfill(); moved = nil }
                }))
        }
        let host = UIHostingController(rootView: screen(.locate, command: 0))
        let window = show(host)
        defer { window.isHidden = true }
        await fulfillment(of: [opened], timeout: 3)
        await withCheckedContinuation { continuation in DispatchQueue.main.async { continuation.resume() } }
        XCTAssertTrue(pages.contains { $0.physicalPage == 1 && $0.cause == .restoration })
        pages.removeAll()
        let next = expectation(description: "the next-page control browses the original")
        expectedPage = 2; moved = next
        host.rootView = screen(.nextPage, command: 1)
        host.view.setNeedsLayout()
        host.view.layoutIfNeeded()
        await fulfillment(of: [next], timeout: 3)
        XCTAssertTrue(pages.contains { $0.physicalPage == 2 && $0.cause == .userInteraction },
                      "an explicit next-page action is active browsing")
        pages.removeAll()
        let native = try XCTUnwrap(pdfView(in: host.view))
        let automatic = expectation(description: "a native programmatic move changes the current page")
        expectedPage = 1; moved = automatic
        native.go(to: try XCTUnwrap(native.document?.page(at: 0)))
        await fulfillment(of: [automatic], timeout: 3)
        XCTAssertTrue(pages.allSatisfy { $0.cause == .programmatic },
                      "an idle PDFKit navigation call is not a restoration or user gesture")
    }

    func testNativeAccessibilityPageBrowsingReportsUserInteraction() async throws {
        let file = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".pdf")
        try pdf(pages: 3).write(to: file)
        defer { try? FileManager.default.removeItem(at: file) }
        let opened = expectation(description: "the original opens")
        var moved: XCTestExpectation?
        var pages: [PDFPageEvent] = []
        let host = UIHostingController(rootView:
            NativePDFReader(request: PDFReadingRequest(file: file,
                physicalPage: 1, focusText: "", command: .locate, commandID: 0,
                paged: true, attemptID: "original", renderID: "first-page"),
                onLoad: { if case .success = $0.result { opened.fulfill() } },
                onPageChange: { event in
                    pages.append(event)
                    if event.physicalPage == 2 { moved?.fulfill(); moved = nil }
                })
        )
        let window = show(host)
        defer { window.isHidden = true }
        await fulfillment(of: [opened], timeout: 3)
        await withCheckedContinuation { continuation in DispatchQueue.main.async { continuation.resume() } }
        let native = try XCTUnwrap(pdfView(in: host.view))
        pages.removeAll()
        let didBrowse = native.accessibilityScroll(.down)
        XCTAssertTrue(didBrowse, "the native accessibility action can browse the full original")
        if didBrowse && !pages.contains(where: { $0.physicalPage == 2 }) {
            let changed = expectation(description: "the real native page change is observed")
            moved = changed
            await fulfillment(of: [changed], timeout: 3)
        }
        XCTAssertEqual(native.document?.index(for: try XCTUnwrap(native.currentPage)), 1)
        XCTAssertTrue(pages.contains { $0.physicalPage == 2 && $0.cause == .userInteraction })
    }

    func testPhysicalPageBoundsAndUnreadableOriginalHaveExplicitLocalResults() async throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let valid = folder.appendingPathComponent("original.pdf"), bad = folder.appendingPathComponent("broken.pdf")
        try pdf(pages: 2).write(to: valid)
        try Data("This is not a PDF original.".utf8).write(to: bad)
        for (file, page) in [(valid, 1), (valid, 2), (valid, 0), (valid, 3), (bad, 1)] {
            let completed = expectation(description: "local original produces a definite load result")
            var result: PDFLoadEvent?
            let host = UIHostingController(rootView:
                NativePDFReader(request: PDFReadingRequest(file: file,
                    physicalPage: page, focusText: "not present", command: .locate, commandID: 0,
                    paged: true, attemptID: "bounds", renderID: page),
                    onLoad: { result = $0; completed.fulfill() }, onPageChange: { _ in })
            )
            let window = show(host)
            await fulfillment(of: [completed], timeout: 3)
            let load = try XCTUnwrap(result)
            XCTAssertEqual(load.attemptID, AnyHashable("bounds"))
            switch load.result {
            case .success(let count):
                XCTAssertEqual(file, valid)
                XCTAssertTrue((1...2).contains(page))
                XCTAssertEqual(count, 2)
                let native = try XCTUnwrap(pdfView(in: host.view))
                XCTAssertEqual(native.document?.index(for: try XCTUnwrap(native.currentPage)), page - 1)
            case .failure(.invalidPage): XCTAssertTrue(page == 0 || page == 3)
            case .failure(.invalidDocument): XCTAssertEqual(file, bad)
            case .failure(.missingFile): XCTFail("both local fixture files exist")
            }
            window.isHidden = true
        }
    }

    func testDismantlingStopsQueuedAndLaterRealNativePageObservations() async throws {
        let file = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".pdf")
        try pdf(pages: 2).write(to: file)
        defer { try? FileManager.default.removeItem(at: file) }
        let opened = expectation(description: "the original opens before closing")
        var pages: [PDFPageEvent] = []
        let host = UIHostingController(rootView: AnyView(
            NativePDFReader(request: PDFReadingRequest(file: file,
                physicalPage: 1, focusText: "", command: .locate, commandID: 0,
                paged: true, attemptID: "closed", renderID: "closed"),
                onLoad: { if case .success = $0.result { opened.fulfill() } },
                onPageChange: { pages.append($0) })
        ))
        let window = show(host)
        defer { window.isHidden = true }
        await fulfillment(of: [opened], timeout: 3)
        await withCheckedContinuation { continuation in DispatchQueue.main.async { continuation.resume() } }
        let native = try XCTUnwrap(pdfView(in: host.view))
        let document = try XCTUnwrap(native.document)
        pages.removeAll()
        native.go(to: try XCTUnwrap(document.page(at: 1)))
        host.rootView = AnyView(EmptyView())
        host.view.setNeedsLayout()
        host.view.layoutIfNeeded()
        native.go(to: try XCTUnwrap(document.page(at: 0)))
        await withCheckedContinuation { continuation in DispatchQueue.main.async { continuation.resume() } }
        XCTAssertTrue(pages.isEmpty, "a retained native PDFView cannot update a closed reading host")
    }

    func testPagedOriginalUsesANativePageNavigationContainer() async throws {
        let file = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".pdf")
        try pdf(pages: 3).write(to: file)
        defer { try? FileManager.default.removeItem(at: file) }
        let opened = expectation(description: "the paged original opens")
        let host = UIHostingController(rootView:
            NativePDFReader(request: PDFReadingRequest(file: file,
                physicalPage: 1, focusText: "", command: .locate, commandID: 0,
                paged: true, attemptID: "paged", renderID: "first-page"),
                onLoad: { if case .success = $0.result { opened.fulfill() } }, onPageChange: { _ in })
        )
        let window = show(host)
        defer { window.isHidden = true }
        await fulfillment(of: [opened], timeout: 3)
        let native = try XCTUnwrap(pdfView(in: host.view))
        let pager = try XCTUnwrap(pageController(in: host))
        XCTAssertNotNil(pager.dataSource, "the original has native cross-page navigation")
        XCTAssertTrue(pager.viewControllers?.first?.view === native,
                      "the native pager presents the actual full-document PDFView")
        XCTAssertEqual(native.document?.pageCount, 3)
    }

    func testNativePagingKeepsNewlyVisiblePagesAtTheReadableWidth() async throws {
        let file = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".pdf")
        try pdf(pages: 3).write(to: file)
        defer { try? FileManager.default.removeItem(at: file) }
        let opened = expectation(description: "the first physical page opens")
        var changed: XCTestExpectation?
        let host = UIHostingController(rootView:
            NativePDFReader(request: PDFReadingRequest(file: file,
                physicalPage: 1, focusText: "", command: .locate, commandID: 0,
                paged: true, attemptID: "fit", renderID: "first"),
                onLoad: { if case .success = $0.result { opened.fulfill() } },
                onPageChange: { if $0.physicalPage == 2 { changed?.fulfill(); changed = nil } })
        )
        let window = show(host)
        defer { window.isHidden = true }
        await fulfillment(of: [opened], timeout: 3)
        let native = try XCTUnwrap(pdfView(in: host.view))
        XCTAssertEqual(native.scaleFactor, 0.49, accuracy: 0.02, "the 612-point original fits the 320-point reader")
        let second = expectation(description: "PDFKit itself navigates to the second physical page")
        changed = second
        native.goToNextPage(nil)
        await fulfillment(of: [second], timeout: 3)
        let page = try XCTUnwrap(native.currentPage)
        let visiblePage = native.convert(page.bounds(for: native.displayBox), from: page)
        XCTAssertLessThanOrEqual(visiblePage.width, native.bounds.width + 1,
                                 "the whole newly visible physical page fits the reader width")
        XCTAssertGreaterThan(visiblePage.width, native.bounds.width * 0.9,
                             "native paging keeps the original at a readable width")
    }

    func testAReplacementOriginalFitsItsOwnPaperWidthInTheSameViewport() async throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let first = folder.appendingPathComponent("letter.pdf")
        let wider = folder.appendingPathComponent("wider.pdf")
        try pdf(pages: 2).write(to: first)
        try pdf(pages: 2, pageSize: CGSize(width: 1000, height: 792)).write(to: wider)
        var completed: XCTestExpectation?
        func screen(_ file: URL, attempt: String, command: PDFReadingAction = .locate, commandID: Int = 0) -> AnyView {
            AnyView(NativePDFReader(request: PDFReadingRequest(file: file,
                physicalPage: 1, focusText: "", command: command, commandID: commandID,
                paged: true, attemptID: attempt, renderID: attempt),
                onLoad: { _ in completed?.fulfill(); completed = nil }, onPageChange: { _ in }))
        }
        let opened = expectation(description: "the first paper size fits the reader")
        completed = opened
        let host = UIHostingController(rootView: screen(first, attempt: "letter"))
        let window = show(host)
        defer { window.isHidden = true }
        await fulfillment(of: [opened], timeout: 3)
        let native = try XCTUnwrap(pdfView(in: host.view))
        let originalScale = native.scaleFactor
        host.rootView = screen(first, attempt: "letter", command: .zoomIn, commandID: 1)
        host.view.setNeedsLayout()
        host.view.layoutIfNeeded()
        await withCheckedContinuation { continuation in DispatchQueue.main.async { continuation.resume() } }
        XCTAssertGreaterThan(native.scaleFactor, originalScale, "the reader actually zoomed the earlier original")
        let replaced = expectation(description: "a different paper size opens at the same viewport width")
        completed = replaced
        host.rootView = screen(wider, attempt: "wider")
        host.view.setNeedsLayout()
        host.view.layoutIfNeeded()
        await fulfillment(of: [replaced], timeout: 3)
        XCTAssertTrue(pdfView(in: host.view) === native)
        let page = try XCTUnwrap(native.currentPage)
        XCTAssertEqual(page.bounds(for: native.displayBox).width, 1000, accuracy: 1)
        window.frame.size.width = 480
        host.view.setNeedsLayout()
        host.view.layoutIfNeeded()
        native.setNeedsLayout()
        native.layoutIfNeeded()
        let displayed = native.convert(page.bounds(for: native.displayBox), from: page)
        XCTAssertLessThanOrEqual(displayed.width, native.bounds.width + 1,
                                 "a new original cannot reuse the former source's paper-width basis")
        XCTAssertGreaterThan(displayed.width, native.bounds.width * 0.9)
    }

    func testAFailedReplacementCannotDisplayOrBrowseThePreviousOriginalUnderTheNewAttempt() async throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let original = folder.appendingPathComponent("original.pdf")
        let missing = folder.appendingPathComponent("missing.pdf")
        try pdf(pages: 3).write(to: original)
        var completed: XCTestExpectation?
        var loads: [PDFLoadEvent] = []
        var pages: [PDFPageEvent] = []
        func screen(_ file: URL, attempt: String) -> AnyView {
            AnyView(NativePDFReader(request: PDFReadingRequest(file: file,
                physicalPage: 1, focusText: "distinct searchable quotation", command: .locate, commandID: 0,
                paged: true, attemptID: attempt, renderID: attempt),
                onLoad: { loads.append($0); completed?.fulfill(); completed = nil },
                onPageChange: { pages.append($0) }))
        }
        let opened = expectation(description: "the first original is readable")
        completed = opened
        let host = UIHostingController(rootView: screen(original, attempt: "first"))
        let window = show(host)
        defer { window.isHidden = true }
        await fulfillment(of: [opened], timeout: 3)
        let native = try XCTUnwrap(pdfView(in: host.view))
        XCTAssertEqual(native.document?.pageCount, 3)
        let failed = expectation(description: "the replacement reports its missing local original")
        completed = failed
        host.rootView = screen(missing, attempt: "missing")
        host.view.setNeedsLayout()
        host.view.layoutIfNeeded()
        await fulfillment(of: [failed], timeout: 3)
        guard case .failure(.missingFile) = try XCTUnwrap(loads.last).result else {
            return XCTFail("the replacement must report its own missing file")
        }
        XCTAssertNil(native.document, "a failed replacement cannot keep another source's original on screen")
        XCTAssertTrue(native.highlightedSelections?.isEmpty ?? true)
        pages.removeAll()
        native.goToNextPage(nil)
        await withCheckedContinuation { continuation in DispatchQueue.main.async { continuation.resume() } }
        XCTAssertTrue(pages.isEmpty, "the prior original cannot emit page facts under the failed attempt")
    }

    func testAContinuousOriginalKeepsVerticalPDFKitNavigationWithoutHorizontalPaging() async throws {
        let file = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".pdf")
        try pdf(pages: 3).write(to: file)
        defer { try? FileManager.default.removeItem(at: file) }
        let opened = expectation(description: "the continuous original opens")
        let host = UIHostingController(rootView:
            NativePDFReader(request: PDFReadingRequest(file: file,
                physicalPage: 1, focusText: "", command: .locate, commandID: 0,
                paged: false, attemptID: "continuous", renderID: "first"),
                onLoad: { if case .success = $0.result { opened.fulfill() } }, onPageChange: { _ in })
        )
        let window = show(host)
        defer { window.isHidden = true }
        await fulfillment(of: [opened], timeout: 3)
        let native = try XCTUnwrap(pdfView(in: host.view))
        XCTAssertEqual(native.document?.pageCount, 3)
        XCTAssertEqual(native.displayMode, .singlePageContinuous)
        XCTAssertEqual(native.displayDirection, .vertical)
        XCTAssertNil(try XCTUnwrap(pageController(in: host)).dataSource,
                     "a continuous original cannot switch to a horizontal single-page child")
    }

    func testCancelledNativePageDragKeepsTheIndependentResumePage() throws {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launch()
        let open = app.buttons.matching(identifier: "library-open-current").firstMatch
        if open.waitForExistence(timeout: 3) { open.tap() }
        let diagram = app.tabBars.buttons["workspace-tab-diagram"]
        XCTAssertTrue(diagram.waitForExistence(timeout: 10))
        diagram.tap()
        let selected = XCTNSPredicateExpectation(predicate: NSPredicate(format: "selected == true"), object: diagram)
        XCTAssertEqual(XCTWaiter.wait(for: [selected], timeout: 5), .completed)
        XCTAssertFalse(app.tabBars.buttons["workspace-tab-report"].isSelected)
        XCTAssertFalse(app.tabBars.buttons["workspace-tab-library"].isSelected)
        let overview = app.buttons["study-overview"]
        if overview.waitForExistence(timeout: 3) { overview.tap() }
        app.buttons["study-map-business-delivery"].tap()
        app.buttons["study-evidence"].tap()
        app.buttons.matching(identifier: "study-open-pdf").firstMatch.tap()
        let position = app.staticTexts["study-pdf-position"]
        let ready = XCTNSPredicateExpectation(predicate: NSPredicate(format: "value == %@", "原文已打开"), object: position)
        XCTAssertEqual(XCTWaiter.wait(for: [ready], timeout: 15), .completed)
        let citation = position.label
        app.buttons["study-pdf-next"].tap()
        let next = XCTNSPredicateExpectation(predicate: NSPredicate(format: "label != %@", citation), object: position)
        XCTAssertEqual(XCTWaiter.wait(for: [next], timeout: 5), .completed)
        let resume = app.buttons["study-pdf-resume"]
        let independentResume = resume.label
        app.buttons["study-pdf-citation"].tap()
        let returned = XCTNSPredicateExpectation(predicate: NSPredicate(format: "label == %@", citation), object: position)
        XCTAssertEqual(XCTWaiter.wait(for: [returned], timeout: 5), .completed)
        let pdf = app.otherElements["study-native-pdf"].firstMatch
        XCTAssertTrue(pdf.waitForExistence(timeout: 5))
        // A slow, short drag released well before halfway is a real cancelled
        // native page turn, rather than a delegate callback invoked by the test.
        pdf.coordinate(withNormalizedOffset: CGVector(dx: 0.65, dy: 0.5)).press(forDuration: 0.05,
            thenDragTo: pdf.coordinate(withNormalizedOffset: CGVector(dx: 0.55, dy: 0.5)),
            withVelocity: XCUIGestureVelocity(rawValue: 40), thenHoldForDuration: 0.3)
        XCTAssertEqual(position.label, citation, "the partial drag leaves the citation page visible")
        XCTAssertEqual(resume.label, independentResume, "a cancelled turn is not browsing another physical page")
        app.terminate()
    }

    private func pageController(in controller: UIViewController) -> UIPageViewController? {
        if let pager = controller as? UIPageViewController { return pager }
        return controller.children.lazy.compactMap { self.pageController(in: $0) }.first
    }

    private func pdfView(in view: UIView) -> PDFView? {
        if let pdf = view as? PDFView { return pdf }
        return view.subviews.lazy.compactMap { self.pdfView(in: $0) }.first
    }

    private func show<V: View>(_ host: UIHostingController<V>) -> UIWindow {
        host.safeAreaRegions = []
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 320, height: 600))
        window.rootViewController = host
        window.makeKeyAndVisible()
        host.view.setNeedsLayout()
        host.view.layoutIfNeeded()
        return window
    }

    private func pdf(pages: Int, pageSize: CGSize = CGSize(width: 612, height: 792)) -> Data {
        UIGraphicsPDFRenderer(bounds: CGRect(origin: .zero, size: pageSize)).pdfData { context in
            for page in 1...pages {
                context.beginPage()
                ("Original physical page \(page)\nA distinct searchable quotation." as NSString)
                    .draw(at: CGPoint(x: 40, y: 40), withAttributes: [.font: UIFont.systemFont(ofSize: 18)])
            }
        }
    }
}
#endif
