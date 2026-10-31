import Foundation
@testable import SheetMusicCore
import Testing

struct LyricPlacementMetricTests {
    /// A lyric placement: measure, chord slot in that measure, verse and text.
    private struct Put {
        var measure: Int
        var chord: Int
        var text: String
        var verse = 0
    }

    /// Two measures of four one-note chords in one voice, with `puts` attached as lyrics.
    private func score(_ puts: [Put]) -> Score {
        let measures = (0 ..< 2).map { mi -> Measure in
            let elements = (0 ..< 4).map { ci -> VoiceElement in
                let lyrics = puts.filter { $0.measure == mi && $0.chord == ci }
                    .map { Lyric(text: $0.text, verse: $0.verse) }
                return .chord(Chord(duration: .quarter, notes: [Note(pitch: 60, tpc: 14)], lyrics: lyrics))
            }
            return Measure(voices: [Voice(elements: elements)])
        }
        return Score(
            division: 480,
            parts: [Part(id: "p", instrument: Instrument(id: "i"), staves: [Staff(measures: measures)])],
        )
    }

    private func place(_ a: [Put], _ b: [Put]) -> LyricPlacementResult {
        ScoreSemanticMetrics.lyricPlacement(scoreA: score(a), scoreB: score(b))
    }

    @Test func identicalLyricsAreAllOnTheirNotes() {
        let puts = [
            Put(measure: 0, chord: 0, text: "いき"),
            Put(measure: 0, chord: 1, text: "て"),
            Put(measure: 1, chord: 0, text: "あ"),
            Put(measure: 1, chord: 2, text: "さひ"),
        ]
        let r = place(puts, puts)
        #expect(r.total == LyricPlacementCounts(truthChars: 6, on: 6))
    }

    @Test func aBoundaryShiftedByOneNoteIsOneOff() {
        let a = [Put(measure: 0, chord: 0, text: "al"), Put(measure: 0, chord: 1, text: "most")]
        let b = [Put(measure: 0, chord: 0, text: "alm"), Put(measure: 0, chord: 1, text: "ost")]
        let r = place(a, b)
        #expect(r.total.on == 5)
        #expect(r.total.oneOff == 1)
        #expect(r.total.far == 0 && r.total.missing == 0 && r.total.extra == 0 && r.total.edits == 0)
    }

    @Test func aSyllableInAnotherMeasureIsFar() {
        let a = [
            Put(measure: 0, chord: 0, text: "い"),
            Put(measure: 0, chord: 1, text: "き"),
            Put(measure: 0, chord: 2, text: "て"),
            Put(measure: 0, chord: 3, text: "た"),
        ]
        let b = [
            Put(measure: 0, chord: 0, text: "い"),
            Put(measure: 0, chord: 1, text: "き"),
            Put(measure: 0, chord: 2, text: "て"),
            Put(measure: 1, chord: 2, text: "た"),
        ]
        let r = place(a, b)
        #expect(r.total.truthChars == 4)
        #expect(r.total.on == 3)
        #expect(r.total.far == 1)
        #expect(r.total.edits == 0)
    }

    @Test func missingAndExtraAreCountedApart() {
        let a = [
            Put(measure: 0, chord: 0, text: "あ"),
            Put(measure: 0, chord: 1, text: "い"),
            Put(measure: 0, chord: 2, text: "う"),
        ]
        let b = [
            Put(measure: 0, chord: 1, text: "い"),
            Put(measure: 0, chord: 2, text: "う"),
            Put(measure: 0, chord: 3, text: "x"),
        ]
        let r = place(a, b)
        #expect(r.total.missing == 1)
        #expect(r.total.extra == 1)
        #expect(r.total.on == 2)
        #expect(r.total.edits == 2)
        #expect(r.latin.extra == 1)
        #expect(r.kanaKanji.missing == 1)
    }

    @Test func aMisreadCharacterIsPlacedButEdited() {
        let a = [
            Put(measure: 0, chord: 0, text: "い"),
            Put(measure: 0, chord: 1, text: "き"),
            Put(measure: 0, chord: 2, text: "て"),
        ]
        let b = [
            Put(measure: 0, chord: 0, text: "い"),
            Put(measure: 0, chord: 1, text: "ぎ"),
            Put(measure: 0, chord: 2, text: "て"),
        ]
        let r = place(a, b)
        #expect(r.total.on == 3)
        #expect(r.total.edits == 1)
        #expect(r.total.missing == 0 && r.total.extra == 0)
    }

    @Test func countsAreSplitByScript() {
        let puts = [
            Put(measure: 0, chord: 0, text: "Good"),
            Put(measure: 0, chord: 1, text: "あ"),
            Put(measure: 0, chord: 2, text: "さ"),
        ]
        let r = place(puts, puts)
        #expect(r.latin.truthChars == 4)
        #expect(r.kanaKanji.truthChars == 2)
        #expect(r.total.truthChars == 6)
        #expect(r.latin.on == 4 && r.kanaKanji.on == 2)
        #expect(ScoreSemanticMetrics.lyricScript("1") == .other)
        #expect(ScoreSemanticMetrics.lyricScript("漢") == .kanaKanji)
    }

    @Test func versesAreScoredSeparately() {
        // Merged into one stream these would be identical (all on); per verse each is a one-off substitution.
        let a = [Put(measure: 0, chord: 0, text: "あ", verse: 0), Put(measure: 0, chord: 1, text: "い", verse: 1)]
        let b = [Put(measure: 0, chord: 1, text: "い", verse: 0), Put(measure: 0, chord: 0, text: "あ", verse: 1)]
        let r = place(a, b)
        #expect(r.total == LyricPlacementCounts(truthChars: 2, oneOff: 2, edits: 2))
    }

    @Test func aVerseOnlyInTheTruthIsAllMissing() {
        let a = [Put(measure: 0, chord: 0, text: "あ", verse: 1), Put(measure: 0, chord: 1, text: "い", verse: 1)]
        let r = place(a, [])
        #expect(r.total == LyricPlacementCounts(truthChars: 2, missing: 2, edits: 2))
    }

    @Test func aVerseOnlyInTheReadIsAllExtra() {
        let b = [Put(measure: 0, chord: 0, text: "x", verse: 1), Put(measure: 0, chord: 1, text: "y", verse: 1)]
        let r = place([], b)
        #expect(r.total == LyricPlacementCounts(extra: 2, edits: 2))
        #expect(r.latin.extra == 2)
    }

    @Test func aDroppedLastSyllableDoesNotShiftTheOthers() {
        let a = (0 ..< 4).map { Put(measure: 0, chord: $0, text: "あ") }
        let b = (0 ..< 3).map { Put(measure: 0, chord: $0, text: "あ") }
        let r = place(a, b)
        #expect(r.total == LyricPlacementCounts(truthChars: 4, on: 3, missing: 1, edits: 1))
    }

    @Test func aDroppedFirstSyllableDoesNotShiftTheOthers() {
        let a = (0 ..< 4).map { Put(measure: 0, chord: $0, text: "ら") }
        let b = (1 ..< 4).map { Put(measure: 0, chord: $0, text: "ら") }
        let r = place(a, b)
        #expect(r.total == LyricPlacementCounts(truthChars: 4, on: 3, missing: 1, edits: 1))
    }

    @Test func titleTextReadsTheTitleFrame() {
        let frame = ScoreFrame(heightSp: 10, texts: [
            FrameText(style: .composer, text: "X"),
            FrameText(style: .title, text: "  曲名 "),
        ])
        #expect(ScoreSemanticMetrics.titleText(Score(division: 480, parts: [], titleFrame: frame)) == "曲名")
        #expect(ScoreSemanticMetrics.titleText(Score(division: 480, parts: [])) == nil)
    }

    @Test func firstTempoBPMRoundsBeatsPerSecond() {
        let withTempo = Score(
            division: 480, parts: [],
            systemMeasures: [SystemMeasure(elements: [
                PositionedSystemElement(position: .start, element: .tempo(Tempo(beatsPerSecond: 1.05))),
            ])],
        )
        #expect(ScoreSemanticMetrics.firstTempoBPM(withTempo) == 63)
        #expect(ScoreSemanticMetrics.firstTempoBPM(Score(division: 480, parts: [])) == nil)
    }
}
