import SheetMusicFoundation
import Wirelet

// Wire codecs for the annotation anchor primitives (freehand ink ↔ musical
// position). Folino's shared anchoring core turns `ResolvedAnchorWire` into a
// Domain `MusicalAnchor` and bakes the stroke; these types carry ONLY geometry
// — no ink, no bake — so ssm stays Folino-agnostic. `@WireFormat` generates the
// matching Kotlin codecs via the wirelet Gradle task.

/// Output of `nativeResolveAnchor`: a musical position resolved from a
/// document-mm point, in the cached (filtered) layout's address space. The six
/// fields map 1:1 to Domain's `MusicalAnchor` and to `SheetMusicLayout`'s
/// `ResolvedAnchor`. `dxSp` / `verticalOffsetSp` are unit-neutral sp-multiples
/// (a pt/pt ratio == the same mm/mm ratio), so they need no mm conversion.
@WireFormat
public struct ResolvedAnchorWire: Equatable {
    public let measureIndex: Int32
    public let tickInMeasure: Int32
    public let partIndex: Int32
    public let staffIndexInPart: Int32
    public let dxSp: Double
    public let verticalOffsetSp: Double

    public init(
        measureIndex: Int32, tickInMeasure: Int32, partIndex: Int32, staffIndexInPart: Int32,
        dxSp: Double, verticalOffsetSp: Double,
    ) {
        self.measureIndex = measureIndex
        self.tickInMeasure = tickInMeasure
        self.partIndex = partIndex
        self.staffIndexInPart = staffIndexInPart
        self.dxSp = dxSp
        self.verticalOffsetSp = verticalOffsetSp
    }
}

/// One element of `nativeAnchorReferencePoint`'s input array: the identity part
/// of a stored anchor (no sp offsets — the caller composes those). A strict
/// subset of `ResolvedAnchorWire`'s identity fields.
@WireFormat
public struct AnchorIdentityWire: Equatable {
    public let measureIndex: Int32
    public let tickInMeasure: Int32
    public let partIndex: Int32
    public let staffIndexInPart: Int32

    public init(measureIndex: Int32, tickInMeasure: Int32, partIndex: Int32, staffIndexInPart: Int32) {
        self.measureIndex = measureIndex
        self.tickInMeasure = tickInMeasure
        self.partIndex = partIndex
        self.staffIndexInPart = staffIndexInPart
    }
}

/// One element of `nativeAnchorReferencePoint`'s output array: the anchor's
/// document reference point + staff-space, in millimetres (both are lengths, so
/// converted pt→mm at the bridge). `spMm > 0` when resolved; `spMm == 0` is the
/// sentinel for an anchor that did not resolve in this layout (out-of-range
/// measure / hidden staff) — the caller drops just that stroke while keeping the
/// array positionally aligned with its input identities.
@WireFormat
public struct AnchorRefPointWire: Equatable {
    public let xMm: Double
    public let yMm: Double
    public let spMm: Double

    public init(xMm: Double, yMm: Double, spMm: Double) {
        self.xMm = xMm
        self.yMm = yMm
        self.spMm = spMm
    }
}
