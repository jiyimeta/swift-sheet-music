import Foundation
@testable import SheetMusicCore
@testable import SheetMusicMSCX
import Testing

@Suite("MSCXEncoder")
struct MSCXEncoderTests {
    @Test("minimal Score round-trips division and metaTags")
    func minimalScoreRoundTrip() throws {
        let original = Score(
            division: 480,
            metaTags: ["composer": "Bach", "workTitle": "Invention"]
        )

        let bytes = try MSCXEncoder.encode(original)
        let reparsed = try MSCXParser.parse(bytes)

        #expect(reparsed.division == 480)
        #expect(reparsed.metaTags == original.metaTags)
    }

    @Test("Score round-trips custom spatium")
    func spatiumRoundTrip() throws {
        var style = ScoreStyle.museScoreDefaults
        style.spatium = 1.5
        let original = Score(division: 480, style: style)

        let bytes = try MSCXEncoder.encode(original)
        let reparsed = try MSCXParser.parse(bytes)

        #expect(reparsed.style.spatium == 1.5)
    }
}
