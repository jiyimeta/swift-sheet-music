import Foundation
@testable import SheetMusicCore
@testable import SheetMusicMIDI
import Testing

@Suite struct MidiImporterAccidentalTests {
    private func nOn(_ tick: Int, _ pitch: Int) -> TimedMidiEvent {
        TimedMidiEvent(tick: tick, event: .noteOn(channel: 0, pitch: pitch, velocity: 80))
    }

    private func nOff(_ tick: Int, _ pitch: Int) -> TimedMidiEvent {
        TimedMidiEvent(tick: tick, event: .noteOff(channel: 0, pitch: pitch, velocity: 0))
    }

    @Test func keySigAlterReturnsExpectedDirectionForFlatAndSharpKeys() {
        // C (letter 0): in 7-flat key (Cb major), gets a flat.
        #expect(MidiImporter.keySigAlter(letter: 0, concertKey: -7) == -1)
        // F (letter 3): in 1-sharp key (G major), gets a sharp.
        #expect(MidiImporter.keySigAlter(letter: 3, concertKey: 1) == 1)
        // A (letter 5): in 4-flat key (Ab major), gets a flat.
        #expect(MidiImporter.keySigAlter(letter: 5, concertKey: -4) == -1)
        // E (letter 2): in 4-flat key, also gets a flat (B/E/A/D).
        #expect(MidiImporter.keySigAlter(letter: 2, concertKey: -4) == -1)
        // C (letter 0): in 4-flat key, NOT altered.
        #expect(MidiImporter.keySigAlter(letter: 0, concertKey: -4) == 0)
    }

    @Test func aNaturalInFlatKeyGetsExplicitNaturalAccidental() {
        // 4-flat key (Ab major). The key sig flatts B/E/A/D. An A
        // natural (MIDI 69, TPC 17 = A natural) is chromatic against
        // the key, so it must carry an explicit natural sign.
        let measure = ImportMeasure(
            startTick: 0, endTick: 1920, measureIndex: 0,
            timeSignature: TimeSignature(numerator: 4, denominator: 4),
            events: [
                nOn(0, 69), nOff(480, 69), // A natural
                nOn(480, 67), nOff(960, 67), // G natural — in key, nil
                nOn(960, 70), nOff(1440, 70), // Bb — in key, nil
                nOn(1440, 71), nOff(1920, 71), // B natural — chromatic
            ],
            carryIns: [], carryOuts: []
        )
        let q = MidiImporter.quantize(measure: measure, division: 480, options: .init())
        let voice = MidiImporter.voice(
            quantized: q, measure: measure, division: 480,
            concertKey: -4
        )
        let pitchesAndAccs: [(pitch: Int, acc: Accidental?)] = voice.elements.compactMap { el in
            if case let .chord(c) = el, let n = c.notes.first {
                return (n.pitch, n.accidental)
            }
            return nil
        }
        #expect(pitchesAndAccs.map(\.pitch) == [69, 67, 70, 71])
        let accFor: (Int) -> Accidental? = { pitch in
            pitchesAndAccs.first { $0.pitch == pitch }?.acc
        }
        #expect(accFor(69) == .natural)
        #expect(accFor(67) == nil)
        #expect(accFor(70) == nil)
        #expect(accFor(71) == .natural)
    }

    @Test func midSongKeyChangeUpdatesTpcSpellings() throws {
        // Two-measure file: measure 0 in 4 flats (Ab major),
        // measure 1 modulates to 3 sharps (A major). The same MIDI
        // pitch class — black key 1 (C#/Db) — should spell as Db
        // (flat) in measure 0 and C# (sharp) in measure 1.
        let track0 = MidiTrack(events: [
            TimedMidiEvent(tick: 0, event: .meta(.trackName("Conductor"))),
            TimedMidiEvent(tick: 0, event: .meta(.keySignature(sharpsFlats: -4, isMinor: false))),
            TimedMidiEvent(tick: 0, event: .meta(.timeSignature(
                numerator: 4, denominator: 4, clocksPerClick: 24, thirtySecondsPerQuarter: 8
            ))),
            // Key change at bar 1 (tick 1920).
            TimedMidiEvent(tick: 1920, event: .meta(.keySignature(sharpsFlats: 3, isMinor: false))),
            TimedMidiEvent(tick: 3840, event: .endOfTrack),
        ])
        let track1 = MidiTrack(events: [
            TimedMidiEvent(tick: 0, event: .meta(.trackName("Piano"))),
            // Measure 0 — flat-key context. Pitch 61 should be Db (TPC 9).
            TimedMidiEvent(tick: 0, event: .noteOn(channel: 0, pitch: 61, velocity: 80)),
            TimedMidiEvent(tick: 1920, event: .noteOff(channel: 0, pitch: 61, velocity: 0)),
            // Measure 1 — sharp-key context. Pitch 61 should be C# (TPC 21).
            TimedMidiEvent(tick: 1920, event: .noteOn(channel: 0, pitch: 61, velocity: 80)),
            TimedMidiEvent(tick: 3840, event: .noteOff(channel: 0, pitch: 61, velocity: 0)),
            TimedMidiEvent(tick: 3840, event: .endOfTrack),
        ])
        let file = MidiFile(division: 480, format: 1, tracks: [track0, track1])
        let bytes = try MidiWriter.write(file)
        let score = try MidiImporter.parse(bytes)

        guard let pi = score.parts.firstIndex(where: { $0.trackName == "Piano" }) else {
            Issue.record("expected piano part"); return
        }
        let piano = score.staves[pi]
        // Helper: TPC of the first note in a measure.
        func firstNoteTpc(in measureIndex: Int) -> Int? {
            for v in piano.measures[measureIndex].voices {
                for el in v.elements {
                    if case let .chord(c) = el, let n = c.notes.first {
                        return n.tpc
                    }
                }
            }
            return nil
        }
        // Db in flat key (tpc 9), C# in sharp key (tpc 21).
        #expect(firstNoteTpc(in: 0) == 9)
        #expect(firstNoteTpc(in: 1) == 21)
    }

    @Test func accidentalPersistsWithinMeasureAndResetsAtBar() {
        // Within a measure, a written accidental persists for the
        // same letter+octave. C-major key sig.
        let measure = ImportMeasure(
            startTick: 0, endTick: 1920, measureIndex: 0,
            timeSignature: TimeSignature(numerator: 4, denominator: 4),
            events: [
                nOn(0, 66), nOff(480, 66), // F#
                nOn(480, 66), nOff(960, 66), // F# again
                nOn(960, 65), nOff(1440, 65), // F natural — needs cancellation
                nOn(1440, 65), nOff(1920, 65), // F natural again — already cancelled
            ],
            carryIns: [], carryOuts: []
        )
        let q = MidiImporter.quantize(measure: measure, division: 480, options: .init())
        let voice = MidiImporter.voice(
            quantized: q, measure: measure, division: 480,
            concertKey: 0
        )
        let accs = voice.elements.compactMap { el -> Accidental?? in
            if case let .chord(c) = el, let n = c.notes.first {
                return n.accidental
            }
            return nil
        }
        #expect(accs.count == 4)
        #expect(accs[0] == .sharp) // first F#
        #expect(accs[1] == nil) // second F# (carried over)
        #expect(accs[2] == .natural) // F natural cancels
        #expect(accs[3] == nil) // already natural
    }
}
