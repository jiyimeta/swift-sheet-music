import Foundation
@testable import SheetMusicCore
@testable import SheetMusicMIDI
import Testing

struct MidiImporterBarTests {
    private func tn(_ name: String) -> TimedMidiEvent {
        TimedMidiEvent(tick: 0, event: .meta(.trackName(name)))
    }

    private func ts(_ tick: Int, _ n: Int, _ d: Int) -> TimedMidiEvent {
        TimedMidiEvent(tick: tick, event: .meta(.timeSignature(
            numerator: n, denominator: d, clocksPerClick: 24, thirtySecondsPerQuarter: 8,
        )))
    }

    private func nOn(_ tick: Int, _ pitch: Int) -> TimedMidiEvent {
        TimedMidiEvent(tick: tick, event: .noteOn(channel: 0, pitch: pitch, velocity: 80))
    }

    private func nOff(_ tick: Int, _ pitch: Int) -> TimedMidiEvent {
        TimedMidiEvent(tick: tick, event: .noteOff(channel: 0, pitch: pitch, velocity: 0))
    }

    @Test func defaultsToFourFour() {
        let imports = [ImportTrack(
            trackIndex: 0, trackName: "P", isDrums: false,
            programChange: nil,
            events: [
                nOn(0, 60), nOff(1920, 60),
                TimedMidiEvent(tick: 1920, event: .endOfTrack),
            ],
        )]
        let measures = MidiImporter.segmentBars(imports: imports, division: 480)
        // 1920 ticks at 480 PPQ in 4/4 = 1 measure (1920 = 4*480).
        // The note ends exactly at the bar line, so 1 measure suffices.
        #expect(measures[0].count == 1)
        #expect(measures[0][0].timeSignature == TimeSignature(numerator: 4, denominator: 4))
    }

    @Test func splitsAtTimeSignatureChange() {
        let imports = [ImportTrack(
            trackIndex: 0, trackName: "P", isDrums: false,
            programChange: nil,
            events: [
                ts(0, 4, 4),
                nOn(0, 60), nOff(1920, 60),
                ts(1920, 3, 4),
                nOn(1920, 62), nOff(1920 + 1440, 62),
                TimedMidiEvent(tick: 1920 + 1440, event: .endOfTrack),
            ],
        )]
        let measures = MidiImporter.segmentBars(imports: imports, division: 480)
        // 1 measure of 4/4 + 1 measure of 3/4 = 2 measures.
        #expect(measures[0].count == 2)
        #expect(measures[0][1].timeSignature == TimeSignature(numerator: 3, denominator: 4))
    }

    @Test func detectsCarryAcrossBars() {
        let imports = [ImportTrack(
            trackIndex: 0, trackName: "P", isDrums: false,
            programChange: nil,
            events: [
                // noteOn at tick 0, noteOff at tick 2400 — crosses
                // the 4/4 bar line at 1920 into measure 1.
                nOn(0, 60), nOff(2400, 60),
                TimedMidiEvent(tick: 2400, event: .endOfTrack),
            ],
        )]
        let measures = MidiImporter.segmentBars(imports: imports, division: 480)
        #expect(measures[0].count >= 2)
        #expect(measures[0][0].carryOuts.count == 1)
        #expect(measures[0][1].carryIns.count == 1)
        #expect(measures[0][1].carryIns[0].pitch == 60)
    }

    @Test func emptyImportProducesSingleDefaultBar() {
        let measures = MidiImporter.segmentBars(imports: [], division: 480)
        #expect(measures.isEmpty)
    }

    /// A Format 1 file keeps its meter on the conductor track — track 0, meta events only — which yields no
    /// `ImportTrack` of its own. The bar lengths still have to follow it: MuseScore builds its time-signature map from
    /// every track's meta events (`createMTrackList`). Reading only the note tracks cut a 3/4 piece into 4/4 bars
    /// (1920 + 960 ticks for two bars of 3/4) under a "3/4" signature.
    @Test func conductorTrackMeterSetsTheBarLength() throws {
        let conductor = MidiTrack(events: [ts(0, 3, 4), TimedMidiEvent(tick: 2880, event: .endOfTrack)])
        let piano = MidiTrack(events: [
            nOn(0, 60), nOff(1440, 60), nOn(1440, 62), nOff(2880, 62),
            TimedMidiEvent(tick: 2880, event: .endOfTrack),
        ])
        let file = MidiFile(division: 480, format: 1, tracks: [conductor, piano])
        let score = try MidiImporter.parse(MidiWriter.write(file))
        let lengths = score.parts[0].staves[0].measures.map { measure in
            measure.voices[0].elements.reduce(0) { $0 + ($1.tickCount(division: 480) ?? 0) }
        }
        #expect(lengths == [1440, 1440])
    }
}
