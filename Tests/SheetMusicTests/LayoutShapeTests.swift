#if !os(Android)
    import CoreGraphics
    @testable import SheetMusicLayout
    import Testing

    @Suite("LayoutShape.minVerticalDistance")
    struct LayoutShapeTests {
        private func shape(
            _ rect: CGRect, kind: ShapeItemKind = .staffText, id: Int = 0,
        ) -> LayoutShape {
            LayoutShape(rects: [ShapeRect(
                rect: rect, item: ShapeItem(kind: kind, id: id),
            )])
        }

        /// Above shape's bottom is 10 below the lower shape's top, so
        /// they overlap vertically by 10.
        @Test func overlappingReturnsPositiveOverlap() {
            let above = shape(CGRect(x: 0, y: 0, width: 20, height: 30))
            let below = shape(CGRect(x: 0, y: 20, width: 20, height: 30))
            #expect(above.minVerticalDistance(
                below, minHorizontalClearance: 0,
            ) == 10)
        }

        /// A 5 pt gap between them reports −5.
        @Test func clearedReturnsNegativeClearance() {
            let above = shape(CGRect(x: 0, y: 0, width: 20, height: 10))
            let below = shape(CGRect(x: 0, y: 15, width: 20, height: 10))
            #expect(above.minVerticalDistance(
                below, minHorizontalClearance: 0,
            ) == -5)
        }

        /// Edge-to-edge touching is exactly 0.
        @Test func touchingReturnsZero() {
            let above = shape(CGRect(x: 0, y: 0, width: 20, height: 10))
            let below = shape(CGRect(x: 0, y: 10, width: 20, height: 10))
            #expect(above.minVerticalDistance(
                below, minHorizontalClearance: 0,
            ) == 0)
        }

        /// No horizontal overlap at all → −infinity (no interaction).
        @Test func horizontallyDisjointReturnsNegativeInfinity() {
            let above = shape(CGRect(x: 0, y: 0, width: 10, height: 10))
            let below = shape(CGRect(x: 50, y: 5, width: 10, height: 10))
            #expect(above.minVerticalDistance(
                below, minHorizontalClearance: 0,
            ) == -.infinity)
        }

        /// A 6 pt horizontal gap is bridged by a 7 pt clearance.
        @Test func horizontalClearanceWidensTheOverlapTest() {
            let above = shape(CGRect(x: 0, y: 0, width: 10, height: 20))
            let below = shape(CGRect(x: 16, y: 10, width: 10, height: 20))
            #expect(above.minVerticalDistance(
                below, minHorizontalClearance: 0,
            ) == -.infinity)
            #expect(above.minVerticalDistance(
                below, minHorizontalClearance: 7,
            ) == 10)
        }

        /// The maximum over all overlapping pairs wins.
        @Test func takesMaximumOverPairs() {
            let above = LayoutShape(rects: [
                ShapeRect(
                    rect: CGRect(x: 0, y: 0, width: 10, height: 5),
                    item: ShapeItem(kind: .staffText, id: 0),
                ),
                ShapeRect(
                    rect: CGRect(x: 0, y: 0, width: 10, height: 40),
                    item: ShapeItem(kind: .staffText, id: 1),
                ),
            ])
            let below = shape(CGRect(x: 0, y: 20, width: 10, height: 10))
            #expect(above.minVerticalDistance(
                below, minHorizontalClearance: 0,
            ) == 20)
        }

        @Test func emptyShapeReturnsNegativeInfinity() {
            let above = LayoutShape()
            let below = shape(CGRect(x: 0, y: 0, width: 10, height: 10))
            #expect(above.minVerticalDistance(
                below, minHorizontalClearance: 0,
            ) == -.infinity)
        }

        @Test func translatedYMovesEveryRect() {
            let s = shape(CGRect(x: 1, y: 2, width: 3, height: 4))
            let moved = s.translatedY(10)
            #expect(moved.rects[0].rect.minY == 12)
            #expect(moved.rects[0].rect.minX == 1)
        }

        @Test func bboxUnionsEveryRect() throws {
            let s = LayoutShape(rects: [
                ShapeRect(
                    rect: CGRect(x: 0, y: 0, width: 10, height: 10),
                    item: ShapeItem(kind: .chord, id: 0),
                ),
                ShapeRect(
                    rect: CGRect(x: 20, y: -5, width: 10, height: 10),
                    item: ShapeItem(kind: .chord, id: 1),
                ),
            ])
            let box = try #require(s.bbox)
            #expect(box.minX == 0)
            #expect(box.maxX == 30)
            #expect(box.minY == -5)
            #expect(box.maxY == 10)
            #expect(LayoutShape().bbox == nil)
        }

        @Test func textKindsAreFlagged() {
            #expect(ShapeItemKind.lyrics.isText)
            #expect(ShapeItemKind.rehearsalMark.isText)
            #expect(!ShapeItemKind.chord.isText)
            #expect(!ShapeItemKind.hairpin.isText)
        }
    }
#endif
