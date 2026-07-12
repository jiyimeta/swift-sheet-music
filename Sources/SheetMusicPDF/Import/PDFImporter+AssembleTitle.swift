import CoreGraphics
import Foundation
import PDFKit
import SheetMusicCore

// Title-frame + page-boundary helpers split out of PDFImporter+Assemble to
// keep that file under the 400-line cap. Both are self-contained: the title
// frame is built from the document's first-page size + text stream, and the
// page-boundary set marks systems whose successor is on a different page
// (used for line / page break flags).

extension PDFImporter {
    static func makeTitleFrame(
        firstPageSize: CGSize?,
        documentAttributes: [String: Any]?,
        texts: [TextGlyph],
        options: PDFImportOptions,
    ) -> ScoreFrame? {
        let pageSize = firstPageSize ?? CGSize(width: 595, height: 842)
        return extractTitleFrame(
            texts: texts,
            pageSize: pageSize,
            documentAttributes: documentAttributes,
            options: options,
        )
    }

    /// Sort + scan to identify systems whose successor is on a different
    /// page (or the last system overall). The LAST system is also a page
    /// boundary because there's no "next page" to migrate to.
    static func systemPageBoundaries(_ systems: [ImportSystem]) -> Set<Int> {
        var boundaries = Set<Int>()
        for i in 0 ..< systems.count {
            let isLast = i == systems.count - 1
            if isLast || systems[i].pageIndex != systems[i + 1].pageIndex {
                boundaries.insert(i)
            }
        }
        return boundaries
    }
}
