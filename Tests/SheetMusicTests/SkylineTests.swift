#if !os(Android)
    import CoreGraphics
    @testable import SheetMusicLayout
    import Testing

    @Suite("Skyline")
    struct SkylineTests {
        // Staff occupies y ∈ [100, 140] in these fixtures.
        private let staffTop: CGFloat = 100
        private let staffBottom: CGFloat = 140

        private func rect(
            _ r: CGRect, _ kind: ShapeItemKind, _ id: Int = 0,
        ) -> LayoutShape {
            LayoutShape(rects: [ShapeRect(
                rect: r, item: ShapeItem(kind: kind, id: id),
            )])
        }

        private func makeSkyline() -> Skyline {
            Skyline(staffTop: staffTop, staffBottom: staffBottom)
        }

        /// A rect entirely inside the staff pokes out neither side, so
        /// it lands in neither line.
        @Test func rectInsideStaffIsDropped() {
            var sky = makeSkyline()
            sky.add(rect(
                CGRect(x: 0, y: 110, width: 10, height: 10), .chord,
            ))
            #expect(sky.north.isEmpty)
            #expect(sky.south.isEmpty)
        }

        /// A rect poking above the top staff line lands in NORTH only.
        @Test func rectAboveStaffLandsInNorth() {
            var sky = makeSkyline()
            sky.add(rect(
                CGRect(x: 0, y: 90, width: 10, height: 20), .chord,
            ))
            #expect(sky.north.rects.count == 1)
            #expect(sky.south.isEmpty)
        }

        /// A rect poking below the bottom staff line lands in SOUTH only.
        @Test func rectBelowStaffLandsInSouth() {
            var sky = makeSkyline()
            sky.add(rect(
                CGRect(x: 0, y: 130, width: 10, height: 20), .chord,
            ))
            #expect(sky.south.rects.count == 1)
            #expect(sky.north.isEmpty)
        }

        /// A rect spanning the whole staff lands in BOTH lines.
        @Test func rectSpanningStaffLandsInBoth() {
            var sky = makeSkyline()
            sky.add(rect(
                CGRect(x: 0, y: 80, width: 10, height: 80), .chord,
            ))
            #expect(sky.north.rects.count == 1)
            #expect(sky.south.rects.count == 1)
        }

        /// The staff rect itself is exempt from the filter — it defines
        /// the edges, so it must stay visible to both lines.
        @Test func staffRectAlwaysKept() {
            var sky = makeSkyline()
            sky.add(rect(
                CGRect(x: 0, y: 100, width: 500, height: 40), .staff,
            ))
            #expect(sky.north.rects.count == 1)
            #expect(sky.south.rects.count == 1)
        }

        @Test func filteredDropsMatchingItems() {
            var sky = makeSkyline()
            sky.add(rect(
                CGRect(x: 0, y: 80, width: 10, height: 10), .chord, 1,
            ))
            sky.add(rect(
                CGRect(x: 0, y: 80, width: 10, height: 10), .dynamics, 2,
            ))
            let filtered = sky.filtered { $0.kind == .dynamics }
            #expect(filtered.north.rects.count == 1)
            #expect(filtered.north.rects[0].item.kind == .chord)
            // The original is untouched.
            #expect(sky.north.rects.count == 2)
        }

        /// A shape above the staff overlapping the north skyline by 4.
        @Test func overlapAboveMeasuresIntoNorth() {
            var sky = makeSkyline()
            sky.add(rect(
                CGRect(x: 0, y: 80, width: 10, height: 30), .chord,
            ))
            let item = rect(
                CGRect(x: 0, y: 70, width: 10, height: 14), .tempo,
            )
            #expect(sky.overlapAbove(item, clearance: 0) == 4)
        }

        /// A shape below the staff overlapping the south skyline by 4.
        @Test func overlapBelowMeasuresIntoSouth() {
            var sky = makeSkyline()
            sky.add(rect(
                CGRect(x: 0, y: 130, width: 10, height: 30), .chord,
            ))
            let item = rect(
                CGRect(x: 0, y: 156, width: 10, height: 10), .lyrics,
            )
            #expect(sky.overlapBelow(item, clearance: 0) == 4)
        }

        @Test func overlapAgainstEmptyLineIsNegativeInfinity() {
            let sky = makeSkyline()
            let item = rect(
                CGRect(x: 0, y: 70, width: 10, height: 10), .tempo,
            )
            #expect(sky.overlapAbove(item, clearance: 0) == -.infinity)
            #expect(sky.overlapBelow(item, clearance: 0) == -.infinity)
        }
    }
#endif
