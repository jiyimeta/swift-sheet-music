#if canImport(CoreGraphics)
    import CoreGraphics
#endif
import Foundation

/// Stem placement math for a chord.
///
/// Encodes the Bravura-anchored attach offset, the standard
/// `tip + stemLength` extension when the chord is not beamed, and the
/// "beam Y substitutes for the stem terminus" rule that gives every
/// stem in a beam group the same outer endpoint.
public enum StemGeometry {
    /// Horizontal distance from a Bravura `noteheadBlack` center to
    /// the stem. Derived from Bravura's published `stemUpSE.x = 1.18 sp`
    /// (half-width when glyphs are drawn with a `.center` anchor):
    /// `|stem_x − center| = 0.59 sp`.
    public static func attachDx(sp: CGFloat) -> CGFloat {
        sp * 0.59
    }

    public struct Result: Equatable, Sendable {
        public let xStem: CGFloat
        public let startY: CGFloat
        public let endY: CGFloat

        public init(xStem: CGFloat, startY: CGFloat, endY: CGFloat) {
            self.xStem = xStem
            self.startY = startY
            self.endY = endY
        }
    }

    /// Compute stem geometry for a chord whose noteheads sit at
    /// `noteOrigins` (in screen coordinates, y-down).
    ///
    /// - Parameters:
    ///   - noteOrigins: Notehead origin points in any order. Empty array
    ///     yields `nil`.
    ///   - direction: Which side of the chord the stem sits on.
    ///   - beamY: When non-nil, substitutes for the natural stem-tip y
    ///     on the beam side. Used so every stem in a beam group ends on
    ///     the same beam bar.
    ///   - defaultStemLength: Natural extension of an unbeamed stem from
    ///     the outermost notehead.
    ///   - stemExtension: Additional length (e.g. extra leger-line
    ///     headroom). Defaults to 0.
    ///   - sp: Staff-space size, used by `attachDx`.
    public static func compute(
        noteOrigins: [CGPoint],
        direction: StemDirection,
        beamY: CGFloat?,
        defaultStemLength: CGFloat,
        stemExtension: CGFloat = 0,
        sp: CGFloat,
    ) -> Result? {
        guard !noteOrigins.isEmpty else { return nil }
        let xs = noteOrigins.map(\.x)
        let ys = noteOrigins.map(\.y)
        let attach = attachDx(sp: sp)
        let xMin = xs.min() ?? 0
        let xMax = xs.max() ?? 0
        let yTop = ys.min() ?? 0
        let yBot = ys.max() ?? 0
        switch direction {
        case .up:
            return Result(
                xStem: xMax + attach,
                startY: beamY ?? (yTop - defaultStemLength - stemExtension),
                endY: yBot,
            )
        case .down:
            return Result(
                xStem: xMin - attach,
                startY: yTop,
                endY: beamY ?? (yBot + defaultStemLength + stemExtension),
            )
        }
    }
}
