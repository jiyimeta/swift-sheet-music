import Foundation
@testable import SheetMusicCore
@testable import SheetMusicMIDI
import Testing

struct MidiImporterQuantizeTests {
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
            carryIns: [], carryOuts: [],
        )
        let quantized = MidiImporter.quantize(
            measure: measure, division: 480, options: .init(),
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
            carryIns: [], carryOuts: [],
        )
        let quantized = MidiImporter.quantize(
            measure: measure, division: 480, options: .init(),
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
            carryIns: [], carryOuts: [],
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

    /// D4a: Quintuplet — 5 evenly-spaced onsets in one beat → Tuplet(4,5).
    ///
    /// At 480 PPQ the beat span is 480 ticks. Quintuplet unit = 480/5 = 96 ticks.
    /// `fitsBinary` grid=120 fails (onset at 192 is 48 ticks from the nearest
    /// grid step, exceeding tolerance=30). `fitsTuplet(5:4)` succeeds because
    /// all onsets land exactly on multiples of 96.
    /// Written duration per member: 96 × 5 / 4 = 120 → .sixteenth (120 ticks).
    @Test func quintupletDetectedInOneBeat() {
        // 1/4 measure (480 ticks). 5 onsets spaced 96 ticks apart.
        var events: [TimedMidiEvent] = []
        for i in 0 ..< 5 {
            events.append(TimedMidiEvent(
                tick: i * 96, event: .noteOn(channel: 0, pitch: 60 + i, velocity: 80),
            ))
            events.append(TimedMidiEvent(
                tick: i * 96 + 80, event: .noteOff(channel: 0, pitch: 60 + i, velocity: 0),
            ))
        }
        let measure = ImportMeasure(
            startTick: 0, endTick: 480, measureIndex: 0,
            timeSignature: TimeSignature(numerator: 1, denominator: 4),
            events: events,
            carryIns: [], carryOuts: [],
        )
        let q = MidiImporter.quantize(measure: measure, division: 480, options: .init())
        #expect(q.tuplets.count == 1)
        #expect(q.tuplets[0].actualNotes == 5)
        #expect(q.tuplets[0].normalNotes == 4)
        #expect(q.elements.count == 5)
    }

    /// D4b: Septuplet — 7 onsets in one beat → Tuplet(4,7).
    ///
    /// At 480 PPQ the beat span is 480 ticks. Ideal septuplet unit = 480/7 ≈ 68.57
    /// ticks; onsets are placed at round(480/7 × i). `fitsBinary` fails because
    /// onset at tick 69 is 51 ticks from the nearest sixteenth-grid step.
    /// `fitsTuplet(3:2)` and `fitsTuplet(5:4)` both fail. `fitsTuplet(7:4)` uses
    /// integer unit = 68; rounding error ≤ 3 ticks, well within tolerance=30.
    @Test func septupletDetectedInOneBeat() {
        // 1/4 measure (480 ticks). 7 onsets spaced ~68–69 ticks apart.
        // Tick positions: round(480/7 × i) = 0, 69, 137, 206, 274, 343, 411.
        let onsetTicks = [0, 69, 137, 206, 274, 343, 411]
        var events: [TimedMidiEvent] = []
        for (i, tick) in onsetTicks.enumerated() {
            events.append(TimedMidiEvent(
                tick: tick, event: .noteOn(channel: 0, pitch: 60 + i, velocity: 80),
            ))
            events.append(TimedMidiEvent(
                tick: tick + 50, event: .noteOff(channel: 0, pitch: 60 + i, velocity: 0),
            ))
        }
        let measure = ImportMeasure(
            startTick: 0, endTick: 480, measureIndex: 0,
            timeSignature: TimeSignature(numerator: 1, denominator: 4),
            events: events,
            carryIns: [], carryOuts: [],
        )
        let q = MidiImporter.quantize(measure: measure, division: 480, options: .init())
        #expect(q.tuplets.count == 1)
        #expect(q.tuplets[0].actualNotes == 7)
        #expect(q.tuplets[0].normalNotes == 4)
        #expect(q.elements.count == 7)
    }

    /// D5: Force-snap fallback — onsets that fit no binary or tuplet grid.
    ///
    /// With tuplet detection disabled and a very tight tolerance (1 tick),
    /// no assignment is recorded for any span. `snapTick` returns each raw
    /// onset tick unchanged; `assemble` still produces one element per
    /// inter-onset gap plus one final element for the gap to measure end.
    /// The quantizer must not throw and must emit ≥ 3 elements.
    ///
    /// Ticks 317 and 953 are prime-ish values chosen so that
    ///   317 % 120 = 77  (min(77,43) = 43 > 1) — binary fails
    ///   953 % 120 = 113 (min(113,7) = 7 > 1)  — binary fails
    /// With `tupletRatios: []`, no tuplet fit is attempted at all.
    @Test func irrationaOnsetsFallBackToForceSnap() {
        let measure = ImportMeasure(
            startTick: 0, endTick: 1920, measureIndex: 0,
            timeSignature: TimeSignature(numerator: 4, denominator: 4),
            events: [
                TimedMidiEvent(tick: 317, event: .noteOn(channel: 0, pitch: 60, velocity: 80)),
                TimedMidiEvent(tick: 700, event: .noteOff(channel: 0, pitch: 60, velocity: 0)),
                TimedMidiEvent(tick: 953, event: .noteOn(channel: 0, pitch: 62, velocity: 80)),
                TimedMidiEvent(tick: 1400, event: .noteOff(channel: 0, pitch: 62, velocity: 0)),
            ],
            carryIns: [], carryOuts: [],
        )
        var opts = MidiImportOptions()
        opts.tupletRatios = []
        opts.onsetTolerance = 1
        let q = MidiImporter.quantize(measure: measure, division: 480, options: opts)
        // Must not throw (compile-time guarantee — quantize is non-throwing).
        // Must produce at least 3 elements: gap before onset1, gap between
        // onsets, and gap from onset2 to measure end.
        #expect(q.elements.count >= 3)
        #expect(q.tuplets.isEmpty)
    }
}
