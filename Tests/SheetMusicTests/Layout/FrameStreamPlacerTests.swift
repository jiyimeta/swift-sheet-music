#if canImport(CoreGraphics)
    import CoreGraphics
#endif
@testable import SheetMusicLayout
import Testing

#if !canImport(CoreGraphics)
    /// See `TitleBlockAlignTests`: anchor to SheetMusicLayout's own `CGFloat` off Apple.
    private typealias CGFloat = SheetMusicLayout.CGFloat
#endif

/// The vertical stream between the title and the systems when a mid-score box is present. Hand numbers at `sp = 10`:
/// the default gap is 7 sp = 70 pt, the padding to notation 2 sp = 20 pt.
@Suite("Frame stream placer") struct FrameStreamPlacerTests {
    private let sp: CGFloat = 10

    private func system(_ top: CGFloat, _ bottom: CGFloat) -> FrameStreamPlacer.Item {
        FrameStreamPlacer.Item(kind: .system(top: top, bottom: bottom))
    }

    private func frame(
        topGap: CGFloat? = nil, bottomGap: CGFloat? = nil, height: CGFloat,
    ) -> FrameStreamPlacer.Item {
        FrameStreamPlacer.Item(kind: .frame(topGap: topGap, bottomGap: bottomGap, height: height))
    }

    @Test("a default frame sits 7 sp below a system and replaces the baked distance to the next one")
    func defaultGapsReplaceTheBakedDistance() {
        let result = FrameStreamPlacer.place(
            title: nil, items: [system(0, 100), frame(height: 40), system(110, 210)], sp: sp,
        )
        #expect(result.frameOriginY == [170])
        #expect(result.systemShift == [0, 170])
        #expect(result.contentBottom == 380)
    }

    @Test("gaps below the 2 sp padding are raised to it, on both sides")
    func smallGapsFloorAtThePadding() {
        let result = FrameStreamPlacer.place(
            title: nil,
            items: [system(0, 100), frame(topGap: 1, bottomGap: 1, height: 40), system(110, 210)],
            sp: sp,
        )
        #expect(result.frameOriginY == [120])
        // The next system starts at 120 + 40 + 20 = 180; it was at 110.
        #expect(result.systemShift == [0, 70])
    }

    @Test("between two frames the larger of the two gaps wins when both are non-negative")
    func frameToFrameTakesTheLargerGap() {
        let result = FrameStreamPlacer.place(
            title: nil,
            items: [system(0, 100), frame(bottomGap: 5, height: 30), frame(topGap: 4, height: 20)],
            sp: sp,
        )
        // First frame: 100 + 70 = 170. Second: 170 + 30 + max(5, 4) * 10 = 250.
        #expect(result.frameOriginY == [170, 250])
        #expect(result.contentBottom == 270)
    }

    @Test("between two frames a negative gap makes the distance the sum")
    func frameToFrameWithANegativeGapSums() {
        let result = FrameStreamPlacer.place(
            title: nil,
            items: [system(0, 100), frame(bottomGap: -2, height: 30), frame(topGap: 4, height: 20)],
            sp: sp,
        )
        // Second: 170 + 30 + (-2 + 4) * 10 = 220.
        #expect(result.frameOriginY == [170, 220])
    }

    @Test("a frame right after the title sits 7 sp below it when the title names no gap")
    func titleThenFrame() {
        let result = FrameStreamPlacer.place(
            title: (bottom: 50, bottomGap: nil),
            items: [frame(topGap: 3, height: 40), system(60, 160)],
            sp: sp,
        )
        #expect(result.frameOriginY == [120])
        // The system follows at 120 + 40 + 70 = 230; it was at 60.
        #expect(result.systemShift == [170])
    }

    @Test("a frame after the last system extends the content by its distance and height")
    func trailingFrameExtendsTheContent() {
        let result = FrameStreamPlacer.place(
            title: nil, items: [system(0, 100), frame(height: 40)], sp: sp,
        )
        #expect(result.frameOriginY == [170])
        #expect(result.contentBottom == 210)
    }

    @Test("without frames nothing moves and the content ends at the last system")
    func noFramesLeavesTheStreamAlone() {
        let result = FrameStreamPlacer.place(
            title: (bottom: 50, bottomGap: nil), items: [system(60, 100), system(110, 210)], sp: sp,
        )
        #expect(result.systemShift == [0, 0])
        #expect(result.frameOriginY == [])
        #expect(result.contentBottom == 210)
    }
}
