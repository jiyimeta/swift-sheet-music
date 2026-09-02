@testable import SheetMusicCore
import SheetMusicMSCX
import Testing

/// Pins the convention every tick walker in this package relies on: a tuplet member's stored `NoteDuration` is its
/// SOUNDING length (`CreateTuplet` writes `original / actualNotes`; `MSCXDecoder+Voice` scales by the ratio stack
/// on read), so summing stored durations IS the sounding onset and no walker needs the tuplet ratio. Group 2's
/// range engine re-resolves targets by these onsets; this is what makes that safe after a tuplet.
@Suite("Tuplet onsets are sounding ticks")
struct TupletOnsetTests {
    private static let staff0 = StaffAddress(partIndex: 0, staffIndexInPart: 0)

    private static func slot(_ element: Int) -> VoiceElementID {
        VoiceElementID(staff: staff0, measureIndex: 0, voiceIndex: 0, elementIndex: element)
    }

    /// `[ts, r q, r q, r q, r q]` with element 1 turned into a triplet: `[ts, r 1/12, r 1/12, r 1/12, r q, r q, r q]`.
    private static func tripletScore() throws -> Score {
        var score = EditingFixtures.fourQuarterRests()
        _ = try CreateTuplet(at: slot(1), actualNotes: 3, normalNotes: 2).apply(to: &score)
        return score
    }

    @Test("the element after a triplet starts where the quarter it replaced ended")
    func onsetAfterTupletIsUnscaled() throws {
        let score = try Self.tripletScore()
        #expect(score.onset(of: Self.slot(4)) == ScoreTickPosition(measure: 0, tick: 480))
        #expect(score.onset(of: Self.slot(2)) == ScoreTickPosition(measure: 0, tick: 160))
        #expect(DurationChangeAlgorithm.tickOffset(
            in: score.parts[0].staves[0].measures[0].voices[0], ofElementAt: 4, division: 480,
        ) == 480)
    }

    @Test("the MSCX decoder stores the same sounding lengths CreateTuplet writes")
    func decoderAgreesWithCreateTuplet() throws {
        let written = try Self.tripletScore()
        let read = try MSCXParser.parse(MSCXEncoder.encode(written))
        let voice = read.parts[0].staves[0].measures[0].voices[0]
        #expect(voice.tuplets == [Tuplet(normalNotes: 2, actualNotes: 3, startIndex: 1, endIndex: 3)])
        #expect(read.onset(of: Self.slot(4)) == written.onset(of: Self.slot(4)))
        #expect(voice.elements[1].tickCount(division: 480) == 160)
    }

    @Test("a range whose start follows a tuplet resolves to the elements after it, not one third early")
    func rangeAfterTupletResolves() throws {
        let score = try Self.tripletScore()
        let range = VoiceElementRange(start: Self.slot(4), end: Self.slot(6))
        #expect(score.voiceElements(in: range) == [Self.slot(4), Self.slot(5), Self.slot(6)])
    }
}
