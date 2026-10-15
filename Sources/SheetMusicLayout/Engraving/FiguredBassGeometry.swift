#if canImport(CoreGraphics)
    import CoreGraphics
#endif
import SheetMusicCore
import SheetMusicFoundation

/// A `<FiguredBass>` as SMuFL `figbass*` glyphs (`TLayout::layoutFiguredBassItem`, `tlayout.cpp:1972-2073`;
/// `TDraw::draw(FiguredBassItem)`, `tdraw.cpp:1268-1325`). MuseScore draws its own MScoreBC font at 8 pt, which is not
/// shipped; the glyphs are sized so a digit is as tall as MScoreBC's, set on its baseline, and items stack at its line
/// pitch. The three sizes are measured off MuseScore 4.7's own engraving of `own/figured-bass` at 600 dpi.
enum FiguredBassGeometry {
    /// MuseScore's line pitch, baseline to baseline, in spatiums.
    static let linePitchSp: CGFloat = 1.65
    /// The height of an MScoreBC digit at 8 pt, in spatiums; the SMuFL glyphs are scaled to it.
    static let digitHeightSp: CGFloat = 1.14
    /// An item's first baseline below its top — MScoreBC's ascent: a digit's top sits 0.35 sp under the item's.
    static let baselineSp: CGFloat = 1.49
    /// The continuation line: `3/16 sp` after the text, at `0.875` of the item's height, `3/32 sp` thick, round caps.
    static let lineGapSp: CGFloat = 3.0 / 16.0
    static let lineWidthSp: CGFloat = 3.0 / 32.0
    static let lineHeightRatio: CGFloat = 0.875

    private static func glyph(_ name: String) -> UInt32? {
        SMuFLCodepoint.byName(name)
    }

    private static func modifier(_ modifier: FiguredBassItem.Modifier?) -> UInt32? {
        switch modifier {
        case .doubleFlat: glyph("figbassDoubleFlat")
        case .flat: glyph("figbassFlat")
        case .natural: glyph("figbassNatural")
        case .sharp: glyph("figbassSharp")
        case .doubleSharp: glyph("figbassDoubleSharp")
        case .cross: glyph("figbassPlus")
        case .slash: glyph("figbassCombiningRaising")
        case .backslash: glyph("figbassCombiningLowering")
        case .none?, .other?, nil: nil
        }
    }

    private static func parenthesis(_ parenthesis: FiguredBassItem.Parenthesis) -> UInt32? {
        switch parenthesis {
        case .roundOpen: glyph("figbassParensLeft")
        case .roundClosed: glyph("figbassParensRight")
        case .squareOpen: glyph("figbassBracketLeft")
        case .squareClosed: glyph("figbassBracketRight")
        case .none, .other: nil
        }
    }

    /// `figbassNRaised` where SMuFL has a raised form of the digit.
    private static let raisedDigits: [Int: String] = [
        2: "figbass2Raised", 4: "figbass4Raised", 5: "figbass5Raised1", 6: "figbass6Raised", 7: "figbass7Raised1",
        9: "figbass9Raised",
    ]

    /// One item's glyphs in drawing order, the digit's span marked: parenthesis, prefix, parenthesis, digit (a cross,
    /// slash or backslash suffix with no parenthesis between combines with a one-digit number), parenthesis, suffix,
    /// parenthesis. `bracket4`, which follows the continuation line, is not among them.
    static func glyphs(for item: FiguredBassItem) -> [UInt32] {
        spelled(item).glyphs
    }

    /// The glyphs and the span `[x1, x2)` — as glyph indices — MuseScore centers under the note: the digit, or a lone
    /// prefix.
    private static func spelled(_ item: FiguredBassItem) -> (glyphs: [UInt32], center: Range<Int>) {
        var glyphs: [UInt32] = []
        var center = 0 ..< 0
        if let open = parenthesis(item.bracket0) { glyphs.append(open) }
        if let prefix = modifier(item.prefix), item.prefix != .slash, item.prefix != .backslash {
            let start = glyphs.count
            glyphs.append(prefix)
            if item.digit == nil { center = start ..< glyphs.count }
        }
        if let paren = parenthesis(item.bracket1) { glyphs.append(paren) }
        let combining: Set<FiguredBassItem.Modifier> = [.cross, .slash, .backslash]
        var suffixCombined = false
        if let digit = item.digit, digit >= 0 {
            let start = glyphs.count
            if digit < 10, let suffix = item.suffix, combining.contains(suffix), item.bracket2 == .none {
                suffixCombined = true
                if suffix != .cross, let raised = raisedDigits[digit].flatMap(glyph) {
                    glyphs.append(raised)
                } else {
                    glyph("figbass\(digit)").map { glyphs.append($0) }
                    modifier(suffix).map { glyphs.append($0) }
                }
            } else {
                for character in String(digit) {
                    glyph("figbass\(character)").map { glyphs.append($0) }
                }
            }
            center = start ..< glyphs.count
        }
        if let paren = parenthesis(item.bracket2) { glyphs.append(paren) }
        if !suffixCombined, let suffix = modifier(item.suffix) { glyphs.append(suffix) }
        if let close = parenthesis(item.bracket3) { glyphs.append(close) }
        return (glyphs, center)
    }

    /// The figure hung from `topY` (6 sp below the staff's top line) with its items' digits centered on `columnX`, one
    /// line pitch apart, and their continuation lines running to `lineEndX`. Text that did not parse draws as its
    /// lines in the staff-text face at MuseScore's 8 pt.
    static func figure(_ figuredBass: FiguredBass, columnX: CGFloat, topY: CGFloat, lineEndX: CGFloat, sp: CGFloat)
        -> LayoutFigure
    {
        let pitch = linePitchSp * sp
        guard !figuredBass.items.isEmpty else {
            return textFigure(figuredBass.text, columnX: columnX, topY: topY, pitch: pitch, sp: sp)
        }
        let font = glyphFont(sp: sp)
        let provider = FontMetrics.provider
        let ascent = baselineSp * sp
        var primitives: [LayoutFigure.Primitive] = []
        for (index, item) in figuredBass.items.enumerated() {
            let (glyphs, center) = spelled(item)
            let advances = glyphs.map { codepoint -> CGFloat in
                Unicode.Scalar(codepoint).map { provider.typographicWidth(text: String(Character($0)), font: font) }
                    ?? 0
            }
            let x1 = advances.prefix(center.lowerBound).reduce(0, +)
            let x2 = advances.prefix(center.upperBound).reduce(0, +)
            var pen = glyphs.isEmpty ? columnX : columnX - (x1 + x2) / 2
            let itemTop = topY + CGFloat(index) * pitch
            let baseline = itemTop + ascent
            for (codepoint, advance) in zip(glyphs, advances) {
                let origin = CGPoint(x: pen, y: baseline)
                let run = LayoutRichTextPositionedRun(
                    content: .symbol(codepoint: codepoint), font: font, baseline: origin,
                )
                primitives.append(.run(run, rotation: 0, pivot: origin))
                pen += advance
            }
            primitives += continuation(
                of: item, figuredBass: figuredBass, textRight: pen, itemTop: itemTop, lineEndX: lineEndX, font: font,
                baseline: baseline, sp: sp,
            )
        }
        return LayoutFigure(primitives: primitives)
    }

    /// The continuation line from just after the text to `lineEndX`, when the figure has a printed length; dropped when
    /// shorter than a point. `bracket4` closes after it (or after the text when there is none).
    private static func continuation(
        of item: FiguredBassItem, figuredBass: FiguredBass, textRight: CGFloat, itemTop: CGFloat,
        lineEndX: CGFloat, font: LayoutFont, baseline: CGFloat, sp: CGFloat,
    ) -> [LayoutFigure.Primitive] {
        var primitives: [LayoutFigure.Primitive] = []
        var end = textRight
        let hasLine = switch item.continuationLine {
        case .simple?, .extended?: true
        default: false
        }
        if hasLine, figuredBass.ticks != nil {
            let start = textRight + lineGapSp * sp
            let y = itemTop + lineHeightRatio * linePitchSp * sp
            if lineEndX - start >= 1 {
                primitives.append(.line(
                    from: CGPoint(x: start, y: y), to: CGPoint(x: lineEndX, y: y), width: lineWidthSp * sp, cap: .round,
                ))
                end = lineEndX
            }
        }
        if let close = parenthesis(item.bracket4) {
            let origin = CGPoint(x: end, y: baseline)
            let run = LayoutRichTextPositionedRun(content: .symbol(codepoint: close), font: font, baseline: origin)
            primitives.append(.run(run, rotation: 0, pivot: origin))
        }
        return primitives
    }

    /// Bravura at the size that makes `figbass6` `digitHeightSp` tall.
    private static func glyphFont(sp: CGFloat) -> LayoutFont {
        let probe = LayoutFont(face: SMuFLFamily.bravura, pointSize: 4 * sp)
        let height = glyph("figbass6").flatMap(Unicode.Scalar.init).flatMap {
            FontMetrics.provider.textInkBounds(text: String(Character($0)), font: probe)?.height
        } ?? 0
        let size = height > 0 ? 4 * sp * digitHeightSp * sp / height : 4 * sp * 0.6
        return LayoutFont(face: SMuFLFamily.bravura, pointSize: size)
    }

    /// Unparsed text: each line centered on the column in the staff-text face at 8 pt (scaled by the spatium).
    private static func textFigure(
        _ text: String, columnX: CGFloat, topY: CGFloat, pitch: CGFloat, sp: CGFloat,
    ) -> LayoutFigure {
        let face = TextInkGeometry.font(for: .staffText, metrics: StaffMetrics(staffSize: 4 * sp)).face
        let font = LayoutFont(face: face, pointSize: 8 * sp / 5)
        let ascent = FontMetrics.provider.ascent(font: font)
        let lines = text.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        var primitives: [LayoutFigure.Primitive] = []
        for (index, line) in lines.enumerated() where !line.isEmpty {
            let width = FontMetrics.provider.typographicWidth(text: line, font: font)
            let origin = CGPoint(x: columnX - width / 2, y: topY + CGFloat(index) * pitch + ascent)
            let run = LayoutRichTextPositionedRun(content: .text(line), font: font, baseline: origin)
            primitives.append(.run(run, rotation: 0, pivot: origin))
        }
        return LayoutFigure(primitives: primitives)
    }
}
