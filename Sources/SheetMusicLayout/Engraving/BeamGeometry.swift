#if canImport(CoreGraphics)
    import CoreGraphics
#endif
import SheetMusicFoundation

/// Geometry constants for a beamed-note beam bar.
///
/// A `.beam` LayoutElement is emitted once per (run, level) pair. The
/// LayoutEngine passes the chord stem endpoints unchanged for every
/// level — it's the renderer's job to apply the level offset so
/// secondary bars stack inside the primary toward the noteheads.
///
/// `level == 1` is the primary 8th-note bar. `level == 2` is the
/// first secondary (16th-note); `level == 3` adds a 32nd, and so on.
/// The stack direction depends on the chord's stem direction:
///
///   - stem-up: bars stack DOWN (positive y in y-down screen coords)
///   - stem-down: bars stack UP (negative y)
public enum BeamGeometry {
    public static let beamThicknessSp: CGFloat = 0.5
    public static let beamGapSp: CGFloat = 0.3

    /// Y offset (in points) from the primary beam endpoint Y at which
    /// a beam at `level` should be drawn. Returns 0 for `level == 1`.
    public static func levelOffsetDy(
        level: Int, stemDirection: StemDirection, sp: CGFloat,
    ) -> CGFloat {
        guard level >= 1 else { return 0 }
        let stackSign: CGFloat = stemDirection == .up ? 1 : -1
        return CGFloat(level - 1)
            * (beamThicknessSp + beamGapSp) * sp * stackSign
    }
}
