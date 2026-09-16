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
    /// the face's full ascent-plus-descent height below `origin.y`.
    public let frame: CGRect

    /// The face the title block is drawn in. Title-block texts are set in the platform's system font at their
    /// resolved size (`TitleFrameRenderer`), which `LayoutFont`'s empty face names.
    public var font: LayoutFont {
        LayoutFont(face: "", pointSize: fontSize)
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
        let font = LayoutFont(face: "", pointSize: line.fontSize)
        let provider = FontMetrics.provider
        // The layer renderer aligns a title line on its INK box (`ScoreLayerBuilder.textLayer`), so the box is
        // measured the same way; an ink-less line (spaces only) falls back to its advance.
        let width = provider.textInkBounds(text: line.text, font: font)?.width
            ?? provider.typographicWidth(text: line.text, font: font)
        let height = provider.ascent(font: font) + provider.descent(font: font)
        return CreditTextLine(
            field: field,
            text: line.text,
            fontSize: line.fontSize,
            origin: line.position,
            horizontalAnchor: line.horizontalAnchor,
            frame: CGRect(
                x: line.position.x - line.horizontalAnchor * width,
                y: line.position.y,
                width: width,
                height: height,
            ),
        )
    }
}
