// swiftlint:disable function_body_length file_length
import CoreGraphics
import SheetMusicCore

@available(macOS 15.0, iOS 16.0, *)
extension LayoutEngine {
    // MARK: - Per-system layout

    static func buildSystem(
        measureRange: Range<Int>,
        widths: [CGFloat],
        systemOriginY: CGFloat,
        isFirstSystem: Bool,
        activeClefs: inout [NotatedClef],
        activeKeys: inout [Int],
        context: RenderContext
    ) -> LayoutSystem {
        let metrics = context.metrics
        let allStaves = context.score.allStaves
        let staves = allStaves.map(\.staff)
        let partLabelWidth: CGFloat = labelWidth(
            score: context.score,
            metrics: metrics,
            useLong: isFirstSystem
        )

        // Inter-system breathing room. MuseScore's style defaults
        // (`engraving/style/styledef.cpp`):
        //   * `staffUpperBorder` = 7sp — but it acts only on a
        //     page's *first* system, not every system; `systemGap`
        //     (configured at the exporter / view level) handles the
        //     distance between consecutive systems.
        //   * `staffDistance` = 6.5sp — total gap between adjacent
        //     staves *within* a system.
        // Our previous `topPad = bottomPad = 6sp` double-counted
        // that distance and produced systems ~50% taller than
        // MuseScore. 1sp leaves a hairline so glyph extents that
        // overshoot the staff don't graze the system above / below.
        let topPad: CGFloat = metrics.sp * 1
        let bottomPad: CGFloat = metrics.sp * 1
        // Inter-staff vertical gap baseline. Combined with
        // `staffBottomPads[idx]` (lyrics / dynamics extent) and
        // the next staff's `staffTopPads` (2 sp baseline), this
        // approximates MuseScore's `Sid::staffDistance = 6.5 sp`.
        // 0.5 sp keeps total system height in line with
        // MuseScore's reference output without sacrificing
        // breathing room.
        let minGap: CGFloat = metrics.sp * 0.5

        // `staffBottomPads` is computed AFTER the untranslated
        // layout below — it depends on the actual south-skyline
        // Y of each staff (chord-pushed lyrics, melismas, etc.),
        // which only exists once `placeMeasureElements` has run.

        // --- Pass 1: place all measures untranslated ---
        //
        // Element auto-placement (e.g. `<StaffText>` getting bumped
        // above a high stem) makes each staff's vertical extent
        // dynamic — we can't size `staffTopPads` until we've seen
        // where the elements actually landed. Run `placeMeasureElements`
        // first into a per-staff buffer, then derive padding from
        // the resulting Y bounds, then translate in pass 2.
        struct UntranslatedMeasure {
            let measureIdx: Int
            let width: CGFloat
            var perStaffElements: [Int: [LayoutElement]]
            let staff0Measure: Measure?
        }
        var untranslated: [UntranslatedMeasure] = []
        var clefs = activeClefs
        var keys = activeKeys
        for (j, measureIdx) in measureRange.enumerated() {
            let w = widths[j]
            let synthesizeClefHere = j == 0
            let synthesizeKeySigHere = j == 0
            let schedule = computeHeaderSchedule(
                measureIdx: measureIdx,
                staves: staves,
                metrics: metrics,
                synthesizeClefForAllStaves: synthesizeClefHere,
                synthesizeKeySigForAllStaves: synthesizeKeySigHere,
                activeKeys: keys
            )
            let tickCols = tickColumns(
                staves: staves,
                measureIdx: measureIdx,
                metrics: metrics,
                headerSchedule: schedule,
                width: w,
                division: context.score.division
            )
            var perStaff: [Int: [LayoutElement]] = [:]
            for (staffIdx, staff) in staves.enumerated() {
                guard measureIdx < staff.measures.count else { continue }
                let m = staff.measures[measureIdx]
                let synthClef: String? = synthesizeClefHere
                    ? clefs[staffIdx].rawType
                    : nil
                let synthKey: Int? = synthesizeKeySigHere
                    ? keys[staffIdx]
                    : nil
                let part = context.score.parts[allStaves[staffIdx].address.partIndex]
                let drumMap: [Int: Int]? =
                    part.instrument.useDrumset
                        ? part.instrument.drumLineMap
                        : nil
                let totalMeasures = staves.first?.measures.count ?? 0
                let lastMeasure = measureIdx == totalMeasures - 1
                let incomingMelismas = context.melismaContinuations
                    .indices.contains(staffIdx)
                    && context.melismaContinuations[staffIdx]
                    .indices.contains(measureIdx)
                    ? context.melismaContinuations[staffIdx][measureIdx]
                    : []
                let placementInputs = LayoutCache.PlacementInputs(
                    measure: m,
                    width: w,
                    metricsSp: metrics.sp,
                    activeClef: clefs[staffIdx],
                    activeKey: keys[staffIdx],
                    initialClefRawType: synthClef,
                    initialKeyForSynth: synthKey,
                    headerSchedule: schedule,
                    tickColumns: tickCols,
                    division: context.score.division,
                    drumLineMap: drumMap,
                    isLastMeasure: lastMeasure,
                    incomingMelismas: incomingMelismas,
                    effectiveMelismaTicks: context.effectiveMelismaTicks
                )
                let els: [LayoutElement]
                let newClef: NotatedClef
                let newKey: Int
                if let cached = context.cache?
                    .entries[measureIdx]?.placements[staffIdx],
                    cached.inputs == placementInputs
                {
                    els = cached.elements
                    newClef = cached.newClef
                    newKey = cached.newKey
                    context.cache?.placementHits += 1
                } else {
                    let result = placeMeasureElements(
                        measure: m,
                        staffAddress: allStaves[staffIdx].address,
                        measureIndex: measureIdx,
                        width: w,
                        metrics: metrics,
                        activeClef: clefs[staffIdx],
                        activeKey: keys[staffIdx],
                        initialClefRawType: synthClef,
                        initialKeyForSynth: synthKey,
                        headerSchedule: schedule,
                        tickColumns: tickCols,
                        division: context.score.division,
                        drumLineMap: drumMap,
                        isLastMeasure: lastMeasure,
                        incomingMelismas: incomingMelismas,
                        effectiveMelismaTicks: context.effectiveMelismaTicks
                    )
                    els = result.elements
                    newClef = result.clef
                    newKey = result.key
                    context.cache?.placementMisses += 1
                    if var entry = context.cache?.entries[measureIdx] {
                        entry.placements[staffIdx] = LayoutCache
                            .StaffPlacement(
                                inputs: placementInputs,
                                elements: els,
                                newClef: newClef,
                                newKey: newKey
                            )
                        context.cache?.entries[measureIdx] = entry
                    }
                }
                clefs[staffIdx] = newClef
                keys[staffIdx] = newKey
                perStaff[staffIdx] = els
            }
            let staff0Measure: Measure? = measureIdx
                < (staves.first?.measures.count ?? 0)
                ? staves.first?.measures[measureIdx]
                : nil
            untranslated.append(UntranslatedMeasure(
                measureIdx: measureIdx,
                width: w,
                perStaffElements: perStaff,
                staff0Measure: staff0Measure
            ))
        }

        // --- System-wide lyric-Y alignment ---
        //
        // MuseScore's
        // `LyricsLayout::checkCollisionsWithStaffElements`
        // (`engraving/rendering/score/lyricslayout.cpp:614-651`)
        // walks the whole system, finds the deepest required
        // verse-Y, and shifts EVERY lyric in the verse uniformly
        // so the row stays horizontally aligned across the
        // system. `placeMeasureElements` only ratchets per
        // measure — across measures, lyric Y can still differ
        // (one measure has a low note that pushes lyrics down;
        // adjacent measures don't). This post-pass enforces the
        // system-wide max.
        for staffIdx in 0 ..< staves.count {
            // For each measure on this staff, the lowest Y among
            // its lyric elements is verse 0's Y (the
            // `maxLyricCenterYInMeasure` ratchet inside
            // `placeMeasureElements` gives all chords in the
            // measure the same Y base).
            var measureVerse0Y: [Int: CGFloat] = [:]
            for (mIdx, m) in untranslated.enumerated() {
                guard let els = m.perStaffElements[staffIdx]
                else { continue }
                var minY = CGFloat.infinity
                for el in els {
                    if case let .textMark(.lyrics, _, p) = el,
                       p.y < minY
                    {
                        minY = p.y
                    }
                }
                if minY != .infinity {
                    measureVerse0Y[mIdx] = minY
                }
            }
            guard let systemTargetY = measureVerse0Y.values.max()
            else { continue }
            // Per-measure shift for lyric text + hyphens: all
            // verses move uniformly so verse N stays at
            // `systemTargetY + N * 1.7sp`.
            for (mIdx, baseY) in measureVerse0Y
                where baseY < systemTargetY
            {
                let dy = systemTargetY - baseY
                if var els = untranslated[mIdx]
                    .perStaffElements[staffIdx]
                {
                    els = els.map { shiftLyricTextY($0, dy: dy) }
                    untranslated[mIdx]
                        .perStaffElements[staffIdx] = els
                }
            }
            // Melisma rules need an absolute snap, not a per-
            // measure shift. Anchor rules emitted in a chord-
            // pushed measure use that measure's pushed Y; the
            // continuation rule for the SAME melisma emitted in
            // the following measure (`emitMelismaContinuation`)
            // uses the default verse-0 Y because it has no view
            // of the originating chord. Without this snap the
            // continuation lands at default Y + dy_thisMeasure,
            // which only equals `systemTargetY + offset` when the
            // current measure has no own push. Force every
            // melisma in the system to `systemTargetY + 0.9 sp`
            // (the lyric font's underline level — see
            // `melismaLineYOffset`) so the rule sits flush with
            // the now-aligned lyric row, regardless of which
            // measure emitted it. Verse 0 only — multi-verse
            // melismas would need a verse hint on the element.
            let melismaTargetY = systemTargetY + metrics.sp * 0.9
            for mIdx in untranslated.indices {
                guard var els = untranslated[mIdx]
                    .perStaffElements[staffIdx] else { continue }
                els = els.map {
                    setMelismaAbsoluteY($0, y: melismaTargetY)
                }
                untranslated[mIdx]
                    .perStaffElements[staffIdx] = els
            }
        }

        // --- Per-staff Y bounds from the untranslated elements ---
        //
        // Mirrors MuseScore's "skyline" — the highest and lowest
        // points each staff actually paints, which feeds the
        // adaptive staff distance below. Staff top in placement
        // coords sits at `sp * 2` (see `staffMidY` in
        // `placeMeasureElements`); the bottom is at `sp * 6` for
        // a 5-line staff. Anything outside that range pushes the
        // adjacent staff away so they don't overlap.
        let staffTopLocal: CGFloat = metrics.sp * 2
        let staffBottomLocal: CGFloat = staffTopLocal
            + metrics.staffHeight
        var staffMinY = Array(
            repeating: CGFloat.infinity, count: staves.count
        )
        var staffMaxY = Array(
            repeating: -CGFloat.infinity, count: staves.count
        )
        for um in untranslated {
            for (staffIdx, els) in um.perStaffElements {
                for el in els {
                    for y in elementYPoints(el) {
                        if y < staffMinY[staffIdx] {
                            staffMinY[staffIdx] = y
                        }
                        if y > staffMaxY[staffIdx] {
                            staffMaxY[staffIdx] = y
                        }
                    }
                }
            }
        }

        // --- Adaptive per-staff top padding ---
        let staffTopPads: [CGFloat] = staves.indices.map { idx in
            let topOverflow: CGFloat = staffMinY[idx].isFinite
                ? max(
                    0,
                    staffTopLocal - staffMinY[idx]
                        + metrics.sp * 0.5
                )
                : 0
            // First staff falls under the system's `topPad`
            // already. For subsequent staves, MuseScore's
            // `Sid::staffDistance = 6.5 sp` is the total gap
            // between adjacent staves. We split that across
            // `staffBottomPads[idx-1] + minGap + this baseline`,
            // so the baseline carries roughly 2 sp of clearance
            // — enough that the upper staff's lyrics or staff-
            // text dynamics don't visually fuse with this
            // staff's top line.
            let baseline: CGFloat = idx == 0 ? 0 : metrics.sp * 2
            return baseline + topOverflow
        }

        // --- Adaptive per-staff bottom padding ---
        //
        // Two sources feed the gap below a staff:
        //   - A verse-count estimate that matches MuseScore's
        //     default `Sid::staffDistance = 6.5 sp` for a staff
        //     with one verse (1.5 sp `lyricsMinBottomDistance` +
        //     1.7 sp verse stride; see
        //     `engraving/style/styledef.cpp:92-99`).
        //   - The measured south skyline (`staffMaxY`), which
        //     captures chord-pushed lyrics + melisma rules +
        //     hyphens that can dip well below the verse-count
        //     estimate when low notes / ties are present.
        //
        // We take the max so the default case stays page-count
        // compatible with MuseScore while chord-pushed measures
        // get the extra room they need (see
        // `LyricsLayout::addToSkyline`,
        // `lyricslayout.cpp:707`).
        let staffBottomPads: [CGFloat] = staves.enumerated().map { idx, staff in
            var maxLyricsVerses = 0
            for mIdx in measureRange {
                guard mIdx < staff.measures.count else { continue }
                for voice in staff.measures[mIdx].voices {
                    for el in voice.elements {
                        if case let .chord(c) = el {
                            let nonEmpty = c.lyrics.filter {
                                !$0.text.isEmpty
                            }.count
                            maxLyricsVerses = max(
                                maxLyricsVerses, nonEmpty
                            )
                        }
                    }
                }
            }
            let basePad: CGFloat = metrics.sp * 2.5
            let lyricsEstimate: CGFloat = maxLyricsVerses > 0
                ? metrics.sp * 1.5
                + CGFloat(maxLyricsVerses) * metrics.sp * 1.7
                : 0
            let southExtent: CGFloat = staffMaxY[idx].isFinite
                ? max(0, staffMaxY[idx] - staffBottomLocal)
                : 0
            // Clearance constant stays smaller than MuseScore's
            // raw `lyricsMinBottomDistance = 1.5 sp` because our
            // `staffTopPads` baseline already adds another ~2 sp
            // above the next staff — together they reach the
            // 1.5 sp lyric-bottom-to-next-staff minimum without
            // bloating the page count. The same 0.5 sp matches
            // MuseScore's `Sid::minVerticalDistance` for general
            // skyline padding (`styledef.cpp:772`).
            let measuredPad = southExtent + metrics.sp * 0.5
            return max(basePad, lyricsEstimate, measuredPad)
        }

        // --- Compute staffOrigins from cumulative extent ---
        var staffOrigins: [CGPoint] = []
        var currentY: CGFloat = topPad
        for idx in 0 ..< staves.count {
            currentY += staffTopPads[idx]
            staffOrigins.append(CGPoint(
                x: partLabelWidth, y: currentY
            ))
            if idx < staves.count - 1 {
                currentY += metrics.staffHeight
                    + staffBottomPads[idx] + minGap
            }
        }

        // Per-Part labels. Multi-staff parts (Piano grand staff)
        // collapse to a single label centered between the topmost
        // and bottommost spanned staves, matching engraving
        // convention. Single-staff parts trivially center on their
        // one staff.
        let labels: [LayoutPartLabel] = context.score.parts.enumerated().compactMap { partIdx, part in
            let text: String
            if isFirstSystem {
                text = part.instrument.longName
                    ?? part.trackName
                    ?? ""
            } else {
                text = part.instrument.shortName
                    ?? part.instrument.longName.map { String($0.prefix(3)) }
                    ?? part.trackName.map { String($0.prefix(3)) }
                    ?? ""
            }
            // Locate the part's flat-staff range. A part with no
            // entries in `allStaves` (shouldn't normally happen — a
            // Part declares staves that always end up flattened)
            // is skipped silently.
            guard let firstFlat = allStaves.firstIndex(where: {
                $0.address.partIndex == partIdx
            }), let lastFlat = allStaves.lastIndex(where: {
                $0.address.partIndex == partIdx
            }) else { return nil }
            let topY = staffOrigins[firstFlat].y
            let bottomY = staffOrigins[lastFlat].y + metrics.staffHeight
            let centerY = (topY + bottomY) / 2
            return LayoutPartLabel(
                text: text,
                origin: CGPoint(x: 4, y: centerY)
            )
        }

        // --- Pass 2: translate elements with adjusted origins ---
        var layoutMeasures: [LayoutMeasure] = []
        var xCursor: CGFloat = partLabelWidth
        for (j, um) in untranslated.enumerated() {
            let w = um.width
            let measureIdx = um.measureIdx
            var aggregated: [LayoutElement] = []
            var markers: [LayoutElement] = []
            var jumps: [LayoutElement] = []
            for staffIdx in staves.indices {
                guard let els = um.perStaffElements[staffIdx]
                else { continue }
                // Placement emits positions relative to "staff top
                // at sp*2" (see `staffMidY` inside
                // `placeMeasureElements`). Shift by the difference
                // so placement coords end up in system coords.
                let yOffset = staffOrigins[staffIdx].y
                    - metrics.sp * 2
                aggregated.append(contentsOf: els.map {
                    translate(element: $0, dy: yOffset)
                })
            }
            // Markers / jumps come from the first staff only — they
            // apply to the whole system at this measure, not per
            // staff. A piano grand staff repeats the same marker
            // on both staves in MSCX; we draw it once above the
            // top staff to match engraving convention.
            if let m = um.staff0Measure {
                let staffTopY = staffOrigins[0].y
                let staffBottomY = staffTopY + metrics.staffHeight
                for marker in m.markers {
                    let labelText = marker.text.isEmpty
                        ? marker.label : marker.text
                    markers.append(.marker(
                        kind: marker.kind,
                        text: labelText,
                        origin: CGPoint(
                            x: 4, y: staffTopY - metrics.sp
                        )
                    ))
                }
                for jump in m.jumps {
                    jumps.append(.jump(
                        text: jump.text,
                        origin: CGPoint(
                            x: w - metrics.sp * 4,
                            y: staffBottomY + metrics.sp
                        )
                    ))
                }
            }
            // Measure number at every system head — TOP STAFF
            // ONLY. Engraving convention places a single number
            // above the topmost staff at the start of each system.
            if j == 0, !staves.isEmpty {
                let staffTopY = staffOrigins[0].y
                markers.append(.measureNumber(
                    text: "\(measureIdx + 1)",
                    origin: CGPoint(
                        x: -metrics.sp * 0.5,
                        y: staffTopY - metrics.sp * 1.5
                    )
                ))
            }
            // Surface the source measure's break flags so the
            // pagination phase (page break → close page) and the
            // on-screen indicator overlay (icons at the measure's
            // top-right) can consult them without re-walking
            // `score.allStaves`.
            let sourceMeasure = staves.first
                .flatMap { $0.measures.indices.contains(measureIdx)
                    ? $0.measures[measureIdx]
                    : nil
                }
            layoutMeasures.append(LayoutMeasure(
                measureIndex: measureIdx,
                origin: CGPoint(x: xCursor, y: 0),
                width: w,
                elements: aggregated,
                markers: markers,
                jumps: jumps,
                lineBreak: sourceMeasure?.lineBreak ?? false,
                pageBreak: sourceMeasure?.pageBreak ?? false
            ))
            xCursor += w
        }

        // Baseline height: last staff's bottom + bottomPad.
        let lastStaffBottom = (staffOrigins.last?.y ?? topPad)
            + metrics.staffHeight
        let baselineHeight = lastStaffBottom + bottomPad

        // Extend to fit the actual bounding box of emitted elements so
        // nothing clips when e.g. a note lands on the 5th ledger line
        // above the top staff or a dynamic text hangs farther below the
        // bottom staff than the baseline allowed.
        let bbox = elementYBounds(
            in: layoutMeasures,
            metrics: metrics
        )
        let bottomSlack = max(0, bbox.max - baselineHeight) + metrics.sp * 2
        let totalHeight = baselineHeight + bottomSlack

        // Content above y=0 (e.g. a tempo glyph above staff 0 when the
        // existing topPad isn't quite enough) would clip against the
        // document's top edge. If we see it, shift every element down
        // and enlarge the system so the whole bounding box is visible.
        let topShift = max(0, -bbox.min + metrics.sp * 2)
        let adjustedMeasures = topShift > 0
            ? layoutMeasures.map { shiftMeasure($0, dy: topShift) }
            : layoutMeasures
        let adjustedStaffOrigins = topShift > 0
            ? staffOrigins.map { CGPoint(x: $0.x, y: $0.y + topShift) }
            : staffOrigins
        let adjustedLabels = topShift > 0
            ? labels.map {
                LayoutPartLabel(
                    text: $0.text,
                    origin: CGPoint(x: $0.origin.x, y: $0.origin.y + topShift)
                )
            }
            : labels

        // Hand the (possibly mutated) clef / key state back to the
        // caller so the next system continues from where this one
        // ended.
        activeClefs = clefs
        activeKeys = keys

        return LayoutSystem(
            origin: CGPoint(x: 0, y: systemOriginY),
            size: CGSize(width: xCursor, height: totalHeight + topShift),
            measures: adjustedMeasures,
            staffOrigins: adjustedStaffOrigins,
            staffAddresses: allStaves.map(\.address),
            partLabels: adjustedLabels,
            spanners: [],
            sp: metrics.sp
        )
    }
}
