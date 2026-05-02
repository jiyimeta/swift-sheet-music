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
}
