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

    @Test func unknown_subtype_emits_diagnostic_and_drops_tremolo() throws {
        let xml = """
        <Chord>
            <durationType>quarter</durationType>
            <Tremolo>
                <subtype>r128</subtype>
            </Tremolo>
            <Note><pitch>60</pitch><tpc>14</tpc></Note>
        </Chord>
        """
        let collector = MSCXDiagnosticCollector()
        let chord = try MSCXParserContext.$collector.withValue(collector) {
            try parseChord(xml)
        }
        #expect(chord.tremolo == nil)
        #expect(collector.entries.count == 1)
        #expect(collector.entries.first?.code == "mscx.tremolo.unknownSubtype")
    }

    @Test func decodes_ms4_TremoloSingleChord() throws {
        // MS4 splits the MS3 `<Tremolo>` element into two distinct
        // tags; the `<subtype>` text keeps the same r-prefix tokens.
        let xml = """
        <Chord>
            <durationType>quarter</durationType>
            <TremoloSingleChord>
                <subtype>r16</subtype>
                <eid>Qiqea8EoARG_TAW57YqR/CD</eid>
            </TremoloSingleChord>
            <Note><pitch>60</pitch><tpc>14</tpc></Note>
        </Chord>
        """
        let chord = try parseChord(xml)
        #expect(chord.tremolo?.subtype == .r16)
        #expect(chord.tremolo?.span == .single)
    }

    @Test func decodes_ms4_TremoloTwoChord() throws {
        // MS4 two-chord tremolo. The new tag pins the span; the
        // pairing-validation second pass in MSCXDecoder+Voice still
        // expects `.between` to mark the start chord.
        let xml = """
        <Chord>
            <durationType>half</durationType>
            <TremoloTwoChord>
                <subtype>c16</subtype>
            </TremoloTwoChord>
            <Note><pitch>60</pitch><tpc>14</tpc></Note>
        </Chord>
        """
        let chord = try parseChord(xml)
        #expect(chord.tremolo?.subtype == .r16)
        #expect(chord.tremolo?.span == .between)
    }
}

struct TremoloMSCXDecodeSecondPassTests {
    private func parseVoice(_ xml: String) throws -> Voice {
        let node = try XMLTreeParser.parse(Data(xml.utf8))
        return try Voice.decode(node)
    }

    @Test func c8_pair_clears_follower_tremolo() throws {
        // Two half-notes both marked c8 — the start keeps .between,
        // the follower has its redundant tremolo cleared.
        let xml = """
        <voice>
            <Chord>
                <durationType>half</durationType>
                <Tremolo><subtype>c8</subtype></Tremolo>
                <Note><pitch>60</pitch><tpc>14</tpc></Note>
            </Chord>
            <Chord>
                <durationType>half</durationType>
                <Tremolo><subtype>c8</subtype></Tremolo>
                <Note><pitch>64</pitch><tpc>18</tpc></Note>
            </Chord>
        </voice>
        """
        let voice = try parseVoice(xml)
        guard case let .chord(c0) = voice.elements[0],
              case let .chord(c1) = voice.elements[1]
        else { Issue.record("expected two chords"); return }
        #expect(c0.tremolo?.span == .between)
        #expect(c0.tremolo?.subtype == .r8)
        #expect(c1.tremolo == nil)
    }

    @Test func c8_with_no_follower_throws() throws {
        let xml = """
        <voice>
            <Chord>
                <durationType>half</durationType>
                <Tremolo><subtype>c16</subtype></Tremolo>
                <Note><pitch>60</pitch><tpc>14</tpc></Note>
            </Chord>
        </voice>
        """
        #expect(throws: SheetMusicError.self) {
            _ = try parseVoice(xml)
        }
    }

    @Test func r16_unaffected_by_pairing_pass() throws {
        let xml = """
        <voice>
            <Chord>
                <durationType>quarter</durationType>
                <Tremolo><subtype>r16</subtype></Tremolo>
                <Note><pitch>60</pitch><tpc>14</tpc></Note>
            </Chord>
        </voice>
        """
        let voice = try parseVoice(xml)
        guard case let .chord(c) = voice.elements[0] else {
            Issue.record("expected chord"); return
        }
        #expect(c.tremolo?.span == .single)
        #expect(c.tremolo?.subtype == .r16)
    }
}
