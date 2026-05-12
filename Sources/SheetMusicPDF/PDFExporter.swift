// swiftlint:disable file_length
import CoreGraphics
import Foundation
import SheetMusicCore
import SheetMusicLayout
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

/// Renders a `Score` to a PDF document, reproducing MuseScore's
/// page geometry, spatium-driven staff size, and header/footer
/// chrome.
///
/// The exporter mirrors MuseScore's approach
/// (`importexport/imagesexport/internal/pdfwriter.cpp`): the same
/// drawing pipeline that paints the on-screen view paints the PDF
/// pages, just with a `CGPDFContext` as the destination instead of
/// the screen. Page geometry / staff size resolve from the score's
/// `<Style>` block by default (see `PDFExporter.Options`).
///
/// All public methods are `@MainActor` because `ImageRenderer` is.
/// Wrap calls in a detached task if you don't want to block the UI.
@available(macOS 15.0, iOS 16.0, *)
@MainActor
public enum PDFExporter {
    /// Knobs for page geometry, staff scaling, layout gap, and PDF
    /// metadata. Defaults pull every dimensional value from the
    /// score's `<Style>` block (`.fromScore` selectors).
    public struct Options: Sendable {
        public enum PageGeometry: Sendable {
            /// Resolve from `score.style.pageLayout`. Default.
            case fromScore
            /// Override with explicit point-space values.
            case explicit(EngravingPage)
        }

        public enum StaffSize: Sendable {
            /// Total staff height in points, derived from
            /// `score.style.spatium` (mm). A staff is 4 × spatium
            /// tall, so the resolved value is
            /// `4 × spatium_mm × 72 / 25.4`. Default.
            case fromScore
            /// Override with an explicit total staff height in
            /// points (= 4 × one staff space).
            case explicit(CGFloat)
        }

        public var page: PageGeometry
        public var staffSize: StaffSize
        public var systemGap: CGFloat
        public var title: String?
        public var author: String?
        /// How to consume authored `<LayoutBreak>` markup. Default
        /// `.honor` reproduces export behavior from before this option
        /// existed.
        public var breakPolicy: LayoutBreakPolicy

        public init(
            page: PageGeometry = .fromScore,
            staffSize: StaffSize = .fromScore,
            systemGap: CGFloat = 16,
            title: String? = nil,
            author: String? = nil,
            breakPolicy: LayoutBreakPolicy = .honor,
        ) {
            self.page = page
            self.staffSize = staffSize
            self.systemGap = systemGap
            self.title = title
            self.author = author
            self.breakPolicy = breakPolicy
        }
    }

    /// Render `score` to a PDF document and return its raw bytes.
    public static func export( // swiftlint:disable:this function_body_length
        score: Score,
        options: Options = Options(),
    ) throws -> Data {
        // Trigger Bravura registration on the export thread. The
        // on-screen views do this via their own bodies, but
        // `PDFExporter` is the first contact with `ImageRenderer` in
        // many host-app paths and would otherwise render music
        // glyphs as tofu boxes.
        _ = BravuraFont.register
        let resolved = resolve(options: options, score: score)
        let layoutOptions = ScoreViewOptions(
            staffSize: resolved.staffSize,
            systemGap: options.systemGap,
            wrapToViewWidth: true,
            breakPolicy: options.breakPolicy,
        )
        let availableWidth = max(
            resolved.staffSize * 4,
            resolved.page.size.width
                - resolved.page.oddMargins.leading
                - resolved.page.oddMargins.trailing,
        )
        let document = LayoutEngine.layout(
            score: score, options: layoutOptions,
            availableWidth: availableWidth,
        )
        let pages = paginate(
            systems: document.systems,
            page: resolved.page,
            policy: options.breakPolicy,
        )

        let data = NSMutableData()
        guard let consumer = CGDataConsumer(data: data),
              let pdfContext = CGContext(
                  consumer: consumer,
                  mediaBox: nil,
                  makePDFInfo(options: options) as CFDictionary,
              )
        else {
            throw PDFExportError.contextCreationFailed
        }

        for (idx, page) in pages.enumerated() {
            let margins = resolved.page.margins(forPageIndex: idx)
            let view = PDFPageView(
                systems: page.systems,
                pageStartY: page.startY,
                titleFrame: idx == 0 ? document.titleFrame : nil,
                metrics: document.metrics,
                pageSize: resolved.page.size,
                margins: margins,
                // Authoring overlay is for previews only; the
                // exported file must not show it.
                breakIndicatorVisibility: .none,
                policy: options.breakPolicy,
            )
            let renderer = ImageRenderer(content: view)
            renderer.proposedSize = ProposedViewSize(
                width: resolved.page.size.width,
                height: resolved.page.size.height,
            )
            renderer.scale = 1
            renderer.isOpaque = true
            renderer.render { _, drawInto in
                var mediaBox = CGRect(
                    origin: .zero, size: resolved.page.size,
                )
                pdfContext.beginPDFPage(
                    [
                        kCGPDFContextMediaBox as String:
                            Data(bytes: &mediaBox, count: MemoryLayout<CGRect>.size),
                    ] as CFDictionary,
                )
                drawInto(pdfContext)
                PageChromeRenderer.draw(
                    chrome: score.style.pageChrome,
                    pageIndex: idx,
                    pageCount: pages.count,
                    pageSize: resolved.page.size,
                    margins: margins,
                    metaTags: score.metaTags,
                    into: pdfContext,
                )
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
        options: Options = Options(),
    ) throws {
        let data = try export(score: score, options: options)
        try data.write(to: url, options: .atomic)
    }

    // MARK: - Pagination (public so previewers can mirror the export layout)

    public struct PageBatch: Sendable {
        public let startY: CGFloat
        public let systems: [LayoutSystem]
    }

    /// Group `systems` (in document Y order) into pages so each
    /// page's combined height fits inside its usable height (page
    /// height minus the active top + bottom margins for that page).
    /// Two-sided pages alternate between odd and even margin sets
    /// per `EngravingPage.margins(forPageIndex:)`.
    ///
    /// Systems whose final measure carries `<LayoutBreak>page` end
    /// the current page even when more systems would fit
    /// vertically. Mirrors MuseScore's
    /// `MeasureBase::pageBreak()` honoring in
    /// `engraving/rendering/score/pagelayout.cpp`.
    ///
    /// Systems are not split across page boundaries — the largest
    /// single system is allowed to exceed the usable height (it
    /// just spills off its page) rather than being clipped or
    /// dropped.
    public static func paginate(
        systems: [LayoutSystem],
        page: EngravingPage,
        policy: LayoutBreakPolicy = .honor,
    ) -> [PageBatch] {
        var pages: [PageBatch] = []
        var currentSystems: [LayoutSystem] = []
        var currentStartY: CGFloat = 0

        func usableHeight(forPageIndex idx: Int) -> CGFloat {
            let m = page.margins(forPageIndex: idx)
            return max(1, page.size.height - m.top - m.bottom)
        }

        func systemEndsPage(_ system: LayoutSystem) -> Bool {
            guard policy != .ignoreAll else { return false }
            return system.measures.last?.pageBreak ?? false
        }

        for system in systems {
            if currentSystems.isEmpty {
                // Page 1 always anchors at doc Y = 0 so a leading
                // title frame (which sits above the first system in
                // doc coords) lands inside the page's content area
                // rather than off the top. Without a title, system
                // 0's origin.y is also 0 — same answer either way.
                currentStartY = pages.isEmpty ? 0 : system.origin.y
                currentSystems.append(system)
                if systemEndsPage(system) {
                    pages.append(PageBatch(
                        startY: currentStartY,
                        systems: currentSystems,
                    ))
                    currentSystems = []
                }
                continue
            }
            let bottomOnPage =
                (system.origin.y + system.size.height) - currentStartY
            if bottomOnPage > usableHeight(forPageIndex: pages.count) {
                pages.append(PageBatch(
                    startY: currentStartY,
                    systems: currentSystems,
                ))
                currentStartY = system.origin.y
                currentSystems = [system]
            } else {
                currentSystems.append(system)
            }
            if systemEndsPage(system) && !currentSystems.isEmpty {
                pages.append(PageBatch(
                    startY: currentStartY,
                    systems: currentSystems,
                ))
                currentSystems = []
            }
        }
        if !currentSystems.isEmpty {
            pages.append(PageBatch(
                startY: currentStartY,
                systems: currentSystems,
            ))
        }
        return pages
    }

    // MARK: - Resolution

    /// What `export(score:options:)` actually uses after applying
    /// the `.fromScore` selectors. Public so on-screen previewers
    /// can mirror the geometry that the exported PDF will have.
    public struct Resolved: Sendable, Equatable {
        public let page: EngravingPage
        /// Spatium in points (one staff space).
        public let staffSize: CGFloat
    }

    public static func resolve(
        options: Options, score: Score,
    ) -> Resolved {
        let page: EngravingPage
        switch options.page {
        case .fromScore:
            page = EngravingPage.from(score.style.pageLayout)
        case let .explicit(p):
            page = p
        }
        let staffSize: CGFloat
        switch options.staffSize {
        case .fromScore:
            // `StaffMetrics.staffSize` denotes total staff height
            // (= 4 × sp), not a single staff space. MuseScore's
            // spatium is in mm and equals one sp, so the conversion
            // is `4 × spatium_mm × 72 / 25.4`. Source:
            // `engraving/dom/staff.cpp::Staff::staffHeight`.
            staffSize = CGFloat(
                4 * score.style.spatium * 72.0 / 25.4,
            )
        case let .explicit(v):
            staffSize = v
        }
        return Resolved(page: page, staffSize: staffSize)
    }

    private static func makePDFInfo(
        options: Options,
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
