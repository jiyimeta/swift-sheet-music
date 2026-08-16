import Foundation
import SheetMusicCore

extension MidiRenderer {
    /// One synthesized tempo change bracketing a fermata hold, at a NOTATED (pre-repeat) tick.
    ///
    /// A fermata has no note-duration of its own: `render(score:)` realises the hold by slowing the
    /// tempo across the held chord and restoring it afterwards. Anything that has to agree with the
    /// rendered SMF's clock — a cursor timeline, an elapsed-time readout — needs the same pair of
    /// events, which is what `fermataTempoBookends(score:)` hands back.
    public struct FermataTempoBookend: Sendable, Equatable {
        /// Notated tick the tempo takes effect at.
        public let tick: Int
        public let microsecondsPerQuarter: Int
        /// `false` when this event restores the underlying tempo (no fermata still held at `tick`),
        /// `true` while at least one is. It decides the tie-break against a score `<Tempo>` sitting
        /// on the same tick: a close must lose to it, an open must win — the ordering
        /// `renderTrack`'s stable sort realises by placing close events before the voice walks and
        /// open events after.
        public let isOpen: Bool
    }

    /// Score-global fermata tempo bookends, in ascending tick order.
    ///
    /// Public counterpart of `fermataBookendEvents(score:)`, for callers that need the SMF's tempo
    /// map without rendering it — `PlaybackTimeline` folds these into its own clock so the cursor
    /// holds exactly as long as the audio does.
    public static func fermataTempoBookends(score: Score) -> [FermataTempoBookend] {
        let events = fermataBookendEvents(score: score)
        let tagged = events.closeEvents.map { ($0, false) } + events.openEvents.map { ($0, true) }
        return tagged.compactMap { event, isOpen -> FermataTempoBookend? in
            guard case let .meta(.tempo(micros)) = event.event else { return nil }
            return FermataTempoBookend(
                tick: event.tick, microsecondsPerQuarter: micros, isOpen: isOpen,
            )
        }
        .sorted { ($0.tick, $0.isOpen ? 1 : 0) < ($1.tick, $1.isOpen ? 1 : 0) }
    }

    /// Fermata tempo bookends for the whole score, at notated ticks.
    ///
    /// SCORE-GLOBAL on both halves, and it has to be:
    ///
    /// * The ranges are the union of every staff's fermatas (piecewise-max stretch where they
    ///   overlap, which `tempoEvents`' sweep applies). MuseScore writes a system fermata onto every
    ///   staff, and a hold is a property of the score's clock, not of one part.
    /// * The baseline tempo the bookends are computed against comes from ALL of `systemMeasures`.
    ///   A tempo map is score-global once a sequencer merges the tracks, whereas
    ///   `filterSystemElements` routes a system-level `<Tempo>` to the canonical staff alone — so a
    ///   per-staff build sees no tempo markings on staves 1…n and falls back to 120 BPM. That made
    ///   every non-canonical staff carrying a fermata emit a CLOSE event restoring 120 BPM, which
    ///   then overrode the real tempo in the merged map for the rest of the piece.
    static func fermataBookendEvents(score: Score) -> FermataRanges.TempoEvents {
        let division = score.division
        var ranges: [FermataRange] = []
        for entry in score.allStaves {
            ranges.append(contentsOf: FermataRanges.collect(from: entry.staff, division: division))
        }
        guard !ranges.isEmpty else {
            return FermataRanges.TempoEvents(openEvents: [], closeEvents: [])
        }
        return FermataRanges.tempoEvents(
            ranges: FermataRanges.dedupeMaxStretch(ranges),
            timeline: TempoTimeline.build(
                measures: score.parts.first?.staves.first?.measures ?? [],
                systemMeasures: score.systemMeasures,
                division: division,
            ),
        )
    }
}
