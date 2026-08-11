import Foundation
@testable import SheetMusicCore
@testable import SheetMusicMIDI
import Testing

/// A performance's recorded noteOn velocities must survive import as
/// per-note overrides. The import path emits no `Dynamic`s, so this is
/// the only thing standing between an expressive MIDI file and a score
/// where every note sits at the default mezzo-forte.
/// C++: `setMusicNotesFromMidi` (`importmidi.cpp`) calls
/// `note->setUserVelocity(mn.velo)` on every imported note.
struct MidiImporterVelocityTests {
    private func nOn(_ tick: Int, _ pitch: Int, _ velocity: Int) -> TimedMidiEvent {
        TimedMidiEvent(
            tick: tick, event: .noteOn(channel: 0, pitch: pitch, velocity: velocity),
        )
    }

    private func nOff(_ tick: Int, _ pitch: Int) -> TimedMidiEvent {
        TimedMidiEvent(tick: tick, event: .noteOff(channel: 0, pitch: pitch, velocity: 0))
    }

    private func voice(
        events: [TimedMidiEvent],
        carryIns: [CarriedNote] = [],
        carryOuts: [CarriedNote] = [],
        endTick: Int = 480,
    ) -> Voice {
        let measure = ImportMeasure(
            startTick: 0, endTick: endTick, measureIndex: 0,
            timeSignature: TimeSignature(numerator: 1, denominator: 4),
            events: events,
            carryIns: carryIns, carryOuts: carryOuts,
        )
        let quantized = MidiImporter.quantize(
            measure: measure, division: 480, options: .init(),
        )
        return MidiImporter.voice(quantized: quantized, measure: measure, division: 480)
    }

    private func notes(in voice: Voice, at index: Int) -> [Note] {
        guard case let .chord(chord) = voice.elements[index] else { return [] }
        return Array(chord.notes)
    }

    @Test func recordedVelocityBecomesAnAbsolutePerNoteOverride() {
        let imported = voice(events: [nOn(0, 60, 112), nOff(480, 60)])
        let note = notes(in: imported, at: 0).first
        #expect(note?.userVelocity == 112)
        #expect(note?.velocityType == .user)
    }

    /// Simultaneous notes routinely differ in velocity (a voiced chord,
    /// a drum hit layered under a rimshot) — the override is per note,
    /// not per chord.
    @Test func notesOfOneChordKeepTheirIndividualVelocities() {
        let imported = voice(events: [
            nOn(0, 60, 100), nOn(0, 64, 40),
            nOff(480, 60), nOff(480, 64),
        ])
        let chordNotes = notes(in: imported, at: 0)
        #expect(chordNotes.first { $0.pitch == 60 }?.userVelocity == 100)
        #expect(chordNotes.first { $0.pitch == 64 }?.userVelocity == 40)
    }

    /// A note whose noteOff lands after another's splits into two tied
    /// chords. Both parts describe one sounding note, so both carry the
    /// velocity that struck it.
    @Test func tiedContinuationsInheritTheAttackVelocity() {
        let imported = voice(events: [
            nOn(0, 60, 96), nOn(0, 64, 96), nOff(240, 64), nOff(480, 60),
        ])
        #expect(notes(in: imported, at: 0).first { $0.pitch == 60 }?.userVelocity == 96)
        #expect(notes(in: imported, at: 1).first { $0.pitch == 60 }?.userVelocity == 96)
    }

    /// A note held across a bar line reaches the following measure as a
    /// `carryIn`, which has no noteOn of its own to read.
    @Test func notesCarriedAcrossABarLineKeepTheirVelocity() {
        let carried = CarriedNote(
            pitch: 60, channel: 0, sourceMeasureIndex: 0,
            noteOnTick: -480, noteOffTick: 240, velocity: 55,
        )
        let imported = voice(events: [nOff(240, 60)], carryIns: [carried])
        let note = notes(in: imported, at: 0).first { $0.pitch == 60 }
        #expect(note?.userVelocity == 55)
        #expect(note?.tieBack == 1)
    }

    /// End to end: render a score whose notes carry overrides, write it
    /// as an SMF, import it back, and re-render. The velocities must
    /// come back rather than collapsing to the default dynamic.
    @Test func velocitiesSurviveARenderImportRenderRoundTrip() throws {
        let score = Score(division: 480, parts: [Part(
            id: "P1",
            instrument: Instrument(id: "piano", longName: "Piano"),
            staves: [Staff(measures: [Measure(voices: [Voice(elements: [
                .chord(Chord(duration: .quarter, notes: ChordNotes([
                    Note(pitch: 60, tpc: 14, userVelocity: 112),
                ]))),
                .chord(Chord(duration: .quarter, notes: ChordNotes([
                    Note(pitch: 62, tpc: 16, userVelocity: 33),
                ]))),
            ])])])],
        )])
        let smf = try MidiWriter.write(MidiRenderer.render(score: score))
        let imported = try MidiImporter.parse(smf)
        let reRendered = try MidiRenderer.render(score: imported)
        var velocities: [Int: Int] = [:]
        for event in reRendered.tracks.flatMap(\.events) {
            if case let .noteOn(_, pitch, velocity) = event.event, velocity > 0 {
                velocities[pitch] = velocity
            }
        }
        #expect(velocities[60] == 112)
        #expect(velocities[62] == 33)
    }
}
