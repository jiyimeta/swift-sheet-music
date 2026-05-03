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
}
