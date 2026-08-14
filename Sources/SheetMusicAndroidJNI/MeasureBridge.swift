import Foundation
import SheetMusicBridgeCore
import SheetMusicCore
import SheetMusicLayout

// Measure-frame JNI bridge. Returns the bounding rect (mm) of the measure the
// playback cursor sits in, so the Android horizontal Reader can step
// measure-by-measure exactly like iOS `HorizontalScoreContainer.measureRect`.

/// JNI entry point exposed via swift-java for the Kotlin
/// `SheetMusicJNI.nativeMeasureFrame(...)` call site. Returns an empty `Data`
/// when the handle is unknown, the layout document is not cached, the cursor
/// fails to decode, or the measure cannot be resolved. Same wire format as
/// `nativeCursorFrame` (a single `CursorFrameCodec.DecodedFrame`, mm units).
public func nativeMeasureFrame(scoreHandle: Int64, cursorBytes: Data) -> Data {
    guard scoreTable.value(for: scoreHandle) != nil,
          let document = LayoutDocumentCache.value(for: scoreHandle)
    else { return Data() }
    guard !cursorBytes.isEmpty,
          let cursor = try? ScoreCursorCodec.decode(cursorBytes)
    else { return Data() }

    // The measure the cursor sits in: `.beat` carries it directly; `.item`
    // resolves via `ScoreItemID.measureIndex` (note/rest/tuplet/clef).
    let measureIndex: Int
    switch cursor {
    case let .beat(mi, _):
        measureIndex = mi
    case let .item(itemID):
        measureIndex = itemID.measureIndex
    }

    // Scan every system so honored layout breaks (multi-row layouts) resolve.
    for system in document.systems {
        guard let measure = system.measures
            .first(where: { $0.measureIndex == measureIndex }) else { continue }
        // SheetMusicLayout works in pt; convert to mm to match `nativeCursorFrame`
        // (the unit the Kotlin overlay multiplies by pxPerMM).
        let ptToMM = 25.4 / 72.0
        return CursorFrameCodec.encodeComponents(
            x: Double(system.origin.x + measure.origin.x) * ptToMM,
            y: Double(system.origin.y + measure.origin.y) * ptToMM,
            width: Double(measure.width) * ptToMM,
            height: Double(system.size.height) * ptToMM,
        )
    }
    return Data()
}
