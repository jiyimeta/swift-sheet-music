@testable import SheetMusicCore
import Testing

/// How long a bar plays (design 2026-10-26, drum voice conversion, §5): the renderer measures each bar by its first
/// voice — its written lengths and its breaths' pauses (`MidiRenderer.measureTicks`) — and places every later bar from
/// that. A conversion that would change that length, by moving a pause into the first voice or by rewriting a first
/// voice that does not fill its bar, leaves the bar as written, and the rest of the staff still converts.
@Suite("RevoiceDrumStaff bar lengths")
struct RevoiceBarLengthTests {
    private static let filled = ["H/4 H/4 H/4 H/4", "K/4 r/4 r/2"]

    private static func preview(_ score: Score, to map: [Int: Int]) -> RevoicePreview {
        RevoiceDrumStaff(staff: RevoiceFixtures.staff, voiceForPitch: map, policy: .default).preview(in: score)
    }

    /// Both caesuras end their bar in voice 2: bar 0's, whose kick merges into voice 1, and bar 1's, in a rest-only
    /// voice 2 that one voice removes. Either would end voice 1 instead, lengthening its bar by the pause and delaying
    /// every bar after it. Bar 2 converts.
    @Test func `a pause moving into the first voice leaves its bar`() throws {
        let caesura = Breath(kind: .caesura(.normal), pause: 0.5)
        var score = RevoiceFixtures.score([Self.filled, ["H/4 H/4 H/4 H/4", "r/m"], Self.filled])
        score = RevoiceFixtures.inserting(.breath(caesura), into: score, voice: 1, at: 3)
        score = RevoiceFixtures.inserting(.breath(caesura), into: score, measure: 1, voice: 1, at: 1)
        #expect(Self.preview(score, to: RevoiceFixtures.oneVoice)
            == RevoicePreview(rewrittenMeasures: [2], measuresLeftAsWritten: [0, 1]))
        for measure in 0 ..< 2 {
            #expect(RevoiceFixtures.barPlan(score, measure: measure, to: RevoiceFixtures.oneVoice)
                == .leftAsWritten(.unsupported))
        }
        let (after, _) = try RevoiceFixtures.converted(score, to: RevoiceFixtures.oneVoice)
        #expect(RevoiceFixtures.voices(after, measure: 2) == ["H+K/4 H/4 H/4 H/4"])
        try RevoiceSoundGate.expectKeepsSound(before: score, after: after, staff: RevoiceFixtures.staff)
    }

    /// Bar 0's first voice holds three quarters of a 4/4 bar, so the bar plays three beats long; written afresh it
    /// would fill the bar and every later bar would start a beat later. Bar 1 would only lose a rest-only voice, and
    /// is left too. Bar 2 converts.
    @Test func `an underfull first voice leaves its bar`() throws {
        let score = RevoiceFixtures.score([["H/4 H/4 H/4", "K/4 r/4 r/2"], ["H/4 H/4 H/4", "r/m"], Self.filled])
        #expect(Self.preview(score, to: RevoiceFixtures.oneVoice)
            == RevoicePreview(rewrittenMeasures: [2], measuresLeftAsWritten: [0, 1]))
        for measure in 0 ..< 2 {
            #expect(RevoiceFixtures.barPlan(score, measure: measure, to: RevoiceFixtures.oneVoice)
                == .leftAsWritten(.unsupported))
        }
        let (after, _) = try RevoiceFixtures.converted(score, to: RevoiceFixtures.oneVoice)
        #expect(after.parts[0].staves[0].measures[0].voices == score.parts[0].staves[0].measures[0].voices)
        #expect(RevoiceFixtures.voices(after, measure: 2) == ["H+K/4 H/4 H/4 H/4"])
        try RevoiceSoundGate.expectKeepsSound(before: score, after: after, staff: RevoiceFixtures.staff)
    }
}
