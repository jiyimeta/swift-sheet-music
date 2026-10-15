import SheetMusicFoundation

extension Score {
    /// One entry in a part's sound timeline: the position from which `instrument` sounds.
    package struct SoundPoint: Sendable, Equatable {
        package let measureIndex: Int
        package let position: MeasurePosition
        package let instrument: Instrument
        /// Index of an earlier point that sounds exactly like this one (same instrument in force, same technique):
        /// it shares that point's MIDI channels instead of taking a fresh set.
        package let reusesPoint: Int?
        /// The earlier point, and the index of its `<Channel>`, a technique point sounds through: a technique that
        /// selects one of the instrument's own channels plays on the channel MuseScore already gave it, rather than
        /// taking a fresh one.
        package let flavourSource: FlavourSource?
        /// For a play technique's point, the index of the instrument point (the seed or a change) it modifies; `nil`
        /// for an instrument point. A technique's sound that can have no MIDI channel of its own sounds as that point.
        package let basePoint: Int?

        package struct FlavourSource: Sendable, Equatable {
            package let point: Int
            package let flavour: Int
        }
    }

    /// A play technique on a part, at its place in the bar.
    private struct TechniqueEvent {
        let measureIndex: Int
        let position: MeasurePosition
        let technique: PlayingTechnique
    }

    /// A part's play techniques in time order: every annotated staff text on the part that plays back with a
    /// technique MuseScore knows (`PlaybackContext::updatePlayTechMap`, `playback/playbackcontext.cpp:430-451`).
    /// Sorted rather than trusted to the lane's order — the merge below depends on it, and a lane built in memory
    /// need not keep a bar's elements in time order. The sort is stable, so two at one position keep theirs.
    private func techniqueEvents(forPart partIndex: Int) -> [TechniqueEvent] {
        var events: [TechniqueEvent] = []
        for (measureIndex, measure) in systemMeasures.enumerated() {
            for positioned in measure.elements {
                guard case let .staffText(text) = positioned.element,
                      case let .playTechnique(technique, playsBack)? = text.annotation, playsBack,
                      (positioned.originalStaff ?? Score.canonicalStaff).partIndex == partIndex
                else { continue }
                if case .other = technique { continue }
                events.append(TechniqueEvent(
                    measureIndex: measureIndex, position: positioned.position, technique: technique,
                ))
            }
        }
        let division = division
        return events.enumerated().sorted { lhs, rhs in
            let left = (lhs.element.measureIndex, lhs.element.position.ticks(division: division), lhs.offset)
            let right = (rhs.element.measureIndex, rhs.element.position.ticks(division: division), rhs.offset)
            return left < right
        }.map(\.element)
    }

    /// Builds the points: a sound is the instrument in force (its index in the instrument timeline) and the
    /// technique's channel name, `nil` for the instrument's own sound. A sound heard before is a reuse of its first
    /// point.
    private struct SoundTimelineBuilder {
        struct Key: Hashable {
            let base: Int
            let sound: String?
        }

        let base: [InstrumentChangePoint]
        private(set) var points: [SoundPoint] = []
        private var firstPoint: [Key: Int] = [:]
        private var lastKey = Key(base: 0, sound: nil)
        private var baseIndex = 0

        init(base: [InstrumentChangePoint]) {
            self.base = base
        }

        /// An instrument change (or the seed) is always a point, as in the instrument timeline.
        mutating func addInstrument(_ index: Int) {
            baseIndex = index
            let point = base[index]
            emit(
                Key(base: index, sound: nil), point.measureIndex, point.position, point.instrument, nil,
                basePoint: nil, always: true,
            )
        }

        /// A technique is a point only when it changes the sound.
        mutating func addTechnique(_ event: TechniqueEvent) {
            let instrument = base[baseIndex].instrument
            let outcome = PlayTechniqueSound.resolve(event.technique, for: instrument)
            let sound: String? = outcome == .keep ? nil : PlayTechniqueSound.channelName(event.technique)
            // The instrument point in force: instrument points are never reuses, so it is its key's first point.
            let owner = firstPoint[Key(base: baseIndex, sound: nil)]
            var source: SoundPoint.FlavourSource?
            if case let .channel(channel) = outcome, let flavour = instrument.channels.firstIndex(of: channel),
               let owner
            {
                source = SoundPoint.FlavourSource(point: owner, flavour: flavour)
            }
            let variant = PlayTechniqueSound.variant(of: instrument, technique: event.technique, outcome: outcome)
            emit(
                Key(base: baseIndex, sound: sound), event.measureIndex, event.position, variant, source,
                basePoint: owner, always: false,
            )
        }

        private mutating func emit(
            _ key: Key, _ measureIndex: Int, _ position: MeasurePosition, _ instrument: Instrument,
            _ flavourSource: SoundPoint.FlavourSource?, basePoint: Int?, always: Bool,
        ) {
            guard always || key != lastKey else { return }
            let reuses = firstPoint[key]
            points.append(SoundPoint(
                measureIndex: measureIndex, position: position, instrument: instrument, reusesPoint: reuses,
                flavourSource: reuses == nil ? flavourSource : nil, basePoint: basePoint,
            ))
            if reuses == nil { firstPoint[key] = points.count - 1 }
            lastKey = key
        }
    }

    /// `instrumentTimeline(forPart:)` with the part's play techniques applied: a technique that changes the sound
    /// adds a point, as an instrument change does, until the next technique or instrument change. A score with no
    /// technique gets its instrument timeline point for point.
    package func soundTimeline(forPart partIndex: Int) -> [SoundPoint] {
        let base = instrumentTimeline(forPart: partIndex)
        let techniques = techniqueEvents(forPart: partIndex)
        guard !base.isEmpty, !techniques.isEmpty else {
            return base.map {
                SoundPoint(
                    measureIndex: $0.measureIndex, position: $0.position, instrument: $0.instrument,
                    reusesPoint: nil, flavourSource: nil, basePoint: nil,
                )
            }
        }
        var builder = SoundTimelineBuilder(base: base)
        builder.addInstrument(0)
        var nextBase = 1
        var nextTechnique = 0
        /// Merge the two streams; at one position an instrument change comes before a technique.
        func tick(_ measureIndex: Int, _ position: MeasurePosition) -> (Int, Int) {
            (measureIndex, position.ticks(division: division))
        }
        while nextBase < base.count || nextTechnique < techniques.count {
            let takeBase = nextTechnique == techniques.count || nextBase < base.count
                && tick(base[nextBase].measureIndex, base[nextBase].position)
                <= tick(techniques[nextTechnique].measureIndex, techniques[nextTechnique].position)
            if takeBase {
                builder.addInstrument(nextBase)
                nextBase += 1
            } else {
                builder.addTechnique(techniques[nextTechnique])
                nextTechnique += 1
            }
        }
        return builder.points
    }
}
