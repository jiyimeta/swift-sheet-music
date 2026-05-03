import Foundation
@testable import SheetMusicCore
@testable import SheetMusicMIDI
import Testing

@Suite struct MidiImporterQuantizeTests {
    private func nOn(_ tick: Int, _ pitch: Int) -> TimedMidiEvent {
        TimedMidiEvent(tick: tick, event: .noteOn(channel: 0, pitch: pitch, velocity: 80))
    }

    private func nOff(_ tick: Int, _ pitch: Int) -> TimedMidiEvent {
        TimedMidiEvent(tick: tick, event: .noteOff(channel: 0, pitch: pitch, velocity: 0))
    }

    @Test func straightQuartersFitBinary() {
        // 4 onsets at quarter intervals (0, 480, 960, 1440), bar 0..1920.
        let measure = ImportMeasure(
            startTick: 0, endTick: 1920, measureIndex: 0,
            timeSignature: TimeSignature(numerator: 4, denominator: 4),
            events: [
                nOn(0, 60), nOn(480, 62), nOn(960, 64), nOn(1440, 65),
                nOff(1920, 65),
            ],
            carryIns: [], carryOuts: []
        )
        let quantized = MidiImporter.quantize(
            measure: measure, division: 480, options: .init()
        )
        #expect(quantized.elements.count == 4)
        #expect(quantized.tuplets.isEmpty)
    }

    @Test func eighthTripletDetectedAtBeatScope() {
        // Triplet over beat 0..480: onsets at 0, 160, 320; offset at 480.
        let measure = ImportMeasure(
            startTick: 0, endTick: 480, measureIndex: 0,
            timeSignature: TimeSignature(numerator: 1, denominator: 4),
            events: [
                TimedMidiEvent(tick: 0, event: .noteOn(channel: 0, pitch: 60, velocity: 80)),
                TimedMidiEvent(tick: 160, event: .noteOff(channel: 0, pitch: 60, velocity: 0)),
                TimedMidiEvent(tick: 160, event: .noteOn(channel: 0, pitch: 62, velocity: 80)),
                TimedMidiEvent(tick: 320, event: .noteOff(channel: 0, pitch: 62, velocity: 0)),
                TimedMidiEvent(tick: 320, event: .noteOn(channel: 0, pitch: 64, velocity: 80)),
                TimedMidiEvent(tick: 480, event: .noteOff(channel: 0, pitch: 64, velocity: 0)),
            ],
            carryIns: [], carryOuts: []
        )
        let quantized = MidiImporter.quantize(
            measure: measure, division: 480, options: .init()
        )
        #expect(quantized.tuplets.count == 1)
        #expect(quantized.tuplets[0].normalNotes == 2)
        #expect(quantized.tuplets[0].actualNotes == 3)
    }
}
