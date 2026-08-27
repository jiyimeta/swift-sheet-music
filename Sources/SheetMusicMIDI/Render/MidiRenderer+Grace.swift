import SheetMusicCore
import SheetMusicFoundation

extension MidiRenderer {
    /// Default playback length of one grace note in ticks.
    /// Mirrors `CompatMidiRender::graceTickLen` — appoggiatura is
    /// proportional to the parent (`mainTicks/2`); the rest are
    /// constants in PPQ. `acciaccatura` is intentionally short
    /// (1/32 of a quarter) so it reads as a "crushed" ornament.
    static func playbackTicks(
        for grace: GraceChord, mainTicks: Int, division: Int,
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
        _ before: [GraceChord], division: Int,
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
        _ before: [GraceChord], mainTicks: Int, division: Int,
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
        _ after: [GraceChord], mainTicks: Int, division: Int,
    ) -> Int {
        let raw = after.reduce(0) { acc, g in
            acc + playbackTicks(for: g, mainTicks: mainTicks, division: division)
        }
        return min(raw, max(0, mainTicks / 2))
    }

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
    static func renderChordWithGraces( // swiftlint:disable:this function_body_length function_parameter_count
        _ originalChord: Chord,
        tick: Int,
        velocity: Int,
        channel: Int,
        instrument: Instrument,
        tempoBps: Double,
        division: Int,
        glissandoEndPitch: Int?,
        bendChainSlots: BendChainChordSlots? = nil,
        currentKey: Int,
        events: inout [TimedMidiEvent],
        playedTicksOverride: Int? = nil,
        pitchShift: Int = 0,
    ) {
        // Apply an ottava transposition to every sounding pitch
        // (parent + grace notes). Clamping to MIDI's 0..127 keeps a
        // 22ma chord audible at the extremes rather than wrapping.
        let chord = pitchShift == 0
            ? originalChord
            : transpose(originalChord, by: pitchShift)
        let shiftedGlissandoEnd = glissandoEndPitch.map {
            min(127, max(0, $0 + pitchShift))
        }
        // The chain's sounding key rides the ottava like every other pitch.
        let shiftedBendSlots = bendChainSlots.map { shifted($0, by: pitchShift) }
        // `playedTicksOverride` is set by the swing pass to express
        // a chord whose audible length differs from its written
        // duration (off-beat shift / down-beat extension). The grace
        // allocation and gate-time math work off the audible length
        // so swung chords keep proportional grace timing.
        let mainTicks = playedTicksOverride
            ?? chord.duration.ticks(division: division)
        let stealFromPrev = totalStealFromPrev(
            chord.graceNotesBefore, division: division,
        )
        let stealFromHead = totalStealFromMainHead(
            chord.graceNotesBefore, mainTicks: mainTicks, division: division,
        )
        let stealFromTail = totalStealFromMainTail(
            chord.graceNotesAfter, mainTicks: mainTicks, division: division,
        )

        // 1. Pull preceding noteOffs (this voice / channel only) back
        // by `stealFromPrev`, clamped so they never precede their
        // own noteOn. Without this clamp a back-to-back acciaccatura
        // followed by a very short prev chord would overlap.
        if stealFromPrev > 0 {
            let prevNoteOnTicks = collectPriorNoteOnTicks(
                in: events, channel: channel,
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
                    event: .noteOff(channel: ch, pitch: pitch, velocity: vel),
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
        for (graceIndex, g) in chord.graceNotesBefore.enumerated() {
            let dur = playbackTicks(
                for: g, mainTicks: mainTicks, division: division,
            )
            let onset: Int
            if g.graceType == .acciaccatura {
                onset = prevCursor
                prevCursor += dur
            } else {
                onset = headCursor
                headCursor += dur
            }
            emitGraceChord(
                g, slot: shiftedBendSlots?.before[graceIndex],
                onset: max(0, onset), durationTicks: dur,
                velocity: velocity, channel: channel, events: &events,
            )
        }

        // 3. Main chord — onset shifted by stealFromHead, length
        //    shortened by stealFromHead + stealFromTail.
        let mainOnset = tick + stealFromHead
        let playedTicks = max(1, mainTicks - stealFromHead - stealFromTail)
        let gate = effectiveGateTime(for: chord, instrument: instrument)
        let gatedTicks = playedTicks * gate / 100
        let mainOff = mainOnset + gatedTicks - 1
        let mainVelocity = adjustVelocityForChord(
            baseVelocity: velocity,
            chord: chord,
            instrument: instrument,
        )
        if let arpeggio = chord.arpeggio {
            // Keep arpeggio behavior intact: same call as the
            // pre-grace path, just with the shifted onset / shortened
            // length. This preserves the existing arpeggio tests.
            let pairs = arpeggioNoteEvents(
                noteCount: chord.notes.count,
                chordTicks: playedTicks,
                stretch: arpeggio.timeStretch,
                tempoBps: tempoBps,
            )
            let order = arpeggio.isAscending
                ? Array(0 ..< chord.notes.count)
                : Array((0 ..< chord.notes.count).reversed())
            for (i, noteIndex) in order.enumerated() {
                let note = chord.notes[noteIndex]
                let onTick = mainOnset + pairs[i].onOffset
                let offTick = mainOnset + pairs[i].offOffset
                emitNoteEventsForGrace(
                    note: note, channel: channel, velocity: mainVelocity,
                    onTick: onTick, offTick: offTick, events: &events,
                )
            }
        } else {
            // Only the bend-carrying note of the chord drives the chain; the
            // rest emit normally and are dragged along by the channel-wide
            // wheel (see `guitarBendChains`' chord-level simplification).
            let parentSlot = shiftedBendSlots?.parent
            let chainPitch = parentSlot == nil
                ? nil
                : bendChainNote(in: chord.notes)?.pitch
            for note in chord.notes {
                if let slot = parentSlot, note.pitch == chainPitch {
                    renderBendChainNote(
                        note: note, slot: slot,
                        startTick: mainOnset, durationTicks: playedTicks,
                        velocity: mainVelocity, channel: channel,
                        events: &events,
                    )
                } else if let glissando = note.glissando, let endPitch = shiftedGlissandoEnd {
                    renderGlissandoNote(
                        note: note, glissando: glissando, endPitch: endPitch,
                        startTick: mainOnset, durationTicks: playedTicks,
                        velocity: mainVelocity, channel: channel,
                        currentKey: currentKey, events: &events,
                    )
                } else {
                    emitNoteEventsForGrace(
                        note: note, channel: channel, velocity: mainVelocity,
                        onTick: mainOnset, offTick: mainOff, events: &events,
                    )
                }
            }
        }

        // 4. After-graces — share the tail slot the main gave up.
        var afterCursor = mainOnset + playedTicks
        for (graceIndex, g) in chord.graceNotesAfter.enumerated() {
            let dur = playbackTicks(
                for: g, mainTicks: mainTicks, division: division,
            )
            emitGraceChord(
                g, slot: shiftedBendSlots?.after[graceIndex],
                onset: afterCursor, durationTicks: dur,
                velocity: velocity, channel: channel, events: &events,
            )
            afterCursor += dur
        }
    }

    /// Every slot of `slots` with its sounding key transposed — the chain
    /// rides an ottava like any other pitch.
    private static func shifted(
        _ slots: BendChainChordSlots, by semitones: Int,
    ) -> BendChainChordSlots {
        guard semitones != 0 else { return slots }
        func shift(_ slot: BendChainSlot) -> BendChainSlot {
            var copy = slot
            copy.basePitch = min(127, max(0, slot.basePitch + semitones))
            return copy
        }
        var copy = slots
        copy.parent = slots.parent.map(shift)
        copy.before = slots.before.mapValues(shift)
        copy.after = slots.after.mapValues(shift)
        return copy
    }

    // swiftlint:disable:next function_parameter_count
    /// Emit one grace chord's note events.
    ///
    /// A grace note is an ordinary member of a bend chain — MuseScore's
    /// `collectGuitarBend` follows `bendFor()` links without caring whether
    /// the note it lands on is a grace, and starts the wheel segment at the
    /// GRACE's onset for a `GRACE_NOTE_BEND`
    /// (`curPitchBendSegmentStart -= graceOffset`). So the chain member here
    /// goes through `renderBendChainNote`, which strikes the key only at the
    /// chain's head and releases it only at its end; every other grace note
    /// keeps its own plain on/off pair.
    private static func emitGraceChord(
        _ grace: GraceChord,
        slot: BendChainSlot?,
        onset: Int,
        durationTicks: Int,
        velocity: Int,
        channel: Int,
        events: inout [TimedMidiEvent],
    ) {
        let chainPitch = slot == nil ? nil : bendChainNote(in: grace.notes)?.pitch
        for note in grace.notes where note.play {
            if let slot, note.pitch == chainPitch {
                renderBendChainNote(
                    note: note, slot: slot,
                    startTick: onset, durationTicks: durationTicks,
                    velocity: velocity, channel: channel, events: &events,
                )
                continue
            }
            events.append(TimedMidiEvent(
                tick: onset,
                event: .noteOn(
                    channel: channel,
                    pitch: note.pitch,
                    velocity: note.customizedVelocity(velocity),
                ),
            ))
            events.append(TimedMidiEvent(
                tick: max(0, onset + durationTicks - 1),
                event: .noteOff(
                    channel: channel, pitch: note.pitch, velocity: 0,
                ),
            ))
        }
    }

    /// Return a copy of `chord` with every parent and grace-note pitch
    /// shifted by `semitones` and clamped to MIDI's 0..127 range. Used
    /// only by the ottava transposition path; pitches that overflow
    /// pin to the extreme rather than wrapping octaves.
    static func transpose(_ chord: Chord, by semitones: Int) -> Chord {
        guard semitones != 0 else { return chord }
        var result = chord
        result.notes = ChordNotes(chord.notes.map { transpose($0, by: semitones) })
        result.graceNotesBefore = chord.graceNotesBefore.map {
            transpose($0, by: semitones)
        }
        result.graceNotesAfter = chord.graceNotesAfter.map {
            transpose($0, by: semitones)
        }
        return result
    }

    private static func transpose(
        _ grace: GraceChord, by semitones: Int,
    ) -> GraceChord {
        var copy = grace
        copy.notes = ChordNotes(grace.notes.map { transpose($0, by: semitones) })
        return copy
    }

    private static func transpose(_ note: Note, by semitones: Int) -> Note {
        var copy = note
        copy.pitch = min(127, max(0, note.pitch + semitones))
        return copy
    }

    /// Map of pitch → most recent noteOn tick on `channel`. Used by
    /// the prev-chord shortening pass to avoid pulling a noteOff in
    /// past its own noteOn.
    private static func collectPriorNoteOnTicks(
        in events: [TimedMidiEvent], channel: Int,
    ) -> [Int: Int] {
        var map: [Int: Int] = [:]
        for e in events {
            if case let .noteOn(ch, pitch, _) = e.event, ch == channel {
                map[pitch] = e.tick
            }
        }
        return map
    }

    /// Emit note-on/off for a single note, respecting tie flags. For a
    /// tied chain we want ONE combined event pair:
    ///   - A note with `tieBack` set must not re-trigger: its note-on is
    ///     suppressed because the preceding chord's note-on still sounds.
    ///   - A note with `tieForward` set must not release: its note-off is
    ///     suppressed because the sound continues into the next chord.
    /// Mirrors MuseScore's `Note::playTicksFraction()`, which reports the
    /// full tied span as the single sounding event.
    private static func emitNoteEventsForGrace(
        note: Note,
        channel: Int,
        velocity: Int,
        onTick: Int,
        offTick: Int,
        events: inout [TimedMidiEvent],
    ) {
        // A muted note (`<play>0</play>`) emits no MIDI. Mirrors the
        // `if (!note->play()) return;` guard in CompatMidiRender::collectNote.
        guard note.play else { return }
        let velocity = note.customizedVelocity(velocity)
        if note.tieBack == nil {
            events.append(TimedMidiEvent(
                tick: onTick,
                event: .noteOn(channel: channel, pitch: note.pitch, velocity: velocity),
            ))
        }
        if note.tieForward == nil {
            events.append(TimedMidiEvent(
                tick: offTick,
                event: .noteOff(channel: channel, pitch: note.pitch, velocity: 0),
            ))
        }
    }
}
