// swiftlint:disable file_length
import Foundation
import SheetMusicCore

/// A pre-computed map from playback time → cursor position, used by
/// `PlaybackEngine` to drive a MuseScore-style cursor that snaps
/// chord-by-chord (not pixel-by-pixel) as audio time advances.
///
/// One frame is emitted per *unique tick*. The set of ticks is the
/// union of:
///
/// * Every chord / rest onset in any voice on any staff (`.item`).
/// * Every metric beat tick derived from the active time signature's
///   denominator (`.beat`) — quarter steps in 3/4 or 4/4, eighth
///   steps in 6/8 or 12/8, etc. These are emitted only at ticks that
///   don't already carry a chord / rest, so a measure densely packed
///   with notes gets no extra beat-only entries while a held half
///   note in 4/4 still gets a cursor stop on beat 2.
///
/// Tempo events inside the score are folded into the time conversion
/// so a `<Tempo>` change halfway through the piece is reflected in
/// `timeSeconds`.
public struct PlaybackTimeline: Sendable, Equatable {
    public struct Frame: Sendable, Equatable {
        public let tick: Int
        public let timeSeconds: TimeInterval
        public let cursor: ScoreCursor
    }

    public let frames: [Frame]
    public let totalSeconds: TimeInterval
    /// End-of-piece tick (last note's offset, not its onset). The
    /// playback engine compares `currentPositionInBeats * division`
    /// against this to detect end of playback.
    public let totalTicks: Int
    public let division: Int
    /// Maps EVERY selectable chord-note / rest in the score to its
    /// onset tick. `frames` carries one representative item per
    /// unique tick column (staff 0 / voice 0 wins the dedup), so an
    /// exact-ID lookup against `frames` would miss selections on any
    /// other staff or voice. This map closes that gap so
    /// `frame(forCursor:)` and `earliest(of:)` can resolve any
    /// selectable item to its tick.
    public let itemTicks: [ScoreItemID: Int]
    /// Companion to `itemTicks` carrying each item's offset tick
    /// (onset + notated duration). All notes inside a chord share the
    /// same end tick. Used by playback features that need to span
    /// "through the end of an item" — e.g. loop regions that should
    /// include the last note's full ringing duration.
    public let itemEndTicks: [ScoreItemID: Int]

    /// Latest frame whose `timeSeconds` is at or before `t`. Used by
    /// the cursor poller — returns `nil` for `t` before the first
    /// event so the cursor can stay hidden until playback actually
    /// starts.
    public func frame(atTime t: TimeInterval) -> Frame? {
        guard !frames.isEmpty, t >= frames[0].timeSeconds else {
            return nil
        }
        // Binary search for the largest index i with
        // frames[i].timeSeconds <= t.
        var lo = 0, hi = frames.count - 1, best = 0
        while lo <= hi {
            let mid = (lo + hi) / 2
            if frames[mid].timeSeconds <= t {
                best = mid
                lo = mid + 1
            } else {
                hi = mid - 1
            }
        }
        return frames[best]
    }

    /// Latest frame whose `tick` is at or before `tick`. Used by the
    /// cursor poller in preference to `frame(atTime:)` because
    /// `AVAudioSequencer.currentPositionInSeconds` is converted from
    /// beats using the sequencer's *current* tempo (not the integrated
    /// tempo map), which makes it unsuitable for cursor sync on a
    /// score with tempo changes — the cursor can race ahead of the
    /// audio when a slower tempo is active. `currentPositionInBeats`
    /// is the stable monotonic clock, so we convert to ticks and look
    /// up by tick directly.
    public func frame(atTick tick: Int) -> Frame? {
        guard !frames.isEmpty, tick >= frames[0].tick else {
            return nil
        }
        var lo = 0, hi = frames.count - 1, best = 0
        while lo <= hi {
            let mid = (lo + hi) / 2
            if frames[mid].tick <= tick {
                best = mid
                lo = mid + 1
            } else {
                hi = mid - 1
            }
        }
        return frames[best]
    }

    /// Find the frame for `cursor` — the column the user wants to
    /// seek to. For `.item` cursors, tries the exact representative
    /// first, then falls back to "any frame at the same tick", so a
    /// selection on a staff that lost the dedup still maps to the
    /// right point in time. For `.beat` cursors, looks up by tick
    /// directly. O(N) — only called at the start of a play-from-
    /// selection action.
    public func frame(forCursor cursor: ScoreCursor) -> Frame? {
        switch cursor {
        case let .item(id):
            if let exact = frames.first(where: { $0.cursor == .item(id) }) {
                return exact
            }
            guard let tick = itemTicks[id] else { return nil }
            return frames.first { $0.tick == tick }
        case .beat:
            return frames.first { $0.cursor == cursor }
        }
    }

    /// Of the supplied items, the one with the smallest onset tick
    /// (ties broken by input order). Items absent from `itemTicks`
    /// are skipped; returns `nil` if none are mapped. Used by
    /// play-from-selection to pick the "first note" of a range —
    /// the user dragged a region with `anchor` and `target` corners
    /// and pressing space should start at whichever corner came
    /// earlier in time, regardless of which one the user clicked
    /// first.
    public func earliest(of items: [ScoreItemID]) -> ScoreItemID? {
        var bestItem: ScoreItemID?
        var bestTick = Int.max
        for item in items {
            guard let tick = itemTicks[item] else { continue }
            if tick < bestTick {
                bestTick = tick
                bestItem = item
            }
        }
        return bestItem
    }
}

extension PlaybackTimeline {
    /// Build a timeline from `score`. Walks each staff/voice for
    /// chord/rest onsets, tracks active time signatures so beat-only
    /// ticks can be inserted between them, and folds tempo events
    /// into the seconds conversion. Mirrors the per-voice tick
    /// accumulation used by `MidiRenderer.renderTrack` so the
    /// playback time we report matches the `.mid` export's timing.
    public init(score: Score) { // swiftlint:disable:this function_body_length
        let division = score.division
        struct Pending {
            let tick: Int
            // Sort key for dedup: lower wins. Item entries from
            // staff/voice (0,0) sort before beat-only entries
            // (which use sentinel sort keys at the end).
            let sortKey: (Int, Int)
            let cursor: ScoreCursor
        }
        var pending: [Pending] = []
        // (tick, microseconds-per-quarter). Default 120 BPM = 500_000.
        var tempoEvents: [(tick: Int, mpq: Int)] = []
        var maxEndTick = 0
        var itemTicks: [ScoreItemID: Int] = [:]
        var itemEndTicks: [ScoreItemID: Int] = [:]

        // Per-measure cache: absolute start tick of each measure
        // (from staff 0's voice 0 spine) and the time signature
        // active at that measure. Beat ticks are computed from
        // these in a second pass below.
        let measureCount = score.parts.first?.staves.first?.measures.count ?? 0
        var measureStarts = [Int](repeating: 0, count: measureCount)
        var measureTimeSigs = [TimeSignature](
            repeating: TimeSignature(numerator: 4, denominator: 4),
            count: measureCount,
        )
        var spineTick = 0
        var currentTimeSig = TimeSignature(numerator: 4, denominator: 4)
        for mi in 0 ..< measureCount {
            measureStarts[mi] = spineTick
            // Time signature for this measure: take whichever is
            // declared in voice 0 (any staff) before the first
            // chord / rest. Falls back to the previous measure's
            // value, with 4/4 as the global default.
            staffLoop: for entry in score.allStaves {
                let staff = entry.staff
                guard mi < staff.measures.count else { continue }
                for el in staff.measures[mi].voices.first?.elements ?? [] {
                    switch el {
                    case let .timeSignature(ts):
                        currentTimeSig = ts
                        break staffLoop
                    case .chord:
                        // Time sigs are emitted before the first
                        // chord/rest; once we see one we're past
                        // the meta header for this measure.
                        break staffLoop
                    default:
                        break
                    }
                }
            }
            measureTimeSigs[mi] = currentTimeSig
            // Advance the spine by voice 0 / staff 0's chord+rest
            // durations. Other voices in the same measure share
            // this start tick by construction.
            if let voice0 = score.parts.first?.staves.first?.measures[mi].voices.first {
                for el in voice0.elements {
                    switch el {
                    case let .chord(c):
                        spineTick += c.duration.ticks(division: division)
                    default:
                        break
                    }
                }
            }
        }

        for (staffIdx, entry) in score.allStaves.enumerated() {
            let staff = entry.staff
            for (measureIdx, measure) in staff.measures.enumerated() {
                let measureStartTick = measureIdx < measureCount
                    ? measureStarts[measureIdx]
                    : 0
                for (voiceIdx, voice) in measure.voices.enumerated() {
                    var tick = measureStartTick
                    for (elemIdx, el) in voice.elements.enumerated() {
                        switch el {
                        case let .locationShift(delta):
                            // Mirrors `MidiRenderer.renderVoiceElement`'s
                            // handling — the running tick cursor jogs by
                            // the location's fractional delta so any
                            // following Tempo / chord / rest lands at the
                            // same absolute tick the MIDI sequencer uses.
                            // Without this, tempo events emitted after a
                            // `<location>` shift would be recorded at the
                            // wrong tick, making `timeSeconds` drift away
                            // from `currentPositionInSeconds` and the
                            // playback cursor jump ahead of the audio.
                            tick += delta.ticks(division: division)
                        case let .chord(chord) where !chord.notes.isEmpty:
                            let chordDur = chord.duration.ticks(
                                division: division,
                            )
                            for noteIdx in chord.notes.indices {
                                let nid = NoteID(
                                    staff: entry.address,
                                    measureIndex: measureIdx,
                                    voiceIndex: voiceIdx,
                                    elementIndex: elemIdx,
                                    noteIndexInChord: noteIdx,
                                )
                                itemTicks[.note(nid)] = tick
                                itemEndTicks[.note(nid)] = tick + chordDur
                            }
                            let id = NoteID(
                                staff: entry.address,
                                measureIndex: measureIdx,
                                voiceIndex: voiceIdx,
                                elementIndex: elemIdx,
                                noteIndexInChord: 0,
                            )
                            pending.append(.init(
                                tick: tick,
                                sortKey: (staffIdx, voiceIdx),
                                cursor: .item(.note(id)),
                            ))
                            tick += chordDur
                        case let .chord(rest):
                            // Empty chord = rest.
                            let id = RestID(
                                staff: entry.address,
                                measureIndex: measureIdx,
                                voiceIndex: voiceIdx,
                                elementIndex: elemIdx,
                            )
                            itemTicks[.rest(id)] = tick
                            itemEndTicks[.rest(id)] = tick
                                + rest.duration.ticks(division: division)
                            // Whole-note rests render *centered* in the
                            // measure, not at the rhythmic onset
                            // column (`LayoutEngine+Placement.swift`'s
                            // `isWholeRest` branch). Letting one win
                            // the cursor-frame slot would park the
                            // cursor halfway through the bar while
                            // audio is still on beat 1 — visible as
                            // the cursor being ~5/16 ahead at every
                            // measure with a `<durationType>measure
                            // </durationType>` rest on staff 0. Skip
                            // those from the cursor's pending entries
                            // so the dedup falls through to a chord
                            // onset on another staff (or a `.beat`
                            // entry for that tick), both of which sit
                            // on the correct rhythmic column.
                            let restTicks = rest.duration.ticks(
                                division: division,
                            )
                            let isWholeNoteRest =
                                restTicks >= 4 * division
                            if !isWholeNoteRest {
                                pending.append(.init(
                                    tick: tick,
                                    sortKey: (staffIdx, voiceIdx),
                                    cursor: .item(.rest(id)),
                                ))
                            }
                            tick += restTicks
                        default:
                            break
                        }
                    }
                    maxEndTick = max(maxEndTick, tick)
                }
            }
        }

        // Beat-only entries — one per metric beat tick that isn't
        // already carrying a chord/rest. The sortKey puts these
        // strictly after any item at the same tick, so the dedup
        // below picks the .item cursor when both exist.
        var occupied: Set<Int> = Set(pending.map(\.tick))
        for mi in 0 ..< measureCount {
            let ts = measureTimeSigs[mi]
            // Beat unit ticks = ticks-per-quarter * 4 / denominator.
            // 4/4 → division ticks (quarter); 6/8 → division/2
            // (eighth); etc. Mirrors MuseScore's metronome step
            // for non-compound time signatures
            // (`PlaybackEventsRenderer::renderMetronome` →
            // `dUnitTicks()`). Compound-vs-simple distinction
            // depends on tempo there, but for cursor positioning
            // the simpler denominator-derived step is what the
            // user asked for.
            let step = max(1, division * 4 / ts.denominator)
            for i in 0 ..< ts.numerator {
                let beatTick = measureStarts[mi] + i * step
                guard !occupied.contains(beatTick) else { continue }
                pending.append(.init(
                    tick: beatTick,
                    sortKey: (Int.max, Int.max),
                    cursor: .beat(
                        measureIndex: mi,
                        tickInMeasure: i * step,
                    ),
                ))
                occupied.insert(beatTick)
            }
        }

        // Stable sort: tick → sortKey so dedup picks a deterministic
        // representative cursor per tick column (item beats beat).
        pending.sort {
            if $0.tick != $1.tick { return $0.tick < $1.tick }
            if $0.sortKey.0 != $1.sortKey.0 {
                return $0.sortKey.0 < $1.sortKey.0
            }
            return $0.sortKey.1 < $1.sortKey.1
        }
        // Pull tempo events from the score-level `systemMeasures`.
        // Each entry's `MeasurePosition` is relative to its measure
        // start, so we add `measureStarts[measureIdx]` to land at
        // the absolute spine tick.
        for (measureIdx, systemMeasure) in score.systemMeasures.enumerated() {
            guard measureIdx < measureStarts.count else { continue }
            let measureStart = measureStarts[measureIdx]
            for positioned in systemMeasure.elements {
                guard case let .tempo(t) = positioned.element else { continue }
                let tick = measureStart + positioned.position.ticks(
                    division: division,
                )
                tempoEvents.append((tick, t.microsecondsPerQuarter))
            }
        }
        tempoEvents.sort { $0.tick < $1.tick }

        // Walk pending entries, advancing time using the tempo map.
        var frames: [Frame] = []
        var lastTick = 0
        var currentMpq = 500_000 // 120 BPM default
        var nextTempoIdx = 0
        var currentTime: TimeInterval = 0
        var lastEmittedTick = -1

        func advance(to targetTick: Int) {
            while nextTempoIdx < tempoEvents.count
                && tempoEvents[nextTempoIdx].tick <= targetTick
            {
                let te = tempoEvents[nextTempoIdx]
                let dt = te.tick - lastTick
                if dt > 0 {
                    currentTime += secondsForTicks(
                        dt, mpq: currentMpq, division: division,
                    )
                }
                currentMpq = te.mpq
                lastTick = te.tick
                nextTempoIdx += 1
            }
            let dt = targetTick - lastTick
            if dt > 0 {
                currentTime += secondsForTicks(
                    dt, mpq: currentMpq, division: division,
                )
            }
            lastTick = targetTick
        }

        for entry in pending {
            advance(to: entry.tick)
            if entry.tick != lastEmittedTick {
                frames.append(Frame(
                    tick: entry.tick,
                    timeSeconds: currentTime,
                    cursor: entry.cursor,
                ))
                lastEmittedTick = entry.tick
            }
        }
        // End time: advance to the last tick reached by any voice.
        advance(to: maxEndTick)

        self.frames = frames
        totalSeconds = currentTime
        totalTicks = maxEndTick
        self.division = division
        self.itemTicks = itemTicks
        self.itemEndTicks = itemEndTicks
    }
}

private func secondsForTicks(
    _ ticks: Int, mpq: Int, division: Int,
) -> TimeInterval {
    TimeInterval(ticks) * TimeInterval(mpq)
        / TimeInterval(division) / 1_000_000
}
