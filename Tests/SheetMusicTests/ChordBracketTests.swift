import Foundation
@testable import SheetMusicCore
@testable import SheetMusicMSCX
@testable import SheetMusicXMLTools
import Testing

/// `<Chord>` fragments, not whole scores: `Chord.decode` is the unit under
/// test, and the fixture-level round trip is the preservation gate's job.
private func parseBracketChord(_ inner: String) throws -> Chord {
    let root = try XMLTreeParser.parse(Data("<Chord>\(inner)</Chord>".utf8))
    return try Chord.decode(root)
}

@Suite("ChordBracket model")
struct ChordBracketModelTests {
    @Test(arguments: ChordBracket.HookPosition.allCases)
    func hookPositionsRoundTripTheirTokens(_ position: ChordBracket.HookPosition) {
        #expect(ChordBracket.HookPosition(rawValue: position.rawValue) == position)
    }

    @Test func chordDefaultsToNoBracket() {
        let chord = Chord(
            duration: .quarter,
            notes: ChordNotes([Note(pitch: 60, tpc: 14)]),
        )
        #expect(chord.bracket == nil)
    }

    @Test func chordStoresABracket() {
        let bracket = ChordBracket(
            hookLength: 2.75,
            hookPosition: .down,
            isRightSide: true,
        )
        let chord = Chord(
            duration: .quarter,
            notes: ChordNotes([Note(pitch: 60, tpc: 14)]),
            bracket: bracket,
        )
        #expect(chord.bracket == bracket)
    }

    private func fingerprint(_ bracket: ChordBracket?) -> UInt64 {
        var hasher = FNV1a()
        hasher.combineOccupied(bracket, tag: 43)
        return hasher.value
    }

    @Test func fingerprintSeparatesModeledFields() {
        let bare = fingerprint(ChordBracket())
        #expect(bare != fingerprint(ChordBracket(hookLength: 2.75)))
        #expect(bare != fingerprint(ChordBracket(hookPosition: .up)))
        #expect(bare != fingerprint(ChordBracket(isRightSide: false)))
    }

    @Test func fingerprintSeparatesElementProperties() {
        let bare = fingerprint(ChordBracket())
        #expect(bare != fingerprint(ChordBracket(
            elementProperties: ElementProperties(visible: false),
        )))
        #expect(bare != fingerprint(ChordBracket(
            elementProperties: ElementProperties(
                color: ScoreColor(red: 10, green: 20, blue: 30, alpha: 40),
            ),
        )))
    }

    @Test func fingerprintIgnoresPreservedMarkup() {
        let bare = ChordBracket()
        let withBag = ChordBracket(
            preservedMarkup: [PreservedXML(name: "userLen1", text: "1.25")],
        )
        #expect(fingerprint(bare) == fingerprint(withBag))
    }

    @Test func fingerprintOfNoBracketFeedsNothing() {
        var hasher = FNV1a()
        let before = hasher.value
        hasher.combineOccupied(nil as ChordBracket?, tag: 43)
        #expect(hasher.value == before)
    }
}

@Suite("ChordBracket decoding")
struct ChordBracketDecodeTests {
    @Test func decodesABareBracketWithoutInventingDefaults() throws {
        let chord = try parseBracketChord("""
        <durationType>quarter</durationType>
        <Note><pitch>60</pitch><tpc>14</tpc></Note>
        <ChordBracket/>
        """)
        #expect(chord.bracket == ChordBracket())
        #expect(chord.bracket?.hookLength == nil)
        #expect(chord.bracket?.hookPosition == nil)
        #expect(chord.bracket?.isRightSide == nil)
    }

    @Test func decodesModeledFieldsAndElementProperties() throws {
        let chord = try parseBracketChord("""
        <durationType>quarter</durationType>
        <Note><pitch>60</pitch><tpc>14</tpc></Note>
        <ChordBracket>
          <bracketHookLen>2.75</bracketHookLen>
          <bracketHookPos>up</bracketHookPos>
          <bracketRightSide>0</bracketRightSide>
          <visible>0</visible>
          <color r="10" g="20" b="30" a="40"/>
        </ChordBracket>
        """)
        let bracket = try #require(chord.bracket)
        #expect(bracket.hookLength == 2.75)
        #expect(bracket.hookPosition == .up)
        #expect(bracket.isRightSide == false)
        #expect(bracket.elementProperties.visible == false)
        #expect(bracket.elementProperties.color == ScoreColor(
            red: 10, green: 20, blue: 30, alpha: 40,
        ))
    }

    @Test func nonzeroRightSideTextDecodesAsTrue() throws {
        let chord = try parseBracketChord("""
        <durationType>quarter</durationType>
        <Note><pitch>60</pitch><tpc>14</tpc></Note>
        <ChordBracket><bracketRightSide>unexpected</bracketRightSide></ChordBracket>
        """)
        #expect(chord.bracket?.isRightSide == true)
    }

    @Test func malformedTypedValuesDegradeToNil() throws {
        let chord = try parseBracketChord("""
        <durationType>quarter</durationType>
        <Note><pitch>60</pitch><tpc>14</tpc></Note>
        <ChordBracket>
          <bracketHookLen>not-a-number</bracketHookLen>
          <bracketHookPos>sideways</bracketHookPos>
        </ChordBracket>
        """)
        #expect(chord.bracket?.hookLength == nil)
        #expect(chord.bracket?.hookPosition == nil)
    }

    @Test func keepsArpeggioPropertiesAndUnknownChildrenAsPreservedMarkup() throws {
        let chord = try parseBracketChord("""
        <durationType>quarter</durationType>
        <Note><pitch>60</pitch><tpc>14</tpc></Note>
        <ChordBracket>
          <userLen1>1.25</userLen1>
          <userLen2>-0.5</userLen2>
          <span>2</span>
          <play>0</play>
          <timeStretch>1.5</timeStretch>
          <offset x="0" y="1"/>
        </ChordBracket>
        """)
        let bracket = try #require(chord.bracket)
        #expect(bracket.preservedMarkup == [
            PreservedXML(name: "userLen1", text: "1.25"),
            PreservedXML(name: "userLen2", text: "-0.5"),
            PreservedXML(name: "span", text: "2"),
            PreservedXML(name: "play", text: "0"),
            PreservedXML(name: "timeStretch", text: "1.5"),
            PreservedXML(name: "offset", attributes: ["x": "0", "y": "1"]),
        ])
    }

    @Test func bracketIsNotAlsoPreservedOnTheChord() throws {
        let chord = try parseBracketChord("""
        <durationType>quarter</durationType>
        <Note><pitch>60</pitch><tpc>14</tpc></Note>
        <ChordBracket/>
        """)
        #expect(!chord.preservedMarkup.map(\.name).contains("ChordBracket"))
    }

    @Test func aSecondBracketIsDroppedWithADiagnostic() throws {
        let root = try XMLTreeParser.parse(Data("""
        <Chord>
          <durationType>quarter</durationType>
          <Note><pitch>60</pitch><tpc>14</tpc></Note>
          <ChordBracket><bracketHookPos>up</bracketHookPos></ChordBracket>
          <ChordBracket><bracketHookPos>down</bracketHookPos></ChordBracket>
        </Chord>
        """.utf8))
        let collector = MSCXDiagnosticCollector()
        let chord = try MSCXParserContext.$collector.withValue(collector) {
            try Chord.decode(root)
        }
        #expect(chord.bracket?.hookPosition == .up)
        #expect(collector.entries.map(\.code) == ["mscx.chordBracket.duplicateDropped"])
    }
}

@Suite("ChordBracket encoding")
struct ChordBracketEncodeTests {
    @Test func bareBracketWritesNoChildren() {
        let node = ChordBracket().encode()
        #expect(node.name == "ChordBracket")
        #expect(node.children.isEmpty)
    }

    @Test func writesModeledFieldsBeforePreservedMarkupWithoutSubtype() {
        let node = ChordBracket(
            hookLength: 2.75,
            hookPosition: .down,
            isRightSide: false,
            elementProperties: ElementProperties(visible: false),
            preservedMarkup: [
                PreservedXML(name: "userLen1", text: "1.25"),
                PreservedXML(name: "timeStretch", text: "1.5"),
            ],
        ).encode()
        #expect(node.children.map(\.name) == [
            "bracketHookLen", "bracketHookPos", "bracketRightSide", "visible",
            "userLen1", "timeStretch",
        ])
        #expect(node.first("bracketHookLen")?.text == "2.75")
        #expect(node.first("bracketHookPos")?.text == "down")
        #expect(node.first("bracketRightSide")?.text == "0")
        #expect(!node.children.map(\.name).contains("subtype"))
    }

    @Test func trueRightSideWritesOne() {
        let node = ChordBracket(isRightSide: true).encode()
        #expect(node.first("bracketRightSide")?.text == "1")
    }

    @Test func preservedMarkupCanBeOmitted() {
        var options = MSCXEncoderOptions()
        options.emitPreservedMarkup = false
        let node = ChordBracket(
            preservedMarkup: [PreservedXML(name: "userLen1", text: "1.25")],
        ).encode(options: options)
        #expect(node.children.isEmpty)
    }

    @Test func chordWritesBracketAfterNotesAndArpeggio() throws {
        let chord = Chord(
            duration: .quarter,
            notes: ChordNotes([Note(pitch: 60, tpc: 14)]),
            arpeggio: Arpeggio(subtype: 0),
            bracket: ChordBracket(),
        )
        let names = chord.encodeAsChord().children.map(\.name)
        let note = try #require(names.firstIndex(of: "Note"))
        let arpeggio = try #require(names.firstIndex(of: "Arpeggio"))
        let bracket = try #require(names.firstIndex(of: "ChordBracket"))
        #expect(note < arpeggio)
        #expect(arpeggio < bracket)
    }

    @Test func restNeverWritesAChordBracket() {
        let rest = Chord(
            duration: .quarter,
            notes: ChordNotes(),
            bracket: ChordBracket(),
        )
        #expect(!rest.encodeAsRest().children.map(\.name).contains("ChordBracket"))
    }

    @Test func roundTripsEverythingModeledAndPreserved() throws {
        let decoded = try parseBracketChord("""
        <durationType>quarter</durationType>
        <Note><pitch>60</pitch><tpc>14</tpc></Note>
        <ChordBracket>
          <bracketHookLen>2.75</bracketHookLen>
          <bracketHookPos>down</bracketHookPos>
          <bracketRightSide>1</bracketRightSide>
          <visible>0</visible>
          <userLen1>1.25</userLen1>
        </ChordBracket>
        """)
        let reDecoded = try Chord.decode(decoded.encodeAsChord())
        #expect(reDecoded.bracket == decoded.bracket)
    }

    /// The preservation gate skips a fixture it cannot parse
    /// (`guard let score = try? MSCXParser.parse(source) else { continue }`),
    /// so this proves `chord-brackets.mscx` is actually being read and pins
    /// every bracket value it carries.
    @Test func fixtureDecodesEveryChordBracketItCarries() throws {
        let score = try MSCXParser.parse(MSCXFixtureLoader.mscxData("chord-brackets"))
        let chords = score.parts[0].staves[0].measures
            .flatMap { $0.voices[0].elements }
            .compactMap { element -> Chord? in
                guard case let .chord(chord) = element else { return nil }
                return chord
            }
        #expect(chords.count == 2)
        #expect(chords.map(\.notes.count) == [1, 1])

        let bare = try #require(chords[0].bracket)
        #expect(bare.hookLength == nil)
        #expect(bare.hookPosition == nil)
        #expect(bare.isRightSide == nil)
        #expect(bare.elementProperties == .default)
        #expect(bare.preservedMarkup.isEmpty)

        let populated = try #require(chords[1].bracket)
        #expect(populated.hookLength == 2.75)
        #expect(populated.hookPosition == .down)
        #expect(populated.isRightSide == true)
        #expect(populated.elementProperties.visible == false)
        #expect(populated.elementProperties.color == nil)
        #expect(populated.preservedMarkup == [
            PreservedXML(name: "userLen1", text: "1.25"),
            PreservedXML(name: "userLen2", text: "-0.5"),
            PreservedXML(name: "span", text: "2"),
            PreservedXML(name: "play", text: "0"),
            PreservedXML(name: "timeStretch", text: "1.5"),
        ])
    }

    @Test func strippingPreservedMarkupClearsTheBracketBag() throws {
        let score = try MSCXParser.parse(MSCXFixtureLoader.mscxData("chord-brackets"))
        let stripped = score.strippingPreservedMarkup()
        let chords = stripped.parts[0].staves[0].measures[0].voices[0].elements
            .compactMap { element -> Chord? in
                guard case let .chord(chord) = element else { return nil }
                return chord
            }
        #expect(chords[1].bracket?.preservedMarkup.isEmpty == true)
    }
}

/// Places `<ChordBracket>` reaches that the modeled field on `Chord` cannot
/// follow it to. Both were found by review after the first green run: the
/// suites above pass without either fix.
@Suite("ChordBracket beyond the chord decoder")
struct ChordBracketEdgeTests {
    /// `GraceChord` has no `bracket` field, and `Chord.decode` lifts
    /// `<ChordBracket>` out of the preserved-markup bag. Without the
    /// re-injection in `MSCXDecoder+Voice`, modeling the element would have
    /// *removed* it from grace chords that used to round-trip it untouched.
    @Test func graceChordKeepsItsBracketAsPreservedMarkup() throws {
        let root = try XMLTreeParser.parse(Data("""
        <voice>
          <Chord>
            <appoggiatura/>
            <durationType>eighth</durationType>
            <Note><pitch>59</pitch><tpc>15</tpc></Note>
            <ChordBracket><bracketHookPos>up</bracketHookPos></ChordBracket>
          </Chord>
          <Chord>
            <durationType>quarter</durationType>
            <Note><pitch>60</pitch><tpc>14</tpc></Note>
          </Chord>
        </voice>
        """.utf8))
        let voice = try Voice.decode(root)
        let chords = voice.elements.compactMap { element -> Chord? in
            guard case let .chord(chord) = element else { return nil }
            return chord
        }
        let grace = try #require(chords.first?.graceNotesBefore.first)
        #expect(grace.preservedMarkup.map(\.name).contains("ChordBracket"))
    }

    /// `encodeAsRest` never writes `<ChordBracket>` — read460 accepts it only
    /// on a `<Chord>` — but the fingerprint hashes it, so a bracket surviving
    /// the collapse to a rest would change `stableFingerprint` across a save
    /// and reload.
    @Test func collapsingToARestDropsTheBracket() throws {
        var score = EditingFixtures.fourQuarterRests()
        let chordVE = VoiceElementID(
            staff: StaffAddress(partIndex: 0, staffIndexInPart: 0), measureIndex: 0,
            voiceIndex: 0, elementIndex: 1,
        )
        score[chordVE] = .chord(Chord(
            duration: .quarter,
            notes: [Note(pitch: 60, tpc: 14)],
            bracket: ChordBracket(hookLength: 2.75),
        ))
        let removeID = NoteID(
            staff: StaffAddress(partIndex: 0, staffIndexInPart: 0), measureIndex: 0,
            voiceIndex: 0, elementIndex: 1, noteIndexInChord: 0,
        )
        _ = try RemoveNoteFromChord(at: removeID).apply(to: &score)
        guard case let .chord(collapsed)? = score[chordVE] else {
            Issue.record("expected the collapsed rest to still be a chord value")
            return
        }
        #expect(collapsed.notes.isEmpty)
        #expect(collapsed.bracket == nil)
    }
}
