import Foundation
@testable import SheetMusicCore
@testable import SheetMusicMSCX
@testable import SheetMusicXMLTools
import Testing

/// `Spanner.offsets(from:to:in:)` is MuseScore's `<next>` WRITER, not an inverse of `LayoutEngine.endAnchor`
/// (which is many-to-one). The pins below take MuseScore-authored files, recompute each spanner's offsets from
/// the positions the model resolves, and compare the re-encoded `<next>` block byte-for-byte with the file's.
@Suite("Spanner.offsets")
struct SpannerOffsetsTests {
    private static let staff0 = StaffAddress(partIndex: 0, staffIndexInPart: 0)

    private static func slot(_ measure: Int, _ element: Int, voice: Int = 0) -> VoiceElementID {
        VoiceElementID(staff: staff0, measureIndex: measure, voiceIndex: voice, elementIndex: element)
    }

    /// Every descendant (not just direct child) of `node` named `name`, in document order. `XMLTreeNode` only
    /// exposes `first(_:)` / `all(_:)` over direct children, so a `<Spanner>` nested inside a `<Chord>` needs
    /// this small recursive walk.
    private static func descendants(_ name: String, in node: XMLTreeNode) -> [XMLTreeNode] {
        var found: [XMLTreeNode] = []
        for child in node.children {
            if child.name == name { found.append(child) }
            found.append(contentsOf: descendants(name, in: child))
        }
        return found
    }

    /// The serialized `<next>` child of the `index`-th `<Spanner type="type">` in the file that carries a
    /// `<next>` child, in document order. Filtering to `<next>`-carrying blocks matters: a spanner is written
    /// as a begin/end pair, and the end side carries only `<prev>`.
    private static func nextBlock(_ fixture: String, type: String, index: Int) throws -> String {
        let root = try XMLTreeParser.parse(MSCXFixtureLoader.mscxData(fixture))
        let candidates = descendants("Spanner", in: root).filter {
            $0.attributes["type"] == type && !$0.all("next").isEmpty
        }
        let spanner = try #require(
            candidates.indices.contains(index) ? candidates[index] : nil,
            "expected a <Spanner type=\"\(type)\"> carrying <next> at index \(index) in \(fixture)",
        )
        let next = try #require(spanner.first("next"))
        return try #require(String(bytes: XMLTreeSerializer.serialize(next), encoding: .utf8))
    }

    /// The `<next>` block MuseScore's writer would spell for the given offsets, via this package's own encoder.
    /// The spanner kind used to build it is irrelevant — `<next>` content depends only on the offsets, never on
    /// `rawType` / `kind` — so a `.slur` stand-in serves every fixture's spanner type in these tests.
    private static func encodedNext(_ measures: Int, _ fractions: Fraction?) throws -> String {
        var spanner = Spanner(kind: .slur, rawType: "Slur")
        spanner.nextMeasuresOffset = measures
        spanner.nextFractionsOffset = fractions
        let node = try #require(spanner.encodeChordAnchoredBegin().first("next"))
        return try #require(String(bytes: XMLTreeSerializer.serialize(node), encoding: .utf8))
    }

    @Test("ticks convert back to a reduced fraction, sign kept")
    func fractionFromTicks() {
        #expect(Fraction(ticks: 960, division: 480) == Fraction(numerator: 1, denominator: 2))
        #expect(Fraction(ticks: -960, division: 480) == Fraction(numerator: -1, denominator: 2))
        #expect(Fraction(ticks: 1920, division: 480) == Fraction(numerator: 1, denominator: 1))
        #expect(Fraction(ticks: 0, division: 480) == Fraction(numerator: 0, denominator: 1))
    }

    /// `slur_ms4_resave.mscx:39-43` — bar 0's first slur runs C4 (rtick 0) to E4 (rtick 1/2) inside the bar.
    /// A slur's `tick2` is the END CHORD'S ONSET (`edit.cpp` sets `endElement` to the last chord), so this is
    /// the mid-measure case: measures 0 (elided), fractions 1/2.
    @Test("mid-measure end")
    func midMeasure() throws {
        let score = try MSCXParser.parse(MSCXFixtureLoader.mscxData("slur_ms4_resave"))
        let end = try #require(score.onset(of: Self.slot(0, 3))) // the E4
        let offsets = try #require(Spanner.offsets(from: Self.slot(0, 1), to: end, in: score))
        #expect(offsets.measures == 0)
        #expect(offsets.fractions == Fraction(numerator: 1, denominator: 2))
        try #expect(Self.encodedNext(offsets.measures, offsets.fractions)
            == Self.nextBlock("slur_ms4_resave", type: "Slur", index: 0))
    }

    /// `slur_ms4_resave.mscx:68-73` — bar 0's second slur runs E4 (rtick 1/2) to the G4 that opens bar 1, so
    /// `tick2` sits ON the bar line. `tick2measure` returns the NEXT measure at frac 0, and `toRelative`
    /// subtracts the begin side's 1/2: measures 1, fractions −1/2.
    @Test("bar-end end, from a begin side that is not at the bar line")
    func barEnd() throws {
        let score = try MSCXParser.parse(MSCXFixtureLoader.mscxData("slur_ms4_resave"))
        let end = try #require(score.onset(of: Self.slot(1, 0))) // the G4 opening bar 1
        let offsets = try #require(Spanner.offsets(from: Self.slot(0, 3), to: end, in: score))
        #expect(offsets.measures == 1)
        #expect(offsets.fractions == Fraction(numerator: -1, denominator: 2))
        try #expect(Self.encodedNext(offsets.measures, offsets.fractions)
            == Self.nextBlock("slur_ms4_resave", type: "Slur", index: 1))
    }

    /// `testSingleNoteDynamics.mscx:100-108` — a hairpin over one whole note, beginning at rtick 0 and ending at
    /// the bar line. Same bar-end case with `rs == 0`, so `fractions` is zero and MuseScore ELIDES it: the file
    /// carries `<measures>1</measures>` and nothing else, which is what `nil` must encode to.
    @Test("bar-end end from the bar line elides <fractions>")
    func barEndFromBarLine() throws {
        let score = try MSCXParser.parse(MSCXFixtureLoader.mscxData("testSingleNoteDynamics"))
        let end = try #require(score.end(of: Self.slot(0, 3))) // the whole-note chord's END tick
        let offsets = try #require(Spanner.offsets(from: Self.slot(0, 1), to: end, in: score))
        #expect(offsets.measures == 1)
        #expect(offsets.fractions == nil)
        try #expect(Self.encodedNext(offsets.measures, offsets.fractions)
            == Self.nextBlock("testSingleNoteDynamics", type: "HairPin", index: 0))
    }

    /// The score end is NOT a bar-end: `measureByTick` steps back onto the LAST measure rather than off the end,
    /// so `m` is that measure and `fractions` is its whole length. One hand-written fixture, because no vendored
    /// file carries a spanner that ends at the score end.
    @Test("score-end end stays in the last measure and spells the whole bar")
    func scoreEnd() throws {
        let score = try MSCXParser.parse(MSCXFixtureLoader.mscxData("spanner_offsets_score_end"))
        let end = try #require(score.end(of: Self.slot(0, 2)))
        let offsets = try #require(Spanner.offsets(from: Self.slot(0, 1), to: end, in: score))
        #expect(offsets.measures == 0)
        #expect(offsets.fractions == Fraction(numerator: 1, denominator: 1))
        try #expect(Self.encodedNext(offsets.measures, offsets.fractions)
            == Self.nextBlock("spanner_offsets_score_end", type: "HairPin", index: 0))
    }

    @Test("the hand-written score-end fixture is a decode/encode fixed point")
    func scoreEndFixtureRoundTrips() throws {
        let data = try MSCXFixtureLoader.mscxData("spanner_offsets_score_end")
        let once = try MSCXEncoder.encode(MSCXParser.parse(data))
        let twice = try MSCXEncoder.encode(MSCXParser.parse(once))
        #expect(once == twice)
        #expect(try MSCXParser.parse(once) == MSCXParser.parse(data))
    }

    @Test("an end that precedes the start, and an unresolvable start, are nil")
    func refusals() throws {
        let score = try MSCXParser.parse(MSCXFixtureLoader.mscxData("slur_ms4_resave"))
        let earlier = try #require(score.onset(of: Self.slot(0, 1)))
        #expect(Spanner.offsets(from: Self.slot(0, 3), to: earlier, in: score) == nil)
        #expect(Spanner.offsets(from: Self.slot(9, 0), to: earlier, in: score) == nil)
    }

    /// `MeasureStructure.adjustSpannerOffsets` walked `.spanner` VOICE ELEMENTS only, so a slur — which lives in
    /// `Chord.spanners` — kept a stale `nextMeasuresOffset` across an `InsertMeasure` / `DeleteMeasure` inside its
    /// span. Group 6 is where slurs become writable, so the walk is extended here.
    @Test("inserting a measure inside a slur's span widens the slur")
    func slurFollowsAMeasureInsertion() throws {
        var score = EditingFixtures.parityFixture()
        var head = Chord(duration: .quarter, notes: [Note(pitch: 60, tpc: 14)])
        head.spanners = [Spanner(kind: .slur, rawType: "Slur", nextMeasuresOffset: 2)]
        score.parts[0].staves[0].measures[0].voices[0].elements[1] = .chord(head)
        _ = try InsertMeasure(measureIndex: 1).apply(to: &score)
        guard case let .chord(after) = score.parts[0].staves[0].measures[0].voices[0].elements[1] else {
            Issue.record("expected the slurred chord at 1")
            return
        }
        #expect(after.spanners[0].nextMeasuresOffset == 3)
    }
}
