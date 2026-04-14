@testable import SheetMusic
@testable import SheetMusicCore
@testable import SheetMusicMIDI
@testable import SheetMusicMSCX
import Testing

@Suite struct SheetMusicErrorTests {
    @Test func unsupportedFeatureCarriesNameAndLocation() {
        let error = SheetMusicError.unsupportedFeature(name: "Tuplet", location: "Voice")
        guard case let .unsupportedFeature(name, location) = error else {
            Issue.record("expected unsupportedFeature case")
            return
        }
        #expect(name == "Tuplet")
        #expect(location == "Voice")
    }
}
