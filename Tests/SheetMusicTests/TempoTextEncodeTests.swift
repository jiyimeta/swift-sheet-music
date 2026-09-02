import Foundation
@testable import SheetMusicCore
@testable import SheetMusicMSCX
@testable import SheetMusicXMLTools
import Testing

/// `Tempo.encode()` synthesizes the `<text>` MuseScore 4 needs to show a saved tempo, from `beatNote` /
/// `beatDots` / bps, and `Tempo.decode` reads the beat back out of it — so encode → parse → encode is a fixed
/// point, which is what the corpus 2-pass gate measures.
@Suite("Tempo <text> encode")
struct TempoTextEncodeTests {
    private static func text(of tempo: Tempo) -> XMLTreeNode? {
        tempo.encode().first("text")
    }

    private static func syms(_ node: XMLTreeNode?) -> [String] {
        node?.all("sym").map(\.text) ?? []
    }

    @Test("a plain quarter at 2 bps prints ♩ = 120 with followText on")
    func quarter() {
        let node = Tempo(beatsPerSecond: 2).encode()
        #expect(node.first("followText")?.text == "1")
        #expect(node.children.last?.name == "text")
        #expect(Self.syms(node.first("text")) == ["metNoteQuarterUp"])
        #expect(node.first("text")?.first("b")?.text == " = 120")
    }

    @Test("a dotted quarter prints the space-and-dot run MuseScore's tpSym table lists")
    func dottedQuarter() {
        let text = Self.text(of: Tempo(beatsPerSecond: 2, beatNote: .quarter, beatDots: 1))
        #expect(Self.syms(text) == ["metNoteQuarterUp", "space", "metAugmentationDot"])
        #expect(text?.first("b")?.text == " = 80")
    }

    @Test("a double-dotted half prints two dots")
    func doubleDottedHalf() {
        let text = Self.text(of: Tempo(beatsPerSecond: 3.5, beatNote: .half, beatDots: 2))
        #expect(Self.syms(text) == ["metNoteHalfUp", "space", "metAugmentationDot", "metAugmentationDot"])
        #expect(text?.first("b")?.text == " = 60")
    }

    @Test("six-digit bps prints a clean integer")
    func roundsToTwoDecimals() {
        #expect(Self.text(of: Tempo(beatsPerSecond: 0.666667))?.first("b")?.text == " = 40")
        #expect(Self.text(of: Tempo(beatsPerSecond: 1.24667))?.first("b")?.text == " = 74.8")
    }

    @Test("a beat the decoder cannot read back is printed as a quarter, and a non-positive bps prints nothing")
    func fallbacks() {
        let sixtyFourth = Self.text(of: Tempo(beatsPerSecond: 2, beatNote: .sixtyFourth))
        #expect(Self.syms(sixtyFourth) == ["metNoteQuarterUp"])
        #expect(sixtyFourth?.first("b")?.text == " = 120")
        let threeDots = Self.text(of: Tempo(beatsPerSecond: 2, beatNote: .quarter, beatDots: 3))
        #expect(Self.syms(threeDots) == ["metNoteQuarterUp"])
        let silent = Tempo(beatsPerSecond: 0).encode()
        #expect(silent.all("text").isEmpty)
        #expect(silent.all("followText").isEmpty)
    }

    @Test("encode → parse → encode is a fixed point for every beat the text can spell", arguments: [
        Tempo(beatsPerSecond: 2), Tempo(beatsPerSecond: 0.666667),
        Tempo(beatsPerSecond: 2, beatNote: .quarter, beatDots: 1),
        Tempo(beatsPerSecond: 1.5, beatNote: .half), Tempo(beatsPerSecond: 4, beatNote: .eighth, beatDots: 1),
        Tempo(beatsPerSecond: 2, beatNote: .sixtyFourth),
    ])
    func twoPassIsAFixedPoint(tempo: Tempo) throws {
        var score = EditingFixtures.fourQuarterRests()
        score.systemMeasures = [SystemMeasure(elements: [
            PositionedSystemElement(position: .start, element: .tempo(tempo)),
        ])]
        let first = try MSCXEncoder.encode(score)
        let second = try MSCXEncoder.encode(MSCXParser.parse(first))
        #expect(first == second)
    }

    /// Every `Tests/SheetMusicTests/Resources/*.mscx` that carries a `<Tempo>` (the set `grep -l "<Tempo>"`
    /// returns), so pass-2 stability is pinned on every local tempo shape: the MS4 `<sym>` marking with and
    /// without an inline `<font>`, the MS3-era double-`<b>` wrapper (`repeat52`, `testArpeggio`, `testVoltaTemp`),
    /// and a `<Tempo>` with a `<text>` but no `<followText>` (`guitarbend_release_twice`), whose beat the decoder
    /// cannot read back and which therefore re-emerges as the quarter its `<tempo>` means.
    @Test("the tempo fixtures are fixed points too", arguments: [
        "slur_ms4_glissando_legato", "grace_after", "guitarbend_tied", "guitarbend_prebend",
        "guitarbend_simple", "guitarbend_slightbend", "guitarbend_gracebend", "guitarbend_release_twice",
        "repeat52", "repeat53", "testArpeggio", "testVoltaTemp",
    ])
    func fixturesAreFixedPoints(name: String) throws {
        let first = try MSCXEncoder.encode(MSCXParser.parse(MSCXFixtureLoader.mscxData(name)))
        let second = try MSCXEncoder.encode(MSCXParser.parse(first))
        #expect(first == second)
    }
}
