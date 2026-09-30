@testable import SheetMusicCore
import Testing

@Suite("Instrument.drumset")
struct InstrumentDrumsetTests {
    @Test("a line map assigned to an empty kit gets the GM head, name and voice for each pitch")
    func lineMapAssignmentFillsFromGM() {
        var instrument = Instrument(id: "drumset", useDrumset: true)
        instrument.drumLineMap = [38: 2, 42: -1]
        #expect(instrument.drumset.count == 2)
        #expect(instrument.drumset[38]?.line == 2)
        #expect(instrument.drumset[38]?.head == "normal")
        #expect(instrument.drumset[38]?.name == "Acoustic Snare")
        #expect(instrument.drumset[42]?.head == "cross")
        #expect(instrument.drumset[42]?.voiceIndex == 0)
    }

    @Test("drumLineMap reads back the lines it was given")
    func lineMapRoundTrips() {
        var instrument = Instrument(id: "drumset", useDrumset: true)
        instrument.drumLineMap = GMPercussion.drumLineMap
        #expect(instrument.drumLineMap == GMPercussion.drumLineMap)
    }

    @Test("a kit built from GMDrumset reads back the GM lines")
    func gmKitReadsBackGMLines() {
        let instrument = Instrument(id: "drumset", useDrumset: true, drumset: GMDrumset.entries)
        #expect(instrument.drumLineMap == GMPercussion.drumLineMap)
    }

    @Test("assigning drumLineMap moves a drum's line and keeps everything else about it")
    func assigningKeepsTheRest() {
        var instrument = Instrument(id: "drumset", useDrumset: true, drumset: [
            51: DrumsetEntry(name: "Ride", head: "diamond", line: 0, voiceIndex: 0, stem: 1, shortcut: "R"),
        ])
        instrument.drumLineMap = [51: 3]
        #expect(instrument.drumset[51]?.line == 3)
        #expect(instrument.drumset[51]?.head == "diamond")
        #expect(instrument.drumset[51]?.name == "Ride")
        #expect(instrument.drumset[51]?.shortcut == "R")
    }

    @Test("assigning drumLineMap drops the pitches the new map does not name")
    func assigningReplacesWholesale() {
        var instrument = Instrument(id: "drumset", useDrumset: true, drumset: [
            38: GMDrumset.entry(forPitch: 38, line: 2),
            42: GMDrumset.entry(forPitch: 42, line: -1),
        ])
        instrument.drumLineMap = [38: 2]
        #expect(Set(instrument.drumset.keys) == [38])
    }

    @Test("a pitched instrument has an empty kit")
    func pitchedIsEmpty() {
        let instrument = Instrument(id: "flute")
        #expect(instrument.drumset.isEmpty)
        #expect(instrument.drumLineMap.isEmpty)
    }
}
