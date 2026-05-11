import Foundation
@testable import SheetMusicCore
@testable import SheetMusicMIDI
import Testing

struct MidiImporterTracksTests {
    private func noteOn(_ tick: Int, channel: Int, pitch: Int) -> TimedMidiEvent {
        TimedMidiEvent(
            tick: tick, event: .noteOn(channel: channel, pitch: pitch, velocity: 80),
        )
    }

    private func noteOff(_ tick: Int, channel: Int, pitch: Int) -> TimedMidiEvent {
        TimedMidiEvent(
            tick: tick, event: .noteOff(channel: channel, pitch: pitch, velocity: 0),
        )
    }

    @Test func splitsMixedDrumAndPitchedIntoTwoTracks() {
        let track = MidiTrack(events: [
            TimedMidiEvent(tick: 0, event: .meta(.trackName("Mixed"))),
            noteOn(0, channel: 0, pitch: 60),
            noteOn(0, channel: 9, pitch: 36),
            noteOff(240, channel: 0, pitch: 60),
            noteOff(240, channel: 9, pitch: 36),
            TimedMidiEvent(tick: 240, event: .endOfTrack),
        ])
        let file = MidiFile(division: 480, format: 1, tracks: [track])
        let imports = MidiImporter.partition(file)
        #expect(imports.count == 2)
        #expect(imports.contains(where: { $0.isDrums && $0.trackName == "Mixed (drums)" }))
        #expect(imports.contains(where: { !$0.isDrums && $0.trackName == "Mixed" }))
    }

    @Test func skipsTracksWithOnlyMeta() {
        let metaOnly = MidiTrack(events: [
            TimedMidiEvent(tick: 0, event: .meta(.trackName("Tempo Map"))),
            TimedMidiEvent(tick: 0, event: .meta(.tempo(microsecondsPerQuarter: 500_000))),
            TimedMidiEvent(tick: 0, event: .endOfTrack),
        ])
        let withNotes = MidiTrack(events: [
            TimedMidiEvent(tick: 0, event: .meta(.trackName("Piano"))),
            noteOn(0, channel: 0, pitch: 60),
            noteOff(240, channel: 0, pitch: 60),
            TimedMidiEvent(tick: 240, event: .endOfTrack),
        ])
        let file = MidiFile(division: 480, format: 1, tracks: [metaOnly, withNotes])
        let imports = MidiImporter.partition(file)
        #expect(imports.count == 1)
        #expect(imports[0].trackName == "Piano")
        #expect(imports[0].trackIndex == 1)
    }

    @Test func format0SplitsByChannel() {
        let track = MidiTrack(events: [
            noteOn(0, channel: 0, pitch: 60),
            noteOn(0, channel: 9, pitch: 36),
            noteOff(240, channel: 0, pitch: 60),
            noteOff(240, channel: 9, pitch: 36),
            TimedMidiEvent(tick: 240, event: .endOfTrack),
        ])
        let file = MidiFile(division: 480, format: 0, tracks: [track])
        let imports = MidiImporter.partition(file)
        #expect(imports.count == 2)
    }

    @Test func drumOnlyTrackProducesOneDrumImport() {
        let track = MidiTrack(events: [
            TimedMidiEvent(tick: 0, event: .meta(.trackName("Drums"))),
            noteOn(0, channel: 9, pitch: 36),
            noteOff(240, channel: 9, pitch: 36),
            TimedMidiEvent(tick: 240, event: .endOfTrack),
        ])
        let file = MidiFile(division: 480, format: 1, tracks: [track])
        let imports = MidiImporter.partition(file)
        #expect(imports.count == 1)
        #expect(imports[0].isDrums == true)
        #expect(imports[0].trackName == "Drums")
    }

    @Test func capturesFirstProgramChange() {
        let track = MidiTrack(events: [
            TimedMidiEvent(tick: 0, event: .programChange(channel: 0, program: 24)),
            noteOn(0, channel: 0, pitch: 60),
            noteOff(240, channel: 0, pitch: 60),
            TimedMidiEvent(tick: 240, event: .endOfTrack),
        ])
        let file = MidiFile(division: 480, format: 1, tracks: [track])
        let imports = MidiImporter.partition(file)
        #expect(imports[0].programChange == 24)
    }
}
