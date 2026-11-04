@testable import SheetMusicRenderWindows
import Testing

/// The stroke floor gives way when zoomed out, so a staff's lines stay apart (folino Windows QA, 2026-10-31).
@Suite("Stroke floor")
struct StrokeFloorTests {
    @Test("at and above ~3.75 px/mm the floor is the fixed 1.5 px the other renderers keep")
    func fixedFloorAtReadingSizes() {
        // 96 dpi at zoom 100% is ~3.78 px/mm; the parity probe draws at 8.
        for pxPerMM in [3.78, 8.0, 16.0] {
            #expect(DrawCommandWalker.strokeFloorPx(pxPerMM: pxPerMM) == DrawCommandWalker.minStrokePx)
        }
    }

    @Test("zoomed out, the floor leaves most of a staff space clear")
    func floorShrinksWhenZoomedOut() {
        // Zoom 25% on a 100% display: ~0.95 px/mm, a 1.75 mm staff space ~1.65 px.
        let pxPerMM = 0.945
        let floor = DrawCommandWalker.strokeFloorPx(pxPerMM: pxPerMM)
        #expect(floor < DrawCommandWalker.minStrokePx)
        #expect(floor <= 1.75 * pxPerMM / 4)
    }
}
