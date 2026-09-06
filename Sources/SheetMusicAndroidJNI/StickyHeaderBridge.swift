import Foundation
import SheetMusicBridgeCore
import SheetMusicCore

// MARK: - Sticky header (swift-java entry point)

/// JNI entry point exposed via swift-java for the Kotlin
/// `SheetMusicJNI.nativeStickyHeaderProgram(...)` call site: the frozen clef / key / time /
/// instrument-name pane a horizontal continuous view pins to its left edge.
///
/// MuseScore's continuous view keeps that pane so a reader who has scrolled past bar 1 can still
/// see what key and metre they are in. `SheetMusicUI.StickyHeaderView` provides it on Apple; no
/// other host could, because the pane is a *synthesized* system rather than a slice of the score
/// and nothing bridged the synthesis.
///
/// Answers a one-page draw program in the same wire format `nativeComputeLayout` returns, so a host
/// decodes and paints it with the renderer it already has — no second drawing path, and a change to
/// how a clef is drawn reaches the pane for free.
///
/// - Parameter scrollXMm: the viewport's left edge in document millimetres, the same space every
///   other geometry entry point takes.
///
/// Returns an empty `Data` when the handle is unknown, no layout is cached, or the score has no
/// measures to freeze.
public func nativeStickyHeaderProgram(scoreHandle: Int64, scrollXMm: Double) -> Data {
    guard let score = scoreTable.value(for: scoreHandle),
          let entry = LayoutDocumentCache.entry(for: scoreHandle)
    else { return Data() }
    guard #available(macOS 15.0, iOS 16.0, *) else { return Data() }

    // mm → document points, matching `nativeEditingHitTest` and `nativeItemIDsInRect`.
    let mmToPt = 72.0 / 25.4
    // The filtered score and document, not the full ones: the pane must show the staves the host
    // is actually looking at. A hidden staff's clef frozen at the left edge of a view that does not
    // render that staff is worse than no pane.
    guard let page = LayoutBridge.stickyHeaderPage(
        score: entry.filteredScore,
        document: entry.document,
        scrollXPt: scrollXMm * mmToPt,
    ) else { return Data() }

    return DrawProgramCodec.encode(pages: [page])
}
