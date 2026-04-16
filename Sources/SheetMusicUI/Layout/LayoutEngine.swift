#if os(macOS)
import CoreGraphics
import SheetMusicCore

/// Pure function: `Score` → `LayoutDocument`.
///
/// v1 is a single-pass engine with simple heuristics. No caching, no
/// mutation, no back-pointers. Safe to re-run on every option change.
///
/// The enum is split across extensions for readability:
/// - `LayoutEngine+Spacing.swift`    — measure width calculations.
/// - `LayoutEngine+Placement.swift`  — per-measure element placement
///   (`placeMeasureElements`), glissando, beaming pass.
/// - `LayoutEngine+Beaming.swift`    — `beamGroups` + helpers.
/// - `LayoutEngine+Spanners.swift`   — anchor collect + attach pass.
/// - `LayoutEngine+Ties.swift`       — tie pair resolve + attach.
@available(macOS 15.0, *)
public enum LayoutEngine {
    public static func layout(
        score: Score,
        options: ScoreViewOptions,
        availableWidth: CGFloat
    ) -> LayoutDocument {
        let metrics = StaffMetrics(staffSize: options.staffSize)
        let context = RenderContext(
            score: score,
            options: options,
            metrics: metrics,
            availableWidth: availableWidth
        )
        let systems = packSystems(context: context)
        let totalHeight = systems.reduce(CGFloat(0)) { acc, system in
            max(acc, system.origin.y + system.size.height)
        }
        let anchors = collectSpanners(score: score)
        let systemsWithSpanners = attachSpanners(
            to: systems,
            anchors: anchors,
            score: score,
            metrics: metrics
        )
        let firstPass = LayoutDocument(
            size: CGSize(width: availableWidth, height: totalHeight),
            systems: systemsWithSpanners,
            metrics: metrics
        )
        let ties = resolveTies(for: firstPass, score: score)
        let systemsWithTies = attachTies(
            to: systemsWithSpanners, pairs: ties)
        return LayoutDocument(
            size: firstPass.size,
            systems: systemsWithTies,
            metrics: metrics
        )
    }

    // MARK: - Context

    struct RenderContext {
        let score: Score
        let options: ScoreViewOptions
        let metrics: StaffMetrics
        let availableWidth: CGFloat
    }

    // MARK: - System packing

    static func packSystems(
        context: RenderContext
    ) -> [LayoutSystem] {
        let stavesCount = context.score.staves.count
        guard stavesCount > 0,
              let firstStaff = context.score.staves.first,
              !firstStaff.measures.isEmpty else {
            return []
        }

        let measureCount = firstStaff.measures.count
        // Per-measure minimum width = max across staves so that the
        // widest staff's content fits at this index.
        let minWidths: [CGFloat] = (0..<measureCount).map { i in
            context.score.staves.map { staff in
                i < staff.measures.count
                    ? minimumMeasureWidth(
                        measure: staff.measures[i],
                        metrics: context.metrics)
                    : 0
            }.max() ?? 0
        }

        var systems: [LayoutSystem] = []
        var currentY: CGFloat = 0
        var cursor = 0
        var isFirstSystem = true
        while cursor < measureCount {
            var widthSoFar: CGFloat = 0
            let systemStart = cursor
            while cursor < measureCount {
                let w = minWidths[cursor]
                if context.options.wrapToViewWidth
                    && widthSoFar + w > context.availableWidth
                    && cursor > systemStart {
                    break
                }
                widthSoFar += w
                cursor += 1
            }
            let widthsSlice = Array(minWidths[systemStart..<cursor])
            let stretched = stretchWidths(
                widths: widthsSlice,
                availableWidth: context.availableWidth,
                shouldStretch: context.options.wrapToViewWidth
            )
            let system = buildSystem(
                measureRange: systemStart..<cursor,
                widths: stretched,
                systemOriginY: currentY,
                isFirstSystem: isFirstSystem,
                context: context
            )
            currentY += system.size.height + context.options.systemGap
            systems.append(system)
            isFirstSystem = false
        }
        return systems
    }

    static func stretchWidths(
        widths: [CGFloat],
        availableWidth: CGFloat,
        shouldStretch: Bool
    ) -> [CGFloat] {
        let total = widths.reduce(0, +)
        guard shouldStretch, total > 0, availableWidth > total else {
            return widths
        }
        let ratio = availableWidth / total
        return widths.map { $0 * ratio }
    }

    // MARK: - Per-system layout

    static func buildSystem(
        measureRange: Range<Int>,
        widths: [CGFloat],
        systemOriginY: CGFloat,
        isFirstSystem: Bool,
        context: RenderContext
    ) -> LayoutSystem {
        let metrics = context.metrics
        let staves = context.score.staves
        // Vertical stacking: each staff gets staffHeight + 4 sp slack.
        let staffSpacing = metrics.staffHeight + metrics.sp * 4
        // First system reserves wider space for long part names.
        let partLabelWidth: CGFloat = isFirstSystem ? 80 : 30

        // Breathing room above the top staff and below the bottom staff
        // so ledger-line notes, tempo text, ottavas, voltas, hairpins,
        // and pedal marks don't clip. 8 sp ≈ 4 ledger positions + a
        // comfortable margin for an inline text mark.
        let topPad: CGFloat = metrics.sp * 8
        let bottomPad: CGFloat = metrics.sp * 8

        let staffOrigins: [CGPoint] = staves.enumerated().map { idx, _ in
            CGPoint(
                x: partLabelWidth,
                y: topPad + CGFloat(idx) * staffSpacing
            )
        }

        // Per-staff labels. Stage 5 assumes staves align 1:1 with parts;
        // multi-staff-per-part (piano grand staff) is handled the same
        // way for now — each staff gets its own label.
        let labels: [LayoutPartLabel] = staves.enumerated().map { idx, _ in
            let part = idx < context.score.parts.count
                ? context.score.parts[idx] : nil
            let text: String
            if isFirstSystem {
                text = part?.trackName
                    ?? part?.instrument.longName
                    ?? ""
            } else {
                text = part?.instrument.shortName
                    ?? part?.trackName.map { String($0.prefix(3)) }
                    ?? ""
            }
            let y = staffOrigins[idx].y + metrics.staffHeight / 2
            return LayoutPartLabel(
                text: text,
                origin: CGPoint(x: 4, y: y)
            )
        }

        // Resolve each staff's default clef from its Part's declaration.
        // MuseScore omits an explicit `<Clef>` in the first measure when
        // the default is obvious (treble for pitched voice, PERC for
        // percussion); without this resolution the staff renders with no
        // clef glyph at all.
        let defaultClefRawTypes: [String] =
            staves.enumerated().map { idx, _ in
                let part = idx < context.score.parts.count
                    ? context.score.parts[idx] : nil
                let decl = part?.staffDeclarations.first
                if let declared = decl?.defaultClefType {
                    return declared
                }
                if decl?.group == "percussion" { return "PERC" }
                return "G"
            }

        var layoutMeasures: [LayoutMeasure] = []
        var xCursor: CGFloat = partLabelWidth
        var clefs: [NotatedClef] = defaultClefRawTypes.map {
            NotatedClef(rawType: $0)
        }
        for (j, measureIdx) in measureRange.enumerated() {
            let w = widths[j]
            let synthesizeClefHere = isFirstSystem && j == 0
            let schedule = computeHeaderSchedule(
                measureIdx: measureIdx,
                staves: staves,
                metrics: metrics,
                synthesizeClefForAllStaves: synthesizeClefHere
            )
            var aggregated: [LayoutElement] = []
            var markers: [LayoutElement] = []
            var jumps: [LayoutElement] = []
            for (staffIdx, staff) in staves.enumerated() {
                guard measureIdx < staff.measures.count else { continue }
                let m = staff.measures[measureIdx]
                let synthClef: String? = synthesizeClefHere
                    ? defaultClefRawTypes[staffIdx]
                    : nil
                let (els, newClef) = placeMeasureElements(
                    measure: m,
                    width: w,
                    metrics: metrics,
                    activeClef: clefs[staffIdx],
                    initialClefRawType: synthClef,
                    headerSchedule: schedule,
                    division: context.score.division
                )
                clefs[staffIdx] = newClef
                // Placement emits positions relative to "staff top at
                // sp*2" (see `staffMidY` inside placeMeasureElements).
                // Shift by the difference so placement coords end up in
                // system coords.
                let yOffset = staffOrigins[staffIdx].y - metrics.sp * 2
                aggregated.append(contentsOf: els.map {
                    translate(element: $0, dy: yOffset)
                })
                // Markers / jumps are collected only from the first staff
                // — they apply to the whole system at this measure, not
                // per staff. A piano grand staff repeats the same marker
                // on both staves in MSCX; we draw it once above the top
                // staff to match engraving convention.
                if staffIdx == 0 {
                    let staffTopY = staffOrigins[staffIdx].y
                    let staffBottomY = staffTopY + metrics.staffHeight
                    for marker in m.markers {
                        let labelText = marker.text.isEmpty
                            ? marker.label : marker.text
                        markers.append(.marker(
                            kind: marker.kind,
                            text: labelText,
                            origin: CGPoint(
                                x: 4, y: staffTopY - metrics.sp)
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
            }
            layoutMeasures.append(LayoutMeasure(
                origin: CGPoint(x: xCursor, y: 0),
                width: w,
                elements: aggregated,
                markers: markers,
                jumps: jumps
            ))
            xCursor += w
        }

        // Baseline height: top pad + all staves + bottom pad.
        let baselineHeight =
            topPad
            + CGFloat(max(0, staves.count - 1)) * staffSpacing
            + metrics.staffHeight
            + bottomPad

        // Extend to fit the actual bounding box of emitted elements so
        // nothing clips when e.g. a note lands on the 5th ledger line
        // above the top staff or a dynamic text hangs farther below the
        // bottom staff than the baseline allowed.
        let bbox = elementYBounds(
            in: layoutMeasures,
            metrics: metrics)
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
                    origin: CGPoint(x: $0.origin.x, y: $0.origin.y + topShift))
            }
            : labels

        return LayoutSystem(
            origin: CGPoint(x: 0, y: systemOriginY),
            size: CGSize(width: xCursor, height: totalHeight + topShift),
            measures: adjustedMeasures,
            staffOrigins: adjustedStaffOrigins,
            partLabels: adjustedLabels,
            spanners: []
        )
    }

    /// Compute the y extent (min/max) of every placed element across all
    /// measures of a system. Used to size the system so notes on far
    /// ledger lines, tempo glyphs, dynamics, etc. don't clip.
    private static func elementYBounds(
        in measures: [LayoutMeasure],
        metrics: StaffMetrics
    ) -> (min: CGFloat, max: CGFloat) {
        var minY = CGFloat.infinity
        var maxY = -CGFloat.infinity
        // Glyph metrics are anchored at their center; extend by one sp
        // in every direction so the reported bounds cover the rendered
        // pixels, not just the anchor point.
        let glyphPad = metrics.sp
        for measure in measures {
            for el in measure.elements + measure.markers + measure.jumps {
                for p in elementYPoints(el) {
                    minY = min(minY, p - glyphPad)
                    maxY = max(maxY, p + glyphPad)
                }
            }
        }
        if !minY.isFinite { minY = 0 }
        if !maxY.isFinite { maxY = 0 }
        return (minY, maxY)
    }

    /// y values contributed by a single LayoutElement.
    private static func elementYPoints(
        _ element: LayoutElement
    ) -> [CGFloat] {
        switch element {
        case .clef(_, let p),
             .keySignature(_, _, let p),
             .timeSignature(_, _, let p),
             .barLine(_, let p),
             .rest(_, let p),
             .textMark(_, _, let p),
             .fermata(_, let p),
             .marker(_, _, let p),
             .jump(_, let p),
             .measureRepeat(_, let p):
            return [p.y]
        case .note(_, _, _, _, let p, _, _, _):
            return [p.y]
        case .chord(let notes, _, _, let so, _, _, _):
            var ys = notes.map(\.origin.y)
            ys.append(so.y)
            return ys
        case .beam(let from, let to, _, _):
            return [from.y, to.y]
        case .spannerSegment(_, let from, let to, _, _, _),
             .tieArc(let from, let to, _),
             .glissandoLine(let from, let to, _, _):
            return [from.y, to.y]
        case .arpeggioWiggle(let top, let bot, _):
            return [top.y, bot.y]
        }
    }

    private static func shiftMeasure(
        _ measure: LayoutMeasure, dy: CGFloat
    ) -> LayoutMeasure {
        LayoutMeasure(
            origin: measure.origin,
            width: measure.width,
            elements: measure.elements.map { translate(element: $0, dy: dy) },
            markers: measure.markers.map { translate(element: $0, dy: dy) },
            jumps: measure.jumps.map { translate(element: $0, dy: dy) }
        )
    }

    /// Shift an element's origin(s) by a vertical offset, for stacking
    /// staves that were placed in staff-0-local coordinates.
    static func translate(
        element: LayoutElement, dy: CGFloat
    ) -> LayoutElement {
        func shift(_ p: CGPoint) -> CGPoint {
            CGPoint(x: p.x, y: p.y + dy)
        }
        switch element {
        case .clef(let t, let p):
            return .clef(rawType: t, origin: shift(p))
        case .keySignature(let s, let f, let p):
            return .keySignature(sharps: s, flats: f, origin: shift(p))
        case .timeSignature(let n, let d, let p):
            return .timeSignature(
                numerator: n, denominator: d, origin: shift(p))
        case .barLine(let s, let p):
            return .barLine(subtype: s, origin: shift(p))
        case .rest(let d, let p):
            return .rest(duration: d, origin: shift(p))
        case .chord(let notes, let dur, let stem, let so, let arp, let art, let beamed):
            let shiftedNotes = notes.map {
                LayoutChordNote(
                    step: $0.step,
                    accidental: $0.accidental,
                    origin: shift($0.origin),
                    tieForward: $0.tieForward,
                    tieBack: $0.tieBack,
                    hasGlissando: $0.hasGlissando
                )
            }
            return .chord(
                notes: shiftedNotes,
                duration: dur,
                stem: stem,
                stemOrigin: shift(so),
                hasArpeggio: arp,
                arpeggioRawType: art,
                isBeamed: beamed
            )
        case .textMark(let k, let t, let p):
            return .textMark(kind: k, text: t, origin: shift(p))
        case .fermata(let s, let p):
            return .fermata(subtype: s, origin: shift(p))
        case .measureRepeat(let c, let p):
            return .measureRepeat(count: c, origin: shift(p))
        case .beam(let from, let to, let levels, let direction):
            return .beam(
                fromOrigin: shift(from),
                toOrigin: shift(to),
                levels: levels,
                direction: direction)
        case .glissandoLine(let from, let to, let wavy, let text):
            return .glissandoLine(
                fromOrigin: shift(from),
                toOrigin: shift(to),
                wavy: wavy,
                text: text)
        case .arpeggioWiggle(let top, let bot, let subtype):
            return .arpeggioWiggle(
                top: shift(top),
                bottom: shift(bot),
                subtype: subtype)
        case .note, .marker, .jump, .spannerSegment, .tieArc:
            return element
        }
    }
}
#endif
