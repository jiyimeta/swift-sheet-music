#if canImport(CoreGraphics)
    import CoreGraphics
#endif
import SheetMusicCore

extension SkylineAutoplacePass {
    /// The dynamic items an expression being placed ignores. MuseScore lets a dynamic and an expression of the same
    /// segment ignore each other (`Autoplace::itemsShouldIgnoreEachOther`, `rendering/score/autoplace.cpp:433-436`):
    /// the expression snapped to its dynamic (`LayoutEngine.snapExpressions`) — so it starts at most the snap's 0.5 sp
    /// right of that dynamic's ink, on its line — and would otherwise be pushed away from the dynamic it sits beside.
    static func snappedDynamics(
        of element: LayoutElement, shape: LayoutShape, in skyline: Skyline, sp: CGFloat,
    ) -> Set<Int> {
        guard case .staffText(_, _, _, .expression, _, _, _, _, _) = element, let box = shape.bbox else { return [] }
        let tolerance: CGFloat = 0.01
        let candidates = skyline.north.rects + skyline.south.rects
        return Set(candidates.filter { candidate in
            let rect = candidate.rect
            return candidate.item.kind == .dynamics
                && rect.maxX <= box.minX + tolerance && rect.maxX >= box.minX - 0.5 * sp - tolerance
                && rect.maxY > box.minY && rect.minY < box.maxY
        }.map(\.item.id))
    }
}
