import Foundation
import SheetMusicBridgeCore
import SheetMusicCore
import SheetMusicEditWire
import SheetMusicLayout

#if canImport(CoreGraphics)
    import CoreGraphics
#endif

#if !canImport(CoreGraphics)
    /// On Android, Foundation's CoreGraphics shims also export `CGFloat`/`CGPoint`, clashing with
    /// SheetMusicLayout's stubs — see `EditGeometryBridge.swift`'s copy of this guard.
    private typealias CGFloat = SheetMusicLayout.CGFloat
    private typealias CGPoint = SheetMusicLayout.CGPoint
#endif

// Credit-text JNI bridge: where the engraved title-block credits (title, subtitle, composer, lyricist) sit in the
// cached layout, so an Android host can hit-test a tap on one and hang a control off it, as an Apple host does with
// `LayoutDocument.creditTextLine(at:tolerance:)`. Both entry points read `LayoutDocumentCache`, never write it, and
// answer a `CreditTextFrameCodec` payload in document millimetres (`25.4 / 72.0`).

/// JNI entry point exposed via swift-java for the Kotlin `SheetMusicJNI.nativeCreditTextHit(...)` call site: the credit
/// whose line a tap lands on, with that line's frame.
///
/// `xMm`/`yMm` are a tap in document millimetres, converted to points as every other bridge does (`72.0 / 25.4`). The
/// reach is a quarter of a staff space around the line (`document.metrics.sp * 0.25`), the tolerance an Apple host
/// uses.
///
/// Empty `Data` when the handle is unknown, nothing is cached, or the point is on no credit.
public func nativeCreditTextHit(scoreHandle: Int64, xMm: Double, yMm: Double) -> Data {
    guard let entry = LayoutDocumentCache.entry(for: scoreHandle) else { return Data() }
    let mmToPt = 72.0 / 25.4
    let point = CGPoint(x: CGFloat(xMm * mmToPt), y: CGFloat(yMm * mmToPt))
    guard let line = entry.document.creditTextLine(at: point, tolerance: entry.document.metrics.sp * 0.25) else {
        return Data()
    }
    return encode(line, sp: entry.document.metrics.sp)
}

/// JNI entry point exposed via swift-java for the Kotlin `SheetMusicJNI.nativeCreditTextFrame(...)` call site: where
/// the credit `fieldCode` (`ScoreInfoFieldCode`) is engraved, for a host that already knows which credit it holds
/// selected and wants its frame again after a relayout.
///
/// Empty `Data` when the handle is unknown, nothing is cached, `fieldCode` is outside the table, or that credit is not
/// engraved as an editable line.
public func nativeCreditTextFrame(scoreHandle: Int64, fieldCode: Int32) -> Data {
    guard let entry = LayoutDocumentCache.entry(for: scoreHandle),
          let field = ScoreInfoFieldCode.field(code: fieldCode),
          let line = entry.document.creditTextLine(for: field)
    else { return Data() }
    return encode(line, sp: entry.document.metrics.sp)
}

/// The frame in millimetres plus the document's staff space (`metrics.sp`) in millimetres, which a host sizes its
/// controls by.
private func encode(_ line: CreditTextLine, sp: CGFloat) -> Data {
    let ptToMm = 25.4 / 72.0
    return CreditTextFrameCodec.encode(
        fieldCode: ScoreInfoFieldCode.code(of: line.field),
        xMm: Double(line.frame.minX) * ptToMm,
        yMm: Double(line.frame.minY) * ptToMm,
        widthMm: Double(line.frame.width) * ptToMm,
        heightMm: Double(line.frame.height) * ptToMm,
        spMm: Double(sp) * ptToMm,
    )
}
