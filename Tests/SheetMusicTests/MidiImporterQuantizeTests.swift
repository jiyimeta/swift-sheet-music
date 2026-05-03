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

    /// D3: Half-triplet with unequal members (half + quarter written).
    ///
    /// A 2/4 measure (960 ticks at 480 PPQ) contains a (3:2) triplet spanning
    /// the whole measure. The first note plays for 2 tuplet-units (640 ticks)
    /// and is written as a half; the second plays for 1 tuplet-unit (320 ticks)
    /// and is written as a quarter.
    ///
    /// Arithmetic: tuplet_unit = 960 / 3 = 320.
    /// durationFor formula: written = gap × actual / normal.
    ///   Member 1: 640 × 3 / 2 = 960 → .half  ✓
    ///   Member 2: 320 × 3 / 2 = 480 → .quarter  ✓
    @Test func halfTripletWithHalfPlusQuarterMembers() {
        // 2/4 measure (960 ticks at 480 PPQ). Two notes: tick 0..640
        // (= 2 tuplet-units, written as half) and tick 640..960
        // (= 1 tuplet-unit, written as quarter). Expected ratio (3,2).
        let measure = ImportMeasure(
            startTick: 0, endTick: 960, measureIndex: 0,
            timeSignature: TimeSignature(numerator: 2, denominator: 4),
            events: [
                TimedMidiEvent(tick: 0, event: .noteOn(channel: 0, pitch: 60, velocity: 80)),
                TimedMidiEvent(tick: 640, event: .noteOff(channel: 0, pitch: 60, velocity: 0)),
                TimedMidiEvent(tick: 640, event: .noteOn(channel: 0, pitch: 62, velocity: 80)),
                TimedMidiEvent(tick: 960, event: .noteOff(channel: 0, pitch: 62, velocity: 0)),
            ],
            carryIns: [], carryOuts: []
        )
        let q = MidiImporter.quantize(measure: measure, division: 480, options: .init())
        #expect(q.tuplets.count == 1)
        #expect(q.tuplets[0].actualNotes == 3)
        #expect(q.tuplets[0].normalNotes == 2)
        // Two members, durations half + quarter.
        #expect(q.elements.count == 2)
        if case let .chord(c0) = q.elements[0] { #expect(c0.duration == .half) }
        if case let .chord(c1) = q.elements[1] { #expect(c1.duration == .quarter) }
    }
}
