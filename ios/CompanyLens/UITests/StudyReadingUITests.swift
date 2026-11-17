import XCTest
import UIKit

private enum WorkspaceTab: String, CaseIterable {
    case library, diagram, report
}

private extension XCTestCase {
    func reportContentsDestination(_ title: String, in app: XCUIApplication) -> XCUIElement {
        app.buttons["report-contents"].tap()
        let search = app.searchFields.firstMatch
        XCTAssertTrue(search.waitForExistence(timeout: 5))
        search.tap()
        search.typeText(title)
        let destination = app.buttons[title]
        XCTAssertTrue(destination.waitForExistence(timeout: 5))
        return destination
    }

    func selectWorkspaceTab(_ tab: WorkspaceTab, in app: XCUIApplication,
                            file: StaticString = #filePath, line: UInt = #line) {
        let button = app.tabBars.buttons["workspace-tab-" + tab.rawValue]
        XCTAssertTrue(button.waitForExistence(timeout: 10), file: file, line: line)
        button.tap()
        assertWorkspaceTab(tab, in: app, file: file, line: line)
    }

    func assertWorkspaceTab(_ tab: WorkspaceTab, in app: XCUIApplication,
                            file: StaticString = #filePath, line: UInt = #line) {
        let selected = app.tabBars.buttons["workspace-tab-" + tab.rawValue]
        let accepted = XCTNSPredicateExpectation(predicate: NSPredicate(format: "selected == true"), object: selected)
        XCTAssertEqual(XCTWaiter.wait(for: [accepted], timeout: 5), .completed, file: file, line: line)
        for other in WorkspaceTab.allCases where other != tab {
            let button = app.tabBars.buttons["workspace-tab-" + other.rawValue]
            XCTAssertTrue(button.exists, file: file, line: line)
            XCTAssertFalse(button.isSelected, file: file, line: line)
        }
    }
}

/// Exercises the same controls used by a reader, including the native PDF host.
final class StudyReadingUITests: XCTestCase {
    func testFullReportContentsReachMonitoringAndRetargetFromADistantNonzeroPosition() throws {
        continueAfterFailure = false
        let app = XCUIApplication()
        launchReading(app)
        selectWorkspaceTab(.report, in: app)
        reportContentsDestination("最近一个季度，利润降得比销售金额快得多", in: app).tap()
        let quarter = app.staticTexts["report-heading-gree-latest-quarter"]
        let arrived = XCTNSPredicateExpectation(predicate: NSPredicate(format: "hittable == true"), object: quarter)
        XCTAssertEqual(XCTWaiter.wait(for: [arrived], timeout: 8), .completed)
        let sourceY = quarter.frame.minY
        app.buttons["report-contents"].tap()
        app.buttons["report-contents-close"].tap()
        assertRestored(quarter, to: sourceY)
        reportContentsDestination("继续查用户实际买了多少、维修结果怎样，以及经销商手里还有多少没卖出的货。", in: app).tap()
        let status = app.staticTexts["report-monitor-status-monitor-customer"]
        reveal(status, in: app)
        XCTAssertEqual(status.label, "状态：待核对")
        XCTAssertEqual(app.staticTexts["report-monitor-trigger-monitor-customer"].label, "何时跟进：相关事件发生时")
        reportContentsDestination("完整研究摘要", in: app).tap()
        let summary = app.staticTexts["report-summary-heading"]
        let returned = XCTNSPredicateExpectation(predicate: NSPredicate(format: "hittable == true"), object: summary)
        XCTAssertEqual(XCTWaiter.wait(for: [returned], timeout: 8), .completed)
        attachReportScreenshot(app, name: "report-complete-summary")
        assertWorkspaceTab(.report, in: app)
    }

    func testCompleteReportRemainsReadableWithAccessibilityTextAndSafeAreas() throws {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchArguments += ["-UIPreferredContentSizeCategoryName", "UICTContentSizeCategoryAccessibilityXXXL"]
        launchReading(app)
        selectWorkspaceTab(.report, in: app)
        reportContentsDestination("最近一个季度，利润降得比销售金额快得多", in: app).tap()
        let heading = app.staticTexts["report-heading-gree-latest-quarter"]
        let visible = XCTNSPredicateExpectation(predicate: NSPredicate(format: "hittable == true"), object: heading)
        XCTAssertEqual(XCTWaiter.wait(for: [visible], timeout: 8), .completed)
        XCTAssertLessThanOrEqual(heading.frame.maxX, app.frame.maxX)
        XCTAssertGreaterThanOrEqual(heading.frame.minX, app.frame.minX)
        XCTAssertTrue(app.tabBars.buttons["workspace-tab-report"].isHittable)
        app.scrollViews.firstMatch.swipeUp()
        attachReportScreenshot(app, name: "report-accessibility-long-prose")
    }

    func testAnUnassociatedReportJudgmentClearlyExplainsTheMissingDiagram() throws {
        continueAfterFailure = false
        let app = XCUIApplication()
        launchReading(app)
        selectWorkspaceTab(.report, in: app)
        reportContentsDestination("先分清利息记在哪里，再看产品生意赚了多少", in: app).tap()
        let absence = app.staticTexts["report-no-diagram-gree-profit"]
        reveal(absence, in: app)
        XCTAssertEqual(absence.label, "这条判断暂无关联图解，可继续核对计算与依据。")
        XCTAssertTrue(absence.isHittable)
        assertWorkspaceTab(.report, in: app)
    }

    func testReturningFromLibraryResumesBothReportAndDiagramPositions() throws {
        continueAfterFailure = false
        let app = XCUIApplication()
        launchReading(app)
        selectDiagram(in: app)
        if app.buttons["study-overview"].waitForExistence(timeout: 3) { app.buttons["study-overview"].tap() }
        openOverviewScene("capital-choices", in: app)
        let title = app.staticTexts["study-scene-title"]
        XCTAssertTrue(title.waitForExistence(timeout: 5))
        let originalTitle = title.label
        selectWorkspaceTab(.report, in: app)
        reportContentsDestination("2026年销售收款减少，收回贷款补了一部分", in: app).tap()
        let calculation = app.buttons["report-calculation-gree-2026-cash-drivers"]
        reveal(calculation, in: app)
        XCTAssertTrue(calculation.isHittable)
        selectWorkspaceTab(.library, in: app)
        let resume = app.buttons["library-continue"]
        XCTAssertTrue(resume.waitForExistence(timeout: 5))
        resume.tap()
        assertWorkspaceTab(.report, in: app)
        XCTAssertTrue(calculation.waitForExistence(timeout: 5))
        let returned = XCTNSPredicateExpectation(predicate: NSPredicate(format: "hittable == true"), object: calculation)
        XCTAssertEqual(XCTWaiter.wait(for: [returned], timeout: 5), .completed)
        selectWorkspaceTab(.diagram, in: app)
        XCTAssertTrue(title.waitForExistence(timeout: 5))
        XCTAssertEqual(title.label, originalTitle)
        selectWorkspaceTab(.library, in: app)
        XCTAssertTrue(resume.waitForExistence(timeout: 5))
        resume.tap()
        assertWorkspaceTab(.diagram, in: app)
        XCTAssertTrue(title.waitForExistence(timeout: 5))
        XCTAssertEqual(title.label, originalTitle)
    }

    func testNativeTabsFollowAssociationsBackAndLibraryResumeInTheSameStudy() throws {
        continueAfterFailure = false
        let app = XCUIApplication()
        launchReading(app)
        selectWorkspaceTab(.library, in: app)
        XCTAssertTrue(app.buttons["library-continue"].waitForExistence(timeout: 5))

        selectWorkspaceTab(.diagram, in: app)
        assertCompany(in: app)
        let overview = app.buttons["study-overview"]
        if overview.waitForExistence(timeout: 3) { overview.tap() }
        openOverviewScene("capital-choices", in: app)
        XCTAssertTrue(app.staticTexts["study-scene-title"].waitForExistence(timeout: 5))
        XCTAssertEqual(app.staticTexts["study-scene-title"].label, "金融资产增加，一些项目却停了。")

        selectWorkspaceTab(.report, in: app)
        assertCompany(in: app)
        reportContentsDestination("2026年销售收款减少，收回贷款补了一部分", in: app).tap()
        XCTAssertTrue(app.staticTexts["report-heading-gree-2026-cash-drivers"].waitForExistence(timeout: 5))

        // This declared report association targets a nondefault focus in the real cash diagram.
        let association = app.buttons["report-diagram-11:cash-recentcash-sales"]
        reveal(association, in: app)
        let sourceY = association.frame.minY
        association.tap()
        assertWorkspaceTab(.diagram, in: app)
        assertCompany(in: app)
        XCTAssertTrue(app.staticTexts["study-scene-title"].waitForExistence(timeout: 5))
        XCTAssertEqual(app.staticTexts["study-scene-title"].label, "销售收款减少，贷款回收补了一部分。")
        XCTAssertTrue(app.staticTexts["只看销售收回的钱"].waitForExistence(timeout: 5))

        reveal(app.buttons["study-back"], in: app)
        app.buttons["study-back"].tap()
        assertWorkspaceTab(.report, in: app)
        assertCompany(in: app)
        assertRestored(association, to: sourceY)

        selectWorkspaceTab(.library, in: app)
        let resume = app.buttons["library-continue"]
        XCTAssertTrue(resume.waitForExistence(timeout: 5))
        resume.tap()
        assertWorkspaceTab(.report, in: app)
        assertCompany(in: app)
        assertRestored(association, to: sourceY)

        selectWorkspaceTab(.diagram, in: app)
        assertCompany(in: app)
        XCTAssertEqual(app.staticTexts["study-scene-title"].label, "销售收款减少，贷款回收补了一部分。")
        XCTAssertTrue(app.staticTexts["只看销售收回的钱"].waitForExistence(timeout: 5),
                      "Returning to the diagram preserves the association's selected focus")
    }

    func testAReadingPositionIsSavedAndTheAppRelaunchesIntoTheSameVersionAndScene() throws {
        continueAfterFailure = false
        let app = XCUIApplication()
        launchReading(app)
        selectDiagram(in: app)
        let overview = app.buttons["study-overview"]
        if overview.waitForExistence(timeout: 3) { overview.tap() }
        openOverviewScene("capital-choices", in: app)
        let title = app.staticTexts["study-scene-title"]
        XCTAssertTrue(title.waitForExistence(timeout: 5))
        let expected = title.label
        selectWorkspaceTab(.library, in: app)
        XCTAssertTrue(app.buttons["library-continue"].waitForExistence(timeout: 5))
        let saved = app.staticTexts["library-record-status"]
        let durable = XCTNSPredicateExpectation(predicate: NSPredicate(format: "label CONTAINS %@", "已保存在本机"), object: saved)
        XCTAssertEqual(XCTWaiter.wait(for: [durable], timeout: 5), .completed)
        app.terminate()
        app.launch()
        XCTAssertTrue(title.waitForExistence(timeout: 10))
        assertWorkspaceTab(.diagram, in: app)
        XCTAssertEqual(title.label, expected)
    }

    func testStudyLibraryOffersICloudConnectionAndThePreparedResearch() throws {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launch()
        selectWorkspaceTab(.library, in: app)
        XCTAssertTrue(app.buttons.matching(identifier: "library-open-current").firstMatch.exists)
        attachReportScreenshot(app, name: "native-library-reading-title")
        let sync = app.buttons["library-sync"]
        XCTAssertTrue(sync.waitForExistence(timeout: 5))
        sync.tap()
        XCTAssertTrue(app.buttons["library-connect"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.staticTexts["library-record-status"].exists)
        attachReportScreenshot(app, name: "native-library-sync-sheet")
    }

    func testNativePDFSwipeUpdatesResumeWithoutChangingItsCitation() throws {
        continueAfterFailure = false
        let app = XCUIApplication()
        launchReading(app)
        selectDiagram(in: app)
        let overview = app.buttons["study-overview"]
        if overview.waitForExistence(timeout: 3) { overview.tap() }
        openOverviewScene("business-delivery", in: app)
        reveal(app.buttons["study-evidence"], in: app)
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
        selectWorkspaceTab(.report, in: app)
        reportContentsDestination("2026年销售收款减少，收回贷款补了一部分", in: app).tap()
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

    func testPublishedLongDiagramTitleWrapsInsideTheMainReadingViewport() throws {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchArguments += ["-UIPreferredContentSizeCategoryName", "UICTContentSizeCategoryL"]
        launchReading(app)
        selectDiagram(in: app)
        if app.buttons["study-overview"].waitForExistence(timeout: 3) { app.buttons["study-overview"].tap() }
        openOverviewScene("business-delivery", in: app)
        for _ in 0..<2 {
            reveal(app.buttons["study-next"], in: app)
            app.buttons["study-next"].tap()
        }
        let title = app.staticTexts["study-scene-title"]
        XCTAssertTrue(title.waitForExistence(timeout: 5))
        XCTAssertEqual(title.label, "看到了具体行动，还缺赚钱的那一段证据。")
        XCTAssertGreaterThanOrEqual(title.frame.minX, app.frame.minX + 16)
        XCTAssertLessThanOrEqual(title.frame.maxX, app.frame.maxX - 16)
        if app.frame.width < 500 { XCTAssertGreaterThan(title.frame.height, 50, "The full published title wraps at phone width") }
        attachReportScreenshot(app, name: "native-diagram-full-long-title")
    }

    func testDiagramCanBeEnlargedAndReturnedToTheSameReading() throws {
        continueAfterFailure = false
        let app = XCUIApplication()
        launchReading(app)
        selectDiagram(in: app)
        let overview = app.buttons["study-overview"]
        if overview.waitForExistence(timeout: 3) { overview.tap() }
        openOverviewScene("business-delivery", in: app)
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
        selectWorkspaceTab(.report, in: app)
        reportContentsDestination("先分清利息记在哪里，再看产品生意赚了多少", in: app).tap()
        let heading = app.staticTexts["report-heading-gree-profit"]
        let visible = XCTNSPredicateExpectation(predicate: NSPredicate(format: "hittable == true"), object: heading)
        XCTAssertEqual(XCTWaiter.wait(for: [visible], timeout: 5), .completed)
    }

    func testOrdinaryModeSwitchResumesTheReportsOwnPosition() throws {
        continueAfterFailure = false
        let app = XCUIApplication()
        launchReading(app)
        selectWorkspaceTab(.report, in: app)
        reportContentsDestination("最近一个季度，利润降得比销售金额快得多", in: app).tap()
        let heading = app.staticTexts["report-heading-gree-latest-quarter"]
        XCTAssertTrue(heading.waitForExistence(timeout: 5))
        let visible = XCTNSPredicateExpectation(predicate: NSPredicate(format: "hittable == true"), object: heading)
        let visibility = XCTWaiter.wait(for: [visible], timeout: 5)
        XCTAssertEqual(visibility, .completed)
        selectWorkspaceTab(.diagram, in: app)
        selectWorkspaceTab(.report, in: app)
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
        openOverviewScene("business-delivery", in: app)
        for _ in 0..<10 {
            reveal(app.buttons["study-next"], in: app)
            app.buttons["study-next"].tap()
        }
        reveal(app.staticTexts["study-mainline-end"], in: app)
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
        openOverviewScene("business-delivery", in: app)

        let evidence = app.buttons["study-evidence"]
        reveal(evidence, in: app)
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

    private func attachReportScreenshot(_ app: XCUIApplication, name: String) {
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    private func assertCompany(in app: XCUIApplication) {
        let company = app.staticTexts["workspace-company-title"]
        XCTAssertTrue(company.waitForExistence(timeout: 5))
        XCTAssertEqual(company.label, "格力电器")
    }

    private func assertRestored(_ element: XCUIElement, to sourceY: CGFloat) {
        let restored = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in
            element.exists && element.isHittable && abs(element.frame.minY - sourceY) <= 24
        }, object: element)
        XCTAssertEqual(XCTWaiter.wait(for: [restored], timeout: 5), .completed,
                       "Returning restores the report's actual scrolled source position")
    }

    private func openOverviewScene(_ sceneID: String, in app: XCUIApplication) {
        let target = app.buttons["study-map-" + sceneID]
        let first = app.buttons["study-map-business-delivery"]
        let scroll = app.scrollViews.firstMatch
        // Restore may start below the map, so first find its real beginning.
        for _ in 0..<8 {
            if first.exists && first.isHittable { break }
            scroll.swipeDown()
        }
        for _ in 0..<8 {
            if target.exists && target.isHittable { target.tap(); return }
            scroll.swipeUp()
        }
        XCTFail("The published overview scene did not become reachable: " + sceneID)
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
        selectWorkspaceTab(.diagram, in: app)
    }
}

/// Opt-in physical-device sampling of the complete native reader.
/// Tap-to-accessibility intervals are proxies, not touch-to-presented-frame timings.
final class NativeReportPerformanceUITests: XCTestCase {
    private var environment: [String: String] { ProcessInfo.processInfo.environment }
    private var repetitions: Int { max(1, Int(environment["COMPANYLENS_PERF_REPETITIONS"] ?? "10") ?? 10) }
    private var activeSeconds: Double { Double(environment["COMPANYLENS_PERF_SCROLL_SECONDS"] ?? "30") ?? 30 }

    override func setUpWithError() throws {
        continueAfterFailure = false
        try XCTSkipUnless(environment["COMPANYLENS_PERF_ENABLED"] == "1", "Run Tools/run_native_performance.py explicitly on a physical iPhone")
        XCUIDevice.shared.orientation = .portrait
        recordRunnerConditions("test-setup")
    }

    func testFreshProcessFirstReport() throws {
        for sample in 0..<repetitions {
            let expectedDiagram = prepareDurableFreshProcessPositions(XCUIApplication())
            let app = XCUIApplication()
            openReading(app)
            assertRestoredDiagram(app, expectedTitle: expectedDiagram)
            sampleInterval("fresh-process-first-report", index: sample) {
                selectWorkspaceTab(.report, in: app)
                assertReportReadable(app)
            }
        }
        attachScreenshot(XCUIApplication(), name: "fresh-process-report")
    }

    /// One process keeps both modes' own positions throughout all switches.
    func testWarmModeSwitches() throws {
        let app = XCUIApplication()
        openReading(app)
        selectDiagram(app)
        selectWorkspaceTab(.report, in: app)
        assertReportReadable(app)
        selectDiagram(app)
        for sample in 0..<repetitions {
            sampleInterval("warm-diagram-to-report", index: sample) {
                selectWorkspaceTab(.report, in: app)
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
                let destination = reportContentsDestination(title, in: app)
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
        defer { recordRunnerConditions("journey-after") }
        let expectedDiagram = prepareDurableFreshProcessPositions(XCUIApplication())
        if environment["COMPANYLENS_PERF_ACTIVATE_EXISTING"] == "1" {
            fputs("COMPANYLENS_PERF_PRELAUNCH_READY\n", stderr)
            Thread.sleep(forTimeInterval: 10)
        }
        let app = XCUIApplication()
        openReading(app)
        assertRestoredDiagram(app, expectedTitle: expectedDiagram)
        recordRunnerConditions("journey-before")
        fputs("COMPANYLENS_PERF_TRACE_READY\n", stderr)
        Thread.sleep(forTimeInterval: 10)
        sampleInterval("fresh-process-first-report", index: 0) {
            selectWorkspaceTab(.report, in: app)
            assertReportReadable(app)
        }
        if environment["COMPANYLENS_PERF_FIRST_REPORT_ONLY"] == "1" {
            attachScreenshot(app, name: "verified-fresh-first-report")
            return
        }
        for sample in 0..<repetitions {
            sampleInterval("warm-report-to-diagram", index: sample) { selectDiagram(app) }
            sampleInterval("warm-diagram-to-report", index: sample) {
                selectWorkspaceTab(.report, in: app)
                assertReportReadable(app)
            }
        }
        jumpToFirstTarget(app)
        attachScreenshot(app, name: "complete-formal-report-before-scroll")
        scroll(app, seconds: activeSeconds, phase: "continuous")
        Thread.sleep(forTimeInterval: 2)
        scroll(app, seconds: activeSeconds / 2, phase: "resumed")
        for (title, id) in jumpTargets {
            let destination = reportContentsDestination(title, in: app)
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
        if environment["COMPANYLENS_PERF_ACTIVATE_EXISTING"] == "1" {
            XCTAssertTrue(app.wait(for: .runningForeground, timeout: 15), "The explicitly installed/prelaunched process must remain foreground")
        }
        else { app.launch() }
        let open = app.buttons.matching(identifier: "library-open-current").firstMatch
        if open.waitForExistence(timeout: 3) { open.tap() }
        XCTAssertTrue(app.tabBars.buttons["workspace-tab-diagram"].waitForExistence(timeout: 15))
        XCTAssertTrue(app.staticTexts["workspace-company-title"].waitForExistence(timeout: 15))
    }

    private func prepareDurableFreshProcessPositions(_ app: XCUIApplication) -> String {
        if environment["COMPANYLENS_PERF_ACTIVATE_EXISTING"] == "1" { app.launch() }
        openReading(app)
        selectReport(app)
        jumpToFirstTarget(app)
        selectDiagram(app)
        let overview = app.buttons["study-overview"]
        if overview.waitForExistence(timeout: 3) { overview.tap() }
        let scene = app.buttons["study-map-business-delivery"]
        XCTAssertTrue(scene.waitForExistence(timeout: 10))
        for _ in 0..<8 {
            if scene.isHittable { break }
            app.scrollViews.firstMatch.swipeDown()
        }
        XCTAssertTrue(scene.isHittable)
        scene.tap()
        let title = app.staticTexts["study-scene-title"]
        XCTAssertTrue(title.waitForExistence(timeout: 10))
        let expected = title.label
        selectWorkspaceTab(.library, in: app)
        XCTAssertTrue(app.buttons["library-continue"].waitForExistence(timeout: 10))
        let durable = XCTNSPredicateExpectation(predicate: NSPredicate(format: "label CONTAINS %@", "已保存在本机"),
                                                object: app.staticTexts["library-record-status"])
        XCTAssertEqual(XCTWaiter.wait(for: [durable], timeout: 15), .completed)
        app.terminate()
        emit(["scenario": "fresh-process-preparation", "metric_kind": "cohort-preparation-not-latency",
              "saved_diagram_scene_title": expected, "saved_report_target": jumpTargets[0].1,
              "durable_status_verified": true])
        return expected
    }

    private func assertRestoredDiagram(_ app: XCUIApplication, expectedTitle: String) {
        let title = app.staticTexts["study-scene-title"]
        XCTAssertTrue(title.waitForExistence(timeout: 15))
        XCTAssertEqual(title.label, expectedTitle)
        XCTAssertFalse(app.buttons["report-contents"].exists, "Report must not be laid out before this process's first report entry")
        emit(["scenario": "fresh-process-precondition", "metric_kind": "cohort-precondition-not-latency",
              "diagram_restoration_verified_before_mode_action": true, "scene_title": expectedTitle])
    }

    private func selectDiagram(_ app: XCUIApplication) {
        selectWorkspaceTab(.diagram, in: app)
        XCTAssertTrue(app.buttons["study-overview"].exists || app.buttons["study-archive"].exists)
        XCTAssertFalse(app.buttons["report-contents"].exists)
    }

    private func selectReport(_ app: XCUIApplication) {
        selectWorkspaceTab(.report, in: app)
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
        let target = reportContentsDestination(jumpTargets[0].0, in: app)
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

    private func recordRunnerConditions(_ phase: String) {
        let process = ProcessInfo.processInfo
        let device = UIDevice.current
        let wasMonitoring = device.isBatteryMonitoringEnabled
        device.isBatteryMonitoringEnabled = true
        defer { device.isBatteryMonitoringEnabled = wasMonitoring }
        let thermal: String
        switch process.thermalState {
        case .nominal: thermal = "nominal"
        case .fair: thermal = "fair"
        case .serious: thermal = "serious"
        case .critical: thermal = "critical"
        @unknown default: thermal = "unknown"
        }
        let style: String
        switch UIApplication.shared.connectedScenes.compactMap({ $0 as? UIWindowScene })
            .first?.traitCollection.userInterfaceStyle {
        case .light: style = "light"
        case .dark: style = "dark"
        default: style = "unspecified"
        }
        let value: [String: Any] = [
            "schema": "companylens-performance-runner-conditions/v1", "phase": phase,
            "scope": "test-runner-and-system-state-not-app-presented-frame",
            "test": name, "observed_at_utc": ISO8601DateFormatter().string(from: Date()),
            "system_uptime_s": process.systemUptime, "thermal_state": thermal,
            "low_power_mode_enabled": process.isLowPowerModeEnabled,
            "battery_level": device.batteryLevel, "battery_state_raw": device.batteryState.rawValue,
            "system_version": device.systemVersion, "os_version": process.operatingSystemVersionString,
            "maximum_frames_per_second": UIScreen.main.maximumFramesPerSecond,
            "runner_preferred_content_size_category": UIApplication.shared.preferredContentSizeCategory.rawValue,
            "runner_interface_style": style, "requested_orientation": "portrait",
            "observed_device_orientation_raw": XCUIDevice.shared.orientation.rawValue
        ]
        let bytes = try! JSONSerialization.data(withJSONObject: value, options: [.sortedKeys])
        let line = String(data: bytes, encoding: .utf8)!
        fputs("COMPANYLENS_PERF_CONDITIONS " + line + "\n", stderr)
        let attachment = XCTAttachment(string: line)
        attachment.name = "native-performance-runner-conditions-" + phase
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
