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

private let mmToPt = 72.0 / 25.4
private let ptToMM = 25.4 / 72.0

/// JNI entry point exposed via swift-java for the Kotlin
/// `SheetMusicJNI.nativeResolveAnchor(...)` call site. Resolves a document-mm
/// point to a `ResolvedAnchor` in the cached (filtered) layout's address space
/// — the inverse of `nativeAnchorReferencePoint`. Unlike `nativeNearestCursor`
/// it does NOT re-address into the full score (the anchor never reaches the
/// audio engine; capture and display both run against the same cached document),
/// so it needs no hidden-staves blob.
///
/// Returns an empty `Data` when the score handle's layout is not cached, or when
/// the layout has no systems / staves / measures. On a hit, returns the
/// `ResolvedAnchorWire` encoding.
public func nativeResolveAnchor(scoreHandle: Int64, tapXmm: Double, tapYmm: Double) -> Data {
    guard let document = LayoutDocumentCache.value(for: scoreHandle) else { return Data() }
    let point = CGPoint(x: CGFloat(tapXmm * mmToPt), y: CGFloat(tapYmm * mmToPt))
    guard let r = document.resolveAnchor(at: point) else { return Data() }
    return ResolvedAnchorWire(
        measureIndex: Int32(r.measureIndex),
        tickInMeasure: Int32(r.tickInMeasure),
        partIndex: Int32(r.partIndex),
        staffIndexInPart: Int32(r.staffIndexInPart),
        dxSp: Double(r.dxSp),
        verticalOffsetSp: Double(r.verticalOffsetSp),
    ).encodeToData()
}

/// JNI entry point exposed via swift-java for the Kotlin
/// `SheetMusicJNI.nativeAnchorReferencePoint(...)` call site. Batched: resolves
/// each `(measure, tick, part, staff)` identity to its document-mm reference
/// point + staff-space (mm). One call resolves a whole annotation layer on the
/// hot display / reflow path. Identities that don't resolve emit an `spMm == 0`
/// sentinel, preserving positional alignment so the caller drops only that
/// stroke.
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
        guard let ref = document.anchorReferencePoint(
            measureIndex: Int(id.measureIndex),
            tickInMeasure: Int(id.tickInMeasure),
            partIndex: Int(id.partIndex),
            staffIndexInPart: Int(id.staffIndexInPart),
        ) else { return AnchorRefPointWire(xMm: 0, yMm: 0, spMm: 0) }
        return AnchorRefPointWire(
            xMm: Double(ref.point.x) * ptToMM,
            yMm: Double(ref.point.y) * ptToMM,
            spMm: Double(ref.sp) * ptToMM,
        )
    }
    return points.encodeToData()
}
