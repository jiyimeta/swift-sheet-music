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
        score(bars: [syllables], duration: duration)
    }

    /// One bar per entry of `bars`, each of `duration` chords with `bars[b][i]` under chord `i` (`nil` = none); a
    /// line break after each bar in `breaksAfter`.
    private static func score(bars: [[String?]], duration: NoteDuration, breaksAfter: Set<Int> = []) -> Score {
        let measures = bars.enumerated().map { barIndex, syllables in
            let chords = syllables.enumerated().map { index, syllable in
                VoiceElement.chord(Chord(
                    duration: duration, notes: ChordNotes([Note(pitch: 60 + index % 5, tpc: 14)]),
                    lyrics: syllable.map { [Lyric(text: $0)] } ?? [],
                ))
            }
            var measure = Measure(voices: [Voice(elements: chords)])
            measure.lineBreak = breaksAfter.contains(barIndex)
            return measure
        }
        let staff = Staff(measures: measures)
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
        document.systems.flatMap { syllableSpans(of: $0.measures, metrics: document.metrics) }
            .sorted { $0.left < $1.left }
    }

    /// `syllableSpans` per system, so a syllable is paired only with the ones on its own line.
    private static func syllableSpansBySystem(_ document: LayoutDocument) -> [[(left: CGFloat, right: CGFloat)]] {
        document.systems.map { system in
            syllableSpans(of: system.measures, metrics: document.metrics).sorted { $0.left < $1.left }
        }
    }

    private static func syllableSpans(
        of measures: [LayoutMeasure], metrics: StaffMetrics,
    ) -> [(left: CGFloat, right: CGFloat)] {
        measures.flatMap { measure in
            measure.elements.compactMap { element -> (left: CGFloat, right: CGFloat)? in
                guard case let .textMark(.lyrics, text, origin, _) = element else { return nil }
                let half = LayoutEngine.lyricsTextWidth(text, sp: metrics.sp) / 2
                let x = measure.origin.x + origin.x
                return (x - half, x + half)
            }
        }
    }

    /// The distance from bar `index`'s barline to its first column and from its last column to its barline.
    private static func barEdges(_ document: LayoutDocument, bar index: Int) throws -> (lead: CGFloat, tail: CGFloat) {
        let measure = try #require(document.systems.flatMap(\.measures).first { $0.measureIndex == index })
        let xs = measure.tickColumns.values
        return try (#require(xs.min()), measure.width - #require(xs.max()))
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

    // MARK: - Across a barline

    private static let longWords: [String?] = [
        "Hallelujah", "glory", "everlasting", "amen", "Hosanna", "in", "excelsis", "Deoeverlasting",
    ]

    /// The last syllable of a bar and the first of the next are a pair like any two in one bar. MuseScore spaces the
    /// line against every earlier segment, a barline no exception: a syllable may run across the barline
    /// (`HorizontalSpacing::doComputeKerningType`, barline → lyrics `ALLOW_COLLISION`) but not into the next
    /// syllable of its verse (`computeLyricsKerningType`, `NON_KERNING`). The walk used to stop at the bar's end.
    @Test("syllables either side of a barline keep clear of each other, stretched or not", arguments: [true, false])
    func syllablesClearAcrossBarlines(wrap: Bool) throws {
        let bars = [Self.longWords, Self.longWords.reversed(), Self.longWords, Self.longWords.reversed()]
        let document = Self.layout(Self.score(bars: bars, duration: .sixteenth), wrap: wrap)
        let systems = Self.syllableSpansBySystem(document)
        try #require(systems.joined().count == 32)
        let clearance = document.metrics.sp * 0.25
        for spans in systems {
            for (left, right) in zip(spans, spans.dropFirst()) {
                #expect(left.right + clearance <= right.left + 0.001, "\(left) runs into \(right)")
            }
        }
    }

    private static let barTail: [String?] = [nil, nil, nil, nil, nil, nil, nil, "everlasting"]
    private static let barHead: [String?] = ["Hallelujah", nil, nil, nil, nil, nil, nil, nil]
    private static let bareBar = [String?](repeating: nil, count: 8)

    /// MuseScore shares the room a collision asks for over the gaps after the earlier syllable's segment
    /// (`spaceAgainstPreviousSegments` moves every segment after it, the barline among them), so it lands in the
    /// first bar, before the barline, and the next bar keeps its usual distance from the barline to its first note.
    @Test("the room two syllables need across a barline goes before it")
    func roomGoesBeforeTheBarline() throws {
        let joined = Self.layout(Self.score(bars: [Self.barTail, Self.barHead], duration: .sixteenth), wrap: false)
        let alone = Self.layout(Self.score(bars: [Self.barTail, Self.bareBar], duration: .sixteenth), wrap: false)
        let joinedFirst = try Self.barEdges(joined, bar: 0)
        let aloneFirst = try Self.barEdges(alone, bar: 0)
        #expect(joinedFirst.tail > aloneFirst.tail + joined.metrics.sp, "the first bar \(joinedFirst) vs \(aloneFirst)")
        let joinedSecond = try Self.barEdges(joined, bar: 1)
        let aloneSecond = try Self.barEdges(alone, bar: 1)
        #expect(abs(joinedSecond.lead - aloneSecond.lead) < 0.001, "the second bar \(joinedSecond) vs \(aloneSecond)")
        let spans = Self.syllableSpans(joined)
        try #require(spans.count == 2)
        #expect(spans[0].right + joined.metrics.sp * 0.25 <= spans[1].left + 0.001, "\(spans)")
    }

    /// The first syllable of the next line is not beside the last of this one, so the bar that ends the line keeps
    /// the tail its own notes give it. The line is laid out at its least width, where a floor would bind.
    @Test("a bar that ends a line makes no room for the next line's first syllable")
    func lineEndMakesNoRoom() throws {
        let options = ScoreViewOptions(staffSize: 28, wrapToViewWidth: true)
        let width = LayoutEngine.naturalContentWidth(
            score: Self.score(bars: [Self.barTail], duration: .sixteenth), options: options,
        )
        func lineEnd(before next: [String?]) throws -> (lead: CGFloat, tail: CGFloat) {
            let score = Self.score(bars: [Self.barTail, next], duration: .sixteenth, breaksAfter: [0])
            let document = LayoutEngine.layout(score: score, options: options, availableWidth: width)
            try #require(document.systems.count == 2)
            return try Self.barEdges(document, bar: 0)
        }
        let beforeSyllable = try lineEnd(before: Self.barHead)
        let beforeBare = try lineEnd(before: Self.bareBar)
        #expect(abs(beforeSyllable.tail - beforeBare.tail) < 0.001, "\(beforeSyllable) vs \(beforeBare)")
    }
}
