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

    /// A Format 0 file (or any single MTrk carrying several channels)
    /// where multiple *melodic* channels share one physical track must
    /// yield one pitched `ImportTrack` per channel — otherwise every
    /// melodic voice collapses onto a single staff.
    @Test func splitsMultipleMelodicChannelsInOneTrack() {
        let track = MidiTrack(events: [
            noteOn(0, channel: 0, pitch: 60),
            noteOn(0, channel: 1, pitch: 64),
            noteOn(0, channel: 2, pitch: 67),
            noteOn(0, channel: 9, pitch: 36),
            noteOff(240, channel: 0, pitch: 60),
            noteOff(240, channel: 1, pitch: 64),
            noteOff(240, channel: 2, pitch: 67),
            noteOff(240, channel: 9, pitch: 36),
            TimedMidiEvent(tick: 240, event: .endOfTrack),
        ])
        let file = MidiFile(division: 480, format: 0, tracks: [track])
        let imports = MidiImporter.partition(file)
        let pitched = imports.filter { !$0.isDrums }
        let drums = imports.filter(\.isDrums)
        #expect(pitched.count == 3)
        #expect(drums.count == 1)
        #expect(Set(pitched.compactMap(\.channel)) == [0, 1, 2])
    }

    /// End-to-end: a multi-channel Format 0 track becomes separate
    /// Parts (one staff each) with unique part ids, rather than one
    /// melodic staff with every channel overlaid.
    @Test func format0MultiChannelProducesSeparateParts() throws {
        let track = MidiTrack(events: [
            noteOn(0, channel: 0, pitch: 60),
            noteOn(0, channel: 1, pitch: 64),
            noteOn(0, channel: 9, pitch: 36),
            noteOff(1920, channel: 0, pitch: 60),
            noteOff(1920, channel: 1, pitch: 64),
            noteOff(1920, channel: 9, pitch: 36),
            TimedMidiEvent(tick: 1920, event: .endOfTrack),
        ])
        let file = MidiFile(division: 480, format: 0, tracks: [track])
        let score = try MidiImporter.assembleSync(
            file: file, options: .init(), sourceFilename: nil,
        )
        let melodic = score.parts.filter { !$0.instrument.useDrumset }
        let drums = score.parts.filter(\.instrument.useDrumset)
        #expect(melodic.count == 2)
        #expect(drums.count == 1)
        // Part ids stay unique even though every slice came from SMF track 0.
        #expect(Set(score.parts.map(\.id)).count == score.parts.count)
        #expect(score.parts.allSatisfy { $0.staves.count == 1 })
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
