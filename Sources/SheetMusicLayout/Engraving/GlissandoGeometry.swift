#if canImport(CoreGraphics)
    import CoreGraphics
#endif
import Foundation

/// Glissando line geometry: straight or wavy line between two
/// noteheads, with an optional centered text label whose baseline
/// follows the line's slope. Mirrors MuseScore's
/// `tdraw.cpp::draw(GlissandoSegment)`.
///
/// Geometry is computed in a LOCAL coordinate system anchored at the
/// `from` point and rotated so the line runs along the local x axis
/// from `(0, 0)` to `(length, 0)`. The renderer transforms the points
/// back into world coords with `translate(from) · rotate(angle)`.
public enum GlissandoGeometry {
    /// Stroke thickness as a multiple of `sp`.
    public static let lineThicknessSp: CGFloat = 0.15

    /// Result of resolving the from/to pair into the rotated local
    /// frame: euclidean distance and the rotation angle in radians.
    public static func length(from: CGPoint, to: CGPoint) -> CGFloat {
        let dx = to.x - from.x
        let dy = to.y - from.y
        return sqrt(dx * dx + dy * dy)
    }

    public static func angle(from: CGPoint, to: CGPoint) -> CGFloat {
        let dx = to.x - from.x
        let dy = to.y - from.y
        return atan2(dy, dx)
    }

    /// Polyline points in the LOCAL (rotated) frame. The first point
    /// is `(0, 0)`; the last point is `(length, 0)` for a straight
    /// line, or near it for a wavy line. Wavy lines zig-zag between
    /// `+sp*0.3` and `-sp*0.3` on alternating segments.
    public static func linePoints(
        length: CGFloat, wavy: Bool, sp: CGFloat,
    ) -> [CGPoint] {
        if wavy {
            let waveAmp = sp * 0.3
            let segments = max(3, Int(length / (sp * 0.8)))
            let segLen = length / CGFloat(segments)
            var pts: [CGPoint] = [.zero]
            pts.reserveCapacity(segments + 1)
            for i in 1 ... segments {
                let x = segLen * CGFloat(i)
                let y = i.isMultiple(of: 2) ? waveAmp : -waveAmp
                pts.append(CGPoint(x: x, y: y))
            }
            return pts
        }
        return [.zero, CGPoint(x: length, y: 0)]
    }

    /// Vertical clearance between the text's descender and the
    /// underlying line. Mirrors `tdraw.cpp:1584`.
    public static func textClearanceSp(wavy: Bool) -> CGFloat {
        wavy ? 0.4 : 0.1
    }

    /// Position of the label's anchor (bottom-center) in the LOCAL
    /// rotated frame. The label sits at the midpoint of the line
    /// with its descender just above the line by `textClearanceSp(:)`.
    public static func textAnchorLocal(
        length: CGFloat, wavy: Bool, sp: CGFloat,
    ) -> CGPoint {
        CGPoint(
            x: length / 2,
            y: -sp * textClearanceSp(wavy: wavy),
        )
    }

    /// Rotate a LOCAL-frame point back into WORLD coords via the
    /// transform `T_from · R(angle)`.
    public static func toWorld(
        local: CGPoint, from: CGPoint, angle: CGFloat,
    ) -> CGPoint {
        let cosA = cos(angle)
        let sinA = sin(angle)
        return CGPoint(
            x: cosA * local.x - sinA * local.y + from.x,
            y: sinA * local.x + cosA * local.y + from.y,
        )
    }
}
