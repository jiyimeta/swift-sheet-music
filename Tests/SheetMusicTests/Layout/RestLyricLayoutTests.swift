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

/// A syllable under a rest is drawn, and spaced, like one under a chord. MuseScore anchors lyrics to any `ChordRest`
/// and lays a syllable out relative to its rest while the rest still stands at its segment (`RestLayout::layoutRest`
/// resets its x, `LyricsLayout::layout` negates it); `MeasureLayout` centers a full-measure rest only afterwards, and
/// the syllable moves with it — so it stands under the centered rest, and its offset counts from there. The segment's
/// shape carries the syllable into horizontal spacing like any other.
@Suite("Lyrics on rests in layout")
struct RestLyricLayoutTests {
    private let _installFontMetrics = TestSupport.installFontMetrics

    @Test("A full-measure rest's syllable is drawn under the centered rest, anchored to it")
    func measureRestSyllableStandsUnderTheRest() throws {
        let rest = Chord(duration: .measure, notes: [], lyrics: [Lyric(text: "でもね、")])
        let document = Self.layout(Self.score(bars: [[.chord(rest)]]))
        let measure = try #require(document.systems.first?.measures.first)
        let marks = Self.lyricMarks(in: measure)
        try #require(marks.count == 1)
        #expect(marks[0].text == "でもね、")
        #expect(marks[0].anchor?.elementIndex == 0)
        let restX = try #require(Self.restOrigins(in: measure).first).x
        let firstColumn = try #require(measure.tickColumns[0])
        // The two candidates stand 3 sp apart in this lone (unjustified) bar, so the check below tells them apart.
        try #require(restX - firstColumn > document.metrics.sp * 2)
        #expect(abs(marks[0].origin.x - restX) < 0.001)
    }

    /// The owner's report (2026-11-06): a moved syllable under a full-measure rest kept its distance from the bar's
    /// first column rather than from the rest, where MuseScore measures it.
    @Test("A full-measure rest's syllable offset counts from the rest")
    func measureRestSyllableOffsetCountsFromTheRest() throws {
        var lyric = Lyric(text: "でもね、")
        lyric.elementProperties.offset = ScoreOffset(x: -2.5, y: 3)
        let rest = Chord(duration: .measure, notes: [], lyrics: [lyric])
        let document = Self.layout(Self.score(bars: [[.chord(rest)]]))
        let measure = try #require(document.systems.first?.measures.first)
        let mark = try #require(Self.lyricMarks(in: measure).first)
        let restX = try #require(Self.restOrigins(in: measure).first).x
        #expect(abs(mark.origin.x - (restX - 2.5 * document.metrics.sp)) < 0.001)
    }

    @Test("A typed rest's syllable is drawn at the rest's column")
    func typedRestSyllableStandsAtItsColumn() throws {
        let elements: [VoiceElement] = [
            .chord(Self.note(.half, "la")),
            .chord(Chord(duration: .half, notes: [], lyrics: [Lyric(text: "ha")])),
        ]
        let document = Self.layout(Self.score(bars: [elements]))
        let measure = try #require(document.systems.first?.measures.first)
        let marks = Self.lyricMarks(in: measure)
        try #require(marks.count == 2)
        let restColumn = try #require(measure.tickColumns[960])
        #expect(marks.map(\.text) == ["la", "ha"])
        #expect(abs(marks[1].origin.x - restColumn) < 0.001)
    }

    @Test("A hidden-lyrics host drops a rest's syllable too")
    func hiddenLyricsDropRestSyllable() throws {
        let rest = Chord(duration: .measure, notes: [], lyrics: [Lyric(text: "でもね、")])
        let options = ScoreViewOptions(staffSize: 28, lyricsVisible: false)
        let document = LayoutEngine.layout(
            score: Self.score(bars: [[.chord(rest)]]), options: options, availableWidth: 900,
        )
        let measure = try #require(document.systems.first?.measures.first)
        #expect(Self.lyricMarks(in: measure).isEmpty)
    }

    /// Long syllables on sixteenths, rests among them: every syllable — under a note or under a rest — has to clear
    /// its neighbour, which only holds if a rest's syllable is a spacing demand and a note's syllable reaches to the
    /// rest's rather than past it.
    @Test("syllables under rests and notes keep clear of each other")
    func restSyllablesAreSpaced() throws {
        let word = "wwwwww"
        let elements: [VoiceElement] = (0 ..< 8).map { index in
            index.isMultiple(of: 2)
                ? .chord(Self.note(.sixteenth, word))
                : .chord(Chord(duration: .sixteenth, notes: [], lyrics: [Lyric(text: word)]))
        } + [.chord(Chord(duration: .half, notes: []))]
        let document = Self.layout(Self.score(bars: [elements]), wrap: false)
        let spans = Self.syllableSpans(document)
        try #require(spans.count == 8)
        for (left, right) in zip(spans, spans.dropFirst()) {
            #expect(left.right <= right.left + 0.001, "\(left) overlaps \(right)")
        }
    }

    /// Lyric entry opens on a selected rest (⌘L): the empty caret has to stand where the first letter will be drawn,
    /// under the centered rest for a full-measure one, or the field jumps when it is.
    @Test("an empty caret under a full-measure rest stands where its syllable is drawn")
    func emptyRestCaretMatchesItsSyllable() throws {
        let anchor = VoiceElementID(
            staff: StaffAddress(partIndex: 0, staffIndexInPart: 0), measureIndex: 0, voiceIndex: 0, elementIndex: 0,
        )
        let empty = Self.layout(Self.score(bars: [[.chord(Chord(duration: .measure, notes: []))]]))
        let caret = try #require(empty.lyricEntryOrigin(
            at: LyricInputPlanner.Cursor(location: anchor, verse: 0), placementStyle: TextPlacementStyles(),
            elementProperties: .default, textProperties: TextProperties(),
        ))
        let emptySystem = try #require(empty.systems.first)
        let emptyMeasure = try #require(emptySystem.measures.first)
        let restX = try #require(Self.restOrigins(in: emptyMeasure).first).x
        #expect(abs(caret.x - (emptySystem.origin.x + emptyMeasure.origin.x + restX)) < 0.001)
        let typed = Self.layout(Self.score(bars: [[
            .chord(Chord(duration: .measure, notes: [], lyrics: [Lyric(text: "で")])),
        ]]))
        let system = try #require(typed.systems.first)
        let measure = try #require(system.measures.first)
        let mark = try #require(Self.lyricMarks(in: measure).first)
        #expect(abs(caret.x - (system.origin.x + measure.origin.x + mark.origin.x)) < 0.001)
    }

    // MARK: - Helpers

    private static func note(_ duration: NoteDuration, _ syllable: String) -> Chord {
        Chord(duration: duration, notes: ChordNotes([Note(pitch: 64, tpc: 18)]), lyrics: [Lyric(text: syllable)])
    }

    private static func score(bars: [[VoiceElement]]) -> Score {
        let staff = Staff(measures: bars.map { Measure(voices: [Voice(elements: $0)]) })
        return Score(division: 480, parts: [Part(id: "1", instrument: Instrument(id: "voice"), staves: [staff])])
    }

    private static func layout(_ score: Score, wrap: Bool = true) -> LayoutDocument {
        let options = ScoreViewOptions(staffSize: 28, wrapToViewWidth: wrap)
        let width = wrap ? 900 : LayoutEngine.naturalContentWidth(score: score, options: options)
        return LayoutEngine.layout(score: score, options: options, availableWidth: width)
    }

    private static func lyricMarks(
        in measure: LayoutMeasure,
    ) -> [(text: String, origin: CGPoint, anchor: VoiceElementID?)] {
        measure.elements.compactMap { element -> (text: String, origin: CGPoint, anchor: VoiceElementID?)? in
            guard case let .textMark(.lyrics(_, _, anchor, _, _), text, origin, _) = element else { return nil }
            return (text, origin, anchor)
        }.sorted { $0.origin.x < $1.origin.x }
    }

    private static func restOrigins(in measure: LayoutMeasure) -> [CGPoint] {
        measure.elements.compactMap { element -> CGPoint? in
            guard case let .rest(_, origin, _, _, _) = element else { return nil }
            return origin
        }
    }

    private static func syllableSpans(_ document: LayoutDocument) -> [(left: CGFloat, right: CGFloat)] {
        document.systems.flatMap(\.measures).flatMap { measure in
            measure.elements.compactMap { element -> (left: CGFloat, right: CGFloat)? in
                guard case let .textMark(.lyrics, text, origin, _) = element else { return nil }
                let half = LayoutEngine.lyricsTextWidth(text, sp: document.metrics.sp) / 2
                let x = measure.origin.x + origin.x
                return (x - half, x + half)
            }
        }.sorted { $0.left < $1.left }
    }
}
