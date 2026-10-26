@testable import SheetMusicCore
import Testing

/// The gate's own negative controls. Each test changes a groove by hand in one way a conversion must never change
/// it, and the gate has to record an issue (`withKnownIssue` fails the test when none is recorded) from the check
/// meant to catch it, which `RevoiceSoundGate.problems` names. A gate that passed everything would leave every
/// conversion test green.
@Suite("RevoiceSoundGate")
struct RevoiceSoundGateSelfTests {
    private static let staff = RevoiceFixtures.staff
    private static let fourFour = TimeSignature(numerator: 4, denominator: 4)
    /// Hi-hat and snare in voice 1, kicks in voice 2, and a crash tied over the bar line.
    private static let bar0 = ["H/4 H/4 H+S/4 C/4~", "K/4 r/4 K/4 r/4"]
    private static let bar1 = ["~C/4 H/4 H+S/4 H/4", "K/4 r/4 K/8 K/8 r/4"]

    /// The two-bar groove, with `marks` at the head of bar 0's voice `markVoice` (after the meter in voice 0).
    private static func groove(marks: [VoiceElement] = [], in markVoice: Int = 0) -> Score {
        let score = RevoiceFixtures.score([bar0, bar1])
        guard !marks.isEmpty else { return score }
        let leading: [VoiceElement] = markVoice == 0 ? [.timeSignature(fourFour)] + marks : marks
        return replacing(
            score, measure: 0, voice: markVoice, with: RevoiceFixtures.voice(bar0[markVoice], leading: leading),
        )
    }

    private static func replacing(_ score: Score, measure: Int, voice: Int, with replacement: Voice) -> Score {
        var result = score
        result.parts.updateValue(at: 0) { part in
            part.staves.updateValue(at: 0) { $0.measures[measure].voices[voice] = replacement }
        }
        return result
    }

    private static func accenting(_ score: Score, measure: Int, voice: Int, element: Int) -> Score {
        var result = score
        result.parts.updateValue(at: 0) { part in
            part.staves.updateValue(at: 0) { staffValue in
                staffValue.measures[measure].voices[voice].elements.updateValue(at: element) { slot in
                    guard case var .chord(chord) = slot else { return }
                    chord.articulations.append(ChordArticulation(kind: .accent))
                    slot = .chord(chord)
                }
            }
        }
        return result
    }

    @Test func `the gate passes a score compared with itself`() throws {
        let score = Self.groove(marks: [.dynamic(Dynamic(subtype: "f", velocity: 96))])
        try RevoiceSoundGate.expectKeepsSound(before: score, after: score, staff: Self.staff)
    }

    @Test func `a kick moved by an eighth is caught`() throws {
        let before = Self.groove()
        let after = Self.replacing(before, measure: 0, voice: 1, with: RevoiceFixtures.voice("r/8 K/8 r/4 K/4 r/4"))
        withKnownIssue { try RevoiceSoundGate.expectKeepsSound(before: before, after: after, staff: Self.staff) }
        let found = try RevoiceSoundGate.problems(before: before, after: after, staff: Self.staff)
        #expect(found.contains { $0.contains("note-on lost") })
        #expect(found.contains { $0.hasPrefix("hit lost") })
    }

    @Test func `a dynamic taken away is caught`() throws {
        let before = Self.groove(marks: [.dynamic(Dynamic(subtype: "f", velocity: 96))])
        let after = Self.groove()
        withKnownIssue { try RevoiceSoundGate.expectKeepsSound(before: before, after: after, staff: Self.staff) }
        let found = try RevoiceSoundGate.problems(before: before, after: after, staff: Self.staff)
        #expect(found.contains { $0.hasPrefix("annotation lost") })
    }

    /// Bar 0's `H+S` (element 3, after the meter) gains an accent while nothing merges into it, which D1 allows
    /// only on a merge.
    @Test func `an accent added without a merge is caught`() throws {
        let before = Self.groove()
        let after = Self.accenting(before, measure: 0, voice: 0, element: 3)
        withKnownIssue { try RevoiceSoundGate.expectKeepsSound(before: before, after: after, staff: Self.staff) }
        let found = try RevoiceSoundGate.problems(before: before, after: after, staff: Self.staff)
        #expect(found.contains { $0.contains("gained a velocity-shaping articulation without a merge") })
    }

    @Test func `a tied crash cut short is caught`() throws {
        let before = Self.groove()
        let after = Self.replacing(
            before, measure: 0, voice: 0,
            with: RevoiceFixtures.voice("H/4 H/4 H+S/4 C/8~ r/8", leading: [.timeSignature(Self.fourFour)]),
        )
        withKnownIssue { try RevoiceSoundGate.expectKeepsSound(before: before, after: after, staff: Self.staff) }
        let found = try RevoiceSoundGate.problems(before: before, after: after, staff: Self.staff)
        #expect(found.contains { $0.contains("audible length changed") })
    }

    /// A `currentVoiceOnly` dynamic governs only the voice it is written in (`HairpinRamps+Part.swift`), so
    /// moving it from voice 1 to voice 2 at the same tick changes which notes it plays on. Its bar and tick stay
    /// the same, so the annotation check cannot see it; the velocities in check 1 have to.
    @Test func `a voice-only dynamic that changes voice is caught`() throws {
        let pianissimo = VoiceElement.dynamic(
            Dynamic(subtype: "pp", velocity: 33, voiceAssignment: .currentVoiceOnly),
        )
        let before = Self.groove(marks: [pianissimo], in: 0)
        let after = Self.groove(marks: [pianissimo], in: 1)
        withKnownIssue { try RevoiceSoundGate.expectKeepsSound(before: before, after: after, staff: Self.staff) }
        let found = try RevoiceSoundGate.problems(before: before, after: after, staff: Self.staff)
        #expect(found.contains { $0.contains("note-on lost") })
        #expect(!found.contains { $0.hasPrefix("annotation") })
    }
}
