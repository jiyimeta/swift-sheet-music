import Foundation
@testable import SheetMusicCore
@testable import SheetMusicMSCX
@testable import SheetMusicXMLTools
import Testing

struct AccidentalBracketDecodeTests {
    private func parseNote(_ xml: String) throws -> Note {
        let node = try XMLTreeParser.parse(Data(xml.utf8))
        return try Note.decode(node)
    }

    @Test func decodesSubtypeAndBracket() throws {
        let xml = """
        <Note><pitch>61</pitch><tpc>20</tpc>\
        <Accidental><subtype>accidentalSharp</subtype><bracket>1</bracket></Accidental></Note>
        """
        let note = try parseNote(xml)
        #expect(note.accidental == .sharp)
        #expect(note.accidentalBracket == .parenthesis)
    }

    @Test func decodesSquareBracket() throws {
        let xml = """
        <Note><pitch>61</pitch><tpc>20</tpc>\
        <Accidental><subtype>accidentalFlat</subtype><bracket>2</bracket></Accidental></Note>
        """
        let note = try parseNote(xml)
        #expect(note.accidental == .flat)
        #expect(note.accidentalBracket == .bracket)
    }

    @Test func absentBracketDefaultsToNone() throws {
        let xml = """
        <Note><pitch>61</pitch><tpc>20</tpc>\
        <Accidental><subtype>accidentalSharp</subtype></Accidental></Note>
        """
        let note = try parseNote(xml)
        #expect(note.accidental == .sharp)
        #expect(note.accidentalBracket == .none)
    }

    @Test func unknownSubtypeWarnsAndDropsAccidental() throws {
        let collector = MSCXDiagnosticCollector()
        let xml = """
        <Note><pitch>61</pitch><tpc>20</tpc>\
        <Accidental><subtype>accidentalBogus</subtype></Accidental></Note>
        """
        let note = try MSCXParserContext.$collector.withValue(collector) {
            try parseNote(xml)
        }
        #expect(collector.entries.contains { $0.code == "mscx.accidental.unsupportedSubtype" })
        #expect(note.accidental == nil)
    }

    @Test func noAccidentalElementDefaultsToNilAndNone() throws {
        let xml = "<Note><pitch>60</pitch><tpc>14</tpc></Note>"
        let note = try parseNote(xml)
        #expect(note.accidental == nil)
        #expect(note.accidentalBracket == .none)
    }
}
