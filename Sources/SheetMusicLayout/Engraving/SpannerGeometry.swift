#if canImport(CoreGraphics)
    import CoreGraphics
#endif
import SheetMusicCore
import SheetMusicFoundation

/// Pure geometry for spanner segments — slurs, voltas, hairpins,
/// pedals, ottavas, and generic text lines. Each spanner kind exposes
/// the primitive shapes (polyline points, Bezier control point, glyph
/// positions) the renderer needs; the renderer is responsible for
/// turning those primitives into platform-specific stroke / glyph /
/// text draw calls.
public enum SpannerGeometry {
    /// Stroke thickness for slurs, voltas, hairpins (`sp * 0.15`).
    public static let strokeThicknessSp: CGFloat = 0.15

    /// Stroke thickness for ottava / generic text-line dashes
    /// (`sp * 0.10`).
    public static let lineThicknessSp: CGFloat = 0.10

    /// Volta label point size (`sp * 2.0`).
    public static let voltaLabelSizeSp: CGFloat = 2.0

    /// Ottava label point size (`sp * 2.5`).
    public static let ottavaLabelSizeSp: CGFloat = 2.5

    /// TextLine label point size (`sp * 2.2`).
    public static let textLineLabelSizeSp: CGFloat = 2.2

    /// Vertical ink extent of a laid-out segment, centred on its anchor
    /// line. Single-sourced here because two consumers must agree on
    /// it: `LayoutElementShape.spannerRect` builds the rect the skyline
    /// collides against, and `LayoutEngine.elementYPoints` reserves the
    /// system height the segment is drawn into. If they drift apart, a
    /// segment the skyline pushed down gets clipped by a system that
    /// never grew to hold it.
    ///
    /// A wedge is `1.4 sp` tall (the aperture at its open end) and a
    /// pedal `1.5 sp` (the bracket plus its hook); every other kind is
    /// as tall as its label.
    public static func segmentThickness(
        kind: LayoutElement.SpannerKind, sp: CGFloat,
    ) -> CGFloat {
        switch kind {
        case .hairpinOpen, .hairpinClose:
            sp * 1.4
        case .hairpinLine:
            sp * hairpinLineLabelSizeSp
        case .volta:
            sp * voltaLabelSizeSp
        case .ottava:
            sp * ottavaLabelSizeSp
        case .textLine, .palmMute, .letRing, .gradualTempoChange, .chordTextLine:
            // A gradual tempo change measures its own ink (`gradualTempoChangeInk`); this is only the plain-band
            // fallback for callers that hold no label.
            sp * textLineLabelSizeSp
        case .pedal:
            sp * 1.5
        case .slur, .vibrato, .trill:
            sp
        }
    }

    // MARK: - Slur

    /// Quadratic Bezier control point for a single-segment slur arc.
    /// The renderer composes `Path.addQuadCurve(to: to, control:)`
    /// using this point.
    public static func slurControlPoint(
        from: CGPoint, to: CGPoint, sp: CGFloat,
    ) -> CGPoint {
        CGPoint(
            x: (from.x + to.x) / 2,
            y: min(from.y, to.y) - sp * 2,
        )
    }

    // MARK: - Volta

    /// Volta bracket polyline: optional left hook, top run, optional
    /// right hook. `continuesLeft` / `continuesRight` suppress the
    /// hooks at the corresponding ends (system-spanning voltas).
    public static func voltaBracketPoints(
        from: CGPoint, to: CGPoint,
        continuesLeft: Bool, continuesRight: Bool,
        sp: CGFloat,
    ) -> [CGPoint] {
        let top = min(from.y, to.y)
        var pts: [CGPoint] = []
        if !continuesLeft {
            pts.append(CGPoint(x: from.x, y: top + sp))
            pts.append(CGPoint(x: from.x, y: top))
        } else {
            pts.append(CGPoint(x: from.x, y: top))
        }
        pts.append(CGPoint(x: to.x, y: top))
        if !continuesRight {
            pts.append(CGPoint(x: to.x, y: top + sp))
        }
        return pts
    }

    // MARK: - Hairpin

    /// Two line segments diverging from / converging to a shared
    /// vertex. `open` selects crescendo (apex at `from`) vs.
    /// decrescendo (apex at `to`).
    public struct HairpinSegments: Sendable, Equatable {
        public let upperFrom: CGPoint
        public let upperTo: CGPoint
        public let lowerFrom: CGPoint
        public let lowerTo: CGPoint
    }

    public static func hairpin(
        from: CGPoint, to: CGPoint, open: Bool, sp: CGFloat,
    ) -> HairpinSegments {
        let y = max(from.y, to.y)
        if open {
            return HairpinSegments(
                upperFrom: CGPoint(x: from.x, y: y),
                upperTo: CGPoint(x: to.x, y: y - sp),
                lowerFrom: CGPoint(x: from.x, y: y),
                lowerTo: CGPoint(x: to.x, y: y + sp),
            )
        }
        return HairpinSegments(
            upperFrom: CGPoint(x: from.x, y: y - sp),
            upperTo: CGPoint(x: to.x, y: y),
            lowerFrom: CGPoint(x: from.x, y: y + sp),
            lowerTo: CGPoint(x: to.x, y: y),
        )
    }

    // MARK: - Hairpin line ("cresc." / "dim.")

    /// Label height, in spatia, a hairpin line reserves where no label has been measured (`segmentThickness`). The
    /// line itself is `textLineBase`'s.
    public static let hairpinLineLabelSizeSp: CGFloat = 2.2

    // MARK: - Ottava

    public struct OttavaParts: Sendable, Equatable {
        /// SMuFL codepoint of the label glyph.
        public let labelCodepoint: UInt32
        /// Plain-text spelling of the same label. Kept for hit-testing
        /// / accessibility and for back-ends without the music font.
        public let label: String
        public let labelOrigin: CGPoint
        public let lineStart: CGPoint
        public let lineEnd: CGPoint
        public let lineThicknessSp: CGFloat
        public let dashPattern: [CGFloat]
    }

    /// `subtype` selects the label glyph, mirroring MuseScore's
    /// `Sid::ottava*Text` style rows (`styledef.cpp:645-668`): the full
    /// `ottavaAlta` / `quindicesimaBassa` / … forms, or the bare
    /// `ottava` / `quindicesima` / `ventiduesima` number glyphs when
    /// `numbersOnly` is on (MuseScore's default —
    /// `Sid::ottavaNumbersOnly`, `styledef.cpp:679`). The alta / bassa
    /// distinction then rides on the line's placement.
    public static func ottava(
        from: CGPoint, to: CGPoint, sp: CGFloat,
        subtype: Spanner.OttavaPayload.Subtype,
        numbersOnly: Bool = false,
    ) -> OttavaParts {
        let codepoint = ottavaCodepoint(
            subtype: subtype, numbersOnly: numbersOnly,
        )
        return OttavaParts(
            labelCodepoint: codepoint,
            label: numbersOnly
                ? ottavaNumberText(subtype: subtype)
                : subtype.rawValue,
            labelOrigin: from,
            lineStart: CGPoint(x: from.x + sp * 3, y: from.y),
            lineEnd: to,
            lineThicknessSp: lineThicknessSp,
            dashPattern: [3, 3],
        )
    }

    /// SMuFL glyph for an octave-line label.
    public static func ottavaCodepoint(
        subtype: Spanner.OttavaPayload.Subtype, numbersOnly: Bool,
    ) -> UInt32 {
        switch subtype {
        case .eightVA:
            return numbersOnly
                ? SMuFLCodepoint.ottava : SMuFLCodepoint.ottavaAlta
        case .eightVB:
            return numbersOnly
                ? SMuFLCodepoint.ottava : SMuFLCodepoint.ottavaBassa
        case .fifteenMA:
            return numbersOnly
                ? SMuFLCodepoint.quindicesima
                : SMuFLCodepoint.quindicesimaAlta
        case .fifteenMB:
            return numbersOnly
                ? SMuFLCodepoint.quindicesima
                : SMuFLCodepoint.quindicesimaBassa
        case .twentyTwoMA:
            return numbersOnly
                ? SMuFLCodepoint.ventiduesima
                : SMuFLCodepoint.ventiduesimaAlta
        case .twentyTwoMB:
            return numbersOnly
                ? SMuFLCodepoint.ventiduesima
                : SMuFLCodepoint.ventiduesimaBassa
        // An unrecognized subtype falls back to 8va, matching
        // `OttavaPayload.Subtype.semitones`.
        case .other:
            return numbersOnly
                ? SMuFLCodepoint.ottava : SMuFLCodepoint.ottavaAlta
        }
    }

    private static func ottavaNumberText(
        subtype: Spanner.OttavaPayload.Subtype,
    ) -> String {
        switch subtype {
        case .fifteenMA, .fifteenMB: "15"
        case .twentyTwoMA, .twentyTwoMB: "22"
        case .eightVA, .eightVB, .other: "8"
        }
    }

    // MARK: - Vibrato

    /// SMuFL codepoint for the given vibrato subtype.
    public static func vibratoCodepoint(type: VibratoType) -> UInt32 {
        switch type {
        case .guitarVibrato: return SMuFLCodepoint.guitarVibratoStroke
        case .guitarVibratoWide: return SMuFLCodepoint.guitarWideVibratoStroke
        case .sawtooth: return SMuFLCodepoint.wiggleSawtooth
        case .sawtoothWide: return SMuFLCodepoint.wiggleSawtoothWide
        }
    }

    /// Glyph run for a vibrato line. Returns the SMuFL codepoint to
    /// draw and the origins of each glyph copy along the line.
    ///
    /// The glyph is repeated as many times as fit between `from` and `to`:
    ///   count = lrint((width − advance) / advance)
    /// Each copy is placed at `from.x + i * advance` on the same Y as `from`.
    ///
    /// - Parameters:
    ///   - from: Start point of the vibrato segment (layout Y-down).
    ///   - to:   End point of the vibrato segment.
    ///   - type: Vibrato subtype controlling the glyph.
    ///   - sp:   Staff spatium (unused in current geometry; reserved for
    ///           future sub-spatium nudges).
    ///   - advance: Typographic advance of the glyph in layout points.
    ///
    /// C++: `vibrato.cpp:49-67`, `tlayout.cpp:6447-6462`.
    public static func vibratoGlyphRun(
        from: CGPoint,
        to: CGPoint,
        type: VibratoType,
        sp _: CGFloat,
        advance: CGFloat,
    ) -> (codepoint: UInt32, origins: [CGPoint]) {
        let codepoint = vibratoCodepoint(type: type)
        guard advance > 0 else { return (codepoint, []) }
        let width = to.x - from.x
        // Mirror MuseScore `VibratoSegment::symbolLine(start, fill)`:
        // always emit the start glyph, then append fill copies.
        // C++: vibrato.cpp:49-67
        let fillCount = max(0, lrint(Double((width - advance) / advance)))
        let count = 1 + fillCount
        let origins = (0 ..< count).map { i in
            CGPoint(x: from.x + CGFloat(i) * advance, y: from.y)
        }
        return (codepoint, origins)
    }
}
