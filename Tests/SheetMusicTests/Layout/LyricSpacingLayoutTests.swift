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

/// A syllable is room its notes must keep, not weight they carry: MuseScore spaces a bar by its durations and lets a
/// syllable widen a gap only where it would otherwise run into the next one (`ChordLayout::chordRestShape` puts the
/// lyric in the segment's shape, and `HorizontalSpacing::computeLyricsPadding` pads it against the next).
///
/// Reported 2026-10-17: bar 65 of a choral score, eight eighths under "ん じゅ じゃ な い の よ", stood
/// 1.50 / 3.30 / 4.31 / 3.30 / 2.28 / 2.28 / 2.28 sp apart times one factor however wide the line was, where
/// MuseScore spaces the bar evenly — the syllables were weight, and weight stretches with the line.
@Suite("Lyric spacing in layout")
struct LyricSpacingLayoutTests {
    private let _installFontMetrics = TestSupport.installFontMetrics

    /// One bar of `duration` chords, `syllables[i]` under chord `i` (`nil` = none).
    private static func score(_ syllables: [String?], duration: NoteDuration = .eighth) -> Score {
        let chords = syllables.enumerated().map { index, syllable in
            VoiceElement.chord(Chord(
                duration: duration, notes: ChordNotes([Note(pitch: 60 + index % 5, tpc: 14)]),
                lyrics: syllable.map { [Lyric(text: $0)] } ?? [],
            ))
        }
        let staff = Staff(measures: [Measure(voices: [Voice(elements: chords)])])
        return Score(division: 480, parts: [Part(id: "1", instrument: Instrument(id: "voice"), staves: [staff])])
    }

    private static func layout(_ score: Score, wrap: Bool) -> LayoutDocument {
        let options = ScoreViewOptions(staffSize: 28, wrapToViewWidth: wrap)
        let width = wrap ? 900 : LayoutEngine.naturalContentWidth(score: score, options: options)
        return LayoutEngine.layout(score: score, options: options, availableWidth: width)
    }

    /// The x of every chord, left to right.
    private static func chordXs(_ document: LayoutDocument) -> [CGFloat] {
        document.systems.flatMap(\.measures).flatMap { measure in
            measure.elements.compactMap { element -> CGFloat? in
                guard case let .chord(notes, _, _, _, _, _, _, _, _, _, _) = element else { return nil }
                return notes.first.map { measure.origin.x + $0.origin.x }
            }
        }.sorted()
    }

    /// Every syllable's left and right edge, left to right, measured the way spacing measures it.
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

    private static func gaps(_ xs: [CGFloat]) -> [CGFloat] {
        zip(xs.dropFirst(), xs).map { $0 - $1 }
    }

    /// **The report.** Stretched across the line there is room to spare for every pair of syllables, so the bar
    /// stays as even as its durations.
    @Test("syllables of different widths leave a stretched bar of equal notes evenly spaced")
    func stretchedBarStaysEven() throws {
        let document = Self.layout(Self.score([nil, "ん", "じゅ", "じゃ", "な", "い", "の", "よ"]), wrap: true)
        let xs = Self.chordXs(document)
        try #require(xs.count == 8)
        let gaps = Self.gaps(xs)
        let spread = (gaps.max() ?? 0) - (gaps.min() ?? 0)
        #expect(spread < 0.5, "note gaps \(gaps)")
    }

    /// Long syllables on a dense bar of sixteenths, where every pair needs more than the notes' own room: the bar
    /// must give way, at its natural width as much as stretched.
    @Test(
        "syllables wider than their notes' room still keep clear of each other, stretched or not",
        arguments: [true, false],
    )
    func wideSyllablesStayApart(wrap: Bool) throws {
        let words = ["Hallelujah", "glory", "everlasting", "amen", "Hosanna", "in", "excelsis", "Deo"]
        let document = Self.layout(Self.score(words + words, duration: .sixteenth), wrap: wrap)
        let spans = Self.syllableSpans(document)
        try #require(spans.count == 16)
        let clearance = document.metrics.sp * 0.25
        for (left, right) in zip(spans, spans.dropFirst()) {
            #expect(left.right + clearance <= right.left + 0.001, "\(left) runs into \(right)")
        }
    }

    /// A syllable only has to clear the NEXT syllable. Two long words three notes apart, at natural width where they
    /// bind: the room they need is shared by the three gaps between them, not torn open beside one note.
    @Test("a syllable's room is shared by the gaps up to the next syllable")
    func roomIsSharedToTheNextSyllable() throws {
        let document = Self.layout(
            Self.score(["Hallelujah", nil, nil, "everlasting", nil, nil, nil, nil], duration: .sixteenth), wrap: false,
        )
        let xs = Self.chordXs(document)
        try #require(xs.count == 8)
        let shared = Array(Self.gaps(xs)[0 ..< 3])
        #expect((shared.max() ?? 0) - (shared.min() ?? 0) < 0.001, "gaps to the next syllable \(shared)")
        let spans = Self.syllableSpans(document)
        try #require(spans.count == 2)
        #expect(spans[0].right + document.metrics.sp * 0.25 <= spans[1].left + 0.001)
    }
}
