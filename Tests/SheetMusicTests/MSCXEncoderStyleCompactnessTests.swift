import Foundation
@testable import SheetMusicCore
@testable import SheetMusicMSCX
@testable import SheetMusicXMLTools
import Testing

/// Phase 3 polish: encoder elides `<Style>` fields that equal
/// MuseScore's documented defaults so re-encoded scores stay close to
/// MuseScore Studio's terse output. Decoder already overlays
/// `ScoreStyle.museScoreDefaults`, so elided fields round-trip back
/// to the same value.
@Suite("MSCXEncoder Style compactness")
struct MSCXEncoderStyleCompactnessTests {
    /// Encode a Score, reparse the bytes, and return the inner
    /// `<Style>` element so individual children can be inspected.
    private func encodedStyleNode(_ score: Score) throws -> XMLTreeNode {
        let bytes = try MSCXEncoder.encode(score)
        // `XMLTreeParser.parse` returns the document's root element
        // directly — i.e. the `<museScore>` node itself, not a
        // synthetic wrapper containing it.
        let museScore = try XMLTreeParser.parse(bytes)
        #expect(museScore.name == "museScore")
        let scoreNode = try #require(museScore.first("Score"))
        return try #require(scoreNode.first("Style"))
    }

    @Test("Default ScoreStyle emits only <spatium>")
    func defaultStyleEmitsOnlySpatium() throws {
        let score = Score(division: 480, style: .museScoreDefaults)
        let style = try encodedStyleNode(score)
        let names = style.children.map(\.name)
        #expect(names == ["spatium"])
    }

    @Test("Overriding pageWidth emits only spatium + pageWidth")
    func selectiveOverrideEmitsOnlyChangedField() throws {
        var s = ScoreStyle.museScoreDefaults
        s.pageLayout.width = 12.0
        let score = Score(division: 480, style: s)
        let style = try encodedStyleNode(score)
        let names = style.children.map(\.name)
        #expect(Set(names) == Set(["spatium", "pageWidth"]))
        #expect(style.first("pageWidth")?.text == "12.0")
    }

    @Test("Header.oddEvenDifferent == false suppresses evenHeader* fields")
    func defaultHeaderOmitsEvenSideWhenSingleSided() throws {
        var s = ScoreStyle.museScoreDefaults
        // Default header has oddEvenDifferent = true; flip it off and
        // change odd.left so the header block isn't *entirely* default.
        s.pageChrome.header.oddEvenDifferent = false
        s.pageChrome.header.odd = TextRow(left: "L", center: "", right: "")
        let score = Score(division: 480, style: s)
        let style = try encodedStyleNode(score)
        let names = Set(style.children.map(\.name))
        #expect(!names.contains("evenHeaderL"))
        #expect(!names.contains("evenHeaderC"))
        #expect(!names.contains("evenHeaderR"))
        #expect(names.contains("oddHeaderL"))
        #expect(names.contains("headerOddEven"))
    }

    @Test("Header.oddEvenDifferent == true re-enables evenHeader* gating")
    func evenHeaderEmittedWhenDifferentAndNonDefault() throws {
        var s = ScoreStyle.museScoreDefaults
        s.pageChrome.header.even = TextRow(left: "X", center: "", right: "")
        let score = Score(division: 480, style: s)
        let style = try encodedStyleNode(score)
        #expect(style.first("evenHeaderL")?.text == "X")
        // evenHeaderC / evenHeaderR are still default ("") and stay
        // elided. (XMLTreeNode.first(_:) is a custom child lookup,
        // not Sequence.first(where:), so SwiftLint's
        // contains_over_first_not_nil rule fires as a false
        // positive — silence per-call here.)
        // swiftlint:disable:next contains_over_first_not_nil
        #expect(style.first("evenHeaderC") == nil)
        // swiftlint:disable:next contains_over_first_not_nil
        #expect(style.first("evenHeaderR") == nil)
    }

    @Test("Default style still round-trips through parse")
    func defaultStyleRoundTrip() throws {
        let original = Score(division: 480, style: .museScoreDefaults)
        let bytes = try MSCXEncoder.encode(original)
        let reparsed = try MSCXParser.parse(bytes)
        #expect(reparsed.style == ScoreStyle.museScoreDefaults)
    }
}
