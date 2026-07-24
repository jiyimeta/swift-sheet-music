#if canImport(CoreGraphics)
    import CoreGraphics
#endif
import Foundation
import SheetMusicCore

/// One segment of a `ChordLine`'s stroked outline, in coordinates
/// relative to the element's origin. Mirrors the subset of
/// `muse::draw::PainterPath` that `ChordLine` ever produces.
public enum ChordLinePathSegment: Sendable, Equatable {
    case move(to: CGPoint)
    case line(to: CGPoint)
    case curve(control1: CGPoint, control2: CGPoint, to: CGPoint)
}

/// How a laid-out `ChordLine` is drawn. The default / straight / user
/// paths are stroked outlines; the "rough" palette variants are a
/// single rotated SMuFL glyph instead. C++: the `isWavy()` branch of
/// `TDraw::draw(const ChordLine*, …)`.
public enum ChordLineShape: Sendable, Equatable {
    /// Stroked outline, relative to the element's origin.
    case path([ChordLinePathSegment])
    /// SMuFL wave glyph, rotated about the origin by `rotationDegrees`
    /// (clockwise-positive, matching `Painter::rotate`).
    case glyph(codepoint: UInt32, rotationDegrees: CGFloat)
}

/// Shape + glyph geometry for the jazz/brass inflection lines
/// (fall / doit / plop / scoop). Single source of truth shared by the
/// Canvas renderer, the CALayer renderer, and the Android draw-program
/// bridge — the same pattern as `AccidentalGlyph` / `NoteheadGlyph`.
///
/// C++: `TLayout::layoutChordLine` (`rendering/score/tlayout.cpp`),
/// `TDraw::draw(const ChordLine*, …)` (`rendering/score/tdraw.cpp`), and
/// `ChordLine::waveSym` (`dom/chordline.cpp`).
public enum ChordLineGeometry {
    /// Stroke width. C++: `Sid::chordlineThickness` = `0.16_sp`.
    public static let thicknessSp: CGFloat = 0.16

    /// Horizontal clearance between the chord's edge and the start of
    /// the line. C++: `horOffset = 0.33 * spatium`.
    public static let horizontalOffsetSp: CGFloat = 0.33

    /// Vertical shift from the notehead's center. C++:
    /// `vertOffset = 0.25 * spatium`.
    public static let verticalOffsetSp: CGFloat = 0.25

    /// Vertical reach of the generated shape, before `mag`. C++:
    /// `baseLength = spatium * chord()->intrinsicMag()`.
    public static let verticalLengthSp: CGFloat = 1.0

    /// Horizontal reach of the generated shape, before `mag`. C++:
    /// `horBaseLength = 1.2 * baseLength` — "let the symbols extend a
    /// bit more horizontally".
    public static let horizontalLengthSp: CGFloat = 1.2

    public static func thickness(sp: CGFloat, mag: CGFloat = 1) -> CGFloat {
        thicknessSp * sp * mag
    }

    /// SMuFL glyph used by the wavy ("rough") palette variants.
    /// C++: `ChordLine::waveSym`.
    public static func waveCodepoint(kind: ChordLine.Kind) -> UInt32 {
        switch kind {
        case .fall, .plop: SMuFLCodepoint.brassFallRoughShort
        case .doit, .scoop: SMuFLCodepoint.brassLiftShort
        }
    }

    /// Rotation applied to the wave glyph. C++: `TDraw::draw` rotates by
    /// `(chordLineType() == FALL ? 1 : -1)` degrees.
    public static func waveRotationDegrees(kind: ChordLine.Kind) -> CGFloat {
        kind == .fall ? 1 : -1
    }

    /// The generated default outline, used whenever the user has not
    /// dragged the line into a custom shape.
    ///
    /// C++: the `if (!item->modified())` branch of `layoutChordLine`.
    /// `lengthX` / `lengthY` are deliberately *not* consulted — upstream
    /// they only accumulate drag deltas inside `ChordLine::dragGrip`,
    /// which then bakes the result into the stored `<Path>`.
    public static func defaultPath(
        for line: ChordLine,
        sp: CGFloat,
        mag: CGFloat = 1,
    ) -> [ChordLinePathSegment] {
        let baseLength = verticalLengthSp * sp * mag
        let horBaseLength = horizontalLengthSp * sp * mag
        let x2 = line.isToTheLeft ? -horBaseLength : horBaseLength
        let y2 = line.isBelow ? baseLength : -baseLength
        let end = CGPoint(x: x2, y: y2)
        let start = ChordLinePathSegment.move(to: .zero)

        if line.isStraight {
            return [start, .line(to: end)]
        }
        // The two curved forms differ in which axis leads: a line drawn
        // to the right leaves the notehead horizontally, one drawn to
        // the left arrives vertically.
        if line.isToTheLeft {
            return [start, .curve(
                control1: CGPoint(x: 0, y: y2 / 2),
                control2: CGPoint(x: x2 / 2, y: y2),
                to: end,
            )]
        }
        return [start, .curve(
            control1: CGPoint(x: x2 / 2, y: 0),
            control2: CGPoint(x: x2, y: y2 / 2),
            to: end,
        )]
    }

    /// Convert a user-edited `<Path>` (stored in spatium units) into
    /// renderable segments. Mirrors the state machine in
    /// `TRead::read(ChordLine*, …)`: a `curveTo` element carries the
    /// first control point and the two `curveToData` elements that
    /// follow carry the second control point and the end point.
    ///
    /// A truncated trailing cubic (fewer than two `curveToData` entries)
    /// is dropped rather than guessed at.
    public static func userPath(
        _ elements: [ChordLine.PathElement],
        sp: CGFloat,
    ) -> [ChordLinePathSegment] {
        var segments: [ChordLinePathSegment] = []
        var control1: CGPoint?
        var control2: CGPoint?
        for element in elements {
            let point = CGPoint(x: element.x * sp, y: element.y * sp)
            switch element.kind {
            case .moveTo:
                segments.append(.move(to: point))
            case .lineTo:
                segments.append(.line(to: point))
            case .curveTo:
                control1 = point
                control2 = nil
            case .curveToData:
                if control1 != nil, control2 == nil {
                    control2 = point
                } else if let c1 = control1, let c2 = control2 {
                    segments.append(.curve(control1: c1, control2: c2, to: point))
                    control1 = nil
                    control2 = nil
                }
            }
        }
        return segments
    }

    /// Ink extents of the wave glyph, in points. C++:
    /// `conf.engravingFont()->bbox(item->waveSym(), item->magS())`,
    /// which `layoutChordLine` uses to nudge the element into place.
    public static func waveGlyphBox(codepoint: UInt32, sp: CGFloat) -> CGSize {
        // pointSize 4 makes one em == 4 units == 1 sp, so the measured
        // box comes back in spatium units; scale once at the end.
        let font = LayoutFont(face: SMuFLFamily.bravura, pointSize: 4)
        guard let box = FontMetrics.provider.glyphPathBoundingBox(
            font: font, codepoint: UInt16(truncatingIfNeeded: codepoint),
        ) else {
            // Bravura's brass wiggles are roughly 1 sp tall and 2 wide;
            // only used when the provider has no glyph (stub / missing
            // font), where a plausible box beats a zero-size one.
            return CGSize(width: 2 * sp, height: sp)
        }
        return CGSize(width: box.width * sp, height: box.height * sp)
    }

    /// Convert MuseScore's baseline-left placement of the wave glyph
    /// into the centre-anchored point the renderers use
    /// (`GraphicsContext.drawGlyph` anchor `.center`, and the Android
    /// bridge's `emitCenterAnchoredGlyph`).
    ///
    /// The vertical half uses ascent/descent rather than the ink box:
    /// `.center` centres the *typographic* frame, so the baseline sits
    /// `(ascent − descent) / 2` below the anchor.
    public static func waveGlyphCenter(
        baselineOrigin: CGPoint,
        codepoint: UInt32,
        sp: CGFloat,
    ) -> CGPoint {
        let font = LayoutFont(face: SMuFLFamily.bravura, pointSize: sp * 4)
        let provider = FontMetrics.provider
        let baselineFromCentre =
            (provider.ascent(font: font) - provider.descent(font: font)) / 2
        let glyph = String(UnicodeScalar(codepoint).map(Character.init) ?? " ")
        let advance = provider.typographicWidth(text: glyph, font: font)
        return CGPoint(
            x: baselineOrigin.x + advance / 2,
            y: baselineOrigin.y - baselineFromCentre,
        )
    }

    /// Bounding box of a segment list, used to size the layout element
    /// and to place the wavy glyph. C++: `PainterPath::boundingRect`.
    ///
    /// Control points are included, so a curve's box can be slightly
    /// wider than its ink — the same approximation Qt's `boundingRect`
    /// makes, and what upstream feeds into `ldata->setBbox`.
    public static func boundingBox(of segments: [ChordLinePathSegment]) -> CGRect {
        var points: [CGPoint] = [.zero]
        for segment in segments {
            switch segment {
            case let .move(to), let .line(to):
                points.append(to)
            case let .curve(control1, control2, to):
                points.append(contentsOf: [control1, control2, to])
            }
        }
        let xs = points.map(\.x)
        let ys = points.map(\.y)
        guard let minX = xs.min(), let maxX = xs.max(),
              let minY = ys.min(), let maxY = ys.max()
        else { return .zero }
        return CGRect(
            x: minX, y: minY, width: maxX - minX, height: maxY - minY,
        )
    }
}
