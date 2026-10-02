import Foundation
@testable import SheetMusicCore
import SheetMusicMSCX
import Testing

/// A note typed into an empty bar is spelled the way the file it is saved to reads it back.
///
/// `InputNote` on a `.measure` rest takes the rest's resolved length. That used to be `.fraction(1/1)` in 4/4, which
/// the encoder writes as `<durationType>whole</durationType>` and the decoder reads as `.whole` — so the edited score
/// was not a fixed point of encode → parse under `==` or under `stableFingerprint`, and a host that rebuilds its
/// copy by saving and loading (folino's Android editor, on every bar-level merge) saw a divergence that was not one.
@Suite("Bar-length note spelling")
struct BarLengthNoteSpellingTests {
    private static let staff = StaffAddress(partIndex: 0, staffIndexInPart: 0)
    private static let emptyBarRest = RestID(staff: staff, measureIndex: 0, voiceIndex: 0, elementIndex: 1)

    private static func emptyBar(_ numerator: Int, _ denominator: Int) -> Score {
        let voice = Voice(elements: [
            .timeSignature(TimeSignature(numerator: numerator, denominator: denominator)),
            .rest(duration: .measure),
        ])
        return Score(division: 480, parts: [Part(
            id: "1", instrument: Instrument(id: "piano"),
            staves: [Staff(measures: [Measure(voices: [voice])])],
        )])
    }

    @Test(
        "a note typed into an empty bar survives encode → parse unchanged",
        arguments: [(4, 4), (2, 4), (2, 2), (3, 4), (1, 4), (6, 8)],
    )
    func typedBarLengthNoteIsAFixedPoint(signature: (Int, Int)) throws {
        let session = ScoreEditSession(score: Self.emptyBar(signature.0, signature.1))
        #expect(session.apply(.inputNote(at: Self.emptyBarRest, pitch: 60, tpc: 14, duration: nil)))
        let edited = session.score

        let reparsed = try MSCXParser.parse(MSCXEncoder.encode(edited))

        let slot = VoiceElementID(Self.emptyBarRest)
        guard case let .chord(written)? = edited[slot], case let .chord(read)? = reparsed[slot] else {
            Issue.record("expected a chord in the bar both before and after the round trip")
            return
        }
        #expect(written.duration == read.duration)
        #expect(edited.stableFingerprint == reparsed.stableFingerprint)
    }

    @Test("an undotted bar length resolves to its named case, anything else to a fraction")
    func canonicalSpelling() {
        #expect(NoteDuration.measure.resolved(in: Fraction(numerator: 1, denominator: 1)) == .whole)
        #expect(NoteDuration.measure.resolved(in: Fraction(numerator: 2, denominator: 4)) == .half)
        #expect(NoteDuration.measure.resolved(in: Fraction(numerator: 1, denominator: 4)) == .quarter)
        #expect(
            NoteDuration.measure.resolved(in: Fraction(numerator: 3, denominator: 4))
                == .fraction(Fraction(numerator: 3, denominator: 4)),
        )
        #expect(
            NoteDuration.measure.resolved(in: Fraction(numerator: 5, denominator: 4))
                == .fraction(Fraction(numerator: 5, denominator: 4)),
        )
        #expect(NoteDuration.quarter.resolved(in: Fraction(numerator: 1, denominator: 1)) == .quarter)
    }
}
