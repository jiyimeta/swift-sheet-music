// swiftlint:disable file_length
import CoreGraphics
import Foundation
import SheetMusicCore
import SheetMusicLayout
import SheetMusicLayoutApple
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
@available(macOS 15.0, *)
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
        /// Engraving spacing forwarded to the layout engine.
        ///
        /// PDF already has the page margins in `EngravingPage`, and
        /// `PDFPageView` maps document coordinates by that page's leading
        /// and top margins. Non-default `spacing.margins` therefore add an
        /// inner margin inside the page margin. PDF hosts should normally
        /// treat the page margin as authoritative and leave
        /// `spacing.margins` at its default.
        public var spacing: EngravingSpacing

        public init(
            page: PageGeometry = .fromScore,
            staffSize: StaffSize = .fromScore,
            systemGap: CGFloat = 16,
            title: String? = nil,
            author: String? = nil,
            breakPolicy: LayoutBreakPolicy = .honor,
            spacing: EngravingSpacing = .standard,
        ) {
            self.page = page
            self.staffSize = staffSize
            self.systemGap = systemGap
            self.title = title
            self.author = author
            self.breakPolicy = breakPolicy
            self.spacing = spacing
        }
    }

    /// Render `score` to a PDF document and return its raw bytes.
    ///
    /// Lays the score out and paginates it from its `<Style>`, then draws through
    /// `export(document:sheets:score:options:)`.
    public static func export(
        score: Score,
        options: Options = Options(),
    ) throws -> Data {
        let paged = pagedLayout(score: score, options: options)
        let sheets = paged.batches.enumerated().map { idx, page in
            Sheet(
                systems: page.systems,
                pageStartY: page.startY,
                pageSize: paged.resolved.page.size,
                margins: paged.resolved.page.margins(forPageIndex: idx),
            )
        }
        return try export(
            document: paged.document,
            sheets: sheets,
            score: score,
            options: SheetOptions(title: options.title, author: options.author),
        )
    }

    /// What `export(score:options:)` draws: `score` laid out into the printable width of its resolved page
    /// (`resolve(options:score:)`) and cut into batches by `paginate(document:page:policy:)`.
    static func pagedLayout(
        score: Score,
        options: Options,
    ) -> (document: LayoutDocument, resolved: Resolved, batches: [PageBatch]) {
        // Trigger Bravura registration on the export thread. The
        // on-screen views do this via their own bodies, but
        // `PDFExporter` is the first contact with `ImageRenderer` in
        // many host-app paths and would otherwise render music
        // glyphs as tofu boxes.
        _ = SheetMusicLayoutApple.install
        let resolved = resolve(options: options, score: score)
        let layoutOptions = ScoreViewOptions(
            staffSize: resolved.staffSize,
            systemGap: options.systemGap,
            wrapToViewWidth: true,
            breakPolicy: options.breakPolicy,
            // PDF export always uses print behavior: invisible elements
            // are fully omitted, never grayed. Explicit even though false
            // is the default — guards against the default ever changing.
            showsInvisibleElements: false,
            spacing: options.spacing,
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
        let batches = paginate(document: document, page: resolved.page, policy: options.breakPolicy)
        return (document, resolved, batches)
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
    ///
    /// The frames between systems (`LayoutDocument.frames`) enter as `LayoutPaginator.paginate` takes them:
    /// `pageBreaksBefore` starts a page at each listed system (the one below a frame with `pageBreakAfter`; ignored
    /// under `.ignoreAll` and outside `1 ..< systems.count`), its value the lowest bottom of those frames. They stay at
    /// the bottom of the page they close, so that page must hold them under its last system — one that does not fit
    /// with them moves to the next page with them, unless it is the page's first — and the next page starts at their
    /// bottom. A `trailingFramesBottom` — the lowest bottom of the frames after the last system — adds a batch with no
    /// systems, whose `startY` is the last system's bottom, when those frames do not fit on the last page or an
    /// honored page break on the last system already closed it. A page whose first system is in
    /// `systemsWithFrameAbove` (a frame sits between it and the system before) starts at that previous system's bottom
    /// rather than at its own top, so the frame is on this page and not lost between two — or, for a system in
    /// `pageBreaksBefore`, at the bottom of the frames whose break it is, so they stay on the page above. Every other
    /// page starts where it always did. Each page therefore starts at `LayoutDocument.pageTop(ofPageStartingAt:)` when
    /// a frame sits above its first system.
    ///
    /// The three frame parameters are derived from a document internally — `export(score:options:)` cuts through
    /// `paginate(document:page:policy:)`, which reads the `package` helpers behind
    /// `LayoutDocument.paginate(pageHeight:policy:)` — so a host cannot compute them itself. A host printing a
    /// document with frames calls `export(score:options:)`, or cuts its own pages with
    /// `LayoutDocument.paginate(pageHeight:policy:)` and draws them with `export(document:sheets:score:options:)`, each
    /// sheet starting as `Sheet.pageStartY` requires. Called without them, this paginates the systems as if there were
    /// no frames.
    public static func paginate(
        systems: [LayoutSystem],
        page: EngravingPage,
        policy: LayoutBreakPolicy = .honor,
        pageBreaksBefore: [Int: CGFloat] = [:],
        trailingFramesBottom: CGFloat? = nil,
        systemsWithFrameAbove: Set<Int> = [],
    ) -> [PageBatch] {
        let forced: [Int: CGFloat] = policy == .ignoreAll
            ? [:]
            : pageBreaksBefore.filter { $0.key >= 1 && $0.key < systems.count }
        // A frame's page break sits in a frame above the system it breaks before.
        let framed = systemsWithFrameAbove.union(pageBreaksBefore.keys)
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

        /// Where a later page starting with system `index` starts: its own top, or — when a frame sits between it and
        /// the previous system — that system's bottom, so the frame is drawn on this page rather than lost between
        /// two, or the bottom of the frames whose page break comes before `index`, which stay on the page above.
        func startY(ofPageAt index: Int) -> CGFloat {
            guard index > 0, framed.contains(index) else { return systems[index].origin.y }
            let previousBottom = systems[index - 1].origin.y + systems[index - 1].size.height
            return max(previousBottom, forced[index] ?? previousBottom)
        }

        for (index, system) in systems.enumerated() {
            if currentSystems.isEmpty {
                // Page 1 always anchors at doc Y = 0 so a leading
                // title frame (which sits above the first system in
                // doc coords) lands inside the page's content area
                // rather than off the top. Without a title, system
                // 0's origin.y is also 0 — same answer either way.
                currentStartY = pages.isEmpty ? 0 : startY(ofPageAt: index)
                currentSystems.append(system)
                if systemEndsPage(system) {
                    pages.append(PageBatch(startY: currentStartY, systems: currentSystems))
                    currentSystems = []
                }
                continue
            }
            // Down to the frames under this system when their page break ends the page there.
            let reach = max(system.origin.y + system.size.height, forced[index + 1] ?? -CGFloat.infinity)
            if forced[index] != nil || reach - currentStartY > usableHeight(forPageIndex: pages.count) {
                pages.append(PageBatch(startY: currentStartY, systems: currentSystems))
                currentStartY = startY(ofPageAt: index)
                currentSystems = [system]
            } else {
                currentSystems.append(system)
            }
            if systemEndsPage(system) && !currentSystems.isEmpty {
                pages.append(PageBatch(startY: currentStartY, systems: currentSystems))
                currentSystems = []
            }
        }
        // As in `LayoutPaginator`: the trailing frames get a batch of their own when they do not fit on the open page,
        // and always when a page break on the last system's last measure has already closed it.
        let lastBottom = systems.last.map { $0.origin.y + $0.size.height }
        let closedByPageBreak = currentSystems.isEmpty
        let openPageIndex = pages.count
        if !currentSystems.isEmpty {
            pages.append(PageBatch(startY: currentStartY, systems: currentSystems))
        }
        if let trailingFramesBottom, let lastBottom,
           closedByPageBreak || trailingFramesBottom - currentStartY > usableHeight(forPageIndex: openPageIndex)
        {
            pages.append(PageBatch(startY: lastBottom, systems: []))
        }
        return pages
    }

    /// `paginate(systems:page:policy:…)` of `document.systems` with what its frames ask of the cut, derived as
    /// `LayoutDocument.paginate(pageHeight:policy:)` derives it, so the PDF and the page-mode readers put every frame
    /// on the same page.
    static func paginate(document: LayoutDocument, page: EngravingPage, policy: LayoutBreakPolicy) -> [PageBatch] {
        paginate(
            systems: document.systems, page: page, policy: policy,
            pageBreaksBefore: document.pageBreakFrameBottoms, trailingFramesBottom: document.trailingFramesBottom,
            systemsWithFrameAbove: document.systemsBelowFrames,
        )
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
}
