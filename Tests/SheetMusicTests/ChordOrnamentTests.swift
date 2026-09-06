import Foundation
@testable import SheetMusicCore
@testable import SheetMusicMSCX
@testable import SheetMusicXMLTools
import Testing

@Suite("ChordOrnament model")
struct ChordOrnamentModelTests {
    @Test func knownKindRoundTripsItsToken() {
        #expect(ChordOrnament.Kind(mscxToken: "ornamentTrill") == .trill)
        #expect(ChordOrnament.Kind.turnInverted.mscxToken == "ornamentTurnInverted")
        #expect(ChordOrnament.Kind(mscxToken: "ornamentNotAThing") == nil)
    }

    @Test func everyModeledKindHasADistinctTokenThatParsesBack() {
        var seen: Set<String> = []
        for kind in ChordOrnament.Kind.modeled {
            let token = kind.mscxToken
            #expect(token.hasPrefix("ornament"), "\(token) is not a SymId name")
            #expect(seen.insert(token).inserted, "duplicate token \(token)")
            #expect(ChordOrnament.Kind(mscxToken: token) == kind)
        }
        #expect(seen.count == 23)
    }

    @Test func unknownKeepsItsRawToken() {
        let kind = ChordOrnament.Kind.unknown(subtype: "ornamentNotAThing")
        #expect(kind.mscxToken == "ornamentNotAThing")
        #expect(kind != .trill)
    }

    @Test func intervalDefaultMatchesMuseScore() {
        #expect(ChordOrnament.Interval.default == .init(step: .second, quality: .auto))
        #expect(ChordOrnament.Interval.default.mscxToken == "second,auto")
    }

    @Test func intervalParsesTheWrittenPair() {
        #expect(
            ChordOrnament.Interval(mscxToken: "third,major")
                == .init(step: .third, quality: .major),
        )
    }

    @Test(arguments: ["", "third", "third,major,extra", "ninth,major", "third,wobbly"])
    func malformedIntervalFallsBackPerField(_ token: String) {
        // TConv::fromXml(const String&, OrnamentInterval) logs and keeps the
        // default rather than rejecting; a bad step keeps the default step and
        // a good quality still lands.
        let interval = ChordOrnament.Interval(mscxToken: token)
        #expect(interval.step == .second || interval.step == .third)
        #expect(interval.quality == .auto || interval.quality == .major)
    }

    @Test func chordDefaultsToNoOrnaments() {
        let chord = Chord(duration: .quarter, notes: ChordNotes([Note(pitch: 60, tpc: 14)]))
        #expect(chord.ornaments.isEmpty)
    }

    @Test func chordStoresOrnaments() {
        let chord = Chord(
            duration: .quarter,
            notes: ChordNotes([Note(pitch: 60, tpc: 14)]),
            ornaments: [ChordOrnament(
                kind: .trill,
                intervalAbove: .init(step: .third, quality: .major),
            )],
        )
        #expect(chord.ornaments.count == 1)
        #expect(chord.ornaments[0].intervalAbove == .init(step: .third, quality: .major))
    }

    private func fingerprint(_ ornaments: [ChordOrnament]) -> UInt64 {
        var hasher = FNV1a()
        hasher.combineOccupied(ornaments, tag: 33)
        return hasher.value
    }

    @Test func fingerprintSeparatesOrnamentKinds() {
        #expect(fingerprint([.init(kind: .trill)]) != fingerprint([.init(kind: .mordent)]))
    }

    @Test func fingerprintSeparatesAbsentFromExplicitlyFalse() {
        #expect(
            fingerprint([.init(kind: .trill, startOnUpperNote: nil)])
                != fingerprint([.init(kind: .trill, startOnUpperNote: false)]),
        )
    }

    @Test func fingerprintIgnoresPreservedMarkup() {
        let bare = ChordOrnament(kind: .trill)
        let withBag = ChordOrnament(
            kind: .trill,
            preservedMarkup: [PreservedXML(name: "Chord")],
        )
        #expect(fingerprint([bare]) == fingerprint([withBag]))
    }

    @Test func fingerprintOfNoOrnamentsFeedsNothing() {
        var hasher = FNV1a()
        let before = hasher.value
        hasher.combineOccupied([] as [ChordOrnament], tag: 33)
        #expect(hasher.value == before)
    }
}

/// `<Chord>` fragments, not whole scores: `Chord.decode` is the unit under
/// test, and the fixture-level round trip is the preservation gate's job.
private func parseChord(_ inner: String) throws -> Chord {
    let root = try XMLTreeParser.parse(Data("<Chord>\(inner)</Chord>".utf8))
    return try Chord.decode(root)
}

@Suite("ChordOrnament decoding")
struct ChordOrnamentDecodeTests {
    @Test func decodesBareTrill() throws {
        let chord = try parseChord("""
        <durationType>quarter</durationType>
        <Ornament><subtype>ornamentTrill</subtype></Ornament>
        <Note><pitch>60</pitch><tpc>14</tpc></Note>
        """)
        #expect(chord.ornaments == [ChordOrnament(kind: .trill)])
        #expect(chord.articulations.isEmpty)
    }

    @Test func decodesIntervalsAccidentalsAndFlags() throws {
        let chord = try parseChord("""
        <durationType>half</durationType>
        <Ornament>
          <Accidental><subtype>accidentalSharp</subtype><placement>above</placement></Accidental>
          <Accidental><subtype>accidentalFlat</subtype></Accidental>
          <intervalAbove>second,major</intervalAbove>
          <intervalBelow>third,minor</intervalBelow>
          <ornamentShowAccidental>2</ornamentShowAccidental>
          <ornamentShowCueNote>on</ornamentShowCueNote>
          <startOnUpperNote>1</startOnUpperNote>
          <subtype>ornamentTurn</subtype>
          <play>0</play>
          <ornamentStyle>baroque</ornamentStyle>
        </Ornament>
        <Note><pitch>60</pitch><tpc>14</tpc></Note>
        """)
        let ornament = try #require(chord.ornaments.first)
        #expect(ornament.kind == .turn)
        #expect(ornament.intervalAbove == .init(step: .second, quality: .major))
        #expect(ornament.intervalBelow == .init(step: .third, quality: .minor))
        #expect(ornament.showAccidental == .always)
        #expect(ornament.showCueNote == .on)
        #expect(ornament.startOnUpperNote == true)
        #expect(ornament.ornamentStyle == .baroque)
        #expect(ornament.plays == false)
        #expect(ornament.accidentalAbove == .sharp)
        #expect(ornament.accidentalBelow == .flat)
    }

    @Test func absentTagsStayNilRatherThanTakingADefault() throws {
        let chord = try parseChord("""
        <durationType>quarter</durationType>
        <Ornament><subtype>ornamentMordent</subtype></Ornament>
        <Note><pitch>60</pitch><tpc>14</tpc></Note>
        """)
        let ornament = try #require(chord.ornaments.first)
        #expect(ornament.intervalAbove == nil)
        #expect(ornament.intervalBelow == nil)
        #expect(ornament.showAccidental == nil)
        #expect(ornament.showCueNote == nil)
        #expect(ornament.startOnUpperNote == nil)
        #expect(ornament.ornamentStyle == nil)
        #expect(ornament.plays == nil)
    }

    @Test func decodesSeveralOrnamentsInDocumentOrder() throws {
        let chord = try parseChord("""
        <durationType>quarter</durationType>
        <Ornament><subtype>ornamentTurn</subtype></Ornament>
        <Ornament><subtype>ornamentMordent</subtype></Ornament>
        <Note><pitch>60</pitch><tpc>14</tpc></Note>
        """)
        #expect(chord.ornaments.map(\.kind) == [.turn, .mordent])
    }

    @Test func keepsUnknownSubtypeAndCueNoteWhileModelingPlacement() throws {
        let chord = try parseChord("""
        <durationType>quarter</durationType>
        <Ornament>
          <Chord><durationType>eighth</durationType>
                 <Note><pitch>62</pitch><tpc>16</tpc></Note></Chord>
          <subtype>ornamentNotAThing</subtype>
          <placement>below</placement>
        </Ornament>
        <Note><pitch>60</pitch><tpc>14</tpc></Note>
        """)
        let ornament = try #require(chord.ornaments.first)
        #expect(ornament.kind == .unknown(subtype: "ornamentNotAThing"))
        #expect(ornament.elementProperties.placement == .below)
        #expect(ornament.preservedMarkup.map(\.name) == ["Chord"])
    }

    @Test func ornamentIsNotAlsoPreservedOnTheChord() throws {
        let chord = try parseChord("""
        <durationType>quarter</durationType>
        <Ornament><subtype>ornamentTrill</subtype></Ornament>
        <Note><pitch>60</pitch><tpc>14</tpc></Note>
        """)
        #expect(!chord.preservedMarkup.map(\.name).contains("Ornament"))
    }

    @Test func museScore3OrnamentArticulationsAreStillArticulations() throws {
        // MuseScore 3 wrote ornaments as <Articulation> with an ornament SymId.
        // Converting them here would change the element shape a round trip
        // produces; compat migration is a separate concern from parity.
        let chord = try parseChord("""
        <durationType>quarter</durationType>
        <Articulation><subtype>ornamentTrill</subtype></Articulation>
        <Note><pitch>60</pitch><tpc>14</tpc></Note>
        """)
        #expect(chord.ornaments.isEmpty)
        #expect(chord.articulations == [
            ChordArticulation(kind: .unknown(subtype: "ornamentTrill")),
        ])
    }

    @Test func hiddenOrnamentKeepsItsVisibility() throws {
        let chord = try parseChord("""
        <durationType>quarter</durationType>
        <Ornament><subtype>ornamentTrill</subtype><visible>0</visible></Ornament>
        <Note><pitch>60</pitch><tpc>14</tpc></Note>
        """)
        let ornament = try #require(chord.ornaments.first)
        #expect(ornament.elementProperties.visible == false)
        #expect(ornament.preservedMarkup.isEmpty)
    }
}

@Suite("ChordOrnament encoding")
struct ChordOrnamentEncodeTests {
    @Test func writesMuseScoreChildOrder() {
        let ornament = ChordOrnament(
            kind: .turn,
            intervalAbove: .init(step: .second, quality: .major),
            intervalBelow: .init(step: .third, quality: .minor),
            showAccidental: .always,
            showCueNote: .on,
            startOnUpperNote: true,
            ornamentStyle: .baroque,
            plays: false,
            accidentalAbove: .sharp,
            accidentalBelow: .flat,
        )
        let node = ornament.encode()
        #expect(node.name == "Ornament")
        #expect(node.children.map(\.name) == [
            "Accidental", "Accidental", "intervalAbove", "intervalBelow",
            "ornamentShowAccidental", "ornamentShowCueNote", "startOnUpperNote",
            "subtype", "play", "ornamentStyle",
        ])
        #expect(node.first("intervalAbove")?.text == "second,major")
        #expect(node.first("ornamentShowAccidental")?.text == "2")
        #expect(node.first("ornamentShowCueNote")?.text == "on")
        #expect(node.first("startOnUpperNote")?.text == "1")
        #expect(node.first("play")?.text == "0")
        #expect(node.first("ornamentStyle")?.text == "baroque")
    }

    @Test func placesTheAboveAccidentalByItsPlacementTag() {
        let node = ChordOrnament(kind: .trill, accidentalAbove: .sharp, accidentalBelow: .flat)
            .encode()
        let accidentals = node.all("Accidental")
        #expect(accidentals.count == 2)
        #expect(accidentals[0].first("subtype")?.text == "accidentalSharp")
        #expect(accidentals[0].first("placement")?.text == "above")
        #expect(accidentals[1].first("subtype")?.text == "accidentalFlat")
        #expect(!accidentals[1].children.contains { $0.name == "placement" })
    }

    @Test func omitsEverythingUnset() {
        let node = ChordOrnament(kind: .trill).encode()
        #expect(node.children.map(\.name) == ["subtype"])
        #expect(node.first("subtype")?.text == "ornamentTrill")
    }

    @Test func writesPreservedMarkupAfterItsOwnChildren() {
        let node = ChordOrnament(
            kind: .trill,
            preservedMarkup: [PreservedXML(name: "Chord")],
        ).encode()
        #expect(node.children.map(\.name) == ["subtype", "Chord"])
    }

    @Test func preservedMarkupIsOmittedWhenTheCallerAsks() {
        var options = MSCXEncoderOptions()
        options.emitPreservedMarkup = false
        let node = ChordOrnament(
            kind: .trill,
            preservedMarkup: [PreservedXML(name: "Chord")],
        ).encode(options: options)
        #expect(node.children.map(\.name) == ["subtype"])
    }

    @Test func v3TargetDegradesToArticulation() {
        let node = ChordOrnament(
            kind: .mordent,
            intervalAbove: .init(step: .third, quality: .major),
        ).encode(options: MSCXEncoderOptions(targetVersion: .v3))
        #expect(node.name == "Articulation")
        #expect(node.children.map(\.name) == ["subtype"])
        #expect(node.first("subtype")?.text == "ornamentMordent")
    }

    @Test func v3TargetKeepsVisibilityWhichIsNotOrnamentOnlyState() {
        var ornament = ChordOrnament(kind: .trill)
        ornament.elementProperties.visible = false
        let node = ornament.encode(options: MSCXEncoderOptions(targetVersion: .v3))
        #expect(node.children.map(\.name) == ["subtype", "visible"])
        #expect(node.first("visible")?.text == "0")
    }

    @Test func chordEncodesOrnamentsAfterArticulationsAndBeforeNotes() throws {
        let chord = Chord(
            duration: .quarter,
            notes: ChordNotes([Note(pitch: 60, tpc: 14)]),
            articulations: [ChordArticulation(kind: .staccato, anchor: .above)],
            ornaments: [ChordOrnament(kind: .trill)],
        )
        let names = chord.encodeAsChord().children.map(\.name)
        let articulation = try #require(names.firstIndex(of: "Articulation"))
        let ornament = try #require(names.firstIndex(of: "Ornament"))
        let note = try #require(names.firstIndex(of: "Note"))
        #expect(articulation < ornament)
        #expect(ornament < note)
    }

    @Test func roundTripsEverythingModeled() throws {
        let source = """
        <durationType>quarter</durationType>
        <Ornament>
          <Accidental><subtype>accidentalSharp</subtype><placement>above</placement></Accidental>
          <Accidental><subtype>accidentalNatural</subtype></Accidental>
          <intervalAbove>third,major</intervalAbove>
          <intervalBelow>second,minor</intervalBelow>
          <ornamentShowAccidental>1</ornamentShowAccidental>
          <ornamentShowCueNote>off</ornamentShowCueNote>
          <startOnUpperNote>1</startOnUpperNote>
          <subtype>ornamentTrill</subtype>
          <play>0</play>
          <ornamentStyle>baroque</ornamentStyle>
        </Ornament>
        <Note><pitch>60</pitch><tpc>14</tpc></Note>
        """
        let decoded = try parseChord(source)
        let reDecoded = try Chord.decode(decoded.encodeAsChord())
        #expect(reDecoded.ornaments == decoded.ornaments)
    }

    /// The preservation gate skips a fixture it cannot parse
    /// (`guard let score = try? MSCXParser.parse(source) else { continue }`),
    /// so a gate pass alone would not prove `ornaments.mscx` is being read.
    /// This is what pins that it is, and what it decodes to.
    @Test func fixtureDecodesEveryOrnamentItCarries() throws {
        let score = try MSCXParser.parse(MSCXFixtureLoader.mscxData("ornaments"))
        let chords = score.parts[0].staves[0].measures
            .flatMap { $0.voices[0].elements }
            .compactMap { element -> Chord? in
                guard case let .chord(chord) = element else { return nil }
                return chord
            }
        #expect(chords.flatMap(\.ornaments).map(\.kind) == [
            .trill, .turn, .mordent, .pinceCouperin,
            .turnInverted, .unknown(subtype: "ornamentNotInThisLibrary"),
        ])
        let turn = try #require(chords[1].ornaments.first)
        #expect(turn.accidentalAbove == .sharp)
        #expect(turn.accidentalBelow == .flat)
        #expect(turn.intervalAbove == .init(step: .third, quality: .major))
        #expect(turn.showAccidental == .always)
        #expect(chords[2].ornaments[0].elementProperties.visible == false)
        #expect(chords[4].ornaments[0].preservedMarkup.map(\.name) == ["Chord"])
        #expect(chords[5].ornaments[0].preservedMarkup.map(\.name) == ["direction"])
    }

    @Test func roundTripsTheCueNoteChordThroughPreservedMarkup() throws {
        let decoded = try parseChord("""
        <durationType>quarter</durationType>
        <Ornament>
          <Chord><durationType>eighth</durationType>
                 <Note><pitch>62</pitch><tpc>16</tpc></Note></Chord>
          <subtype>ornamentTurn</subtype>
        </Ornament>
        <Note><pitch>60</pitch><tpc>14</tpc></Note>
        """)
        let ornamentNode = try #require(decoded.encodeAsChord().first("Ornament"))
        let cueNote = try #require(ornamentNode.first("Chord"))
        #expect(cueNote.first("Note")?.first("pitch")?.text == "62")
    }
}
