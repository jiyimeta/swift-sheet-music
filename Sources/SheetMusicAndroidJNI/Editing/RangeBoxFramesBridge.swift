import Foundation
import SheetMusicBridgeCore
import SheetMusicCore
import SheetMusicEditWire
import SheetMusicLayout

#if canImport(CoreGraphics)
    import CoreGraphics
#endif

/// JNI entry point exposed via swift-java for the Kotlin `SheetMusicJNI.nativeRangeBoxFrames(...)` call site: the
/// outline a range selection draws in the cached layout — the box an Apple host strokes in
/// `ScoreLayerBuilder.drawRangeBoxes` — so Android draws the same one instead of measuring its own.
///
/// One frame per system the selection reaches: `LayoutSystem.rangeBoxRect(selectedIDs:metrics:)` (system coordinates)
/// moved into document coordinates by the system's origin, as an Apple host's system layer sits at that origin, and
/// converted to millimetres (`25.4 / 72.0`). The stroke width, `StaffMetrics.rangeBoxLineWidth`, comes once beside
/// them. Both read the cached document's own metrics, the ones it was laid out with.
///
/// `selectionBytes` is the `SelectionTintCodec` payload the host already hands `nativeEncodeDrawProgram`, and its ids
/// go through the same re-addressing and expansion (`cachedSelectionIDs`), so the box surrounds exactly what the tint
/// lights. Its color is not read: the host strokes the box in its own. Like the encode, this takes no layout
/// options — the hidden-staff set is the cache entry's, the one the document was actually laid out from.
///
/// When to draw a box is the host's call, and this verb answers for whatever ids it is given. Apple draws one only for
/// a RANGE selection (`SelectionRenderState.drawRangeBox`), never for a single or multi selection.
///
/// Empty `Data` means no box: the handle is unknown, nothing is cached, `selectionBytes` fails to decode, or none of
/// its ids is a note or rest laid out on some system (an empty selection, one wholly on hidden staves, one of texts
/// alone). Otherwise a `RangeBoxFramesCodec` payload.
public func nativeRangeBoxFrames(scoreHandle: Int64, selectionBytes: Data) -> Data {
    guard let score = scoreTable.value(for: scoreHandle),
          let entry = LayoutDocumentCache.entry(for: scoreHandle),
          let decoded = try? SelectionTintCodec.decode(selectionBytes)
    else { return Data() }

    let ids = cachedSelectionIDs(decoded.ids, of: score, in: entry)
    guard !ids.isEmpty else { return Data() }

    let ptToMm = 25.4 / 72.0
    let metrics = entry.document.metrics
    let frames = entry.document.systems.compactMap { system -> RangeBoxFrameWire? in
        guard let box = system.rangeBoxRect(selectedIDs: ids, metrics: metrics) else { return nil }
        let rect = box.offsetBy(dx: system.origin.x, dy: system.origin.y)
        return RangeBoxFrameWire(
            xMm: Double(rect.minX) * ptToMm,
            yMm: Double(rect.minY) * ptToMm,
            widthMm: Double(rect.width) * ptToMm,
            heightMm: Double(rect.height) * ptToMm,
        )
    }
    guard !frames.isEmpty else { return Data() }
    return RangeBoxFramesCodec.encode(lineWidthMm: Double(metrics.rangeBoxLineWidth) * ptToMm, frames: frames)
}
