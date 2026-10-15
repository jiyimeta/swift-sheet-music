#if canImport(CoreGraphics)
    import CoreGraphics
#endif
@testable import SheetMusicCore
@testable import SheetMusicLayout
import Testing

#if !canImport(CoreGraphics)
    private typealias CGFloat = SheetMusicLayout.CGFloat
#endif

/// MuseScore's own numbers for the annotation text styles (`style/styledef.cpp`), the roles whose placement a score's
/// `<Style>` can move, and the glyph names `<sym>` and `<Symbol>` resolve.
@Suite("Annotation styles")
struct AnnotationStyleTests {
    private struct Row {
        let style: TextStyleType
        let size: Double
        let fontStyle: FontStyleSet
        let frame: TextFrameType
        let symbolSize: CGFloat
    }

    private static let rows: [Row] = [
        Row(style: .expression, size: 10, fontStyle: [.italic], frame: .none, symbolSize: 10),
        Row(style: .sticking, size: 10, fontStyle: [], frame: .none, symbolSize: 10),
        Row(style: .fingering, size: 8, fontStyle: [], frame: .none, symbolSize: 8),
        Row(style: .lhGuitarFingering, size: 8, fontStyle: [], frame: .none, symbolSize: 8),
        Row(style: .rhGuitarFingering, size: 8, fontStyle: [.italic], frame: .none, symbolSize: 8),
        Row(style: .stringNumber, size: 8, fontStyle: [], frame: .circle, symbolSize: 8),
        Row(style: .stringTunings, size: 9, fontStyle: [], frame: .none, symbolSize: 9),
        Row(style: .harpPedalDiagram, size: 10, fontStyle: [], frame: .none, symbolSize: 10),
        Row(style: .harpPedalTextDiagram, size: 8, fontStyle: [], frame: .none, symbolSize: 8),
        Row(style: .fretDiagramFretNumber, size: 6, fontStyle: [], frame: .none, symbolSize: 6),
    ]

    @Test("each style carries its styledef row")
    func defaultsMatchStyledef() {
        for row in Self.rows {
            let defaults = row.style.museScoreDefault
            #expect(defaults.face == "Edwin", "\(row.style) face")
            #expect(defaults.size == row.size, "\(row.style) size")
            #expect(defaults.style == row.fontStyle, "\(row.style) style")
            #expect(defaults.frameType == row.frame, "\(row.style) frame")
            #expect(defaults.spatiumDependent, "\(row.style) is spatium dependent")
        }
    }

    @Test("a style's <sym> runs are drawn at its musical-symbol size")
    func symbolSizes() {
        for row in Self.rows {
            #expect(LayoutRichText.musicalSymbolSize(for: row.style) == row.symbolSize, "\(row.style)")
        }
    }

    @Test("expression and sticking default below the staff, the harp text diagram too, the glyph diagram above")
    func rolePlacements() {
        #expect(TextPlacementRole.expression.defaultPlacement == .below)
        #expect(TextPlacementRole.sticking.defaultPlacement == .below)
        #expect(TextPlacementRole.harpPedalDiagram.defaultPlacement == .above)
        #expect(TextPlacementRole.harpPedalTextDiagram.defaultPlacement == .below)
    }

    @Test("role positions are the styledef pos rows")
    func rolePositions() {
        #expect(TextPlacementRole.expression.defaultPosition(on: .above) == ScoreOffset(x: 0, y: -1.5))
        #expect(TextPlacementRole.expression.defaultPosition(on: .below) == ScoreOffset(x: 0, y: 2.5))
        #expect(TextPlacementRole.sticking.defaultPosition(on: .above) == ScoreOffset(x: 0, y: -1))
        #expect(TextPlacementRole.sticking.defaultPosition(on: .below) == ScoreOffset(x: 0, y: 2))
        // The harp diagram rows are never applied by MuseScore: the position is the staff edge itself.
        for role in [TextPlacementRole.harpPedalDiagram, .harpPedalTextDiagram] {
            #expect(role.defaultPosition(on: .above) == ScoreOffset(x: 0, y: 0))
            #expect(role.defaultPosition(on: .below) == ScoreOffset(x: 0, y: 0))
        }
    }

    @Test("the by-name table resolves what annotations spell")
    func glyphNames() {
        #expect(SMuFLCodepoint.byName("csymAccidentalFlat") == 0xED60)
        #expect(SMuFLCodepoint.byName("csymAccidentalNatural") == 0xED61)
        #expect(SMuFLCodepoint.byName("csymAccidentalSharp") == 0xED62)
        #expect(SMuFLCodepoint.byName("guitarString1") == 0xE834)
        #expect(SMuFLCodepoint.byName("guitarString6") == 0xE839)
        #expect(SMuFLCodepoint.byName("ornamentTrill") == 0xE566)
        #expect(SMuFLCodepoint.byName("ornamentTurn") == 0xE567)
        #expect(SMuFLCodepoint.byName("stringsUpBow") == 0xE612)
        #expect(SMuFLCodepoint.byName("fingering1") == 0xED11)
        #expect(SMuFLCodepoint.byName("tremoloFingered1") == 0xE225)
        #expect(SMuFLCodepoint.byName("noSuchGlyph") == nil)
    }
}
