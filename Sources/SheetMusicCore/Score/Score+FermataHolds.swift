import SheetMusicFoundation

/// One fermata's hold, expressed against the bar it sits in.
///
/// A fermata has no notated duration of its own — it stretches the chord it is anchored to. Every
/// clock that has to agree with playback needs the same set of holds: the MIDI renderer turns them
/// into tempo bookends around the held chord, and the notated-time API adds their extra time to the
/// bar's own length. Deriving them once here is what keeps those answers equal.
public struct FermataHold: Sendable, Equatable {
    public let measureIndex: Int
    /// Ticks from the bar's downbeat to the held chord's onset.
    public let startTickInMeasure: Int
    /// The held chord's own notated length in ticks.
    public let ticks: Int
    /// MIDI hold ratio (`Fermata.timeStretch`), ≥ 1. The chord sounds for `ticks * stretch`.
    public let stretch: Double

    public init(measureIndex: Int, startTickInMeasure: Int, ticks: Int, stretch: Double) {
        self.measureIndex = measureIndex
        self.startTickInMeasure = startTickInMeasure
        self.ticks = ticks
        self.stretch = stretch
    }

    /// Time the hold ADDS, in ticks at the bar's own tempo — the whole point of the type for a
    /// caller that only needs durations rather than a tempo map.
    public var extraTicks: Double {
        Double(ticks) * max(0, stretch - 1)
    }
}

extension Score {
    /// Every fermata in the score, resolved to the chord it holds.
    ///
    /// Merged across staves: MuseScore replicates a system fermata onto every staff, and a hold is
    /// a property of the score's clock rather than of one part, so two staves marking the same
    /// chord collapse to one hold and the longer stretch wins where they disagree. Sorted by
    /// `(measureIndex, startTickInMeasure)`.
    public func fermataHolds() -> [FermataHold] {
        var byPosition: [Position: FermataHold] = [:]
        for entry in allStaves {
            let measureDurations = entry.staff.measures.effectiveMeasureDurations()
            for (measureIndex, measure) in entry.staff.measures.enumerated() {
                let measureDuration = measureIndex < measureDurations.count
                    ? measureDurations[measureIndex]
                    : Fraction(numerator: 4, denominator: 4)
                for voice in measure.voices {
                    for hold in Self.holds(
                        in: voice, measureIndex: measureIndex,
                        measureDuration: measureDuration, division: division,
                    ) {
                        let key = Position(
                            measureIndex: hold.measureIndex,
                            startTickInMeasure: hold.startTickInMeasure,
                            ticks: hold.ticks,
                        )
                        if let existing = byPosition[key], existing.stretch >= hold.stretch {
                            continue
                        }
                        byPosition[key] = hold
                    }
                }
            }
        }
        return byPosition.values.sorted {
            ($0.measureIndex, $0.startTickInMeasure, $0.ticks)
                < ($1.measureIndex, $1.startTickInMeasure, $1.ticks)
        }
    }

    private struct Position: Hashable {
        let measureIndex: Int
        let startTickInMeasure: Int
        let ticks: Int
    }

    /// Anchor every `.fermata` in one voice to a chord and measure the resulting hold. Forward
    /// search first — MusicXML writes the fermata before its target — then a backward fallback for
    /// the MSCX shape, where it is a sibling AFTER the chord. A fermata with no chord in either
    /// direction is dropped.
    private static func holds(
        in voice: Voice, measureIndex: Int, measureDuration: Fraction, division: Int,
    ) -> [FermataHold] {
        // Onset of each chord within the bar, so both searches are O(1) lookups. `.locationShift`
        // jogs the running tick exactly as the renderer's and the timeline's walkers do.
        var chordStarts: [Int?] = Array(repeating: nil, count: voice.elements.count)
        var runningTick = 0
        for (index, element) in voice.elements.enumerated() {
            switch element {
            case let .chord(chord):
                chordStarts[index] = runningTick
                runningTick += chord.duration
                    .resolved(in: measureDuration)
                    .ticks(division: division)
            case let .locationShift(delta):
                runningTick += delta.ticks(division: division)
            default:
                break
            }
        }

        var holds: [FermataHold] = []
        for (index, element) in voice.elements.enumerated() {
            guard case let .fermata(fermata) = element else { continue }
            guard let anchor = anchorIndex(for: index, in: voice, chordStarts: chordStarts),
                  case let .chord(chord) = voice.elements[anchor],
                  let start = chordStarts[anchor]
            else { continue }
            holds.append(FermataHold(
                measureIndex: measureIndex,
                startTickInMeasure: start,
                ticks: chord.duration.resolved(in: measureDuration).ticks(division: division),
                stretch: fermata.timeStretch,
            ))
        }
        return holds
    }

    private static func anchorIndex(
        for index: Int, in voice: Voice, chordStarts: [Int?],
    ) -> Int? {
        if index + 1 < voice.elements.count {
            for candidate in (index + 1) ..< voice.elements.count
                where chordStarts[candidate] != nil
            {
                return candidate
            }
        }
        if index > 0 {
            for candidate in stride(from: index - 1, through: 0, by: -1)
                where chordStarts[candidate] != nil
            {
                return candidate
            }
        }
        return nil
    }
}
