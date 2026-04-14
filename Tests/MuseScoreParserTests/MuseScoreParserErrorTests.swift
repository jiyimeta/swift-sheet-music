@testable import MuseScoreParser
import Testing

@Suite struct MuseScoreParserErrorTests {
    @Test func unsupportedFeatureCarriesNameAndLocation() {
        let error = MuseScoreParserError.unsupportedFeature(name: "Tuplet", location: "Voice")
        guard case let .unsupportedFeature(name, location) = error else {
            Issue.record("expected unsupportedFeature case")
            return
        }
        #expect(name == "Tuplet")
        #expect(location == "Voice")
    }
}
