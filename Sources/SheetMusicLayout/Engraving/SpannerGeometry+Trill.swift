#if canImport(CoreGraphics)
    import CoreGraphics
#endif
import SheetMusicCore
import SheetMusicFoundation

/// Trill-line geometry: which SMuFL glyphs a `TrillType` is built
/// from, and how they tile along the segment.
extension SpannerGeometry {
    /// The SMuFL glyphs a trill line is built from. `end` is non-nil
    /// only for the zig-zag forms, which MuseScore terminates with a
    /// dedicated right-end glyph.
    /// C++: `tlayout.cpp:6313-6328` (`TrillSegment::symbolLine` args).
    public struct TrillSymbols: Sendable, Equatable {
        public let start: UInt32
        public let fill: UInt32
        public let end: UInt32?
    }

    /// `continuesLeft` marks a continuation segment: MuseScore drops
    /// the sigil and starts with the fill glyph (`tlayout.cpp:6344`).
    public static func trillSymbols(
        type: TrillType, continuesLeft: Bool = false,
    ) -> TrillSymbols {
        switch type {
        case .trill:
            return TrillSymbols(
                start: continuesLeft
                    ? SMuFLCodepoint.wiggleTrill
                    : SMuFLCodepoint.ornamentTrill,
                fill: SMuFLCodepoint.wiggleTrill,
                end: nil,
            )
        case .prallprall:
            return TrillSymbols(
                start: SMuFLCodepoint.wiggleTrill,
                fill: SMuFLCodepoint.wiggleTrill,
                end: nil,
            )
        case .upprall, .downprall:
            let sigil = type == .upprall
                ? SMuFLCodepoint.ornamentBottomLeftConcaveStroke
                : SMuFLCodepoint.ornamentLeftVerticalStroke
            return TrillSymbols(
                start: continuesLeft
                    ? SMuFLCodepoint.ornamentZigZagLineNoRightEnd
                    : sigil,
                fill: SMuFLCodepoint.ornamentZigZagLineNoRightEnd,
                end: SMuFLCodepoint.ornamentZigZagLineWithRightEnd,
            )
        }
    }

    /// Lay a trill's glyph sequence out along `from`…`to`.
    ///
    /// Mirrors `TrillSegment::symbolLine` (`trill.cpp:82-122`): emit
    /// the start glyph, then `lrint((width − startAdvance − endAdvance)
    /// / fillAdvance)` fill copies, then the end glyph when the form
    /// has one. Advances come from the caller because only the
    /// platform font provider can measure them.
    public static func trillGlyphRun(
        from: CGPoint, to: CGPoint,
        symbols: TrillSymbols,
        startAdvance: CGFloat,
        fillAdvance: CGFloat,
        endAdvance: CGFloat,
    ) -> [(codepoint: UInt32, origin: CGPoint)] {
        guard fillAdvance > 0 else { return [] }
        let width = to.x - from.x
        let fillCount = max(0, lrint(Double(
            (width - startAdvance - endAdvance) / fillAdvance,
        )))
        var codepoints: [UInt32] = [symbols.start]
        codepoints.append(
            contentsOf:
            Array(repeating: symbols.fill, count: Int(fillCount)),
        )
        if let end = symbols.end { codepoints.append(end) }

        var out: [(codepoint: UInt32, origin: CGPoint)] = []
        var x = from.x
        for (index, codepoint) in codepoints.enumerated() {
            out.append((codepoint, CGPoint(x: x, y: from.y)))
            if index == 0 {
                x += startAdvance
            } else if symbols.end != nil, index == codepoints.count - 1 {
                x += endAdvance
            } else {
                x += fillAdvance
            }
        }
        return out
    }
}
