import SheetMusicCore
import SheetMusicFoundation

extension MidiRenderer {
    /// The last tempo meta the first track's voice walk wrote, and its tick; before any, the header's default at 0.
    struct TempoSequence {
        var tick = 0
        var micros = MidiRenderer.defaultMicrosPerQuarter
    }

    /// The first track's fermata bookends at their unrolled ticks, in the order `renderTrack` sorts them: on one tick a
    /// close comes ahead of the voice walk's tempo metas and an open after them, each list in its own order.
    struct BookendTempoTrack {
        private struct Bookend {
            let tick: Int
            /// 0 for a close, 2 for an open: the voice walk's metas rank 1, between them.
            let rank: Int
            let micros: Int
            /// Insertion position, every close before every open — what keeps the sort stable.
            let order: Int
        }

        private static let walkRank = 1
        private let bookends: [Bookend]

        init(close: [TimedMidiEvent] = [], open: [TimedMidiEvent] = []) {
            var bookends: [Bookend] = []
            for (events, rank) in [(close, 0), (open, 2)] {
                for event in events {
                    guard case let .meta(.tempo(micros)) = event.event else { continue }
                    bookends.append(Bookend(tick: event.tick, rank: rank, micros: micros, order: bookends.count))
                }
            }
            self.bookends = bookends.sorted { ($0.tick, $0.rank, $0.order) < ($1.tick, $1.rank, $1.order) }
        }

        /// The tempo the track plays just before the voice walk's metas at `tick`: the last bookend sorting between
        /// the walk's own last meta (`sequence`) and them, else that meta's.
        func micros(before tick: Int, after sequence: TempoSequence) -> Int {
            guard let last = bookends.last(where: { ($0.tick, $0.rank) < (tick, Self.walkRank) }),
                  (last.tick, last.rank) > (sequence.tick, Self.walkRank)
            else { return sequence.micros }
            return last.micros
        }
    }

    /// The first track's tempo metas for one plan entry. After a jump — an entry that does not continue the measure
    /// before it — the tempo in force at the target's downbeat, the notated one MuseScore's playback and the cursor
    /// play there (`RepeatList::utick2utime`, `engraving/dom/repeatlist.cpp:297-309`), unless a point on that downbeat
    /// states it or the track already plays it there; then the measure's own points. `sequence` is the walk's last
    /// meta, carried from entry to entry.
    ///
    /// What the track plays at the jump is not the walk's sequence alone: a fermata bookend can sort after its last
    /// meta. A close restores the marking in force where its hold ends on the NOTATED spine (`TempoTimeline.build`);
    /// for a hold ending the bar before the jump that is the downbeat of the bar that follows in notation, so the close
    /// can carry a tempo marked in a bar that is not played next while the sequence already stands at the target's.
    /// (MuseScore restores a hold one tick before its end, on the tempo at the hold — `engraving/dom/score.cpp:623-626`
    /// — so not even its export carries a later bar's tempo across a jump.) The re-statement is skipped only when the
    /// sequence and what the track plays both stand at the target's tempo; keeping the sequence's own test keeps every
    /// re-statement made without the bookends, redundant where a close restored that tempo on the same tick.
    ///
    /// The re-statement is what MuseScore's export lacks: it writes only the map entries inside each repeat segment
    /// (`PauseMap::calculate`, `engraving/compat/midi/pausemap.cpp`), so its SMF keeps the previous segment's tempo
    /// until the next entry. Only a real difference adds an event, so a score MuseScore exports without drift exports
    /// the same here.
    static func tempoEvents(
        for entry: PlaybackEntry, jumped: Bool, tempoMap: ResolvedTempoMap, bookends: BookendTempoTrack,
        sequence: inout TempoSequence,
    ) -> [TimedMidiEvent] {
        var events: [TimedMidiEvent] = []
        let points = tempoMap.points(inMeasure: entry.measureIndex)
        if jumped, points.first?.tickInMeasure != 0 {
            let inForce = tempoMap.point(inForceAtMeasure: entry.measureIndex, tickInMeasure: 0)?
                .microsecondsPerQuarter ?? defaultMicrosPerQuarter
            let playing = bookends.micros(before: entry.tickOffset, after: sequence)
            if inForce != sequence.micros || inForce != playing {
                events.append(TimedMidiEvent(
                    tick: entry.tickOffset, event: .meta(.tempo(microsecondsPerQuarter: inForce)),
                ))
                sequence = TempoSequence(tick: entry.tickOffset, micros: inForce)
            }
        }
        for point in points {
            let tick = entry.tickOffset + point.tickInMeasure
            events.append(TimedMidiEvent(
                tick: tick, event: .meta(.tempo(microsecondsPerQuarter: point.microsecondsPerQuarter)),
            ))
            sequence = TempoSequence(tick: tick, micros: point.microsecondsPerQuarter)
        }
        return events
    }
}
