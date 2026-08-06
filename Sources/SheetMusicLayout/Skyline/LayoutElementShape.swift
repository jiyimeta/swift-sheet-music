#if canImport(CoreGraphics)
    import CoreGraphics
#endif
import SheetMusicCore

/// `LayoutElement` → `LayoutShape`. This is where the quality of the
/// skyline is decided: text extents come from `FontMetrics.provider`
/// and SMuFL glyph extents from `glyphPathBoundingBox`, rather than
/// the character-count constants the retired `LayoutEngine+Extents`
/// helpers used.
///
/// All rects are produced in MEASURE-LOCAL coordinates and shifted by
/// `xOffset` (the measure's accumulated `xCursor`) in `shape`.
public enum LayoutElementShape {
    /// Category of `element`, or `nil` when it must not participate in
    /// the skyline at all: `.staffName` lives in the gutter, and slurs
    /// / vibrato already have dedicated placement passes that consult
    /// chord extents directly.
    public static func kind(of element: LayoutElement) -> ShapeItemKind? {
        switch element {
        case .staffName: nil
        case .chord: .chord
        case .graceChord: .graceChord
        case .beam: .beam
        case .rest: .rest
        case .note: .note
        case .articulation: .articulation
        case .fermata: .fermata
        case .breath: .breath
        case .tieArc: .tie
        case .tupletLabel: .tupletLabel
        case .barLine: .barLine
        case .clef: .clef
        case .keySignature: .keySignature
        case .timeSignature: .timeSignature
        case .measureRepeat: .measureRepeat
        case .multiMeasureRest: .multiMeasureRest
        case .tremoloBars: .tremolo
        case .chordLine: .chordLine
        case .arpeggioWiggle: .arpeggio
        case .glissandoLine: .glissando
        case .measureNumber: .measureNumber
        case .harmony: .harmony
        case .rehearsalMark: .rehearsalMark
        case .marker: .marker
        case .jump: .jump
        case .lyricsMelisma: .lyricsMelisma
        case .lyricHyphen: .lyricHyphen
        case let .staffText(_, _, _, style):
            // Instrument-change instructions reuse the staffText skyline
            // slot — same staff-attached autoplace behaviour, and
            // `AutoplaceRules` already lists `.staffText`.
            style == .systemText ? .systemText : .staffText
        case let .textMark(markKind, _, _):
            switch markKind {
            case .dynamic: .dynamics
            case .tempo: .tempo
            case .lyrics: .lyrics
            }
        case let .spannerSegment(spannerKind, _, _, _, _, _):
            switch spannerKind {
            case .slur, .vibrato: nil
            case .volta: .volta
            case .hairpinOpen, .hairpinClose: .hairpin
            case .pedal: .pedal
            case .ottava: .ottava
            case .textLine: .textLine
            }
        }
    }

    /// Synthetic rect for the staff itself, spanning the system's
    /// horizontal extent. Registered first so `Skyline.add`'s filter
    /// has its reference edges.
    static func staffRect(
        xMin: CGFloat, xMax: CGFloat,
        staffMidY: CGFloat, metrics: StaffMetrics,
    ) -> ShapeRect {
        ShapeRect(
            rect: CGRect(
                x: xMin, y: staffMidY - metrics.sp * 2,
                width: max(0, xMax - xMin),
                height: metrics.staffHeight,
            ),
            item: ShapeItem(kind: .staff, id: -1),
        )
    }

    /// Ink rect of a SMuFL glyph drawn with a `.center` anchor at
    /// `center`. Mirrors the baseline math in `FermataGlyphMetrics`:
    /// the anchor puts the typographic centre at `center.y`, so the
    /// baseline sits `(ascent − descent) / 2` below it, and the glyph
    /// path bbox is measured relative to that baseline.
    ///
    /// `baselineFromCenter` evaluates to exactly 0 on Bravura, whose
    /// ascent and descent are equal (8.048 each at pointSize 4), so
    /// for the fonts we ship the baseline IS the anchor. It is kept
    /// because the derivation — not the number — is what makes this
    /// rect agree with the renderer, and a non-symmetric SMuFL face
    /// would need it. Consequence for testing: no assertion can catch
    /// this term being dropped, so
    /// `fermataShapeInkMatchesGlyphMetrics` pins the band against
    /// `FermataGlyphMetrics` instead, which catches every error that
    /// actually moves ink (centring on the origin, using the em box,
    /// using `ascent` as the baseline).
    static func smuflGlyphRect(
        codepoint: UInt32, center: CGPoint, sp: CGFloat,
    ) -> CGRect {
        // pointSize 4 ⇒ 1 em = 4 units ⇒ 1 unit = 1 sp.
        let em = LayoutFont(face: SMuFLFamily.bravura, pointSize: 4)
        let provider = FontMetrics.provider
        let baselineFromCenter =
            (provider.ascent(font: em) - provider.descent(font: em)) / 2
        guard let bbox = provider.glyphPathBoundingBox(
            font: em, codepoint: UInt16(truncatingIfNeeded: codepoint),
        ), bbox.width > 0, bbox.height > 0 else {
            return CGRect(
                x: center.x - sp * 0.5, y: center.y - sp * 0.5,
                width: sp, height: sp,
            )
        }
        let top = center.y + (baselineFromCenter - bbox.maxY) * sp
        let bottom = center.y + (baselineFromCenter - bbox.minY) * sp
        return CGRect(
            x: center.x - bbox.width * sp / 2,
            y: top,
            width: bbox.width * sp,
            height: max(0, bottom - top),
        )
    }

    /// Full shape of `element` in SYSTEM-X / staff-local-Y coordinates.
    /// `nil` when the element is excluded from the skyline.
    public static func shape(
        for element: LayoutElement, id: Int,
        xOffset: CGFloat, metrics: StaffMetrics,
    ) -> LayoutShape? {
        guard let kind = kind(of: element) else { return nil }
        let rects = AutoplaceRules.isAutoplaced(kind)
            ? autoplacedRects(for: element, kind: kind, metrics: metrics)
            : baseRects(for: element, kind: kind, metrics: metrics)
        guard !rects.isEmpty else { return nil }
        let item = ShapeItem(kind: kind, id: id)
        return LayoutShape(rects: rects.map {
            ShapeRect(
                rect: CGRect(
                    x: $0.minX + xOffset, y: $0.minY,
                    width: $0.width, height: $0.height,
                ),
                item: item,
            )
        })
    }
}
