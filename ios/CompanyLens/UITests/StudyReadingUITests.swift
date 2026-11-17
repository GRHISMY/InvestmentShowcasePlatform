import XCTest

/// Exercises the same controls used by a reader, including the native PDF host.
final class StudyReadingUITests: XCTestCase {
    func testReturningFromLibraryResumesBothReportAndDiagramPositions() throws {
        continueAfterFailure = false
        let app = XCUIApplication()
        launchReading(app)
        selectDiagram(in: app)
        if app.buttons["study-overview"].waitForExistence(timeout: 3) { app.buttons["study-overview"].tap() }
        app.buttons["study-map-capital-choices"].tap()
        let title = app.staticTexts["study-scene-title"]
        XCTAssertTrue(title.waitForExistence(timeout: 5))
        let originalTitle = title.label
        app.buttons["reader-mode-report"].tap()
        app.buttons["report-contents"].tap()
        app.buttons["2026年销售收款减少，收回贷款补了一部分"].tap()
        let calculation = app.buttons["report-calculation-gree-2026-cash-drivers"]
        reveal(calculation, in: app)
        XCTAssertTrue(calculation.isHittable)
        app.buttons["study-library"].tap()
        let resume = app.buttons["library-continue"]
        XCTAssertTrue(resume.waitForExistence(timeout: 5))
        resume.tap()
        XCTAssertTrue(calculation.waitForExistence(timeout: 5))
        let returned = XCTNSPredicateExpectation(predicate: NSPredicate(format: "hittable == true"), object: calculation)
        XCTAssertEqual(XCTWaiter.wait(for: [returned], timeout: 5), .completed)
        app.buttons["reader-mode-diagram"].tap()
        XCTAssertTrue(title.waitForExistence(timeout: 5))
        XCTAssertEqual(title.label, originalTitle)
        app.buttons["study-library"].tap()
        XCTAssertTrue(resume.waitForExistence(timeout: 5))
        resume.tap()
        XCTAssertTrue(title.waitForExistence(timeout: 5))
        XCTAssertEqual(title.label, originalTitle)
    }

    func testAReadingPositionIsSavedAndTheAppRelaunchesIntoTheSameVersionAndScene() throws {
        continueAfterFailure = false
        let app = XCUIApplication()
        launchReading(app)
        selectDiagram(in: app)
        let overview = app.buttons["study-overview"]
        if overview.waitForExistence(timeout: 3) { overview.tap() }
        app.buttons["study-map-capital-choices"].tap()
        let title = app.staticTexts["study-scene-title"]
        XCTAssertTrue(title.waitForExistence(timeout: 5))
        let expected = title.label
        app.buttons["study-library"].tap()
        XCTAssertTrue(app.buttons["library-continue"].waitForExistence(timeout: 5))
        let saved = app.staticTexts["library-record-status"]
        let durable = XCTNSPredicateExpectation(predicate: NSPredicate(format: "label CONTAINS %@", "已保存在本机"), object: saved)
        XCTAssertEqual(XCTWaiter.wait(for: [durable], timeout: 5), .completed)
        app.terminate()
        app.launch()
        XCTAssertTrue(title.waitForExistence(timeout: 10))
        XCTAssertEqual(title.label, expected)
    }

    func testStudyLibraryOffersICloudConnectionAndThePreparedResearch() throws {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launch()
        let library = app.buttons["study-library"]
        if library.waitForExistence(timeout: 2) { library.tap() }
        XCTAssertTrue(app.buttons["library-connect"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.buttons.matching(identifier: "library-open-current").firstMatch.exists)
    }

    func testNativePDFSwipeUpdatesResumeWithoutChangingItsCitation() throws {
        continueAfterFailure = false
        let app = XCUIApplication()
        launchReading(app)
        selectDiagram(in: app)
        let overview = app.buttons["study-overview"]
        if overview.waitForExistence(timeout: 3) { overview.tap() }
        app.buttons["study-map-business-delivery"].tap()
        app.buttons["study-evidence"].tap()
        app.buttons.matching(identifier: "study-open-pdf").firstMatch.tap()
        let position = app.staticTexts["study-pdf-position"]
        let ready = XCTNSPredicateExpectation(predicate: NSPredicate(format: "value == %@", "原文已打开"), object: position)
        XCTAssertEqual(XCTWaiter.wait(for: [ready], timeout: 15), .completed)
        let original = position.label
        let pages = original.split(separator: "/").compactMap { Int($0.trimmingCharacters(in: .whitespaces)) }
        XCTAssertEqual(pages.count, 2)
        let pdf = app.otherElements["study-native-pdf"].firstMatch
        XCTAssertTrue(pdf.waitForExistence(timeout: 5))
        if pages[0] < pages[1] { pdf.swipeLeft() } else { pdf.swipeRight() }
        let moved = XCTNSPredicateExpectation(predicate: NSPredicate(format: "label != %@", original), object: position)
        XCTAssertEqual(XCTWaiter.wait(for: [moved], timeout: 6), .completed)
        let newPosition = position.label
        let newPage = newPosition.split(separator: "/").first!.trimmingCharacters(in: .whitespaces)
        let resume = app.buttons["study-pdf-resume"]
        XCTAssertEqual(resume.label, "继续读第 " + newPage + " 页")
        app.buttons["study-pdf-citation"].tap()
        let cited = XCTNSPredicateExpectation(predicate: NSPredicate(format: "label == %@", original), object: position)
        XCTAssertEqual(XCTWaiter.wait(for: [cited], timeout: 5), .completed)
        XCTAssertEqual(resume.label, "继续读第 " + newPage + " 页")
        resume.tap()
        let continued = XCTNSPredicateExpectation(predicate: NSPredicate(format: "label == %@", newPosition), object: position)
        XCTAssertEqual(XCTWaiter.wait(for: [continued], timeout: 5), .completed)
        app.buttons["study-pdf-citation"].tap()
        let citedAgain = XCTNSPredicateExpectation(predicate: NSPredicate(format: "label == %@", original), object: position)
        XCTAssertEqual(XCTWaiter.wait(for: [citedAgain], timeout: 5), .completed)
        pdf.pinch(withScale: 1.5, velocity: 1)
        XCTAssertEqual(resume.label, "继续读第 " + newPage + " 页", "Zooming to check a citation preserves the separate PDF resume position")
    }

    func testReportCalculationCanOpenAnInputsEvidenceAndReturnThroughItsSource() throws {
        continueAfterFailure = false
        let app = XCUIApplication()
        launchReading(app)
        let mode = app.buttons["reader-mode-report"]
        XCTAssertTrue(mode.waitForExistence(timeout: 10))
        if mode.isEnabled { mode.tap() }
        app.buttons["report-contents"].tap()
        app.buttons["2026年销售收款减少，收回贷款补了一部分"].tap()
        let calculate = app.buttons["report-calculation-gree-2026-cash-drivers"]
        reveal(calculate, in: app)
        calculate.tap()
        let evidence = app.buttons.matching(identifier: "study-input-evidence-e-q3-cfo26").firstMatch
        reveal(evidence, in: app)
        evidence.tap()
        XCTAssertTrue(app.buttons.matching(identifier: "study-open-pdf").firstMatch.waitForExistence(timeout: 5))
        app.buttons["study-close-evidence"].tap()
        XCTAssertTrue(app.buttons["study-close-calculation"].waitForExistence(timeout: 5))
        app.buttons["study-close-calculation"].tap()
        XCTAssertTrue(calculate.waitForExistence(timeout: 5))
        let restored = XCTNSPredicateExpectation(predicate: NSPredicate(format: "hittable == true"), object: calculate)
        XCTAssertEqual(XCTWaiter.wait(for: [restored], timeout: 5), .completed)
    }

    func testDiagramCanBeEnlargedAndReturnedToTheSameReading() throws {
        continueAfterFailure = false
        let app = XCUIApplication()
        launchReading(app)
        selectDiagram(in: app)
        let overview = app.buttons["study-overview"]
        if overview.waitForExistence(timeout: 3) { overview.tap() }
        let first = app.buttons["study-map-business-delivery"]
        XCTAssertTrue(first.waitForExistence(timeout: 10))
        first.tap()
        let enlarge = app.buttons["study-enlarge-diagram"]
        reveal(enlarge, in: app)
        enlarge.tap()
        let close = app.buttons["关闭全屏图解"]
        XCTAssertTrue(close.waitForExistence(timeout: 5))
        close.tap()
        XCTAssertTrue(app.buttons["study-evidence"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.buttons["study-enlarge-diagram"].exists)
    }

    func testReportContentsCanOpenAJudgmentOutsideTheHeadlines() throws {
        continueAfterFailure = false
        let app = XCUIApplication()
        launchReading(app)
        let mode = app.buttons["reader-mode-report"]
        XCTAssertTrue(mode.waitForExistence(timeout: 10))
        if mode.isEnabled { mode.tap() }
        let contents = app.buttons["report-contents"]
        XCTAssertTrue(contents.waitForExistence(timeout: 3))
        contents.tap()
        let profit = app.buttons["先分清利息记在哪里，再看产品生意赚了多少"]
        XCTAssertTrue(profit.waitForExistence(timeout: 4))
        profit.tap()
        let heading = app.staticTexts["report-heading-gree-profit"]
        let visible = XCTNSPredicateExpectation(predicate: NSPredicate(format: "hittable == true"), object: heading)
        XCTAssertEqual(XCTWaiter.wait(for: [visible], timeout: 5), .completed)
    }

    func testOrdinaryModeSwitchResumesTheReportsOwnPosition() throws {
        continueAfterFailure = false
        let app = XCUIApplication()
        launchReading(app)
        let reportMode = app.buttons["reader-mode-report"]
        XCTAssertTrue(reportMode.waitForExistence(timeout: 10))
        if reportMode.isEnabled { reportMode.tap() }
        app.buttons["report-contents"].tap()
        let quarter = app.buttons["最近一个季度，利润降得比销售金额快得多"]
        XCTAssertTrue(quarter.waitForExistence(timeout: 5))
        quarter.tap()
        let heading = app.staticTexts["report-heading-gree-latest-quarter"]
        XCTAssertTrue(heading.waitForExistence(timeout: 5))
        let visible = XCTNSPredicateExpectation(predicate: NSPredicate(format: "hittable == true"), object: heading)
        let visibility = XCTWaiter.wait(for: [visible], timeout: 5)
        XCTAssertEqual(visibility, .completed)
        app.buttons["reader-mode-diagram"].tap()
        app.buttons["reader-mode-report"].tap()
        XCTAssertTrue(heading.waitForExistence(timeout: 5))
        XCTAssertTrue(heading.isHittable)
    }

    func testMainlineEndsWithoutSendingTheReaderAway() throws {
        continueAfterFailure = false
        let app = XCUIApplication()
        launchReading(app)
        selectDiagram(in: app)
        let overview = app.buttons["study-overview"]
        if overview.waitForExistence(timeout: 3) { overview.tap() }
        let firstScene = app.buttons["study-map-business-delivery"]
        XCTAssertTrue(firstScene.waitForExistence(timeout: 10))
        firstScene.tap()
        for _ in 0..<10 { app.buttons["study-next"].tap() }
        XCTAssertTrue(app.staticTexts["study-mainline-end"].waitForExistence(timeout: 3))
        XCTAssertFalse(app.buttons["study-next"].isEnabled)
        XCTAssertTrue(app.buttons["study-overview"].exists)
    }

    func testReaderCanCheckOriginalPDFAndReturnToTheDiagram() throws {
        continueAfterFailure = false
        let app = XCUIApplication()
        launchReading(app)
        selectDiagram(in: app)

        let overview = app.buttons["study-overview"]
        if overview.waitForExistence(timeout: 3) { overview.tap() }
        let first = app.buttons["study-map-business-delivery"]
        XCTAssertTrue(first.waitForExistence(timeout: 10))
        first.tap()

        let evidence = app.buttons["study-evidence"]
        XCTAssertTrue(evidence.waitForExistence(timeout: 5))
        evidence.tap()
        let original = app.buttons.matching(identifier: "study-open-pdf").firstMatch
        XCTAssertTrue(original.waitForExistence(timeout: 5))
        original.tap()

        let position = app.staticTexts["study-pdf-position"]
        let ready = NSPredicate(format: "value == %@", "原文已打开")
        expectation(for: ready, evaluatedWith: position)
        waitForExpectations(timeout: 15)
        app.buttons["study-close-pdf"].tap()
        XCTAssertTrue(app.buttons["study-close-evidence"].waitForExistence(timeout: 5))
        app.buttons["study-close-evidence"].tap()
        XCTAssertTrue(app.buttons["study-evidence"].waitForExistence(timeout: 5))
    }

    private func launchReading(_ app: XCUIApplication) {
        app.launch()
        let open = app.buttons.matching(identifier: "library-open-current").firstMatch
        if open.waitForExistence(timeout: 3) { open.tap() }
    }

    private func reveal(_ element: XCUIElement, in app: XCUIApplication) {
        XCTAssertTrue(element.waitForExistence(timeout: 8))
        let scroll = app.scrollViews.firstMatch
        for _ in 0..<12 {
            if element.isHittable { return }
            if element.frame.minY < scroll.frame.minY { scroll.swipeDown() }
            else { scroll.swipeUp() }
        }
        XCTAssertTrue(element.isHittable)
    }

    private func selectDiagram(in app: XCUIApplication) {
        let mode = app.buttons["reader-mode-diagram"]
        if mode.waitForExistence(timeout: 3), mode.isEnabled { mode.tap() }
    }
}

/// Opt-in physical-device sampling of the unmodified, complete native reader.
/// Tap-to-accessibility intervals are proxies, not touch-to-presented-frame timings.
final class NativeReportPerformanceUITests: XCTestCase {
    private var environment: [String: String] { ProcessInfo.processInfo.environment }
    private var repetitions: Int { max(1, Int(environment["COMPANYLENS_PERF_REPETITIONS"] ?? "10") ?? 10) }
    private var activeSeconds: Double { Double(environment["COMPANYLENS_PERF_SCROLL_SECONDS"] ?? "30") ?? 30 }

    override func setUpWithError() throws {
        continueAfterFailure = false
        try XCTSkipUnless(environment["COMPANYLENS_PERF_ENABLED"] == "1", "Run Tools/run_native_performance.py explicitly on a physical iPhone")
    }

    func testFreshProcessFirstReport() throws {
        let app = XCUIApplication()
        for sample in 0..<repetitions {
            app.terminate()
            openReading(app)
            selectDiagram(app)
            sampleInterval("fresh-process-first-report", index: sample) {
                app.buttons["reader-mode-report"].tap()
                assertReportReadable(app)
            }
        }
        attachScreenshot(app, name: "fresh-process-report")
    }

    /// One process keeps both modes' own positions throughout all switches.
    func testWarmModeSwitches() throws {
        let app = XCUIApplication()
        openReading(app)
        selectDiagram(app)
        app.buttons["reader-mode-report"].tap()
        assertReportReadable(app)
        selectDiagram(app)
        for sample in 0..<repetitions {
            sampleInterval("warm-diagram-to-report", index: sample) {
                app.buttons["reader-mode-report"].tap()
                assertReportReadable(app)
            }
            sampleInterval("warm-report-to-diagram", index: sample) {
                selectDiagram(app)
            }
        }
        attachScreenshot(app, name: "warm-diagram")
    }

    func testContentsDirectedJumps() throws {
        let app = XCUIApplication()
        openReading(app)
        selectReport(app)
        for sample in 0..<repetitions {
            for (title, id) in jumpTargets {
                let contents = app.buttons["report-contents"]
                contents.tap()
                let destination = app.buttons[title]
                XCTAssertTrue(destination.waitForExistence(timeout: 10))
                sampleInterval("contents-jump-" + id, index: sample) {
                    destination.tap()
                    assertReadable(app.staticTexts["report-heading-" + id])
                }
            }
        }
        attachScreenshot(app, name: "contents-directed-jump")
    }

    func testContinuousScrollAndResume() throws {
        let app = XCUIApplication()
        openReading(app)
        selectReport(app)
        jumpToFirstTarget(app)
        let options = XCTMeasureOptions()
        options.iterationCount = repetitions
        measure(metrics: [XCTOSSignpostMetric.scrollingAndDecelerationMetric], options: options) {
            scroll(app, seconds: activeSeconds, phase: "continuous")
            Thread.sleep(forTimeInterval: 2)
            scroll(app, seconds: activeSeconds / 2, phase: "resumed")
        }
        attachScreenshot(app, name: "after-native-scroll")
    }

    /// Short complete path for an attached Animation Hitches + Time Profiler trace.
    /// The runner starts Instruments after this test emits TRACE_READY.
    func testInstrumentedNativeJourney() throws {
        let app = XCUIApplication()
        openReading(app)
        selectDiagram(app)
        fputs("COMPANYLENS_PERF_TRACE_READY\n", stderr)
        Thread.sleep(forTimeInterval: 10)
        sampleInterval("fresh-process-first-report", index: 0) {
            app.buttons["reader-mode-report"].tap()
            assertReportReadable(app)
        }
        for sample in 0..<repetitions {
            sampleInterval("warm-report-to-diagram", index: sample) { selectDiagram(app) }
            sampleInterval("warm-diagram-to-report", index: sample) {
                app.buttons["reader-mode-report"].tap()
                assertReportReadable(app)
            }
        }
        jumpToFirstTarget(app)
        attachScreenshot(app, name: "complete-formal-report-before-scroll")
        scroll(app, seconds: activeSeconds, phase: "continuous")
        Thread.sleep(forTimeInterval: 2)
        scroll(app, seconds: activeSeconds / 2, phase: "resumed")
        for (title, id) in jumpTargets {
            app.buttons["report-contents"].tap()
            let destination = app.buttons[title]
            XCTAssertTrue(destination.waitForExistence(timeout: 10))
            sampleInterval("contents-jump-" + id, index: 0) {
                destination.tap()
                assertReadable(app.staticTexts["report-heading-" + id])
            }
        }
        attachScreenshot(app, name: "complete-formal-report-after-jumps")
    }

    private let jumpTargets = [
        ("先分清利息记在哪里，再看产品生意赚了多少", "gree-profit"),
        ("最近一个季度，利润降得比销售金额快得多", "gree-latest-quarter"),
        ("2026年销售收款减少，收回贷款补了一部分", "gree-2026-cash-drivers")
    ]

    private func openReading(_ app: XCUIApplication) {
        app.launch()
        let open = app.buttons.matching(identifier: "library-open-current").firstMatch
        if open.waitForExistence(timeout: 3) { open.tap() }
        XCTAssertTrue(app.buttons["reader-mode-diagram"].waitForExistence(timeout: 15))
    }

    private func selectDiagram(_ app: XCUIApplication) {
        app.buttons["reader-mode-diagram"].tap()
        XCTAssertTrue(app.buttons["study-overview"].exists || app.buttons["study-archive"].exists)
        XCTAssertFalse(app.buttons["report-contents"].exists)
    }

    private func selectReport(_ app: XCUIApplication) {
        if !app.buttons["report-contents"].exists { app.buttons["reader-mode-report"].tap() }
        assertReportReadable(app)
    }

    private func assertReportReadable(_ app: XCUIApplication) {
        XCTAssertTrue(app.buttons["report-contents"].waitForExistence(timeout: 30))
        let scroll = app.scrollViews.firstMatch
        assertReadable(scroll)
        XCTAssertTrue(scroll.staticTexts.firstMatch.exists, "The report has native accessibility text")
    }

    private func assertReadable(_ element: XCUIElement) {
        let ready = XCTNSPredicateExpectation(predicate: NSPredicate(format: "exists == true AND hittable == true"), object: element)
        XCTAssertEqual(XCTWaiter.wait(for: [ready], timeout: 30), .completed)
    }

    private func jumpToFirstTarget(_ app: XCUIApplication) {
        app.buttons["report-contents"].tap()
        let target = app.buttons[jumpTargets[0].0]
        XCTAssertTrue(target.waitForExistence(timeout: 10))
        target.tap()
        assertReadable(app.staticTexts["report-heading-" + jumpTargets[0].1])
    }

    private func scroll(_ app: XCUIApplication, seconds: Double, phase: String) {
        let scroll = app.scrollViews.firstMatch
        XCTAssertTrue(scroll.exists)
        let start = ProcessInfo.processInfo.systemUptime
        var gestures = 0
        repeat {
            // Same relative native viewport gesture; reverse periodically to avoid an end stop.
            if gestures % 12 < 8 { scroll.swipeUp(velocity: .fast) }
            else { scroll.swipeDown(velocity: .fast) }
            gestures += 1
        } while ProcessInfo.processInfo.systemUptime - start < seconds
        emit(["scenario": "scroll-" + phase, "started_system_uptime_s": start,
              "elapsed_s": ProcessInfo.processInfo.systemUptime - start, "gestures": gestures,
              "metric_kind": "gesture-window-not-active-frame-time"])
        assertReportReadable(app)
    }

    private func sampleInterval(_ scenario: String, index: Int, action: () -> Void) {
        let start = ProcessInfo.processInfo.systemUptime
        action()
        emit(["scenario": scenario, "sample": index, "started_system_uptime_s": start,
              "elapsed_ms": (ProcessInfo.processInfo.systemUptime - start) * 1000,
              "metric_kind": "xcui-tap-to-accessibility-ready-upper-bound"])
    }

    private func emit(_ value: [String: Any]) {
        let bytes = try! JSONSerialization.data(withJSONObject: value, options: [.sortedKeys])
        let line = String(data: bytes, encoding: .utf8)!
        fputs("COMPANYLENS_PERF_SAMPLE " + line + "\n", stderr)
        let attachment = XCTAttachment(string: line)
        attachment.name = "native-performance-sample"
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    private func attachScreenshot(_ app: XCUIApplication, name: String) {
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }
}
