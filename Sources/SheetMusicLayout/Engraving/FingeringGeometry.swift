#if canImport(CoreGraphics)
    import CoreGraphics
#endif
import SheetMusicCore
import SheetMusicFoundation

/// The arithmetic of MuseScore's fingering placement, kept apart from the pass that applies it.
enum FingeringGeometry {
    /// `Fingering::calculatePlacement` (`dom/fingering.cpp:88-99`), unless the element says `<placement>`: with
    /// another voice under the chord, below when the chord's stem points down; else below on the last staff of a
    /// multi-staff part (a grand staff's left hand), above otherwise.
    static func side(
        explicit: Placement?, chordUp: Bool, hasVoices: Bool, staffIndexInPart: Int, staffCountInPart: Int,
    ) -> Placement {
        if let explicit { return explicit }
        if hasVoices { return chordUp ? .above : .below }
        return staffCountInPart > 1 && staffIndexInPart == staffCountInPart - 1 ? .below : .above
    }

    /// `Measure::hasVoices` (`dom/measure.cpp:2360-2415`): whether a voice other than the first holds a visible chord
    /// or rest sounding in `[chordTick, chordTick + chordTicks)`, measure-relative ticks.
    static func hasVoices(
        in measure: Measure, chordTick: Int, chordTicks: Int, division: Int, measureDuration: Fraction,
    ) -> Bool {
        let end = chordTick + chordTicks
        for voice in measure.voices.dropFirst() {
            var tick = 0
            for element in voice.elements {
                guard tick < end else { break }
                switch element {
                case let .chord(chord):
                    let ticks = chord.duration.resolved(in: measureDuration).ticks(division: division)
                    let visible = element.isRest
                        ? chord.visible
                        : chord.stemVisible || chord.notes.contains(where: \.visible)
                    if tick + ticks > chordTick, visible { return true }
                    tick += ticks
                case let .locationShift(delta):
                    tick += delta.ticks(division: division)
                default:
                    break
                }
            }
        }
        return false
    }

    /// The vertical centers of a chord's fingering blocks on one side, nearest the chord first
    /// (`ChordLayout::layoutChordBaseFingering`, `chordlayout.cpp:3028-3066`; `TLayout::layoutFingering`'s
    /// `bbox().height() * .25`): the first block clears `limit` by `minDistance`, each next one sits a quarter of its
    /// own height beyond the previous.
    static func stackedCenters(heights: [CGFloat], side: Placement, limit: CGFloat, minDistance: CGFloat) -> [CGFloat] {
        let sign: CGFloat = side == .above ? -1 : 1
        var edge = limit + sign * minDistance
        var centers: [CGFloat] = []
        for (index, height) in heights.enumerated() {
            if index > 0 { edge += sign * 0.25 * height }
            centers.append(edge + sign * height / 2)
            edge += sign * height
        }
        return centers
    }
}
