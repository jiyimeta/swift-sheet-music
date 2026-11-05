#if canImport(CoreGraphics)
    import CoreGraphics
#endif
import Foundation
@testable import SheetMusicCore
@testable import SheetMusicLayout
import Testing

#if !canImport(CoreGraphics)
    private typealias CGFloat = SheetMusicLayout.CGFloat
    private typealias CGPoint = SheetMusicLayout.CGPoint
#endif

/// An engraved text's authored `<offset>` replaces its style's position; it does not add to it. MuseScore lays a text
/// out at its staff edge (`TextLayout::layoutBaseTextBase`) and draws it at that plus its offset, whose default value
/// IS the style's position (`textstyle.cpp`), so a file writes the whole offset once the text was moved.
///
/// Reported 2026-11-05 in a medley: three syllables MuseScore wrote as `<offset x="…" y="3"/>` — moved right along
/// their own row, `3` being `Sid::lyricsPosBelow` — were drawn a row's worth below it, and the spoken 「でもね、」 at
/// `y="2.12607"` 2 sp below the row where MuseScore draws it a little above.
@Suite("A text's authored offset replaces its style position")
struct TextOffsetReplacesStyleTests {
    private let _installFontMetrics = TestSupport.installFontMetrics

    @Test("a syllable whose offset carries the style's own y stays on the row")
    func lyricOffsetAtStyleYStaysOnRow() throws {
        let plain = try Self.lyricY(offset: nil)
        let moved = try Self.lyricY(offset: ScoreOffset(x: 4.16073, y: 3))
        #expect(abs(moved - plain) < 0.001)
    }

    @Test("a syllable's offset y is measured from the staff's bottom line")
    func lyricOffsetIsMeasuredFromTheStaff() throws {
        let plain = try Self.lyricY(offset: nil)
        let raised = try Self.lyricY(offset: ScoreOffset(x: 0, y: 2.12607))
        #expect(abs((raised - plain) - CGFloat(2.12607 - 3) * Self.sp) < 0.001)
    }

    @Test("a syllable's offset x replaces the style's x")
    func lyricOffsetXReplacesStyleX() throws {
        var style = TextPlacementStyles()
        style[.lyrics].positionBelow = ScoreOffset(x: 1, y: 3)
        let styled = try Self.lyricX(offset: nil, style: style)
        let moved = try Self.lyricX(offset: ScoreOffset(x: 0.5, y: 3), style: style)
        #expect(abs((moved - styled) - CGFloat(0.5 - 1) * Self.sp) < 0.001)
    }

    @Test("staff text's offset y is measured from the staff's top line")
    func staffTextOffsetIsMeasuredFromTheStaff() throws {
        let plain = try Self.staffTextY(offset: nil)
        let moved = try Self.staffTextY(offset: ScoreOffset(x: 0.753912, y: -4))
        // `Sid::staffTextPosAbove` is (0, -1).
        #expect(abs((moved - plain) - CGFloat(-4 - -1) * Self.sp) < 0.001)
    }

    @Test("a tempo marking's offset y is measured from the staff's top line")
    func tempoOffsetIsMeasuredFromTheStaff() throws {
        let plain = try Self.tempoY(offset: nil)
        let moved = try Self.tempoY(offset: ScoreOffset(x: 0.159757, y: -4.39983))
        // `Sid::tempoPosAbove` is (0, -2).
        #expect(abs((moved - plain) - CGFloat(-4.39983 - -2) * Self.sp) < 0.001)
        let atStyle = try Self.tempoY(offset: ScoreOffset(x: 0.292079, y: -2))
        #expect(abs(atStyle - plain) < 0.001)
    }

    // MARK: - Helpers

    private static let sp: CGFloat = StaffMetrics(staffSize: 28).sp

    private static func layout(
        _ elements: [VoiceElement],
        systemElement: SystemElement? = nil,
        style: TextPlacementStyles = .init(),
    ) -> LayoutDocument {
        var score = Score(
            division: 480,
            parts: [Part(id: "1", instrument: Instrument(id: "voice"), staves: [Staff(measures: [
                Measure(voices: [Voice(elements: elements)]),
            ])])],
        )
        score.style.textPlacement = style
        if let systemElement {
            score.systemMeasures = [SystemMeasure(elements: [PositionedSystemElement(
                position: .start, element: systemElement,
                originalStaff: StaffAddress(partIndex: 0, staffIndexInPart: 0),
            )])]
        }
        return LayoutEngine.layout(score: score, options: ScoreViewOptions(staffSize: 28), availableWidth: 900)
    }

    private static let wholeNote = VoiceElement.chord(
        Chord(duration: .whole, notes: ChordNotes([Note(pitch: 60, tpc: 14)])),
    )

    private static func allElements(_ document: LayoutDocument) -> [LayoutElement] {
        document.systems.flatMap(\.measures).flatMap(\.elements)
    }

    /// The top staff line's y in the same frame as the measure elements. A system is shifted so its highest ink sits
    /// at its top, so a text above the staff moves the staff, not itself: heights are read off the staff.
    private static func topStaffLine(_ document: LayoutDocument) throws -> CGFloat {
        try #require(allElements(document).lazy.compactMap { element -> CGFloat? in
            guard case let .barLine(_, origin, halfHeight, _, _) = element else { return nil }
            return origin.y - halfHeight
        }.first)
    }

    private static func note(lyricOffset: ScoreOffset?) -> VoiceElement {
        var lyric = Lyric(text: "la")
        lyric.elementProperties.offset = lyricOffset
        lyric.elementProperties.autoplace = false
        return .chord(Chord(duration: .whole, notes: ChordNotes([Note(pitch: 72, tpc: 14)]), lyrics: [lyric]))
    }

    private static func lyricMark(_ document: LayoutDocument) throws -> CGPoint {
        let measure = try #require(document.systems.first?.measures.first)
        let origin = try #require(measure.elements.lazy.compactMap { element -> CGPoint? in
            guard case let .textMark(.lyrics, _, origin, _) = element else { return nil }
            return origin
        }.first)
        return CGPoint(x: measure.origin.x + origin.x, y: measure.origin.y + origin.y)
    }

    private static func lyricY(offset: ScoreOffset?) throws -> CGFloat {
        let document = layout([note(lyricOffset: offset)])
        let measureY = try #require(document.systems.first?.measures.first).origin.y
        return try lyricMark(document).y - measureY - topStaffLine(document)
    }

    private static func lyricX(offset: ScoreOffset?, style: TextPlacementStyles) throws -> CGFloat {
        try lyricMark(layout([note(lyricOffset: offset)], style: style)).x
    }

    private static func staffTextY(offset: ScoreOffset?) throws -> CGFloat {
        var text = StaffText(text: "体育館ディスコ")
        text.elementProperties.offset = offset
        text.elementProperties.autoplace = false
        let document = layout([wholeNote], systemElement: .staffText(text))
        return try #require(allElements(document).lazy.compactMap { element -> CGFloat? in
            guard case let .staffText(_, origin, _, _, _, _, _, _, _) = element else { return nil }
            return origin.y
        }.first) - topStaffLine(document)
    }

    private static func tempoY(offset: ScoreOffset?) throws -> CGFloat {
        var tempo = Tempo(beatsPerSecond: 136.0 / 60)
        tempo.elementProperties.offset = offset
        tempo.elementProperties.autoplace = false
        let document = layout([wholeNote], systemElement: .tempo(tempo))
        return try #require(allElements(document).lazy.compactMap { element -> CGFloat? in
            guard case let .textMark(.tempo, _, origin, _) = element else { return nil }
            return origin.y
        }.first) - topStaffLine(document)
    }
}
