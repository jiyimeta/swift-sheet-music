#if canImport(CoreGraphics)
    import CoreGraphics
#endif
@testable import SheetMusicCore
@testable import SheetMusicLayout
import Testing

#if !canImport(CoreGraphics)
    /// See `TitleBlockAlignTests`: anchor to SheetMusicLayout's own `CGFloat` off Apple.
    private typealias CGFloat = SheetMusicLayout.CGFloat
#endif

/// An `<HBox>` between two measures is horizontal room inside the system: `(widthSp ?? 5) + (topGapSp ?? 0) +
/// (bottomGapSp ?? 0)` spatium before the measure it sits before (MS `box.cpp:71-74`), summed over consecutive boxes,
/// never stretched, and dropped where that measure opens a system. Measure widths depend on font metrics, so they are
/// compared between documents laid out from the same score; the room itself is an exact multiple of `metrics.sp`.
@Suite("HBox room between measures") struct HorizontalFrameLayoutTests {
    private let _installFontMetrics = TestSupport.installFontMetrics

    // MARK: - Fixtures

    /// An HBox before measure `index`, `widthSp` wide, with its left and right gaps (`topGapSp` / `bottomGapSp`).
    private static func hbox(
        _ widthSp: CGFloat, before index: Int, leftGapSp: CGFloat? = nil, rightGapSp: CGFloat? = nil,
    ) -> PositionedScoreBlock {
        let frame = HorizontalFrame(widthSp: widthSp, topGapSp: leftGapSp, bottomGapSp: rightGapSp)
        return PositionedScoreBlock(beforeMeasureIndex: index, block: .horizontalFrame(frame))
    }

    /// Four bars of one whole note on one treble staff, no title, with `blocks` among them; `lineBreakAfter` names the
    /// bar that ends the first system. With `pedals`, one pedal line runs from bar 1 and another from bar 2, both to
    /// the end of bar 2 (`<measures>N</measures>` ends at the right edge of bar `start + N - 1`).
    private static func score(
        blocks: [PositionedScoreBlock] = [], lineBreakAfter: Int? = nil, pedals: Bool = false,
    ) -> Score {
        let note = VoiceElement.chord(Chord(duration: .whole, notes: [Note(pitch: 60, tpc: 14)]))
        let measures = (0 ..< 4).map { index -> Measure in
            let pedal = Spanner(kind: .pedal, rawType: "Pedal", nextMeasuresOffset: 3 - index)
            let elements: [VoiceElement] = pedals && (1 ... 2).contains(index) ? [.spanner(pedal), note] : [note]
            return Measure(voices: [Voice(elements: elements)], lineBreak: index == lineBreakAfter)
        }
        return Score(
            division: 480,
            parts: [Part(id: "1", instrument: Instrument(id: "x"), staves: [Staff(measures: measures)])],
            blocks: blocks,
        )
    }

    /// Blocks that put no HBox between two measures: a fret-diagram box between two measures, an HBox before the first
    /// measure and an HBox after the last.
    private static let inertBlocks: [[PositionedScoreBlock]] = [
        [PositionedScoreBlock(beforeMeasureIndex: 2, block: .opaqueFrame(OpaqueFrame(kind: .fret)))],
        [hbox(6, before: 0)],
        [hbox(6, before: 4)],
    ]

    /// `score` laid out wrapped at `width` — wide enough that its four bars are one system unless a bar breaks it.
    private func laidOut(_ score: Score, width: CGFloat = 2000, cache: LayoutCache? = nil) -> LayoutDocument {
        LayoutEngine.layout(score: score, options: ScoreViewOptions(), availableWidth: width, cache: cache)
    }

    /// The measure with `index` in `document`.
    private func measure(_ index: Int, in document: LayoutDocument) throws -> LayoutMeasure {
        let match = document.systems.flatMap(\.measures).first { $0.measureIndex == index }
        return try #require(match, "no measure \(index)")
    }

    /// How far right of measure 1 measure 2 starts in `document`.
    private func step(in document: LayoutDocument) throws -> CGFloat {
        let before = try measure(1, in: document)
        let after = try measure(2, in: document)
        return after.origin.x - before.origin.x
    }

    /// The pedal lines `document` draws, as `(from, to)` x pairs in the order the systems emit them.
    private func pedals(in document: LayoutDocument) -> [(from: CGFloat, to: CGFloat)] {
        document.systems.flatMap(\.spanners).compactMap { element -> (from: CGFloat, to: CGFloat)? in
            guard case let .spannerSegment(.pedal, from, to, _, _, _, _, _, _) = element else { return nil }
            return (from: from.x, to: to.x)
        }
    }

    private func closeEnough(_ lhs: CGFloat, _ rhs: CGFloat) -> Bool {
        abs(lhs - rhs) < 0.001
    }

    // MARK: - Tests

    /// The width equalities pin the mechanics: the gap sits in measure 2's slot and is taken out again before the
    /// measure is laid out, so neither measure around it is wider than without the box.
    @Test("an HBox between two measures moves the measure after it right by its width, and no measure grows")
    func gapShiftsLaterMeasures() throws {
        let bare = laidOut(Self.score())
        let boxed = laidOut(Self.score(blocks: [Self.hbox(6, before: 2)]))
        try #require(bare.systems.count == 1)
        try #require(boxed.systems.count == 1)
        let extra = try step(in: boxed) - step(in: bare)
        #expect(closeEnough(extra, 6 * boxed.metrics.sp))
        let boxedBefore = try measure(1, in: boxed)
        let bareBefore = try measure(1, in: bare)
        #expect(closeEnough(boxedBefore.width, bareBefore.width))
        let boxedAfter = try measure(2, in: boxed)
        let bareAfter = try measure(2, in: bare)
        #expect(closeEnough(boxedAfter.width, bareAfter.width))
    }

    @Test("a wider page stretches the measures but not the room an HBox leaves")
    func gapIsNotStretched() throws {
        let blocks = [Self.hbox(6, before: 2)]
        let narrow = laidOut(Self.score(blocks: blocks))
        let wide = laidOut(Self.score(blocks: blocks), width: 2200)
        try #require(narrow.systems.count == 1)
        try #require(wide.systems.count == 1)
        let sp = wide.metrics.sp
        let narrowExtra = try step(in: narrow) - step(in: laidOut(Self.score()))
        let wideExtra = try step(in: wide) - step(in: laidOut(Self.score(), width: 2200))
        let narrowWidth = try measure(1, in: narrow).width
        let wideWidth = try measure(1, in: wide).width
        #expect(wideWidth > narrowWidth)
        #expect(closeEnough(narrowExtra, 6 * sp))
        #expect(closeEnough(wideExtra, 6 * sp))
    }

    @Test("an HBox before the measure that opens a system takes no room")
    func gapAtSystemStartIsDropped() throws {
        let bare = laidOut(Self.score(lineBreakAfter: 1))
        let boxed = laidOut(Self.score(blocks: [Self.hbox(6, before: 2)], lineBreakAfter: 1))
        try #require(bare.systems.count == 2)
        #expect(bare.systems[1].measures.first?.measureIndex == 2)
        #expect(boxed.systems == bare.systems)
    }

    /// The second box is 3 sp as 2 sp of width plus two 0.5 sp gaps, so its left and right gaps count too.
    @Test("two HBoxes before the same measure leave as much room as one box as wide as both")
    func consecutiveBoxesAdd() throws {
        let pair = laidOut(Self.score(blocks: [
            Self.hbox(3, before: 2), Self.hbox(2, before: 2, leftGapSp: 0.5, rightGapSp: 0.5),
        ]))
        let single = laidOut(Self.score(blocks: [Self.hbox(6, before: 2)]))
        let bare = laidOut(Self.score())
        try #require(pair.systems.count == 1)
        let extra = try step(in: pair) - step(in: bare)
        #expect(closeEnough(extra, 6 * pair.metrics.sp))
        #expect(pair.systems == single.systems)
    }

    @Test("a score with no HBox between two measures lays out as if it had no boxes", arguments: inertBlocks)
    func noHBoxIsUnchanged(_ blocks: [PositionedScoreBlock]) {
        #expect(laidOut(Self.score(blocks: blocks)) == laidOut(Self.score()))
    }

    /// An HBox lives in `score.blocks`, not in any staff's measures, so the system cache can only see it through the
    /// widths it keys on.
    @Test("widening an HBox through a warm cache rebuilds its system and moves the measure after it")
    func hboxEditInvalidatesTheCachedSystem() throws {
        let cache = LayoutCache()
        let first = laidOut(Self.score(blocks: [Self.hbox(6, before: 2)]), cache: cache)
        let edited = Self.score(blocks: [Self.hbox(10, before: 2)])
        let second = laidOut(edited, cache: cache)
        try #require(first.systems.count == 1)
        try #require(second.systems.count == 1)
        #expect(cache.systemMisses == 1)
        let moved = try measure(2, in: second).origin.x - measure(2, in: first).origin.x
        #expect(closeEnough(moved, 4 * second.metrics.sp))
        #expect(second.systems == laidOut(edited).systems)
    }

    /// `buildSystem`'s pass 1 (`xOffsets`), `extractLineSpanners` and pass 2 each walk the measures' x on their own.
    /// A line that starts before the box and ends after it pins pass 1 to pass 2; one that starts after it pins the
    /// extraction's walk.
    @Test("a line spanner keeps both ends on its measures when an HBox sits before or under it")
    func lineSpannersFollowTheGap() throws {
        let bare = pedals(in: laidOut(Self.score(pedals: true)))
        let boxedDocument = laidOut(Self.score(blocks: [Self.hbox(6, before: 2)], pedals: true))
        let boxed = pedals(in: boxedDocument)
        try #require(bare.count == 2)
        try #require(boxed.count == 2)
        let room = 6 * boxedDocument.metrics.sp
        #expect(closeEnough(boxed[0].from, bare[0].from))
        #expect(closeEnough(boxed[0].to - bare[0].to, room))
        #expect(closeEnough(boxed[1].from - bare[1].from, room))
        #expect(closeEnough(boxed[1].to - bare[1].to, room))
    }
}
