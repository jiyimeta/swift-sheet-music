import Foundation
@testable import SheetMusicCore
@testable import SheetMusicLayout
@testable import SheetMusicMSCX
@testable import SheetMusicXMLTools
import Testing

/// A tuplet's own display settings — side, number, bracket, visibility — survive a MuseScore round trip and reach
/// the page. They used to be dropped on read, so a hidden number or bracket came back on the next save.
@Suite("Tuplet appearance")
struct TupletAppearanceTests {
    private let _installFontMetrics = TestSupport.installFontMetrics

    // MARK: - MSCX

    private static func decodeVoice(_ xml: String) throws -> Voice {
        try Voice.decode(XMLTreeParser.parse(Data(xml.utf8)))
    }

    private static func encodedTuplet(_ voice: Voice) throws -> XMLTreeNode {
        try #require(voice.encode().first("Tuplet"))
    }

    private static let threeEighths = """
    <Chord><durationType>eighth</durationType><Note><pitch>60</pitch><tpc>14</tpc></Note></Chord>
    <Chord><durationType>eighth</durationType><Note><pitch>62</pitch><tpc>16</tpc></Note></Chord>
    <Chord><durationType>eighth</durationType><Note><pitch>64</pitch><tpc>18</tpc></Note></Chord>
    """

    @Test("A tuplet's side, number, bracket and visibility are read, and its unmodeled children kept")
    func decodesAppearance() throws {
        let voice = try Self.decodeVoice("""
        <voice>
          <Tuplet>
            <visible>0</visible>
            <normalNotes>2</normalNotes>
            <actualNotes>3</actualNotes>
            <p1 x="0" y="-1.5"/>
            <p2 x="0.5" y="-1.5"/>
            <baseNote>eighth</baseNote>
            <Number><style>tuplet</style><text>3</text></Number>
            <track>4</track>
            <direction>up</direction>
            <numberType>2</numberType>
            <bracketType>1</bracketType>
          </Tuplet>
          \(Self.threeEighths)
          <endTuplet/>
        </voice>
        """)
        let appearance = try #require(voice.tuplets.first).appearance
        #expect(appearance.direction == .up)
        #expect(appearance.numberType == .noText)
        #expect(appearance.bracketType == .bracket)
        #expect(!appearance.visible)
        // The bracket ends a user dragged are kept verbatim; the number MuseScore rebuilds and the track the voice
        // implies are not.
        #expect(appearance.preservedMarkup.map(\.name) == ["p1", "p2"])
    }

    @Test("A tuplet that says nothing about its look follows the style")
    func absentSettingsStayUnset() throws {
        let voice = try Self.decodeVoice("""
        <voice>
          <Tuplet><normalNotes>2</normalNotes><actualNotes>3</actualNotes><baseNote>eighth</baseNote></Tuplet>
          \(Self.threeEighths)
          <endTuplet/>
        </voice>
        """)
        #expect(try #require(voice.tuplets.first).appearance == TupletAppearance())
    }

    @Test("A sextuplet stays 6:4 rather than reducing to 3:2")
    func sextupletKeepsItsRatio() throws {
        let sixteenth = "<Chord><durationType>16th</durationType><Note><pitch>60</pitch><tpc>14</tpc></Note></Chord>"
        let voice = try Self.decodeVoice("""
        <voice>
          <Tuplet><normalNotes>4</normalNotes><actualNotes>6</actualNotes><baseNote>16th</baseNote></Tuplet>
          \(String(repeating: sixteenth, count: 6))
          <endTuplet/>
        </voice>
        """)
        let tuplet = try #require(voice.tuplets.first)
        #expect(tuplet.actualNotes == 6)
        #expect(tuplet.normalNotes == 4)

        let encoded = try Self.encodedTuplet(voice)
        #expect(encoded.first("actualNotes")?.text == "6")
        #expect(encoded.first("normalNotes")?.text == "4")
        #expect(encoded.first("baseNote")?.text == "16th")
    }

    @Test("A tuplet's appearance is written back and reads the same")
    func appearanceRoundTrips() throws {
        let source = try Self.decodeVoice("""
        <voice>
          <Tuplet>
            <offset x="0.5" y="-1"/>
            <visible>0</visible>
            <normalNotes>2</normalNotes>
            <actualNotes>3</actualNotes>
            <p1 x="0" y="-1.5"/>
            <baseNote>eighth</baseNote>
            <direction>down</direction>
            <numberType>1</numberType>
            <bracketType>2</bracketType>
            <color r="255" g="0" b="0" a="255"/>
          </Tuplet>
          \(Self.threeEighths)
          <endTuplet/>
        </voice>
        """)
        let encoded = try Self.encodedTuplet(source)
        #expect(encoded.first("direction")?.text == "down")
        #expect(encoded.first("numberType")?.text == "1")
        #expect(encoded.first("bracketType")?.text == "2")
        #expect(encoded.first("visible")?.text == "0")
        let names = Set(encoded.children.map(\.name))
        #expect(names.isSuperset(of: ["p1", "color", "offset"]))

        let bytes = try XMLTreeSerializer.serialize(XMLTreeNode(name: "root", children: [source.encode()]))
        let reread = try Voice.decode(#require(XMLTreeParser.parse(bytes).first("voice")))
        #expect(reread == source)
        #expect(reread.tuplets.first?.appearance == source.tuplets.first?.appearance)
    }

    @Test("A tuplet with no settings of its own writes none, and no <Number>")
    func defaultAppearanceWritesNothingExtra() throws {
        let voice = try Self.decodeVoice("""
        <voice>
          <Tuplet>
            <normalNotes>2</normalNotes><actualNotes>3</actualNotes><baseNote>eighth</baseNote>
            <Number><style>tuplet</style><text>3</text></Number>
          </Tuplet>
          \(Self.threeEighths)
          <endTuplet/>
        </voice>
        """)
        let names = try Self.encodedTuplet(voice).children.map(\.name)
        #expect(names == ["normalNotes", "actualNotes", "baseNote"])
    }

    // MARK: - Model

    @Test("Two voices that differ only in a tuplet's appearance are not equal")
    func voiceEqualityCoversAppearance() {
        let elements: [VoiceElement] = (0 ..< 3).map { _ in .rest(duration: Self.twelfth) }
        let plain = Voice(
            elements: elements, tuplets: [Tuplet(normalNotes: 2, actualNotes: 3, startIndex: 0, endIndex: 2)],
        )
        var hidden = plain
        hidden.tuplets.updateValue(at: 0) { $0.appearance.visible = false }
        #expect(plain != hidden)
    }

    @Test("A duplicated tuplet keeps its appearance")
    func duplicateCarriesAppearance() throws {
        var score = EditingFixtures.parityFixture()
        let flute = StaffAddress(partIndex: 0, staffIndexInPart: 0)
        func slot(_ element: Int) -> VoiceElementID {
            VoiceElementID(staff: flute, measureIndex: 0, voiceIndex: 0, elementIndex: element)
        }
        _ = try CreateTuplet(at: slot(1), actualNotes: 3, normalNotes: 2).apply(to: &score)
        let look = TupletAppearance(direction: .down, numberType: .ratio, bracketType: .noBracket)
        let ref = VoiceRef(staff: flute, measureIndex: 0, voiceIndex: 0)
        var voice = try #require(score[voice: ref])
        voice.tuplets.updateValue(at: 0) { $0.appearance = look }
        score[voice: ref] = voice

        _ = try DuplicateRange(over: VoiceElementRange(start: slot(1), end: slot(3))).apply(to: &score)

        let spans = try #require(score[voice: ref]).tupletSpans
        #expect(spans.map(\.startIndex) == [1, 4])
        #expect(spans.map(\.appearance) == [look, look])
    }

    // MARK: - Layout

    /// A twelfth — one third of a quarter — as `CreateTuplet` spells it.
    private static let twelfth = NoteDuration.fraction(Fraction(numerator: 1, denominator: 12))

    private static func notes() -> [VoiceElement] {
        [60, 62, 64].map { .chord(Chord(duration: twelfth, notes: [Note(pitch: $0, tpc: 14)])) }
    }

    private static func rests() -> [VoiceElement] {
        (0 ..< 3).map { _ in .rest(duration: twelfth) }
    }

    /// One 4/4 measure whose first quarter is a triplet of `members` drawn as `appearance`, then three quarter rests.
    private static func score(members: [VoiceElement], appearance: TupletAppearance) -> Score {
        var elements: [VoiceElement] = [
            .clef(Clef(concertClefType: "G")),
            .timeSignature(TimeSignature(numerator: 4, denominator: 4)),
        ]
        let start = elements.count
        elements += members
        elements += (0 ..< 3).map { _ in VoiceElement.rest(duration: .quarter) }
        var voice = Voice(elements: elements)
        voice.tuplets = [Tuplet(
            normalNotes: 2, actualNotes: 3, startIndex: start, endIndex: start + members.count - 1,
            appearance: appearance,
        )]
        return Score(division: 480, parts: [Part(
            id: "P1",
            instrument: Instrument(id: "piano", longName: "Piano"),
            staves: [Staff(
                staffType: "stdNormal", group: "pitched", defaultClefType: "G",
                measures: [Measure(voices: [voice])],
            )],
        )])
    }

    private struct Label {
        let text: String
        let hasBracket: Bool
        let isAbove: Bool
    }

    private static func labels(
        in score: Score, showsInvisible: Bool = false, invisible: Bool = false,
    ) -> [Label] {
        let doc = LayoutEngine.layout(
            score: score, options: ScoreViewOptions(showsInvisibleElements: showsInvisible), availableWidth: 600,
        )
        return doc.systems.flatMap(\.measures).flatMap { invisible ? $0.invisibleElements : $0.elements }
            .compactMap { element in
                guard case let .tupletLabel(_, _, text, hasBracket, isAbove, _) = element else { return nil }
                return Label(text: text, hasBracket: hasBracket, isAbove: isAbove)
            }
    }

    @Test("The number shows the count, the ratio, or nothing")
    func numberType() throws {
        guard #available(macOS 15.0, *) else { return }
        let ratio = try #require(Self.labels(in: Self.score(
            members: Self.rests(), appearance: TupletAppearance(numberType: .ratio),
        )).first)
        #expect(ratio.text == "3:2")
        let none = try #require(Self.labels(in: Self.score(
            members: Self.rests(), appearance: TupletAppearance(numberType: .noText),
        )).first)
        #expect(none.text.isEmpty)
        #expect(none.hasBracket)
    }

    @Test("A bracket can be forced on a beamed group, and off an unbeamed one")
    func bracketType() throws {
        guard #available(macOS 15.0, *) else { return }
        // Control: three beamed triplet eighths show the number alone.
        let auto = try #require(Self.labels(in: Self.score(members: Self.notes(), appearance: .init())).first)
        #expect(!auto.hasBracket)
        let forced = try #require(Self.labels(in: Self.score(
            members: Self.notes(), appearance: TupletAppearance(bracketType: .bracket),
        )).first)
        #expect(forced.hasBracket)
        let removed = try #require(Self.labels(in: Self.score(
            members: Self.rests(), appearance: TupletAppearance(bracketType: .noBracket),
        )).first)
        #expect(!removed.hasBracket)
    }

    @Test("A tuplet forced to the noteheads' side sits there, with a bracket away from the beam")
    func direction() throws {
        guard #available(macOS 15.0, *) else { return }
        // C4 D4 E4 have their stems up, so the marking goes above by default.
        let auto = try #require(Self.labels(in: Self.score(members: Self.notes(), appearance: .init())).first)
        #expect(auto.isAbove)
        let down = try #require(Self.labels(in: Self.score(
            members: Self.notes(), appearance: TupletAppearance(direction: .down),
        )).first)
        #expect(!down.isAbove)
        #expect(down.hasBracket)
    }

    @Test("A tuplet with neither number nor bracket draws nothing")
    func nothingToDraw() {
        guard #available(macOS 15.0, *) else { return }
        let appearance = TupletAppearance(numberType: .noText, bracketType: .noBracket)
        #expect(Self.labels(in: Self.score(members: Self.rests(), appearance: appearance)).isEmpty)
    }

    @Test("A hidden tuplet is drawn only among invisible elements, and only when they are shown")
    func hidden() {
        guard #available(macOS 15.0, *) else { return }
        var appearance = TupletAppearance()
        appearance.visible = false
        let score = Self.score(members: Self.rests(), appearance: appearance)
        #expect(Self.labels(in: score).isEmpty)
        #expect(Self.labels(in: score, invisible: true).isEmpty)
        #expect(Self.labels(in: score, showsInvisible: true).isEmpty)
        #expect(Self.labels(in: score, showsInvisible: true, invisible: true).map(\.text) == ["3"])
    }

    @Test("The bracket's gap fits the number: none, one digit, or a ratio")
    func bracketGap() {
        // Literals rather than a spelled `CGFloat` / `CGPoint`: on WebAssembly both Foundation and this package
        // declare them, and naming one here is ambiguous.
        #expect(TupletBracketGeometry.labelHalfWidth(for: "", sp: 10) == 0)
        #expect(TupletBracketGeometry.labelHalfWidth(for: "3", sp: 10) == 8)
        #expect(TupletBracketGeometry.labelHalfWidth(for: "3:2", sp: 10) == 18)
        let closed = TupletBracketGeometry.segments(
            from: .init(x: 0, y: 0), to: .init(x: 100, y: 0), isAbove: true, sp: 10, labelHalfWidth: 0,
        )
        #expect(closed.leftSegTo == closed.rightSegFrom)
    }
}
