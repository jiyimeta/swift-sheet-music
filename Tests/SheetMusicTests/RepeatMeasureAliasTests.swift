import Foundation
@testable import SheetMusicCore
@testable import SheetMusicMIDI
@testable import SheetMusicMSCX
@testable import SheetMusicXMLTools
import Testing

/// MuseScore 3.x spells the single-measure-repeat marker `<RepeatMeasure>`,
/// while 4.x uses `<MeasureRepeat>`. The reader treats them as aliases
/// (`MeasureRead::readVoice` in `measureread.cpp:336`). We must recognise both
/// or 3.x scores end up with silent measures where they should replay the prior bar.
struct RepeatMeasureAliasTests {
    @Test func parsesRepeatMeasureAsMeasureRepeat() throws {
        // Exact shape from a MuseScore 3.x export: <RepeatMeasure> with no
        // <subtype> (defaults to numMeasures=1) and a measure-duration body.
        let xml = """
        <voice>
          <RepeatMeasure>
            <linked></linked>
            <durationType>measure</durationType>
            <duration>4/4</duration>
          </RepeatMeasure>
        </voice>
        """
        let voice = try Voice.decode(XMLTreeParser.parse(Data(xml.utf8)))
        #expect(voice.elements.count == 1)
        guard case let .measureRepeat(rep) = voice.elements[0] else {
            Issue.record("expected .measureRepeat, got \(voice.elements)")
            return
        }
        #expect(rep.numMeasures == 1)
        #expect(rep.duration == .measure)
    }

    /// MuseScore replays ALL voices of the source measure when ANY voice
    /// carries a measure-repeat marker. Mirrors the per-staff (not per-voice)
    /// detection at `compatmidirenderinternal.cpp:1314`. Without this, scores
    /// where the marker only lives in voice 0 lose voice 1's notes.
    @Test func repeatMeasureMarker_replaysEveryVoice() throws {
        let instrument = Instrument(id: "test", articulations: [InstrumentArticulation()])
        // Source measure has TWO voices.
        let sourceVoice0 = Voice(elements: [
            .chord(Chord(duration: .half, notes: [Note(pitch: 60, tpc: 14)])),
            .chord(Chord(duration: .half, notes: [Note(pitch: 62, tpc: 16)])),
        ])
        let sourceVoice1 = Voice(elements: [
            .chord(Chord(duration: .half, notes: [Note(pitch: 72, tpc: 14)])),
            .chord(Chord(duration: .half, notes: [Note(pitch: 74, tpc: 16)])),
        ])
        let sourceMeasure = Measure(voices: [sourceVoice0, sourceVoice1])
        // Repeat measure has only voice 0 carrying the marker. Voice 1 is absent
        // entirely — yet MuseScore still replays voice 1 of the source.
        let markerVoice = Voice(elements: [
            .measureRepeat(MeasureRepeat(
                numMeasures: 1,
                duration: .fraction(Fraction(numerator: 4, denominator: 4)),
            )),
        ])
        let repeatMeasure = Measure(voices: [markerVoice])
        let staff = Staff(measures: [sourceMeasure, repeatMeasure])
        let part = Part(id: "P1", instrument: instrument, staves: [staff])
        let score = Score(division: 480, parts: [part])
        let file = try MidiRenderer.render(score: score)
        let track = try #require(file.tracks.first)
        let pitches = track.events.compactMap { ev -> Int? in
            if case let .noteOn(_, pitch, vel) = ev.event, vel > 0 { return pitch }
            return nil
        }.sorted()
        // Source: 60, 62, 72, 74. Replay measure: another 60, 62, 72, 74.
        #expect(pitches == [60, 60, 62, 62, 72, 72, 74, 74])
    }

    /// Mirror image of the above: marker lives in voice 1, voice 0 is silent
    /// in the marker measure. Both voices of the source must still play.
    @Test func repeatMeasureMarker_inSecondaryVoice_stillReplaysAll() throws {
        let instrument = Instrument(id: "test", articulations: [InstrumentArticulation()])
        let sourceVoice0 = Voice(elements: [
            .chord(Chord(duration: .whole, notes: [Note(pitch: 60, tpc: 14)])),
        ])
        let sourceVoice1 = Voice(elements: [
            .chord(Chord(duration: .whole, notes: [Note(pitch: 72, tpc: 14)])),
        ])
        let sourceMeasure = Measure(voices: [sourceVoice0, sourceVoice1])
        let emptyVoice0 = Voice(elements: [])
        let markerVoice1 = Voice(elements: [
            .measureRepeat(MeasureRepeat(
                numMeasures: 1,
                duration: .fraction(Fraction(numerator: 4, denominator: 4)),
            )),
        ])
        let repeatMeasure = Measure(voices: [emptyVoice0, markerVoice1])
        let staff = Staff(measures: [sourceMeasure, repeatMeasure])
        let part = Part(id: "P1", instrument: instrument, staves: [staff])
        let score = Score(division: 480, parts: [part])
        let file = try MidiRenderer.render(score: score)
        let track = try #require(file.tracks.first)
        let pitches = track.events.compactMap { ev -> Int? in
            if case let .noteOn(_, pitch, vel) = ev.event, vel > 0 { return pitch }
            return nil
        }.sorted()
        // Source: 60, 72. Replay: 60, 72.
        #expect(pitches == [60, 60, 72, 72])
    }

    /// Two-measure repeat group (`<MeasureRepeat><subtype>2</subtype>`): the
    /// marker only appears in one voice of one of the group's measures, but
    /// every voice of the source two-measure span must replay.
    @Test func multiMeasureRepeatGroup_replaysAllVoicesAcrossGroup() throws {
        let instrument = Instrument(id: "test", articulations: [InstrumentArticulation()])
        // Two source measures, each two voices.
        let m1v0 = Voice(elements: [.chord(Chord(duration: .whole, notes: [Note(pitch: 60, tpc: 14)]))])
        let m1v1 = Voice(elements: [.chord(Chord(duration: .whole, notes: [Note(pitch: 72, tpc: 14)]))])
        let m2v0 = Voice(elements: [.chord(Chord(duration: .whole, notes: [Note(pitch: 64, tpc: 18)]))])
        let m2v1 = Voice(elements: [.chord(Chord(duration: .whole, notes: [Note(pitch: 76, tpc: 18)]))])
        let m1 = Measure(voices: [m1v0, m1v1])
        let m2 = Measure(voices: [m2v0, m2v1])
        // Two-measure repeat group: marker in voice 0 of measure 4 (the 2nd
        // member of the group); both members carry measureRepeatCount.
        let m3 = Measure(
            voices: [Voice(elements: []), Voice(elements: [])],
            measureRepeatCount: 1,
        )
        let m4MarkerVoice = Voice(elements: [
            .measureRepeat(MeasureRepeat(
                numMeasures: 2,
                duration: .fraction(Fraction(numerator: 4, denominator: 4)),
            )),
        ])
        let m4 = Measure(
            voices: [m4MarkerVoice, Voice(elements: [])],
            measureRepeatCount: 2,
        )
        let staff = Staff(measures: [m1, m2, m3, m4])
        let part = Part(id: "P1", instrument: instrument, staves: [staff])
        let score = Score(division: 480, parts: [part])
        let file = try MidiRenderer.render(score: score)
        let track = try #require(file.tracks.first)
        let pitches = track.events.compactMap { ev -> Int? in
            if case let .noteOn(_, pitch, vel) = ev.event, vel > 0 { return pitch }
            return nil
        }.sorted()
        // Source pitches once: 60, 64, 72, 76. Replay (m3+m4): again 60, 64, 72, 76.
        #expect(pitches == [60, 60, 64, 64, 72, 72, 76, 76])
    }

    /// End-to-end: a measure containing only a `<RepeatMeasure>` marker should
    /// replay the previous measure's notes when rendered to MIDI.
    @Test func repeatMeasureMarker_replaysPreviousMeasureNotes() throws {
        let instrument = Instrument(id: "test", articulations: [InstrumentArticulation()])
        // Measure 1: a single quarter note at pitch 60.
        let sourceVoice = Voice(elements: [
            .chord(Chord(duration: .quarter, notes: [Note(pitch: 60, tpc: 14)])),
            .chord(Chord(duration: .quarter, notes: [Note(pitch: 62, tpc: 16)])),
            .chord(Chord(duration: .quarter, notes: [Note(pitch: 64, tpc: 18)])),
            .chord(Chord(duration: .quarter, notes: [Note(pitch: 65, tpc: 13)])),
        ])
        let sourceMeasure = Measure(voices: [sourceVoice])
        // Measure 2: a single <MeasureRepeat> marker spanning the whole measure.
        let repeatVoice = Voice(elements: [
            .measureRepeat(MeasureRepeat(
                numMeasures: 1,
                duration: .fraction(Fraction(numerator: 4, denominator: 4)),
            )),
        ])
        let repeatMeasure = Measure(voices: [repeatVoice])
        let staff = Staff(measures: [sourceMeasure, repeatMeasure])
        let part = Part(id: "P1", instrument: instrument, staves: [staff])
        let score = Score(division: 480, parts: [part])
        let file = try MidiRenderer.render(score: score)
        let track = try #require(file.tracks.first)

        // Expect 8 note-ons total: 4 from the source, 4 replayed in the next bar.
        let noteOns = track.events.compactMap { ev -> (tick: Int, pitch: Int)? in
            if case let .noteOn(_, pitch, vel) = ev.event, vel > 0 { return (ev.tick, pitch) }
            return nil
        }
        #expect(noteOns.count == 8)
        #expect(noteOns.map(\.pitch) == [60, 62, 64, 65, 60, 62, 64, 65])
        // Replay measure starts one whole-measure later (4 quarters * 480 = 1920).
        #expect(noteOns[4].tick == 1920)
    }
}
