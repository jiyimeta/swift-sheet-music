#if canImport(CoreGraphics)
    import CoreGraphics
#endif
import SheetMusicCore

/// A title-block credit a host can edit in place — the title, subtitle, composer or lyricist engraved at the head of
/// the first page — with the geometry an inline editor needs to sit over it.
///
/// **Only what `SetScoreInfo` can write back is reported.** That command addresses a credit by FIELD and rewrites the
/// first frame text of the field's style, so this answers for exactly that text: a second composer line carried in
/// from a file, or a text of the unranked `.other` style, has no command to receive an edit and is left out rather
/// than offered and then silently written somewhere else.
///
/// **Only a one-line credit is reported.** A multi-line `<Text>` block (test-platinum.mscx's three Lyricist columns)
/// cannot be edited in a single-line field without flattening it, so it is not offered for one.
public struct CreditTextLine: Sendable, Equatable {
    public let field: ScoreInfoWrite.Field
    public let text: String
    public let fontSize: CGFloat
    /// Where the line's anchor lands in document coordinates: `x` per `horizontalAnchor`, `y` the line's top edge.
    public let origin: CGPoint
    /// How much of the line lies to the left of `origin.x`: 0 leading, 0.5 centered, 1 trailing.
    public let horizontalAnchor: CGFloat
    /// The line's box in document coordinates: its measured ink width, aligned the way the renderer aligns it, and
    /// the face's full ascent-plus-descent height below `origin.y`. A formatted line (bold, a `<font size>`, a symbol)
    /// takes the ink of the runs the renderers draw instead, so the box covers what is on the page.
    public let frame: CGRect
    /// Whether every text run of the line is bold in its `LayoutFont`.
    public let isBold: Bool
    /// Whether every text run of the line is italic in its `LayoutFont`.
    public let isItalic: Bool

    init(
        field: ScoreInfoWrite.Field,
        text: String,
        fontSize: CGFloat,
        origin: CGPoint,
        horizontalAnchor: CGFloat,
        frame: CGRect,
        isBold: Bool = false,
        isItalic: Bool = false,
    ) {
        self.field = field
        self.text = text
        self.fontSize = fontSize
        self.origin = origin
        self.horizontalAnchor = horizontalAnchor
        self.frame = frame
        self.isBold = isBold
        self.isItalic = isItalic
    }

    /// The face the title block is drawn in. Title-block texts are set in the platform's system font at their
    /// resolved size (`LayoutTitleFrame.font(size:)`), which `LayoutFont`'s empty face names.
    public var font: LayoutFont {
        Self.font(size: fontSize, isBold: isBold, isItalic: isItalic)
    }

    /// The title face at `size` with the line's traits.
    fileprivate static func font(size: CGFloat, isBold: Bool, isItalic: Bool) -> LayoutFont {
        let base = LayoutTitleFrame.font(size: size)
        return LayoutFont(
            face: base.face, pointSize: size, weight: isBold ? .bold : base.weight, isItalic: isItalic,
        )
    }
}

extension LayoutDocument {
    /// Every editable credit on this document's title block, in engraving order. Empty when there is no title block
    /// — a page other than the first, or a layout asked for without one.
    public var creditTextLines: [CreditTextLine] {
        guard let titleFrame else { return [] }
        let lines = titleFrame.placedLines()
        var seenStyles: Set<FrameText.Style> = []
        var result: [CreditTextLine] = []
        for (index, entry) in titleFrame.texts.enumerated() {
            guard let field = ScoreInfoWrite.Field.allCases.first(where: { $0.frameTextStyle == entry.style }),
                  seenStyles.insert(entry.style).inserted
            else { continue }
            let entryLines = lines.filter { $0.entryIndex == index }
            guard entryLines.count == 1, let line = entryLines.first else { continue }
            result.append(Self.creditTextLine(field: field, line: line))
        }
        return result
    }

    /// The editable credit whose box contains `point`, grown by `tolerance` on every side; `nil` when none does.
    public func creditTextLine(at point: CGPoint, tolerance: CGFloat = 0) -> CreditTextLine? {
        creditTextLines.first { $0.frame.insetBy(dx: -tolerance, dy: -tolerance).contains(point) }
    }

    /// The editable credit engraved for `field`, or `nil` when that field has no one-line text on the title block.
    public func creditTextLine(for field: ScoreInfoWrite.Field) -> CreditTextLine? {
        creditTextLines.first { $0.field == field }
    }

    private static func creditTextLine(field: ScoreInfoWrite.Field, line: LayoutTitleFrame.PlacedLine)
        -> CreditTextLine
    {
        let textFonts = (line.richLine?.runs ?? []).compactMap { run -> LayoutFont? in
            if case .text = run.content { run.font } else { nil }
        }
        let isBold = !textFonts.isEmpty && textFonts.allSatisfy { $0.weight == .bold }
        let isItalic = !textFonts.isEmpty && textFonts.allSatisfy(\.isItalic)
        return CreditTextLine(
            field: field,
            text: line.text,
            fontSize: line.fontSize,
            origin: line.position,
            horizontalAnchor: line.horizontalAnchor,
            frame: richFrame(of: line) ?? plainFrame(of: line, isBold: isBold, isItalic: isItalic),
            isBold: isBold,
            isItalic: isItalic,
        )
    }

    /// A plain line's box. The layer renderer aligns a title line on its INK box (`ScoreLayerBuilder.textLayer`), so
    /// the box is measured the same way; an ink-less line (spaces only) falls back to its advance.
    private static func plainFrame(of line: LayoutTitleFrame.PlacedLine, isBold: Bool, isItalic: Bool) -> CGRect {
        let font = CreditTextLine.font(size: line.fontSize, isBold: isBold, isItalic: isItalic)
        let provider = FontMetrics.provider
        let width = provider.textInkBounds(text: line.text, font: font)?.width
            ?? provider.typographicWidth(text: line.text, font: font)
        let height = provider.ascent(font: font) + provider.descent(font: font)
        return CGRect(
            x: line.position.x - line.horizontalAnchor * width, y: line.position.y, width: width, height: height,
        )
    }

    /// A formatted line's box: the ink of the runs and bars the renderers draw for it (`PlacedLine.positionedRuns`,
    /// `decorations`), over the band from the line's top edge down its own ascent and descent. A bold run, a
    /// `<font size>` or a symbol inks wider or taller than the plain face the plain box is measured in, and the tap
    /// target and the inline editor sit over what was drawn. `nil` for a plain line, and for one with no ink, which
    /// falls back to the plain box.
    private static func richFrame(of line: LayoutTitleFrame.PlacedLine) -> CGRect? {
        guard let richLine = line.richLine else { return nil }
        let provider = FontMetrics.provider
        var ink: CGRect?
        for run in line.positionedRuns {
            guard let box = provider.textInkBounds(text: run.content.string, font: run.font) else { continue }
            let rect = CGRect(
                x: run.baseline.x + box.minX, y: run.baseline.y - box.maxY, width: box.width, height: box.height,
            )
            ink = ink.map { $0.union(rect) } ?? rect
        }
        for bar in line.decorations {
            ink = ink.map { $0.union(bar.rect) } ?? bar.rect
        }
        guard let ink else { return nil }
        let band = CGRect(
            x: ink.minX, y: line.position.y, width: ink.width, height: richLine.ascent + richLine.descent,
        )
        return band.union(ink)
    }
}
