// swiftlint:disable file_length
#if canImport(CoreGraphics)
    import CoreGraphics
#endif
import SheetMusicCore

extension LayoutEngine {
    /// Maximum upward extent (smallest Y) of any chord stem-tip,
    /// notehead, beam, or above-arcing tie in `elements`. Used by
    /// the staff-text and harmony auto-placement post-passes.
    /// Returns `+infinity` when the measure has no chords/beams.
    ///
    /// Tie contribution mirrors MuseScore's skyline-with-ties: an
    /// "above" tie on the topmost note extends the north skyline
    /// past the notehead by the tie's head-clearance plus its
    /// shoulder. Without this, a chord symbol auto-placed at
    /// `chordTop − 1.5 sp` lands inside the tie arc whenever the
    /// chord protrudes above the staff and carries an upward tie.
    private static func chordTopExtent(
        in elements: [LayoutElement],
        metrics: StaffMetrics,
    ) -> CGFloat {
        var minY = CGFloat.infinity
        for el in elements {
            switch el {
            case let .chord(
                notes,
                _,
                dir,
                stemOrigin,
                _,
                _,
                _,
                _,
                _,
                _,
            ):
                let topNote = notes.map(\.origin.y).min()
                    ?? stemOrigin.y
                let extent = dir == .up
                    ? min(stemOrigin.y, topNote)
                    : topNote
                minY = min(minY, extent)
                if let tieTop = aboveTieExtent(
                    notes: notes, stem: dir, metrics: metrics,
                ) {
                    minY = min(minY, tieTop)
                }
            case let .beam(from, to, _, _, _):
                minY = min(minY, from.y, to.y)
            default:
                break
            }
        }
        return minY
    }

    /// Smallest (highest) Y reached by any above-arcing tie on the
    /// chord's notes, or `nil` when no note carries an "above" tie.
    /// Tie direction rule mirrors `LayoutEngine+Ties.swift::resolveTies`:
    /// single note → above when stem is down; multi-note top note →
    /// always above; multi-note middle note → above when stem is
    /// down; bottom note → never above.
    ///
    /// The arc apex sits at `noteY − headClearance − shoulderH`. We
    /// use `headClearance = 0.6 sp` (matching `TieRenderer`) and a
    /// fixed `shoulderH ≈ 1.0 sp` because tie length isn't known
    /// until tie pairing runs at the document level. 1.0 sp is the
    /// midpoint of MuseScore's `tieMinShoulderHeight = 0.3 sp` and
    /// `tieMaxShoulderHeight = 2.0 sp`, which keeps clearance
    /// generous for typical ties without over-reserving space for
    /// very short ones.
    private static func aboveTieExtent(
        notes: [LayoutChordNote],
        stem: StemDirection,
        metrics: StaffMetrics,
    ) -> CGFloat? {
        let steps = notes.map(\.step)
        guard let maxStep = steps.max(),
              let minStep = steps.min()
        else { return nil }
        let isSingle = maxStep == minStep
        var top: CGFloat?
        for n in notes {
            guard n.tieForward != nil || n.tieBack != nil
            else { continue }
            let above: Bool
            if isSingle {
                above = stem == .down
            } else if n.step == maxStep {
                above = true
            } else if n.step == minStep {
                above = false
            } else {
                above = stem == .down
            }
            guard above else { continue }
            let apex = n.origin.y - metrics.sp * 1.6
            top = min(top ?? apex, apex)
        }
        return top
    }

    /// Shift every `.staffText` in `out` upward as needed so that
    /// its Y clears the topmost chord/beam in the measure. The
    /// user-supplied vertical offset (already baked into the
    /// element's `origin.y` during placement) is preserved — only
    /// the BASE position changes; the offset shifts relative to it.
    static func autoPlaceStaffText(
        in out: inout [LayoutElement],
        staffMidY: CGFloat,
        metrics: StaffMetrics,
    ) {
        let chordTop = chordTopExtent(in: out, metrics: metrics)
        guard chordTop.isFinite else { return }
        // Default placement Y matches the constant used when the
        // text was first emitted (`staffMidY - sp * 3`). The auto
        // base sits 1.5 sp above the highest chord/beam point.
        let defaultBase = staffMidY - metrics.sp * 3
        let autoBase = chordTop - metrics.sp * 1.5
        // Only shift when the chord is actually pushing into the
        // text's default zone — otherwise leave the layout alone.
        guard autoBase < defaultBase else { return }
        let shift = autoBase - defaultBase
        for i in 0 ..< out.count {
            if case let .staffText(
                text,
                p,
                color,
                isSystem,
            ) = out[i] {
                out[i] = .staffText(
                    text: text,
                    origin: CGPoint(x: p.x, y: p.y + shift),
                    color: color,
                    isSystemText: isSystem,
                )
            }
        }
    }

    /// Shift every `.harmony` in `out` upward as needed so that its
    /// Y clears the topmost chord/beam in the measure. The author's
    /// `<offset y>` is preserved — only the BASE position changes.
    /// Mirrors `autoPlaceStaffText`; harmony sits 1.5 sp above the
    /// chord top (0.5 sp clearance + ~1 sp half-height of the centre-
    /// anchored chord-symbol text body).
    static func autoPlaceHarmony(
        in out: inout [LayoutElement],
        staffMidY: CGFloat,
        metrics: StaffMetrics,
    ) {
        let chordTop = chordTopExtent(in: out, metrics: metrics)
        guard chordTop.isFinite else { return }
        // Default base matches the constant used at emission
        // (`staffTopLocal + harmonyPlacementAbove`, i.e.
        // `staffMidY - sp*2 - sp*2.5`). Auto base puts the symbol's
        // centre 1.5 sp above the highest chord/beam point.
        let staffTopLocal = staffMidY - metrics.sp * 2
        let defaultBase = staffTopLocal + metrics.harmonyPlacementAbove
        let autoBase = chordTop - metrics.sp * 1.5
        guard autoBase < defaultBase else { return }
        let shift = autoBase - defaultBase
        for i in 0 ..< out.count {
            if case let .harmony(lh) = out[i] {
                out[i] = .harmony(LayoutHarmony(
                    harmony: lh.harmony,
                    anchorX: lh.anchorX,
                    y: lh.y + Double(shift),
                    runs: lh.runs,
                    width: lh.width,
                ))
            }
        }
    }

    /// Shift every `.textMark(.tempo, …)` in `out` upward as needed
    /// so that its visible bottom clears the topmost chord/beam in
    /// the measure. Mirrors `autoPlaceStaffText` but accounts for the
    /// `.center` anchor used by `TextMarkRenderer.drawTempo`: the
    /// glyph half-height is added when computing how far above the
    /// chord top the origin must sit. Author's `<offset y>` is
    /// already baked into the element's `origin.y` at emission time;
    /// only the BASE position changes.
    ///
    /// Default tempo origin is `staffMidY - sp * 4`; the autoplaced
    /// origin is `chordTop - sp * 2` (matching MuseScore's TempoText
    /// `min-distance` of 0.5 sp from the skyline plus the glyph's
    /// 1.5 sp half-height).
    static func autoPlaceTempo(
        in out: inout [LayoutElement],
        staffMidY: CGFloat,
        metrics: StaffMetrics,
    ) {
        let chordTop = chordTopExtent(in: out, metrics: metrics)
        guard chordTop.isFinite else { return }
        let defaultBase = staffMidY - metrics.sp * 4
        let autoBase = chordTop - metrics.sp * 2
        guard autoBase < defaultBase else { return }
        let shift = autoBase - defaultBase
        for i in 0 ..< out.count {
            if case let .textMark(.tempo, text, p) = out[i] {
                out[i] = .textMark(
                    kind: .tempo, text: text,
                    origin: CGPoint(x: p.x, y: p.y + shift),
                )
            }
        }
    }

    /// Per-element approximate vertical height (in sp) used when
    /// stacking above-staff text marks. Errs on the generous side
    /// so the gap stays visually clear without pixel-precise font
    /// measurement: tracks one full text line plus small padding so
    /// adjacent items don't touch when their underlying glyphs are
    /// rendered.
    private static func aboveStaffHeight(
        _ element: LayoutElement, metrics: StaffMetrics,
    ) -> CGFloat {
        switch element {
        case .textMark(.tempo, _, _):
            // Tempo strings start with "♩" (U+2669) whose tail
            // dips well below the cap baseline of the digits, so
            // the visible extent is taller than the 12 pt body.
            return metrics.sp * 3.0
        case .staffText:
            return metrics.sp * 2.0 // Edwin 10 pt + line gap
        case .rehearsalMark:
            return metrics.sp * 2.6 // Edwin 14 pt + frame box
        case .harmony:
            // Approximate font height: text is `chordSymbolA` size
            // (10 pt at 5 pt-spatium ≈ 2 sp). Add 0.4 sp gap so
            // adjacent symbols don't touch.
            return metrics.sp * 2.0
        default:
            return metrics.sp * 2.0
        }
    }

    /// Stacking priority. Lower = closer to the staff (placed first
    /// so subsequent items lift above it). Mirrors MuseScore's
    /// default skyline order: chord symbols hug the staff, free-form
    /// staff/system text sits a touch higher, rehearsal marks above
    /// that, and tempo at the very top.
    private static func aboveStaffPriority(
        _ element: LayoutElement,
    ) -> Int? {
        switch element {
        case .harmony:
            return 0 // Closest to the staff (chord symbols hug the staff line).
        case .staffText:
            return 1
        case .rehearsalMark:
            return 2
        case .textMark(.tempo, _, _):
            return 3
        default:
            return nil
        }
    }

    /// How an element's `origin.y` relates to its visual extent —
    /// determined by the anchor each renderer passes to
    /// `GraphicsContext.draw`. Used by stacking math to convert
    /// between "where Y was emitted" and "actual top / bottom of
    /// the rendered glyph."
    private enum AboveStaffAnchor { case bottom, center }

    private static func aboveStaffAnchor(
        _ element: LayoutElement,
    ) -> AboveStaffAnchor {
        switch element {
        case .textMark(.tempo, _, _):
            // `TextMarkRenderer.drawTempo` uses `.leading` (centre-Y).
            return .center
        case .staffText:
            // `StaffTextRenderer` uses `.bottomLeading`.
            return .bottom
        case .harmony:
            // `HarmonyRenderer` anchors at `.leading` (centre Y).
            return .center
        case .rehearsalMark:
            // `RehearsalMarkRenderer` anchors the FRAME box's
            // lower-left corner at `origin`; the box (and the text
            // inside) extend upward.
            return .bottom
        default:
            return .center
        }
    }

    /// Set `origin.y` of an above-staff text mark while preserving
    /// the rest of its payload. Returns the element unchanged when
    /// the kind isn't one of the supported text marks.
    private static func setAboveStaffOriginY(
        _ element: LayoutElement, y: CGFloat,
    ) -> LayoutElement {
        switch element {
        case let .textMark(kind, text, p):
            return .textMark(
                kind: kind, text: text,
                origin: CGPoint(x: p.x, y: y),
            )
        case let .staffText(text, p, color, isSystem):
            return .staffText(
                text: text,
                origin: CGPoint(x: p.x, y: y),
                color: color, isSystemText: isSystem,
            )
        case let .rehearsalMark(text, p, frame, color):
            return .rehearsalMark(
                text: text,
                origin: CGPoint(x: p.x, y: y),
                frame: frame, color: color,
            )
        case let .harmony(lh):
            return .harmony(LayoutHarmony(
                harmony: lh.harmony,
                anchorX: lh.anchorX,
                y: Double(y),
                runs: lh.runs,
                width: lh.width,
            ))
        default:
            return element
        }
    }

    /// Same-tick collision avoidance for above-staff marks. Tempo,
    /// rehearsal mark, staff text and system text all default to a
    /// fixed Y just above the top staff line, so authors who attach
    /// several to the same beat see them pile on top of each other.
    /// MuseScore avoids this with its skyline + autoplace step,
    /// stacking lower-priority items closer to the staff and
    /// pushing higher-priority ones (tempo, rehearsal mark) further
    /// up. We approximate by clustering elements at the same
    /// X column and lifting each one above the previous.
    static func autoStackAboveStaffMarks(
        in out: inout [LayoutElement],
        metrics: StaffMetrics,
    ) {
        let entries = collectAboveStaffEntries(in: out, metrics: metrics)
        guard !entries.isEmpty else { return }
        // Cluster by HORIZONTAL OVERLAP rather than exact-X. Two
        // marks whose extents overlap — e.g. a system tempo placed
        // at the first chord's X and a chord-symbol harmony emitted
        // while still in the measure's header zone (anchored at
        // `contentStartX`, a couple sp to the left) — should stack
        // vertically so neither is partially hidden. Exact-X
        // grouping (the old behaviour) missed pairs like this
        // because their anchor X differs by 1–2 sp.
        let sorted = entries.sorted { $0.xMin < $1.xMin }
        let minDistance = metrics.sp * 0.5
        // Items whose extents are within `tolerance` count as
        // overlapping. A small positive value bridges the tiny gap
        // between two text marks that nominally don't touch but
        // still read as adjacent at typical body sizes.
        let tolerance = metrics.sp * 0.25
        var cluster: [AboveStaffEntry] = []
        var clusterRight: CGFloat = -.infinity
        for entry in sorted {
            if !cluster.isEmpty, entry.xMin <= clusterRight + tolerance {
                cluster.append(entry)
                clusterRight = max(clusterRight, entry.xMax)
            } else {
                if cluster.count > 1 {
                    stackCluster(
                        cluster, in: &out, minDistance: minDistance,
                    )
                }
                cluster = [entry]
                clusterRight = entry.xMax
            }
        }
        if cluster.count > 1 {
            stackCluster(cluster, in: &out, minDistance: minDistance)
        }
    }

    /// Stacking entry for a single above-staff text mark.
    private struct AboveStaffEntry {
        let index: Int
        let originX: CGFloat
        let defaultOriginY: CGFloat
        let height: CGFloat
        let anchor: AboveStaffAnchor
        let priority: Int
        /// Horizontal extent (leading…trailing) used to detect
        /// visual overlap with neighbouring marks. Two marks whose
        /// extents touch — even at slightly different anchor X —
        /// must stack vertically so neither is partially hidden.
        let xMin: CGFloat
        let xMax: CGFloat
    }

    private static func collectAboveStaffEntries(
        in out: [LayoutElement], metrics: StaffMetrics,
    ) -> [AboveStaffEntry] {
        var entries: [AboveStaffEntry] = []
        for (i, el) in out.enumerated() {
            guard let priority = aboveStaffPriority(el) else { continue }
            let p: CGPoint
            switch el {
            case let .textMark(_, _, point),
                 let .staffText(_, point, _, _),
                 let .rehearsalMark(_, point, _, _):
                p = point
            case let .harmony(lh):
                p = CGPoint(x: CGFloat(lh.anchorX), y: CGFloat(lh.y))
            default:
                continue
            }
            let (xMin, xMax) = aboveStaffXRange(
                el, originX: p.x, metrics: metrics,
            )
            entries.append(AboveStaffEntry(
                index: i,
                originX: p.x,
                defaultOriginY: p.y,
                height: aboveStaffHeight(el, metrics: metrics),
                anchor: aboveStaffAnchor(el),
                priority: priority,
                xMin: xMin,
                xMax: xMax,
            ))
        }
        return entries
    }

    /// Approximate horizontal extent (leading…trailing X) for an
    /// above-staff text mark. Conservative on the wide side so
    /// items at *slightly* different anchor X — e.g. a tempo at
    /// `tickColumns[0]` and a harmony placed at the same beat but
    /// emitted while `inHeader` was still true (anchor =
    /// `contentStartX`) — get clustered together and stack
    /// vertically instead of overlapping visually.
    private static func aboveStaffXRange(
        _ element: LayoutElement,
        originX: CGFloat,
        metrics: StaffMetrics,
    ) -> (CGFloat, CGFloat) {
        let width = aboveStaffWidth(element, metrics: metrics)
        switch aboveStaffAnchor(element) {
        case .center:
            return (originX - width / 2, originX + width / 2)
        case .bottom:
            // Anchors like `.bottomLeading` / `.bottom` align the
            // origin at the visible glyph's lower-LEFT edge, so the
            // text extends to the right of `originX`.
            return (originX, originX + width)
        }
    }

    /// Approximate horizontal width (in pt) for an above-staff
    /// mark. Coarse pen-and-paper estimate keyed off character
    /// count — exact font metrics would require running the same
    /// shaper the renderer does, which is too heavy for a layout
    /// pre-pass. Errs slightly large so the cluster grouping
    /// captures visual overlaps that pixel-precise widths would
    /// just barely miss.
    private static func aboveStaffWidth(
        _ element: LayoutElement, metrics: StaffMetrics,
    ) -> CGFloat {
        switch element {
        case let .textMark(.tempo, text, _):
            // Tempo strings start with "♩ = N" (4-6 visible chars).
            // 1.1 sp per char is roomy for a 12 pt body face.
            let chars = CGFloat(max(text.count, 4))
            return chars * metrics.sp * 1.1
        case let .staffText(text, _, _, _):
            // 10 pt Edwin, ~0.9 sp per char.
            let chars = CGFloat(max(text.count, 1))
            return chars * metrics.sp * 0.9
        case let .rehearsalMark(text, _, _, _):
            // 14 pt + boxed frame; frame padding ~1 sp on each side.
            let chars = CGFloat(max(text.count, 1))
            return chars * metrics.sp * 1.1 + metrics.sp * 1.5
        case let .harmony(lh):
            return CGFloat(lh.width)
        default:
            return metrics.sp * 2.0
        }
    }

    /// Stack one X-aligned cluster from closest-to-staff outward,
    /// lifting subsequent entries above whatever sits below them.
    private static func stackCluster(
        _ cluster: [AboveStaffEntry],
        in out: inout [LayoutElement],
        minDistance: CGFloat,
    ) {
        let sorted = cluster.sorted {
            if $0.priority != $1.priority {
                return $0.priority < $1.priority
            }
            return $0.index < $1.index
        }
        // Smallest Y currently consumed by anything in this cluster —
        // above-staff stacking is monotonically upward, so the top of
        // the highest-placed item is the cluster top.
        var stackTop = CGFloat.infinity
        for entry in sorted {
            let (newOriginY, newTop) = stackedPosition(
                for: entry, stackTop: stackTop, minDistance: minDistance,
            )
            stackTop = min(stackTop, newTop)
            out[entry.index] = setAboveStaffOriginY(
                out[entry.index], y: newOriginY,
            )
        }
    }

    /// Decide where one entry should sit given the cluster's current
    /// stack top. Returns `(origin.y to assign, new top of the entry)`.
    private static func stackedPosition(
        for entry: AboveStaffEntry,
        stackTop: CGFloat,
        minDistance: CGFloat,
    ) -> (originY: CGFloat, top: CGFloat) {
        let halfHeight = entry.height / 2
        let defaultTop: CGFloat
        let defaultBottom: CGFloat
        switch entry.anchor {
        case .bottom:
            defaultBottom = entry.defaultOriginY
            defaultTop = defaultBottom - entry.height
        case .center:
            defaultTop = entry.defaultOriginY - halfHeight
            defaultBottom = entry.defaultOriginY + halfHeight
        }
        if defaultBottom <= stackTop - minDistance {
            return (entry.defaultOriginY, defaultTop)
        }
        let newBottom = stackTop - minDistance
        let newTop = newBottom - entry.height
        let newOriginY: CGFloat
        switch entry.anchor {
        case .bottom: newOriginY = newBottom
        case .center: newOriginY = newBottom - halfHeight
        }
        return (newOriginY, newTop)
    }

    /// Horizontal distance from a note's anchor x to its
    /// notehead right edge. Bravura's `noteheadBlack` is 1.18 sp
    /// wide (half-width 0.59 sp); whole / half noteheads are a
    /// touch wider. We pick 0.7 sp as a single constant that
    /// covers every notehead family with a small safety margin
    /// without bleeding into the next note's space.
    static func noteheadHalfExtent(sp: CGFloat) -> CGFloat {
        sp * 0.7
    }

    /// Horizontal width budget for one grace note in measure-local
    /// units. Picked once-and-for-all at 1.5 sp — wide enough for a
    /// 0.6×-scaled notehead + flag, narrow enough that three graces
    /// can stack before bumping into the previous chord.
    static func graceWidth(sp: CGFloat) -> CGFloat {
        sp * 1.5
    }

    /// Lowest Y a chord's geometry occupies BELOW the staff,
    /// in measure-local coords. Used to push lyrics below low
    /// noteheads / ties-below so they don't overlap.
    /// Approximates the "south skyline" MuseScore computes for
    /// collision avoidance in `lyricslayout.cpp`.
    ///
    /// Counts only elements that actually hang below the staff —
    /// noteheads with `step ≤ -4` and tie arcs on the lowest
    /// note. Stem direction is NOT included: stem-down chords
    /// have their stem extending opposite to the lyric direction
    /// in the upper half of the staff (where stem-down is the
    /// engraving rule), and stem-up stems point away from the
    /// lyric area entirely. Including stem length here pushed
    /// every stem-down chord's lyric down by ~0.6 sp,
    /// disconnecting melisma rules from their continuation rules
    /// in subsequent measures.
    static func chordSouthExtent(
        notes: [LayoutChordNote],
        stem: StemDirection,
        staffMidY: CGFloat,
        metrics: StaffMetrics,
    ) -> CGFloat {
        guard let lowestStep = notes.map(\.step).min() else {
            return staffMidY
        }
        let lowestNoteY = staffMidY
            - CGFloat(lowestStep) * metrics.sp / 2
        let noteheadBottom = lowestNoteY + metrics.sp * 0.5
        var south = noteheadBottom
        // Ties on the lowest note arc downward when the stem
        // is up (they go opposite to the stem). The arc peaks
        // ~0.8 sp below the notehead bottom.
        if stem == .up {
            let hasTie = notes.contains { (n: LayoutChordNote) in
                n.tieForward != nil || n.tieBack != nil
            }
            if hasTie {
                south = max(
                    south, noteheadBottom + metrics.sp * 0.8,
                )
            }
        }
        return south
    }

    /// Extract a render-ready subtype string from the Core `Arpeggio` value.
    /// `Arpeggio.subtype` is MuseScore's mscx integer code
    /// (0=NORMAL, 1=UP, 2=DOWN, 3=UP_STRAIGHT, 4=DOWN_STRAIGHT, 5=BRACKET).
    /// `ArpeggioRenderer` consumes "up" / "down" / nil — map accordingly.
    static func arpeggioSubtype(_ arp: Arpeggio) -> String? {
        switch arp.subtype {
        case 1, 3: "up"
        case 2, 4: "down"
        default: nil
        }
    }

    /// Width consumed by the leading header (clef / key sig / time sig)
    /// of the first voice that has such elements. Measured from the left
    /// padding, inclusive of `startPadding`.
    static func headerWidth(
        measure: Measure,
        metrics: StaffMetrics,
        startPadding: CGFloat,
    ) -> CGFloat {
        var w = startPadding
        let voice = measure.voices.first
        guard let elements = voice?.elements else { return w }
        for el in elements {
            switch el {
            case .clef: w += metrics.sp * 3
            case let .keySignature(k):
                w += metrics.sp * (CGFloat(abs(k.concertKey)) + 1.5)
            case .timeSignature: w += metrics.sp * 3
            case .chord:
                return w // first timed element ends the header
            default:
                continue
            }
        }
        return w
    }
}
