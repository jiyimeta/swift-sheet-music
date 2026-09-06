import Foundation
import SheetMusicBridgeCore
import SheetMusicCore
import SheetMusicEditWire
import SheetMusicLayout

#if !canImport(CoreGraphics)
    /// See `FontMetricsTable.swift` — on Android, Foundation's CoreGraphics shims export their own
    /// `CGFloat` / `CGPoint` / `CGRect`, which clash with `SheetMusicLayout`'s stubs. Anchor to the
    /// Layout definitions so the hit tester's geometry resolves. File-scoped `private` for the same
    /// reason it is there: a module-scope `typealias` collides with the identical pattern in the
    /// other bridge files.
    private typealias CGFloat = SheetMusicLayout.CGFloat
    private typealias CGPoint = SheetMusicLayout.CGPoint
    private typealias CGRect = SheetMusicLayout.CGRect
    private typealias CGSize = SheetMusicLayout.CGSize
#endif

// MARK: - Marquee selection (swift-java entry point)

/// JNI entry point exposed via swift-java for the Kotlin `SheetMusicJNI.nativeItemIDsInRect(...)`
/// call site: every chord / rest whose layout box intersects the given rectangle, in query order.
///
/// The bridge had a single-point hit test (`nativeEditingHitTest`) and nothing else, so a host could
/// select one thing at a time. `ScoreHitTester.itemIDs(in:)` — the marquee query the Apple example
/// drags a rubber band with — is in `SheetMusicLayout` and has always cross-compiled to Android; it
/// simply had no entry point.
///
/// Coordinates are millimetres in document space, converted here the same way
/// `nativeEditingHitTest` converts its point, so a host works in one unit across both calls.
///
/// The ids come back *full-score-addressed* via `engineCursorForFilteredTap`, matching what
/// `nativeEditingHitTest` returns and what `SelectionTintCodec` expects — a host can hand this
/// result straight to `nativeEncodeDrawProgram` without re-addressing anything.
///
/// Order is `ScoreHitTester`'s own: systems top-to-bottom, then event columns left-to-right within a
/// system. A host extending a selection, or naming "the first thing the drag covered", depends on
/// it, so the payload is a list rather than a set.
///
/// A degenerate (zero width or height) rect is *not* special-cased to empty: `CGRect.intersects` is
/// three-way at the edges, and a zero-height band across a staff is a legitimate query. See
/// `ScoreHitTester.itemIDs(in:)`'s own doc comment.
///
/// Returns an empty `Data` when the score handle is unknown or the layout document is not cached —
/// the same "empty means no answer" contract the other geometry entry points use. An empty *list*
/// (a rect covering nothing) encodes as a decodable payload with zero items, which is a different
/// thing and a host can tell them apart.
public func nativeItemIDsInRect(
    scoreHandle: Int64,
    xMm: Double,
    yMm: Double,
    widthMm: Double,
    heightMm: Double,
) -> Data {
    guard let score = scoreTable.value(for: scoreHandle),
          let entry = LayoutDocumentCache.entry(for: scoreHandle)
    else { return Data() }

    // mm → document points (inverse of the frame bridges' `pt * 25.4 / 72.0`), matching
    // `nativeEditingHitTest`.
    let mmToPt = 72.0 / 25.4
    let rect = CGRect(
        origin: CGPoint(x: CGFloat(xMm * mmToPt), y: CGFloat(yMm * mmToPt)),
        size: CGSize(width: CGFloat(widthMm * mmToPt), height: CGFloat(heightMm * mmToPt)),
    )

    guard #available(macOS 15.0, iOS 16.0, *) else { return Data() }
    let filtered = ScoreHitTester(document: entry.document).itemIDs(in: rect)

    // Re-address into full-score space, dropping anything that does not survive — the same
    // translation `nativeEditingHitTest` applies to its single hit, applied element-wise so the
    // two entry points hand a host ids from one address space.
    var ids: [ScoreItemID] = []
    ids.reserveCapacity(filtered.count)
    for item in filtered {
        guard case let .item(full) = score.engineCursorForFilteredTap(
            .item(item), hiddenStaves: entry.hiddenStaves,
        ) else { continue }
        ids.append(full)
    }
    return ScoreItemIDListCodec.encode(ids)
}
