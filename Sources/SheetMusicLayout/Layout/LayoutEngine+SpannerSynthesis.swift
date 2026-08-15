#if canImport(CoreGraphics)
    import CoreGraphics
#endif
import SheetMusicCore

/// The slice of a measure's geometry a spanner edge needs, so the edge
/// helpers can run in either coordinate space: against a finished
/// `LayoutMeasure` (system-local, `originX` = the measure's X) in the
/// `attachSpanners` post-pass, and against a pass-1
/// `UntranslatedMeasure` (measure-local, `originX` = 0) during
/// `buildSystem`.
struct SpannerMeasureGeometry {
    let originX: CGFloat
    let width: CGFloat
    let tickColumns: [Int: CGFloat]
    let dynamicExtents: [LayoutMeasure.DynamicExtent]

    init(
        originX: CGFloat,
        width: CGFloat,
        tickColumns: [Int: CGFloat],
        dynamicExtents: [LayoutMeasure.DynamicExtent] = [],
    ) {
        self.originX = originX
        self.width = width
        self.tickColumns = tickColumns
        self.dynamicExtents = dynamicExtents
    }

    init(_ measure: LayoutMeasure) {
        self.init(
            originX: measure.origin.x,
            width: measure.width,
            tickColumns: measure.tickColumns,
            dynamicExtents: measure.dynamicExtents,
        )
    }
}

extension LayoutElement {
    var isSpannerSegment: Bool {
        if case .spannerSegment = self { return true }
        return false
    }
}

extension LayoutEngine {
    /// Line spanners laid out in pass 1 so `SkylineAutoplacePass` can
    /// place them, rather than in the `attachSpanners` post-pass.
    ///
    /// This is the set MuseScore runs through `processLines` inside
    /// `SystemLayout::layoutSystemElements` and then adds to the staff
    /// skyline (`systemlayout.cpp:1902`). Slurs, vibrato and trills map
    /// to no `ShapeItemKind` at all, and voltas are top-staff /
    /// system-scoped — all four keep the post-pass.
    static func isPassPlacedSpanner(
        kind: LayoutElement.SpannerKind,
    ) -> Bool {
        switch kind {
        case .hairpinOpen, .hairpinClose, .hairpinLine,
             .pedal, .ottava, .textLine, .palmMute, .letRing:
            true
        case .slur, .vibrato, .trill, .volta:
            false
        }
    }

    /// Emit one `.spannerSegment` per pass-placed anchor overlapping
    /// this system, into the per-staff pass-1 buffer of the measure the
    /// segment starts in.
    ///
    /// **Coordinates.** X is measure-local to that start measure —
    /// `SkylineAutoplacePass` adds the measure's `xOffsets` entry when
    /// it builds the shape, and pass 2 adds the same `xCursor` when it
    /// lifts the segment into system coords. `toOrigin.x` routinely
    /// runs past the measure's own width; nothing clips it, it is one
    /// rect spanning several columns. Y is staff-local (staff top at
    /// `sp * 2`), matching everything else `placeMeasureElements`
    /// emits.
    ///
    /// **Clipping replaces the split.** `attachSpanners` needs three
    /// branches — start system, middle systems, end system — because it
    /// walks a spanner across the whole document. Here the system's
    /// `measureRange` is given, so clipping the anchor to it yields the
    /// one segment this system draws, and `continuesLeft` /
    /// `continuesRight` fall out of whether the anchor's own ends
    /// survived the clip.
    ///
    /// Must run BEFORE the autoplace `do`-block in `buildSystem`: that
    /// block writes its result back only where the staff already has a
    /// buffer entry, so a segment inserted afterwards into a staff with
    /// no entry would be dropped without a word.
    static func synthesizeLineSpanners( // swiftlint:disable:this function_parameter_count
        into untranslated: inout [UntranslatedMeasure],
        anchors: [SpannerAnchor],
        measureRange: Range<Int>,
        staffCount: Int,
        // Per-staff line geometry, parallel to the staff index used by
        // `SpannerAnchor.startStaff`. A short entry (or an out-of-range
        // staff) falls back to five lines.
        staffGeometries: [StaffLineGeometry],
        xOffsets: [CGFloat],
        systemWidth: CGFloat,
        ottavaNumbersOnly: Bool,
        metrics: StaffMetrics,
    ) {
        guard !anchors.isEmpty, !untranslated.isEmpty,
              untranslated.count == xOffsets.count
        else { return }
        let localIndex = localIndexByMeasure(untranslated)
        let staffTopLocal = metrics.sp * 2
        // `collectDynamicExtents` is not free and a hairpin queries the
        // same (measure, staff) twice; memoize per system.
        var extentCache: [ExtentKey: [LayoutMeasure.DynamicExtent]] = [:]
        // Mirrors `attachSpanners`: a continued edge uses the system
        // margin rather than a measure column.
        let continuationInset = metrics.sp * 2

        for anchor in anchors {
            let kind = layoutKind(
                anchor: anchor, ottavaNumbersOnly: ottavaNumbersOnly,
            )
            guard isPassPlacedSpanner(kind: kind),
                  anchor.startStaff >= 0, anchor.startStaff < staffCount,
                  let clip = clipToSystem(
                      anchor: anchor, measureRange: measureRange,
                  ),
                  let startLocal = localIndex[clip.startMeasure],
                  let endLocal = localIndex[clip.endMeasure],
                  startLocal < untranslated.count,
                  endLocal < untranslated.count
            else { continue }

            let edges = systemEdges(
                anchor: anchor, clip: clip,
                start: geometry(
                    untranslated[startLocal],
                    originX: xOffsets[startLocal],
                    staffIndex: anchor.startStaff, metrics: metrics,
                    cache: &extentCache,
                ),
                end: geometry(
                    untranslated[endLocal],
                    originX: xOffsets[endLocal],
                    staffIndex: anchor.endStaff, metrics: metrics,
                    cache: &extentCache,
                ),
                systemWidth: systemWidth,
                continuationInset: continuationInset,
                metrics: metrics,
            )
            let y = staffTopLocal + defaultBandOffsetY(
                belowStaff: isBelowStaff(anchor: anchor),
                lineGeometry: geometry(staffGeometries, anchor.startStaff),
                metrics: metrics,
            )
            // Back into the start measure's own frame — the pass and
            // pass 2 both re-add `xOffsets[startLocal]`.
            let localOrigin = xOffsets[startLocal]
            untranslated[startLocal]
                .perStaffElements[anchor.startStaff, default: []]
                .append(.spannerSegment(
                    kind: kind,
                    fromOrigin: CGPoint(
                        x: edges.from - localOrigin, y: y,
                    ),
                    toOrigin: CGPoint(x: edges.to - localOrigin, y: y),
                    continuesLeft: clip.continuesLeft,
                    continuesRight: clip.continuesRight,
                    text: layoutLabel(anchor: anchor),
                ))
        }
    }

    /// Line geometry for `staffIndex`, falling back to five lines when
    /// the caller supplied none (or a shorter array than the staff
    /// count) — the same tolerance `LayoutSystem.geometry(atFlatIndex:)`
    /// gives, so a caller that has not been taught about line counts
    /// keeps its old behavior instead of trapping.
    private static func geometry(
        _ staffGeometries: [StaffLineGeometry], _ staffIndex: Int,
    ) -> StaffLineGeometry {
        staffGeometries.indices.contains(staffIndex)
            ? staffGeometries[staffIndex]
            : .standard
    }

    /// The segment's two edges in SYSTEM-local X. A clipped end uses
    /// the system margin — the same inset `attachSpanners` gives a
    /// continued line — instead of a measure column, since the column
    /// it would want lives in another system.
    private static func systemEdges( // swiftlint:disable:this function_parameter_count
        anchor: SpannerAnchor,
        clip: SystemClip,
        start: SpannerMeasureGeometry,
        end: SpannerMeasureGeometry,
        systemWidth: CGFloat,
        continuationInset: CGFloat,
        metrics: StaffMetrics,
    ) -> (from: CGFloat, to: CGFloat) {
        let from = clip.continuesLeft
            ? continuationInset
            : snappedHairpinStartX(
                startX(
                    anchor: anchor, measure: start, metrics: metrics,
                ),
                anchor: anchor, measure: start, metrics: metrics,
            )
        let to = clip.continuesRight
            ? systemWidth - continuationInset
            : snappedHairpinEndX(
                endX(anchor: anchor, measure: end, metrics: metrics),
                anchor: anchor, measure: end, metrics: metrics,
                notBefore: from,
            )
        return (from, to)
    }

    /// Lift the synthesized segments back out of the pass-1 buffer and
    /// into system coordinates.
    ///
    /// They were parked in the measure they start in so the skyline
    /// pass would see them beside that staff's other annotations, but a
    /// segment routinely spans several measures and belongs to
    /// `LayoutSystem.spanners`. Running here rather than inside pass 2
    /// also covers multi-measure-rest placeholders, whose branch of
    /// pass 2 never reads `perStaffElements` at all.
    ///
    /// `xCursor` walks the same `partLabelWidth + Σ width` sequence as
    /// pass 1's `xOffsets` and pass 2's own cursor — that identity is
    /// what makes the measure-local X round-trip exact.
    static func extractLineSpanners(
        from untranslated: inout [UntranslatedMeasure],
        staffOrigins: [CGPoint],
        partLabelWidth: CGFloat,
        metrics: StaffMetrics,
    ) -> [LayoutElement] {
        var out: [LayoutElement] = []
        var xCursor = partLabelWidth
        for idx in untranslated.indices {
            // Sorted so the emitted order is staff-by-staff and
            // reproducible; `Dictionary` iteration order is not.
            for staffIdx in untranslated[idx]
                .perStaffElements.keys.sorted()
            {
                guard staffIdx < staffOrigins.count,
                      let els = untranslated[idx]
                          .perStaffElements[staffIdx],
                          els.contains(where: \.isSpannerSegment)
                else { continue }
                // Same staff-local → system translation pass 2 applies
                // to everything else in this buffer.
                let dy = staffOrigins[staffIdx].y - metrics.sp * 2
                var kept: [LayoutElement] = []
                kept.reserveCapacity(els.count)
                for el in els {
                    guard case let .spannerSegment(
                        kind, from, to, continuesLeft, continuesRight,
                        text,
                    ) = el else {
                        kept.append(el)
                        continue
                    }
                    out.append(.spannerSegment(
                        kind: kind,
                        fromOrigin: CGPoint(
                            x: from.x + xCursor, y: from.y + dy,
                        ),
                        toOrigin: CGPoint(
                            x: to.x + xCursor, y: to.y + dy,
                        ),
                        continuesLeft: continuesLeft,
                        continuesRight: continuesRight,
                        text: text,
                    ))
                }
                untranslated[idx].perStaffElements[staffIdx] = kept
            }
            xCursor += untranslated[idx].width
        }
        return out
    }

    /// The portion of a spanner this system draws.
    struct SystemClip {
        let startMeasure: Int
        let endMeasure: Int
        let continuesLeft: Bool
        let continuesRight: Bool
    }

    /// The portion of `anchor` this system draws, or nil when it does
    /// not reach into `measureRange` at all.
    private static func clipToSystem(
        anchor: SpannerAnchor, measureRange: Range<Int>,
    ) -> SystemClip? {
        guard !measureRange.isEmpty else { return nil }
        let last = measureRange.upperBound - 1
        // `endAnchor` can point past the final measure; treat a
        // backwards span as a zero-length one at its start.
        let anchorEnd = max(anchor.startMeasure, anchor.endMeasure)
        guard anchor.startMeasure <= last,
              anchorEnd >= measureRange.lowerBound
        else { return nil }
        return SystemClip(
            startMeasure: max(
                anchor.startMeasure, measureRange.lowerBound,
            ),
            endMeasure: min(anchorEnd, last),
            continuesLeft: anchor.startMeasure < measureRange.lowerBound,
            continuesRight: anchorEnd > last,
        )
    }

    /// Global measure index → index into `untranslated`. A
    /// multi-measure-rest placeholder stands in for its whole run, so
    /// every measure the run swallowed maps to the run's own entry —
    /// otherwise a spanner starting inside a collapsed run would find
    /// no measure and vanish.
    private static func localIndexByMeasure(
        _ untranslated: [UntranslatedMeasure],
    ) -> [Int: Int] {
        var map: [Int: Int] = [:]
        for (localIdx, um) in untranslated.enumerated() {
            let span = max(1, um.multiMeasureRestCount ?? 1)
            for offset in 0 ..< span {
                map[um.measureIdx + offset] = localIdx
            }
        }
        return map
    }

    struct ExtentKey: Hashable {
        let measureIdx: Int
        let staffIndex: Int
    }

    /// The dynamic extents are the reason this takes a staff: hairpin
    /// snapping (`snappedHairpinStartX` / `…EndX`) reads them, and in
    /// pass 1 they have to be derived from the staff's own buffer
    /// rather than from `LayoutMeasure.dynamicExtents`, which pass 2
    /// has not built yet. Both compute the same measure-local spans
    /// from the same elements — pass 2 deliberately collects them
    /// before aggregation, while the owning staff is still known.
    private static func geometry(
        _ um: UntranslatedMeasure, originX: CGFloat,
        staffIndex: Int, metrics: StaffMetrics,
        cache: inout [ExtentKey: [LayoutMeasure.DynamicExtent]],
    ) -> SpannerMeasureGeometry {
        let key = ExtentKey(
            measureIdx: um.measureIdx, staffIndex: staffIndex,
        )
        let extents: [LayoutMeasure.DynamicExtent]
        if let cached = cache[key] {
            extents = cached
        } else {
            extents = collectDynamicExtents(
                in: um.perStaffElements[staffIndex] ?? [],
                staffIndex: staffIndex,
                tickColumns: um.tickCols,
                metrics: metrics,
            )
            cache[key] = extents
        }
        return SpannerMeasureGeometry(
            originX: originX,
            width: um.width,
            tickColumns: um.tickCols,
            dynamicExtents: extents,
        )
    }
}
