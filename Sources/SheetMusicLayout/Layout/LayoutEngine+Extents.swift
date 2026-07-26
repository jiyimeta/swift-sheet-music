#if canImport(CoreGraphics)
    import CoreGraphics
#endif
import SheetMusicCore

extension LayoutEngine {
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
