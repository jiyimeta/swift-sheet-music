#if canImport(CoreGraphics)
    import CoreGraphics
#endif
import SheetMusicCore

/// One typeset run of a `LayoutRichText` line: a string in one font, or one SMuFL glyph in Bravura.
public struct LayoutRichTextRun: Sendable, Equatable {
    public enum Content: Sendable, Equatable {
        case text(String)
        /// A SMuFL codepoint, drawn in the run's font (Bravura).
        case symbol(codepoint: UInt32)

        /// What a text-drawing call is handed: the string, or the symbol as a one-character string.
        public var string: String {
            switch self {
            case let .text(text): text
            case let .symbol(codepoint): Unicode.Scalar(codepoint).map { String(Character($0)) } ?? ""
            }
        }
    }

    public let content: Content
    /// The font the run is measured and drawn in — the element's text font with the run's format applied, or Bravura
    /// at the style's musical-symbol size. Weight and slant ride here, so a renderer reads them off it exactly as it
    /// does for plain text (`TextFontMapping`, `AppleFontMetricsProvider.renderingFont(for:)`).
    public let font: LayoutFont
    /// Pen position from the start of the line, in points.
    public let x: CGFloat
    /// Typographic advance, in points.
    public let advance: CGFloat
    /// Y-down offset of the run's baseline from its line's: positive for a subscript, negative for a superscript.
    public let baselineShift: CGFloat
    public let underline: Bool
    public let strike: Bool
}

/// One line of a `LayoutRichText`.
public struct LayoutRichTextLine: Sendable, Equatable {
    public let runs: [LayoutRichTextRun]
    /// The runs' advances, summed.
    public let width: CGFloat
    /// The tallest text run's ascent and the deepest one's descent; the element's own font's when the line has no text
    /// run. Symbols do not count, a deliberate simplification of ours: Bravura's em box is far taller than its ink.
    /// MuseScore does count a symbol fragment — as 1.25 × the line's ink above the baseline, in place of the face's
    /// line spacing (`TextLayout::layoutTextBlock`, `rendering/score/textlayout.cpp:375-379`) — so a symbol taller than
    /// its line's text can sit closer to the line above here than it would in MuseScore.
    public let ascent: CGFloat
    public let descent: CGFloat

    /// The runs placed with the line's pen start at `leftX` and its baseline at `baselineY`.
    public func positionedRuns(leftX: CGFloat, baselineY: CGFloat) -> [LayoutRichTextPositionedRun] {
        runs.map { run in
            LayoutRichTextPositionedRun(
                content: run.content, font: run.font,
                baseline: CGPoint(x: leftX + run.x, y: baselineY + run.baselineShift),
            )
        }
    }

    /// The underline and strike-through bars for the same placement.
    public func decorations(leftX: CGFloat, baselineY: CGFloat) -> [LayoutRichTextDecoration] {
        var result: [LayoutRichTextDecoration] = []
        for run in runs where run.advance > 0 && (run.underline || run.strike) {
            let size = run.font.pointSize
            let baseline = baselineY + run.baselineShift
            let from = leftX + run.x
            let to = from + run.advance
            let thickness = size * LayoutRichText.decorationThicknessEm
            if run.underline {
                let y = baseline + size * LayoutRichText.underlineOffsetEm
                result.append(LayoutRichTextDecoration(
                    from: CGPoint(x: from, y: y), to: CGPoint(x: to, y: y), thickness: thickness,
                ))
            }
            if run.strike {
                let y = baseline - size * LayoutRichText.strikeOffsetEm
                result.append(LayoutRichTextDecoration(
                    from: CGPoint(x: from, y: y), to: CGPoint(x: to, y: y), thickness: thickness,
                ))
            }
        }
        return result
    }
}

/// A run placed on the page.
public struct LayoutRichTextPositionedRun: Sendable, Equatable {
    public let content: LayoutRichTextRun.Content
    public let font: LayoutFont
    /// Where the run's pen starts, on its baseline.
    public let baseline: CGPoint
}

/// An underline or strike-through bar: a stroke from `from` to `to`.
public struct LayoutRichTextDecoration: Sendable, Equatable {
    public let from: CGPoint
    public let to: CGPoint
    public let thickness: CGFloat

    /// The bar as a filled rect, for a renderer that fills rather than strokes.
    public var rect: CGRect {
        CGRect(x: from.x, y: from.y - thickness / 2, width: to.x - from.x, height: thickness)
    }
}

/// A formatted text typeset once at layout time, the way `LayoutHarmony` is: runs with their fonts and pen positions,
/// lines with their metrics, and the ink they cover. Measurement, the skyline, ink rects and every renderer read these
/// numbers, so what layout measures is what each renderer draws.
///
/// Coordinates are block-local — x from the left edge of the block's ink, y down from the top of the line stack. Each
/// line is placed by its own ink, as MuseScore's `TextLayout::textHorizontalLayout` places a text's blocks
/// (`rendering/score/textlayout.cpp:206-248`): the longest line's ink starts at 0, and a shorter line's sits `anchor.x`
/// of the difference further right — left-, center- or right-aligned against the longest for an anchor x of 0, 0.5 or
/// 1. The anchor stands in for MuseScore's horizontal alignment: its default styles pair each text's alignment with its
/// position (`Sid::staffTextAlign` / `staffTextPosition`, `engraving/style/styledef.cpp:1316, 1328`; lyrics at 109,
/// 116), and the anchor is where this layout hangs the text off its reference point. Where a style's alignment and
/// position differ (tempo, the marker roles) a multi-line text aligns its lines by position, not by MuseScore's
/// alignment; a one-line text, the common case, is unaffected. A consumer places the block with
/// `blockOrigin(at:anchor:)`, the rule `TextInkGeometry.baselineOrigin` applies to plain text: horizontally by ink,
/// vertically by the typographic stack.
public struct LayoutRichText: Sendable, Equatable {
    public let lines: [LayoutRichTextLine]
    /// The gap between consecutive lines, from the element's own font.
    public let leading: CGFloat
    /// Every run's ink and every decoration, block-local, `nil` when nothing inks. Whatever the alignment, its `minX`
    /// is 0 and its width the longest line's ink.
    public let ink: CGRect?
    /// Each line's baseline, down from the block's top: the first line's ascent, then each next one the previous line's
    /// descent, the leading and its own ascent further — `TextInkGeometry.typographicSize`'s stacking line by line, so
    /// single-font text measures exactly as plain text does.
    let lineBaselines: [CGFloat]
    /// The widest line's advance and the whole stack.
    let size: CGSize
    /// Each line's ink and decorations, x from the line's own pen start; `nil` for a line with none.
    private let lineInks: [CGRect?]

    init(lines: [LayoutRichTextLine], leading: CGFloat) {
        self.lines = lines
        self.leading = leading
        let baselines = Self.baselines(of: lines, leading: leading)
        lineBaselines = baselines
        size = CGSize(
            width: lines.map(\.width).max() ?? 0,
            height: (baselines.last ?? 0) + (lines.last?.descent ?? 0),
        )
        let inks = zip(lines, baselines).map { Self.lineInk(of: $0, baseline: $1) }
        lineInks = inks
        let union = inks.compactMap(\.self).reduce(CGRect?.none) { $0?.union($1) ?? $1 }
        let width = inks.compactMap { $0?.width }.max() ?? 0
        ink = union.map { CGRect(x: 0, y: $0.minY, width: width, height: $0.height) }
    }

    /// The block's top-left — the left edge of its ink, the top of its line stack — for an element whose `origin` names
    /// the point `anchor` divides the block at (UnitPoint convention: `(0, 1)` bottom-leading, `(0.5, 0.5)` center).
    /// A line's pen start sits its own ink's `minX` before that ink (`positionedRuns(at:anchor:)`).
    public func blockOrigin(at origin: CGPoint, anchor: CGPoint) -> CGPoint {
        CGPoint(x: origin.x - anchor.x * (ink?.width ?? 0), y: origin.y - anchor.y * size.height)
    }

    public func inkRect(at origin: CGPoint, anchor: CGPoint) -> CGRect? {
        guard let ink else { return nil }
        let block = blockOrigin(at: origin, anchor: anchor)
        return ink.offsetBy(dx: block.x, dy: block.y)
    }

    /// Every line's runs, each line's pen placed by its own ink and the anchor's alignment.
    public func positionedRuns(at origin: CGPoint, anchor: CGPoint) -> [LayoutRichTextPositionedRun] {
        let block = blockOrigin(at: origin, anchor: anchor)
        return lines.indices.flatMap { index in
            lines[index].positionedRuns(
                leftX: block.x + penX(ofLine: index, alignment: anchor.x),
                baselineY: block.y + lineBaselines[index],
            )
        }
    }

    /// Every line's bars, for the same placement as `positionedRuns(at:anchor:)`.
    public func decorations(at origin: CGPoint, anchor: CGPoint) -> [LayoutRichTextDecoration] {
        let block = blockOrigin(at: origin, anchor: anchor)
        return lines.indices.flatMap { index in
            lines[index].decorations(
                leftX: block.x + penX(ofLine: index, alignment: anchor.x),
                baselineY: block.y + lineBaselines[index],
            )
        }
    }

    /// Where line `index`'s pen starts, from the block's left ink edge: its own ink's left edge at 0, moved right by
    /// `alignment` of the gap between its ink and the longest line's — `textHorizontalLayout`'s `xAdj`. A line with no
    /// ink takes the whole width as its gap.
    private func penX(ofLine index: Int, alignment: CGFloat) -> CGFloat {
        let blockWidth = ink?.width ?? 0
        guard let lineInk = lineInks[index] else { return alignment * blockWidth }
        return alignment * (blockWidth - lineInk.width) - lineInk.minX
    }

    /// A line's glyph ink and decoration bars, x from its pen start, y block-local.
    private static func lineInk(of line: LayoutRichTextLine, baseline: CGFloat) -> CGRect? {
        let provider = FontMetrics.provider
        var union: CGRect?
        for run in line.runs {
            guard let box = provider.textInkBounds(text: run.content.string, font: run.font) else { continue }
            let rect = CGRect(
                x: run.x + box.minX, y: baseline + run.baselineShift - box.maxY, width: box.width, height: box.height,
            )
            union = union.map { $0.union(rect) } ?? rect
        }
        for bar in line.decorations(leftX: 0, baselineY: baseline) {
            union = union.map { $0.union(bar.rect) } ?? bar.rect
        }
        return union
    }

    static func baselines(of lines: [LayoutRichTextLine], leading: CGFloat) -> [CGFloat] {
        var result: [CGFloat] = []
        for (index, line) in lines.enumerated() {
            if let last = result.last {
                result.append(last + lines[index - 1].descent + leading + line.ascent)
            } else {
                result.append(line.ascent)
            }
        }
        return result
    }
}
