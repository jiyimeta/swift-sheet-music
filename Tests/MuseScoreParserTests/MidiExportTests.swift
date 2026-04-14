import Foundation
@testable import MuseScoreParser
import Testing

@Suite struct MidiExportTests {
    @Test func midi01() throws {
        try assertExportMatchesReference(name: "midi01")
    }

    @Test func midi02() throws {
        try assertExportMatchesReference(name: "midi02")
    }

    private func assertExportMatchesReference(name: String) throws {
        let scoreURL = try #require(Bundle.module.url(forResource: name, withExtension: "mscx"))
        let refURL = try #require(Bundle.module.url(forResource: "\(name)-ref", withExtension: "mid"))

        let score = try MuseScoreParser.loadScore(mscxData: try Data(contentsOf: scoreURL))
        let produced = try MuseScoreParser.exportMIDI(score: score)
        let reference = try Data(contentsOf: refURL)

        try MidiSemanticComparison.assertEquivalent(produced: produced, reference: reference)
    }
}
