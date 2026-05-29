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

    @Test("multiple breath siblings on one note preserve document order")
    func multipleBreathSiblingsPreserveDocumentOrder() throws {
        // Two notation children on the same note: a tick breath mark
        // followed by a short caesura. Both should land as separate
        // voice elements in document order, after the C chord and
        // before the D chord.
        let notation = """
        <breath-mark>tick</breath-mark>
        <caesura>short</caesura>
        """
        let s = try Self.score(notation: notation)
        let elements = s.parts[0].staves[0].measures[0].voices[0].elements
        let breaths = elements.compactMap { el -> Breath? in
            if case let .breath(b) = el { return b }
            return nil
        }
        #expect(breaths.count == 2)
        #expect(breaths.first?.kind == .breathMark(.tick))
        #expect(breaths.last?.kind == .caesura(.short))
        // Document-order placement: both breaths sit between the two chords.
        let breathIndices = elements.indices.filter {
            if case .breath = elements[$0] { return true }; return false
        }
        #expect(breathIndices.count == 2)
        #expect(breathIndices[0] + 1 == breathIndices[1])
    }

    /// Builds an MSCX score where the first measure contains a single
    /// two-note quarter chord (C + E) whose chord-tone (the E) carries
    /// a breath-mark notation. The chord is followed by a D quarter note
    /// with no notation.
    static func chordFoldScore() throws -> Score {
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
              </note>
              <note>
                <chord/>
                <pitch><step>E</step><octave>4</octave></pitch>
                <duration>480</duration><voice>1</voice><type>quarter</type>
                <notations><breath-mark>comma</breath-mark></notations>
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

    @Test("breath on chord-tone (<chord/>) folds breath after host chord")
    func breathOnChordToneFoldsToHostChord() throws {
        let s = try Self.chordFoldScore()
        let elements = s.parts[0].staves[0].measures[0].voices[0].elements

        // Expect: chord(C,E), breath(.breathMark(.comma)), chord(D).
        let chords = elements.compactMap { el -> Chord? in
            if case let .chord(c) = el { return c }
            return nil
        }
        let breaths = elements.compactMap { el -> Breath? in
            if case let .breath(b) = el { return b }
            return nil
        }

        #expect(chords.count == 2, "expected exactly two chords (folded host + following), got \(chords.count)")
        #expect(breaths.count == 1, "expected exactly one breath (no duplication), got \(breaths.count)")
        // First chord should carry two notes (C + E merged).
        #expect(chords.first?.notes.count == 2)
        // Breath should be a comma breath mark.
        #expect(breaths.first?.kind == .breathMark(.comma))

        // Position: the breath must sit between the two chords.
        guard let breathIdx = elements.firstIndex(where: {
            if case .breath = $0 { return true }; return false
        }) else { Issue.record("expected a .breath"); return }
        #expect(breathIdx > 0)
        #expect(breathIdx < elements.count - 1)
        // Element before the breath must be the chord, element after must be the next chord.
        if case .chord = elements[breathIdx - 1] {} else {
            Issue.record("expected a chord immediately before the breath")
        }
        if case .chord = elements[breathIdx + 1] {} else {
            Issue.record("expected a chord immediately after the breath")
        }
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
