#if canImport(CoreGraphics)
    import CoreGraphics
#endif
import SheetMusicCore

/// One horizontal line of music. Contains one or more staves stacked
/// vertically and one or more parts.
public struct LayoutSystem: Sendable, Equatable {
    public let origin: CGPoint // in document coordinates
    public let size: CGSize
    public let measures: [LayoutMeasure]
    /// Per-staff baselines (top-left in system coordinates).
    public let staffOrigins: [CGPoint]
    /// `StaffAddress` for each entry in `staffOrigins`, in the same
    /// display order. Enables `StaffAddress → flat-index` conversion
    /// without re-visiting the originating `Score`.
    public let staffAddresses: [StaffAddress]
    /// Per-staff line geometry, parallel to `staffOrigins`. Empty means "every staff is standard five-line".
    ///
    /// The initializer takes this and `staffAddresses` without a default, because an empty value is not neutral:
    /// a rebuild that dropped them would silently revert the system to five-line geometry and lose its
    /// `StaffAddress → flat-index` map rather than failing. Rebuild an existing system with `addingSpanners(_:)` /
    /// `movedBy(dy:)` instead of re-invoking `init` — see `LayoutSystem+Rebuild.swift`.
    public let staffGeometries: [StaffLineGeometry]
    /// Part labels at the left edge of this system (empty on continuation
    /// systems per MuseScore convention).
    public let partLabels: [LayoutPartLabel]
    /// Brackets / braces drawn at the left edge of this system, one
    /// per `BracketItem` on each staff. Empty when no `Staff.brackets`
    /// were populated upstream.
    public let brackets: [LayoutBracket]
    /// Cross-measure spanner segments (slurs, voltas, hairpins, etc.)
    /// resolved after measure placement. Origins are in system coords.
    public let spanners: [LayoutElement]
    /// System-level spanner segments whose source is hidden but emitted
    /// because `showsInvisibleElements` is on. Drawn at 50 % opacity.
    public let invisibleSpanners: [LayoutElement]
    /// Chord/rest anchors of every measure flattened into one
    /// X-sorted index. Built deterministically from `measures` —
    /// callers MUST NOT supply a divergent value via `init`.
    /// Drives `ScoreHitTester.itemIDs(in:)` (marquee) and is the
    /// substrate for future O(log N) nearest-X lookups.
    public let eventColumns: [EventColumn]
    /// Largest `eventColumns[i].bbox.width / 2`, or 0 when empty.
    /// Used as the binary-search tolerance so a rect that intersects
    /// an event's bbox but lies outside its `centerX` still hits.
    public let maxBBoxHalfWidth: CGFloat
    /// Spatium (one staff space, equal to one quarter of the total
    /// staff height) used to compute event bboxes.
    /// Equals `StaffMetrics(staffSize:).sp` for the current staff size.
    public let sp: CGFloat
    /// Whether this system was laid out with the
    /// `ScoreViewOptions.showsInvisibleElements` toggle on. Renderers
    /// read this to decide per-note whether a hidden notehead should
    /// be grayed (50 %) or skipped outright — the chord's full note
    /// list is preserved in either case so stem / beam geometry stays
    /// stable across the toggle.
    public let showsInvisibleElements: Bool
    /// System-local x ranges where every staff line breaks: an `<HBox>`'s room between two measures, from where the
    /// measure before it ends to where the measure after it starts. MuseScore draws staff lines per measure, so a box
    /// has none. Sorted and non-overlapping; empty for every system without such room. Renderers split the lines
    /// through `BarLineGeometry.staffLineSegments(for:startX:staffEndX:)`.
    public let staffLineGaps: [Range<CGFloat>]

    public init(
        origin: CGPoint,
        size: CGSize,
        measures: [LayoutMeasure],
        staffOrigins: [CGPoint],
        staffAddresses: [StaffAddress],
        staffGeometries: [StaffLineGeometry],
        partLabels: [LayoutPartLabel],
        brackets: [LayoutBracket] = [],
        spanners: [LayoutElement],
        sp: CGFloat,
        invisibleSpanners: [LayoutElement] = [],
        showsInvisibleElements: Bool = false,
        staffLineGaps: [Range<CGFloat>] = [],
    ) {
        self.origin = origin
        self.size = size
        self.measures = measures
        self.staffOrigins = staffOrigins
        self.staffAddresses = staffAddresses
        self.staffGeometries = staffGeometries
        self.partLabels = partLabels
        self.brackets = brackets
        self.spanners = spanners
        self.sp = sp
        self.invisibleSpanners = invisibleSpanners
        self.showsInvisibleElements = showsInvisibleElements
        self.staffLineGaps = staffLineGaps
        let columns = Self.buildEventColumns(measures: measures, sp: sp)
        eventColumns = columns
        maxBBoxHalfWidth = columns
            .map { $0.bbox.width / 2 }
            .max() ?? 0
    }

    /// `base` with a new `origin` and `spanners`, for the two rebuilds in `LayoutSystem+Rebuild.swift`.
    ///
    /// It takes `base.eventColumns` instead of rebuilding them: they are a function of `measures` and `sp` alone, and
    /// neither changes here. Rebuilding them on every copy — packing moves each system down once, and three
    /// spanner passes append to it — was a fifth of a warm relayout. Listing every stored property keeps the
    /// compiler checking that a new field is carried forward.
    init(rebuilding base: LayoutSystem, origin: CGPoint, spanners: [LayoutElement]) {
        self.origin = origin
        size = base.size
        measures = base.measures
        staffOrigins = base.staffOrigins
        staffAddresses = base.staffAddresses
        staffGeometries = base.staffGeometries
        partLabels = base.partLabels
        brackets = base.brackets
        self.spanners = spanners
        invisibleSpanners = base.invisibleSpanners
        eventColumns = base.eventColumns
        maxBBoxHalfWidth = base.maxBBoxHalfWidth
        sp = base.sp
        showsInvisibleElements = base.showsInvisibleElements
        staffLineGaps = base.staffLineGaps
    }

    /// Flat index (= index into `staffOrigins`) for the given address.
    /// Returns `nil` when the address is not present in this system.
    public func flatIndex(for address: StaffAddress) -> Int? {
        staffAddresses.firstIndex(of: address)
    }

    /// Line geometry for the staff at `index` in `staffOrigins`.
    /// Falls back to a standard five-line staff.
    public func geometry(atFlatIndex index: Int) -> StaffLineGeometry {
        staffGeometries.indices.contains(index)
            ? staffGeometries[index]
            : .standard
    }

    /// System-local X and Y span of the vertical stroke every renderer
    /// draws at a system's left edge — MuseScore's system-begin barline
    /// (`MeasureLayout::createSystemBeginBarLine`,
    /// `rendering/score/measurelayout.cpp:2843`). `nil` when the system
    /// has no staves.
    ///
    /// MuseScore builds it out of ordinary `BarLine` elements — one per
    /// staff, each laid out by `TLayout::layoutBarLine` — so its two
    /// ends obey the same per-staff rule `LayoutElement.barLine` already
    /// does: the top staff's top line, the bottom staff's bottom line,
    /// each replaced by ±2 sp about the single line when that staff
    /// draws only one (`dom/barline.cpp:256-291`,
    /// `BARLINE_SPAN_1LINESTAFF_FROM`/`_TO`). Deriving the bottom from
    /// `StaffMetrics.staffHeight` instead leaves the stroke hanging 4 sp
    /// past a one-line bottom staff; deriving it from that staff's
    /// (zero) height alone would collapse a single one-line staff's
    /// stroke to a dot.
    ///
    /// The playback cursor and the loop highlight take their vertical
    /// span from here too. They want "the system's staves, top to
    /// bottom", which is the same question — and the same one-line
    /// answer keeps them visible: a rect sized by that staff's (zero)
    /// drawn height would have no height at all on a score whose
    /// systems are a single one-line staff.
    public var systemStartBarLine: (x: CGFloat, top: CGFloat, bottom: CGFloat)? {
        guard let first = staffOrigins.first,
              let last = staffOrigins.last else { return nil }
        let topSpan = geometry(atFlatIndex: 0).barLineSpanY(sp: sp)
        let bottomSpan = geometry(atFlatIndex: staffOrigins.count - 1)
            .barLineSpanY(sp: sp)
        return (first.x, first.y + topSpan.top, last.y + bottomSpan.bottom)
    }

    /// Subtype + system-local origin X of the rightmost barline in the
    /// last measure. Returned to renderers that need to know where the
    /// system's terminal barline lives — e.g. to clip staff lines so
    /// they end flush with it instead of extending through the
    /// trailing-barline gutter (≈ 0.5 sp) baked into each measure's
    /// width. `subtype == nil` means a default thin barline; an empty
    /// `measures` array (defensive — never expected in practice)
    /// returns `nil`.
    public var trailingBarLine: (subtype: String?, x: CGFloat)? {
        guard let last = measures.last else { return nil }
        return BarLineGeometry.trailingBarLine(of: last)
    }

    private static func buildEventColumns(
        measures: [LayoutMeasure],
        sp: CGFloat,
    ) -> [EventColumn] {
        var result: [EventColumn] = []
        for measure in measures {
            let mx = measure.origin.x
            let my = measure.origin.y
            for el in measure.elements {
                switch el {
                case let .chord(notes, _, _, _, _, _, _, voiceIndex, _, _, _):
                    guard !notes.isEmpty else { continue }
                    let xs = notes.map { mx + $0.origin.x }
                    let ys = notes.map { my + $0.origin.y }
                    guard let minX = xs.min(),
                          let maxX = xs.max(),
                          let minY = ys.min(),
                          let maxY = ys.max(),
                          let topNote = notes.min(by: {
                              $0.origin.y < $1.origin.y
                          })
                    else { continue }
                    // Matches `ScoreHitTester.hitNote`'s hit radius.
                    let pad: CGFloat = sp * 1.2
                    let bbox = CGRect(
                        x: minX - pad,
                        y: minY - pad,
                        width: (maxX - minX) + pad * 2,
                        height: (maxY - minY) + pad * 2,
                    )
                    result.append(EventColumn(
                        id: .note(topNote.noteID),
                        voiceIndex: voiceIndex,
                        centerX: (minX + maxX) / 2,
                        centerY: (minY + maxY) / 2,
                        bbox: bbox,
                    ))
                case .rest, .measureRepeat:
                    // A measure repeat stands in its bar's rest column (`LayoutElement.restSlot`).
                    guard let (restID, origin, voiceIndex, _) = el.restSlot else { continue }
                    let cx = mx + origin.x
                    let cy = my + origin.y
                    // Matches `ScoreHitTester.hitRest`'s half-extents.
                    let halfW: CGFloat = sp * 1.8
                    let halfH: CGFloat = sp * 2.5
                    let bbox = CGRect(
                        x: cx - halfW, y: cy - halfH,
                        width: halfW * 2, height: halfH * 2,
                    )
                    result.append(EventColumn(
                        id: .rest(restID),
                        voiceIndex: voiceIndex,
                        centerX: cx,
                        centerY: cy,
                        bbox: bbox,
                    ))
                default:
                    continue
                }
            }
        }
        result.sort { $0.centerX < $1.centerX }
        return result
    }
}

public struct LayoutPartLabel: Sendable, Equatable {
    public let text: String
    public let origin: CGPoint
    /// The part name this label draws (`ScoreElementID.partName`) — the identity a click on it selects. `nil` for a
    /// label built by hand without one, which is then drawn but not selectable, as any element without an identity.
    public let elementID: ScoreElementID?

    public init(text: String, origin: CGPoint, elementID: ScoreElementID? = nil) {
        self.text = text
        self.origin = origin
        self.elementID = elementID
    }
}

public struct LayoutBracket: Sendable, Equatable {
    public let type: BracketType
    /// Top edge of the topmost spanned staff (system coords).
    public let topY: CGFloat
    /// Bottom edge of the bottommost spanned staff (system coords).
    public let bottomY: CGFloat
    /// Horizontal nesting column. 0 sits closest to the staff; higher
    /// values stack further left.
    public let column: Int
    /// Number of staves spanned (after end-of-score clamping). Used by
    /// the brace renderer to select the SMuFL variant glyph and the
    /// per-span horizontal magnification — see MuseScore's
    /// `engraving/dom/bracket.cpp::Bracket::computeMagx`.
    public let staffCount: Int

    public init(
        type: BracketType,
        topY: CGFloat,
        bottomY: CGFloat,
        column: Int,
        staffCount: Int = 1,
    ) {
        self.type = type
        self.topY = topY
        self.bottomY = bottomY
        self.column = column
        self.staffCount = max(staffCount, 1)
    }
}
