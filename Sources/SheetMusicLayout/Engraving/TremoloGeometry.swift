#if canImport(CoreGraphics)
    import CoreGraphics
#endif
import SheetMusicFoundation

/// Pure geometry for tremolo bars: the slanted bars that cross a
/// chord's stem (single-chord tremolo) or span between two chords
/// (between tremolo). Apple renders these into `GraphicsContext` /
/// `CALayer`; Android emits them as stroked line segments.
///
/// Each bar is a thin line slanted +12° (left-low → right-high in
/// screen coords). Thickness and spacing match the beam constants
/// in `BeamGeometry` so beam and tremolo bars look uniform.
public enum TremoloGeometry {
    /// Beam-bar thickness, matching `drawBeam`.
    public static func barThickness(sp: CGFloat) -> CGFloat {
        sp * 0.5
    }

    /// Gap between successive bars, matching `drawBeam` (thickness +
    /// gap).
    public static func barSpacing(sp: CGFloat) -> CGFloat {
        sp * 0.8 // thickness (0.5 sp) + gap (0.3 sp)
    }

    /// Anchor for a tremolo decoration. Geometry is pre-computed by
    /// the placement / beam passes so the renderer just strokes
    /// parallel bars around `center`.
    public typealias Anchor = TremoloAnchor

    /// Result of resolving the anchor into a fixed center, half-width,
    /// and slant offset that the renderer consumes.
    public struct Resolved: Sendable, Equatable {
        public let center: CGPoint
        public let halfWidth: CGFloat
        /// Vertical offset between bar center and either endpoint
        /// — matches a +12° slant. Screen y grows downward, so the
        /// LEFT endpoint sits at `center.y + slantDy` (lower) and the
        /// RIGHT endpoint at `center.y - slantDy` (higher).
        public let slantDy: CGFloat
    }

    /// Geometry shared by both rendering surfaces.
    public static func resolve(
        anchor: Anchor, sp: CGFloat,
    ) -> Resolved {
        let center: CGPoint
        let halfWidth: CGFloat
        switch anchor {
        case let .single(c):
            center = c
            // Bars span the notehead width — Bravura's noteheadBlack
            // is 1.18 sp wide, so halfWidth = 0.59 sp matches.
            halfWidth = sp * 0.59
        case let .between(left, right):
            center = CGPoint(
                x: (left.x + right.x) / 2,
                y: (left.y + right.y) / 2,
            )
            halfWidth = max(
                sp * 0.3,
                (right.x - left.x) / 2 - sp * 0.2,
            )
        }
        let slantDy = halfWidth * tan(.pi / 15) // +12° (~0.2126)
        return Resolved(
            center: center, halfWidth: halfWidth, slantDy: slantDy,
        )
    }

    /// A single tremolo bar as two endpoints. Renderers stroke a line
    /// segment between `from` and `to` with `barThickness(sp:)`.
    public struct Bar: Sendable, Equatable {
        public let from: CGPoint
        public let to: CGPoint
    }

    /// Build the full list of bar segments for a tremolo with
    /// `barCount` bars.
    public static func bars(
        anchor: Anchor, barCount: Int, sp: CGFloat,
    ) -> [Bar] {
        guard barCount > 0 else { return [] }
        let resolved = resolve(anchor: anchor, sp: sp)
        let spacing = barSpacing(sp: sp)
        let firstOffset = -CGFloat(barCount - 1) / 2 * spacing
        var result: [Bar] = []
        result.reserveCapacity(barCount)
        for i in 0 ..< barCount {
            let offsetY = firstOffset + CGFloat(i) * spacing
            let from = CGPoint(
                x: resolved.center.x - resolved.halfWidth,
                y: resolved.center.y + offsetY + resolved.slantDy,
            )
            let to = CGPoint(
                x: resolved.center.x + resolved.halfWidth,
                y: resolved.center.y + offsetY - resolved.slantDy,
            )
            result.append(Bar(from: from, to: to))
        }
        return result
    }
}
