import Foundation
@testable import SheetMusicCore
@testable import SheetMusicMSCX
@testable import SheetMusicXMLTools
import Testing

struct NoteParenthesesChordDecodeTests {
    private func parseChord(_ xml: String) throws -> Chord {
        let node = try XMLTreeParser.parse(Data(xml.utf8))
        return try Chord.decode(node)
    }

    @Test func rep3GroupParenthesizesReferencedNotes() throws {
        let xml = """
        <Chord><durationType>quarter</durationType>\
        <Note><pitch>60</pitch><tpc>14</tpc></Note>\
        <Note><pitch>64</pitch><tpc>18</tpc></Note>\
        <NoteParenGroup>\
        <Parenthesis><horizontalDirection>left</horizontalDirection></Parenthesis>\
        <Parenthesis><horizontalDirection>right</horizontalDirection></Parenthesis>\
        <Notes><NoteIdx>0</NoteIdx><NoteIdx>1</NoteIdx></Notes>\
        </NoteParenGroup></Chord>
        """
        let chord = try parseChord(xml)
        #expect(chord.notes[0].parentheses == .both)
        #expect(chord.notes[1].parentheses == .both)
    }

    @Test func rep3GroupWithoutParenthesisChildrenStillBoth() throws {
        // MuseScore omits <Parenthesis> children when unmodified.
        let xml = """
        <Chord><durationType>quarter</durationType>\
        <Note><pitch>60</pitch><tpc>14</tpc></Note>\
        <Note><pitch>64</pitch><tpc>18</tpc></Note>\
        <NoteParenGroup><Notes><NoteIdx>1</NoteIdx></Notes></NoteParenGroup></Chord>
        """
        let chord = try parseChord(xml)
        #expect(chord.notes[0].parentheses == .none)
        #expect(chord.notes[1].parentheses == .both)
    }

    @Test func rep3OutOfRangeIndexIgnored() throws {
        let xml = """
        <Chord><durationType>quarter</durationType>\
        <Note><pitch>60</pitch><tpc>14</tpc></Note>\
        <NoteParenGroup><Notes><NoteIdx>5</NoteIdx></Notes></NoteParenGroup></Chord>
        """
        let chord = try parseChord(xml)
        #expect(chord.notes[0].parentheses == .none)
    }
}
