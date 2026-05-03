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

    @Test func drumPartGetsPercussionStaffDeclarationAndDrumLineMap() throws {
        // End-to-end: a drum-only track produces a Part with the
        // `group: "percussion"`, `defaultClefType: "PERC"` staff
        // declaration so the layout picks the percussion clef, plus
        // a fully populated `drumLineMap` so each GM pitch lands on
        // its conventional staff line.
        let track0 = MidiTrack(events: [
            TimedMidiEvent(tick: 0, event: .meta(.trackName("Conductor"))),
            TimedMidiEvent(tick: 0, event: .meta(.timeSignature(
                numerator: 4, denominator: 4, clocksPerClick: 24, thirtySecondsPerQuarter: 8
            ))),
            TimedMidiEvent(tick: 480, event: .endOfTrack),
        ])
        let track1 = MidiTrack(events: [
            TimedMidiEvent(tick: 0, event: .meta(.trackName("Drums"))),
            TimedMidiEvent(tick: 0, event: .noteOn(channel: 9, pitch: 36, velocity: 100)),
            TimedMidiEvent(tick: 240, event: .noteOff(channel: 9, pitch: 36, velocity: 0)),
            TimedMidiEvent(tick: 240, event: .noteOn(channel: 9, pitch: 38, velocity: 100)),
            TimedMidiEvent(tick: 480, event: .noteOff(channel: 9, pitch: 38, velocity: 0)),
            TimedMidiEvent(tick: 480, event: .endOfTrack),
        ])
        let file = MidiFile(division: 480, format: 1, tracks: [track0, track1])
        let bytes = try MidiWriter.write(file)
        let score = try MidiImporter.parse(bytes)

        guard let drums = score.parts.first(where: { $0.instrument.useDrumset }) else {
            Issue.record("expected a drumset part"); return
        }
        // Staff declaration drives the layout's clef pick.
        let decl = drums.staffDeclarations.first
        #expect(decl?.group == "percussion")
        #expect(decl?.defaultClefType == "PERC")
        // drumLineMap covers the GM pitches used.
        #expect(drums.instrument.drumLineMap[36] != nil) // bass drum
        #expect(drums.instrument.drumLineMap[38] != nil) // snare
        #expect(drums.instrument.drumLineMap[42] != nil) // closed hi-hat
        #expect(drums.instrument.drumLineMap[49] != nil) // crash
        // Bass below snare (i.e. larger line index = lower).
        if let bass = drums.instrument.drumLineMap[36],
           let snare = drums.instrument.drumLineMap[38]
        {
            #expect(bass > snare)
        }
        // Crash above the staff (negative line index in our convention).
        if let crash = drums.instrument.drumLineMap[49] {
            #expect(crash < 0)
        }
    }
}
