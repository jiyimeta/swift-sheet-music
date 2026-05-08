import Foundation
@testable import SheetMusic
@testable import SheetMusicCore
@testable import SheetMusicMIDI
@testable import SheetMusicMSCX
@testable import SheetMusicXMLTools
import Testing

@Suite("MSCXEncoder MS3 round-trip")
struct MSCXEncoderMS3RoundTripTests {
    @Test("midi01 v3 round-trip matches canonical MS3 root + Style fields")
    func midi01CanonicalKeyFieldsMatch() throws {
        let score = try MSCXParser.parse(MSCXFixtureLoader.mscxData("midi01"))
        let bytes = try MSCXEncoder.encode(score, options: .init(targetVersion: .v3))
        let root = try XMLTreeParser.parse(bytes)

        // Root: §A
        #expect(root.attributes["version"] == "3.02")
        #expect(root.first("programVersion")?.text == "3.6.2")
        #expect(root.first("programRevision")?.text == "3224f34")
        let scoreElement = try #require(root.first("Score"))
        let firstNames = scoreElement.children.prefix(3).map(\.name)
        #expect(firstNames == ["LayerTag", "currentLayer", "Division"])
        let postStyle = scoreElement.children
            .drop(while: { $0.name != "Style" })
            .dropFirst()
            .prefix(4)
            .map(\.name)
        #expect(postStyle == ["showInvisible", "showUnprintable", "showFrames", "showMargins"])

        // Style: §B
        let style = try #require(scoreElement.first("Style"))
        #expect(style.children.count == 1)
        #expect(style.children[0].name == "Spatium")
    }
}
