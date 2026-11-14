// Real PDFKit geometry probe. Creates a hidden window; never presents or activates UI.
// swiftc -parse-as-library Tools/verify_pdf_layout.swift -o /tmp/company-lens-pdf-layout
// /tmp/company-lens-pdf-layout Resources/reports/pdf-7cc972f2d199e2ec.pdf 177
import AppKit
import Foundation
import PDFKit

private struct Geometry: Codable {
    let pageX: Double
    let pageY: Double
    let pageWidth: Double
    let pageHeight: Double
    let scale: Double
    let documentWidth: Double
    let horizontalClipOrigin: Double?
}

private struct LayoutReport: Codable {
    let platform: String
    let sourceFilename: String
    let pageCount: Int
    let physicalPage: Int
    let portraitPageCount: Int
    let landscapePageCount: Int
    let viewportWidth: Double
    let viewportHeight: Double
    let targetCropWidth: Double
    let targetCropHeight: Double
    let widestCropWidth: Double
    let ordinaryPageNavigation: Geometry
    let destinationNavigation: Geometry
    let checks: [String]
    let limitations: [String]
}

@main private enum PDFLayoutProbe {
    static func main() throws {
        guard CommandLine.arguments.count >= 2 else {
            throw failure("Usage: verify_pdf_layout <complete-report.pdf> [physical-page, default 177]")
        }
        let file = URL(fileURLWithPath: CommandLine.arguments[1])
        let physicalPage = CommandLine.arguments.count > 2 ? Int(CommandLine.arguments[2]) ?? 177 : 177
        guard let document = PDFDocument(url: file),
              physicalPage > 0, let page = document.page(at: physicalPage - 1) else {
            throw failure("Report or requested physical page could not be loaded")
        }
        let sizes = (0..<document.pageCount).compactMap { document.page(at: $0)?.bounds(for: .cropBox).size }
        let portraits = sizes.filter { $0.width < $0.height }.count
        let landscapes = sizes.filter { $0.width > $0.height }.count
        guard portraits > 0, landscapes > 0 else {
            throw failure("Probe requires a real report containing portrait and landscape pages")
        }
        let app = NSApplication.shared
        app.setActivationPolicy(.prohibited)
        let viewport = NSRect(x: 0, y: 0, width: 440, height: 640)
        let window = NSWindow(contentRect: viewport, styleMask: [.borderless], backing: .buffered, defer: false)
        let view = PDFView(frame: viewport)
        window.contentView = view
        view.document = document
        view.displayMode = .singlePageContinuous
        view.displayDirection = .vertical
        view.displaysPageBreaks = true
        view.autoScales = false
        view.minScaleFactor = 0.1
        view.maxScaleFactor = 8
        let crop = page.bounds(for: .cropBox)
        view.scaleFactor = (viewport.width - 20) / crop.width
        view.layoutDocumentView()
        view.go(to: page)
        pump()
        let ordinary = geometry(view, page)
        view.go(to: PDFDestination(page: page, at: NSPoint(x: crop.minX, y: crop.maxY)))
        pump()
        let destination = geometry(view, page)
        guard abs(destination.scale - ordinary.scale) < 0.000001,
              abs(destination.pageWidth - 420) < 1,
              destination.pageX >= -2,
              destination.pageX + destination.pageWidth <= viewport.width + 2,
              view.currentPage === page else {
            throw failure("Destination navigation did not expose the requested page at the fitted width")
        }
        let report = LayoutReport(
            platform: "macOS \(ProcessInfo.processInfo.operatingSystemVersionString); AppKit/PDFKit; hidden 440×640 window",
            sourceFilename: file.lastPathComponent,
            pageCount: document.pageCount,
            physicalPage: physicalPage,
            portraitPageCount: portraits,
            landscapePageCount: landscapes,
            viewportWidth: viewport.width,
            viewportHeight: viewport.height,
            targetCropWidth: crop.width,
            targetCropHeight: crop.height,
            widestCropWidth: Double(sizes.map(\.width).max() ?? 0),
            ordinaryPageNavigation: ordinary,
            destinationNavigation: destination,
            checks: ["Real report contains mixed page widths", "Destination keeps fitted scale", "Target page width is 420 points", "Target page fully fits horizontal viewport", "Current physical page remains requested page"],
            limitations: ["Geometry verification on macOS only; does not prove iPhone behavior", "No visible user window or running app was operated", "Does not validate reading comfort, scrolling gestures, or all report pages"]
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        FileHandle.standardOutput.write(try encoder.encode(report))
        FileHandle.standardOutput.write(Data("\n".utf8))
        withExtendedLifetime(window) {}
    }

    private static func failure(_ message: String) -> NSError {
        NSError(domain: "CompanyLens.PDFLayoutProbe", code: 1, userInfo: [NSLocalizedDescriptionKey: message])
    }
    private static func pump() {
        RunLoop.current.run(until: Date().addingTimeInterval(0.25))
    }
    private static func geometry(_ view: PDFView, _ page: PDFPage) -> Geometry {
        let rect = view.convert(page.bounds(for: .cropBox), from: page)
        return Geometry(pageX: rect.minX, pageY: rect.minY, pageWidth: rect.width, pageHeight: rect.height,
                        scale: view.scaleFactor, documentWidth: Double(view.documentView?.frame.width ?? 0),
                        horizontalClipOrigin: scrollView(in: view).map { Double($0.contentView.bounds.minX) })
    }
    private static func scrollView(in view: NSView) -> NSScrollView? {
        for child in view.subviews {
            if let scroll = child as? NSScrollView { return scroll }
            if let scroll = scrollView(in: child) { return scroll }
        }
        return nil
    }
}
