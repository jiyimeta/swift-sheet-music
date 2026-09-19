@testable import SheetMusicCore
import Testing

/// A tuplet asked for on a bar that holds only a measure rest.
///
/// Reported 2026-09-20, with a crash log: ⌘3 on such a bar killed the app in
/// `NoteDuration.ticks(division:)`, which traps on `.measure` by design — its own doc says to resolve the duration
/// against the bar first, and `CreateTuplet` was the one place in the file that did not.
@Suite("CreateTuplet over a measure rest")
struct CreateTupletMeasureRestTests {
    private static let staff = StaffAddress(partIndex: 0, staffIndexInPart: 0)

    private static func emptyBar(numerator: Int = 4, denominator: Int = 4) -> Score {
        Score(
            division: 480,
            parts: [Part(
                id: "1",
                instrument: Instrument(id: "x"),
                staves: [Staff(measures: [Measure(voices: [Voice(elements: [
                    .timeSignature(TimeSignature(numerator: numerator, denominator: denominator)),
                    .rest(duration: .measure),
                ])])])],
            )],
        )
    }

    private static func slot(_ element: Int) -> VoiceElementID {
        VoiceElementID(staff: staff, measureIndex: 0, voiceIndex: 0, elementIndex: element)
    }

    @Test("a triplet over a whole-bar rest is written rather than trapping")
    func tripletOverMeasureRest() throws {
        let session = ScoreEditSession(score: Self.emptyBar())
        #expect(session.apply(.createTuplet(at: Self.slot(1), actualNotes: 3, normalNotes: 2)))

        let voice = try #require(session.score[Self.staff]?.measures[0].voices[0])
        let span = try #require(voice.tupletSpans.first)
        #expect(span.actualNotes == 3)
        // A 4/4 bar is 1920 ticks, so each member is a third of it.
        let members = (span.startIndex ... span.endIndex).compactMap { index -> Fraction? in
            guard case let .chord(chord) = voice.elements[index] else { return nil }
            return chord.duration.asFraction
        }
        #expect(members == Array(repeating: Fraction(numerator: 1, denominator: 3), count: 3))
    }

    @Test("a bar whose length does not divide is refused, not trapped")
    func indivisibleBarIsRefused() {
        // 3/4 is 1440 ticks; a quintuplet over it does not divide evenly.
        let session = ScoreEditSession(score: Self.emptyBar(numerator: 3, denominator: 4))
        #expect(!session.apply(.createTuplet(at: Self.slot(1), actualNotes: 7, normalNotes: 4)))
    }
}
