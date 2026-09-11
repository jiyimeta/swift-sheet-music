import Foundation
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

    @Test("a column, a staff declaration and a part keep their identifiers across an encode")
    func spineIdentifiersSurviveAnEncodeDecode() throws {
        let score = try MSCXParser.parse(MSCXFixtureLoader.mscxData("midi01"))
        #expect(score.parts.count >= 1)
        // midi01.mscx:25 is <Part><Staff><eid>C_C</eid>; :88 is the first
        // <Measure>'s <eid>D_D</eid>. <Score><eid>B_B</eid> is deliberately
        // not modeled, so it is not asserted here.
        let columnEID = score.systemMeasures.eid(at: 0)
        let staffEID = score.parts[0].staves.eid(at: 0)
        let partEID = score.parts.eid(at: 0)
        #expect(columnEID == EID(string: "D_D"))
        #expect(staffEID == EID(string: "C_C"))
        #expect(partEID.isValid) // midi01.mscx has no <Part><eid> — this is our own carrier, minted at parse

        let reparsed = try MSCXParser.parse(MSCXEncoder.encode(score))
        #expect(reparsed.systemMeasures.eid(at: 0) == columnEID)
        #expect(reparsed.parts[0].staves.eid(at: 0) == staffEID)
        #expect(reparsed.parts.eid(at: 0) == partEID)
    }

    @Test("a column identifier is written on the first staff's measure only")
    func columnIdentifierIsWrittenOnce() throws {
        let score = try MSCXParser.parse(MSCXFixtureLoader.mscxData("multiPartMixedStaves"))
        // Part 1 (Violin 1, one staff) is address (0, 0) — the first staff
        // of the whole score — and top-level <Staff> #0 in document order.
        // Part 2 (Violin 2, one staff) is address (1, 0) — top-level
        // <Staff> #1 — and must NOT carry the column identifier.
        let xml = try #require(String(bytes: MSCXEncoder.encode(score), encoding: .utf8))
        #expect(try measureEIDCount(in: xml, staffIndex: 0) > 0)
        #expect(try measureEIDCount(in: xml, staffIndex: 1) == 0)
    }

    @Test("a voice-lane element (a dynamic marking) keeps the identifier the file gave it")
    func dynamicIdentifierSurvivesAnEncodeDecode() throws {
        let eid = EID(first: 5, second: 9)
        let voice = Voice(
            elements: IdentifiedArray([
                (eid, VoiceElement.dynamic(Dynamic(subtype: "mf", velocity: 80))),
            ]),
        )
        let node = try voice.encode()
        let dynamicNode = try #require(node.first("Dynamic"))
        #expect(EIDXML.decode(from: dynamicNode) == eid)

        let decoded = try Voice.decode(node)
        #expect(decoded.elements.eid(at: 0) == eid)
    }

    @Test("a voice-level Symbol keeps the identifier the file gave it, unlike a note-attached one")
    func voiceLevelSymbolIdentifierSurvivesAnEncodeDecode() throws {
        // `Symbol/eid` is one allowlist pair covering two different things in
        // MSCXPreservationGateTests: a `<Note><Symbol>` (a D9 parenthesis
        // attachment this library gives no identity) and a voice-level
        // `<Symbol>` (`VoiceElement.symbol`, which IS identified). The
        // preservation gate counts element paths and cannot tell the two
        // apart, so this is the test that actually pins the voice-level half
        // — see `noteAttachedSymbolEIDReason`.
        let eid = EID(first: 17, second: 19)
        let voice = Voice(
            elements: IdentifiedArray([
                (eid, VoiceElement.symbol(EngravingSymbol(name: "segno"))),
            ]),
        )
        let node = try voice.encode()
        let symbolNode = try #require(node.first("Symbol"))
        #expect(EIDXML.decode(from: symbolNode) == eid)

        let decoded = try Voice.decode(node)
        guard case let .symbol(decodedSymbol) = decoded.elements[0] else {
            Issue.record("expected element 0 to be a decoded .symbol")
            return
        }
        #expect(decoded.elements.eid(at: 0) == eid)
        #expect(decodedSymbol.name == "segno")
    }

    @Test("a system-lane element (a rehearsal mark) keeps the identifier the file gave it")
    func rehearsalMarkIdentifierSurvivesAnEncodeDecode() throws {
        let eid = EID(first: 11, second: 13)
        let mark = RehearsalMark(text: "A")
        let score = Score(
            division: 480,
            parts: [Part(
                id: "1",
                instrument: Instrument(id: "voice"),
                staves: [Staff(measures: [Measure(voices: [Voice(elements: [])])])],
            )],
            systemMeasures: [SystemMeasure(elements: IdentifiedArray([
                (eid, PositionedSystemElement(position: .start, element: .rehearsalMark(mark))),
            ]))],
        )
        let bytes = try MSCXEncoder.encode(score)
        let xml = try #require(String(bytes: bytes, encoding: .utf8))
        #expect(xml.contains("<eid>"))

        let decoded = try MSCXParser.parse(bytes)
        #expect(decoded.systemMeasures.first?.elements.eid(at: 0) == eid)
        guard case let .rehearsalMark(reparsed) = decoded.systemMeasures.first?.elements.first?.element
        else {
            Issue.record("expected a decoded .rehearsalMark")
            return
        }
        #expect(reparsed.text == "A")
    }

    @Test("a tuplet keeps the identifier the file gave it")
    func tupletIdentifierSurvivesAnEncodeDecode() throws {
        // The repo's only <Tuplet> fixture; own/grace-notes.mscx:70-73
        // carries <eid>Z_Z</eid> as the Tuplet's own first child — no
        // other committed fixture has a Tuplet/eid pair at all.
        let score = try MSCXParser.parse(MSCXFixtureLoader.mscxData("grace-notes"))
        let voice = score.parts[0].staves[0].measures[1].voices[0]
        let tupletEID = voice.tuplets.eid(at: 0)
        #expect(tupletEID == EID(string: "Z_Z"))

        let reparsed = try MSCXParser.parse(MSCXEncoder.encode(score))
        let reparsedVoice = reparsed.parts[0].staves[0].measures[1].voices[0]
        #expect(reparsedVoice.tuplets.eid(at: 0) == tupletEID)
    }

    @Test("a preserved element round-trips with exactly one identifier")
    func preservedElementCarriesExactlyOneEID() throws {
        let unmodeled = XMLTreeNode(
            name: "FutureElement",
            children: [XMLTreeNode(name: "eid", text: "Q_Q")],
        )
        let decoded = try Voice.decodeWithSystemElements(
            XMLTreeNode(name: "voice", children: [unmodeled]),
        )
        guard case .preserved = decoded.voice.elements[0] else {
            Issue.record("expected element 0 to be a preserved element")
            return
        }
        // The slot's own identifier stays unassigned — the source
        // <eid> was captured verbatim inside the preserved bag
        // instead, not decoded a second time into the slot.
        #expect(decoded.voice.elements.eid(at: 0) == .invalid)

        let reencoded = try decoded.voice.encode()
        let futureNode = try #require(reencoded.first("FutureElement"))
        #expect(futureNode.all("eid").count == 1)
        #expect(futureNode.first("eid")?.text == "Q_Q")
    }

    /// Number of `<Measure>` children carrying an `<eid>` under the
    /// `staffIndex`-th top-level `<Staff>` (document-order, 0-based) —
    /// walked via `XMLTreeNode`, not string search, so a parser that
    /// finds nothing is not mistaken for a fixture that has nothing.
    private func measureEIDCount(in xml: String, staffIndex: Int) throws -> Int {
        let root = try XMLTreeParser.parse(Data(xml.utf8))
        let scoreNode = try #require(root.first("Score"))
        // Direct children only, so this only ever sees top-level
        // <Staff> — a <Part><Staff> declaration is nested one level
        // deeper and `all(_:)` does not recurse into it.
        let topLevelStaves = scoreNode.all("Staff")
        let staff = try #require(topLevelStaves[safe: staffIndex])
        return staff.all("Measure").filter { EIDXML.decode(from: $0).isValid }.count
    }
}

extension Array {
    fileprivate subscript(safe index: Int) -> Element? {
        indices.contains(index) ? self[index] : nil
    }
}
