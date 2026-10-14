import SheetMusicFoundation

/// The tempo a score plays at, position by position: MuseScore's `TempoMap` (`engraving/dom/tempo.h`), built the way
/// `Score::rebuildTempoAndTimeSigMaps` builds it (`engraving/dom/score.cpp:578-627`).
///
/// Measure-relative on purpose: each consumer projects the points onto its own tick base — the SMF's repeat-unrolled
/// ticks, the cursor timeline's notated ticks, a bar's seconds — so none of them reads a raw `Tempo`, and none can
/// disagree with another about what plays. Points are in score order.
public struct ResolvedTempoMap: Sendable, Equatable {
    /// MuseScore's `Constants::DEFAULT_TEMPO`, 120 quarter notes a minute: in force before the first point.
    public static let defaultBeatsPerSecond = 2.0

    /// One tempo taking effect at a position.
    public struct Point: Sendable, Equatable {
        public enum Role: Sendable, Equatable {
            /// A tempo marking (`SystemElement.tempo`).
            case marking
            /// One step of a gradual tempo change.
            case ramp
        }

        public let measureIndex: Int
        public let tickInMeasure: Int
        /// Quarter notes per second — `Tempo.beatsPerSecond`'s unit.
        public let beatsPerSecond: Double
        public let role: Role
        /// The beat a reader counts this tempo in: the marking's own, or for a ramp step the beat of the marking in
        /// force where the change starts.
        public let beatNote: NoteDuration
        public let beatDots: Int

        package init(
            measureIndex: Int, tickInMeasure: Int, beatsPerSecond: Double, role: Role,
            beatNote: NoteDuration = .quarter, beatDots: Int = 0,
        ) {
            self.measureIndex = measureIndex
            self.tickInMeasure = tickInMeasure
            self.beatsPerSecond = beatsPerSecond
            self.role = role
            self.beatNote = beatNote
            self.beatDots = beatDots
        }

        /// The SMF tempo meta value.
        public var microsecondsPerQuarter: Int {
            Tempo.microsecondsPerQuarter(beatsPerSecond: beatsPerSecond)
        }

        /// The tempo in its beat — the number a marking prints for it (`Tempo.beatsPerMinute`).
        public var beatsPerMinute: Double {
            beatsPerSecond * 60 / Tempo.lengthInQuarters(of: beatNote, dots: beatDots)
        }

        /// The beat as Bravura "Individual notes" glyphs (`Tempo.beatGlyph`).
        public var beatGlyph: String {
            Tempo.beatGlyph(note: beatNote, dots: beatDots)
        }
    }

    public let points: [Point]

    /// `points` must already be in score order: the lookups binary-search them.
    package init(points: [Point] = []) {
        assert(
            zip(points, points.dropFirst()).allSatisfy {
                ($0.measureIndex, $0.tickInMeasure) <= ($1.measureIndex, $1.tickInMeasure)
            },
            "ResolvedTempoMap points must be sorted by position",
        )
        self.points = points
    }
}

extension ResolvedTempoMap {
    /// The last point at or before a position in score order; `nil` before the first.
    public func point(inForceAtMeasure measureIndex: Int, tickInMeasure tick: Int) -> Point? {
        var low = 0
        var high = points.count
        while low < high {
            let mid = (low + high) / 2
            if (points[mid].measureIndex, points[mid].tickInMeasure) <= (measureIndex, tick) {
                low = mid + 1
            } else {
                high = mid
            }
        }
        return low > 0 ? points[low - 1] : nil
    }

    /// Quarter notes per second in force at a position; `defaultBeatsPerSecond` before the first point.
    public func beatsPerSecond(atMeasure measureIndex: Int, tickInMeasure tick: Int) -> Double {
        point(inForceAtMeasure: measureIndex, tickInMeasure: tick)?.beatsPerSecond ?? Self.defaultBeatsPerSecond
    }

    /// One measure's points, in order.
    public func points(inMeasure measureIndex: Int) -> ArraySlice<Point> {
        points[firstIndex(atOrAfterMeasure: measureIndex) ..< firstIndex(atOrAfterMeasure: measureIndex + 1)]
    }

    private func firstIndex(atOrAfterMeasure measureIndex: Int) -> Int {
        var low = 0
        var high = points.count
        while low < high {
            let mid = (low + high) / 2
            if points[mid].measureIndex < measureIndex {
                low = mid + 1
            } else {
                high = mid
            }
        }
        return low
    }
}
