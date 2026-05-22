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
    guard scoreTable.value(for: scoreHandle) != nil,
          let document = LayoutDocumentCache.value(for: scoreHandle)
    else { return Data() }
    guard !cursorBytes.isEmpty,
          let cursor = try? ScoreCursorCodec.decode(cursorBytes)
    else { return Data() }
    guard let score = scoreTable.value(for: scoreHandle) else { return Data() }
    guard let rect = document.cursorFrame(for: cursor, in: score) else {
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
