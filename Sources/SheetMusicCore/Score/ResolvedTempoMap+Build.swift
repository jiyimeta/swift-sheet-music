import SheetMusicFoundation

extension Score {
    /// The score's tempo map (`ResolvedTempoMap`), built on each call — a consumer that reads it many times builds it
    /// once.
    public func resolvedTempoMap() -> ResolvedTempoMap {
        ResolvedTempoMap.markings(lane: systemMeasures.values, division: division)
    }
}

extension ResolvedTempoMap {
    /// MuseScore's text pass over the tempo markings, in score order (`Score::rebuildTempoAndTimeSigMaps`,
    /// `engraving/dom/score.cpp:579-600`) — the map fermata holds are measured against, before gradual changes:
    ///
    /// - a marking left out of playback (`playsBack == false`) sets nothing;
    /// - an ordinary marking sets its own tempo, and the first one becomes "tempo primo";
    /// - "a tempo" that follows its text reinstates the tempo in force where it stands — the last point's, so a gradual
    ///   change before it is undone; "tempo primo" that follows its text sets tempo primo, or 120 BPM;
    /// - either one that does not follow its text plays its own number.
    ///
    /// A point carries the beat a reader counts it in: its marking's own, or the reinstated one's. One position holds
    /// one point, the last marking there winning (`TempoMap::setTempo` replaces). A relative marking ("♩ = ♪") plays
    /// its stored tempo: MuseScore never saves `isRelative`, so after a load it does too. Markings keep their exact bps
    /// (MuseScore rounds to six decimals, which every saved file already is).
    package static func markings(lane: [SystemMeasure], division: Int) -> ResolvedTempoMap {
        var points: [Point] = []
        var primo: Point?
        for (measureIndex, tickInMeasure, tempo) in tempos(in: lane, division: division) where tempo.playsBack {
            let own = Point(
                measureIndex: measureIndex, tickInMeasure: tickInMeasure, beatsPerSecond: tempo.beatsPerSecond,
                role: .marking, beatNote: tempo.beatNote, beatDots: tempo.beatDots,
            )
            let fallback = Point(
                measureIndex: measureIndex, tickInMeasure: tickInMeasure, beatsPerSecond: defaultBeatsPerSecond,
                role: .marking,
            )
            let source: Point = switch tempo.textType {
            case .aTempo where tempo.followText: points.last ?? fallback
            case .tempoPrimo where tempo.followText: primo ?? fallback
            default: own
            }
            if tempo.textType == .normal, primo == nil {
                primo = own
            }
            let point = Point(
                measureIndex: measureIndex, tickInMeasure: tickInMeasure, beatsPerSecond: source.beatsPerSecond,
                role: .marking, beatNote: source.beatNote, beatDots: source.beatDots,
            )
            if let last = points.last, last.measureIndex == measureIndex, last.tickInMeasure == tickInMeasure {
                points[points.count - 1] = point
            } else {
                points.append(point)
            }
        }
        return ResolvedTempoMap(points: points)
    }

    /// Every tempo marking of `lane` with its position, in score order — two at one position in lane order.
    static func tempos(
        in lane: [SystemMeasure], division: Int,
    ) -> [(measureIndex: Int, tickInMeasure: Int, tempo: Tempo)] {
        var result: [(measureIndex: Int, tickInMeasure: Int, tempo: Tempo)] = []
        for (measureIndex, measure) in lane.enumerated() {
            var inMeasure: [(tick: Int, offset: Int, tempo: Tempo)] = []
            for (offset, positioned) in measure.elements.enumerated() {
                guard case let .tempo(tempo) = positioned.element else { continue }
                inMeasure.append((positioned.position.ticks(division: division), offset, tempo))
            }
            inMeasure.sort { ($0.tick, $0.offset) < ($1.tick, $1.offset) }
            result += inMeasure.map { (measureIndex, $0.tick, $0.tempo) }
        }
        return result
    }
}
