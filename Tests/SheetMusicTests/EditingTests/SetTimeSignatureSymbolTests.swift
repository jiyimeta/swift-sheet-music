@testable import SheetMusicCore
import Testing

/// `.setTimeSignature` carrying a `TimeSignatureSymbol` — the C / ¢ half of the meter intent.
///
/// Split from `SetTimeSignatureTests` because that suite is at the repository's type-body limit, not because
/// the symbol is a separate feature: it is written by the same intent, in the same undo step, and the
/// re-barring assertions there apply unchanged.
@Suite("Time signature symbols — intents")
struct SetTimeSignatureSymbolTests {
    /// Piano (two staves) + B♭ clarinet, 4 bars of 4/4, a whole-note C in every bar of every staff — the same
    /// shape `SetTimeSignatureTests.uniform44` builds, and for the same reason: a plain C keeps accidental
    /// renotation out of the way of a byte-for-byte undo comparison.
    private func uniform44() -> Score {
        var score = Score.blank(BlankScoreTemplate(
            title: "T",
            parts: [
                .init(instrumentID: "piano", longName: "Piano", staves: [.init(clefType: "G"), .init(clefType: "F")]),
                .init(
                    instrumentID: "clarinet-bb", longName: "Clarinet",
                    staves: [.init(clefType: "G")], transposeDiatonic: -1, transposeChromatic: -2,
                ),
            ],
            concertKey: 0, measureCount: 4,
        ))
        for (partIndex, part) in score.parts.enumerated() {
            for staffIndex in part.staves.indices {
                for measure in 0 ..< 4 {
                    let slot = measure == 0 ? 2 : 0
                    score.parts[partIndex].staves[staffIndex].measures[measure].voices[0].elements[slot] =
                        .chord(Chord(duration: .whole, notes: [Note(pitch: 72, tpc: 14)]))
                }
            }
        }
        return score
    }

    /// The time signature `measure` declares on `part`/`staff`, wherever in the bar it sits.
    private static func declared(_ score: Score, _ part: Int, _ staff: Int, _ measure: Int) -> TimeSignature? {
        for voice in score.parts[part].staves[staff].measures[measure].voices {
            for element in voice.elements {
                if case let .timeSignature(signature) = element { return signature }
            }
        }
        return nil
    }

    private static func measureCounts(_ score: Score) -> [Int] {
        score.parts.flatMap { $0.staves.map(\.measures.count) }
    }

    /// The symbol is written by the same intent that writes the meter, so placing a C over a bar already in 4/4
    /// is one edit and one undo step — not a no-op followed by a second command nobody has.
    @Test("a symbol is written by the meter intent, even when the meter itself does not move")
    func symbolIsWrittenWithTheMeter() {
        let score = uniform44()
        let session = ScoreEditSession(score: score)
        #expect(session.apply(
            .setTimeSignature(measureIndex: 0, numerator: 4, denominator: 4, symbol: .common),
        ))
        #expect(Self.declared(session.score, 0, 0, 0)?.symbol == .common)
        #expect(Self.declared(session.score, 0, 0, 0)?.numerator == 4)
        // The meter is unchanged, so the bars are too — only the glyph moved.
        #expect(Self.measureCounts(session.score) == Self.measureCounts(score))
        #expect(session.undo())
        #expect(session.score == score)
    }

    @Test("restating the same meter AND the same symbol is nothing to apply")
    func sameMeterAndSymbolPlansToNothing() {
        let score = uniform44()
        let session = ScoreEditSession(score: score)
        #expect(!session.apply(.setTimeSignature(measureIndex: 0, numerator: 4, denominator: 4)))
        #expect(session.lastRefusal?.reason == .nothingToApply)
        #expect(session.score == score)
        #expect(!session.canUndo)
    }

    /// A symbol stands for exactly one meter, so the pair is what is refused — not the numbers, which are
    /// perfectly writable on their own. A distinct reason from `.invalidTimeSignatureValue` because a host
    /// telling the user "4/4 is not a time signature" would be saying something false.
    @Test("a symbol over a meter it does not stand for is refused")
    func mismatchedSymbolRefused() {
        let cases: [(TimeSignatureSymbol, Int, Int)] = [
            (.common, 3, 4), (.cutCommon, 4, 4), (.cutBach, 6, 8), (.cutTriple, 3, 4),
        ]
        for (symbol, numerator, denominator) in cases {
            let score = uniform44()
            let session = ScoreEditSession(score: score)
            #expect(!session.apply(.setTimeSignature(
                measureIndex: 0, numerator: numerator, denominator: denominator, symbol: symbol,
            )))
            #expect(
                session.lastRefusal?.reason == .timeSignatureSymbolMismatch(
                    symbol: symbol, numerator: numerator, denominator: denominator,
                ),
            )
            #expect(session.lastRefusal?.code == "edit.timeSignatureSymbolMismatch")
            #expect(session.score == score)
            #expect(!session.canUndo)
        }
    }

    /// Cut time changes the bar length AND the glyph in one edit: the region re-bars to two halves per bar while
    /// the ¢ replaces the numbers. Proves the symbol does not reach `RebarPlanner`'s idea of how long a bar is.
    @Test("a symbol rides along with a real re-bar")
    func symbolSurvivesARebar() {
        let score = uniform44()
        let session = ScoreEditSession(score: score)
        #expect(session.apply(
            .setTimeSignature(measureIndex: 0, numerator: 2, denominator: 2, symbol: .cutCommon),
        ))
        let declared = Self.declared(session.score, 0, 0, 0)
        #expect(declared?.symbol == .cutCommon)
        #expect(declared?.numerator == 2)
        #expect(declared?.denominator == 2)
        // 4/4 and 2/2 are the same length, so the bars do not re-partition — the glyph is the whole change.
        #expect(Self.measureCounts(session.score) == Self.measureCounts(score))
        #expect(session.undo())
        #expect(session.score == score)
    }

    @Test("removing a symbol-drawn change reverts the span to the meter before it")
    func removingASymbolChange() {
        let score = uniform44()
        let session = ScoreEditSession(score: score)
        #expect(session.apply(
            .setTimeSignature(measureIndex: 2, numerator: 2, denominator: 2, symbol: .cutCommon),
        ))
        #expect(Self.declared(session.score, 0, 0, 2)?.symbol == .cutCommon)
        #expect(session.apply(.removeTimeSignature(measureIndex: 2)))
        #expect(Self.declared(session.score, 0, 0, 2) == nil)
        #expect(Self.declared(session.score, 0, 0, 0)?.symbol == .numeric)
    }
}
