#if SHEET_MUSIC_HAS_APPLE_PLATFORM_TEST_SUPPORT
    import CoreGraphics
    @testable import SheetMusicLayout
    import Testing

    struct AccidentalPlacementTests {
        /// sp = 10 pt in all tests so arithmetic is easy to follow.
        private let sp: CGFloat = 10

        @Test func gapApplied() {
            // For a 20 pt wide accidental group, the right edge should
            // sit `gapSp * sp` = 0.16 * 10 = 1.6 pt left of noteheadLeftX.
            let noteheadLeftX: CGFloat = 100
            let advanceWidth: CGFloat = 20
            let leftEdge = AccidentalPlacement.leftEdgeX(
                noteheadLeftX: noteheadLeftX,
                advanceWidth: advanceWidth,
                sp: sp,
            )
            // rightEdge = leftEdge + advance
            let rightEdge = leftEdge + advanceWidth
            #expect(rightEdge == noteheadLeftX - AccidentalPlacement.gapSp * sp)
        }

        @Test func leftEdgeFormula() {
            let noteheadLeftX: CGFloat = 50
            let advanceWidth: CGFloat = 12
            let expected = noteheadLeftX - AccidentalPlacement.gapSp * sp - advanceWidth
            #expect(
                AccidentalPlacement.leftEdgeX(
                    noteheadLeftX: noteheadLeftX,
                    advanceWidth: advanceWidth,
                    sp: sp,
                ) == expected,
            )
        }

        @Test func zeroAdvanceEdgeCaseGapOnly() {
            // A zero-width group (degenerate) still positions the right edge
            // exactly `gapSp * sp` left of the notehead.
            let noteheadLeftX: CGFloat = 30
            let leftEdge = AccidentalPlacement.leftEdgeX(
                noteheadLeftX: noteheadLeftX,
                advanceWidth: 0,
                sp: sp,
            )
            #expect(leftEdge == noteheadLeftX - AccidentalPlacement.gapSp * sp)
        }

        @Test func gapConstant() {
            // The published gap value is 0.16 sp; verify it hasn't drifted.
            #expect(AccidentalPlacement.gapSp == 0.16)
        }

        @Test func scaledSp() {
            // Scaling sp by 2 doubles all distances proportionally.
            let spBase: CGFloat = 10
            let spScaled: CGFloat = 20
            let noteheadLeftX: CGFloat = 100
            let advance: CGFloat = 15

            let base = AccidentalPlacement.leftEdgeX(
                noteheadLeftX: noteheadLeftX,
                advanceWidth: advance,
                sp: spBase,
            )
            // At double sp, the gap doubles.
            let gap = AccidentalPlacement.gapSp * spScaled
            let expected = noteheadLeftX - gap - advance
            let actual = AccidentalPlacement.leftEdgeX(
                noteheadLeftX: noteheadLeftX,
                advanceWidth: advance,
                sp: spScaled,
            )
            #expect(actual == expected)
            // Sanity: scaled gap is larger than base gap.
            #expect(actual < base)
        }
    }
#endif
