import Foundation
import SheetMusicBridgeCore
import SheetMusicCore
import SheetMusicLayout

#if canImport(CoreGraphics)
    import CoreGraphics
#endif

#if !canImport(CoreGraphics)
    /// On Android, Foundation's CoreGraphics shims also export `CGFloat` /
    /// `CGPoint`, clashing with SheetMusicLayout's stubs. Anchor to the Layout
    /// definitions so the primitives resolve to the types the layout target uses.
    private typealias CGFloat = SheetMusicLayout.CGFloat
    private typealias CGPoint = SheetMusicLayout.CGPoint
#endif

// Annotation anchor primitives JNI bridge. Freehand ink is drawn in document
// millimetres (the unit the Kotlin overlay works in); SheetMusicLayout works in
// typographic points. These thin entry points wrap the shipped
// `LayoutDocument.resolveAnchor` / `anchorReferencePoint` primitives so Folino's
// shared anchoring core can reach a `LayoutDocument` cached inside THIS `.so`.
// The affine bake (normalize/denormalize the ink geometry, encode the neutral
// InkStroke) stays in Folino's shared Swift — these entry points are
// geometry-only and Folino-agnostic, mirroring `NearestCursorBridge`.
//
// Four verbs, in two pairs. `nativeResolveAnchor` / `nativeAnchorReferencePoint` speak
// the cached, staff-filtered layout's numbering. `nativeResolveFullScoreAnchor` /
// `nativeFullScoreAnchorReferencePoint` speak FULL-SCORE numbering (every staff the
// score declares) and translate through the hidden set the cached layout was computed
// from. A stored anchor wants the second pair: the hidden set changes, and the ink
// must stay on its staff when it does.

private let mmToPt = 72.0 / 25.4
private let ptToMM = 25.4 / 72.0

/// `r` on the wire, on `staff`: the display verb passes `r`'s own staff, the full-score verb the translated one.
private func resolvedAnchorWire(_ r: ResolvedAnchor, on staff: StaffAddress) -> ResolvedAnchorWire {
    ResolvedAnchorWire(
        measureIndex: Int32(r.measureIndex),
        tickInMeasure: Int32(r.tickInMeasure),
        partIndex: Int32(staff.partIndex),
        staffIndexInPart: Int32(staff.staffIndexInPart),
        dxSp: Double(r.dxSp),
        verticalOffsetSp: Double(r.verticalOffsetSp),
    )
}

/// One reference point on the wire, in mm; the `spMm == 0` sentinel when it did not resolve.
private func refPointWire(_ ref: (point: CGPoint, sp: CGFloat)?) -> AnchorRefPointWire {
    guard let ref else { return AnchorRefPointWire(xMm: 0, yMm: 0, spMm: 0) }
    return AnchorRefPointWire(
        xMm: Double(ref.point.x) * ptToMM, yMm: Double(ref.point.y) * ptToMM, spMm: Double(ref.sp) * ptToMM,
    )
}

/// JNI entry point exposed via swift-java for the Kotlin
/// `SheetMusicJNI.nativeResolveAnchor(...)` call site. Resolves a document-mm
/// point to a `ResolvedAnchor` in the cached (filtered) layout's address space
/// — the inverse of `nativeAnchorReferencePoint`. Unlike `nativeNearestCursor`
/// it does NOT re-address into the full score (the anchor never reaches the
/// audio engine; capture and display both run against the same cached document),
/// so it needs no hidden-staves blob. A host that stores the anchor and hides staves wants
/// `nativeResolveFullScoreAnchor` / `nativeFullScoreAnchorReferencePoint`.
///
/// Returns an empty `Data` when the score handle's layout is not cached, or when
/// the layout has no systems / staves / measures. On a hit, returns the
/// `ResolvedAnchorWire` encoding.
public func nativeResolveAnchor(scoreHandle: Int64, tapXmm: Double, tapYmm: Double) -> Data {
    guard let document = LayoutDocumentCache.value(for: scoreHandle) else { return Data() }
    let point = CGPoint(x: CGFloat(tapXmm * mmToPt), y: CGFloat(tapYmm * mmToPt))
    guard let r = document.resolveAnchor(at: point) else { return Data() }
    return resolvedAnchorWire(
        r, on: StaffAddress(partIndex: r.partIndex, staffIndexInPart: r.staffIndexInPart),
    ).encodeToData()
}

/// JNI entry point exposed via swift-java for the Kotlin
/// `SheetMusicJNI.nativeAnchorReferencePoint(...)` call site. Batched: resolves
/// each `(measure, tick, part, staff)` identity to its document-mm reference
/// point + staff-space (mm). One call resolves a whole annotation layer on the
/// hot display / reflow path. Identities that don't resolve emit an `spMm == 0`
/// sentinel, preserving positional alignment so the caller drops only that
/// stroke. A host that stores the anchor and hides staves wants
/// `nativeResolveFullScoreAnchor` / `nativeFullScoreAnchorReferencePoint`.
///
/// Returns an empty `Data` only when the score handle's layout is not cached, or
/// when the input blob fails to decode — so the caller can tell "no layout"
/// apart from "a layer that happened to be all misses".
public func nativeAnchorReferencePoint(scoreHandle: Int64, anchorsBytes: Data) -> Data {
    guard let document = LayoutDocumentCache.value(for: scoreHandle) else { return Data() }
    let ids: [AnchorIdentityWire]
    do {
        ids = try [AnchorIdentityWire](decoding: anchorsBytes)
    } catch {
        return Data()
    }
    let points = ids.map { id -> AnchorRefPointWire in
        refPointWire(document.anchorReferencePoint(
            measureIndex: Int(id.measureIndex),
            tickInMeasure: Int(id.tickInMeasure),
            partIndex: Int(id.partIndex),
            staffIndexInPart: Int(id.staffIndexInPart),
        ))
    }
    return points.encodeToData()
}

/// JNI entry point exposed via swift-java for the Kotlin `SheetMusicJNI.nativeResolveFullScoreAnchor(...)` call site.
/// `nativeResolveAnchor`, answered in FULL-SCORE addressing: the staff the point lands on in the cached
/// (staff-filtered) layout is moved back to its place in the score as loaded, every staff present. A stored anchor
/// has to be in that addressing, because the hidden set changes and the stored ink must not move with it.
///
/// Takes no hidden-staves argument. The set is `LayoutDocumentCache.entry(for:).hiddenStaves`, the one the cached
/// document was laid out from, as for `nativeEditingHitTest`, so the translation cannot disagree with the document it
/// translates out of. The renumbering is computed from the handle's live score (`scoreTable`), as there. An edit
/// clears the cache (`LayoutDocumentCache.invalidate`) before the two could describe different part shapes.
///
/// Same `ResolvedAnchorWire` as `nativeResolveAnchor`, byte for byte when nothing is hidden. Empty `Data` when the
/// handle is unknown, nothing is cached, the layout has no systems / staves / measures, or the staff has no
/// full-score address.
public func nativeResolveFullScoreAnchor(scoreHandle: Int64, tapXmm: Double, tapYmm: Double) -> Data {
    guard let score = scoreTable.value(for: scoreHandle),
          let entry = LayoutDocumentCache.entry(for: scoreHandle)
    else { return Data() }
    let point = CGPoint(x: CGFloat(tapXmm * mmToPt), y: CGFloat(tapYmm * mmToPt))
    guard let r = entry.document.resolveAnchor(at: point),
          let full = score.unfilterStaffAddress(
              StaffAddress(partIndex: r.partIndex, staffIndexInPart: r.staffIndexInPart),
              hidingStaves: entry.hiddenStaves,
          )
    else { return Data() }
    return resolvedAnchorWire(r, on: full).encodeToData()
}

/// JNI entry point exposed via swift-java for the Kotlin `SheetMusicJNI.nativeFullScoreAnchorReferencePoint(...)` call
/// site. `nativeAnchorReferencePoint` for FULL-SCORE identities: each staff is moved into the cached layout's
/// numbering through the hidden set that layout was computed from (see `nativeResolveFullScoreAnchor`) before the
/// lookup. An identity on a hidden staff, or on a staff the score does not have, answers the `spMm == 0` sentinel in
/// its own slot. The caller drops that stroke from the drawing and keeps it in the layer, so showing the staff again
/// brings the ink back.
///
/// Empty `Data` only when the handle is unknown, nothing is cached, or the input fails to decode, the same
/// "no answer" / "all misses" split `nativeAnchorReferencePoint` makes.
public func nativeFullScoreAnchorReferencePoint(scoreHandle: Int64, anchorsBytes: Data) -> Data {
    guard let score = scoreTable.value(for: scoreHandle),
          let entry = LayoutDocumentCache.entry(for: scoreHandle)
    else { return Data() }
    let ids: [AnchorIdentityWire]
    do {
        ids = try [AnchorIdentityWire](decoding: anchorsBytes)
    } catch {
        return Data()
    }
    return ids.map { id -> AnchorRefPointWire in
        let full = StaffAddress(partIndex: Int(id.partIndex), staffIndexInPart: Int(id.staffIndexInPart))
        guard let shown = score.filterStaffAddress(full, hidingStaves: entry.hiddenStaves) else {
            return refPointWire(nil)
        }
        return refPointWire(entry.document.anchorReferencePoint(
            measureIndex: Int(id.measureIndex), tickInMeasure: Int(id.tickInMeasure),
            partIndex: shown.partIndex, staffIndexInPart: shown.staffIndexInPart,
        ))
    }.encodeToData()
}
