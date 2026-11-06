@testable import SheetMusicCore
import Testing

/// Where lyric entry stops on a rest. MuseScore's `NotationInteraction::navigateToLyrics` walks the segments either
/// way and breaks on a chord, and on a rest only when it already carries a syllable on that verse — so typing words
/// never lands on a silent beat, while a syllable written under a rest is still reached.
@Suite("Lyric entry and rests")
struct LyricInputRestStopTests {
    private static let staff = StaffAddress(partIndex: 0, staffIndexInPart: 0)

    private static func id(_ element: Int) -> VoiceElementID {
        VoiceElementID(staff: staff, measureIndex: 0, voiceIndex: 0, elementIndex: element)
    }

    /// One 4/4 bar: note, quarter rest, note, quarter rest — the first rest carrying `restLyrics`.
    private static func score(restLyrics: [Lyric] = []) -> Score {
        let note = VoiceElement.chord(Chord(duration: .quarter, notes: ChordNotes([Note(pitch: 60, tpc: 14)])))
        let measure = Measure(voices: [Voice(elements: [
            note,
            .chord(Chord(duration: .quarter, notes: [], lyrics: restLyrics)),
            note,
            .chord(Chord(duration: .quarter, notes: [])),
        ])])
        return Score(division: 480, parts: [Part(id: "1", instrument: Instrument(id: "voice"), staves: [
            Staff(measures: [measure]),
        ])])
    }

    @Test("Space from a note passes a bare rest to the next note")
    func spaceSkipsBareRest() {
        let plan = LyricInputPlanner.plan(
            typing: "la", terminatedBy: .word, at: .init(location: Self.id(0), verse: 0), in: Self.score(),
        )
        #expect(plan.next == .init(location: Self.id(2), verse: 0))
    }

    @Test("Space from a note stops on a rest that carries a syllable on its verse")
    func spaceStopsOnRestWithSyllable() {
        let score = Self.score(restLyrics: [Lyric(text: "でもね、")])
        let plan = LyricInputPlanner.plan(
            typing: "la", terminatedBy: .word, at: .init(location: Self.id(0), verse: 0), in: score,
        )
        #expect(plan.next == .init(location: Self.id(1), verse: 0))
    }

    @Test("a rest's syllable on another verse does not stop this one")
    func otherVerseDoesNotStop() {
        let score = Self.score(restLyrics: [Lyric(text: "", verse: 0), Lyric(text: "ah", verse: 1)])
        let plan = LyricInputPlanner.plan(
            typing: "la", terminatedBy: .word, at: .init(location: Self.id(0), verse: 0), in: score,
        )
        #expect(plan.next == .init(location: Self.id(2), verse: 0))
        let second = LyricInputPlanner.plan(
            typing: "la", terminatedBy: .word, at: .init(location: Self.id(0), verse: 1), in: score,
        )
        #expect(second.next == .init(location: Self.id(1), verse: 1))
    }

    @Test("moving without writing takes the same stops, both ways")
    func moveStopsMatch() {
        let bare = Self.score()
        let worded = Self.score(restLyrics: [Lyric(text: "ah")])
        #expect(LyricInputPlanner.nextCursor(from: .init(location: Self.id(0), verse: 0), in: bare)?.location
            == Self.id(2))
        #expect(LyricInputPlanner.nextCursor(from: .init(location: Self.id(0), verse: 0), in: worded)?.location
            == Self.id(1))
        #expect(LyricInputPlanner.previousCursor(from: .init(location: Self.id(2), verse: 0), in: bare)?.location
            == Self.id(0))
        #expect(LyricInputPlanner.previousCursor(from: .init(location: Self.id(2), verse: 0), in: worded)?.location
            == Self.id(1))
        // The last element is a bare rest: nothing after the second note stops entry.
        #expect(LyricInputPlanner.nextCursor(from: .init(location: Self.id(2), verse: 0), in: bare) == nil)
    }

    @Test("a syllable typed on a rest is written to it, and continues the word before it")
    func typingOnRestWritesIt() throws {
        var score = Self.score()
        guard case var .chord(first)? = score[Self.id(0)] else {
            Issue.record("expected a chord")
            return
        }
        first.lyrics = [Lyric(text: "de", syllabic: .begin)]
        score[Self.id(0)] = .chord(first)
        let plan = LyricInputPlanner.plan(
            typing: "mo", terminatedBy: .none, at: .init(location: Self.id(1), verse: 0), in: score,
        )
        let command = try #require(plan.command)
        _ = try command.apply(to: &score)
        let written = try #require(LyricInputPlanner.lyric(at: .init(location: Self.id(1), verse: 0), in: score))
        #expect(written.text == "mo")
        #expect(written.syllabic == .end)
    }
}
