import Foundation
import SheetMusicBridgeCore
import SheetMusicCore
import SheetMusicEditWire
import SheetMusicLayout

#if canImport(CoreGraphics)
    import CoreGraphics
#endif

#if !canImport(CoreGraphics)
    /// On Android, Foundation's CoreGraphics shims export their own `CGRect`, which clashes with `SheetMusicLayout`'s
    /// stub — see `MarqueeBridge.swift`'s copy of this guard. File-scoped `private` for the same reason it is there.
    private typealias CGRect = SheetMusicLayout.CGRect
#endif

/// JNI entry point exposed via swift-java for the Kotlin `SheetMusicJNI.nativeSelectionInkFrames(...)` call site: where
/// a selected clef or engraved element (a mark) is drawn in the cached layout, so an Android host can hang a control
/// off the glyph the reader selected, as an Apple host does.
///
/// One frame per place the item is drawn, in document order: `ScoreHitTester.clefHitRects(for:)` for a `.clef`,
/// `elementHitRects(for:)` for an `.element` — the geometry an Apple host floats its controls by. An element can be
/// drawn in places nowhere near each other (a hairpin clipped across a system break, a key signature and its courtesy
/// announcement), so the pieces come one by one rather than as their union, and picking the one beside the reader's tap
/// is the host's call. Converted from document points to millimetres (`25.4 / 72.0`), with the cached document's own
/// staff space, `StaffMetrics.sp`, once beside them, for a host spacing its control off the glyph.
///
/// `itemBytes` is a `ScoreItemIDCodec` payload, full-score-addressed — the value `nativeEditingHitTarget` returns — and
/// is re-addressed past the cache entry's hidden staves exactly as `nativeEditingCaretFrame`'s is (`cachedItem`). Like
/// it, this takes no layout options.
///
/// Empty `Data` when the handle is unknown, nothing is cached, `itemBytes` fails to decode or names an item on a hidden
/// staff (its re-addressing falls back to a `.beat`), the item is any other kind (a note, rest, tuplet, text or grace
/// note — the caret and the range box answer for those), or it is drawn nowhere. Otherwise a `SelectionInkFramesCodec`
/// payload.
///
/// Not `@available`-annotated, as `nativeEditingHitTarget` is not: the jextract wrapper is generated without one. The
/// hit tester's macOS 15 requirement is met by an `if #available` guard (always true on Android's Swift runtime).
public func nativeSelectionInkFrames(scoreHandle: Int64, itemBytes: Data) -> Data {
    guard let score = scoreTable.value(for: scoreHandle),
          let entry = LayoutDocumentCache.entry(for: scoreHandle),
          let item = cachedItem(itemBytes, of: score, in: entry)
    else { return Data() }

    guard #available(macOS 15.0, iOS 16.0, *) else { return Data() }
    let rects = inkRects(of: item, in: ScoreHitTester(document: entry.document))
    guard !rects.isEmpty else { return Data() }

    let ptToMm = 25.4 / 72.0
    let frames = rects.map { rect in
        SelectionInkFrameWire(
            xMm: Double(rect.minX) * ptToMm,
            yMm: Double(rect.minY) * ptToMm,
            widthMm: Double(rect.width) * ptToMm,
            heightMm: Double(rect.height) * ptToMm,
        )
    }
    return SelectionInkFramesCodec.encode(spMm: Double(entry.document.metrics.sp) * ptToMm, frames: frames)
}

/// Every place `item` is drawn, in document points; empty for an item that is neither a clef nor an element.
@available(macOS 15.0, *)
private func inkRects(of item: ScoreItemID, in tester: ScoreHitTester) -> [CGRect] {
    switch item {
    case let .clef(anchor):
        tester.clefHitRects(for: anchor)
    case let .element(id):
        tester.elementHitRects(for: ScoreHitTarget(elementID: id))
    case .note, .rest, .tuplet, .text, .graceNote:
        []
    }
}
