// swiftlint:disable function_body_length file_length
import CoreGraphics
import SheetMusicCore

@available(macOS 15.0, iOS 16.0, *)
extension LayoutEngine {
    /// Maximum upward extent (smallest Y) of any chord stem-tip,
    /// notehead, or beam in `elements`. Used by the staff-text
    /// auto-placement post-pass. Returns `+infinity` when the
    /// measure has no chords/beams.
    private static func chordTopExtent(
        in elements: [LayoutElement]
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
                _
            ):
                let topNote = notes.map(\.origin.y).min()
                    ?? stemOrigin.y
                let extent = dir == .up
                    ? min(stemOrigin.y, topNote)
                    : topNote
                minY = min(minY, extent)
            case let .beam(from, to, _, _):
                minY = min(minY, from.y, to.y)
            default:
                break
            }
        }
        return minY
    }

    /// Shift every `.staffText` in `out` upward as needed so that
    /// its Y clears the topmost chord/beam in the measure. The
    /// user-supplied vertical offset (already baked into the
    /// element's `origin.y` during placement) is preserved — only
    /// the BASE position changes; the offset shifts relative to it.
    static func autoPlaceStaffText(
        in out: inout [LayoutElement],
        staffMidY: CGFloat,
        metrics: StaffMetrics
    ) {
        let chordTop = chordTopExtent(in: out)
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
                isSystem
            ) = out[i] {
                out[i] = .staffText(
                    text: text,
                    origin: CGPoint(x: p.x, y: p.y + shift),
                    color: color,
                    isSystemText: isSystem
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
        metrics: StaffMetrics
    ) {
        let chordTop = chordTopExtent(in: out)
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
                    width: lh.width
                ))
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
        _ element: LayoutElement, metrics: StaffMetrics
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
        _ element: LayoutElement
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
        _ element: LayoutElement
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
        _ element: LayoutElement, y: CGFloat
    ) -> LayoutElement {
        switch element {
        case let .textMark(kind, text, p):
            return .textMark(
                kind: kind, text: text,
                origin: CGPoint(x: p.x, y: y)
            )
        case let .staffText(text, p, color, isSystem):
            return .staffText(
                text: text,
                origin: CGPoint(x: p.x, y: y),
                color: color, isSystemText: isSystem
            )
        case let .rehearsalMark(text, p, frame, color):
            return .rehearsalMark(
                text: text,
                origin: CGPoint(x: p.x, y: y),
                frame: frame, color: color
            )
        case let .harmony(lh):
            return .harmony(LayoutHarmony(
                harmony: lh.harmony,
                anchorX: lh.anchorX,
                y: Double(y),
                runs: lh.runs,
                width: lh.width
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
        metrics: StaffMetrics
    ) {
        let entries = collectAboveStaffEntries(in: out, metrics: metrics)
        guard !entries.isEmpty else { return }
        // Bucket by integer X — `timedX` returns the same value for
        // elements at the same tick, so an exact comparison is
        // sufficient and we don't need a wider tolerance for items
        // at distinct ticks.
        let groups = Dictionary(grouping: entries) { entry in
            Int(entry.originX.rounded())
        }
        let minDistance = metrics.sp * 0.5
        for (_, group) in groups where group.count > 1 {
            stackCluster(
                group, in: &out, minDistance: minDistance
            )
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
    }

    private static func collectAboveStaffEntries(
        in out: [LayoutElement], metrics: StaffMetrics
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
            entries.append(AboveStaffEntry(
                index: i,
                originX: p.x,
                defaultOriginY: p.y,
                height: aboveStaffHeight(el, metrics: metrics),
                anchor: aboveStaffAnchor(el),
                priority: priority
            ))
        }
        return entries
    }

    /// Stack one X-aligned cluster from closest-to-staff outward,
    /// lifting subsequent entries above whatever sits below them.
    private static func stackCluster(
        _ cluster: [AboveStaffEntry],
        in out: inout [LayoutElement],
        minDistance: CGFloat
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
                for: entry, stackTop: stackTop, minDistance: minDistance
            )
            stackTop = min(stackTop, newTop)
            out[entry.index] = setAboveStaffOriginY(
                out[entry.index], y: newOriginY
            )
        }
    }

    /// Decide where one entry should sit given the cluster's current
    /// stack top. Returns `(origin.y to assign, new top of the entry)`.
    private static func stackedPosition(
        for entry: AboveStaffEntry,
        stackTop: CGFloat,
        minDistance: CGFloat
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
        metrics: StaffMetrics
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
                    south, noteheadBottom + metrics.sp * 0.8
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
        startPadding: CGFloat
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
