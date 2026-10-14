import SheetMusicFoundation

extension ResolvedTempoMap {
    /// A position in the map's own coordinates.
    struct Position: Hashable {
        let measureIndex: Int
        let tickInMeasure: Int
    }

    /// One gradual tempo change as the ramp pass reads it, in the score's nominal ticks.
    struct Ramp: Equatable {
        let startTick: Int
        let ticks: Int
        let factor: Double
        let easing: Spanner.ChangeMethod

        /// `nil` for anything but a playing gradual tempo change's begin side. Its length is measured as
        /// `HairpinRamps.computeEndTick` measures a spanner — the measures it spans plus its fraction offset, at least
        /// one tick.
        init?(_ spanner: Spanner, measureIndex: Int, tickInMeasure: Int, bases: [Int], lengths: [Int], division: Int) {
            guard spanner.kind == .gradualTempoChange, let change = spanner.gradualTempoChange, change.playsBack,
                  bases.indices.contains(measureIndex)
            else { return nil }
            let spanEnd = max(measureIndex, min(lengths.count, measureIndex + max(0, spanner.nextMeasuresOffset)))
            let measureSpan = (measureIndex ..< spanEnd).reduce(0) { $0 + lengths[$1] }
            let fraction = spanner.nextFractionsOffset?.ticks(division: division) ?? 0
            startTick = bases[measureIndex] + tickInMeasure
            ticks = max(1, measureSpan + fraction)
            factor = change.effectiveFactor
            easing = change.easing
        }
    }

    /// MuseScore's gradual pass (`Score::setUpTempoMap`, `engraving/dom/score.cpp:465-496`), the ramps in start order:
    /// each from the tempo in force where it starts (earlier ramps included) to that times its factor, in
    /// `max(8, ticks / division)` eased steps (`easedCurve`), a step written only where no point stands yet and rounded
    /// to six decimals. A step past the last measure is dropped: nothing plays there. A step counts in the beat of the
    /// point in force where its change starts. MuseScore divides by its fixed 480; this divides by the score's own
    /// division, which is the same thing for every MuseScore file.
    func applyingRamps(_ ramps: [Ramp], measureLengths: [Int], division: Int) -> ResolvedTempoMap {
        guard !ramps.isEmpty else { return self }
        var current = self
        for ramp in ramps {
            guard let start = Self.position(ofTick: ramp.startTick, measureLengths: measureLengths) else { continue }
            let inForce = current.point(inForceAtMeasure: start.measureIndex, tickInMeasure: start.tickInMeasure)
            let base = inForce?.beatsPerSecond ?? Self.defaultBeatsPerSecond
            let curve = Self.easedCurve(
                ticks: ramp.ticks, steps: max(8, ramp.ticks / max(1, division)),
                amplitude: base * ramp.factor - base, method: ramp.easing,
            )
            var points = current.points
            var taken = Set(points.map { Position(measureIndex: $0.measureIndex, tickInMeasure: $0.tickInMeasure) })
            for step in curve {
                let tick = ramp.startTick + step.offset
                guard let position = Self.position(ofTick: tick, measureLengths: measureLengths),
                      taken.insert(position).inserted
                else { continue }
                points.append(Point(
                    measureIndex: position.measureIndex, tickInMeasure: position.tickInMeasure,
                    beatsPerSecond: Self.roundTempo(base + step.delta), role: .ramp,
                    beatNote: inForce?.beatNote ?? .quarter, beatDots: inForce?.beatDots ?? 0,
                ))
            }
            current = ResolvedTempoMap(points: Self.inScoreOrder(points))
        }
        return current
    }

    /// `buildEasedValueCurve` (`engraving/types/typesconv.cpp:1928-1945`): `steps + 1` values at `i × (ticks / steps)`
    /// truncated to a tick — of two that truncate alike, the first kept — each `easingFactor(i / steps) × amplitude`,
    /// with MuseScore's float arithmetic, so the sixth decimal agrees.
    static func easedCurve(
        ticks: Int, steps: Int, amplitude: Double, method: Spanner.ChangeMethod,
    ) -> [(offset: Int, delta: Double)] {
        guard steps > 0 else { return [] }
        let durationStep = Float(ticks) / Float(steps)
        var seen: Set<Int> = []
        var curve: [(offset: Int, delta: Double)] = []
        for index in 0 ... steps {
            let offset = Int(Float(index) * durationStep)
            guard seen.insert(offset).inserted else { continue }
            curve.append((offset, Double(easingFactor(Float(index) / Float(steps), method)) * amplitude))
        }
        return curve
    }

    /// `easingFactor` (`typesconv.cpp:1902-1926`): float in and out, with C++'s `std::pow(float, int)` promoting the
    /// intermediate arithmetic to double.
    static func easingFactor(_ x: Float, _ method: Spanner.ChangeMethod) -> Float {
        let eased: Double = switch method {
        case .normal:
            Double(x)
        case .easeIn:
            1 - (1 - Double(x) * Double(x)).squareRoot()
        case .easeOut:
            (1 - Double(x - 1) * Double(x - 1)).squareRoot()
        case .easeInOut where x < 0.5:
            (1 - (1 - Double(2 * x) * Double(2 * x)).squareRoot()) / 2
        case .easeInOut:
            ((1 - Double(-2 * x + 2) * Double(-2 * x + 2)).squareRoot() + 1) / 2
        case .exponential where x == 1:
            Double(x)
        case .exponential:
            1 - pow(2, Double(-10 * x))
        }
        return Float(eased)
    }

    /// `roundTempo` (`engraving/dom/score.cpp:155-158`): six decimals, `floor(x × 10⁶ + 0.5) / 10⁶`.
    static func roundTempo(_ beatsPerSecond: Double) -> Double {
        (beatsPerSecond * 1_000_000 + 0.5).rounded(.down) / 1_000_000
    }

    /// `points` in score order; positions are distinct by construction, so the order is total.
    static func inScoreOrder(_ points: [Point]) -> [Point] {
        points.sorted { ($0.measureIndex, $0.tickInMeasure) < ($1.measureIndex, $1.tickInMeasure) }
    }

    /// The measure and in-measure tick of an absolute nominal tick; `nil` past the last measure.
    static func position(ofTick tick: Int, measureLengths: [Int]) -> Position? {
        var base = 0
        for (index, length) in measureLengths.enumerated() {
            if tick < base + length {
                return tick >= base ? Position(measureIndex: index, tickInMeasure: tick - base) : nil
            }
            base += length
        }
        return nil
    }
}

extension Score {
    /// Every playing gradual tempo change, in start order — staff and voice order within one start: MuseScore keeps its
    /// spanners in a multimap keyed by start tick. Positions are walked as the MIDI ramps walk a voice (chords and
    /// `<location>` shifts advance the tick).
    func gradualTempoRamps(measureLengths: [Int]) -> [ResolvedTempoMap.Ramp] {
        var bases: [Int] = []
        var accumulated = 0
        for length in measureLengths {
            bases.append(accumulated)
            accumulated += length
        }
        var ramps: [ResolvedTempoMap.Ramp] = []
        for entry in allStaves {
            let durations = entry.staff.measures.effectiveMeasureDurations()
            for (measureIndex, measure) in entry.staff.measures.enumerated() where measureIndex < durations.count {
                for voice in measure.voices {
                    var tick = 0
                    for element in voice.elements {
                        switch element {
                        case let .spanner(spanner):
                            if let ramp = ResolvedTempoMap.Ramp(
                                spanner, measureIndex: measureIndex, tickInMeasure: tick,
                                bases: bases, lengths: measureLengths, division: division,
                            ) {
                                ramps.append(ramp)
                            }
                        case let .chord(chord):
                            tick += chord.duration.resolved(in: durations[measureIndex]).ticks(division: division)
                        case let .locationShift(delta):
                            tick += delta.ticks(division: division)
                        default:
                            break
                        }
                    }
                }
            }
        }
        return ramps.enumerated()
            .sorted { ($0.element.startTick, $0.offset) < ($1.element.startTick, $1.offset) }
            .map(\.element)
    }
}
