import Foundation
@testable import SheetMusicCore
@testable import SheetMusicMSCX
import SheetMusicXMLTools
import Testing

/// Covers the `<color>` decode path that drives author-colored
/// noteheads / rests / lyrics (the consolidated `ElementProperties.color`
/// extension point). Rendering of these colors is verified visually.
struct ElementColorTests {
    private func parse(_ xml: String) throws -> XMLTreeNode {
        try XMLTreeParser.parse(Data(xml.utf8))
    }

    @Test func noteColorDecodesIntoElementProperties() throws {
        let chord = try Chord.decode(parse("""
        <Chord>
          <durationType>quarter</durationType>
          <Note>
            <color r="255" g="0" b="0" a="255"/>
            <pitch>68</pitch>
            <tpc>10</tpc>
          </Note>
        </Chord>
        """))
        let note = try #require(chord.notes.first)
        #expect(
            note.elementProperties.color
                == ScoreColor(red: 255, green: 0, blue: 0, alpha: 255),
        )
    }

    @Test func uncoloredNoteHasNilColor() throws {
        let chord = try Chord.decode(parse("""
        <Chord>
          <durationType>quarter</durationType>
          <Note><pitch>60</pitch><tpc>14</tpc></Note>
        </Chord>
        """))
        #expect(chord.notes.first?.elementProperties.color == nil)
    }

    @Test func lyricColorDecodesIntoElementProperties() throws {
        let chord = try Chord.decode(parse("""
        <Chord>
          <durationType>quarter</durationType>
          <Lyrics>
            <color r="255" g="0" b="0" a="255"/>
            <text>き</text>
          </Lyrics>
          <Note><pitch>68</pitch><tpc>10</tpc></Note>
        </Chord>
        """))
        let lyric = try #require(chord.lyrics.first)
        #expect(lyric.text == "き")
        #expect(
            lyric.elementProperties.color
                == ScoreColor(red: 255, green: 0, blue: 0, alpha: 255),
        )
    }

    @Test func restColorDecodesIntoElementProperties() throws {
        let rest = try MSCXRestDecoder.decode(parse("""
        <Rest>
          <durationType>quarter</durationType>
          <color r="255" g="0" b="0" a="255"/>
        </Rest>
        """))
        #expect(
            rest.elementProperties.color
                == ScoreColor(red: 255, green: 0, blue: 0, alpha: 255),
        )
    }
}
