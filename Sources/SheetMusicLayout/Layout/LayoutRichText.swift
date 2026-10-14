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
    /// run. Symbols do not count: Bravura's em box is far taller than its ink, and MuseScore special-cases music fonts
    /// the same way (`TextLayout::layoutTextBlock`, `rendering/score/textlayout.cpp:375-381`).
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
/// Coordinates are block-local — x from each line's pen start, y down from the top of the line stack. A consumer places
/// the block with `blockOrigin(at:anchor:)`, the rule `TextInkGeometry.baselineOrigin` applies to plain text:
/// horizontally by ink, vertically by the typographic stack.
public struct LayoutRichText: Sendable, Equatable {
    public let lines: [LayoutRichTextLine]
    /// The gap between consecutive lines, from the element's own font.
    public let leading: CGFloat
    /// Every run's ink and every decoration, block-local; `nil` when nothing inks.
    public let ink: CGRect?

    init(lines: [LayoutRichTextLine], leading: CGFloat) {
        self.lines = lines
        self.leading = leading
        let provider = FontMetrics.provider
        var union: CGRect?
        for (line, baseline) in zip(lines, Self.baselines(of: lines, leading: leading)) {
            for run in line.runs {
                guard let box = provider.textInkBounds(text: run.content.string, font: run.font) else { continue }
                let rect = CGRect(
                    x: run.x + box.minX, y: baseline + run.baselineShift - box.maxY,
                    width: box.width, height: box.height,
                )
                union = union.map { $0.union(rect) } ?? rect
            }
            for bar in line.decorations(leftX: 0, baselineY: baseline) {
                union = union.map { $0.union(bar.rect) } ?? bar.rect
            }
        }
        ink = union
    }

    /// Each line's baseline, down from the block's top: the first line's ascent, then each next one the previous line's
    /// descent, the leading and its own ascent further — `TextInkGeometry.typographicSize`'s stacking line by line, so
    /// single-font text measures exactly as plain text does.
    public var lineBaselines: [CGFloat] {
        Self.baselines(of: lines, leading: leading)
    }

    /// The widest line and the whole stack.
    public var size: CGSize {
        CGSize(
            width: lines.map(\.width).max() ?? 0,
            height: (lineBaselines.last ?? 0) + (lines.last?.descent ?? 0),
        )
    }

    /// The block's top-left, at the pen start, for an element whose `origin` names the point `anchor` divides the block
    /// at (UnitPoint convention: `(0, 1)` bottom-leading, `(0.5, 0.5)` center).
    public func blockOrigin(at origin: CGPoint, anchor: CGPoint) -> CGPoint {
        CGPoint(
            x: origin.x - (ink?.minX ?? 0) - anchor.x * (ink?.width ?? 0),
            y: origin.y - anchor.y * size.height,
        )
    }

    public func inkRect(at origin: CGPoint, anchor: CGPoint) -> CGRect? {
        guard let ink else { return nil }
        let block = blockOrigin(at: origin, anchor: anchor)
        return ink.offsetBy(dx: block.x, dy: block.y)
    }

    public func positionedRuns(at origin: CGPoint, anchor: CGPoint) -> [LayoutRichTextPositionedRun] {
        let block = blockOrigin(at: origin, anchor: anchor)
        return zip(lines, lineBaselines).flatMap { line, baseline in
            line.positionedRuns(leftX: block.x, baselineY: block.y + baseline)
        }
    }

    public func decorations(at origin: CGPoint, anchor: CGPoint) -> [LayoutRichTextDecoration] {
        let block = blockOrigin(at: origin, anchor: anchor)
        return zip(lines, lineBaselines).flatMap { line, baseline in
            line.decorations(leftX: block.x, baselineY: block.y + baseline)
        }
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
