@testable import SheetMusicCore
import Testing

/// `offset` and `autoplace` are deliberately not hashed. `offset` is named as excluded display trivia in
/// `ScoreFingerprintHasher`, and `placement` was kept out because preserved markup is not hashed and mixing it in
/// would invalidate every committed replay golden (`docs/musescore-model-parity.md` §7.2.3). These tests fail if
/// a later change mixes either field in.
@Suite("Element property fingerprint neutrality")
struct ElementPropertyFingerprintTests {
    private static let staff = StaffAddress(partIndex: 0, staffIndexInPart: 0)
    private static let chord = VoiceElementID(staff: staff, measureIndex: 0, voiceIndex: 0, elementIndex: 1)

    private static func withLyric() throws -> Score {
        var score = EditingFixtures.twoConsecutiveC4Chords()
        try SetLyric(at: chord, verse: 0, text: "la", syllabic: .single).apply(to: &score)
        return score
    }

    @Test("two scores differing only in offset hash the same")
    func offsetIsNotHashed() throws {
        let base = try Self.withLyric()
        var moved = base
        try SetTextOffset(.lyric(anchor: Self.chord, verse: 0), offset: ScoreOffset(x: 2, y: 3))
            .apply(to: &moved)
        #expect(moved.stableFingerprint == base.stableFingerprint)
    }

    @Test("two scores differing only in auto-place hash the same")
    func autoplaceIsNotHashed() throws {
        let base = try Self.withLyric()
        var pinned = base
        try SetTextAutoplace(.lyric(anchor: Self.chord, verse: 0), autoplace: false).apply(to: &pinned)
        #expect(pinned.stableFingerprint == base.stableFingerprint)
    }
}
