import Foundation
@testable import MuseScoreParser
import Testing

@Suite struct SMFReaderTests {
    @Test func readsMidi01Reference() throws {
        let url = try #require(Bundle.module.url(forResource: "midi01-ref", withExtension: "mid"))
        let file = try SMFReader.read(try Data(contentsOf: url))
        #expect(file.format == 1)
        #expect(file.division == 480)
        #expect(file.tracks.count == 1)
        let hasC4 = file.tracks[0].events.contains {
            if case .noteOn(_, let p, let v) = $0.event, p == 60, v > 0 { return true } else { return false }
        }
        #expect(hasC4)
    }
}
