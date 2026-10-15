import Foundation
@testable import SheetMusicCore
@testable import SheetMusicMSCX
import Testing

/// F6.3 / F6.7 and the payload ledger item: a text-line spanner's variants are its payload children; they are read,
/// kept, and written back once.
@Suite("Spanner line properties")
struct LinePropertiesModelTests {
    private static func begin(_ payload: String, type: String = "Pedal") throws -> Spanner {
        let score = try LineVariantFixtures.score("""
        <Spanner type="\(type)">\(payload)<next><location><measures>1</measures></location></next></Spanner>
        <Chord><durationType>whole</durationType><Note><pitch>60</pitch><tpc>14</tpc></Note></Chord>
        """)
        return try #require(LineVariantFixtures.spanners(in: score).first)
    }

    /// `spanner` written back into a one-measure score and encoded to MSCX text.
    private static func encodedText(of spanner: Spanner) throws -> String {
        let data = try MSCXEncoder.encode(LineVariantFixtures.score(spanner: spanner))
        return try #require(String(data: data, encoding: .utf8))
    }

    /// Every property at its default is `nil` — what a pedal made in code carries — so the two compare equal after a
    /// save; the begin side is told apart by `isEndMarker`.
    @Test("a bare <Pedal/> is a begin side with every property at its default")
    func barePedalIsABeginSide() throws {
        let pedal = try Self.begin("<Pedal/>")
        #expect(pedal.kind == .pedal)
        #expect(!pedal.isEndMarker)
        #expect(pedal.lineProperties == nil)
        let silent = try Self.begin("<Pedal><play>0</play></Pedal>")
        #expect(silent.lineProperties == Spanner.LineProperties(playsBack: false))
    }

    @Test("a pedal made in code survives a save unchanged")
    func codeMadePedalRoundTrips() throws {
        let made = Spanner(kind: .pedal, rawType: "Pedal", nextMeasuresOffset: 1)
        let back = try MSCXParser.parse(MSCXEncoder.encode(LineVariantFixtures.score(spanner: made)))
        #expect(LineVariantFixtures.spanners(in: back).first == made)
    }

    @Test("an end side carries no line properties")
    func endSideHasNone() throws {
        let score = try LineVariantFixtures.score("""
        <Chord><durationType>whole</durationType><Note><pitch>60</pitch><tpc>14</tpc></Note></Chord>
        <Spanner type="Pedal"><prev><location><measures>-1</measures></location></prev></Spanner>
        """)
        let end = try #require(LineVariantFixtures.spanners(in: score).first)
        #expect(end.isEndMarker)
        #expect(end.lineProperties == nil)
    }

    @Test("the six palette pedals decode to their hooks and visibility")
    func pedalVariants() throws {
        let cases: [(String, Spanner.LineHookType?, Spanner.LineHookType?, Bool?)] = [
            ("<endHookType>1</endHookType>", nil, .hook90, nil),
            ("<endHookType>6</endHookType><lineVisible>0</lineVisible>", nil, .rosette, false),
            ("<endHookType>1</endHookType><beginHookType>1</beginHookType>", .hook90, .hook90, nil),
            ("<endHookType>2</endHookType><beginHookType>1</beginHookType>", .hook90, .hook45, nil),
            ("<endHookType>2</endHookType><beginHookType>2</beginHookType>", .hook45, .hook45, nil),
            ("<endHookType>1</endHookType><beginHookType>2</beginHookType>", .hook45, .hook90, nil),
        ]
        for (tags, beginHook, endHook, visible) in cases {
            let line = try #require(try Self.begin("<Pedal>\(tags)</Pedal>").lineProperties)
            #expect(line.beginHook == beginHook, "\(tags)")
            #expect(line.endHook == endHook, "\(tags)")
            #expect(line.lineVisible == visible, "\(tags)")
        }
    }

    @Test("line type, dash, width, hook heights and <play> decode")
    func otherProperties() throws {
        let line = try #require(try Self.begin("""
        <TextLine><lineStyle>1</lineStyle><dashLineLength>3</dashLineLength><dashGapLength>2</dashGapLength>\
        <lineWidth>0.3</lineWidth><beginHookHeight>2</beginHookHeight><endHookHeight>1.5</endHookHeight>\
        <play>0</play></TextLine>
        """, type: "TextLine").lineProperties)
        #expect(line.lineType == .dashed)
        #expect(line.dashLength == 3)
        #expect(line.dashGap == 2)
        #expect(line.lineWidth == 0.3)
        #expect(line.beginHookHeight == 2)
        #expect(line.endHookHeight == 1.5)
        #expect(line.playsBack == false)
    }

    @Test("the four guitar lines are their own kind and keep their tag")
    func guitarLines() throws {
        for line in Spanner.ChordTextLine.allCases {
            let spanner = try Self.begin("<\(line.rawValue)/>", type: line.rawValue)
            #expect(spanner.kind == .chordTextLine)
            #expect(spanner.chordTextLine == line)
            #expect(spanner.rawType == line.rawValue)
        }
    }

    @Test("payload children nothing models survive a save")
    func unmodeledPayloadChildrenSurvive() throws {
        let pedal = try Self.begin("""
        <Pedal><endHookType>1</endHookType><Segment><subtype>0</subtype><offset x="0.5" y="1"/></Segment></Pedal>
        """)
        let hairpin = try Self.begin(
            "<HairPin><subtype>2</subtype><lineWidth>0.2</lineWidth></HairPin>", type: "HairPin",
        )
        #expect(pedal.payloadMarkup.count == 1) // the <Segment>; the hook tag is modeled
        // `<lineWidth>` is a modeled `LineProperties` tag, so it is NOT in the bag — it comes back out through
        // `lineChildren()`, exactly once.
        #expect(hairpin.lineProperties?.lineWidth == 0.2)
        #expect(hairpin.payloadMarkup.isEmpty)
        for spanner in [pedal, hairpin] {
            let text = try Self.encodedText(of: spanner)
            #expect(text.contains(spanner.kind == .pedal ? "<Segment>" : "<lineWidth>0.2</lineWidth>"))
        }
    }

    @Test("modeled children are written once")
    func modeledChildrenAreNotDuplicated() throws {
        let pedal = try Self.begin("<Pedal><endHookType>1</endHookType><lineVisible>0</lineVisible></Pedal>")
        let text = try Self.encodedText(of: pedal)
        #expect(text.components(separatedBy: "<endHookType>").count == 2)
        #expect(text.components(separatedBy: "<lineVisible>").count == 2)
    }

    @Test("the pedal fixture saves to a fixed point and keeps every variant's tags")
    func payloadRoundTripIsAFixedPoint() throws {
        let score = try MSCXParser.parse(MSCXFixtureLoader.mscxData("pedal-lines"))
        let once = try MSCXEncoder.encode(score)
        let twice = try MSCXEncoder.encode(MSCXParser.parse(once))
        #expect(once == twice)
        let text = try #require(String(data: once, encoding: .utf8))
        #expect(text.contains("<endHookType>6</endHookType>"))
        #expect(text.contains("<lineVisible>0</lineVisible>"))
        #expect(text.contains("<Segment>"))
        #expect(text.contains("<beginText>Sost.</beginText>"))
    }
}
