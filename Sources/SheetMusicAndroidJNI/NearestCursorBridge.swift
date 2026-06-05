import Foundation
import SheetMusicCore
import SheetMusicLayout

#if canImport(CoreGraphics)
    import CoreGraphics
#endif

#if !canImport(CoreGraphics)
    /// On Android, Foundation's CoreGraphics shims also export `CGFloat`,
    /// clashing with SheetMusicLayout's stub. Anchor to the Layout definitions
    /// so `nearestEngineCursor`'s `CGPoint` parameter resolves to the stub the
    /// rest of the layout target uses.
    private typealias CGFloat = SheetMusicLayout.CGFloat
    private typealias CGPoint = SheetMusicLayout.CGPoint
#endif

// Nearest-cursor (tap → engine cursor) JNI bridge. The Android Reader passes a
// tap in document millimetres plus the current display options (carrying the
// hidden-staves set); this resolves the nearest playable element on the staff
// closest to the touch and returns an engine-ready, full-score-addressed
// ScoreCursor — the same `nearestEngineCursor` entry point iOS calls.

/// JNI entry point exposed via swift-java for the Kotlin
/// `SheetMusicJNI.nativeNearestCursor(...)` call site.
///
/// `hiddenStavesBytes` is a `LayoutOptionsWire` payload — the exact same blob
/// the Reader already builds for `nativeComputeLayout`. We reuse it (rather than
/// inventing a second hidden-staves wire format) so the hidden-staves set the
/// hit-test re-addresses against is byte-for-byte the set the layout was filtered
/// with. Only `hiddenStaffAddresses` is read here; the other fields are ignored.
///
/// The tap arrives in document millimetres (the unit the Kotlin overlay works
/// in); SheetMusicLayout works in typographic points, so we convert mm → pt with
/// the inverse of the pt → mm factor the frame bridges apply.
///
/// Returns an empty `Data` when the score handle is unknown, the layout document
/// is not cached, the options blob fails to decode, or the tap hit no playable
/// element. On a hit, returns the `ScoreCursorCodec` encoding of the cursor —
/// the same wire format `nativeCursorFrame` / `nativeMeasureFrame` accept back.
///
/// Not `@available`-annotated: the swift-java jextract `@_cdecl` wrapper that
/// calls this is generated without an availability attribute, so the entry
/// point must compile at the package's macOS 14 / iOS 17 baseline. The
/// macOS 15 / iOS 16 requirement of `nearestEngineCursor` is satisfied with an
/// `if #available` guard below (always true on Android's Swift runtime).
public func nativeNearestCursor(
    scoreHandle: Int64,
    tapXmm: Double,
    tapYmm: Double,
    hiddenStavesBytes: Data,
) -> Data {
    guard let score = scoreTable.value(for: scoreHandle),
          let document = LayoutDocumentCache.value(for: scoreHandle)
    else { return Data() }

    let hiddenStaves: Set<StaffAddress>
    do {
        hiddenStaves = try LayoutOptionsCodec.decode(hiddenStavesBytes).hiddenStaffAddresses
    } catch {
        return Data()
    }

    // mm → document points (inverse of the frame bridges' `pt * 25.4 / 72.0`).
    let mmToPt = 72.0 / 25.4
    let point = CGPoint(x: CGFloat(tapXmm * mmToPt), y: CGFloat(tapYmm * mmToPt))

    guard #available(macOS 15.0, iOS 16.0, *) else { return Data() }
    guard let cursor = nearestEngineCursor(
        at: point, in: document, score: score, hiddenStaves: hiddenStaves,
    ) else { return Data() }

    return ScoreCursorCodec.encode(cursor)
}
