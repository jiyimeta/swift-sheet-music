#if canImport(CoreGraphics)
    import CoreGraphics
#endif
import SheetMusicCore
import SheetMusicFoundation

extension LayoutEngine {
    /// Converts a first-line baseline into the renderer's whole-block anchor.
    static func textPlacementOrigin(
        text: String, font: LayoutFont, baseline: CGPoint, center: Bool, padding: CGFloat = 0,
    ) -> CGPoint {
        let provider = FontMetrics.provider
        let ascent = provider.ascent(font: font)
        let descent = provider.descent(font: font)
        let extra = TextInkGeometry.typographicSize(text: text, font: font).height - ascent - descent
        return CGPoint(
            x: baseline.x,
            y: baseline.y + (center ? -(ascent - descent) / 2 + extra / 2 : descent + extra) + padding,
        )
    }

    /// `textPlacementOrigin(text:font:…)` for typeset runs: the same rule, with the first line's own ascent and
    /// descent and the whole stack's height standing in for one font's.
    static func textPlacementOrigin(
        rich: LayoutRichText, baseline: CGPoint, center: Bool, padding: CGFloat = 0,
    ) -> CGPoint {
        let ascent = rich.lines.first?.ascent ?? 0
        let descent = rich.lines.first?.descent ?? 0
        let extra = rich.size.height - ascent - descent
        return CGPoint(
            x: baseline.x,
            y: baseline.y + (center ? -(ascent - descent) / 2 + extra / 2 : descent + extra) + padding,
        )
    }

    /// Where a tempo marking's `LayoutRichText.anchor(for: .tempo)` (top-left) origin goes so its FIRST BASELINE sits
    /// at MuseScore's tempo position: `tempoPosAbove` = (0, -2 sp) from the top staff line, `tempoPosBelow` = (0, 3 sp)
    /// from the bottom one (`engraving/style/styledef.cpp:1149-1159`, `tempoAlign` = LEFT, BASELINE). The staff's top
    /// line is at `2 sp` in a measure's frame, as for `placedTextOrigin`. `offset` is the authored offset in sp, which
    /// replaces that position rather than adding to it, as every text's does (`placedTextPosition`).
    static func tempoOrigin(
        rich: LayoutRichText, side: Placement, x: CGFloat, offset: ScoreOffset?,
        lineGeometry: StaffLineGeometry, metrics: StaffMetrics,
    ) -> CGPoint {
        let sp = metrics.sp
        let edge = side == .above ? sp * 2 : sp * 2 + lineGeometry.height(sp: sp)
        let position = offset ?? ScoreOffset(x: 0, y: Double(side == .above ? -tempoPosAboveSp : tempoPosBelowSp))
        return CGPoint(
            x: x + CGFloat(position.x) * sp,
            y: edge + CGFloat(position.y) * sp - rich.firstBaseline,
        )
    }

    /// `Sid::tempoPosAbove`'s distance above the top staff line, in spatiums (`styledef.cpp:1157`).
    static let tempoPosAboveSp: CGFloat = 2
    /// `Sid::tempoPosBelow`'s distance below the bottom staff line, in spatiums (`styledef.cpp:1158`).
    static let tempoPosBelowSp: CGFloat = 3

    /// Where a text's first baseline sits from its staff edge — the top line above the staff, the bottom line below
    /// it — in spatiums: the element's authored offset when it carries one, else the style's position for `side`.
    ///
    /// The authored offset REPLACES the styled position; it does not add to it. MuseScore lays a text out at (0, 0),
    /// or (0, staff height) below the staff (`TextLayout::layoutBaseTextBase`), and draws it at that plus its offset
    /// (`EngravingItem::pos()`), whose default value is the style's position (`textstyle.cpp`: `Sid::lyricsPosBelow`
    /// for a lyric, `Sid::staffTextPosAbove` for staff text, …). So a file writes the whole offset, style part and
    /// all, once the text was moved: `<offset x="4.16" y="3"/>` under a lyric is a syllable moved right along its own
    /// row, and adding it to the style's 3 sp dropped it a row's worth below.
    static func placedTextPosition(
        role: TextPlacementRole, properties: ElementProperties, style: TextPlacementStyles, side: Placement,
    ) -> ScoreOffset {
        properties.offset ?? style.position(for: role, side: side)
    }

    static func placedTextOrigin(
        text: String, role: TextPlacementRole, properties: ElementProperties,
        style: TextPlacementStyles, x: CGFloat, lineGeometry: StaffLineGeometry,
        metrics: StaffMetrics, font: LayoutFont, center: Bool, padding: CGFloat = 0,
        rich: LayoutRichText? = nil,
    ) -> CGPoint {
        let side = style.side(for: role, element: properties)
        let position = placedTextPosition(role: role, properties: properties, style: style, side: side)
        let edge = metrics.sp * 2 + (side == .above ? 0 : lineGeometry.height(sp: metrics.sp))
        let baseline = CGPoint(x: x + CGFloat(position.x) * metrics.sp, y: edge + CGFloat(position.y) * metrics.sp)
        return rich.map { textPlacementOrigin(rich: $0, baseline: baseline, center: center, padding: padding) }
            ?? textPlacementOrigin(text: text, font: font, baseline: baseline, center: center, padding: padding)
    }

    /// How far, in spatiums, a syllable's authored offset moves it off its verse row's styled position — what a
    /// caret recovering the row takes back out (`lyricAnchorCorrectionY`, `LayoutDocument.lyricLineY`). Zero for a
    /// syllable with no offset, and for one whose offset is the style's own.
    static func lyricRowDisplacementY(_ properties: ElementProperties, style: TextPlacementStyles) -> Double {
        let side = style.side(for: .lyrics, element: properties)
        return placedTextPosition(role: .lyrics, properties: properties, style: style, side: side).y
            - style.position(for: .lyrics, side: side).y
    }

    static func lyricOrigin(
        lyric: Lyric, verse: Int, maxAboveVerse: Int, style: TextPlacementStyles,
        x: CGFloat, lineGeometry: StaffLineGeometry, metrics: StaffMetrics,
    ) -> CGPoint {
        let side = style.side(for: .lyrics, element: lyric.elementProperties)
        let origin = placedTextOrigin(
            text: lyric.text, role: .lyrics, properties: lyric.elementProperties,
            style: style, x: x, lineGeometry: lineGeometry, metrics: metrics,
            font: TextInkGeometry.font(for: .lyricsOdd, overrides: lyric.properties, metrics: metrics), center: true,
        )
        let row = side == .above ? verse - maxAboveVerse : verse
        return CGPoint(x: origin.x, y: origin.y + CGFloat(row) * metrics.sp * lyricVerseStrideInSpatiums)
    }

    static func lyricAnchorCorrectionY(
        lyric: Lyric, style: TextPlacementStyles, metrics: StaffMetrics,
    ) -> CGFloat {
        let font = TextInkGeometry.font(for: .lyricsOdd, overrides: lyric.properties, metrics: metrics)
        let provider = FontMetrics.provider
        let extra = TextInkGeometry.typographicSize(text: lyric.text, font: font).height
            - provider.ascent(font: font) - provider.descent(font: font)
        let correction = CGFloat(lyricRowDisplacementY(lyric.elementProperties, style: style)) * metrics.sp
            + extra / 2
        guard lyric.properties.hasFontOverride else { return correction }
        // Not the row's displacement either, so a caret recovering the row takes it out with the rest.
        return correction + lyricCenterShift(properties: lyric.properties, metrics: metrics)
    }

    /// How far below the lyric row's center a syllable's center sits because of its own font. The syllable shares
    /// the row's BASELINE and centers its (ascent − descent) band on it, so a taller font raises the center.
    /// Zero, without any arithmetic, when `properties` carries no face, size or style override.
    static func lyricCenterShift(properties: TextProperties, metrics: StaffMetrics) -> CGFloat {
        guard properties.hasFontOverride else { return 0 }
        let provider = FontMetrics.provider
        let row = TextInkGeometry.font(for: .lyricsOdd, metrics: metrics)
        let own = TextInkGeometry.font(for: .lyricsOdd, overrides: properties, metrics: metrics)
        return (provider.ascent(font: row) - provider.descent(font: row)) / 2
            - (provider.ascent(font: own) - provider.descent(font: own)) / 2
    }

    static func harmonyPlacementRole(_ harmony: Harmony) -> TextPlacementRole {
        switch harmony.harmonyType {
        case .standard: .harmonyA
        case .roman: .romanNumeral
        case .nashville: .nashvilleNumber
        }
    }

    static func maxAboveLyricVerse(
        staff: Staff, measures: Range<Int>, style: TextPlacementStyles, continuations: [[MelismaContinuation]],
        showsInvisibleElements: Bool,
    ) -> Int {
        // The visible and ghost rows share one ordering only while ghosts are shown.
        // Print layout must not move a visible row because a hidden higher verse exists.
        var maximum = 0
        for index in measures {
            if staff.measures.indices.contains(index) {
                for voice in staff.measures[index].voices {
                    for element in voice.elements {
                        guard case let .chord(chord) = element else { continue }
                        for (verse, lyric) in chord.lyrics.enumerated()
                            where (lyric.visible || showsInvisibleElements) && lyricHasContent(lyric)
                            && style.side(for: .lyrics, element: lyric.elementProperties) == .above
                        {
                            maximum = max(maximum, verse)
                        }
                    }
                }
            }
            if continuations.indices.contains(index) {
                for continuation in continuations[index]
                    where style.side(for: .lyrics, element: continuation.lyric.elementProperties) == .above
                {
                    maximum = max(maximum, continuation.verseIndex)
                }
            }
        }
        return maximum
    }
}
