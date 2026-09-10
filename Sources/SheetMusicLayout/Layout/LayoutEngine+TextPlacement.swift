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

    static func placedTextOrigin(
        text: String, role: TextPlacementRole, properties: ElementProperties,
        style: TextPlacementStyles, x: CGFloat, lineGeometry: StaffLineGeometry,
        metrics: StaffMetrics, font: LayoutFont, center: Bool, padding: CGFloat = 0,
    ) -> CGPoint {
        let side = style.side(for: role, element: properties)
        let position = style.position(for: role, side: side)
        let edge = metrics.sp * 2 + (side == .above ? 0 : lineGeometry.height(sp: metrics.sp))
        let baseline = CGPoint(x: x + CGFloat(position.x) * metrics.sp, y: edge + CGFloat(position.y) * metrics.sp)
        let origin = textPlacementOrigin(text: text, font: font, baseline: baseline, center: center, padding: padding)
        return CGPoint(
            x: origin.x + CGFloat(properties.offset?.x ?? 0) * metrics.sp,
            y: origin.y + CGFloat(properties.offset?.y ?? 0) * metrics.sp,
        )
    }

    static func lyricOrigin(
        lyric: Lyric, verse: Int, maxAboveVerse: Int, style: TextPlacementStyles,
        x: CGFloat, lineGeometry: StaffLineGeometry, metrics: StaffMetrics,
    ) -> CGPoint {
        let side = style.side(for: .lyrics, element: lyric.elementProperties)
        let origin = placedTextOrigin(
            text: lyric.text, role: .lyrics, properties: lyric.elementProperties,
            style: style, x: x, lineGeometry: lineGeometry, metrics: metrics,
            font: TextInkGeometry.font(for: .lyricsOdd, metrics: metrics), center: true,
        )
        let row = side == .above ? verse - maxAboveVerse : verse
        return CGPoint(x: origin.x, y: origin.y + CGFloat(row) * metrics.sp * lyricVerseStrideInSpatiums)
    }

    static func lyricAnchorCorrectionY(lyric: Lyric, metrics: StaffMetrics) -> CGFloat {
        let font = TextInkGeometry.font(for: .lyricsOdd, metrics: metrics)
        let provider = FontMetrics.provider
        let extra = TextInkGeometry.typographicSize(text: lyric.text, font: font).height
            - provider.ascent(font: font) - provider.descent(font: font)
        return CGFloat(lyric.elementProperties.offset?.y ?? 0) * metrics.sp + extra / 2
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
    ) -> Int {
        var maximum = 0
        for index in measures {
            if staff.measures.indices.contains(index) {
                for voice in staff.measures[index].voices {
                    for element in voice.elements {
                        guard case let .chord(chord) = element else { continue }
                        for (verse, lyric) in chord.lyrics.enumerated()
                            where lyric.visible && !lyric.text.isEmpty
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
