import Foundation
@testable import SheetMusicCore
@testable import SheetMusicMIDI
import Testing

/// Round-trip: a `Score` carrying chord lyrics must survive
/// render -> SMF bytes -> import, with text / syllabic / verse / melisma
/// reconstructed onto the imported chords.
struct MidiImporterLyricTests {
    private func chord(_ pitch: Int, _ lyrics: [Lyric]) -> Chord {
        Chord(
            duration: .quarter,
            notes: ChordNotes([Note(pitch: pitch, tpc: 14)]),
            lyrics: lyrics,
        )
    }

    private func roundTrip(_ elements: [VoiceElement]) throws -> Score {
        let voice = Voice(elements: elements)
        let measure = Measure(voices: [voice])
        let staff = Staff(measures: [measure])
        let part = Part(
            id: "P1",
            instrument: Instrument(id: "piano", longName: "Piano"),
            staves: [staff],
        )
        let score = Score(division: 480, parts: [part])
        let bytes = try MidiWriter.write(MidiRenderer.render(score: score))
        return try MidiImporter.parse(bytes)
    }

    /// Lyrics of every chord across the score, in tick order.
    private func chordLyrics(in score: Score) -> [[Lyric]] {
        score.parts
            .flatMap(\.staves)
            .flatMap(\.measures)
            .flatMap(\.voices)
            .flatMap(\.elements)
            .compactMap { element in
                if case let .chord(chord) = element, !chord.notes.isEmpty {
                    return chord.lyrics
                }
                return nil
            }
    }

    @Test func roundTripsHyphenatedSyllables() throws {
        let imported = try roundTrip([
            .chord(chord(60, [Lyric(text: "Twin", syllabic: .begin)])),
            .chord(chord(62, [Lyric(text: "kle", syllabic: .end)])),
            .chord(chord(64, [Lyric(text: "lit", syllabic: .begin)])),
            .chord(chord(65, [Lyric(text: "tle", syllabic: .end)])),
        ])
        let lyrics = chordLyrics(in: imported)
        #expect(lyrics.count == 4)
        #expect(lyrics[0] == [Lyric(text: "Twin", syllabic: .begin)])
        #expect(lyrics[1] == [Lyric(text: "kle", syllabic: .end)])
        #expect(lyrics[2] == [Lyric(text: "lit", syllabic: .begin)])
        #expect(lyrics[3] == [Lyric(text: "tle", syllabic: .end)])
    }

    @Test func roundTripsTwoVerses() throws {
        let imported = try roundTrip([
            .chord(chord(60, [
                Lyric(text: "la", verse: 0),
                Lyric(text: "lo", verse: 1),
            ])),
            .chord(chord(62, [
                Lyric(text: "da", verse: 0),
                Lyric(text: "do", verse: 1),
            ])),
        ])
        let lyrics = chordLyrics(in: imported)
        #expect(lyrics.count == 2)
        #expect(lyrics[0] == [Lyric(text: "la", verse: 0), Lyric(text: "lo", verse: 1)])
        #expect(lyrics[1] == [Lyric(text: "da", verse: 0), Lyric(text: "do", verse: 1)])
    }

    @Test func roundTripsSparseVerse() throws {
        // Verse 0 silent on the second chord, verse 1 sings.
        let imported = try roundTrip([
            .chord(chord(60, [
                Lyric(text: "a", verse: 0),
                Lyric(text: "x", verse: 1),
            ])),
            .chord(chord(62, [Lyric(text: "y", verse: 1)])),
        ])
        let lyrics = chordLyrics(in: imported)
        #expect(lyrics.count == 2)
        #expect(lyrics[0] == [Lyric(text: "a", verse: 0), Lyric(text: "x", verse: 1)])
        #expect(lyrics[1] == [Lyric(text: "", verse: 0), Lyric(text: "y", verse: 1)])
    }

    @Test func roundTripsMelisma() throws {
        // "Glo" held across the covered chord, melisma span = 960 ticks.
        let imported = try roundTrip([
            .chord(chord(60, [Lyric(text: "Glo", syllabic: .begin, ticks: 960)])),
            .chord(chord(62, [])),
            .chord(chord(64, [Lyric(text: "ri", syllabic: .end)])),
        ])
        let lyrics = chordLyrics(in: imported)
        #expect(lyrics.count == 3)
        #expect(lyrics[0] == [Lyric(text: "Glo", syllabic: .begin, ticks: 960)])
        #expect(lyrics[1] == []) // covered chord carries no syllable
        #expect(lyrics[2] == [Lyric(text: "ri", syllabic: .end)])
    }
}
