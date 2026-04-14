import Foundation
@testable import MuseScoreParser
import Testing

@Suite struct MidiExportTests {
    @Test func midi01() throws {
        let scoreURL = try #require(Bundle.module.url(forResource: "midi01", withExtension: "mscx"))
        let refURL   = try #require(Bundle.module.url(forResource: "midi01-ref", withExtension: "mid"))

        let score    = try MuseScoreParser.loadScore(mscxData: try Data(contentsOf: scoreURL))
        let produced = try MuseScoreParser.exportMIDI(score: score)
        let reference = try Data(contentsOf: refURL)

        try MidiSemanticComparison.assertEquivalent(produced: produced, reference: reference)
    }
}
