import CoreGraphics
import Foundation
import SheetMusicCore
import SheetMusicUI
import SwiftUI

/// Errors thrown by `PDFExporter`. Distinct from `SheetMusicError`
/// so consumers can pattern-match on PDF-specific failure modes
/// without pulling in the score-model error namespace.
public enum PDFExportError: Error, Sendable {
    /// `CGPDFContext` could not be constructed — typically means
    /// the system PDF subsystem refused the requested page geometry
    /// or info dictionary.
    case contextCreationFailed
}

/// Renders a `Score` to a PDF document.
///
/// The exporter mirrors MuseScore's approach
/// (`importexport/imagesexport/internal/pdfwriter.cpp`): the same
/// drawing pipeline that paints the on-screen view paints the PDF
/// pages, just with a `CGPDFContext` as the destination instead of
/// the screen. Layout runs once at the configured `pageSize`,
/// systems are packed into pages by cumulative height, and each
/// page is rendered through SwiftUI's `ImageRenderer` so glyphs
/// stay vector (no per-page rasterisation).
///
/// All public methods are `@MainActor` because `ImageRenderer` is.
/// Wrap calls in a detached task if you don't want to block the UI:
///
///     let data = await Task.detached { @MainActor in
///         try PDFExporter.export(score: score)
///     }.value
@available(macOS 15.0, iOS 16.0, *)
@MainActor
public enum PDFExporter {

    /// Knobs for page geometry, layout, and PDF metadata. Defaults
    /// produce US Letter, half-inch margins, staff size 14 — a
    /// reasonable preset for a single-instrument practice handout.
    public struct Options: Sendable {
        /// Page size in points (1pt = 1/72"). See `Options.usLetter`
        /// / `.a4` for common presets.
        public var pageSize: CGSize
        /// Inset on all four sides of every page, in points.
        public var margin: CGFloat
        /// Staff space (one staff line interval) in points. Drives
        /// every glyph and spacing dimension downstream.
        public var staffSize: CGFloat
        /// Vertical gap between consecutive systems on the same page.
        public var systemGap: CGFloat
        /// Stamped into the PDF metadata's `Title` field. Visible in
        /// most PDF viewers' window-title / properties panel.
        public var title: String?
        /// Stamped into the PDF metadata's `Author` field.
        public var author: String?

        /// 8.5" × 11" — North American letter size.
        public static let usLetter = CGSize(width: 612, height: 792)
        /// 210mm × 297mm — ISO A4.
        public static let a4 = CGSize(width: 595, height: 842)

        public init(
            pageSize: CGSize = Options.usLetter,
            margin: CGFloat = 36,
            staffSize: CGFloat = 14,
            systemGap: CGFloat = 16,
            title: String? = nil,
            author: String? = nil
        ) {
            self.pageSize = pageSize
            self.margin = margin
            self.staffSize = staffSize
            self.systemGap = systemGap
            self.title = title
            self.author = author
        }
    }

    /// Render `score` to a PDF document and return its raw bytes.
    public static func export(
        score: Score,
        options: Options = Options()
    ) throws -> Data {
        let layoutOptions = ScoreViewOptions(
            staffSize: options.staffSize,
            systemGap: options.systemGap,
            wrapToViewWidth: true)
        let availableWidth = max(
            options.staffSize * 4,
            options.pageSize.width - 2 * options.margin)
        let document = LayoutEngine.layout(
            score: score, options: layoutOptions,
            availableWidth: availableWidth)
        let pages = paginate(
            systems: document.systems,
            pageSize: options.pageSize,
            margin: options.margin)

        let data = NSMutableData()
        guard let consumer = CGDataConsumer(data: data),
              let pdfContext = CGContext(
                consumer: consumer,
                mediaBox: nil,
                makePDFInfo(options: options) as CFDictionary)
        else {
            throw PDFExportError.contextCreationFailed
        }

        for (idx, page) in pages.enumerated() {
            let view = PDFPageView(
                systems: page.systems,
                pageStartY: page.startY,
                titleFrame: idx == 0 ? document.titleFrame : nil,
                metrics: document.metrics,
                pageSize: options.pageSize,
                margin: options.margin)
            let renderer = ImageRenderer(content: view)
            renderer.proposedSize = ProposedViewSize(
                width: options.pageSize.width,
                height: options.pageSize.height)
            renderer.scale = 1
            renderer.isOpaque = true
            renderer.render { _, drawInto in
                var mediaBox = CGRect(
                    origin: .zero, size: options.pageSize)
                pdfContext.beginPDFPage(
                    [kCGPDFContextMediaBox as String:
                        Data(bytes: &mediaBox, count: MemoryLayout<CGRect>.size)
                    ] as CFDictionary)
                drawInto(pdfContext)
                pdfContext.endPDFPage()
            }
        }

        pdfContext.closePDF()
        return data as Data
    }

    /// Render `score` and write the resulting PDF to `url`.
    public static func export(
        score: Score,
        to url: URL,
        options: Options = Options()
    ) throws {
        let data = try export(score: score, options: options)
        try data.write(to: url, options: .atomic)
    }

    // MARK: - Pagination (public so previewers can mirror the export layout)

    public struct PageBatch {
        public let startY: CGFloat
        public let systems: [LayoutSystem]
    }

    /// Group `systems` (in document Y order) into pages so each
    /// page's combined height fits inside `pageSize.height - 2 *
    /// margin`. Systems are not split across page boundaries — the
    /// largest single system is allowed to exceed the usable height
    /// (it just spills off its page) rather than being clipped or
    /// dropped.
    public static func paginate(
        systems: [LayoutSystem],
        pageSize: CGSize,
        margin: CGFloat
    ) -> [PageBatch] {
        let usableHeight = max(1, pageSize.height - 2 * margin)
        var pages: [PageBatch] = []
        var currentSystems: [LayoutSystem] = []
        var currentStartY: CGFloat = 0

        for system in systems {
            if currentSystems.isEmpty {
                // Page 1 always anchors at doc Y = 0 so a leading
                // title frame (which sits above the first system in
                // doc coords) lands inside the page's content area
                // rather than off the top. Without a title, system
                // 0's origin.y is also 0 — same answer either way.
                currentStartY = pages.isEmpty ? 0 : system.origin.y
                currentSystems.append(system)
                continue
            }
            let bottomOnPage =
                (system.origin.y + system.size.height) - currentStartY
            if bottomOnPage > usableHeight {
                pages.append(PageBatch(
                    startY: currentStartY,
                    systems: currentSystems))
                currentStartY = system.origin.y
                currentSystems = [system]
            } else {
                currentSystems.append(system)
            }
        }
        if !currentSystems.isEmpty {
            pages.append(PageBatch(
                startY: currentStartY,
                systems: currentSystems))
        }
        return pages
    }

    private static func makePDFInfo(
        options: Options
    ) -> [String: Any] {
        var info: [String: Any] = [
            kCGPDFContextCreator as String: "swift-sheet-music",
        ]
        if let title = options.title {
            info[kCGPDFContextTitle as String] = title
        }
        if let author = options.author {
            info[kCGPDFContextAuthor as String] = author
        }
        return info
    }
}
