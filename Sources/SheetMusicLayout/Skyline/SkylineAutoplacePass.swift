#if canImport(CoreGraphics)
    import CoreGraphics
#endif
import SheetMusicCore

/// MuseScore's skyline autoplace, applied to one staff of one system.
///
/// Mirrors `SystemLayout::layoutSystemElements`
/// (`src/engraving/rendering/score/systemlayout.cpp`): lay every item
/// out at its default position, then walk the annotation categories
/// from closest-to-staff outward, and for each one measure the vertical
/// distance from its shape to the skyline accumulated so far, push it
/// AWAY from the staff when that distance is less than the item's
/// `minDistance`, and add its shape to the skyline.
///
/// The pass never moves an element toward the staff, so author
/// `<offset>` values (already baked into `origin.y` at emission) and
/// the per-tick chord-avoidance already applied to dynamics, fermatas
/// all survive as better-than-default starting points.
///
/// **Inert categories.** The `.hairpin` / `.pedal` / `.ottava` /
/// `.textLine` / `.volta` / `.marker` / `.jump` entries in `categories`
/// find nothing today: spanner segments are synthesized in a post-pass
/// (`LayoutEngine+Spanners`) into `LayoutSystem.spanners`, and markers
/// and jumps in pass 2 into `LayoutMeasure.markers` / `.jumps` — none
/// of them ever land in the per-staff pass-1 buffer this operates on.
/// They are listed so the ordering is complete when those emissions
/// move. **Before routing any of them into the buffer, teach
/// `LayoutEngine.translate` to shift them**, or the writeback below
/// silently drops their `dy`. `.spannerSegment` is done; `.marker` and
/// `.jump` are still in its no-op case list.
///
/// Being inert is also what makes the ordering unverifiable by test or
/// corpus, so it has to be read off the C++ rather than inferred — see
/// the citation table on `categories`.
enum SkylineAutoplacePass {
    /// Address of one element inside the per-staff measure buffer.
    private struct Address {
        let measure: Int
        let index: Int
    }

    /// One category laid out as a unit, in MuseScore's order.
    private struct Category {
        let kinds: [ShapeItemKind]
        let grouping: Grouping
    }

    private enum Grouping {
        /// Each element gets its own `dy`.
        case individual
        /// One `dy` for every element in the category on this staff.
        case wholeStaff
        /// One `dy` per side and verse row, carried in placement metadata.
        case lyricVerses
    }

    /// MuseScore's order, read off `SystemLayout::layoutSystemElements`
    /// (`systemlayout.cpp`):
    ///
    ///     dynamics + hairpins  :1276   (layoutDynamicExpressionAndHairpins)
    ///     all other spanners   :1278   → .textLine / palmMute / letRing
    ///     measure numbers      :1280
    ///     ottavas              :1294
    ///     pedals               :1295   (processLines align = true)
    ///     lyrics               :1297
    ///     harmonies            :1305
    ///     staff text           :1308
    ///     system text          :1324
    ///     voltas               :1328
    ///     rehearsal marks      :1330
    ///     tempo text           :1335
    ///
    /// Two deliberate departures, both pre-existing: `.staffText` and
    /// `.systemText` share one entry (MuseScore separates them, and
    /// splitting would reorder skyline accumulation for reasons
    /// unrelated to any known defect), and `.dynamics` is `.wholeStaff`
    /// where MuseScore aligns per snapping chain
    /// (`alignmentlayout.cpp:94`).
    ///
    /// `.hairpin` is `.individual` and separate from `.dynamics`: the
    /// pair is exempt in `shouldIgnoreEachOther`, so a hairpin never
    /// sees a dynamic in the skyline anyway, and sharing the group's
    /// single `dy` would let one ledger-line note under a hairpin drag
    /// every dynamic on the staff down with it.
    private static let categories: [Category] = [
        Category(kinds: [.dynamics], grouping: .wholeStaff),
        Category(kinds: [.hairpin], grouping: .individual),
        Category(kinds: [.textLine], grouping: .individual),
        Category(kinds: [.measureNumber], grouping: .individual),
        Category(kinds: [.ottava], grouping: .individual),
        // MuseScore equalizes pedal Y across a staff after autoplacing
        // each segment (`processLines(..., align: true)`); the
        // max-over-group `dy` reproduces that.
        Category(kinds: [.pedal], grouping: .wholeStaff),
        Category(
            kinds: [.lyrics, .lyricsMelisma, .lyricHyphen],
            grouping: .lyricVerses,
        ),
        Category(kinds: [.harmony], grouping: .individual),
        Category(
            kinds: [.staffText, .systemText], grouping: .individual,
        ),
        Category(kinds: [.volta], grouping: .individual),
        Category(kinds: [.rehearsalMark], grouping: .individual),
        Category(kinds: [.tempo], grouping: .individual),
        Category(kinds: [.marker, .jump], grouping: .individual),
    ]

    /// Autoplace one staff of one system in place.
    ///
    /// - Parameters:
    ///   - measures: `measures[i]` is one measure's element array for
    ///     ONE staff, in staff-local Y.
    ///   - xOffsets: `xOffsets[i]` is that measure's accumulated
    ///     system X. Must have the same count as `measures`.
    ///   - systemRightX: right edge of the last measure, so the
    ///     synthetic staff rect spans the whole system. Deriving it
    ///     from `xOffsets` alone would stop at the LAST measure's left
    ///     edge and leave that measure without a staff to clear.
    ///   - staffTop: Y of this staff's own TOP drawn line.
    ///   - staffBottom: Y of its own BOTTOM drawn line — equal to
    ///     `staffTop` on a one-line staff. `Skyline`'s north / south
    ///     filter measures "pokes outside the staff" against these, so
    ///     they must be the DRAWN lines, not `staffMidY ∓ 2 sp`: that
    ///     is the five-line REFERENCE band `step` is expressed in, and
    ///     it overshoots any shorter staff.
    static func run(
        measures: inout [[LayoutElement]],
        xOffsets: [CGFloat],
        systemRightX: CGFloat,
        staffTop: CGFloat,
        staffBottom: CGFloat,
        metrics: StaffMetrics,
    ) {
        guard measures.count == xOffsets.count, !measures.isEmpty
        else { return }
        // `resolveSide` splits at the middle of the same band, so a
        // shorter staff's above/below test tracks its drawn ink.
        let staffMidY = (staffTop + staffBottom) / 2
        var skyline = Skyline(staffTop: staffTop, staffBottom: staffBottom)
        var lyricRows = LyricRowBands()

        // Stable per-(staff, system) identity for the ignore rules.
        var ids: [[Int]] = []
        var next = 0
        for m in measures {
            var row: [Int] = []
            for _ in m.indices {
                row.append(next)
                next += 1
            }
            ids.append(row)
        }

        // 1. Base skyline: the staff itself + every non-autoplaced
        //    element in the system.
        let xMin = xOffsets.first ?? 0
        skyline.add(LayoutShape(rects: [LayoutElementShape.staffRect(
            xMin: xMin, xMax: max(xMin, systemRightX),
            staffTop: staffTop, staffBottom: staffBottom,
        )]))
        for (mIdx, elements) in measures.enumerated() {
            for (i, el) in elements.enumerated() {
                guard let kind = LayoutElementShape.kind(of: el),
                      !AutoplaceRules.isAutoplaced(kind) || el.textPlacement?.autoplace == false,
                      let shape = LayoutElementShape.shape(
                          for: el, id: ids[mIdx][i],
                          xOffset: xOffsets[mIdx], metrics: metrics,
                      )
                else { continue }
                skyline.add(shape)
                if let row = el.textPlacement?.row, let box = shape.bbox {
                    lyricRows.add(box, to: row)
                }
            }
        }

        // 2. Autoplace each category in order.
        for category in categories {
            let addresses = collect(
                kinds: category.kinds, in: measures,
            )
            guard !addresses.isEmpty else { continue }
            let groups = group(
                addresses, by: category.grouping, in: measures,
                sp: metrics.sp,
            )
            var lyricObstacles: [LayoutShape] = []
            if case .lyricVerses = category.grouping {
                lyricObstacles = lyricStemObstacles(measures: measures, ids: ids, xOffsets: xOffsets, metrics: metrics)
            }
            for members in groups {
                apply(
                    group: members, measures: &measures, ids: ids,
                    xOffsets: xOffsets, staffMidY: staffMidY,
                    metrics: metrics, extraObstacles: lyricObstacles, lyricRows: &lyricRows, skyline: &skyline,
                )
            }
        }
    }
}

extension SkylineAutoplacePass {
    private static func collect(
        kinds: [ShapeItemKind], in measures: [[LayoutElement]],
    ) -> [Address] {
        var result: [Address] = []
        for (mIdx, elements) in measures.enumerated() {
            for (i, el) in elements.enumerated() {
                guard let kind = LayoutElementShape.kind(of: el),
                      kinds.contains(kind), el.textPlacement?.autoplace != false else { continue }
                result.append(Address(measure: mIdx, index: i))
            }
        }
        return result
    }

    private static func group(
        _ addresses: [Address], by grouping: Grouping,
        in measures: [[LayoutElement]], sp: CGFloat,
    ) -> [[Address]] {
        switch grouping {
        case .individual:
            return addresses.map { [$0] }
        case .wholeStaff:
            return [addresses]
        case .lyricVerses:
            return lyricVerseGroups(addresses, in: measures, sp: sp)
        }
    }

    /// Process the staff-nearest row first on each side. Metadata, never Y, identifies
    /// generated rows. The fallback supports older manually constructed layout values.
    private static func lyricVerseGroups(
        _ addresses: [Address], in measures: [[LayoutElement]], sp: CGFloat,
    ) -> [[Address]] {
        var buckets: [LyricRow: [Address]] = [:]
        for address in addresses {
            let element = measures[address.measure][address.index]
            let row: LyricRow
            if let explicit = element.textPlacement?.row {
                row = explicit
            } else if case let .textMark(.lyrics(_, verse, _, _), _, _) = element {
                row = LyricRow(side: .below, verse: verse)
            } else {
                let y = LayoutEngine.elementYPoints(element).first ?? 0
                let offset: CGFloat = if case .lyricsMelisma = element {
                    LayoutEngine.melismaLineYOffset(sp: sp)
                } else { 0 }
                let candidates = addresses.compactMap { candidate -> (Int, CGFloat)? in
                    guard case let .textMark(
                        .lyrics(_, verse, _, _),
                        _,
                        point,
                    ) = measures[candidate.measure][candidate.index] else { return nil }
                    return (verse, abs(point.y + offset - y))
                }
                row = LyricRow(side: .below, verse: candidates.min { $0.1 < $1.1 }?.0 ?? 0)
            }
            buckets[row, default: []].append(address)
        }
        return buckets.keys.sorted {
            if $0.side != $1.side { return $0.side == .above }
            return $0.side == .above ? $0.verse > $1.verse : $0.verse < $1.verse
        }.compactMap { buckets[$0] }
    }

    /// Compute one `dy` for the group (max over its members), apply it
    /// to every member, then register the moved shapes.
    private static func apply( // swiftlint:disable:this function_parameter_count
        group: [Address], measures: inout [[LayoutElement]],
        ids: [[Int]], xOffsets: [CGFloat],
        staffMidY: CGFloat, metrics: StaffMetrics,
        extraObstacles: [LayoutShape],
        lyricRows: inout LyricRowBands,
        skyline: inout Skyline,
    ) {
        var shapes: [(address: Address, shape: LayoutShape, kind: ShapeItemKind, side: Placement?)] = []
        for a in group {
            let el = measures[a.measure][a.index]
            guard let kind = LayoutElementShape.kind(of: el),
                  let shape = LayoutElementShape.shape(
                      for: el, id: ids[a.measure][a.index],
                      xOffset: xOffsets[a.measure], metrics: metrics,
                  )
            else { continue }
            shapes.append((a, shape, kind, el.textPlacement?.side))
        }
        guard !shapes.isEmpty else { return }

        var querySkyline = skyline
        for obstacle in extraObstacles {
            querySkyline.add(obstacle)
        }
        var dy = requiredShift(
            shapes: shapes, staffMidY: staffMidY,
            metrics: metrics, skyline: querySkyline,
        )
        if let first = group.first,
           let row = measures[first.measure][first.index].textPlacement?.row
        {
            let box = shapes.compactMap(\.shape.bbox).reduce(CGRect.null) { $0.union($1) }
            let rowShift = lyricRows.outwardShift(
                for: row, box: box, minimumGap: AutoplaceRules.minDistance(for: .lyrics, sp: metrics.sp),
            )
            dy = row.side == .above ? min(dy, rowShift) : max(dy, rowShift)
            lyricRows.add(box.offsetBy(dx: 0, dy: dy), to: row)
        }
        for entry in shapes {
            let m = entry.address.measure
            let i = entry.address.index
            if dy != 0 {
                measures[m][i] = LayoutEngine.translate(
                    element: measures[m][i], dy: dy,
                )
            }
            skyline.add(entry.shape.translatedY(dy))
        }
    }

    private static func lyricStemObstacles(
        measures: [[LayoutElement]], ids: [[Int]], xOffsets: [CGFloat], metrics: StaffMetrics,
    ) -> [LayoutShape] {
        var shapes: [LayoutShape] = []
        for (measure, elements) in measures.enumerated() {
            for (index, element) in elements.enumerated() {
                if let shape = LayoutElementShape.lyricStemClearance(
                    for: element, id: ids[measure][index], xOffset: xOffsets[measure], metrics: metrics,
                ) { shapes.append(shape) }
            }
        }
        return shapes
    }

    /// Farthest-from-the-staff shift any member of the group needs.
    /// Negative above the staff, positive below — i.e. always AWAY
    /// from it, never toward it (0 when nothing collides).
    private static func requiredShift(
        shapes: [(address: Address, shape: LayoutShape, kind: ShapeItemKind, side: Placement?)],
        staffMidY: CGFloat, metrics: StaffMetrics, skyline: Skyline,
    ) -> CGFloat {
        var dy: CGFloat = 0
        for entry in shapes {
            let shape = entry.shape
            let kind = entry.kind
            let side: AutoplaceSide = entry.side.map { $0 == .above ? .above : .below } ?? resolveSide(
                kind: kind, shape: shape, staffMidY: staffMidY,
            )
            let filtered = skyline.filtered { other in
                shape.rects.contains {
                    AutoplaceRules.shouldIgnoreEachOther($0.item, other)
                }
            }
            let clearance = AutoplaceRules.horizontalClearance(
                for: kind, sp: metrics.sp,
            )
            let minDistance = AutoplaceRules.minDistance(
                for: kind, sp: metrics.sp,
            )
            let overlap = side == .above
                ? filtered.overlapAbove(shape, clearance: clearance)
                : filtered.overlapBelow(shape, clearance: clearance)
            guard overlap.isFinite, overlap > -minDistance else { continue }
            let push = overlap + minDistance
            dy = side == .above ? min(dy, -push) : max(dy, push)
        }
        return dy
    }

    /// Side of the staff this item is pushed toward. The spanner kinds
    /// are decided by where the element already sits, because that is
    /// where MuseScore gets it from too — `autoplaceSpannerSegment`
    /// reads `spanner()->placeAbove()`, and an authored `<placement>`
    /// is already baked into the segment's Y.
    private static func resolveSide(
        kind: ShapeItemKind, shape: LayoutShape, staffMidY: CGFloat,
    ) -> AutoplaceSide {
        if let side = AutoplaceRules.defaultSide(for: kind) {
            return side
        }
        guard let box = shape.bbox else { return .above }
        return box.midY < staffMidY ? .above : .below
    }
}
