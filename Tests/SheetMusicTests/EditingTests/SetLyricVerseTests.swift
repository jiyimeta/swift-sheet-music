@testable import SheetMusicCore
import Testing

@Suite("Set lyric verse")
struct SetLyricVerseTests {
    private static let slot = VoiceElementID(
        staff: EditingFixtures.staff0, measureIndex: 0, voiceIndex: 0, elementIndex: 1,
    )

    @Test("a whole syllable moves, neighbors stay unchanged, and undo/redo restores exact arrays")
    func movesWholeSyllable() throws {
        for (source, destination) in [(0, 3), (3, 0)] {
            var score = EditingFixtures.twoConsecutiveC4Chords()
            _ = try SetLyric(at: Self.slot, verse: source, text: "la", syllabic: .middle, ticks: 960)
                .apply(to: &score)
            guard case var .chord(chord)? = score[Self.slot] else { Issue.record("missing chord"); return }
            chord.lyrics[source].properties = TextProperties(face: "Edwin", framePadding: 2)
            chord.lyrics[source].elementProperties.visible = false
            chord.lyrics[source].preservedMarkup = [PreservedXML(name: "offset", text: "1.5")]
            chord.lyrics.append(Lyric(text: "", verse: chord.lyrics.count))
            score[Self.slot] = .chord(chord)
            let neighbor = Self.slot.withElementIndex(2)
            _ = try SetLyric(at: neighbor, verse: source, text: "next", syllabic: .end).apply(to: &score)
            let before = score
            let oldHash = score.stableFingerprint
            let planned = try ScoreEditSession.command(
                for: .setLyricVerse(text: .lyric(anchor: Self.slot, verse: source), toVerse: destination),
                in: score, depth: 0,
            )
            let command = try #require(planned)
            let inverse = try command.apply(to: &score)
            var expected = chord.lyrics[source]
            expected.verse = destination
            #expect(SetLyric.current(at: Self.slot, verse: destination, in: score) == expected)
            guard case let .chord(movedChord)? = score[Self.slot] else { Issue.record("missing chord"); return }
            #expect(movedChord.lyrics.count == destination + 1)
            for (index, lyric) in movedChord.lyrics.enumerated() {
                #expect(lyric.verse == index)
                if index != destination { #expect(lyric == Lyric(text: "", verse: index)) }
            }
            #expect(score[neighbor] == before[neighbor])
            #expect(score.stableFingerprint != oldHash)
            let moved = score
            let redo = try inverse.apply(to: &score)
            #expect(score == before)
            #expect(score.stableFingerprint == oldHash)
            _ = try redo.apply(to: &score)
            #expect(score == moved)
        }
    }

    @Test("occupied destination refuses atomically with its own typed reason")
    func occupiedDestination() throws {
        var score = EditingFixtures.chordAtIndex1()
        _ = try SetLyric(at: Self.slot, verse: 0, text: "one").apply(to: &score)
        _ = try SetLyric(at: Self.slot, verse: 1, text: "two").apply(to: &score)
        let before = score
        let error = #expect(throws: SheetMusicError.self) {
            try SetLyricVerse(.lyric(anchor: Self.slot, verse: 0), toVerse: 1).apply(to: &score)
        }
        guard case let .invalidEdit(refusal)? = error else { Issue.record("expected refusal"); return }
        #expect(refusal.reason == .occupiedLyricVerse(1))
        #expect(score == before)
    }

    @Test("same occupied source is a planning no-op; missing, empty, negative and non-lyric sources refuse")
    func validationAndPlanning() throws {
        var score = EditingFixtures.chordAtIndex1()
        _ = try SetLyric(at: Self.slot, verse: 1, text: "one").apply(to: &score)
        let same = EditIntent.setLyricVerse(text: .lyric(anchor: Self.slot, verse: 1), toVerse: 1)
        #expect(try ScoreEditSession.command(for: same, in: score, depth: 0) == nil)
        let invalid: [(ScoreTextID, Int)] = [
            (.lyric(anchor: Self.slot, verse: 0), 0),
            (.lyric(anchor: Self.slot, verse: -1), 2),
            (.lyric(anchor: Self.slot, verse: 99), 99),
            (.lyric(anchor: Self.slot, verse: 1), -1),
            (.rehearsalMark(measureIndex: 0), 1),
            (.lyric(anchor: Self.slot.withElementIndex(99), verse: 0), 1),
            (.lyric(anchor: Self.slot.withElementIndex(2), verse: 0), 1),
        ]
        for (text, destination) in invalid {
            let before = score
            let planned = try ScoreEditSession.command(
                for: .setLyricVerse(text: text, toVerse: destination), in: score, depth: 0,
            )
            let command = try #require(planned)
            #expect(throws: SheetMusicError.self) { try command.apply(to: &score) }
            #expect(score == before)
        }
    }

    @Test("a composite plans a font patch against the moved verse and reverses both edits")
    func compositeMoveThenFont() throws {
        var score = EditingFixtures.chordAtIndex1()
        _ = try SetLyric(at: Self.slot, verse: 0, text: "la").apply(to: &score)
        let before = score
        let destination = ScoreTextID.lyric(anchor: Self.slot, verse: 2)
        let planned = try ScoreEditSession.command(for: .composite([
            .setLyricVerse(text: .lyric(anchor: Self.slot, verse: 0), toVerse: 2),
            .setTextFont(text: destination, patch: .init(face: .set("Edwin"))),
        ]), in: score, depth: 0)
        let command = try #require(planned)
        let inverse = try command.apply(to: &score)
        #expect(SetTextFont.current(destination, in: score)?.face == "Edwin")
        _ = try inverse.apply(to: &score)
        #expect(score == before)
        #expect(score.stableFingerprint == before.stableFingerprint)
    }
}
