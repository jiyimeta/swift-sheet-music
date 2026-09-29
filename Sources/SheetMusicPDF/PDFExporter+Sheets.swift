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
        public var pageStartY: CGFloat
        public var pageSize: CGSize
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
    /// at its own size and margins. The first sheet carries `document.titleFrame`. `score` supplies the page chrome
    /// (`score.style.pageChrome` and `score.metaTags`), drawn into each sheet's margins as `export(score:options:)`
    /// draws it, which is now built on this.
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
        for (idx, sheet) in sheets.enumerated() {
            let view = PDFPageView(
                systems: sheet.systems,
                pageStartY: sheet.pageStartY,
                titleFrame: idx == 0 ? document.titleFrame : nil,
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
