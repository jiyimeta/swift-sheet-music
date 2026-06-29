import Foundation
@testable import SheetMusicCore
@testable import SheetMusicMSCX
@testable import SheetMusicXMLTools
import Testing

struct SmallNoteTests {
    private func parseNote(_ xml: String) throws -> Note {
        let node = try XMLTreeParser.parse(Data(xml.utf8))
        return try Note.decode(node)
    }

    @Test func decodesSmallFlag() throws {
        let xml = "<Note><pitch>60</pitch><tpc>14</tpc><small>1</small></Note>"
        #expect(try parseNote(xml).isSmall == true)
    }

    @Test func defaultsFalse() throws {
        let xml = "<Note><pitch>60</pitch><tpc>14</tpc></Note>"
        #expect(try parseNote(xml).isSmall == false)
    }
}
