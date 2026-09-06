import Foundation
@testable import SheetMusicCore
@testable import SheetMusicMSCX
@testable import SheetMusicXMLTools
import Testing

private let minimalFiguredBassXML = """
<FiguredBass>
  <FiguredBassItem>
    <brackets b0="0" b1="0" b2="0" b3="0" b4="0"/>
    <digit>6</digit>
  </FiguredBassItem>
</FiguredBass>
"""

private func figuredBassScore(_ inner: String) throws -> Score {
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

private func firstFiguredBassVoiceElements(in score: Score) -> [VoiceElement] {
    score.parts[0].staves[0].measures[0].voices[0].elements
}

private func figuredBassVoiceElements(_ inner: String) throws -> [VoiceElement] {
    try firstFiguredBassVoiceElements(in: figuredBassScore(inner))
}

private func figuredBassValue(_ element: VoiceElement?) -> FiguredBass? {
    guard case let .figuredBass(value)? = element else { return nil }
    return value
}

private func fingerprint(_ element: VoiceElement) -> UInt64 {
    var hasher = FNV1a()
    hasher.combine(element)
    return hasher.value
}

@Suite("Figured bass model")
struct FiguredBassModelTests {
    @Test func defaultsMatchTheWriterOmissionRules() {
        let value = FiguredBass()
        // The trap: MuseScore omits <onNote> only when the value is true.
        #expect(value.isOnNote)
        #expect(value.ticks == nil)
        #expect(value.items.isEmpty)
        #expect(value.text.isEmpty)
    }

    @Test func itemEnumsRoundTripKnownAndUnknownOrdinals() {
        let modifiers: [(Int, FiguredBassItem.Modifier)] = [
            (0, .none), (1, .doubleFlat), (2, .flat), (3, .natural), (4, .sharp),
            (5, .doubleSharp), (6, .cross), (7, .backslash), (8, .slash),
        ]
        for (ordinal, value) in modifiers {
            #expect(FiguredBassItem.Modifier(mscxOrdinal: ordinal) == value)
            #expect(value.mscxOrdinal == ordinal)
        }
        let parentheses: [(Int, FiguredBassItem.Parenthesis)] = [
            (0, .none), (1, .roundOpen), (2, .roundClosed),
            (3, .squareOpen), (4, .squareClosed),
        ]
        for (ordinal, value) in parentheses {
            #expect(FiguredBassItem.Parenthesis(mscxOrdinal: ordinal) == value)
            #expect(value.mscxOrdinal == ordinal)
        }
        let lines: [(Int, FiguredBassItem.ContinuationLine)] = [
            (0, .none), (1, .simple), (2, .extended),
        ]
        for (ordinal, value) in lines {
            #expect(FiguredBassItem.ContinuationLine(mscxOrdinal: ordinal) == value)
            #expect(value.mscxOrdinal == ordinal)
        }
        #expect(FiguredBassItem.Modifier(mscxOrdinal: 99) == .other(rawValue: 99))
        #expect(FiguredBassItem.Parenthesis(mscxOrdinal: 99) == .other(rawValue: 99))
        #expect(FiguredBassItem.ContinuationLine(mscxOrdinal: 99) == .other(rawValue: 99))
    }

    @Test func fingerprintCoversParentPresenceFields() {
        let base = FiguredBass(items: [FiguredBassItem(digit: 6)])
        var changed = base
        changed.isOnNote = false
        #expect(fingerprint(.figuredBass(base)) != fingerprint(.figuredBass(changed)))
        changed = base
        changed.ticks = Fraction(numerator: 0, denominator: 1)
        #expect(fingerprint(.figuredBass(base)) != fingerprint(.figuredBass(changed)))
    }

    @Test func fingerprintCoversItemPresenceOrderAndCount() {
        let absent = FiguredBass(items: [FiguredBassItem(digit: 6)])
        let ordinalZero = FiguredBass(items: [FiguredBassItem(
            prefix: .other(rawValue: 0), digit: 6,
        )])
        #expect(fingerprint(.figuredBass(absent)) != fingerprint(.figuredBass(ordinalZero)))

        let first = FiguredBassItem(digit: 6)
        let second = FiguredBassItem(digit: 4)
        let ordered = FiguredBass(items: [first, second])
        let reversed = FiguredBass(items: [second, first])
        #expect(fingerprint(.figuredBass(ordered)) != fingerprint(.figuredBass(reversed)))
        #expect(fingerprint(.figuredBass(FiguredBass(items: [first]))) != fingerprint(.figuredBass(ordered)))
    }

    @Test func fingerprintIncludesTheVoiceElementCaseTag() {
        let figuredBass = VoiceElement.figuredBass(FiguredBass(items: [FiguredBassItem(digit: 6)]))
        let ambitus = VoiceElement.ambitus(Ambitus(
            topPitch: 6, topTpc: 0, bottomPitch: 0, bottomTpc: 0,
        ))
        #expect(fingerprint(figuredBass) != fingerprint(ambitus))
    }
}

@Suite("Figured bass MSCX round trip")
struct FiguredBassMSCXTests {
    @Test func decodesAtItsVoicePositionWithTheTrueOnNoteDefault() throws {
        let elements = try figuredBassVoiceElements("""
        <Chord><durationType>quarter</durationType><Note><pitch>60</pitch><tpc>14</tpc></Note></Chord>
        \(minimalFiguredBassXML)
        <Chord><durationType>quarter</durationType><Note><pitch>62</pitch><tpc>16</tpc></Note></Chord>
        """)
        try #require(elements.count == 3)
        guard case .chord = elements[0],
              case let .figuredBass(value) = elements[1],
              case .chord = elements[2]
        else {
            Issue.record("expected chord, figured bass, chord")
            return
        }
        #expect(value.isOnNote)
        #expect(value.items.count == 1)
    }

    @Test func distinguishesExplicitOnNoteZeroAndTicksPresence() throws {
        let elements = try figuredBassVoiceElements("""
        \(minimalFiguredBassXML)
        <FiguredBass><onNote>0</onNote><ticks>1/4</ticks><FiguredBassItem/></FiguredBass>
        """)
        let absent = try #require(figuredBassValue(elements.first))
        let explicit = try #require(figuredBassValue(elements.last))
        #expect(absent.isOnNote)
        #expect(absent.ticks == nil)
        #expect(!explicit.isOnNote)
        #expect(explicit.ticks == Fraction(numerator: 1, denominator: 4))
    }

    @Test func decodesOrdinalItemsInDocumentOrder() throws {
        let value = try #require(try figuredBassValue(figuredBassVoiceElements("""
        <FiguredBass><FiguredBassItem>
        <brackets b0="1" b1="2" b2="0" b3="0" b4="0"/>
        <prefix>2</prefix><digit>4</digit><suffix>4</suffix><continuationLine>1</continuationLine>
        </FiguredBassItem><FiguredBassItem>
        <brackets b0="0" b1="0" b2="0" b3="0" b4="0"/><digit>3</digit>
        </FiguredBassItem></FiguredBass>
        """).first))
        try #require(value.items.count == 2)
        let first = value.items[0]
        #expect(first.bracket0 == .roundOpen)
        #expect(first.bracket1 == .roundClosed)
        #expect(first.bracket2 == .none)
        #expect(first.bracket3 == .none)
        #expect(first.bracket4 == .none)
        #expect(first.prefix == .flat)
        #expect(first.digit == 4)
        #expect(first.suffix == .sharp)
        #expect(first.continuationLine == .simple)
        #expect(value.items[1].digit == 3)
    }

    @Test func decodesNamesAcceptedByAllThreeEnums() throws {
        let value = try #require(try figuredBassValue(figuredBassVoiceElements("""
        <FiguredBass><FiguredBassItem>
        <brackets b0="roundOpen" b1="0" b2="0" b3="0" b4="0"/>
        <prefix>flat</prefix><digit>4</digit><suffix>sharp</suffix>
        <continuationLine>simple</continuationLine>
        </FiguredBassItem></FiguredBass>
        """).first))
        let item = try #require(value.items.first)
        #expect(item.bracket0 == .roundOpen)
        #expect(item.prefix == .flat)
        #expect(item.suffix == .sharp)
        #expect(item.continuationLine == .simple)
    }

    @Test func textIsAuthoritativeOnlyWhenThereAreNoItems() throws {
        let textOnly = try #require(try figuredBassValue(figuredBassVoiceElements("""
        <FiguredBass><text>7&#10;#</text></FiguredBass>
        """).first))
        #expect(textOnly.items.isEmpty)
        #expect(textOnly.text == "7\n#")

        let withItem = try #require(try figuredBassValue(figuredBassVoiceElements("""
        <FiguredBass><FiguredBassItem><brackets b0="0" b1="0" b2="0" b3="0" b4="0"/>
        <digit>6</digit></FiguredBassItem><text>ignored</text></FiguredBass>
        """).first))
        #expect(withItem.items.count == 1)
        // MuseScore regenerates normalized text from items and discards this
        // source <text>, so the model deliberately leaves it empty.
        #expect(withItem.text.isEmpty)
    }

    @Test func preservesTextStylingInsteadOfConsumingIt() throws {
        let value = try #require(try figuredBassValue(figuredBassVoiceElements("""
        <FiguredBass><FiguredBassItem/><size>9.5</size></FiguredBass>
        """).first))
        #expect(value.preservedMarkup.map(\.name) == ["size"])
    }

    @Test func modelsPlacementOnTheSharedBase() throws {
        let value = try #require(try figuredBassValue(figuredBassVoiceElements("""
        <FiguredBass><text>6</text><placement>above</placement></FiguredBass>
        """).first))
        #expect(value.elementProperties.placement == .above)
        #expect(value.preservedMarkup.isEmpty)
    }

    @Test func encodesTheTwoExclusivePayloadShapesAndOmissionDefaults() throws {
        let itemForm = FiguredBass(
            items: [FiguredBassItem(digit: 6)],
            text: "ignored",
            isOnNote: false,
            ticks: Fraction(numerator: 1, denominator: 4),
        ).encode()
        #expect(itemForm.children.map(\.name) == ["onNote", "ticks", "FiguredBassItem"])
        let item = try #require(itemForm.first("FiguredBassItem"))
        #expect(item.children.map(\.name) == ["brackets", "digit"])
        #expect(item.first("brackets")?.attributes == [
            "b0": "0", "b1": "0", "b2": "0", "b3": "0", "b4": "0",
        ])

        let textForm = FiguredBass(text: "6\n4").encode()
        #expect(textForm.children.map(\.name) == ["text"])
        #expect(textForm.first("text")?.text == "6\n4")
    }

    @Test func wholeScoreRoundTripPreservesBothPayloadForms() throws {
        for inner in [
            minimalFiguredBassXML,
            "<FiguredBass><text>7&#10;#</text><placement>above</placement></FiguredBass>",
        ] {
            let first = try figuredBassScore(inner)
            let reparsed = try MSCXParser.parse(MSCXEncoder.encode(first))
            #expect(firstFiguredBassVoiceElements(in: reparsed) == firstFiguredBassVoiceElements(in: first))
        }
    }

    @Test func aBareItemIsIdempotent() throws {
        let first = try #require(try figuredBassValue(figuredBassVoiceElements("""
        <FiguredBass><FiguredBassItem/></FiguredBass>
        """).first))
        let second = FiguredBass.decode(first.encode())
        #expect(second == first)
    }
}

@Suite("Figured bass fixture")
struct FiguredBassFixtureTests {
    @Test func fixtureDecodesEveryFiguredBassItCarries() throws {
        let score = try MSCXParser.parse(MSCXFixtureLoader.mscxData("figured-bass"))
        let part = try #require(score.parts.first)
        let staff = try #require(part.staves.first)
        try #require(staff.measures.count == 3)

        let first = try fixtureValue(in: staff.measures[0], measureIndex: 0)
        #expect(first.isOnNote)
        #expect(first.ticks == nil)
        #expect(first.text.isEmpty)
        #expect(first.items == [FiguredBassItem(digit: 6)])
        #expect(first.elementProperties == .default)
        #expect(first.preservedMarkup.isEmpty)

        let second = try fixtureValue(in: staff.measures[1], measureIndex: 1)
        #expect(!second.isOnNote)
        #expect(second.ticks == Fraction(numerator: 1, denominator: 4))
        #expect(second.text.isEmpty)
        try #require(second.items.count == 2)
        #expect(second.items[0] == FiguredBassItem(
            prefix: .flat,
            digit: 4,
            suffix: .sharp,
            continuationLine: .simple,
            bracket0: .roundOpen,
            bracket1: .roundClosed,
        ))
        #expect(second.items[1] == FiguredBassItem(digit: 3))
        #expect(second.elementProperties == .default)
        #expect(second.preservedMarkup.isEmpty)

        let third = try fixtureValue(in: staff.measures[2], measureIndex: 2)
        #expect(third.isOnNote)
        #expect(third.ticks == nil)
        #expect(third.items.isEmpty)
        #expect(third.text == "7\n#")
        #expect(third.elementProperties.placement == .above)
        #expect(third.elementProperties.visible)
        #expect(third.elementProperties.color == nil)
        #expect(third.elementProperties.offset == nil)
        #expect(third.preservedMarkup.isEmpty)
    }

    private func fixtureValue(in measure: Measure, measureIndex: Int) throws -> FiguredBass {
        let elements = try #require(measure.voices.first).elements
        try #require(elements.count == 2)
        let value = try #require(figuredBassValue(elements.first))
        guard case .chord = elements[1] else {
            Issue.record("measure \(measureIndex) element sequence did not match the fixture")
            return value
        }
        return value
    }
}
