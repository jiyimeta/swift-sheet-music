import Foundation
@testable import SheetMusic
@testable import SheetMusicCore
@testable import SheetMusicMIDI
@testable import SheetMusicMSCX
import Testing

@Suite struct MidiImportRoundTripTests {
    // MARK: - Helpers

    /// Walk all `VoiceElement` chord pitches across every staff/measure/voice.
    private func allPitches(in score: Score) -> [Int] {
        score.staves
            .flatMap(\.measures)
            .flatMap(\.voices)
            .flatMap(\.elements)
            .flatMap { element -> [Int] in
                if case let .chord(chord) = element {
                    return chord.notes.map(\.pitch)
                }
                return []
            }
    }

    // MARK: - Synthetic tests

    @Test func syntheticSingleNoteRoundTrips() throws {
        // Build a Score with one C4 quarter note.
        let note = Note(pitch: 60, tpc: 14)
        let chord = Chord(duration: .quarter, notes: ChordNotes([note]))
        let voice = Voice(elements: [.chord(chord)])
        let measure = Measure(voices: [voice])
        let staff = StaffContent(id: 1, measures: [measure])
        let part = Part(
            id: "P1",
            instrument: Instrument(id: "piano", longName: "Piano")
        )
        let originalScore = Score(
            division: 480,
            parts: [part],
            staves: [staff]
        )

        // Round trip: render → SMF bytes → import.
        let smfBytes = try MidiWriter.write(MidiRenderer.render(score: originalScore))
        let imported = try MidiImporter.parse(smfBytes)

        // Verify the imported score has the right shape.
        #expect(imported.parts.count >= 1)
        #expect(!imported.staves.isEmpty)

        let pitches = allPitches(in: imported)
        #expect(pitches.contains(60))
    }

    @Test func syntheticChordRoundTrips() throws {
        // C major triad as a half-note chord.
        let notes: ChordNotes = [
            Note(pitch: 60, tpc: 14),
            Note(pitch: 64, tpc: 18),
            Note(pitch: 67, tpc: 15),
        ]
        let chord = Chord(duration: .half, notes: notes)
        let voice = Voice(elements: [.chord(chord)])
        let measure = Measure(voices: [voice])
        let staff = StaffContent(id: 1, measures: [measure])
        let part = Part(
            id: "P1",
            instrument: Instrument(id: "piano", longName: "Piano")
        )
        let score = Score(division: 480, parts: [part], staves: [staff])

        let smfBytes = try MidiWriter.write(MidiRenderer.render(score: score))
        let imported = try MidiImporter.parse(smfBytes)

        let pitches = allPitches(in: imported)
        #expect(pitches.contains(60))
        #expect(pitches.contains(64))
        #expect(pitches.contains(67))
    }

    // MARK: - Fixture-based test

    @Test func midi01FixtureRoundTrips() throws {
        guard let url = Bundle.module.url(forResource: "midi01", withExtension: "mscx") else {
            Issue.record("midi01.mscx fixture missing")
            return
        }
        let mscxData = try Data(contentsOf: url)
        let original = try MSCXParser.parse(mscxData)
        let firstBytes = try MidiWriter.write(MidiRenderer.render(score: original))

        // Verify import doesn't throw and produces a plausible Score.
        let imported = try MidiImporter.parse(firstBytes)
        #expect(imported.division > 0)
        #expect(!imported.parts.isEmpty)
    }
}
