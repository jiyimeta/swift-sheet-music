import SheetMusicCore
import SheetMusicFoundation

/// One capo of a staff, at the original (pre-repeat) tick it stands at.
struct CapoPoint: Equatable {
    let tick: Int
    let fret: Int
    let ignoredStrings: Set<Int>
    /// Whether it transposes playback: active, and in MuseScore's playback-only mode — which a file without
    /// `<transposeMode>` (every 4.6 file) is, by the property default.
    let plays: Bool
}

/// The capo in force for a note's playback. MuseScore adds the fret of the staff's capo at the chord's segment tick
/// to the sounding pitch when that capo is active and transposes playback only, except on a string the capo skips
/// (`Note::ottaveCapoFret`, `dom/note.cpp:2563-2580`). The capo is staff-bound: one in any voice governs every voice.
enum CapoRanges {
    /// Every capo on `staff`, in original-tick order; at one tick, later voices' capos come after earlier ones.
    static func collect(staff: Staff, division: Int, tempoMap: ResolvedTempoMap) -> [CapoPoint] {
        var points: [CapoPoint] = []
        var measureBase = 0
        let measureDurations = staff.measures.effectiveMeasureDurations()
        for (measureIndex, measure) in staff.measures.enumerated() {
            let measureDuration = measureIndex < measureDurations.count
                ? measureDurations[measureIndex]
                : Fraction(numerator: 4, denominator: 4)
            for voice in measure.voices {
                var runningTick = measureBase
                for element in voice.elements {
                    switch element {
                    case let .capo(capo):
                        points.append(CapoPoint(
                            tick: runningTick, fret: capo.fretPosition, ignoredStrings: capo.ignoredStrings,
                            plays: capo.isActive && (capo.transposeMode ?? .playbackOnly) == .playbackOnly,
                        ))
                    case let .chord(chord):
                        runningTick += chord.duration.resolved(in: measureDuration).ticks(division: division)
                    case let .locationShift(delta):
                        runningTick += delta.ticks(division: division)
                    default:
                        break
                    }
                }
            }
            measureBase += MidiRenderer.measureTicks(
                measure: measure, division: division, measureDuration: measureDuration,
                measureIndex: measureIndex, tempoMap: tempoMap,
            )
        }
        // Stable: two capos at one tick keep their walk order, and the later one wins in `active`.
        return points.enumerated().sorted { ($0.element.tick, $0.offset) < ($1.element.tick, $1.offset) }
            .map(\.element)
    }

    /// The capo that transposes a note at `tick`, or `nil` when none is in force or the one in force is inactive or
    /// transposes the notation or the tab only.
    static func active(in points: [CapoPoint], at tick: Int) -> CapoPoint? {
        guard let point = points.last(where: { $0.tick <= tick }), point.plays else { return nil }
        return point
    }

    /// `chord` with every note on a string `capo` skips lowered by its fret, so the one uniform shift by the fret that
    /// follows leaves those notes where they were. Unclamped: the shift clamps.
    static func compensate(_ chord: Chord, for capo: CapoPoint) -> Chord {
        guard !capo.ignoredStrings.isEmpty, capo.fret != 0 else { return chord }
        func compensated(_ note: Note) -> Note {
            guard let string = note.string, capo.ignoredStrings.contains(string) else { return note }
            var copy = note
            copy.pitch -= capo.fret
            return copy
        }
        var result = chord
        result.notes.mapValues(compensated)
        result.graceNotesBefore.mapValues { grace in
            var copy = grace
            copy.notes.mapValues(compensated)
            return copy
        }
        result.graceNotesAfter.mapValues { grace in
            var copy = grace
            copy.notes.mapValues(compensated)
            return copy
        }
        return result
    }
}
