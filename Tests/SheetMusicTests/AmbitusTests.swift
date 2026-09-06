import Foundation
@testable import SheetMusicCore
@testable import SheetMusicMSCX
@testable import SheetMusicXMLTools
import Testing

private let bareAmbitusXML = """
<Ambitus>
  <topPitch>60</topPitch><topTpc>14</topTpc>
  <bottomPitch>48</bottomPitch><bottomTpc>14</bottomTpc>
</Ambitus>
"""

private func ambitusScore(_ inner: String) throws -> Score {
    try MSCXParser.parse(Data("""
    <?xml version="1.0" encoding="UTF-8"?>
    <museScore version="4.60">
      <Score>
        <Division>480</Division>
        <Part>
          <Staff id="1"/>
          <Instrument id="piano"><trackName>Piano</trackName><Channel/></Instrument>
        </Part>
        <Staff id="1">
          <Measure><voice>\(inner)</voice></Measure>
        </Staff>
      </Score>
    </museScore>
    """.utf8))
}

private func firstAmbitusVoiceElements(in score: Score) -> [VoiceElement] {
    score.parts[0].staves[0].measures[0].voices[0].elements
}

private func ambitusVoiceElements(_ inner: String) throws -> [VoiceElement] {
    try firstAmbitusVoiceElements(in: ambitusScore(inner))
}

private func ambitusValue(_ element: VoiceElement?) -> Ambitus? {
    guard case let .ambitus(value)? = element else { return nil }
    return value
}

private func fingerprint(_ element: VoiceElement) -> UInt64 {
    var hasher = FNV1a()
    hasher.combine(element)
    return hasher.value
}

@Suite("Ambitus model")
struct AmbitusModelTests {
    @Test func defaultsMatchMuseScoreWriterDefaults() {
        let ambitus = Ambitus(topPitch: 79, topTpc: 16, bottomPitch: 55, bottomTpc: 16)
        #expect(ambitus.hasLine)
        #expect(ambitus.noteHeadGroup == nil)
        #expect(ambitus.noteHeadType == nil)
        #expect(ambitus.mirror == nil)
        #expect(ambitus.lineWidth == nil)
        #expect(ambitus.topAccidental == nil)
        #expect(ambitus.bottomAccidental == nil)
    }

    @Test func noteHeadTypesRoundTripKnownAndUnknownOrdinals() {
        let known: [(Int, Ambitus.NoteHeadType)] = [
            (-1, .auto), (0, .whole), (1, .half), (2, .quarter), (3, .brevis),
        ]
        for (ordinal, value) in known {
            #expect(Ambitus.NoteHeadType(mscxOrdinal: ordinal) == value)
            #expect(value.mscxOrdinal == ordinal)
        }
        let unknown = Ambitus.NoteHeadType(mscxOrdinal: 99)
        #expect(unknown == .other(rawValue: 99))
        #expect(unknown.mscxOrdinal == 99)
    }

    @Test func mirrorsRoundTripKnownAndUnknownOrdinals() {
        let known: [(Int, Ambitus.Mirror)] = [(0, .auto), (1, .left), (2, .right)]
        for (ordinal, value) in known {
            #expect(Ambitus.Mirror(mscxOrdinal: ordinal) == value)
            #expect(value.mscxOrdinal == ordinal)
        }
        let unknown = Ambitus.Mirror(mscxOrdinal: 99)
        #expect(unknown == .other(rawValue: 99))
        #expect(unknown.mscxOrdinal == 99)
    }

    @Test func visibilityWritesThroughToElementProperties() {
        var ambitus = Ambitus(topPitch: 79, topTpc: 16, bottomPitch: 55, bottomTpc: 16)
        ambitus.visible = false
        #expect(!ambitus.visible)
        #expect(!ambitus.elementProperties.visible)
    }

    @Test func fingerprintCoversAmbitusFieldsAndPresence() {
        let base = Ambitus(topPitch: 79, topTpc: 16, bottomPitch: 55, bottomTpc: 16)
        let hash = fingerprint(.ambitus(base))
        #expect(hash != fingerprint(.ambitus(Ambitus(
            topPitch: 80, topTpc: 16, bottomPitch: 55, bottomTpc: 16,
        ))))
        #expect(hash != fingerprint(.ambitus(Ambitus(
            topPitch: 79, topTpc: 16, bottomPitch: 55, bottomTpc: -1,
        ))))

        var changed = base
        changed.hasLine = false
        #expect(hash != fingerprint(.ambitus(changed)))
        changed = base
        changed.mirror = .auto
        #expect(hash != fingerprint(.ambitus(changed)))
        changed = base
        changed.noteHeadType = .whole
        #expect(hash != fingerprint(.ambitus(changed)))
        #expect(hash != fingerprint(.capo(Capo(fretPosition: 79, text: ""))))
    }
}

@Suite("Ambitus MSCX round trip")
struct AmbitusMSCXTests {
    @Test func decodesBareAmbitusAtItsVoicePositionWithDefaults() throws {
        let elements = try ambitusVoiceElements("""
        <Chord><durationType>quarter</durationType><Note><pitch>60</pitch><tpc>14</tpc></Note></Chord>
        \(bareAmbitusXML)
        <Chord><durationType>quarter</durationType><Note><pitch>62</pitch><tpc>16</tpc></Note></Chord>
        """)
        try #require(elements.count == 3)
        guard case .chord = elements[0],
              case let .ambitus(ambitus) = elements[1],
              case .chord = elements[2]
        else {
            Issue.record("expected chord, ambitus, chord")
            return
        }
        #expect(ambitus.hasLine)
        #expect(ambitus.noteHeadType == nil)
        #expect(ambitus.mirror == nil)
    }

    @Test func distinguishesAbsentHasLineFromExplicitZero() throws {
        let absent = try #require(try ambitusValue(ambitusVoiceElements(bareAmbitusXML).first))
        let explicit = try #require(try ambitusValue(ambitusVoiceElements("""
        <Ambitus><hasLine>0</hasLine><topPitch>60</topPitch><topTpc>14</topTpc>
        <bottomPitch>48</bottomPitch><bottomTpc>14</bottomTpc></Ambitus>
        """).first))
        #expect(absent.hasLine)
        #expect(!explicit.hasLine)
    }

    @Test func decodesMuseScore46OrdinalAppearanceValues() throws {
        let value = try #require(try ambitusValue(ambitusVoiceElements("""
        <Ambitus><headType>2</headType><mirror>1</mirror>
        <topPitch>60</topPitch><topTpc>14</topTpc>
        <bottomPitch>48</bottomPitch><bottomTpc>14</bottomTpc></Ambitus>
        """).first))
        #expect(value.noteHeadType == .quarter)
        #expect(value.mirror == .left)
    }

    @Test func decodesMuseScore5NameAppearanceValues() throws {
        let value = try #require(try ambitusValue(ambitusVoiceElements("""
        <Ambitus><headType>quarter</headType><mirror>left</mirror>
        <topPitch>60</topPitch><topTpc>14</topTpc>
        <bottomPitch>48</bottomPitch><bottomTpc>14</bottomTpc></Ambitus>
        """).first))
        #expect(value.noteHeadType == .quarter)
        #expect(value.mirror == .left)
    }

    @Test func retainsUnknownOrdinalAndDropsUnknownName() throws {
        let elements = try ambitusVoiceElements("""
        <Ambitus><headType>99</headType><topPitch>60</topPitch><topTpc>14</topTpc>
        <bottomPitch>48</bottomPitch><bottomTpc>14</bottomTpc></Ambitus>
        <Ambitus><headType>future</headType><topPitch>60</topPitch><topTpc>14</topTpc>
        <bottomPitch>48</bottomPitch><bottomTpc>14</bottomTpc></Ambitus>
        """)
        let ordinal = try #require(ambitusValue(elements.first))
        let name = try #require(ambitusValue(elements.last))
        #expect(ordinal.noteHeadType == .other(rawValue: 99))
        #expect(name.noteHeadType == nil)
    }

    @Test func preservesOrdinalAndNameHeadTextVerbatim() throws {
        let elements = try ambitusVoiceElements("""
        <Ambitus><head>5</head><topPitch>60</topPitch><topTpc>14</topTpc>
        <bottomPitch>48</bottomPitch><bottomTpc>14</bottomTpc></Ambitus>
        <Ambitus><head>cross</head><topPitch>60</topPitch><topTpc>14</topTpc>
        <bottomPitch>48</bottomPitch><bottomTpc>14</bottomTpc></Ambitus>
        """)
        #expect(try #require(ambitusValue(elements.first)).noteHeadGroup == "5")
        #expect(try #require(ambitusValue(elements.last)).noteHeadGroup == "cross")
    }

    @Test func retainsPitchAndTpcValuesWithoutNormalization() throws {
        let value = try #require(try ambitusValue(ambitusVoiceElements("""
        <Ambitus><topPitch>91</topPitch><topTpc>-7</topTpc>
        <bottomPitch>22</bottomPitch><bottomTpc>31</bottomTpc></Ambitus>
        """).first))
        #expect(value.topPitch == 91)
        #expect(value.topTpc == -7)
        #expect(value.bottomPitch == 22)
        #expect(value.bottomTpc == 31)
    }

    @Test func decodesKnownAccidentalsAndDropsUnknownSubtype() throws {
        let elements = try ambitusVoiceElements("""
        <Ambitus><topPitch>60</topPitch><topTpc>14</topTpc><bottomPitch>48</bottomPitch><bottomTpc>14</bottomTpc>
          <topAccidental><Accidental><subtype>accidentalSharp</subtype></Accidental></topAccidental>
          <bottomAccidental><Accidental><subtype>accidentalFlat</subtype></Accidental></bottomAccidental>
        </Ambitus>
        <Ambitus><topPitch>60</topPitch><topTpc>14</topTpc><bottomPitch>48</bottomPitch><bottomTpc>14</bottomTpc>
          <topAccidental><Accidental><subtype>futureAccidental</subtype></Accidental></topAccidental>
        </Ambitus>
        """)
        let known = try #require(ambitusValue(elements.first))
        let unknown = try #require(ambitusValue(elements.last))
        #expect(known.topAccidental == .sharp)
        #expect(known.bottomAccidental == .flat)
        #expect(unknown.topAccidental == nil)
    }

    /// `<placement>` was preserved markup when this suite was written; the
    /// shared `ElementProperties` now owns it, so the bag is empty and the
    /// value is typed. Same input, same guarantee, different owner.
    @Test func modelsPlacementOnTheSharedBaseInsteadOfPreservingIt() throws {
        let value = try #require(try ambitusValue(ambitusVoiceElements("""
        <Ambitus><topPitch>60</topPitch><topTpc>14</topTpc>
        <bottomPitch>48</bottomPitch><bottomTpc>14</bottomTpc><placement>above</placement></Ambitus>
        """).first))
        #expect(value.preservedMarkup.isEmpty)
        #expect(value.elementProperties.placement == .above)
    }

    @Test func encodesCanonicalChildOrderAndOrdinalMirror() {
        let bare = Ambitus(topPitch: 60, topTpc: 14, bottomPitch: 48, bottomTpc: 14).encode()
        #expect(bare.name == "Ambitus")
        #expect(bare.children.map(\.name) == [
            "topPitch", "topTpc", "bottomPitch", "bottomTpc",
        ])

        let styled = Ambitus(
            topPitch: 60, topTpc: 14, bottomPitch: 48, bottomTpc: 14,
            mirror: .right, hasLine: false,
        ).encode()
        #expect(styled.children.map(\.name) == [
            "mirror", "hasLine", "topPitch", "topTpc", "bottomPitch", "bottomTpc",
        ])
        #expect(styled.first("mirror")?.text == "2")
        #expect(styled.first("hasLine")?.text == "0")
    }

    @Test func wholeScoreRoundTripPreservesVoiceElements() throws {
        let first = try ambitusScore("""
        <Chord><durationType>quarter</durationType><Note><pitch>60</pitch><tpc>14</tpc></Note></Chord>
        <Ambitus><head>5</head><headType>quarter</headType><mirror>left</mirror>
        <topPitch>79</topPitch><topTpc>16</topTpc><bottomPitch>55</bottomPitch><bottomTpc>16</bottomTpc>
        <placement>above</placement></Ambitus>
        """)
        let reparsed = try MSCXParser.parse(MSCXEncoder.encode(first))
        #expect(firstAmbitusVoiceElements(in: reparsed) == firstAmbitusVoiceElements(in: first))
    }

    @Test func allAbsentAppearanceFieldsAreIdempotent() throws {
        let first = try #require(try ambitusValue(ambitusVoiceElements(bareAmbitusXML).first))
        let second = Ambitus.decode(first.encode())
        #expect(second == first)
    }
}

@Suite("Ambitus fixture")
struct AmbitusFixtureTests {
    /// The preservation gate skips an unreadable fixture, so this proves the
    /// fixture parses and every ambitus it carries reaches the model.
    @Test func fixtureDecodesEveryAmbitusItCarries() throws {
        let score = try MSCXParser.parse(MSCXFixtureLoader.mscxData("ambitus"))
        try #require(score.parts.count == 1)
        let part = try #require(score.parts.first)
        try #require(part.staves.count == 1)
        let staff = try #require(part.staves.first)
        try #require(staff.measures.count == 3)
        try expectBareFixtureMeasure(staff.measures[0])
        try expectAppearanceFixtureMeasure(staff.measures[1])
        try expectAccidentalFixtureMeasure(staff.measures[2])
    }

    private func expectBareFixtureMeasure(_ measure: Measure) throws {
        let elements = try #require(measure.voices.first).elements
        try #require(elements.count == 2)
        let ambitus = try #require(ambitusValue(elements.first))
        guard case .chord = elements[1] else {
            Issue.record("measure 0 element sequence did not match the fixture")
            return
        }
        #expect(ambitus.topPitch == 79)
        #expect(ambitus.topTpc == 16)
        #expect(ambitus.bottomPitch == 55)
        #expect(ambitus.bottomTpc == 16)
        #expect(ambitus.noteHeadGroup == nil)
        #expect(ambitus.noteHeadType == nil)
        #expect(ambitus.mirror == nil)
        #expect(ambitus.hasLine)
        #expect(ambitus.lineWidth == nil)
        #expect(ambitus.topAccidental == nil)
        #expect(ambitus.bottomAccidental == nil)
        #expect(ambitus.elementProperties == .default)
        #expect(ambitus.preservedMarkup.isEmpty)
    }

    private func expectAppearanceFixtureMeasure(_ measure: Measure) throws {
        let elements = try #require(measure.voices.first).elements
        try #require(elements.count == 2)
        let ambitus = try #require(ambitusValue(elements.first))
        guard case .chord = elements[1] else {
            Issue.record("measure 1 element sequence did not match the fixture")
            return
        }
        #expect(ambitus.noteHeadGroup == "5")
        #expect(ambitus.noteHeadType == .quarter)
        #expect(ambitus.mirror == .left)
        #expect(!ambitus.hasLine)
        #expect(ambitus.lineWidth == 0.5)
        #expect(ambitus.topPitch == 84)
        #expect(ambitus.topTpc == 14)
        #expect(ambitus.bottomPitch == 60)
        #expect(ambitus.bottomTpc == 14)
        #expect(ambitus.topAccidental == nil)
        #expect(ambitus.bottomAccidental == nil)
        #expect(ambitus.elementProperties == .default)
        #expect(ambitus.preservedMarkup.isEmpty)
    }

    private func expectAccidentalFixtureMeasure(_ measure: Measure) throws {
        let elements = try #require(measure.voices.first).elements
        try #require(elements.count == 2)
        let ambitus = try #require(ambitusValue(elements.first))
        guard case .chord = elements[1] else {
            Issue.record("measure 2 element sequence did not match the fixture")
            return
        }
        #expect(ambitus.topPitch == 78)
        #expect(ambitus.topTpc == 20)
        #expect(ambitus.bottomPitch == 58)
        #expect(ambitus.bottomTpc == 12)
        #expect(ambitus.noteHeadGroup == nil)
        #expect(ambitus.noteHeadType == nil)
        #expect(ambitus.mirror == nil)
        #expect(ambitus.hasLine)
        #expect(ambitus.lineWidth == nil)
        #expect(ambitus.topAccidental == .sharp)
        #expect(ambitus.bottomAccidental == .flat)
        // The fixture's `<placement>` used to land in the bag; the shared
        // `ElementProperties` owns it now, so the bag is empty and the rest of
        // the base properties are still at their defaults.
        #expect(ambitus.elementProperties.placement == .above)
        #expect(ambitus.elementProperties.visible)
        #expect(ambitus.elementProperties.color == nil)
        #expect(ambitus.elementProperties.offset == nil)
        #expect(ambitus.preservedMarkup.isEmpty)
    }
}
