import Foundation
import SheetMusicCore
import SheetMusicLayout

// Cursor-frame JNI bridge. The testable logic (`LayoutDocumentCache`,
// `CursorFrameCodec`) is host-platform; the swift-java entry point
// below is the sole binding surface the Kotlin facade calls.

/// JNI entry point exposed via swift-java for the Kotlin
/// `SheetMusicJNI.nativeCursorFrame(...)` call site. Returns an empty
/// `Data` when the score handle is unknown, the layout document is not
/// cached, or the cursor bytes fail to decode / resolve.
public func nativeCursorFrame(scoreHandle: Int64, cursorBytes: Data) -> Data {
    guard let score = scoreTable.value(for: scoreHandle),
          let entry = LayoutDocumentCache.entry(for: scoreHandle)
    else { return Data() }
    guard !cursorBytes.isEmpty,
          let cursor = try? ScoreCursorCodec.decode(cursorBytes)
    else { return Data() }
    // The engine emits cursors keyed by full-score staff addresses, but the cached document is laid out
    // from the filtered score. Translate the cursor into the filtered layout's coordinate space — visible
    // staves re-stamped to their filtered address, a cursor on a hidden staff to a `.beat` fallback —
    // before resolving; otherwise a cursor on or after a hidden staff fails the lookup and the playback
    // cursor flickers in and out. Resolve against the *filtered* score so a `.beat` interpolates X against
    // the surviving visible columns.
    let translated = score.translateCursorForHiddenStaves(cursor, hiddenStaves: entry.hiddenStaves) ?? cursor
    guard let rect = entry.document.cursorFrame(for: translated, in: entry.filteredScore) else {
        return Data()
    }
    // SheetMusicLayout works in typographic points (pt); LayoutBridge
    // converts DrawCommands to mm before encoding. Apply the same
    // conversion here so the cursor frame is in mm — the unit the
    // Kotlin overlay multiplies by pxPerMM to reach screen pixels.
    let ptToMM = 25.4 / 72.0
    return CursorFrameCodec.encodeComponents(
        x: Double(rect.origin.x) * ptToMM,
        y: Double(rect.origin.y) * ptToMM,
        width: Double(rect.size.width) * ptToMM,
        height: Double(rect.size.height) * ptToMM,
    )
}
