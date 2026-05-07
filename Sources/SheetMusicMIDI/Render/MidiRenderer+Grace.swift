import Foundation
import SheetMusicCore

extension MidiRenderer {
    /// Default playback length of one grace note in ticks.
    /// Mirrors `CompatMidiRender::graceTickLen` — appoggiatura is
    /// proportional to the parent (`mainTicks/2`); the rest are
    /// constants in PPQ. `acciaccatura` is intentionally short
    /// (1/32 of a quarter) so it reads as a "crushed" ornament.
    static func playbackTicks(
        for grace: GraceChord, mainTicks: Int, division: Int
    ) -> Int {
        switch grace.graceType {
        case .acciaccatura: return division / 8 // 1/32 of a quarter
        case .appoggiatura: return max(0, mainTicks / 2)
        case .grace4: return division // 1/4 = quarter
        case .grace16: return division / 4
        case .grace32: return division / 8
        case .grace8after: return division / 2
        case .grace16after: return division / 4
        case .grace32after: return division / 8
        }
    }

    /// Time stolen from the *previous* chord's tail. Only
    /// acciaccaturas steal from the previous chord; every other
    /// before-grace steals from the parent chord's head.
    /// Mirrors `CompatMidiRender::renderGraceNotesBefore`.
    static func totalStealFromPrev(
        _ before: [GraceChord], division: Int
    ) -> Int {
        before.reduce(0) { acc, g in
            g.graceType == .acciaccatura
                ? acc + playbackTicks(for: g, mainTicks: 0, division: division)
                : acc
        }
    }

    /// Time stolen from the *parent* chord's head. Sum of every
    /// before-grace's playback length, EXCEPT acciaccatura (which
    /// steals from the previous chord). Capped at mainTicks/2 to
    /// keep the parent audible — MuseScore's
    /// `handleOverflowsForGrace` does a non-linear shrink; we do
    /// a single proportional clamp because it handles every realistic
    /// score and stays simple.
    static func totalStealFromMainHead(
        _ before: [GraceChord], mainTicks: Int, division: Int
    ) -> Int {
        let raw = before.reduce(0) { acc, g in
            g.graceType == .acciaccatura
                ? acc
                : acc + playbackTicks(for: g, mainTicks: mainTicks, division: division)
        }
        return min(raw, max(0, mainTicks / 2))
    }

    /// Time stolen from the *parent* chord's tail to fit
    /// after-graces. Same capping rule as the head.
    static func totalStealFromMainTail(
        _ after: [GraceChord], mainTicks: Int, division: Int
    ) -> Int {
        let raw = after.reduce(0) { acc, g in
            acc + playbackTicks(for: g, mainTicks: mainTicks, division: division)
        }
        return min(raw, max(0, mainTicks / 2))
    }

    // swiftlint:disable function_parameter_count function_body_length
    /// Render one parent chord and its surrounding grace notes.
    /// Steals time per the helpers above:
    ///
    ///   prev.tail   ─stealFromPrev─►  before-graces (acciaccatura only)
    ///   main.head   ─stealFromHead─►  before-graces (everything else)
    ///   main.tail   ─stealFromTail─►  after-graces
    ///
    /// Mirrors `CompatMidiRender::renderGraceNotesBefore` /
    /// `renderGraceNotesAfter` semantics, simplified for this codebase
    /// (no per-grace velocity scaling — see spec Non-goals).
    static func renderChordWithGraces(
        _ chord: Chord,
        tick: Int,
        velocity: Int,
        channel: Int,
        instrument: Instrument,
        tempoBps: Double,
        division: Int,
        glissandoEndPitch: Int?,
        currentKey: Int,
        events: inout [TimedMidiEvent]
    ) {
        let mainTicks = chord.duration.ticks(division: division)
        let stealFromPrev = totalStealFromPrev(
            chord.graceNotesBefore, division: division
        )
        let stealFromHead = totalStealFromMainHead(
            chord.graceNotesBefore, mainTicks: mainTicks, division: division
        )
        let stealFromTail = totalStealFromMainTail(
            chord.graceNotesAfter, mainTicks: mainTicks, division: division
        )

        // 1. Pull preceding noteOffs (this voice / channel only) back
        // by `stealFromPrev`, clamped so they never precede their
        // own noteOn. Without this clamp a back-to-back acciaccatura
        // followed by a very short prev chord would overlap.
        if stealFromPrev > 0 {
            let prevNoteOnTicks = collectPriorNoteOnTicks(
                in: events, channel: channel
            )
            for i in events.indices.reversed() {
                guard events[i].tick <= tick - 1,
                      events[i].tick > tick - 1 - stealFromPrev,
                      case let .noteOff(ch, pitch, vel) = events[i].event,
                      ch == channel
                else { continue }
                let onTick = prevNoteOnTicks[pitch] ?? events[i].tick
                let target = max(onTick + 1, events[i].tick - stealFromPrev)
                events[i] = TimedMidiEvent(
                    tick: target,
                    event: .noteOff(channel: ch, pitch: pitch, velocity: vel)
                )
            }
        }

        // 2. Emit before-graces. Two independent cursors so an
        // acciaccatura order-mixed with non-acciaccaturas still
        // lands in the correct steal-region:
        //   prevCursor walks the [tick - stealFromPrev, tick) slot
        //   headCursor walks the [tick, tick + stealFromHead)  slot
        var prevCursor = max(0, tick - stealFromPrev)
        var headCursor = tick
        for g in chord.graceNotesBefore {
            let dur = playbackTicks(
                for: g, mainTicks: mainTicks, division: division
            )
            let onset: Int
            if g.graceType == .acciaccatura {
                onset = prevCursor
                prevCursor += dur
            } else {
                onset = headCursor
                headCursor += dur
            }
            for note in g.notes {
                events.append(TimedMidiEvent(
                    tick: max(0, onset),
                    event: .noteOn(
                        channel: channel,
                        pitch: note.pitch,
                        velocity: velocity
                    )
                ))
                events.append(TimedMidiEvent(
                    tick: max(0, onset + dur - 1),
                    event: .noteOff(
                        channel: channel, pitch: note.pitch, velocity: 0
                    )
                ))
            }
        }

        // 3. Main chord — onset shifted by stealFromHead, length
        //    shortened by stealFromHead + stealFromTail.
        let mainOnset = tick + stealFromHead
        let playedTicks = max(1, mainTicks - stealFromHead - stealFromTail)
        let gate = defaultArticulationGateTime(for: instrument)
        let gatedTicks = playedTicks * gate / 100
        let mainOff = mainOnset + gatedTicks - 1
        if let arpeggio = chord.arpeggio {
            // Keep arpeggio behaviour intact: same call as the
            // pre-grace path, just with the shifted onset / shortened
            // length. This preserves the existing arpeggio tests.
            let pairs = arpeggioNoteEvents(
                noteCount: chord.notes.count,
                chordTicks: playedTicks,
                stretch: arpeggio.timeStretch,
                tempoBps: tempoBps
            )
            let order = arpeggio.isAscending
                ? Array(0 ..< chord.notes.count)
                : Array((0 ..< chord.notes.count).reversed())
            for (i, noteIndex) in order.enumerated() {
                let note = chord.notes[noteIndex]
                let onTick = mainOnset + pairs[i].onOffset
                let offTick = mainOnset + pairs[i].offOffset
                emitNoteEventsForGrace(
                    note: note, channel: channel, velocity: velocity,
                    onTick: onTick, offTick: offTick, events: &events
                )
            }
        } else {
            for note in chord.notes {
                if let glissando = note.glissando, let endPitch = glissandoEndPitch {
                    renderGlissandoNote(
                        note: note, glissando: glissando, endPitch: endPitch,
                        startTick: mainOnset, durationTicks: playedTicks,
                        velocity: velocity, channel: channel,
                        currentKey: currentKey, events: &events
                    )
                } else {
                    emitNoteEventsForGrace(
                        note: note, channel: channel, velocity: velocity,
                        onTick: mainOnset, offTick: mainOff, events: &events
                    )
                }
            }
        }

        // 4. After-graces — share the tail slot the main gave up.
        var afterCursor = mainOnset + playedTicks
        for g in chord.graceNotesAfter {
            let dur = playbackTicks(
                for: g, mainTicks: mainTicks, division: division
            )
            for note in g.notes {
                events.append(TimedMidiEvent(
                    tick: afterCursor,
                    event: .noteOn(
                        channel: channel, pitch: note.pitch, velocity: velocity
                    )
                ))
                events.append(TimedMidiEvent(
                    tick: afterCursor + dur - 1,
                    event: .noteOff(
                        channel: channel, pitch: note.pitch, velocity: 0
                    )
                ))
            }
            afterCursor += dur
        }
    }

    // swiftlint:enable function_parameter_count function_body_length

    /// Map of pitch → most recent noteOn tick on `channel`. Used by
    /// the prev-chord shortening pass to avoid pulling a noteOff in
    /// past its own noteOn.
    private static func collectPriorNoteOnTicks(
        in events: [TimedMidiEvent], channel: Int
    ) -> [Int: Int] {
        var map: [Int: Int] = [:]
        for e in events {
            if case let .noteOn(ch, pitch, _) = e.event, ch == channel {
                map[pitch] = e.tick
            }
        }
        return map
    }

    /// Same tie-aware emit as `MidiRenderer.emitNoteEvents` (private
    /// in `+Voice.swift`). Re-implemented here to avoid widening
    /// access on the original.
    private static func emitNoteEventsForGrace(
        note: Note,
        channel: Int,
        velocity: Int,
        onTick: Int,
        offTick: Int,
        events: inout [TimedMidiEvent]
    ) {
        if note.tieBack == nil {
            events.append(TimedMidiEvent(
                tick: onTick,
                event: .noteOn(channel: channel, pitch: note.pitch, velocity: velocity)
            ))
        }
        if note.tieForward == nil {
            events.append(TimedMidiEvent(
                tick: offTick,
                event: .noteOff(channel: channel, pitch: note.pitch, velocity: 0)
            ))
        }
    }
}
