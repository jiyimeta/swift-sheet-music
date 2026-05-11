import Foundation
@testable import SheetMusicCore
@testable import SheetMusicMSCX
@testable import SheetMusicXMLTools
import Testing

struct TextPropertiesTests {
    // MARK: - TextStyleType defaults

    @Test func dynamicsDefaultIsEdwinItalic10pt() {
        let d = TextStyleType.dynamics.museScoreDefault
        #expect(d.face == "Edwin")
        #expect(d.size == 10)
        #expect(d.style == .italic)
    }

    @Test func rehearsalMarkDefaultIsEdwinBold14ptSquareFrame() {
        let d = TextStyleType.rehearsalMark.museScoreDefault
        #expect(d.face == "Edwin")
        #expect(d.size == 14)
        #expect(d.style == .bold)
        #expect(d.frameType == .rectangle)
        #expect(d.framePadding == 0.5)
    }

    @Test func tempoDefaultIsEdwinBold12pt() {
        let d = TextStyleType.tempo.museScoreDefault
        #expect(d.face == "Edwin")
        #expect(d.size == 12)
        #expect(d.style == .bold)
    }

    @Test func staffAndLyricsDefaultsAreEdwinNormal10pt() {
        for type in [
            TextStyleType.staffText, .systemText, .pedal,
            .lyricsOdd, .lyricsEven, .chordSymbolA,
        ] {
            let d = type.museScoreDefault
            #expect(d.face == "Edwin", "\(type)")
            #expect(d.size == 10, "\(type)")
            #expect(d.style == [], "\(type)")
        }
    }

    @Test func chordSymbolJazzIsItalic() {
        #expect(TextStyleType.chordSymbolB.museScoreDefault.style == .italic)
    }

    @Test func romanNumeralUsesCampania() {
        let d = TextStyleType.chordSymbolRomanNumeral.museScoreDefault
        #expect(d.face == "Campania")
        #expect(d.size == 12)
    }

    // MARK: - TextProperties.resolved

    @Test func unsetPropertiesInheritFromStyle() {
        let resolved = TextProperties().resolved(against: .dynamics)
        #expect(resolved.face == "Edwin")
        #expect(resolved.size == 10)
        #expect(resolved.style == .italic)
    }

    @Test func setPropertiesOverrideStyleFields() {
        let p = TextProperties(face: "Times", size: 14)
        let r = p.resolved(against: .dynamics)
        #expect(r.face == "Times")
        #expect(r.size == 14)
        // Unset style still inherits italic from .dynamics.
        #expect(r.style == .italic)
    }

    // MARK: - MSCX decoding

    @Test func dynamicDecodesFontOverrides() throws {
        let xml = """
        <Dynamic>
          <subtype>p</subtype>
          <face>Arial</face>
          <size>11.5</size>
          <bold>1</bold>
          <italic>0</italic>
        </Dynamic>
        """
        let node = try XMLTreeParser.parse(Data(xml.utf8))
        let d = try Dynamic.decode(node)
        #expect(d.properties.face == "Arial")
        #expect(d.properties.size == 11.5)
        // Both bold/italic flags appear ⇒ style = bold only.
        #expect(d.properties.style == .bold)
    }

    @Test func staffTextDecodesPartialOverride() throws {
        let xml = """
        <StaffText>
          <text>cresc.</text>
          <italic>1</italic>
        </StaffText>
        """
        let node = try XMLTreeParser.parse(Data(xml.utf8))
        let st = try StaffText.decode(node, isSystemText: false)
        #expect(st.properties.face == nil)
        #expect(st.properties.size == nil)
        #expect(st.properties.style == .italic)
    }

    @Test func rehearsalMarkLiftsFrameTypeOutOfProperties() throws {
        let xml = """
        <RehearsalMark>
          <text>B</text>
          <frameType>1</frameType>
          <bold>1</bold>
        </RehearsalMark>
        """
        let node = try XMLTreeParser.parse(Data(xml.utf8))
        let rm = try RehearsalMark.decode(node)
        #expect(rm.frame == .circle)
        #expect(rm.properties.frameType == nil)
        #expect(rm.properties.style == .bold)
    }

    @Test func absentFlagsLeavePropertiesNil() throws {
        let xml = """
        <RehearsalMark>
          <text>A</text>
        </RehearsalMark>
        """
        let node = try XMLTreeParser.parse(Data(xml.utf8))
        let rm = try RehearsalMark.decode(node)
        #expect(rm.properties.isEmpty)
        // Default frame still rectangle — that comes from the
        // static default, not from `properties`.
        #expect(rm.frame == .rectangle)
    }

    @Test func lyricsCarryVerseAndProperties() throws {
        let xml = """
        <Chord>
          <durationType>quarter</durationType>
          <Lyrics>
            <no>1</no>
            <text>foo</text>
            <bold>1</bold>
          </Lyrics>
          <Note><pitch>60</pitch><tpc>14</tpc></Note>
        </Chord>
        """
        let node = try XMLTreeParser.parse(Data(xml.utf8))
        let chord = try Chord.decode(node)
        #expect(chord.lyrics.count == 2) // verse 0 (empty) + verse 1
        #expect(chord.lyrics[1].text == "foo")
        #expect(chord.lyrics[1].verse == 1)
        #expect(chord.lyrics[1].styleType == .lyricsEven)
        #expect(chord.lyrics[1].properties.style == .bold)
    }
}
