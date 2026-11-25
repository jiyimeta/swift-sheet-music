import SheetMusicCore
import SheetMusicFoundation

/// How one note of an ornamented chord is played: the figure, and how far its two neighbors stand from it.
struct NoteOrnament: Equatable {
    var figure: OrnamentFigure
    /// A later link of a tie whose first note started the figure.
    var isContinuing: Bool
    var semitonesAbove: Int
    var semitonesBelow: Int

    /// Semitones from the written note to `step` of the figure.
    func semitones(forStep step: Int) -> Int {
        step < 0 ? step * semitonesBelow : step * semitonesAbove
    }
}

/// One trill line, resolved to the original (pre-repeat) ticks it covers on its own voice.
struct TrillRange: Equatable {
    var startTick: Int
    var endTick: Int
    var type: TrillType

    /// The line a chord sounding `[start, end)` is played under: any that overlaps it, as MuseScore asks
    /// (`SpannerFilter::isPlayable`), the latest to start when several do.
    static func active(in ranges: [TrillRange], from start: Int, to end: Int) -> TrillType? {
        ranges.filter { $0.startTick < end && $0.endTick > start }.max { $0.startTick < $1.startTick }?.type
    }

    static func collect(
        staff: Staff, voiceIndex: Int, division: Int, tempoMap: ResolvedTempoMap,
    ) -> [TrillRange] {
        var ranges: [TrillRange] = []
        var measureBase = 0
        let durations = staff.measures.effectiveMeasureDurations()
        for (measureIndex, measure) in staff.measures.enumerated() {
            let duration = durations.indices.contains(measureIndex)
                ? durations[measureIndex] : Fraction(numerator: 4, denominator: 4)
            if measure.voices.indices.contains(voiceIndex) {
                var tick = measureBase
                for element in measure.voices[voiceIndex].elements {
                    switch element {
                    case let .spanner(spanner) where spanner.kind == .trill:
                        // The end side carries no payload.
                        guard let payload = spanner.trill else { break }
                        let end = OttavaRanges.computeEndTick(
                            startTick: tick, startMeasureIndex: measureIndex, spanner: spanner,
                            measures: staff.measures, division: division, tempoMap: tempoMap,
                        )
                        ranges.append(TrillRange(startTick: tick, endTick: end, type: payload.type))
                    case let .chord(chord):
                        tick += chord.duration.resolved(in: duration).ticks(division: division)
                    case let .locationShift(delta):
                        tick += delta.ticks(division: division)
                    default:
                        break
                    }
                }
            }
            measureBase += MidiRenderer.measureTicks(
                measure: measure, division: division, measureDuration: duration,
                measureIndex: measureIndex, tempoMap: tempoMap,
            )
        }
        return ranges
    }
}

/// The ornaments of one voice, resolved chord by chord as the walk reaches them.
struct OrnamentPlanner {
    private let staff: Staff
    private let division: Int
    private let durations: [Fraction]
    private let trillRanges: [TrillRange]
    /// Unpitched staves have no neighboring note to alternate with.
    private let isPitched: Bool
    private let keyByMeasure: [Int]
    private let compoundByMeasure: [Bool]
    /// The trill an open tie carries into its next chord.
    private var openFigure: OrnamentFigure?

    init(staff: Staff, voiceIndex: Int, isDrumset: Bool, division: Int, tempoMap: ResolvedTempoMap) {
        self.staff = staff
        self.division = division
        durations = staff.measures.effectiveMeasureDurations()
        trillRanges = TrillRange.collect(
            staff: staff, voiceIndex: voiceIndex, division: division, tempoMap: tempoMap,
        )
        isPitched = !isDrumset && staff.group != "percussion"
        var key = 0
        var isCompound = false
        var keys: [Int] = []
        var compounds: [Bool] = []
        for measure in staff.measures {
            // A signature standing inside the bar takes effect in the bars after it.
            var later: Int?
            for voice in measure.voices {
                var isAtStart = true
                for element in voice.elements {
                    switch element {
                    case .chord: isAtStart = false
                    case let .keySignature(signature):
                        if isAtStart { key = signature.concertKey } else { later = signature.concertKey }
                    case let .timeSignature(meter):
                        isCompound = meter.numerator > 3 && meter.numerator.isMultiple(of: 3)
                    default: break
                    }
                }
            }
            keys.append(key)
            compounds.append(isCompound)
            key = later ?? key
        }
        keyByMeasure = keys
        compoundByMeasure = compounds
    }

    func isCompoundMeter(atMeasure index: Int) -> Bool {
        compoundByMeasure.indices.contains(index) && compoundByMeasure[index]
    }

    /// How each note of `chord` is ornamented, by its place in `chord.notes`; `nil` where it is played plain. Reads
    /// the chord as the score has it, before a capo or an ottava moves it. `tick` is its original tick, `tickInMeasure`
    /// its place in the bar.
    mutating func ornaments(
        for chord: Chord, measureIndex: Int, tick: Int, tickInMeasure: Int, ticks: Int,
    ) -> [NoteOrnament?] {
        guard isPitched, !chord.notes.isEmpty else {
            openFigure = nil
            return []
        }
        let carried = openFigure
        let written = chord.ornaments.lazy.compactMap { ornament in
            OrnamentFigure.figure(for: ornament).map { (ornament: Optional(ornament), figure: $0) }
        }.first
        let own = written ?? TrillRange.active(in: trillRanges, from: tick, to: tick + ticks)
            .map { (ornament: nil, figure: OrnamentFigure.figure(for: $0)) }
        openFigure = nil
        guard carried != nil || own != nil else { return [] }
        return chord.notes.map { note in
            let isContinuing = note.tieBack != nil
            // A tied note's own ornament is never reached: the note started with the tie's first link.
            guard let figure = isContinuing ? carried : own?.figure, note.play,
                  let above = interval(
                      own?.ornament?.intervalAbove, up: true, from: note,
                      measureIndex: measureIndex, tickInMeasure: tickInMeasure,
                  ),
                  let below = interval(
                      own?.ornament?.intervalBelow, up: false, from: note,
                      measureIndex: measureIndex, tickInMeasure: tickInMeasure,
                  )
            else { return nil }
            if note.tieForward != nil, figure.repeatsBody { openFigure = figure }
            return NoteOrnament(
                figure: figure, isContinuing: isContinuing, semitonesAbove: above, semitonesBelow: below,
            )
        }
    }

    private func interval(
        _ stated: ChordOrnament.Interval?, up: Bool, from note: Note, measureIndex: Int, tickInMeasure: Int,
    ) -> Int? {
        let interval = stated ?? .default
        if let semitones = interval.semitones { return semitones }
        guard staff.measures.indices.contains(measureIndex), durations.indices.contains(measureIndex)
        else { return nil }
        return MeasureAccidentals.semitones(
            from: note, bySteps: up ? interval.staffSteps : -interval.staffSteps, tick: tickInMeasure,
            in: staff.measures[measureIndex], keySig: keyByMeasure[measureIndex],
            division: division, measureDuration: durations[measureIndex],
        ).map(abs)
    }
}
