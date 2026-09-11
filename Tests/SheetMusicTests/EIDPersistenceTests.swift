import SheetMusicCore
@testable import SheetMusicMSCX
import SheetMusicXMLTools
import Testing

@Suite("EID persistence")
struct EIDPersistenceTests {
    @Test("a MuseScore-written identifier decodes to the same halves it encodes from")
    func childRoundTrips() throws {
        let eid = EID(first: 1, second: 1)
        let node = try #require(EIDXML.node(for: eid))
        #expect(node.name == "eid")
        #expect(node.text == "B_B") // the value in Tests/SheetMusicTests/Resources/midi01.mscx
        #expect(EIDXML.decode(from: XMLTreeNode(name: "Chord", children: [node])) == eid)
    }

    @Test("an absent or malformed child is not an identifier")
    func absentChildIsInvalid() {
        #expect(EIDXML.decode(from: XMLTreeNode(name: "Chord", children: [])) == .invalid)
        let malformed = XMLTreeNode(name: "Chord", children: [XMLTreeNode(name: "eid", text: "_")])
        #expect(EIDXML.decode(from: malformed) == .invalid)
    }

    @Test("an unassigned slot writes no child")
    func unassignedWritesNothing() {
        #expect(EIDXML.node(for: .invalid) == nil)
    }

    @Test("a chord and its notes keep the identifiers the file carried")
    func chordAndNoteIdentifiersSurviveAnEncodeDecode() throws {
        let score = try MSCXParser.parse(MSCXFixtureLoader.mscxData("midi01"))
        let voice = score.parts[0].staves[0].measures[0].voices[0]
        // Element 0 is the staff-head <KeySig>, element 1 the <TimeSig>;
        // the first <Chord> (midi01.mscx:99-107) is element 2 — verified
        // by dumping `voice.elements` against the fixture rather than
        // assuming the brief's illustrative index 0.
        let chordIndex = 2
        let chordEID = voice.elements.eid(at: chordIndex)
        guard case let .chord(chord) = voice.elements[chordIndex] else {
            Issue.record("expected element \(chordIndex) to be the fixture's first chord")
            return
        }
        let noteEID = chord.notes.eid(at: 0)
        // midi01.mscx:100 is <eid>G_G</eid> on the first <Chord>; :103 is
        // <eid>H_H</eid> on its <Note>.
        #expect(chordEID == EID(string: "G_G"))
        #expect(noteEID == EID(string: "H_H"))

        let reparsed = try MSCXParser.parse(MSCXEncoder.encode(score))
        let reparsedVoice = reparsed.parts[0].staves[0].measures[0].voices[0]
        #expect(reparsedVoice.elements.eid(at: chordIndex) == chordEID)
        guard case let .chord(reparsedChord) = reparsedVoice.elements[chordIndex] else {
            Issue.record("expected element \(chordIndex) to be the fixture's first chord")
            return
        }
        #expect(reparsedChord.notes.eid(at: 0) == noteEID)
    }

    @Test("a MuseScore 3 target writes no element identifier")
    func v3TargetWritesNoEID() throws {
        let score = try MSCXParser.parse(MSCXFixtureLoader.mscxData("midi01"))
        let v3Data = try MSCXEncoder.encode(score, options: .init(targetVersion: .v3))
        let v3XML = try #require(String(bytes: v3Data, encoding: .utf8))
        #expect(!v3XML.contains("<eid>"))
        // Control: the v4 encode of the same score DOES contain one, so an
        // empty match above is not proof that the probe itself is broken.
        let v4XML = try #require(String(bytes: MSCXEncoder.encode(score), encoding: .utf8))
        #expect(v4XML.contains("<eid>"))
    }
}
