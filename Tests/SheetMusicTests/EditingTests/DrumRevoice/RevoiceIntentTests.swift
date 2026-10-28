@testable import SheetMusicCore
import Testing

/// `EditIntent.revoiceDrumStaff` through a session (design 2026-10-26, drum voice conversion, §3): one undo step, and
/// nothing to apply once the staff is in the form asked for.
@Suite("RevoiceDrumStaff intent")
struct RevoiceIntentTests {
    private static let handsAndFeet: [DrumVoiceAssignment] = [
        .init(pitch: 35, voiceIndex: 1), .init(pitch: 36, voiceIndex: 1), .init(pitch: 44, voiceIndex: 1),
    ]

    private static func voiceCount(_ score: Score) -> Int {
        score.parts[0].staves[0].measures[0].voices.count
    }

    @Test func `the intent converts the staff in one undo step`() {
        let session = ScoreEditSession(score: RevoiceFixtures.score([["H+K/4 H/4 H+S/4 H/4", "r/m"]]))
        let original = session.score
        #expect(Self.voiceCount(original) == 2)
        #expect(session.apply(.revoiceDrumStaff(staff: RevoiceFixtures.staff, assignments: [], policy: .default)))
        let converted = session.score
        #expect(Self.voiceCount(converted) == 1)
        #expect(session.undo())
        #expect(session.score == original)
        #expect(session.redo())
        #expect(session.score == converted)
    }

    @Test func `the intent on a converted staff is nothing to apply`() {
        let session = ScoreEditSession(score: RevoiceFixtures.score([["H+K/4 H/4 H+S/4 H/4"]]))
        #expect(!session.apply(.revoiceDrumStaff(staff: RevoiceFixtures.staff, assignments: [], policy: .default)))
        #expect(session.lastRefusal?.reason == .nothingToApply)
    }

    @Test func `a later assignment for one pitch wins`() {
        let session = ScoreEditSession(score: RevoiceFixtures.score([["H/4 H/4 H/4 H/4", "K/4 r/4 K/4 r/4"]]))
        // Kick sent to voice 2 and then back to voice 1: the last word leaves the staff in one voice.
        let assignments = Self.handsAndFeet + [.init(pitch: 36, voiceIndex: 0), .init(pitch: 44, voiceIndex: 0)]
        #expect(session.apply(
            .revoiceDrumStaff(staff: RevoiceFixtures.staff, assignments: assignments, policy: .default),
        ))
        #expect(Self.voiceCount(session.score) == 1)
    }

    @Test func `hands and feet moves the kicks to voice 2`() {
        let session = ScoreEditSession(score: RevoiceFixtures.score([["H+K/4 H/4 H+S/4 H/4"]]))
        #expect(session.apply(
            .revoiceDrumStaff(staff: RevoiceFixtures.staff, assignments: Self.handsAndFeet, policy: .default),
        ))
        #expect(Self.voiceCount(session.score) == 2)
    }
}
