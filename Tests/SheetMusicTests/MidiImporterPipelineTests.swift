import Foundation
@testable import SheetMusicCore
@testable import SheetMusicMIDI
import Testing

@Suite struct MidiImporterPipelineTests {
    /// Smoke test: a Format 1 SMF with one piano track + one drum
    /// track produces a Score with two Parts (one drumset).
    @Test func parsesTwoTrackFormat1WithDrumset() throws {
        // Build via MidiRenderer → MidiWriter to avoid hand-rolling SMF bytes.
        let pianoNote = Note(pitch: 60, tpc: 14)
        let pianoChord = Chord(duration: .quarter, notes: ChordNotes([pianoNote]))
        let pianoVoice = Voice(elements: [.chord(pianoChord)])
        let pianoMeasure = Measure(voices: [pianoVoice])
        let pianoStaff = StaffContent(id: 1, measures: [pianoMeasure])
        let pianoPart = Part(
            id: "P1",
            instrument: Instrument(id: "piano", longName: "Piano")
        )
        let drumNote = Note(pitch: 36, tpc: 0, headType: "normal")
        let drumChord = Chord(duration: .quarter, notes: ChordNotes([drumNote]))
        let drumVoice = Voice(elements: [.chord(drumChord)])
        let drumMeasure = Measure(voices: [drumVoice])
        let drumStaff = StaffContent(id: 2, measures: [drumMeasure])
        let drumPart = Part(
            id: "P2",
            instrument: Instrument(
                id: "drumset", longName: "Drumset", useDrumset: true
            )
        )
        let score = Score(
            division: 480,
            parts: [pianoPart, drumPart],
            staves: [pianoStaff, drumStaff]
        )
        let smfBytes = try MidiWriter.write(MidiRenderer.render(score: score))
        let imported = try MidiImporter.parse(smfBytes)
        #expect(imported.parts.count >= 2)
        let hasDrumset = imported.parts.contains(where: \.instrument.useDrumset)
        #expect(hasDrumset)
        #expect(imported.staves.count >= 2)
    }

    @Test func parsesEmptyFormat0PreservingDivision() throws {
        let bytes = Data([
            0x4D, 0x54, 0x68, 0x64, 0x00, 0x00, 0x00, 0x06,
            0x00, 0x00, 0x00, 0x01, 0x01, 0xE0,
            0x4D, 0x54, 0x72, 0x6B, 0x00, 0x00, 0x00, 0x04,
            0x00, 0xFF, 0x2F, 0x00,
        ])
        let imported = try MidiImporter.parse(bytes)
        #expect(imported.division == 480)
    }

    @Test func resolveSwingAsyncIsCalledWhenSet() async throws {
        // Build a swung-eighths SMF (front=160, back=320) over 16 beats.
        var events: [TimedMidiEvent] = []
        for b in 0 ..< 16 {
            let beatStart = b * 480
            events.append(TimedMidiEvent(
                tick: beatStart,
                event: .noteOn(channel: 0, pitch: 60, velocity: 80)
            ))
            events.append(TimedMidiEvent(
                tick: beatStart + 160,
                event: .noteOff(channel: 0, pitch: 60, velocity: 0)
            ))
            events.append(TimedMidiEvent(
                tick: beatStart + 160,
                event: .noteOn(channel: 0, pitch: 62, velocity: 80)
            ))
            events.append(TimedMidiEvent(
                tick: beatStart + 480,
                event: .noteOff(channel: 0, pitch: 62, velocity: 0)
            ))
        }
        let track = MidiTrack(events: events
            + [TimedMidiEvent(tick: 16 * 480, event: .endOfTrack)])
        let file = MidiFile(division: 480, format: 0, tracks: [track])
        let bytes = try MidiWriter.write(file)

        actor Counter { var count = 0; func incr() { count += 1 } }
        let counter = Counter()

        var opts = MidiImportOptions()
        opts.resolveSwingAsync = { _ in
            await counter.incr()
            return .treatAsWritten
        }
        _ = try await MidiImporter.parse(bytes, options: opts)
        let calls = await counter.count
        #expect(calls >= 1)
    }
}
