import Foundation
@testable import SheetMusicCore
@testable import SheetMusicMSCX
@testable import SheetMusicXMLTools
import Testing

struct NoteParenthesesMSCXDecodeTests {
    private func parseNote(_ xml: String) throws -> Note {
        let node = try XMLTreeParser.parse(Data(xml.utf8))
        return try Note.decode(node)
    }

    /// rep2 (MuseScore 4.6) — the real ロビンソン.mscz form.
    @Test func rep2BothFromParenthesesProperty() throws {
        let xml = """
        <Note><parentheses>both</parentheses>\
        <Parenthesis><track>16</track></Parenthesis>\
        <Parenthesis><horizontalDirection>right</horizontalDirection><track>16</track></Parenthesis>\
        <pitch>45</pitch><tpc>17</tpc></Note>
        """
        #expect(try parseNote(xml).parentheses == .both)
    }

    @Test func rep2LeftAndRightTokens() throws {
        let left = "<Note><parentheses>left</parentheses><pitch>60</pitch><tpc>14</tpc></Note>"
        let right = "<Note><parentheses>right</parentheses><pitch>60</pitch><tpc>14</tpc></Note>"
        #expect(try parseNote(left).parentheses == .left)
        #expect(try parseNote(right).parentheses == .right)
    }

    /// rep1 (MuseScore ≤4.5) — <Symbol><name>… form.
    @Test func rep1BothFromSymbols() throws {
        let xml = """
        <Note>\
        <Symbol><name>noteheadParenthesisLeft</name></Symbol>\
        <Symbol><name>noteheadParenthesisRight</name></Symbol>\
        <pitch>60</pitch><tpc>14</tpc></Note>
        """
        #expect(try parseNote(xml).parentheses == .both)
    }

    @Test func rep1LeftOnlyFromSymbol() throws {
        let xml = """
        <Note><Symbol><name>noteheadParenthesisLeft</name></Symbol>\
        <pitch>60</pitch><tpc>14</tpc></Note>
        """
        #expect(try parseNote(xml).parentheses == .left)
    }

    @Test func absentDefaultsToNone() throws {
        #expect(try parseNote("<Note><pitch>60</pitch><tpc>14</tpc></Note>").parentheses == .none)
    }
}
