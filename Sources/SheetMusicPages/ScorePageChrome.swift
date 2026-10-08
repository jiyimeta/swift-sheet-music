import SheetMusicBridgeCore
import SheetMusicCore
import SheetMusicFoundation
import SheetMusicLayout

#if !canImport(CoreGraphics)
    private typealias CGFloat = SheetMusicLayout.CGFloat
#endif

/// A sheet's header and footer (`score.style.pageChrome`, its macros read from `score.metaTags`) as draw commands in
/// the page's margins — what Apple's `PDFExporter` draws with `PageChromeRenderer`, for a host that writes its pages
/// with `ScorePDFWriter`. The same rules: a block shows when it is enabled, and on the first page only when it says
/// so; with odd and even rows different, page 1 is odd; a row's three columns sit at the leading margin, centered
/// between the side margins, and at the trailing margin, aligned by their ink; the line is centered in the top or the
/// bottom margin.
///
/// Measured and drawn in the face the installed provider can draw (`renderingTextFont`) — Edwin where a metrics table
/// stands in for the platform — in the block's weight and slant.
package enum ScorePageChrome {
    private static let mmPerPoint = 25.4 / 72

    /// The commands for page `pageIndex` of `pageCount`, on a page `pageWidthMM` x `pageHeightMM` with `margins`.
    package static func commands(
        chrome: PageChrome,
        metaTags: [String: String],
        pageIndex: Int,
        pageCount: Int,
        pageWidthMM: Double,
        pageHeightMM: Double,
        margins: PageMarginsMM,
    ) -> [DrawCommand] {
        let context = PageChromeMacroExpander.Context(pageIndex: pageIndex, pageCount: pageCount, metaTags: metaTags)
        var out: [DrawCommand] = []
        for (block, isHeader) in [(chrome.header, true), (chrome.footer, false)] {
            guard block.enabled, pageIndex > 0 || block.showOnFirstPage else { continue }
            let row = block.oddEvenDifferent && !pageIndex.isMultiple(of: 2) ? block.even : block.odd
            let provider = FontMetrics.provider
            let font = provider.renderingTextFont(LayoutFont(
                face: block.fontFace,
                pointSize: CGFloat(block.fontSize),
                weight: block.fontStyle.contains(.bold) ? .bold : .regular,
                isItalic: block.fontStyle.contains(.italic),
            ))
            let wire = TextFontMapping.wire(for: font)
            let ascent = Double(provider.ascent(font: font)) * mmPerPoint
            let descent = Double(provider.descent(font: font)) * mmPerPoint
            let bandCenter = isHeader ? margins.top / 2 : pageHeightMM - margins.bottom / 2
            let baseline = bandCenter + (ascent + descent) / 2 - descent
            let leading = margins.leading
            let trailing = pageWidthMM - margins.trailing
            // Each column's template, its anchor, and how much of the text's width lies left of that anchor.
            let columns: [(template: String, x: Double, share: Double)] = [
                (template: row.left, x: leading, share: 0),
                (template: row.center, x: (leading + trailing) / 2, share: 0.5),
                (template: row.right, x: trailing, share: 1),
            ]
            for column in columns {
                let text = PageChromeMacroExpander.expand(column.template, context: context)
                guard !text.isEmpty else { continue }
                let width = Double(provider.inkBounds(text: text, font: font).width) * mmPerPoint
                if wire.style != DrawCommand.TextStyleFlag.none { out.append(.setTextStyle(flags: wire.style)) }
                out.append(.text(
                    text: text,
                    x: column.x - width * column.share,
                    y: baseline,
                    size: Double(font.pointSize) * mmPerPoint,
                    fontId: wire.fontId,
                ))
                if wire.style != DrawCommand.TextStyleFlag.none {
                    out.append(.setTextStyle(flags: DrawCommand.TextStyleFlag.none))
                }
            }
        }
        // Drawn after the music, so in black whatever color the page's last command left in force.
        return out.isEmpty ? [] : [.setColor(argb: 0xFF00_0000)] + out
    }
}
