#if canImport(CoreGraphics)
    import CoreGraphics
#endif
@testable import SheetMusicCore
@testable import SheetMusicLayout
import Testing

#if !canImport(CoreGraphics)
    private typealias CGFloat = SheetMusicLayout.CGFloat
#endif

/// A play technique draws as the staff text it is; a harp pedal diagram in its own style, centered, above (glyph mode)
/// or below (text mode); neither is a caret target.
@Suite("Annotation staff text layout")
struct AnnotationStaffTextLayoutTests {
    private let _installFontMetrics = TestSupport.installFontMetrics
    private typealias F = AnnotationFixtures

    private static func lane(_ text: StaffText) -> [PositionedSystemElement] {
        [PositionedSystemElement(position: .start, element: .staffText(text), originalStaff: F.address)]
    }

    @Test("a play technique is positioned exactly like a staff text of the same words, but not addressable")
    func techniqueLooksLikeStaffText() throws {
        var pizz = StaffText(text: "pizz.")
        pizz.annotation = .playTechnique(.pizzicato, playsBack: true)
        let annotated = F.layout(F.score([F.whole()], system: Self.lane(pizz)))
        let plain = F.layout(F.score([F.whole()], system: Self.lane(StaffText(text: "pizz."))))
        let a = try #require(F.staffTexts(annotated).first)
        let b = try #require(F.staffTexts(plain).first)
        #expect(a.origin == b.origin)
        #expect(a.style == .staffText)
        let element = try #require(F.elements(annotated).first { if case .staffText = $0 { true } else { false } })
        guard case let .staffText(_, _, _, _, anchor, _, _, identity, _) = element else { return }
        #expect(anchor == nil)
        #expect(identity == nil)
        let ordinary = try #require(F.elements(plain).first { if case .staffText = $0 { true } else { false } })
        guard case let .staffText(_, _, _, _, ordinaryAnchor, _, _, _, _) = ordinary else { return }
        #expect(ordinaryAnchor != nil)
    }

    @Test("a harp diagram draws its glyphs, centered on its beat, above the staff; the text mode below")
    func harpDiagrams() throws {
        let document = try F.layout(F.load("w5-diagrams"))
        let texts = F.staffTexts(document).filter { $0.style == .harpPedalDiagram || $0.style == .harpPedalTextDiagram }
        #expect(texts.map(\.style) == [.harpPedalDiagram, .harpPedalTextDiagram])
        try #require(texts.count == 2)
        #expect(texts[0].placement?.side == .above)
        #expect(texts[1].placement?.side == .below)
        let rich = try #require(texts[0].richText)
        // 7 pedal glyphs and the divider, in Bravura.
        let runs = rich.lines.flatMap(\.runs)
        #expect(runs.count == 8)
        let symbolRuns = runs.filter { if case .symbol = $0.content { true } else { false } }
        #expect(symbolRuns.count == runs.count)
        // Centered: the block's center sits on the first chord's column (± half a notehead).
        let noteX = try #require(F.chordNoteX(document))
        let ink = try #require(rich.ink)
        #expect(abs((texts[0].origin.x + ink.width / 2) - noteX) < 0.6 * F.sp)
    }

    /// MuseScore draws a glyph-mode diagram's `<sym>`s in the music font at its SMuFL size (`hasSymbolScale`), so each
    /// pedal is its one-space advance and the row of seven and the divider is eight spaces wide, as in MuseScore's own
    /// engraving of this fixture. The text mode's note names keep the style's 8 pt symbol size.
    @Test("a glyph-mode harp diagram sets its pedals at the music font's size; the text mode at its style's")
    func harpDiagramSymbolSize() throws {
        let document = try F.layout(F.load("w5-diagrams"))
        let texts = F.staffTexts(document).filter { $0.style == .harpPedalDiagram || $0.style == .harpPedalTextDiagram }
        try #require(texts.count == 2)
        let glyphs = try #require(texts[0].richText)
        let pedals = glyphs.lines.flatMap(\.runs)
        #expect(pedals.allSatisfy { abs($0.font.pointSize - 4 * F.sp) < 0.01 })
        #expect(abs(glyphs.size.width - 8 * F.sp) < 0.25 * F.sp)
        let names = try #require(texts[1].richText)
        let symbols = names.lines.flatMap(\.runs).filter { if case .symbol = $0.content { true } else { false } }
        #expect(!symbols.isEmpty)
        #expect(symbols.allSatisfy { abs($0.font.pointSize - 8 * F.sp / 5) < 0.01 })
    }

    @Test("a play technique and a string tunings text set their symbols at the music font's size")
    func scaledSymbolsOnTechniqueAndTunings() throws {
        let markup = PreservedTextMarkup(xmlText: "<sym>stringsDownBow</sym>pizz.")
        var pizz = StaffText(text: "pizz.", preservedTextMarkup: markup)
        pizz.annotation = .playTechnique(.pizzicato, playsBack: true)
        let technique = F.layout(F.score([F.whole()], system: Self.lane(pizz)))
        let run = try #require(F.staffTexts(technique).first?.richText?.lines.first?.runs.first)
        #expect(abs(run.font.pointSize - 4 * F.sp) < 0.01)
        let plain = StaffText(text: "pizz.", preservedTextMarkup: markup)
        let ordinary = F.layout(F.score([F.whole()], system: Self.lane(plain)))
        let plainRun = try #require(F.staffTexts(ordinary).first?.richText?.lines.first?.runs.first)
        #expect(abs(plainRun.font.pointSize - 10 * F.sp / 5) < 0.01)
        let flat = PreservedTextMarkup(xmlText: "Drop D<sym>csymAccidentalFlat</sym>")
        let dropD = StringTunings(text: "Drop D", preservedTextMarkup: flat)
        let tunings = F.layout(F.score([.stringTunings(dropD), F.whole()]))
        let tuningRuns = try #require(F.staffTexts(tunings).first?.richText?.lines.first?.runs)
        let tuningSymbol = try #require(tuningRuns.first { if case .symbol = $0.content { true } else { false } })
        #expect(abs(tuningSymbol.font.pointSize - 4 * F.sp) < 0.01)
    }

    @Test("a diagram with no text draws nothing")
    func emptyDiagramDrawsNothing() {
        var bare = StaffText(text: "")
        bare.annotation = .harpPedal(HarpPedalDiagram())
        #expect(F.staffTexts(F.layout(F.score([F.whole()], system: Self.lane(bare)))).isEmpty)
    }
}
