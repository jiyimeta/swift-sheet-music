import Foundation
@testable import SheetMusicLayout
import Testing

#if !canImport(CoreGraphics)
    /// On Android and WebAssembly, Foundation's CoreGraphics shims also export `CGFloat`,
    /// `CGRect` (see `Sources/SheetMusicLayout/Fonts/CGTypes+Android.swift`), so anchor
    /// explicitly to SheetMusicLayout's own definitions instead of leaving it ambiguous.
    ///
    /// `private typealias` keeps these file-scoped — a module-scope `typealias CGFloat` here
    /// would collide with the same pattern in every other file in this target that needs it.
    private typealias CGFloat = SheetMusicLayout.CGFloat
    private typealias CGRect = SheetMusicLayout.CGRect
#endif

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

    /// The column-indexed query autoplace uses agrees, value for value, with what it replaced: a filtered copy and
    /// `minVerticalDistance` over every rect. Seeded so a failure reproduces; rects range from narrower than a
    /// column to wider than many, at both edges of the staff, with clearances up to two columns.
    @Test func indexedOverlapMatchesExhaustive() {
        var rng = SplitMix64(seed: 0x5EEDF5)
        func next(_ range: ClosedRange<CGFloat>) -> CGFloat {
            range.lowerBound + CGFloat(rng.next() % 1_000_000) / 1_000_000 * (range.upperBound - range.lowerBound)
        }
        func randomRect() -> CGRect {
            let width = rng.next() % 5 == 0 ? next(100 ... 3000) : next(0 ... 40)
            return CGRect(x: next(-200 ... 20000), y: next(40 ... 200), width: width, height: next(1 ... 30))
        }
        let kinds: [ShapeItemKind] = [.chord, .dynamics, .lyrics, .tempo, .staffText, .hairpin, .harmony]
        for round in 0 ..< 40 {
            var sky = makeSkyline()
            sky.add(rect(CGRect(x: 0, y: staffTop, width: 20000, height: staffBottom - staffTop), .staff, -1))
            for id in 0 ..< 300 {
                sky.add(rect(randomRect(), kinds[Int(rng.next() % UInt64(kinds.count))], id))
            }
            for query in 0 ..< 30 {
                let shape = LayoutShape(rects: (0 ..< 1 + Int(rng.next() % 3)).map { _ in
                    ShapeRect(rect: randomRect(), item: ShapeItem(kind: kinds[query % kinds.count], id: 1000 + query))
                })
                let clearance = next(0 ... 64)
                let ignoring: (ShapeItem) -> Bool = { $0.id % 7 == round % 7 }
                let copy = sky.filtered(ignoring: ignoring)
                #expect(
                    sky.overlapAbove(shape, clearance: clearance, ignoring: ignoring)
                        == shape.minVerticalDistance(copy.north, minHorizontalClearance: clearance),
                )
                #expect(
                    sky.overlapBelow(shape, clearance: clearance, ignoring: ignoring)
                        == copy.south.minVerticalDistance(shape, minHorizontalClearance: clearance),
                )
            }
        }
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

/// Fixed-seed generator so a failure is always reproducible — `FormatGTests`' own, which is file-private there.
private struct SplitMix64 {
    private var state: UInt64

    init(seed: UInt64) {
        state = seed
    }

    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }
}
