#if canImport(CoreGraphics)
    import CoreGraphics
#endif
import Foundation

/// Acciaccatura stem-slash placement for a grace chord.
///
/// Uses Bravura's `graceNoteSlash{NE,SW,NW,SE}` glyph anchors (from
/// `bravura_metadata.json`) rather than MuseScore's algorithmic
/// placement: the anchors are the font designer's intended slash
/// endpoints and cross the stem biased toward the notehead, which reads
/// better than the algorithm-derived crossing. Anchors are in glyph
/// em-units with a math y-axis (y > 0 = up); 1 em = 1 sp at glyph
/// rendering size, so multiplying by the (mag-scaled) `sp` gives the
/// on-screen offset relative to the stem tip.
///
/// Shared so the Apple `GraceChordRenderer` and the Android `LayoutBridge`
/// draw the identical slash instead of each carrying the anchor table.
/// Endpoints come back in the SAME coordinate space as `noteOrigins`; the
/// caller adds its own measure / base offset.
public enum GraceSlashGeometry {
    public struct Endpoints: Equatable, Sendable {
        public let from: CGPoint
        public let to: CGPoint
        public init(from: CGPoint, to: CGPoint) {
            self.from = from
            self.to = to
        }
    }

    /// All metrics (`sp`, `defaultStemLength`, `stemThickness`) must be the
    /// grace chord's MAG-SCALED values so the slash matches the reduced
    /// stem. Returns `nil` for an empty chord.
    public static func slash(
        noteOrigins: [CGPoint],
        stem: StemDirection,
        sp: CGFloat,
        defaultStemLength: CGFloat,
        stemThickness: CGFloat,
    ) -> Endpoints? {
        guard let xMin = noteOrigins.map(\.x).min(),
              let xMax = noteOrigins.map(\.x).max(),
              let yTop = noteOrigins.map(\.y).min(),
              let yBot = noteOrigins.map(\.y).max()
        else { return nil }
        // Match the rendered stem attach (see `StemGeometry.attachDx`).
        let stemAttachDx = StemGeometry.attachDx(sp: sp) - stemThickness / 2
        let stemX: CGFloat
        let stemTipY: CGFloat
        // `graceNoteSlash` endpoints in em-units, math y. First tuple = SW
        // (NW for stem-down) bottom/top-left end; second = NE (SE) end.
        let endA: (x: CGFloat, y: CGFloat)
        let endB: (x: CGFloat, y: CGFloat)
        switch stem {
        case .up:
            stemX = xMax + stemAttachDx
            stemTipY = yTop - defaultStemLength
            endA = (-0.644, -2.456)
            endB = (1.284, -0.796)
        case .down:
            stemX = xMin - stemAttachDx
            stemTipY = yBot + defaultStemLength
            endA = (-0.596, 2.168)
            endB = (1.328, 0.628)
        }
        return Endpoints(
            from: CGPoint(x: stemX + endA.x * sp, y: stemTipY - endA.y * sp),
            to: CGPoint(x: stemX + endB.x * sp, y: stemTipY - endB.y * sp),
        )
    }
}
