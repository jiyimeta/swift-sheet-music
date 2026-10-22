#if canImport(CoreGraphics)
    import CoreGraphics
#endif
import Foundation
@testable import SheetMusicCore
@testable import SheetMusicLayout
import Testing

#if !canImport(CoreGraphics)
    /// See `TitleBlockAlignTests`: anchor to SheetMusicLayout's own `CGFloat` off Apple.
    private typealias CGFloat = SheetMusicLayout.CGFloat
#endif

// The model's `CGFloat`, which off Apple is not SheetMusicLayout's: Foundation's on Windows and Linux, SheetMusicCore's
// own on WASI (`CGCompat+WASI`).
#if os(WASI)
    private typealias ModelCGFloat = SheetMusicCore.CGFloat
#else
    private typealias ModelCGFloat = Foundation.CGFloat
#endif

/// An `<HBox>` between two measures is horizontal room inside the system: `(widthSp ?? 5) + (topGapSp ?? 0) +
/// (bottomGapSp ?? 0)` spatium before the measure it sits before (MS `box.cpp:71-74`), summed over consecutive boxes,
/// never stretched, and dropped where that measure opens a system. A justified (wrapped) system gives its measures the
/// available width minus the room, so there the measures' widths are compared as a sum; a horizontal system is not
/// justified and keeps every measure's width. The room itself is an exact multiple of `metrics.sp`.
@Suite("HBox room between measures") struct HorizontalFrameLayoutTests {
    private let _installFontMetrics = TestSupport.installFontMetrics

    // MARK: - Fixtures

    /// An HBox before measure `index`, `widthSp` wide (`nil` = MuseScore's default), with its left and right gaps
    /// (`topGapSp` / `bottomGapSp`).
    private static func hbox(
        _ widthSp: ModelCGFloat?, before index: Int, leftGapSp: ModelCGFloat? = nil, rightGapSp: ModelCGFloat? = nil,
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

    /// A whole note, four whole-measure rests and a whole note on one treble staff, so collapsing multi-measure rests
    /// gives the one run `1 ..< 5`.
    private static func restRunScore(blocks: [PositionedScoreBlock]) -> Score {
        let sounding = Measure(voices: [Voice(elements: [
            .chord(Chord(duration: .whole, notes: [Note(pitch: 60, tpc: 14)])),
        ])])
        let rest = Measure(voices: [Voice(elements: [.rest(duration: .measure)])])
        return Score(
            division: 480,
            parts: [Part(id: "1", instrument: Instrument(id: "x"), staves: [
                Staff(measures: [sounding, rest, rest, rest, rest, sounding]),
            ])],
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

    /// No blocks at all, then `inertBlocks`: every score that leaves no room between two measures.
    private static let roomlessBlocks: [[PositionedScoreBlock]] = [[]] + inertBlocks

    /// `score` laid out at `width` — wrapped unless `options` says otherwise, wide enough that four bars are one
    /// system unless a bar breaks it, and narrow enough that they fill the line past `lastSystemFillLimit`, so the
    /// line is justified rather than left at its natural width (`LayoutEngine.shouldJustify`).
    private func laidOut(
        _ score: Score, width: CGFloat = 1000, cache: LayoutCache? = nil,
        options: ScoreViewOptions = ScoreViewOptions(),
    ) -> LayoutDocument {
        LayoutEngine.layout(score: score, options: options, availableWidth: width, cache: cache)
    }

    /// The measure with `index` in `document`.
    private func measure(_ index: Int, in document: LayoutDocument) throws -> LayoutMeasure {
        let match = document.systems.flatMap(\.measures).first { $0.measureIndex == index }
        return try #require(match, "no measure \(index)")
    }

    /// The room between the end of the measure before `index` and the start of measure `index`, in `document`.
    private func roomBefore(_ index: Int, in document: LayoutDocument) throws -> CGFloat {
        let before = try measure(index - 1, in: document)
        let after = try measure(index, in: document)
        return after.origin.x - (before.origin.x + before.width)
    }

    /// The sum of every measure's width in `document`.
    private func measureWidths(in document: LayoutDocument) -> CGFloat {
        document.systems.flatMap(\.measures).reduce(0) { $0 + $1.width }
    }

    /// The pedal lines `document` draws, as `(from, to)` x pairs in the order the systems emit them.
    private func pedals(in document: LayoutDocument) -> [(from: CGFloat, to: CGFloat)] {
        document.systems.flatMap(\.spanners).compactMap { element -> (from: CGFloat, to: CGFloat)? in
            guard case let .spannerSegment(.pedal, from, to, _, _, _, _, _, _) = element else { return nil }
            return (from: from.x, to: to.x)
        }
    }

    /// The narrowest whole-point width at which `score` still lays out (wrapped) as one system under `options`, by
    /// bisection between 100 pt, where it wraps, and 2000 pt, where it does not.
    private func narrowestOneSystemWidth(
        _ score: Score, options: ScoreViewOptions = ScoreViewOptions(),
    ) throws -> CGFloat {
        var fits = 2000
        var wraps = 100
        try #require(laidOut(score, width: CGFloat(fits), options: options).systems.count == 1)
        try #require(laidOut(score, width: CGFloat(wraps), options: options).systems.count > 1)
        while fits - wraps > 1 {
            let middle = (fits + wraps) / 2
            if laidOut(score, width: CGFloat(middle), options: options).systems.count == 1 {
                fits = middle
            } else {
                wraps = middle
            }
        }
        return CGFloat(fits)
    }

    private func closeEnough(_ lhs: CGFloat, _ rhs: CGFloat) -> Bool {
        abs(lhs - rhs) < 0.001
    }

    // MARK: - Tests

    /// A wrapped system is justified, so the measures share the available width minus the room (MuseScore's
    /// `justifySystem`): their widths sum to the bare system's less the room, and the system ends where the bare one
    /// does.
    @Test("an HBox between two measures leaves its width as room and the system still ends at the page width")
    func gapShiftsLaterMeasures() throws {
        let bare = laidOut(Self.score())
        let boxed = laidOut(Self.score(blocks: [Self.hbox(6, before: 2)]))
        try #require(bare.systems.count == 1)
        try #require(boxed.systems.count == 1)
        let sp = boxed.metrics.sp
        let room = try roomBefore(2, in: boxed)
        #expect(closeEnough(room, 6 * sp))
        #expect(closeEnough(measureWidths(in: boxed) + 6 * sp, measureWidths(in: bare)))
        #expect(closeEnough(boxed.systems[0].size.width, bare.systems[0].size.width))
    }

    @Test("a wider page stretches the measures but not the room an HBox leaves")
    func gapIsNotStretched() throws {
        let blocks = [Self.hbox(6, before: 2)]
        let narrow = laidOut(Self.score(blocks: blocks))
        let wide = laidOut(Self.score(blocks: blocks), width: 1200)
        try #require(narrow.systems.count == 1)
        try #require(wide.systems.count == 1)
        let sp = wide.metrics.sp
        let narrowRoom = try roomBefore(2, in: narrow)
        let wideRoom = try roomBefore(2, in: wide)
        let narrowWidth = try measure(1, in: narrow).width
        let wideWidth = try measure(1, in: wide).width
        #expect(wideWidth > narrowWidth)
        #expect(closeEnough(narrowRoom, 6 * sp))
        #expect(closeEnough(wideRoom, 6 * sp))
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
        try #require(pair.systems.count == 1)
        let room = try roomBefore(2, in: pair)
        #expect(closeEnough(room, 6 * pair.metrics.sp))
        #expect(pair.systems == single.systems)
    }

    @Test("a score with no HBox between two measures lays out as if it had no boxes", arguments: inertBlocks)
    func noHBoxIsUnchanged(_ blocks: [PositionedScoreBlock]) {
        #expect(laidOut(Self.score(blocks: blocks)) == laidOut(Self.score()))
    }

    /// An HBox lives in `score.blocks`, not in any staff's measures, so the system cache can only see it through the
    /// widths it keys on — the slots, room included. In horizontal mode no stretch target moves with the room, so only
    /// the slots can tell the two layouts apart.
    @Test("widening an HBox through a warm cache rebuilds its system with the new room", arguments: [true, false])
    func hboxEditInvalidatesTheCachedSystem(wraps: Bool) throws {
        let options = ScoreViewOptions(wrapToViewWidth: wraps)
        let cache = LayoutCache()
        let first = laidOut(Self.score(blocks: [Self.hbox(6, before: 2)]), cache: cache, options: options)
        let edited = Self.score(blocks: [Self.hbox(10, before: 2)])
        let second = laidOut(edited, cache: cache, options: options)
        try #require(first.systems.count == 1)
        try #require(second.systems.count == 1)
        #expect(cache.systemMisses == 1)
        let sp = second.metrics.sp
        let firstRoom = try roomBefore(2, in: first)
        let secondRoom = try roomBefore(2, in: second)
        #expect(closeEnough(firstRoom, 6 * sp))
        #expect(closeEnough(secondRoom, 10 * sp))
        #expect(second.systems == laidOut(edited, options: options).systems)
    }

    /// `buildSystem`'s pass 1 (`xOffsets`), `extractLineSpanners` and pass 2 each walk the measures' x on their own.
    /// A line that starts before the box and ends after it pins pass 1 to pass 2; one that starts after it pins the
    /// extraction's walk. In horizontal mode no justification moves the measures, so the ends move by exactly the room.
    @Test("a line spanner keeps both ends on its measures when an HBox sits before or under it")
    func lineSpannersFollowTheGap() throws {
        let options = ScoreViewOptions(wrapToViewWidth: false)
        let bare = pedals(in: laidOut(Self.score(pedals: true), options: options))
        let boxedDocument = laidOut(Self.score(blocks: [Self.hbox(6, before: 2)], pedals: true), options: options)
        let boxed = pedals(in: boxedDocument)
        try #require(bare.count == 2)
        try #require(boxed.count == 2)
        let sixSp = 6 * boxedDocument.metrics.sp
        #expect(closeEnough(boxed[0].from, bare[0].from))
        #expect(closeEnough(boxed[0].to - bare[0].to, sixSp))
        #expect(closeEnough(boxed[1].from - bare[1].from, sixSp))
        #expect(closeEnough(boxed[1].to - bare[1].to, sixSp))
    }

    @Test("horizontal mode leaves the room too, and every measure keeps its width")
    func horizontalModeKeepsTheGap() throws {
        let options = ScoreViewOptions(wrapToViewWidth: false)
        let bare = laidOut(Self.score(), options: options)
        let boxed = laidOut(Self.score(blocks: [Self.hbox(6, before: 2)]), options: options)
        try #require(bare.systems.count == 1)
        try #require(boxed.systems.count == 1)
        let sp = boxed.metrics.sp
        let room = try roomBefore(2, in: boxed)
        #expect(closeEnough(room, 6 * sp))
        let bareWidths = bare.systems[0].measures.map(\.width)
        let boxedWidths = boxed.systems[0].measures.map(\.width)
        try #require(boxedWidths.count == bareWidths.count)
        let changed = boxedWidths.indices.filter { !closeEnough(boxedWidths[$0], bareWidths[$0]) }
        #expect(changed.isEmpty)
        #expect(closeEnough(boxed.systems[0].size.width - bare.systems[0].size.width, 6 * sp))
    }

    @Test("an HBox without a width is 5 sp wide")
    func defaultWidthIsFiveSp() throws {
        let document = laidOut(Self.score(blocks: [Self.hbox(nil, before: 2)]))
        try #require(document.systems.count == 1)
        let room = try roomBefore(2, in: document)
        #expect(closeEnough(room, 5 * document.metrics.sp))
    }

    /// At the narrowest width that still holds the four bars on one line, a 6 sp box between them no longer fits. At
    /// the default stretch the natural-stretch test closes the line first. At a stretch of 1 that test and the hard
    /// ceiling are one test, and a 2 sp box is enough to push bar 3 to the next line: the line is filled greedily, as
    /// MuseScore fills it, so the first takes the three bars that still fit. That needs the box wider than the
    /// bisection's 1 pt slack and narrower than bar 3, which the `#require` checks.
    @Test("an HBox's room counts when the line is filled, so it can push a measure onto the next system")
    func gapCanMoveTheWrap() throws {
        let width = try narrowestOneSystemWidth(Self.score())
        let document = laidOut(Self.score(blocks: [Self.hbox(6, before: 2)]), width: width)
        #expect(document.systems.count == 2)
        #expect(document.systems.flatMap(\.measures).map(\.measureIndex) == [0, 1, 2, 3])
        let tight = ScoreViewOptions(spacing: EngravingSpacing(systemStretch: 1))
        let tightWidth = try narrowestOneSystemWidth(Self.score(), options: tight)
        let bare = laidOut(Self.score(), width: tightWidth, options: tight)
        let lastBar = try measure(3, in: bare)
        try #require(lastBar.width > 2 * bare.metrics.sp + 1)
        let pushed = laidOut(Self.score(blocks: [Self.hbox(2, before: 2)]), width: tightWidth, options: tight)
        #expect(pushed.systems.map { $0.measures.map(\.measureIndex) } == [[0, 1, 2], [3]])
    }

    /// MuseScore adds a box's width once to the line's natural width (`horizontalspacing.cpp:120-123`) and compares
    /// that with the line (`systemlayout.cpp:206`): the box does not stretch, so it costs its width once, not
    /// `systemStretch` times. Both thresholds come from a whole-point bisection, so they agree within 1 pt.
    @Test("an HBox makes the narrowest one-line width wider by its room, once")
    func roomCountsOnceAgainstTheLine() throws {
        let boxedScore = Self.score(blocks: [Self.hbox(6, before: 2)])
        let bareWidth = try narrowestOneSystemWidth(Self.score())
        let boxedWidth = try narrowestOneSystemWidth(boxedScore)
        let sp = laidOut(boxedScore).metrics.sp
        #expect(abs(boxedWidth - bareWidth - 6 * sp) <= 1)
    }

    /// The system-width check pins the run-start branch's `slot − room`: a run laid out at its whole slot would push
    /// the system's end out by the room.
    @Test("an HBox inside a collapsed multi-measure rest takes no room, and one at the run's start sits before the run")
    func hboxInsideACollapsedRunTakesNoRoom() throws {
        let options = ScoreViewOptions(multiMeasureRest: .collapse(minimumMeasures: 2))
        let bare = laidOut(Self.restRunScore(blocks: []), width: 600, options: options)
        try #require(bare.systems.flatMap(\.measures).compactMap(\.multiMeasureRest) == [4])
        try #require(bare.systems.count == 1)
        let inside = laidOut(Self.restRunScore(blocks: [Self.hbox(6, before: 3)]), width: 600, options: options)
        #expect(inside == bare)
        let atStart = laidOut(Self.restRunScore(blocks: [Self.hbox(6, before: 1)]), width: 600, options: options)
        try #require(atStart.systems.count == 1)
        let room = try roomBefore(1, in: atStart)
        #expect(closeEnough(room, 6 * atStart.metrics.sp))
        #expect(closeEnough(atStart.systems[0].size.width, bare.systems[0].size.width))
    }

    // MARK: - Staff-line gaps

    /// Where `measure`'s closing barline stroke ends, in system x: the rightmost barline it draws, plain in every bar
    /// these fixtures put before a box, plus half a thin stroke.
    private func plainBarLineEnd(of measure: LayoutMeasure, sp: CGFloat) throws -> CGFloat {
        var bars: [(subtype: String?, x: CGFloat)] = []
        for case let .barLine(subtype, origin, _, _, _) in measure.elements {
            bars.append((subtype: subtype, x: origin.x))
        }
        let closing = bars.max { $0.x < $1.x }
        let bar = try #require(closing, "measure \(measure.measureIndex) draws no barline")
        #expect(bar.subtype == nil)
        return measure.origin.x + bar.x + BarLineGeometry.thinThicknessSp / 2 * sp
    }

    /// MuseScore draws staff lines per measure, so an HBox's room has none: the system carries one gap in its own x,
    /// from the right edge of the barline that closes the measure before the box — where MuseScore's lines stop, short
    /// of that measure's right edge by the gutter after its barline — to where the measure after the box starts.
    @Test("an HBox's room is one staff-line gap from the barline before it to the next measure")
    func staffLineGapsCoverTheRoom() throws {
        let document = laidOut(Self.score(blocks: [Self.hbox(6, before: 2)]))
        try #require(document.systems.count == 1)
        let gaps = document.systems[0].staffLineGaps
        #expect(gaps.count == 1)
        let gap = try #require(gaps.first)
        let before = try measure(1, in: document)
        let after = try measure(2, in: document)
        let barEnd = try plainBarLineEnd(of: before, sp: document.metrics.sp)
        #expect(closeEnough(gap.lowerBound, barEnd))
        #expect(gap.lowerBound < before.origin.x + before.width)
        #expect(closeEnough(gap.upperBound, after.origin.x))
    }

    /// Pass 2 lays a collapsed run out in a branch of its own, so the room before a run's first measure is pinned
    /// apart from the room before an ordinary measure.
    @Test("an HBox before a collapsed multi-measure rest is a staff-line gap too")
    func gapBeforeACollapsedRun() throws {
        let options = ScoreViewOptions(multiMeasureRest: .collapse(minimumMeasures: 2))
        let document = laidOut(Self.restRunScore(blocks: [Self.hbox(6, before: 1)]), options: options)
        try #require(document.systems.count == 1)
        let gaps = document.systems[0].staffLineGaps
        #expect(gaps.count == 1)
        let gap = try #require(gaps.first)
        let before = try measure(0, in: document)
        let run = try measure(1, in: document)
        let barEnd = try plainBarLineEnd(of: before, sp: document.metrics.sp)
        #expect(closeEnough(gap.lowerBound, barEnd))
        #expect(gap.lowerBound < before.origin.x + before.width)
        #expect(closeEnough(gap.upperBound, run.origin.x))
    }

    @Test("a score with no HBox between two measures has no staff-line gap", arguments: roomlessBlocks)
    func noHBoxHasNoGaps(_ blocks: [PositionedScoreBlock]) {
        let document = laidOut(Self.score(blocks: blocks))
        #expect(document.systems.flatMap(\.staffLineGaps).isEmpty)
    }

    @Test("an HBox before the measure that opens a system leaves no staff-line gap")
    func gapAtSystemStartHasNoGap() throws {
        let document = laidOut(Self.score(blocks: [Self.hbox(6, before: 2)], lineBreakAfter: 1))
        try #require(document.systems.count == 2)
        #expect(document.systems[1].measures.first?.measureIndex == 2)
        #expect(document.systems.flatMap(\.staffLineGaps).isEmpty)
    }

    /// A host shades a staff over its lines (`LayoutDocument.staffBands`), so the band breaks where the lines do, and
    /// MuseScore draws no highlight in a box either: one band each side of the room, meeting the gap's two ends.
    @Test("a staff's band breaks over an HBox's room as its lines do")
    func staffBandBreaksOverTheRoom() throws {
        let document = laidOut(Self.score(blocks: [Self.hbox(6, before: 2)]))
        try #require(document.systems.count == 1)
        let system = document.systems[0]
        let gap = try #require(system.staffLineGaps.first)
        let bands = document.staffBands(verticalPaddingSp: 0)
        #expect(bands.count == 2)
        let left = try #require(bands.first)
        let right = try #require(bands.last)
        #expect(closeEnough(left.rect.maxX, system.origin.x + gap.lowerBound))
        #expect(closeEnough(right.rect.minX, system.origin.x + gap.upperBound))
    }
}
