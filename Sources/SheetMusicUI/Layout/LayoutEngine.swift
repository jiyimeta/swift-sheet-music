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
            let y = CGFloat(idx) * staffSpacing
                + metrics.sp * 2
                + metrics.staffHeight / 2
            return LayoutPartLabel(
                text: text,
                origin: CGPoint(x: 4, y: y)
            )
        }

        let staffOrigins: [CGPoint] = staves.enumerated().map { idx, _ in
            CGPoint(
                x: partLabelWidth,
                y: CGFloat(idx) * staffSpacing + metrics.sp * 2
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
                let yOffset = staffOrigins[staffIdx].y - staffOrigins[0].y
                aggregated.append(contentsOf: els.map {
                    translate(element: $0, dy: yOffset)
                })
                // Markers / jumps are collected only from the first staff
                // — they apply to the whole system at this measure, not
                // per staff. A piano grand staff repeats the same marker
                // on both staves in MSCX; we draw it once above the top
                // staff to match engraving convention.
                if staffIdx == 0 {
                    for marker in m.markers {
                        let labelText = marker.text.isEmpty
                            ? marker.label : marker.text
                        markers.append(.marker(
                            kind: marker.kind,
                            text: labelText,
                            origin: CGPoint(x: 4, y: yOffset - metrics.sp)
                        ))
                    }
                    for jump in m.jumps {
                        jumps.append(.jump(
                            text: jump.text,
                            origin: CGPoint(
                                x: w - metrics.sp * 4,
                                y: yOffset
                                    + metrics.staffHeight
                                    + metrics.sp
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

        let totalHeight = CGFloat(staves.count) * staffSpacing
            + metrics.sp * 6
        return LayoutSystem(
            origin: CGPoint(x: 0, y: systemOriginY),
            size: CGSize(width: xCursor, height: totalHeight),
            measures: layoutMeasures,
            staffOrigins: staffOrigins,
            partLabels: labels,
            spanners: []
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
        case .note, .beam, .marker, .jump, .spannerSegment,
             .tieArc, .glissandoLine, .arpeggioWiggle:
            return element
        }
    }
}
#endif
