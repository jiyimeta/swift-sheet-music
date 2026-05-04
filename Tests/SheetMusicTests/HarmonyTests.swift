import Foundation
@testable import SheetMusicCore
@testable import SheetMusicMSCX
@testable import SheetMusicXMLTools
import Testing

@Suite struct HarmonyTests {
    @Test func defaultsAreInert() {
        let h = Harmony(name: "C")
        #expect(h.name == "C")
        #expect(h.harmonyType == .standard)
        #expect(h.rootTpc == nil)
        #expect(h.bassTpc == nil)
        #expect(h.rootCase == .auto)
        #expect(h.bassCase == .auto)
        #expect(h.leftParen == false)
        #expect(h.rightParen == false)
        #expect(h.play == true)
        #expect(h.offsetX == 0)
        #expect(h.offsetY == 0)
        #expect(h.color == nil)
        #expect(h.styleType == .chordSymbolA)
    }

    @Test func styleTypeFollowsHarmonyType() {
        #expect(Harmony(name: "C", harmonyType: .standard).styleType
            == .chordSymbolA)
        #expect(Harmony(name: "I", harmonyType: .roman).styleType
            == .chordSymbolRomanNumeral)
        #expect(Harmony(name: "1", harmonyType: .nashville).styleType
            == .chordSymbolA)
    }

    @Test func voiceElementHarmonyCaseExists() {
        let element: VoiceElement = .harmony(Harmony(name: "C"))
        guard case let .harmony(h) = element else {
            Issue.record("expected .harmony case")
            return
        }
        #expect(h.name == "C")
    }
}

extension HarmonyTests {
    @Test func decodesStandardChordNameAndType() throws {
        let xml = "<Harmony><name>C</name></Harmony>"
        let h = try Harmony.decode(
            XMLTreeParser.parse(Data(xml.utf8)))
        #expect(h.name == "C")
        #expect(h.harmonyType == .standard)
    }

    @Test func decodesSlashChordRootAndBassTpc() throws {
        let xml = """
        <Harmony>
          <name>F#m7b5/A</name>
          <root>20</root>
          <base>17</base>
        </Harmony>
        """
        let h = try Harmony.decode(
            XMLTreeParser.parse(Data(xml.utf8)))
        #expect(h.name == "F#m7b5/A")
        #expect(h.rootTpc == 20)
        #expect(h.bassTpc == 17)
    }

    @Test func decodesRomanNumeralType() throws {
        let xml = """
        <Harmony>
          <name>bIII</name>
          <harmonyType>1</harmonyType>
        </Harmony>
        """
        let h = try Harmony.decode(
            XMLTreeParser.parse(Data(xml.utf8)))
        #expect(h.harmonyType == .roman)
        #expect(h.styleType == .chordSymbolRomanNumeral)
    }

    @Test func decodesParentheses() throws {
        let xml = """
        <Harmony>
          <name>Am7</name>
          <leftParen/>
          <rightParen/>
        </Harmony>
        """
        let h = try Harmony.decode(
            XMLTreeParser.parse(Data(xml.utf8)))
        #expect(h.leftParen)
        #expect(h.rightParen)
    }

    @Test func tpcInvalidNormalizesToNil() throws {
        let xml = """
        <Harmony>
          <name>C</name>
          <root>-1</root>
          <base>-1</base>
        </Harmony>
        """
        let h = try Harmony.decode(
            XMLTreeParser.parse(Data(xml.utf8)))
        #expect(h.rootTpc == nil)
        #expect(h.bassTpc == nil)
    }

    @Test func decodesOffsetAndColor() throws {
        let xml = """
        <Harmony>
          <name>C</name>
          <offset x="0.5" y="-1.2"/>
          <color r="200" g="80" b="40" a="255"/>
        </Harmony>
        """
        let h = try Harmony.decode(
            XMLTreeParser.parse(Data(xml.utf8)))
        #expect(h.offsetX == 0.5)
        #expect(h.offsetY == -1.2)
        #expect(h.color?.red == 200)
        #expect(h.color?.green == 80)
        #expect(h.color?.blue == 40)
    }

    @Test func decodesPlayDefaultsTrue() throws {
        let h = try Harmony.decode(
            XMLTreeParser.parse(Data(
                "<Harmony><name>C</name></Harmony>".utf8)))
        #expect(h.play == true)
    }

    @Test func decodesPlayFalseFromZero() throws {
        let xml = "<Harmony><name>C</name><play>0</play></Harmony>"
        let h = try Harmony.decode(
            XMLTreeParser.parse(Data(xml.utf8)))
        #expect(h.play == false)
    }

    @Test func missingHarmonyTypeDefaultsToStandard() throws {
        let h = try Harmony.decode(
            XMLTreeParser.parse(Data(
                "<Harmony><name>C</name></Harmony>".utf8)))
        #expect(h.harmonyType == .standard)
    }

    @Test func voiceDecoderRecognizesHarmony() throws {
        let xml = """
        <voice>
          <Harmony><name>Am7</name></Harmony>
          <Chord><durationType>quarter</durationType>
            <Note><pitch>60</pitch><tpc>14</tpc></Note></Chord>
        </voice>
        """
        let voice = try Voice.decode(
            XMLTreeParser.parse(Data(xml.utf8)))
        #expect(voice.elements.count == 2)
        guard case let .harmony(h) = voice.elements[0] else {
            Issue.record("element 0 is not .harmony")
            return
        }
        #expect(h.name == "Am7")
    }
}
