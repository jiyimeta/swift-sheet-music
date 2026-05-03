@testable import SheetMusicCore
import Testing

@Suite("SetLyrics")
struct SetLyricsTests {
    private static let chordID = VoiceElementID(
        staff: StaffAddress(partIndex: 0, staffIndexInPart: 0), measureIndex: 0,
        voiceIndex: 0, elementIndex: 1
    )

    @Test("apply replaces the chord's lyrics array")
    func applyReplaces() throws {
        var score = EditingFixtures.chordAtIndex1()
        let cmd = SetLyrics(
            at: Self.chordID,
            lyrics: [Lyric(text: "hello")]
        )
        _ = try cmd.apply(to: &score)
        guard case let .chord(chord) = score[Self.chordID] else {
            Issue.record("Expected chord at index 1")
            return
        }
        #expect(chord.lyrics.count == 1)
        #expect(chord.lyrics.first?.text == "hello")
    }

    @Test("inverse restores the prior lyrics")
    func inverseRestores() throws {
        var score = EditingFixtures.chordAtIndex1()
        // Pre-populate a lyric so the inverse has something to
        // restore.
        let prefill = SetLyrics(
            at: Self.chordID,
            lyrics: [Lyric(text: "old")]
        )
        _ = try prefill.apply(to: &score)
        let snapshot = score
        let cmd = SetLyrics(
            at: Self.chordID,
            lyrics: [Lyric(text: "new")]
        )
        let inverse = try cmd.apply(to: &score)
        _ = try inverse.apply(to: &score)
        #expect(score == snapshot)
    }

    @Test("apply clears lyrics when given an empty array")
    func applyClears() throws {
        var score = EditingFixtures.chordAtIndex1()
        let prefill = SetLyrics(
            at: Self.chordID,
            lyrics: [Lyric(text: "hi")]
        )
        _ = try prefill.apply(to: &score)
        let cmd = SetLyrics(at: Self.chordID, lyrics: [])
        _ = try cmd.apply(to: &score)
        guard case let .chord(chord) = score[Self.chordID] else {
            Issue.record("Expected chord")
            return
        }
        #expect(chord.lyrics.isEmpty)
    }

    @Test("apply throws when the target is not a chord")
    func applyOnRest() {
        var score = EditingFixtures.fourQuarterRests()
        let restID = VoiceElementID(
            staff: StaffAddress(partIndex: 0, staffIndexInPart: 0), measureIndex: 0,
            voiceIndex: 0, elementIndex: 2
        )
        let cmd = SetLyrics(at: restID, lyrics: [Lyric(text: "x")])
        #expect(throws: SheetMusicError.self) {
            _ = try cmd.apply(to: &score)
        }
    }
}
