import CoreGraphics
import Foundation
import SheetMusicCore
import SheetMusicLayout
import SheetMusicLayoutApple
import SwiftUI

@available(macOS 15.0, *)
@MainActor
extension PDFExporter {
    /// One page of an engraving the caller has already laid out and paginated.
    ///
    /// For a host whose screen already shows the score as pages of its own — its own paper, margins and page breaks —
    /// and whose PDF has to be those pages rather than the ones `export(score:options:)` derives from the score's
    /// `<Style>`. The host hands over the systems it put on the page and the document Y the page starts at, and the
    /// export draws exactly that.
    public struct Sheet: Sendable, Equatable {
        /// The systems on this page, in document coordinates.
        public var systems: [LayoutSystem]
        /// The document Y drawn at the page's top margin.
        ///
        /// **A sheet whose first system has a frame above it (`LayoutDocument.frames`) must start at or above that
        /// frame** — at `LayoutDocument.pageTop(ofPageStartingAt:)` of that system, as
        /// `paginate(systems:page:policy:…)` starts such a page: the previous sheet's last-system bottom, or the bottom
        /// of the frames with a page break between the two, which stay on the sheet before. The export draws on each
        /// sheet the frames `frames(of:in:)` assigns it, which include the plain frames above its first system; a sheet
        /// that starts at that system's top instead draws them into its top margin. The first sheet starts at 0, above
        /// the title block.
        public var pageStartY: CGFloat
        /// The page's media box, in points.
        public var pageSize: CGSize
        /// Used exactly as given — no odd/even resolution. The systems are drawn at
        /// `(margins.leading, margins.top − pageStartY)`, and the page chrome sits in these margins.
        public var margins: PageMargins

        public init(systems: [LayoutSystem], pageStartY: CGFloat, pageSize: CGSize, margins: PageMargins) {
            self.systems = systems
            self.pageStartY = pageStartY
            self.pageSize = pageSize
            self.margins = margins
        }
    }

    /// Metadata for `export(document:sheets:score:options:)`.
    public struct SheetOptions: Sendable {
        public var title: String?
        public var author: String?
        /// Whether elements the layout parked as invisible are drawn. `false` prints them away and keeps the room
        /// the layout gave them; see `ScoreCanvasDrawing.drawSystem`.
        public var drawsInvisibleElements: Bool

        public init(title: String? = nil, author: String? = nil, drawsInvisibleElements: Bool = true) {
            self.title = title
            self.author = author
            self.drawsInvisibleElements = drawsInvisibleElements
        }
    }

    /// Draw `sheets` — pages of `document` that the caller has already paginated — to a PDF, one page per sheet, each
    /// at its own size and margins. The first sheet carries `document.titleFrame` and its pictures
    /// (`document.titleImages`); each sheet draws the boxes between systems that `frames(of:in:)` gives it, so a host's
    /// own `Sheet`s need no field for them. `score` supplies the page chrome
    /// (`score.style.pageChrome` and `score.metaTags`), drawn into each sheet's margins as `export(score:options:)`
    /// draws it, which is now built on this. An empty `sheets` still yields a one-page PDF (CoreGraphics writes a page
    /// of its default size); pass a sheet with no systems to choose that page's size.
    public static func export(
        document: LayoutDocument,
        sheets: [Sheet],
        score: Score,
        options: SheetOptions = SheetOptions(),
    ) throws -> Data {
        // Bravura has to be registered before `ImageRenderer` first draws a glyph, or music renders as tofu. See
        // `export(score:options:)`.
        _ = SheetMusicLayoutApple.install
        let data = NSMutableData()
        guard let consumer = CGDataConsumer(data: data),
              let pdfContext = CGContext(
                  consumer: consumer,
                  mediaBox: nil,
                  pdfInfo(title: options.title, author: options.author) as CFDictionary,
              )
        else {
            throw PDFExportError.contextCreationFailed
        }
        let sheetFrames = frames(of: sheets, in: document)
        for (idx, sheet) in sheets.enumerated() {
            let view = PDFPageView(
                systems: sheet.systems,
                pageStartY: sheet.pageStartY,
                titleFrame: idx == 0 ? document.titleFrame : nil,
                frames: sheetFrames[idx],
                titleImages: idx == 0 ? document.titleImages : [],
                metrics: document.metrics,
                pageSize: sheet.pageSize,
                margins: sheet.margins,
                // Authoring overlay is for previews only; the exported file must not show it.
                breakIndicatorVisibility: .none,
                drawsInvisibleElements: options.drawsInvisibleElements,
            )
            let renderer = ImageRenderer(content: view)
            renderer.proposedSize = ProposedViewSize(width: sheet.pageSize.width, height: sheet.pageSize.height)
            renderer.scale = 1
            renderer.isOpaque = true
            renderer.render { _, drawInto in
                var mediaBox = CGRect(origin: .zero, size: sheet.pageSize)
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
                    pageCount: sheets.count,
                    pageSize: sheet.pageSize,
                    margins: sheet.margins,
                    metaTags: score.metaTags,
                    into: pdfContext,
                )
                pdfContext.endPDFPage()
            }
        }
        pdfContext.closePDF()
        return data as Data
    }

    /// The frames each of `sheets` holds, in document coordinates, by the rule every paginator follows
    /// (`LayoutDocument.subdocument`): a frame belongs to the sheet whose first system follows it, unless it carries a
    /// page break (`LayoutFrame.pageBreakAfter`) — then it stays on the sheet it closes. So a sheet holds the frames
    /// whose top lies in `[the sheet before's upper bound, its own)`, its upper bound being its last system's bottom,
    /// or the lowest bottom of the page-break frames between that system and the next sheet's first when that is
    /// further down, and the last sheet takes every frame below the sheets before it. Sheets carry systems rather than
    /// indices, hence the positions. Not `pageStartY ..< next sheet's pageStartY`: a host whose sheet starts at its
    /// first system's top would leave the frame above that system on the sheet before. A sheet with no systems other
    /// than the last holds none. One entry per sheet, in order: what `export(document:sheets:…)` draws on each.
    static func frames(of sheets: [Sheet], in document: LayoutDocument) -> [[LayoutFrame]] {
        var lower = -CGFloat.infinity
        var result: [[LayoutFrame]] = []
        for (index, sheet) in sheets.enumerated() {
            let upper: CGFloat
            if index == sheets.count - 1 {
                upper = .infinity
            } else {
                let lastBottom = sheet.systems.last.map { $0.origin.y + $0.size.height } ?? lower
                let nextTop = sheets[index + 1].systems.first?.origin.y ?? .infinity
                let breakBottoms = document.frames
                    .filter { $0.pageBreakAfter && $0.originY >= lastBottom && $0.bottom <= nextTop }
                    .map(\.bottom)
                upper = max(lower, lastBottom, breakBottoms.max() ?? lastBottom)
            }
            result.append(document.frames.filter { $0.originY >= lower && $0.originY < upper })
            lower = upper
        }
        return result
    }

    static func pdfInfo(title: String?, author: String?) -> [String: Any] {
        var info: [String: Any] = [kCGPDFContextCreator as String: "swift-sheet-music"]
        if let title {
            info[kCGPDFContextTitle as String] = title
        }
        if let author {
            info[kCGPDFContextAuthor as String] = author
        }
        return info
    }
}
