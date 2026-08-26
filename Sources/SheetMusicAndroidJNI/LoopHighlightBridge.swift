import Foundation
import SheetMusicAudioCore
import SheetMusicBridgeCore
import SheetMusicCore
import SheetMusicLayout

// The tick→measure resolution itself lives in
// `SheetMusicBridgeCore.LoopHighlightTickResolver`, which the wasm bridge
// shares; only the JNI binding surface is here.

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
