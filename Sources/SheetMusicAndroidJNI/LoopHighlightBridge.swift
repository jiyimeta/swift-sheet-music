import Foundation
import SheetMusicAudioCore
import SheetMusicBridgeCore
import SheetMusicCore
import SheetMusicLayout

/// Helper that maps a tick range to a measure range via the score's
/// `PlaybackTimeline.measureStartTicks`. Pure function; testable on
/// host without JNI.
enum LoopHighlightTickResolver {
    static func measureRange(
        fromTick: Int64,
        toTick: Int64,
        timeline: PlaybackTimeline,
    ) -> (from: Int, toExclusive: Int)? {
        let measureStarts = timeline.measureStartTicks
        guard !measureStarts.isEmpty else { return nil }

        // fromMeasure = largest index where measureStarts[idx] <= fromTick.
        // toMeasureExclusive = first index where measureStarts[idx] >= toTick;
        // when all starts are < toTick, the entire measure list is included.
        var fromMeasure = 0
        var toMeasureExclusive = measureStarts.count
        for idx in measureStarts.indices {
            let start = Int64(measureStarts[idx])
            if start <= fromTick { fromMeasure = idx }
            if start >= toTick {
                toMeasureExclusive = idx
                break
            }
        }
        guard fromMeasure < toMeasureExclusive else { return nil }
        return (fromMeasure, toMeasureExclusive)
    }
}

/// JNI entry point exposed via swift-java for the Kotlin
/// `SheetMusicJNI.nativeLoopHighlightRects(...)` call site. Returns an
/// empty `Data` when the score handle is unknown, the layout document is
/// not cached, or the tick range yields no measures.
public func nativeLoopHighlightRects(
    scoreHandle: Int64,
    fromTick: Int64,
    toTick: Int64,
) -> Data {
    guard let score = scoreTable.value(for: scoreHandle),
          let document = LayoutDocumentCache.value(for: scoreHandle)
    else { return Data() }

    let timeline = PlaybackTimeline(score: score)
    guard let range = LoopHighlightTickResolver.measureRange(
        fromTick: fromTick,
        toTick: toTick,
        timeline: timeline,
    ) else {
        return Data()
    }

    let rectsPt = document.loopHighlightRects(
        fromMeasureIndex: range.from,
        toMeasureExclusive: range.toExclusive,
    )
    // SheetMusicLayout works in typographic points; convert to mm
    // to match the same unit consumed by the Compose overlay.
    let ptToMM = 25.4 / 72.0
    let rects = rectsPt.map { r in
        LoopHighlightCodec.Rect(
            x: Double(r.origin.x) * ptToMM,
            y: Double(r.origin.y) * ptToMM,
            width: Double(r.size.width) * ptToMM,
            height: Double(r.size.height) * ptToMM,
        )
    }
    return LoopHighlightCodec.encode(rects)
}
