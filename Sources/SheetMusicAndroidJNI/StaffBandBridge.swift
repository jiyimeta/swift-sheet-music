import Foundation
import SheetMusicBridgeCore
import SheetMusicCore
import SheetMusicLayout

#if canImport(CoreGraphics)
    import CoreGraphics
#endif

#if !canImport(CoreGraphics)
    /// On Android, Foundation's CoreGraphics shims also export `CGFloat`, clashing with SheetMusicLayout's stubs.
    /// Anchor to the Layout definition so the primitive resolves to the type the layout target uses.
    private typealias CGFloat = SheetMusicLayout.CGFloat
#endif

/// JNI entry point exposed via swift-java for the Kotlin `SheetMusicJNI.nativeStaffBands(...)` call site: every
/// staff's band in the cached layout (`LayoutDocument.staffBands(verticalPaddingSp:)`, the same rectangle an Apple host
/// shades), as `[StaffBandWire]` in document millimetres.
///
/// Re-addressed like `nativeEditingMeasureHitTest`: the staff the cached (filtered) document names is moved to its
/// full-score address with `Score.unfilterStaffAddress` and the cache entry's own hidden set, so a host matches the
/// bands against the staves it stores highlights for without knowing what is hidden. A hidden staff is not laid out
/// and has no band.
///
/// Empty `Data` when the handle is unknown or nothing is cached — distinct from a layout with no staves, which encodes
/// an empty array.
public func nativeStaffBands(scoreHandle: Int64, verticalPaddingSp: Double) -> Data {
    guard let score = scoreTable.value(for: scoreHandle),
          let entry = LayoutDocumentCache.entry(for: scoreHandle)
    else { return Data() }
    let ptToMm = 25.4 / 72.0
    let bands = entry.document.staffBands(verticalPaddingSp: CGFloat(verticalPaddingSp))
    return bands.compactMap { band -> StaffBandWire? in
        guard let staff = score.unfilterStaffAddress(band.staff, hidingStaves: entry.hiddenStaves) else { return nil }
        return StaffBandWire(
            partIndex: Int32(staff.partIndex),
            staffIndexInPart: Int32(staff.staffIndexInPart),
            xMm: Double(band.rect.minX) * ptToMm,
            yMm: Double(band.rect.minY) * ptToMm,
            widthMm: Double(band.rect.width) * ptToMm,
            heightMm: Double(band.rect.height) * ptToMm,
        )
    }.encodeToData()
}
