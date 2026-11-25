import SheetMusicCore

/// The SMuFL glyphs a `ChordOrnament` is drawn with.
///
/// Most kinds are one glyph, named by the kind's own SymId. Seven have no codepoint in SMuFL: MuseScore composes them
/// from the zig-zag line and stroke pieces, drawn one after another at their advances
/// (`EngravingFont::loadComposedGlyphs`, `internal/engravingfont.cpp`), and so does this.
enum OrnamentGlyph {
    /// The glyphs of `kind`, in drawing order; `nil` for `.unknown`, which is not drawn.
    static func codepoints(_ kind: ChordOrnament.Kind) -> [UInt32]? {
        if case .unknown = kind { return nil }
        let names = composedNames(kind) ?? [kind.mscxToken]
        let codepoints = names.compactMap(SMuFLCodepoint.byName)
        return codepoints.count == names.count ? codepoints : nil
    }

    private static let zigZag = "ornamentZigZagLineNoRightEnd"
    private static let zigZagEnd = "ornamentZigZagLineWithRightEnd"
    private static let middleStroke = "ornamentMiddleVerticalStroke"
    private static let leftStroke = "ornamentLeftVerticalStroke"
    private static let bottomLeftStroke = "ornamentBottomLeftConcaveStroke"

    private static func composedNames(_ kind: ChordOrnament.Kind) -> [String]? {
        switch kind {
        case .prallMordent: [zigZag, zigZag, middleStroke, zigZagEnd]
        case .upPrall: [bottomLeftStroke, zigZag, zigZag, zigZagEnd]
        case .upMordent: [bottomLeftStroke, zigZag, zigZag, middleStroke, zigZagEnd]
        case .prallDown: [zigZag, zigZag, zigZag, "ornamentBottomRightConcaveStroke"]
        case .downMordent: [leftStroke, zigZag, zigZag, middleStroke, zigZagEnd]
        case .prallUp: [zigZag, zigZag, zigZag, "ornamentTopRightConvexStroke"]
        case .linePrall: [leftStroke, zigZag, zigZag, zigZagEnd]
        case .turn, .turnInverted, .turnSlash, .turnUp, .turnUpS, .trill, .shortTrill, .mordent, .haydn,
             .tremblement, .precompMordentUpperPrefix, .precompSlide, .shake3, .shakeMuffat1,
             .tremblementCouperin, .pinceCouperin, .unknown:
            nil
        }
    }
}
