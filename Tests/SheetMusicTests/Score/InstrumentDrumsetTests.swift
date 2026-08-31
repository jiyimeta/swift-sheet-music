@testable import SheetMusicCore
import Testing

@Suite("Instrument.drumset")
struct InstrumentDrumsetTests {
    @Test("a kit built from a line map gets the GM head, name and voice for each pitch")
    func lineMapInitFillsFromGM() {
        let instrument = Instrument(id: "drumset", useDrumset: true, drumLineMap: [38: 2, 42: -1])
        #expect(instrument.drumset.count == 2)
        #expect(instrument.drumset[38]?.head == "normal")
        #expect(instrument.drumset[38]?.name == "Acoustic Snare")
        #expect(instrument.drumset[42]?.head == "cross")
        #expect(instrument.drumset[42]?.voiceIndex == 0)
    }

    @Test("drumLineMap reads back the lines it was given")
    func lineMapRoundTrips() {
        let instrument = Instrument(id: "drumset", useDrumset: true, drumLineMap: GMPercussion.drumLineMap)
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
        var instrument = Instrument(id: "drumset", useDrumset: true, drumLineMap: [38: 2, 42: -1])
        instrument.drumLineMap = [38: 2]
        #expect(Set(instrument.drumset.keys) == [38])
    }

    @Test("an explicit drumset wins over a line map passed alongside it")
    func drumsetWinsOverLineMap() {
        let instrument = Instrument(
            id: "drumset", useDrumset: true,
            drumLineMap: [38: 7],
            drumset: [38: DrumsetEntry(name: "Snare", head: "cross", line: 2, voiceIndex: 0, stem: 1)],
        )
        #expect(instrument.drumLineMap == [38: 2])
        #expect(instrument.drumset[38]?.head == "cross")
    }

    @Test("a pitched instrument has an empty kit")
    func pitchedIsEmpty() {
        let instrument = Instrument(id: "flute")
        #expect(instrument.drumset.isEmpty)
        #expect(instrument.drumLineMap.isEmpty)
    }
}
