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
            case .chord(let notes, _, let dir, let stemOrigin,
                        _, _, _, _):
                let topNote = notes.map(\.origin.y).min()
                    ?? stemOrigin.y
                let extent = dir == .up
                    ? min(stemOrigin.y, topNote)
                    : topNote
                minY = min(minY, extent)
            case .beam(let from, let to, _, _):
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
        for i in 0..<out.count {
            if case .staffText(let text, let p, let color,
                               let isSystem) = out[i] {
                out[i] = .staffText(
                    text: text,
                    origin: CGPoint(x: p.x, y: p.y + shift),
                    color: color,
                    isSystemText: isSystem)
            }
        }
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
                    south, noteheadBottom + metrics.sp * 0.8)
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
        case 1, 3: return "up"
        case 2, 4: return "down"
        default: return nil
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
            case .keySignature(let k):
                w += metrics.sp * (CGFloat(abs(k.concertKey)) + 1.5)
            case .timeSignature: w += metrics.sp * 3
            case .chord, .rest:
                return w   // first timed element ends the header
            default:
                continue
            }
        }
        return w
    }
}
