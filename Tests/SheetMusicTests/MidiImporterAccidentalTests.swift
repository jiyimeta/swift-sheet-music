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
