import Foundation
@testable import SheetMusicCore
@testable import SheetMusicMIDI
import Testing

/// End-to-end export: a `Score` carrying chord lyrics must render SMF
/// Lyric (0x05) meta events following the `LyricMidiCodec` conventions.
struct MidiRendererLyricTests {
    private func chord(_ pitch: Int, _ lyrics: [Lyric]) -> Chord {
        Chord(
            duration: .quarter,
            notes: ChordNotes([Note(pitch: pitch, tpc: 14)]),
            lyrics: lyrics,
        )
    }

    private func render(_ elements: [VoiceElement]) throws -> [(tick: Int, text: String)] {
        let voice = Voice(elements: elements)
        let measure = Measure(voices: [voice])
        let staff = Staff(measures: [measure])
        let part = Part(id: "P1", instrument: Instrument(id: "test"), staves: [staff])
        let score = Score(division: 480, parts: [part])
        let file = try MidiRenderer.render(score: score)
        return try #require(file.tracks.first).events.compactMap { ev in
            if case let .meta(.lyric(text)) = ev.event { return (ev.tick, text) }
            return nil
        }
    }

    @Test func rendersHyphenatedSyllables() throws {
        let lyrics = try render([
            .chord(chord(60, [Lyric(text: "Twin", syllabic: .begin)])),
            .chord(chord(62, [Lyric(text: "kle", syllabic: .end)])),
        ])
        #expect(lyrics.map(\.tick) == [0, 480])
        #expect(lyrics.map(\.text) == ["Twin-", "kle"])
    }

    @Test func rendersTwoVersesOrderedByVerse() throws {
        let lyrics = try render([
            .chord(chord(60, [
                Lyric(text: "la", verse: 0),
                Lyric(text: "lo", verse: 1),
            ])),
        ])
        #expect(lyrics.filter { $0.tick == 0 }.map(\.text) == ["la", "lo"])
    }

    @Test func rendersMelismaAsUnderscoreContinuation() throws {
        let lyrics = try render([
            .chord(chord(60, [Lyric(text: "Glo", syllabic: .begin, ticks: 960)])),
            .chord(chord(62, [])),
            .chord(chord(64, [Lyric(text: "ri", syllabic: .end)])),
        ])
        #expect(lyrics.map(\.tick) == [0, 480, 960])
        #expect(lyrics.map(\.text) == ["Glo-", "_", "ri"])
    }

    @Test func rendersNoLyricEventsForLyriclessScore() throws {
        let lyrics = try render([
            .chord(chord(60, [])),
            .chord(chord(62, [])),
        ])
        #expect(lyrics.isEmpty)
    }
}
