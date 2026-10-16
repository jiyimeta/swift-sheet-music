import Foundation
@testable import SheetMusicMusicXML
import Testing

@Suite("MusicXML import options")
struct MusicXMLImportOptionsTests {
    @Test("inference is on by default")
    func inferenceDefaultsOn() {
        #expect(MusicXMLImportOptions.default.inferTextType)
        #expect(MusicXMLImportOptions().inferTextType)
    }

    @Test("a file with no directions imports the same under either option")
    func optionsAgreeWithoutDirections() throws {
        let xml = try MusicXMLFixtureLoader.xml("testBarlineLoc")
        let inferred = try MusicXMLParser.parse(xml, options: MusicXMLImportOptions(inferTextType: true))
        let plain = try MusicXMLParser.parse(xml, options: MusicXMLImportOptions(inferTextType: false))
        let direct = try MusicXMLParser.parse(xml)
        #expect(inferred == plain)
        #expect(inferred == direct)
    }
}
