#if canImport(CoreGraphics)
    import CoreGraphics
#endif
import Foundation
@testable import SheetMusicCore
@testable import SheetMusicLayout
import Testing

#if !canImport(CoreGraphics)
    private typealias CGFloat = SheetMusicLayout.CGFloat
#endif

/// A justified system spreads its leftover room over every note on the line at once, the way MuseScore's springs do
/// (`HorizontalSpacing::justifySystem`): equal durations come out equally wide in every bar, and a gap something has
/// already pushed open takes no more until the others have caught up with it.
///
/// Reported 2026-10-17: scaling each bar's width by one ratio handed a bar more of the leftover the wider its minimum
/// was — for a header, a syllable's room, an accidental — so one system's eighths stood 1.75 to 9.8 sp apart.
@Suite("System justification")
struct SystemJustificationTests {
    private let _installFontMetrics = TestSupport.installFontMetrics

    /// One bar of quarters per entry of `bars`, `bars[m][i]` the syllable under chord `i` of bar `m` (`nil` = none).
    private static func score(_ bars: [[String?]]) -> Score {
        let measures = bars.map { syllables in
            Measure(voices: [Voice(elements: syllables.enumerated().map { index, syllable in
                VoiceElement.chord(Chord(
                    duration: .quarter, notes: ChordNotes([Note(pitch: 60 + index, tpc: 14)]),
                    lyrics: syllable.map { [Lyric(text: $0)] } ?? [],
                ))
            })])
        }
        return Score(
            division: 480,
            parts: [Part(id: "1", instrument: Instrument(id: "voice"), staves: [Staff(measures: measures)])],
        )
    }

    private static func layout(_ score: Score) -> LayoutDocument {
        LayoutEngine.layout(score: score, options: ScoreViewOptions(staffSize: 28), availableWidth: 900)
    }

    /// Each measure's distances between its consecutive chords, measure by measure.
    private static func gapsPerMeasure(_ document: LayoutDocument) -> [[CGFloat]] {
        document.systems.flatMap(\.measures).map { measure in
            let xs = measure.elements.compactMap { element -> CGFloat? in
                guard case let .chord(notes, _, _, _, _, _, _, _, _, _, _) = element else { return nil }
                return notes.first.map { measure.origin.x + $0.origin.x }
            }.sorted()
            return zip(xs.dropFirst(), xs).map { $0 - $1 }
        }
    }

    private static let plain: [String?] = [nil, nil, nil, nil]

    /// The first bar carries the system's clef, and the second short syllables that need more than a quarter's room
    /// at the bar's minimum but much less than the line gives them: neither may widen its own quarters.
    @Test("equal notes stand equally apart in every bar of a justified system")
    func equalNotesInEveryBar() throws {
        let document = Self.layout(Self.score([Self.plain, ["la", "love", "sing", "oh"], Self.plain, Self.plain]))
        try #require(document.systems.count == 1)
        try #require(document.systems[0].measures.count == 4)
        let gaps = Self.gapsPerMeasure(document).flatMap(\.self)
        try #require(gaps.count == 12)
        let spread = (gaps.max() ?? 0) - (gaps.min() ?? 0)
        #expect(spread < 0.5, "quarter gaps \(Self.gapsPerMeasure(document))")
    }

    /// Two long words on neighbouring quarters need more than the line can give an even quarter: their gap stays at
    /// the room they need, and every other quarter on the line — in their bar and the others — shares what is left.
    @Test("a gap held open by its syllables takes nothing until the others catch up")
    func heldGapTakesNoMore() throws {
        let document = Self.layout(Self.score([
            Self.plain, [nil, "Hallelujah", "everlasting", nil], Self.plain, Self.plain,
        ]))
        try #require(document.systems.count == 1)
        let perMeasure = Self.gapsPerMeasure(document)
        try #require(perMeasure.map(\.count) == [3, 3, 3, 3])
        let held = perMeasure[1][1]
        var others = perMeasure.flatMap(\.self)
        others.remove(at: 4)
        let spread = (others.max() ?? 0) - (others.min() ?? 0)
        #expect(spread < 0.5, "the other quarter gaps \(perMeasure)")
        #expect(held > (others.max() ?? 0) + 1, "the held gap \(held) must stay wider than the rest")
    }
}
