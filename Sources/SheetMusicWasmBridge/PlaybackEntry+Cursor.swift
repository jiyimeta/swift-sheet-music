import JavaScriptKit
import SheetMusicAudioCore
import SheetMusicBridgeCore
import SheetMusicCore
import SheetMusicFoundation
import SheetMusicLayout

#if !canImport(CoreGraphics)
    /// `FoundationEssentials` has no `CGFloat`; anchor to Layout's stub the same
    /// way the bridge's other geometry files do. Swift's imports are
    /// file-scoped, so this has to be repeated per file that needs it.
    private typealias CGFloat = SheetMusicLayout.CGFloat
    private typealias CGPoint = SheetMusicLayout.CGPoint
#endif

/// Where to draw the playback cursor, in document millimetres — the same unit
/// the draw program uses, so a host multiplies both by one `pxPerMM`.
///
/// Android needs two calls for this: `nativeFrameAtTick` hands a `ScoreCursor`
/// to Kotlin, which passes it straight back into `nativeCursorFrame`. That is
/// affordable there because the Wirelet plugin generates a Kotlin codec for the
/// cursor. There is no such generator for JavaScript, so the cursor never leaves
/// wasm and the two calls fold into one.
@JS public struct CursorRect {
    public var xMM: Double
    public var yMM: Double
    public var widthMM: Double
    public var heightMM: Double
    /// The measure the cursor is parked in — what a "now playing bar N" readout
    /// and a "loop from here" button need.
    public var measureIndex: Int
    /// The position on the score's own clock, for a timecode readout. Differs
    /// from the player position the caller passed in on any score with repeats.
    public var notatedSeconds: Double

    /// Spelled out rather than left to the memberwise default, which would be
    /// `internal`: BridgeJS generates a `@_transparent` lowering function that
    /// cannot reference an internal declaration.
    public init(
        xMM: Double,
        yMM: Double,
        widthMM: Double,
        heightMM: Double,
        measureIndex: Int,
        notatedSeconds: Double,
    ) {
        self.xMM = xMM
        self.yMM = yMM
        self.widthMM = widthMM
        self.heightMM = heightMM
        self.measureIndex = measureIndex
        self.notatedSeconds = notatedSeconds
    }
}

/// Android: `nativeFrameAtTick` followed by `nativeCursorFrame`.
///
/// `nil` when the handle is unknown, no layout has been computed for it (the
/// document cache is what turns a cursor into geometry), or the position has no
/// frame.
@JS public func cursorRectAtPlayerSeconds(handle: Int, playerSeconds: Double) -> CursorRect? {
    guard let score = scoreTable.value(for: Int64(handle)),
          let entry = LayoutDocumentCache.entry(for: Int64(handle))
    else { return nil }
    let clock = PlaybackClockCache.clock(for: Int64(handle), score: score)
    guard let frame = clock.frame(atPlayerSeconds: playerSeconds) else { return nil }
    // The timeline emits cursors keyed by FULL-score staff addresses while the
    // cached document was laid out from the FILTERED score. Without this
    // translation a cursor on or after a hidden staff fails the lookup and the
    // playback cursor flickers in and out. Same step `nativeCursorFrame` takes.
    let translated = score.translateCursorForHiddenStaves(
        frame.cursor, hiddenStaves: entry.hiddenStaves,
    ) ?? frame.cursor
    guard let rect = entry.document.cursorFrame(for: translated, in: entry.filteredScore) else {
        return nil
    }
    // SheetMusicLayout works in typographic points; the draw program is encoded
    // in mm, so convert here too and the host needs one scale factor, not two.
    let ptToMM = 25.4 / 72.0
    return CursorRect(
        xMM: Double(rect.origin.x) * ptToMM,
        yMM: Double(rect.origin.y) * ptToMM,
        widthMM: Double(rect.size.width) * ptToMM,
        heightMM: Double(rect.size.height) * ptToMM,
        measureIndex: frame.cursor.measureIndex,
        notatedSeconds: frame.timeSeconds,
    )
}

/// The bounding rectangle of `measureIndex`, flattened as
/// `[xMM, yMM, widthMM, heightMM]`.
///
/// Empty when the handle is unknown, no layout has been computed, or the
/// measure is not present in the cached document.
@JS public func measureFrame(handle: Int, measureIndex: Int) -> [Double] {
    guard measureIndex >= 0,
          scoreTable.value(for: Int64(handle)) != nil,
          let document = LayoutDocumentCache.value(for: Int64(handle))
    else { return [] }
    for system in document.systems {
        guard let measure = system.measures
            .first(where: { $0.measureIndex == measureIndex }) else { continue }
        let ptToMM = 25.4 / 72.0
        return [
            Double(system.origin.x + measure.origin.x) * ptToMM,
            Double(system.origin.y + measure.origin.y) * ptToMM,
            Double(measure.width) * ptToMM,
            Double(system.size.height) * ptToMM,
        ]
    }
    return []
}

/// The player position a tap lands on, for seeking by clicking the score.
///
/// `xMM` / `yMM` are in document millimetres — the same coordinates
/// `computeLayout`'s draw program and `cursorRectAtPlayerSeconds`'s rectangle
/// use, so a host scales a pointer event by the one `pxPerMM` it already has.
///
/// **Nearest, not hit-test.** A tap that lands beside a note — or in a margin —
/// resolves to the closest playable element rather than to nothing, which is
/// what makes tap-to-seek usable with a finger. Only a score with nothing
/// playable in it yields no answer.
///
/// Returns **−1** when the handle is unknown, no layout has been computed, or
/// the document has no playable element at all. `0` would mean the top of the
/// score, which is a real answer.
///
/// Android: `nativeNearestCursor`, which returns an encoded `ScoreCursor` for
/// Kotlin to hand back to `nativeFrameForCursor`. There is no cursor codec in
/// JavaScript, so the two steps are folded together — the same collapse
/// `cursorRectAtPlayerSeconds` makes in the other direction.
///
/// The hidden-staff set comes from the cached layout rather than from a wire
/// payload the caller assembles, so the set the hit-test re-addresses against is
/// necessarily the one the document was filtered with.
@JS public func playerSecondsAtPoint(handle: Int, xMM: Double, yMM: Double) -> Double {
    guard let score = scoreTable.value(for: Int64(handle)),
          let entry = LayoutDocumentCache.entry(for: Int64(handle))
    else { return -1 }
    // mm → document points: the inverse of the pt → mm every geometry entry
    // point applies on the way out.
    let mmToPt = 72.0 / 25.4
    let point = CGPoint(x: CGFloat(xMM * mmToPt), y: CGFloat(yMM * mmToPt))
    guard #available(macOS 15.0, iOS 16.0, *) else { return -1 }
    guard let cursor = nearestEngineCursor(
        at: point, in: entry.document, score: score, hiddenStaves: entry.hiddenStaves,
    ) else { return -1 }
    let clock = PlaybackClockCache.clock(for: Int64(handle), score: score)
    guard let seconds = clock.playerSeconds(atCursor: cursor) else { return -1 }
    return seconds
}

/// The player position measure `measureIndex` starts at — a seek target.
///
/// Returns **−1** for an unknown handle or an out-of-range index. `0` would be
/// indistinguishable from the top of the score, which is a real position.
///
/// Android: `nativeUnrolledTickForNotated`, applied to a measure's start tick.
@JS public func playerSecondsForMeasure(handle: Int, measureIndex: Int) -> Double {
    guard let score = scoreTable.value(for: Int64(handle)) else { return -1 }
    let clock = PlaybackClockCache.clock(for: Int64(handle), score: score)
    return clock.playerSeconds(atMeasureIndex: measureIndex) ?? -1
}

/// Player seconds for a durable musical position.
///
/// Returns **−1** for an unknown handle or a position that does not resolve.
/// `0` would be indistinguishable from the top of the score, which is a real
/// position.
@JS public func playerSecondsForPosition(
    handle: Int, measureIndex: Int, tickInMeasure: Int,
) -> Double {
    guard measureIndex >= 0,
          tickInMeasure >= 0,
          let score = scoreTable.value(for: Int64(handle))
    else { return -1 }
    let clock = PlaybackClockCache.clock(for: Int64(handle), score: score)
    let cursor = ScoreCursor.beat(measureIndex: measureIndex, tickInMeasure: tickInMeasure)
    return clock.playerSeconds(atCursor: cursor) ?? -1
}

/// The durable musical position sounding at `playerSeconds`, flattened as
/// `[measureIndex, tickInMeasure]`.
///
/// Empty for an unknown handle or a position that does not resolve. The clock
/// may return an `.item` cursor at a note/rest onset; JavaScript still gets the
/// beat-shaped address by deriving that item's tick inside its measure.
@JS public func positionAtPlayerSeconds(handle: Int, playerSeconds: Double) -> [Double] {
    guard playerSeconds.isFinite,
          playerSeconds >= 0,
          let score = scoreTable.value(for: Int64(handle))
    else { return [] }
    let clock = PlaybackClockCache.clock(for: Int64(handle), score: score)
    guard playerSeconds <= clock.totalPlayerSeconds,
          let cursor = clock.cursor(atPlayerSeconds: playerSeconds)
    else { return [] }
    return [
        Double(cursor.measureIndex),
        Double(score.tickInMeasure(of: cursor)),
    ]
}

/// The measure sounding at `playerSeconds` — what a "loop from here" button
/// reads. Returns **−1** for an unknown handle or a score with no measures.
@JS public func measureIndexAtPlayerSeconds(handle: Int, playerSeconds: Double) -> Int {
    guard let score = scoreTable.value(for: Int64(handle)) else { return -1 }
    let clock = PlaybackClockCache.clock(for: Int64(handle), score: score)
    return clock.measureIndex(atPlayerSeconds: playerSeconds) ?? -1
}

/// `[startSeconds, endSeconds]` for a measure-range loop, in player
/// coordinates. Empty for an unknown handle or a range that is empty or
/// inverted.
///
/// The host compares its sequencer's position against `endSeconds` and seeks
/// back to `startSeconds`. That wrap is host-driven for the same reason it is on
/// Android: a sequencer's own loop covers the whole sequence, not a range inside
/// it.
///
/// `toMeasureExclusive` may equal the measure count, which loops to the end.
@JS public func loopPlayerSeconds(
    handle: Int, fromMeasureIndex: Int, toMeasureExclusive: Int,
) -> [Double] {
    guard let score = scoreTable.value(for: Int64(handle)) else { return [] }
    let clock = PlaybackClockCache.clock(for: Int64(handle), score: score)
    guard fromMeasureIndex < toMeasureExclusive,
          let start = clock.playerSeconds(atMeasureIndex: fromMeasureIndex)
    else { return [] }
    // A range's end is the start of the measure after it; past the final
    // measure that is the end of the sequence.
    let end = toMeasureExclusive < clock.measureCount
        ? clock.playerSeconds(atMeasureIndex: toMeasureExclusive)
        : clock.totalPlayerSeconds
    guard let end, end > start else { return [] }
    return [start, end]
}

/// The rectangles to tint for a measure-range loop, as `[x, y, width, height]`
/// repeated — four `Double`s per rectangle, in document millimetres.
///
/// One rectangle per system the range spans, so a loop crossing a line break
/// highlights both halves. Android: `nativeLoopHighlightRects`, which takes a
/// tick range; the conversion lives inside here because a loop UI counts in
/// measures, and `LoopHighlightTickResolver` exists for the tick-shaped caller.
///
/// Empty when the handle is unknown, no layout has been computed, or the range
/// is empty or inverted.
@JS public func loopHighlightRects(
    handle: Int, fromMeasureIndex: Int, toMeasureExclusive: Int,
) -> [Double] {
    guard fromMeasureIndex < toMeasureExclusive,
          let document = LayoutDocumentCache.value(for: Int64(handle))
    else { return [] }
    let rectsPt = document.loopHighlightRects(
        fromMeasureIndex: fromMeasureIndex,
        toMeasureExclusive: toMeasureExclusive,
    )
    let ptToMM = 25.4 / 72.0
    var out: [Double] = []
    out.reserveCapacity(rectsPt.count * 4)
    for rect in rectsPt {
        out.append(Double(rect.origin.x) * ptToMM)
        out.append(Double(rect.origin.y) * ptToMM)
        out.append(Double(rect.size.width) * ptToMM)
        out.append(Double(rect.size.height) * ptToMM)
    }
    return out
}
