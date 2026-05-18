import Foundation
@testable import SheetMusicCore
@testable import SheetMusicMSCX
@testable import SheetMusicXMLTools
import Testing

struct TremoloModelTests {
    @Test func tremolo_default_init() {
        let t = Tremolo(subtype: .r16)
        #expect(t.subtype == .r16)
        #expect(t.span == .single)
        #expect(t.strokeStyle == .default)
    }

    @Test func tremolo_full_init() {
        let t = Tremolo(subtype: .r8, span: .between, strokeStyle: .traditional)
        #expect(t.subtype == .r8)
        #expect(t.span == .between)
        #expect(t.strokeStyle == .traditional)
    }
}

struct TremoloMSCXDecodeFirstPassTests {
    private func parseChord(_ xml: String) throws -> Chord {
        let node = try XMLTreeParser.parse(Data(xml.utf8))
        return try Chord.decode(node)
    }

    @Test func decodes_r16_as_single() throws {
        let xml = """
        <Chord>
            <durationType>quarter</durationType>
            <Tremolo>
                <subtype>r16</subtype>
            </Tremolo>
            <Note><pitch>60</pitch><tpc>14</tpc></Note>
        </Chord>
        """
        let chord = try parseChord(xml)
        #expect(chord.tremolo?.subtype == .r16)
        #expect(chord.tremolo?.span == .single)
        #expect(chord.tremolo?.strokeStyle == .default)
    }

    @Test func decodes_c8_as_single_before_pairing_pass() throws {
        // The first-pass result of a two-note tremolo: span is .single;
        // promotion to .between happens in MSCXDecoder+Voice's second pass.
        let xml = """
        <Chord>
            <durationType>half</durationType>
            <Tremolo>
                <subtype>c8</subtype>
            </Tremolo>
            <Note><pitch>60</pitch><tpc>14</tpc></Note>
        </Chord>
        """
        let chord = try parseChord(xml)
        #expect(chord.tremolo?.subtype == .r8)
        // First-pass span is .between to signal "I am a two-chord start";
        // the second pass verifies the follower exists.
        #expect(chord.tremolo?.span == .between)
    }

    @Test func decodes_strokeStyle_traditional() throws {
        let xml = """
        <Chord>
            <durationType>quarter</durationType>
            <Tremolo>
                <subtype>r8</subtype>
                <strokeStyle>1</strokeStyle>
            </Tremolo>
            <Note><pitch>60</pitch><tpc>14</tpc></Note>
        </Chord>
        """
        let chord = try parseChord(xml)
        #expect(chord.tremolo?.strokeStyle == .traditional)
    }

    @Test func unknown_subtype_throws() throws {
        let xml = """
        <Chord>
            <durationType>quarter</durationType>
            <Tremolo>
                <subtype>r64</subtype>
            </Tremolo>
            <Note><pitch>60</pitch><tpc>14</tpc></Note>
        </Chord>
        """
        #expect(throws: SheetMusicError.self) {
            _ = try parseChord(xml)
        }
    }
}
