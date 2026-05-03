import Foundation
@testable import SheetMusicCore
@testable import SheetMusicMIDI
import Testing

@Suite struct MidiImporterVoicingTests {
    private func nOn(_ tick: Int, _ pitch: Int) -> TimedMidiEvent {
        TimedMidiEvent(tick: tick, event: .noteOn(channel: 0, pitch: pitch, velocity: 80))
    }

    private func nOff(_ tick: Int, _ pitch: Int) -> TimedMidiEvent {
        TimedMidiEvent(tick: tick, event: .noteOff(channel: 0, pitch: pitch, velocity: 0))
    }

    @Test func simultaneousOnSimultaneousOffMakesOneChord() {
        let measure = ImportMeasure(
            startTick: 0, endTick: 480, measureIndex: 0,
            timeSignature: TimeSignature(numerator: 1, denominator: 4),
            events: [nOn(0, 60), nOn(0, 64), nOff(480, 60), nOff(480, 64)],
            carryIns: [], carryOuts: []
        )
        let q = MidiImporter.quantize(measure: measure, division: 480, options: .init())
        let voice = MidiImporter.voice(quantized: q, measure: measure, division: 480)
        #expect(voice.elements.count == 1)
        if case let .chord(c) = voice.elements[0] {
            #expect(c.notes.count == 2)
        }
    }

    @Test func staggeredOffMakesTieToContinuingPitch() {
        // C4 and E4 on at tick 0; E4 off at 240, C4 off at 480.
        let measure = ImportMeasure(
            startTick: 0, endTick: 480, measureIndex: 0,
            timeSignature: TimeSignature(numerator: 1, denominator: 4),
            events: [nOn(0, 60), nOn(0, 64), nOff(240, 64), nOff(480, 60)],
            carryIns: [], carryOuts: []
        )
        let q = MidiImporter.quantize(measure: measure, division: 480, options: .init())
        let voice = MidiImporter.voice(quantized: q, measure: measure, division: 480)
        #expect(voice.elements.count == 2)
        // First chord: both pitches; C4 (pitch 60) should carry forward via tieForward.
        if case let .chord(c0) = voice.elements[0] {
            #expect(c0.notes.count == 2)
            let c = c0.notes.first(where: { $0.pitch == 60 })
            #expect(c?.tieForward == 1)
        }
        // Second chord: only C4, with tieBack.
        if case let .chord(c1) = voice.elements[1] {
            #expect(c1.notes.count == 1)
            #expect(c1.notes.first?.pitch == 60)
            #expect(c1.notes.first?.tieBack == 1)
        }
    }

    @Test func gapBetweenNotesProducesEmptyChordRest() {
        // Note ends at 240, next note starts at 360 → gap of 120 ticks
        // emits an empty-chord rest.
        let measure = ImportMeasure(
            startTick: 0, endTick: 480, measureIndex: 0,
            timeSignature: TimeSignature(numerator: 1, denominator: 4),
            events: [nOn(0, 60), nOff(240, 60), nOn(360, 62), nOff(480, 62)],
            carryIns: [], carryOuts: []
        )
        let q = MidiImporter.quantize(measure: measure, division: 480, options: .init())
        let voice = MidiImporter.voice(quantized: q, measure: measure, division: 480)
        // Expect: chord (60), rest, chord (62)
        #expect(voice.elements.count == 3)
        if case let .chord(c1) = voice.elements[1] {
            #expect(c1.notes.isEmpty)
        }
    }

    @Test func tupletIndicesSurviveSustainedNoteThroughVoicing() {
        // Beat 0..480 has a triplet on pitch 60 (onsets at 0, 160, 320).
        // A sustained pitch 67 starts at tick 0 and ends at tick 240
        // — mid-triplet. The voicing pass adds an extra grid step at
        // tick 240, so the rebuilt elements list has more entries than
        // the quantizer's. Tuplet indices must still point at the
        // triplet members in the rebuilt list.
        let measure = ImportMeasure(
            startTick: 0, endTick: 480, measureIndex: 0,
            timeSignature: TimeSignature(numerator: 1, denominator: 4),
            events: [
                // Triplet on pitch 60.
                TimedMidiEvent(
                    tick: 0,
                    event: .noteOn(channel: 0, pitch: 60, velocity: 80)
                ),
                TimedMidiEvent(
                    tick: 160,
                    event: .noteOff(channel: 0, pitch: 60, velocity: 0)
                ),
                TimedMidiEvent(
                    tick: 160,
                    event: .noteOn(channel: 0, pitch: 62, velocity: 80)
                ),
                TimedMidiEvent(
                    tick: 320,
                    event: .noteOff(channel: 0, pitch: 62, velocity: 0)
                ),
                TimedMidiEvent(
                    tick: 320,
                    event: .noteOn(channel: 0, pitch: 64, velocity: 80)
                ),
                TimedMidiEvent(
                    tick: 480,
                    event: .noteOff(channel: 0, pitch: 64, velocity: 0)
                ),
                // Sustained pitch 67, ends mid-triplet at tick 240.
                TimedMidiEvent(
                    tick: 0,
                    event: .noteOn(channel: 0, pitch: 67, velocity: 80)
                ),
                TimedMidiEvent(
                    tick: 240,
                    event: .noteOff(channel: 0, pitch: 67, velocity: 0)
                ),
            ],
            carryIns: [], carryOuts: []
        )
        let q = MidiImporter.quantize(
            measure: measure, division: 480, options: .init()
        )
        let voice = MidiImporter.voice(
            quantized: q, measure: measure, division: 480
        )
        #expect(voice.tuplets.count == 1)
        let tuplet = voice.tuplets[0]
        // The chords at tuplet.startIndex...tuplet.endIndex must all
        // contain pitch 60/62/64 (the triplet members), not the
        // sustained-note rest chord at tick 240.
        let tripletPitches: [[Int]] = (tuplet.startIndex ... tuplet.endIndex).map { i in
            if case let .chord(c) = voice.elements[i] {
                return c.notes.map(\.pitch)
            }
            return []
        }
        // Each tuplet member should contain at least one of {60, 62, 64}.
        let tripletPitchesFlat = Set(tripletPitches.flatMap { $0 })
        #expect(tripletPitchesFlat.contains(60))
        #expect(tripletPitchesFlat.contains(62))
        #expect(tripletPitchesFlat.contains(64))
    }

    @Test func crossBarNoteEmitsTieAcrossBar() {
        // Two adjacent measures of 4/4 (1920 ticks each). A note starts
        // at tick 0 (measure 0), ends at tick 3000 (measure 1, partway).
        let crossing = CarriedNote(
            pitch: 60, channel: 0, sourceMeasureIndex: 0,
            noteOnTick: 0, noteOffTick: 3000
        )
        let m1 = ImportMeasure(
            startTick: 0, endTick: 1920, measureIndex: 0,
            timeSignature: TimeSignature(numerator: 4, denominator: 4),
            events: [
                TimedMidiEvent(tick: 0, event: .noteOn(channel: 0, pitch: 60, velocity: 80)),
                TimedMidiEvent(tick: 1920, event: .endOfTrack),
            ],
            carryIns: [],
            carryOuts: [crossing]
        )
        let m2 = ImportMeasure(
            startTick: 1920, endTick: 3840, measureIndex: 1,
            timeSignature: TimeSignature(numerator: 4, denominator: 4),
            events: [
                TimedMidiEvent(tick: 3000, event: .noteOff(channel: 0, pitch: 60, velocity: 0)),
            ],
            carryIns: [crossing],
            carryOuts: []
        )

        let v1 = MidiImporter.voice(
            quantized: MidiImporter.quantize(measure: m1, division: 480, options: .init()),
            measure: m1, division: 480
        )
        let v2 = MidiImporter.voice(
            quantized: MidiImporter.quantize(measure: m2, division: 480, options: .init()),
            measure: m2, division: 480
        )

        // Last chord of m1: tieForward set on pitch 60.
        guard let lastM1 = v1.elements.last else {
            Issue.record("expected chord at end of m1")
            return
        }
        if case let .chord(c) = lastM1 {
            let n = c.notes.first(where: { $0.pitch == 60 })
            #expect(n != nil)
            #expect(n?.tieForward == 1)
        } else {
            Issue.record("expected chord at end of m1")
        }
        // First chord of m2: tieBack set on pitch 60.
        guard let firstM2 = v2.elements.first else {
            Issue.record("expected chord at start of m2")
            return
        }
        if case let .chord(c) = firstM2 {
            let n = c.notes.first(where: { $0.pitch == 60 })
            #expect(n != nil)
            #expect(n?.tieBack == 1)
        } else {
            Issue.record("expected chord at start of m2")
        }
    }
}
