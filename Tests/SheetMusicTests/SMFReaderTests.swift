import Foundation
@testable import SheetMusic
@testable import SheetMusicCore
@testable import SheetMusicMIDI
@testable import SheetMusicMSCX
import Testing

struct MidiReaderRoundTripTests {
    @Test func readsMidi01Reference() throws {
        let url = try #require(TestResources.url(forResource: "midi01-ref", withExtension: "mid"))
        let file = try MidiReader.read(Data(contentsOf: url))
        #expect(file.format == 1)
        #expect(file.division == 480)
        #expect(file.tracks.count == 1)
        let hasC4 = file.tracks[0].events.contains {
            if case let .noteOn(_, p, v) = $0.event, p == 60, v > 0 { return true } else { return false }
        }
        #expect(hasC4)
    }
}
