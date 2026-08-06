@testable import SheetMusicCore
import Testing

@Suite("Score.stableFingerprint")
struct ScoreFingerprintTests {
    private static let restAt1 = RestID(
        staff: StaffAddress(partIndex: 0, staffIndexInPart: 0), measureIndex: 0, voiceIndex: 0, elementIndex: 1,
    )

    @Test("equal scores fingerprint equally")
    func equalScoresAgree() {
        let a = EditingFixtures.fourQuarterRests()
        let b = EditingFixtures.fourQuarterRests()
        #expect(a.stableFingerprint == b.stableFingerprint)
    }

    @Test("a written note changes the fingerprint")
    func editChangesFingerprint() throws {
        var score = EditingFixtures.fourQuarterRests()
        let before = score.stableFingerprint
        _ = try InputNote(at: Self.restAt1, pitch: 60, tpc: 14).apply(to: &score)
        #expect(score.stableFingerprint != before)
    }

    @Test("undoing an edit restores the fingerprint")
    func undoRestoresFingerprint() throws {
        var score = EditingFixtures.fourQuarterRests()
        let before = score.stableFingerprint
        let inverse = try InputNote(at: Self.restAt1, pitch: 60, tpc: 14).apply(to: &score)
        _ = try inverse.apply(to: &score)
        #expect(score.stableFingerprint == before)
    }

    @Test("pitch and spelling are both in the hash")
    func pitchAndSpellingCount() throws {
        var sharp = EditingFixtures.fourQuarterRests()
        var flat = EditingFixtures.fourQuarterRests()
        _ = try InputNote(at: Self.restAt1, pitch: 61, tpc: 21).apply(to: &sharp) // C#
        _ = try InputNote(at: Self.restAt1, pitch: 61, tpc: 9).apply(to: &flat) // Db
        #expect(sharp.stableFingerprint != flat.stableFingerprint)
    }

    @Test("the fingerprint is stable across repeated reads")
    func repeatedReadsAgree() {
        let score = EditingFixtures.fourQuarterRests()
        let first = score.stableFingerprint
        let second = score.stableFingerprint
        #expect(first == second)
    }
}
