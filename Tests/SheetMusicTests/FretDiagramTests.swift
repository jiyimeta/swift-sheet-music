import Foundation
@testable import SheetMusicCore
@testable import SheetMusicMSCX
@testable import SheetMusicXMLTools
import Testing

private func fretDiagramScore(_ inner: String) throws -> Score {
    try MSCXParser.parse(Data("""
    <?xml version="1.0" encoding="UTF-8"?>
    <museScore version="4.60">
      <Score>
        <Division>480</Division>
        <Part>
          <Staff id="1"/>
          <Instrument id="guitar-steel"><trackName>Guitar</trackName><Channel/></Instrument>
        </Part>
        <Staff id="1">
          <Measure><voice>\(inner)</voice></Measure>
        </Staff>
      </Score>
    </museScore>
    """.utf8))
}

private func fretDiagrams(in score: Score) -> [FretDiagram] {
    score.parts.flatMap(\.staves).flatMap(\.measures).flatMap(\.voices).flatMap(\.elements).compactMap {
        guard case let .fretDiagram(diagram) = $0 else { return nil }
        return diagram
    }
}

private func decodeFretDiagram(_ inner: String) throws -> FretDiagram {
    let node = try XMLTreeParser.parse(Data("<FretDiagram>\(inner)</FretDiagram>".utf8))
    return FretDiagram.decode(node)
}

private func diagramFingerprint(_ diagram: FretDiagram) -> UInt64 {
    var hasher = FNV1a()
    hasher.combine(diagram)
    return hasher.value
}

@Suite("Fret diagram model")
struct FretDiagramModelTests {
    @Test func markerAndDotTokensRoundTripWithoutCollapsingUnknownValues() {
        let markers: [(String, FretString.Marker)] = [
            ("circle", .circle), ("cross", .cross), ("none", .none),
        ]
        for (token, marker) in markers {
            #expect(FretString.Marker(mscxToken: token) == marker)
            #expect(marker.mscxToken == token)
        }
        #expect(FretString.Marker(mscxToken: "future") == .other("future"))
        #expect(FretString.Marker.other("future").mscxToken == "future")

        let dots: [(String, FretString.Dot.Kind)] = [
            ("normal", .normal), ("cross", .cross),
            ("square", .square), ("triangle", .triangle),
        ]
        for (token, kind) in dots {
            #expect(FretString.Dot.Kind(mscxToken: token) == kind)
            #expect(kind.mscxToken == token)
        }
        #expect(FretString.Dot.Kind(mscxToken: "diamond") == .other("diamond"))
        #expect(FretString.Dot.Kind.other("diamond").mscxToken == "diamond")
    }

    @Test func anEmptyDiagramFeedsNothingButMarkerChangesMoveTheFingerprint() {
        var emptyHasher = FNV1a()
        let initial = emptyHasher.value
        emptyHasher.combine(FretDiagram())
        #expect(emptyHasher.value == initial)

        let circle = FretDiagram(strings: [FretString(index: 0, marker: .circle)])
        let cross = FretDiagram(strings: [FretString(index: 0, marker: .cross)])
        #expect(diagramFingerprint(circle) != diagramFingerprint(cross))
    }
}

@Suite("Fret diagram MSCX round trip")
struct FretDiagramMSCXTests {
    @Test func decodesStringsMarkersDotsBarreAndHarmony() throws {
        let diagram = try decodeFretDiagram("""
        <strings>6</strings><frets>5</frets>
        <Harmony><name>C</name><root>14</root></Harmony>
        <fretDiagram>
          <string no="0"><marker>cross</marker></string>
          <string no="2"><dot fret="3">normal</dot><dot fret="4">square</dot></string>
          <barre start="1" end="5">2</barre>
        </fretDiagram>
        """)
        #expect(diagram.stringCount == 6)
        #expect(diagram.fretCount == 5)
        #expect(diagram.strings == [
            FretString(index: 0, marker: .cross),
            FretString(index: 2, dots: [
                FretString.Dot(fret: 3, kind: .normal),
                FretString.Dot(fret: 4, kind: .square),
            ]),
        ])
        #expect(diagram.barre == FretBarre(startString: 1, endString: 5, fret: 2))
        #expect(diagram.harmony?.name == "C")
        #expect(diagram.harmony?.rootTpc == 14)
    }

    @Test func oldCompatibilityChildrenStayInTheBagAndEncodeLast() throws {
        let diagram = try decodeFretDiagram("""
        <strings>6</strings><frets>5</frets>
        <fretDiagram><string no="2"><dot fret="3">normal</dot></string></fretDiagram>
        <string no="2"><dot>3</dot></string><barre>1</barre>
        """)
        #expect(diagram.preservedMarkup.map(\.name) == ["string", "barre"])

        let encoded = diagram.encode()
        let oldString = try #require(encoded.first("string"))
        #expect(oldString.attributes == ["no": "2"])
        #expect(oldString.first("dot")?.text == "3")
        #expect(encoded.first("barre")?.text == "1")
        #expect(Array(encoded.children.map(\.name).suffix(2)) == ["string", "barre"])
    }

    @Test func fretDiagramIsTheLastModeledChild() throws {
        let diagram = FretDiagram(
            strings: [FretString(index: 0, marker: .cross)],
            harmony: Harmony(name: "C", rootTpc: 14),
            preservedMarkup: [PreservedXML(name: "string", attributes: ["no": "0"])],
        )
        let names = diagram.encode().children.map(\.name)
        let harmonyIndex = try #require(names.firstIndex(of: "Harmony"))
        let fretDiagramIndex = try #require(names.firstIndex(of: "fretDiagram"))
        #expect(harmonyIndex < fretDiagramIndex)
        // MuseScore silently discards every child after <fretDiagram>. Neither
        // this repo's preservation nor idempotency gate can detect that reader
        // behavior, so this explicit upstream-order assertion is load-bearing.
        #expect(!names.dropFirst(fretDiagramIndex + 1).contains("Harmony"))
    }

    @Test func wholeScoreRoundTripIsModelStableAndEncoderIdempotent() throws {
        let first = try MSCXParser.parse(MSCXFixtureLoader.mscxData("fret-diagrams"))
        let firstEncoding = try MSCXEncoder.encode(first)
        let second = try MSCXParser.parse(firstEncoding)
        #expect(fretDiagrams(in: second) == fretDiagrams(in: first))

        // This proves the local encoder and decoder agree. It cannot expose
        // MuseScore's after-<fretDiagram> discard; the order test above does.
        let secondEncoding = try MSCXEncoder.encode(second)
        #expect(secondEncoding == firstEncoding)
    }

    @Test func strippingClearsTheDiagramAndNestedHarmonyBags() throws {
        let score = try fretDiagramScore("""
        <FretDiagram>
          <Harmony><name>C</name><customHarmony>kept</customHarmony></Harmony>
          <fretDiagram/><legacyDiagram>kept</legacyDiagram>
        </FretDiagram>
        <Chord><durationType>whole</durationType><Note><pitch>60</pitch><tpc>14</tpc></Note></Chord>
        """)
        let original = try #require(fretDiagrams(in: score).first)
        #expect(original.preservedMarkup.map(\.name) == ["legacyDiagram"])
        #expect(original.harmony?.preservedMarkup.map(\.name) == ["customHarmony"])

        let stripped = try #require(fretDiagrams(in: score.strippingPreservedMarkup()).first)
        #expect(stripped.preservedMarkup.isEmpty)
        #expect(stripped.harmony?.preservedMarkup.isEmpty == true)
    }
}

@Suite("Fret diagram fixture")
struct FretDiagramFixtureTests {
    /// The preservation gate skips fixtures it cannot parse, so this test pins
    /// that the hand-authored file really reaches the typed model.
    @Test func fixtureDecodesBothDiagrams() throws {
        let score = try MSCXParser.parse(MSCXFixtureLoader.mscxData("fret-diagrams"))
        let diagrams = fretDiagrams(in: score)
        try #require(diagrams.count == 2)

        #expect(diagrams[0].harmony?.name == "C")
        #expect(diagrams[0].strings.count == 4)
        #expect(diagrams[0].strings[0].marker == .cross)
        #expect(diagrams[0].barre == FretBarre(startString: 1, endString: 5, fret: 1))
        #expect(diagrams[0].preservedMarkup.map(\.name) == [
            "minDistance", "fretOffset", "showNut", "mag", "orientation",
            "string", "string", "string", "string", "barre",
        ])

        #expect(diagrams[1].harmony == nil)
        #expect(diagrams[1].fretCount == 4)
        #expect(diagrams[1].strings.map(\.index) == [0, 2, 4])
        #expect(diagrams[1].barre == nil)
        #expect(diagrams[1].preservedMarkup.map(\.name) == [
            "showNut", "string", "string", "string",
        ])
    }
}
