import Foundation
@testable import SheetMusicCore
@testable import SheetMusicMusicXML
import Testing

@Suite("Breath MusicXML import")
struct BreathImportTests {
    static func score(notation: String) throws -> Score {
        let xml = """
        <?xml version="1.0" encoding="UTF-8"?>
        <score-partwise version="4.0">
          <part-list><score-part id="P1"><part-name>P</part-name></score-part></part-list>
          <part id="P1">
            <measure number="1">
              <attributes>
                <divisions>480</divisions>
                <key><fifths>0</fifths></key>
                <time><beats>4</beats><beat-type>4</beat-type></time>
                <clef><sign>G</sign><line>2</line></clef>
              </attributes>
              <note>
                <pitch><step>C</step><octave>4</octave></pitch>
                <duration>480</duration><voice>1</voice><type>quarter</type>
                <notations>\(notation)</notations>
              </note>
              <note>
                <pitch><step>D</step><octave>4</octave></pitch>
                <duration>480</duration><voice>1</voice><type>quarter</type>
              </note>
            </measure>
          </part>
        </score-partwise>
        """
        return try MusicXMLParser.parse(Data(xml.utf8))
    }

    static func breath(in score: Score) -> Breath? {
        let voice = score.parts[0].staves[0].measures[0].voices[0]
        for el in voice.elements {
            if case let .breath(b) = el { return b }
        }
        return nil
    }

    @Test("breath-mark values map to BreathMarkStyle")
    func breathMarkValues() throws {
        let cases: [(String, Breath.BreathMarkStyle)] = [
            ("comma", .comma), ("tick", .tick),
            ("upbow", .upbow), ("salzedo", .salzedo),
        ]
        for (value, expected) in cases {
            let s = try Self.score(notation: "<breath-mark>\(value)</breath-mark>")
            guard let b = Self.breath(in: s) else {
                Issue.record("expected a .breath for value '\(value)'"); continue
            }
            #expect(b.kind == .breathMark(expected))
        }
    }

    @Test("caesura values map to CaesuraStyle")
    func caesuraValues() throws {
        let cases: [(String, Breath.CaesuraStyle)] = [
            ("normal", .normal), ("short", .short),
            ("thick", .thick), ("curved", .curved),
        ]
        for (value, expected) in cases {
            let s = try Self.score(notation: "<caesura>\(value)</caesura>")
            guard let b = Self.breath(in: s) else {
                Issue.record("expected a .breath for value '\(value)'"); continue
            }
            #expect(b.kind == .caesura(expected))
        }
    }

    @Test("empty breath-mark value defaults to comma")
    func emptyBreathMarkDefaultsToComma() throws {
        let s = try Self.score(notation: "<breath-mark/>")
        guard let b = Self.breath(in: s) else {
            Issue.record("expected a .breath"); return
        }
        #expect(b.kind == .breathMark(.comma))
    }

    @Test("empty caesura value defaults to normal")
    func emptyCaesuraDefaultsToNormal() throws {
        let s = try Self.score(notation: "<caesura/>")
        guard let b = Self.breath(in: s) else {
            Issue.record("expected a .breath"); return
        }
        #expect(b.kind == .caesura(.normal))
    }

    @Test("MusicXML import uses default pause (no <pause> in MusicXML)")
    func importUsesDefaultPause() throws {
        let s = try Self.score(notation: "<caesura>thick</caesura>")
        guard let b = Self.breath(in: s) else {
            Issue.record("expected a .breath"); return
        }
        #expect(b.pause == 0.75)
    }

    @Test(".breath is appended after the host chord (before the next chord)")
    func breathPositionedBetweenChords() throws {
        let s = try Self.score(notation: "<breath-mark>comma</breath-mark>")
        let elements = s.parts[0].staves[0].measures[0].voices[0].elements
        guard let breathIdx = elements.firstIndex(where: {
            if case .breath = $0 { return true }
            return false
        }) else {
            Issue.record("expected a .breath"); return
        }
        #expect(breathIdx > 0)
        #expect(breathIdx < elements.count - 1)

        // Confirm the surrounding voice elements are the C and D chords.
        if case let .chord(c) = elements[breathIdx - 1] {
            #expect(c.notes.first?.pitch == 60)
        } else {
            Issue.record("expected chord before breath, got \(elements[breathIdx - 1])")
        }
        if case let .chord(c) = elements[breathIdx + 1] {
            #expect(c.notes.first?.pitch == 62)
        } else {
            Issue.record("expected chord after breath, got \(elements[breathIdx + 1])")
        }
    }
}
