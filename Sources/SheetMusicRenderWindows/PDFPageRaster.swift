/// A PDF page drawn into a band at one scale: the band, and which part of the page's pixels it holds.
struct PDFRaster {
    var band: OpaquePointer
    var rect: PixelRect
}

/// Which part of a PDF page `ScoreSurface` draws into one band at a scale — pure geometry, so it can be tested on its
/// own.
///
/// A PDF page costs what its content costs however little of it is drawn (measured on folino's QA machine: a 1024 px
/// tile of a dense page costs what the whole page does — folino's spec
/// 2026-10-05-windows-phase4-import-export-pdf-design §5.3), so a page is drawn whole, once per scale, while its
/// longest side fits `capPx`. Past that a whole page costs too much memory — an A4 page at 8× zoom on a 200 % screen
/// is 12,700 × 17,960 px, 912 MB — so the band holds the part around the view instead: what shows, grown by half of it
/// on each side, within the cap and the page. A view that leaves that part has it drawn again around where the view
/// went.
enum PDFPageRaster {
    /// The longest side a page is drawn whole at: Android's `PdfRasterBudget` cap. An A4 page at it is 2897 × 4096 px,
    /// 47 MB.
    static let capPx = 4096

    /// What a view showing `view` (page pixels at the raster scale) needs drawn of a `pageWidthPx` x `pageHeightPx`
    /// page: the whole page when it fits the cap, else the part of `view` on the page — its middle `capPx` along a side
    /// longer than that. Nil when the view shows none of the page.
    static func needed(view: PixelRect, pageWidthPx: Int, pageHeightPx: Int) -> PixelRect? {
        let left = max(0, view.x)
        let top = max(0, view.y)
        let right = min(pageWidthPx, view.x + view.width)
        let bottom = min(pageHeightPx, view.y + view.height)
        guard left < right, top < bottom else { return nil }
        guard !fitsWhole(pageWidthPx, pageHeightPx) else { return whole(pageWidthPx, pageHeightPx) }
        let (x, width) = middle(left, right - left)
        let (y, height) = middle(top, bottom - top)
        return PixelRect(x: x, y: y, width: width, height: height)
    }

    /// The part of the page to draw for `needed` (from `needed(view:…)`): the whole page when it fits the cap, else
    /// `needed` grown by half its size on each side, within the cap and the page.
    static func drawn(needed: PixelRect, pageWidthPx: Int, pageHeightPx: Int) -> PixelRect {
        guard !fitsWhole(pageWidthPx, pageHeightPx) else { return whole(pageWidthPx, pageHeightPx) }
        let (x, width) = grown(needed.x, needed.width, page: pageWidthPx)
        let (y, height) = grown(needed.y, needed.height, page: pageHeightPx)
        return PixelRect(x: x, y: y, width: width, height: height)
    }

    /// Whether a band holding `drawn` has all of `needed`.
    static func covers(_ drawn: PixelRect, _ needed: PixelRect) -> Bool {
        drawn.x <= needed.x && drawn.y <= needed.y && drawn.x + drawn.width >= needed.x + needed.width
            && drawn.y + drawn.height >= needed.y + needed.height
    }

    static func fitsWhole(_ pageWidthPx: Int, _ pageHeightPx: Int) -> Bool {
        max(pageWidthPx, pageHeightPx) <= capPx
    }

    private static func whole(_ pageWidthPx: Int, _ pageHeightPx: Int) -> PixelRect {
        PixelRect(x: 0, y: 0, width: pageWidthPx, height: pageHeightPx)
    }

    /// The middle `capPx` of a run longer than that; the run itself otherwise.
    private static func middle(_ start: Int, _ length: Int) -> (start: Int, length: Int) {
        guard length > capPx else { return (start, length) }
        return (start + (length - capPx) / 2, capPx)
    }

    /// A run of `length` (at most `capPx`, within the page) grown to twice that around its middle, as far as the cap
    /// and the page allow: it keeps the whole run.
    private static func grown(_ start: Int, _ length: Int, page: Int) -> (start: Int, length: Int) {
        let size = min(page, capPx, length * 2)
        return (min(max(0, start - (size - length) / 2), page - size), size)
    }
}
