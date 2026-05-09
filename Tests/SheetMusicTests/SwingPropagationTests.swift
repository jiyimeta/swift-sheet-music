import Foundation
@testable import SheetMusicCore
@testable import SheetMusicMIDI
import Testing

/// Cross-staff propagation of `Swing` directives, mirroring MuseScore's
/// `Score::updateSwing` (score.cpp:6081):
/// - SystemText-flagged swing fans out into every staff's swing list.
/// - Staff-flagged swing stays on its owning staff.
@Suite("MIDI Swing propagation")
struct MidiSwingPropagationTests {
    private func twoStaffOneMeasureScore(
        firstSwing: Swing
    ) -> Score {
        var style = ScoreStyle.museScoreDefaults
        style.swingUnit = .off
        // Staff 0 carries the swing marker at tick 0.
        let voice0 = Voice(elements: [
            .swing(firstSwing),
            .chord(Chord(
                duration: .eighth,
                notes: ChordNotes([Note(pitch: 60, tpc: 14)])
            )),
            .chord(Chord(
                duration: .eighth,
                notes: ChordNotes([Note(pitch: 60, tpc: 14)])
            )),
        ])
        let staff0 = Staff(
            staffType: "stdNormal", group: "pitched", defaultClefType: nil,
            measures: [Measure(voices: [voice0])]
        )
        // Staff 1 has no swing element of its own.
        let voice1 = Voice(elements: [
            .chord(Chord(
                duration: .eighth,
                notes: ChordNotes([Note(pitch: 64, tpc: 18)])
            )),
            .chord(Chord(
                duration: .eighth,
                notes: ChordNotes([Note(pitch: 64, tpc: 18)])
            )),
        ])
        let staff1 = Staff(
            staffType: "stdNormal", group: "pitched", defaultClefType: nil,
            measures: [Measure(voices: [voice1])]
        )
        let part = Part(
            id: "1", trackName: "V",
            instrument: Instrument(id: "voice"),
            staves: [staff0, staff1]
        )
        return Score(division: 480, parts: [part], style: style)
    }

    private func noteOnTicks(_ track: MidiTrack) -> [Int] {
        track.events.compactMap { ev -> Int? in
            if case .noteOn = ev.event { return ev.tick }
            return nil
        }
    }

    @Test("SystemText swing in one staff propagates to every staff")
    func systemTextSwingPropagatesAcrossStaves() throws {
        let score = twoStaffOneMeasureScore(
            firstSwing: Swing(unit: .eighth, ratio: 60, isSystemText: true)
        )
        let midi = try MidiRenderer.render(score: score)
        // Both staves: down-beat at 0 stays, up-beat at 240 shifts +48
        // (480 * 10 / 100). Without propagation staff 1 would stay at
        // [0, 240] (straight).
        #expect(noteOnTicks(midi.tracks[0]) == [0, 288])
        #expect(noteOnTicks(midi.tracks[1]) == [0, 288])
    }

    @Test("Staff-flagged swing stays on its owning staff")
    func staffFlaggedSwingDoesNotPropagate() throws {
        let score = twoStaffOneMeasureScore(
            firstSwing: Swing(unit: .eighth, ratio: 60, isSystemText: false)
        )
        let midi = try MidiRenderer.render(score: score)
        #expect(noteOnTicks(midi.tracks[0]) == [0, 288])
        #expect(noteOnTicks(midi.tracks[1]) == [0, 240])
    }
}
