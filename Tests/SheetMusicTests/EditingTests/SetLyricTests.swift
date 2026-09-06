@testable import SheetMusicCore
import Testing

@Suite("SetLyric")
struct SetLyricTests {
    private static let chordID = VoiceElementID(
        staff: EditingFixtures.staff0,
        measureIndex: 0,
        voiceIndex: 0,
        elementIndex: 1,
    )

    @Test("writing verse 2 pads lower verses and undo restores the empty array")
    func writingVerseTwoPadsAndRoundTrips() throws {
        var score = EditingFixtures.chordAtIndex1()
        let before = Self.lyrics(in: score)

        let inverse = try SetLyric(
            at: Self.chordID,
            verse: 2,
            text: "  amen  ",
        ).apply(to: &score)

        let lyrics = Self.lyrics(in: score)
        #expect(lyrics.count == 3)
        #expect(lyrics[0] == Lyric(text: "", verse: 0))
        #expect(lyrics[1] == Lyric(text: "", verse: 1))
        #expect(lyrics[2].text == "amen")
        #expect(lyrics[2].verse == 2)

        _ = try inverse.apply(to: &score)
        #expect(Self.lyrics(in: score) == before)
    }

    @Test("writing the same verse twice replaces instead of appending and undo restores the first value")
    func writingTwiceReplacesAndRoundTrips() throws {
        var score = EditingFixtures.chordAtIndex1()
        _ = try SetLyric(at: Self.chordID, verse: 0, text: "first").apply(to: &score)
        let beforeSecondWrite = Self.lyrics(in: score)

        let inverse = try SetLyric(at: Self.chordID, verse: 0, text: "second")
            .apply(to: &score)

        #expect(Self.lyrics(in: score).map(\.text) == ["second"])
        _ = try inverse.apply(to: &score)
        #expect(Self.lyrics(in: score) == beforeSecondWrite)
    }

    @Test("missing, rest, negative verse, and whitespace-only writes have distinct refusals")
    func refusals() {
        var score = EditingFixtures.chordAtIndex1()
        let restID = Self.chordID.withElementIndex(2)
        let missingID = Self.chordID.withElementIndex(99)
        let before = score

        let missing = #expect(throws: SheetMusicError.self) {
            _ = try SetLyric(at: missingID, verse: 0, text: "la").apply(to: &score)
        }
        #expect(Self.reason(of: missing) == .targetNotFound(missingID))

        let rest = #expect(throws: SheetMusicError.self) {
            _ = try SetLyric(at: restID, verse: 0, text: "la").apply(to: &score)
        }
        #expect(Self.reason(of: rest) == .wrongElementKind(at: restID, expected: .chord))

        let negative = #expect(throws: SheetMusicError.self) {
            _ = try SetLyric(at: Self.chordID, verse: -1, text: "la").apply(to: &score)
        }
        #expect(Self.reason(of: negative) == .invalidVerse(-1))

        let empty = #expect(throws: SheetMusicError.self) {
            _ = try SetLyric(at: Self.chordID, verse: 0, text: " \n ").apply(to: &score)
        }
        #expect(Self.reason(of: empty) == .emptyLyricText)
        #expect(score == before)
    }

    @Test("removing the only verse trims the array and undo restores it")
    func removingOnlyVerseRoundTrips() throws {
        var score = EditingFixtures.chordAtIndex1()
        _ = try SetLyric(at: Self.chordID, verse: 0, text: "la").apply(to: &score)
        let before = Self.lyrics(in: score)

        let inverse = try SetLyric(at: Self.chordID, verse: 0, text: nil).apply(to: &score)

        #expect(Self.lyrics(in: score).isEmpty)
        _ = try inverse.apply(to: &score)
        #expect(Self.lyrics(in: score) == before)
    }

    @Test("removing verse 0 preserves the index of verse 1 and undo restores both")
    func removingLowerVersePreservesIndexAndRoundTrips() throws {
        var score = EditingFixtures.chordAtIndex1()
        _ = try SetLyric(at: Self.chordID, verse: 0, text: "one").apply(to: &score)
        _ = try SetLyric(at: Self.chordID, verse: 1, text: "two").apply(to: &score)
        let before = Self.lyrics(in: score)

        let inverse = try SetLyric(at: Self.chordID, verse: 0, text: nil).apply(to: &score)

        let lyrics = Self.lyrics(in: score)
        #expect(lyrics.count == 2)
        #expect(lyrics[0] == Lyric(text: "", verse: 0))
        #expect(lyrics[1].text == "two")
        #expect(lyrics[1].verse == 1)
        _ = try inverse.apply(to: &score)
        #expect(Self.lyrics(in: score) == before)
    }

    @Test("removing an absent verse is a reversible no-op")
    func removingAbsentVerseRoundTrips() throws {
        var score = EditingFixtures.chordAtIndex1()
        let before = score

        let inverse = try SetLyric(at: Self.chordID, verse: 4, text: nil).apply(to: &score)

        #expect(score == before)
        _ = try inverse.apply(to: &score)
        #expect(score == before)
    }

    @Test("undo restores trailing empty padding exactly")
    func inverseRestoresTrailingPadding() throws {
        var score = EditingFixtures.chordAtIndex1()
        var chord = Self.chord(in: score)
        chord.lyrics = [
            Lyric(text: "old", verse: 0),
            Lyric(text: "", verse: 1),
            Lyric(text: "", verse: 2),
        ]
        score[Self.chordID] = .chord(chord)
        let before = chord.lyrics

        let inverse = try SetLyric(at: Self.chordID, verse: 0, text: "new")
            .apply(to: &score)
        _ = try inverse.apply(to: &score)

        #expect(Self.lyrics(in: score) == before)
    }

    @Test("writing scalar fields preserves the existing lyric's non-scalar metadata")
    func writingPreservesMetadata() throws {
        var score = EditingFixtures.chordAtIndex1()
        var chord = Self.chord(in: score)
        var existing = Lyric(
            text: "old",
            syllabic: .begin,
            ticks: 120,
            properties: TextProperties(face: "Edwin", size: 12),
            preservedMarkup: [PreservedXML(name: "offset", text: "1.5")],
        )
        existing.visible = false
        chord.lyrics = [existing]
        score[Self.chordID] = .chord(chord)

        _ = try SetLyric(
            at: Self.chordID,
            verse: 0,
            text: " new ",
            syllabic: .end,
            ticks: 960,
        ).apply(to: &score)

        let written = Self.lyrics(in: score)[0]
        #expect(written.text == "new")
        #expect(written.syllabic == .end)
        #expect(written.ticks == 960)
        #expect(written.visible == false)
        #expect(written.properties == existing.properties)
        #expect(written.elementProperties == existing.elementProperties)
        #expect(written.preservedMarkup == existing.preservedMarkup)
    }

    private static func chord(in score: Score) -> Chord {
        guard case let .chord(chord) = score[chordID] else {
            Issue.record("expected chord")
            return Chord(duration: .quarter, notes: [])
        }
        return chord
    }

    private static func lyrics(in score: Score) -> [Lyric] {
        chord(in: score).lyrics
    }

    private static func reason(of error: SheetMusicError?) -> EditRefusal.Reason? {
        guard case let .invalidEdit(refusal)? = error else { return nil }
        return refusal.reason
    }
}
