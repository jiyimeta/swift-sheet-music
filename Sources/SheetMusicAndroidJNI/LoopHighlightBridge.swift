import Foundation
import SheetMusicAudioCore
import SheetMusicCore

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

// JNI entry point.
#if os(Android)
    import CJNI
    import SheetMusicLayout

    @_cdecl("Java_com_example_sheetmusic_jni_SheetMusicBridge_nativeLoopHighlightRects")
    // swiftlint:disable:next identifier_name
    public func Java_com_example_sheetmusic_jni_SheetMusicBridge_nativeLoopHighlightRects(
        _ envPtr: UnsafeMutablePointer<JNIEnv?>,
        _ clazz: jclass,
        _ scoreHandle: jlong,
        _ fromTick: jlong,
        _ toTick: jlong,
    ) -> jbyteArray? {
        guard let env = envPtr.pointee else { return nil }
        guard let score = scoreTable.value(for: scoreHandle),
              let document = LayoutDocumentCache.value(for: scoreHandle)
        else { return env.pointee.NewByteArray(envPtr, 0) }

        let timeline = PlaybackTimeline(score: score)
        guard let range = LoopHighlightTickResolver.measureRange(
            fromTick: fromTick,
            toTick: toTick,
            timeline: timeline,
        ) else {
            return env.pointee.NewByteArray(envPtr, 0)
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
        let encoded = LoopHighlightCodec.encode(rects)
        return makeJByteArray(env: envPtr, bytes: encoded)
    }
#endif
