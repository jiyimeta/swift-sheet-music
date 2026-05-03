import Foundation
@testable import SheetMusicCore
@testable import SheetMusicMIDI
import Testing

@Suite struct MidiImporterDrumTests {
    @Test func drumTrackPopulatesHeadTypeForCrossNotehead() {
        // Pitch 42 = closed hi-hat → "cross" notehead.
        let measure = ImportMeasure(
            startTick: 0, endTick: 480, measureIndex: 0,
            timeSignature: TimeSignature(numerator: 1, denominator: 4),
            events: [
                TimedMidiEvent(tick: 0, event: .noteOn(channel: 9, pitch: 42, velocity: 80)),
                TimedMidiEvent(tick: 240, event: .noteOff(channel: 9, pitch: 42, velocity: 0)),
            ],
            carryIns: [], carryOuts: []
        )
        let q = MidiImporter.quantize(measure: measure, division: 480, options: .init())
        let voice = MidiImporter.voice(
            quantized: q, measure: measure, division: 480, isDrumTrack: true
        )
        if case let .chord(c) = voice.elements.first {
            #expect(c.notes.first?.headType == "cross")
        } else {
            Issue.record("expected first chord")
        }
    }

    @Test func drumTrackPopulatesHeadTypeForBassDrum() {
        // Pitch 35 = acoustic bass drum → "normal" notehead.
        let measure = ImportMeasure(
            startTick: 0, endTick: 480, measureIndex: 0,
            timeSignature: TimeSignature(numerator: 1, denominator: 4),
            events: [
                TimedMidiEvent(tick: 0, event: .noteOn(channel: 9, pitch: 35, velocity: 80)),
                TimedMidiEvent(tick: 240, event: .noteOff(channel: 9, pitch: 35, velocity: 0)),
            ],
            carryIns: [], carryOuts: []
        )
        let q = MidiImporter.quantize(measure: measure, division: 480, options: .init())
        let voice = MidiImporter.voice(
            quantized: q, measure: measure, division: 480, isDrumTrack: true
        )
        if case let .chord(c) = voice.elements.first {
            #expect(c.notes.first?.headType == "normal")
        } else {
            Issue.record("expected first chord")
        }
    }

    @Test func nonDrumTrackLeavesHeadTypeNil() {
        let measure = ImportMeasure(
            startTick: 0, endTick: 480, measureIndex: 0,
            timeSignature: TimeSignature(numerator: 1, denominator: 4),
            events: [
                TimedMidiEvent(tick: 0, event: .noteOn(channel: 0, pitch: 60, velocity: 80)),
                TimedMidiEvent(tick: 240, event: .noteOff(channel: 0, pitch: 60, velocity: 0)),
            ],
            carryIns: [], carryOuts: []
        )
        let q = MidiImporter.quantize(measure: measure, division: 480, options: .init())
        let voice = MidiImporter.voice(quantized: q, measure: measure, division: 480)
        if case let .chord(c) = voice.elements.first {
            #expect(c.notes.first?.headType == nil)
        }
    }
}
