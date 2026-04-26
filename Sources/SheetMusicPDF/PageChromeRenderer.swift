import CoreGraphics
import CoreText
import Foundation
import SheetMusicCore

#if canImport(AppKit)
import AppKit
#elseif canImport(UIKit)
import UIKit
#endif

/// Draws header / footer / page-number text into the margin area of
/// a PDF page. Pulls from `score.style.pageChrome` (defaults from
/// MuseScore: page number on outer header, copyright in centre
/// footer).
///
/// All measurements arrive in points. The renderer never touches
/// SwiftUI — it draws directly into the `CGContext` so it can be
/// invoked alongside `ImageRenderer` output without a second view
/// hierarchy.
@MainActor
enum PageChromeRenderer {
    static func draw(
        chrome: PageChrome,
        pageIndex: Int,
        pageCount: Int,
        pageSize: CGSize,
        margins: PageMargins,
        metaTags: [String: String],
        into ctx: CGContext
    ) {
        let macroContext = PageChromeMacroExpander.Context(
            pageIndex: pageIndex,
            pageCount: pageCount,
            metaTags: metaTags)
        drawBlock(
            chrome.header, kind: .header,
            pageIndex: pageIndex,
            pageSize: pageSize, margins: margins,
            macroContext: macroContext, into: ctx)
        drawBlock(
            chrome.footer, kind: .footer,
            pageIndex: pageIndex,
            pageSize: pageSize, margins: margins,
            macroContext: macroContext, into: ctx)
    }

    private enum BlockKind { case header, footer }

    private static func drawBlock(
        _ block: HeaderFooter,
        kind: BlockKind,
        pageIndex: Int,
        pageSize: CGSize,
        margins: PageMargins,
        macroContext: PageChromeMacroExpander.Context,
        into ctx: CGContext
    ) {
        guard block.enabled else { return }
        if pageIndex == 0 && !block.showOnFirstPage { return }

        let row = activeRow(block: block, pageIndex: pageIndex)
        let font = makeFont(
            face: block.fontFace,
            size: CGFloat(block.fontSize),
            style: block.fontStyle)
        let baselineY = baseline(
            kind: kind, font: font,
            pageSize: pageSize, margins: margins)

        let leftText = PageChromeMacroExpander.expand(
            row.left, context: macroContext)
        let centerText = PageChromeMacroExpander.expand(
            row.center, context: macroContext)
        let rightText = PageChromeMacroExpander.expand(
            row.right, context: macroContext)

        if !leftText.isEmpty {
            drawLine(
                leftText, font: font,
                x: margins.leading, alignment: .leading,
                baselineY: baselineY, into: ctx)
        }
        if !centerText.isEmpty {
            let mid = (margins.leading
                + (pageSize.width - margins.trailing)) / 2
            drawLine(
                centerText, font: font,
                x: mid, alignment: .center,
                baselineY: baselineY, into: ctx)
        }
        if !rightText.isEmpty {
            drawLine(
                rightText, font: font,
                x: pageSize.width - margins.trailing,
                alignment: .trailing,
                baselineY: baselineY, into: ctx)
        }
    }

    private static func activeRow(
        block: HeaderFooter, pageIndex: Int
    ) -> TextRow {
        guard block.oddEvenDifferent else { return block.odd }
        // Page 1 (index 0) is odd; alternate from there.
        return (pageIndex % 2 == 0) ? block.odd : block.even
    }

    /// Center the row vertically inside the top / bottom margin
    /// band. `headerOffset` / `footerOffset` would shift this; not
    /// honored on first pass (see Risks in the design doc).
    private static func baseline(
        kind: BlockKind, font: CTFont,
        pageSize: CGSize, margins: PageMargins
    ) -> CGFloat {
        let ascent = CTFontGetAscent(font)
        let descent = CTFontGetDescent(font)
        let h = ascent + descent
        switch kind {
        case .header:
            // Y-down (CGContext default for ImageRenderer/PDF):
            // baseline = midpoint of top margin shifted down by
            // (h/2 - descent) so the visible glyph midline sits at
            // the band's centre.
            let mid = margins.top / 2
            return mid + (h / 2) - descent
        case .footer:
            let mid = pageSize.height - (margins.bottom / 2)
            return mid + (h / 2) - descent
        }
    }

    private enum HorizontalAlignment {
        case leading, center, trailing
    }

    private static func drawLine(
        _ text: String, font: CTFont,
        x: CGFloat, alignment: HorizontalAlignment,
        baselineY: CGFloat,
        into ctx: CGContext
    ) {
        let attr = NSAttributedString(
            string: text, attributes: [
                .font: font,
                .foregroundColor: cgBlack(),
            ])
        let line = CTLineCreateWithAttributedString(attr)
        let bounds = CTLineGetBoundsWithOptions(
            line, [.useGlyphPathBounds])
        let width = bounds.width
        let originX: CGFloat
        switch alignment {
        case .leading:  originX = x
        case .center:   originX = x - width / 2
        case .trailing: originX = x - width
        }
        ctx.saveGState()
        // Convert from "Y-down baseline" to CGContext expectations.
        // ImageRenderer's CGContext is already Y-down for our
        // purposes; we draw with `textMatrix` flipped so glyph
        // outlines go up-right rather than down-right.
        ctx.textMatrix = CGAffineTransform(
            a: 1, b: 0, c: 0, d: -1, tx: 0, ty: 0)
        ctx.textPosition = CGPoint(x: originX, y: baselineY)
        CTLineDraw(line, ctx)
        ctx.restoreGState()
    }

    private static func cgBlack() -> CGColor {
        CGColor(gray: 0, alpha: 1)
    }

    private static func makeFont(
        face: String, size: CGFloat, style: FontStyleSet
    ) -> CTFont {
        var traits: CTFontSymbolicTraits = []
        if style.contains(.bold)   { traits.insert(.boldTrait) }
        if style.contains(.italic) { traits.insert(.italicTrait) }
        let descriptor = CTFontDescriptorCreateWithNameAndSize(
            face as CFString, size)
        let withTraits: CTFontDescriptor
        if traits.isEmpty {
            withTraits = descriptor
        } else if let d = CTFontDescriptorCreateCopyWithSymbolicTraits(
            descriptor, traits, traits) {
            withTraits = d
        } else {
            withTraits = descriptor
        }
        let font = CTFontCreateWithFontDescriptor(
            withTraits, size, nil)
        // CT happily creates a stub for missing faces; check by
        // round-tripping the family name and falling back to a
        // system serif if the requested face isn't really there.
        let resolved = CTFontCopyFamilyName(font) as String
        if resolved.isEmpty || resolved == ".AppleSystemUIFont" {
            return systemFallback(size: size, traits: traits)
        }
        return font
    }

    private static func systemFallback(
        size: CGFloat, traits: CTFontSymbolicTraits
    ) -> CTFont {
        #if canImport(AppKit)
        let nsFont = NSFont.systemFont(ofSize: size)
        return nsFont as CTFont
        #elseif canImport(UIKit)
        let uiFont = UIFont.systemFont(ofSize: size)
        return uiFont as CTFont
        #else
        return CTFontCreateWithName(
            "Helvetica" as CFString, size, nil)
        #endif
    }
}
